#!/bin/bash
# 把 Apple Watch（或模拟器）上 Athos 录到的音频导出到本机。
#
# 用法：
#   ./tools/pull-recordings.sh                      # 自动选设备，导出到 ./export
#   ./tools/pull-recordings.sh ./export             # 指定输出目录
#   ./tools/pull-recordings.sh ./export <UDID>      # 指定设备
#   ./tools/pull-recordings.sh ./export --sim       # 强制走模拟器（当前已启动的那台）
#
# 真机前提：手表已解锁、已在充电或与电脑同网络、手表的开发者模式已打开。

set -euo pipefail

BUNDLE_ID="${ATHOS_BUNDLE_ID:-com.kakaqiang.athos}"
DEST="${1:-./export}"
MODE="${2:-}"

mkdir -p "$DEST"

# ---------- 1. 选设备 ----------

REAL_DEVICE=""
SIM_DEVICE=""

REAL_DEVICE=$(xcrun devicectl list devices 2>/dev/null \
    | grep -i "watch" \
    | grep -vi "simulat" \
    | head -1 \
    | sed -E 's/.*[[:space:]]([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}).*/\1/' \
    || true)

SIM_DEVICE=$(xcrun simctl list devices booted 2>/dev/null \
    | grep -i "watch" \
    | grep "Booted" \
    | head -1 \
    | sed -E 's/.*\(([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\).*/\1/' \
    || true)

use_sim=0
if [[ "$MODE" == "--sim" ]]; then
    use_sim=1
elif [[ -n "$MODE" && "$MODE" != "--sim" ]]; then
    # 第二个参数被当成 UDID 传入
    if [[ "$MODE" =~ ^[0-9A-F-]{36}$ ]]; then
        REAL_DEVICE="$MODE"
    fi
elif [[ -z "$REAL_DEVICE" && -n "$SIM_DEVICE" ]]; then
    echo "→ 没检测到真机手表，改用已启动的模拟器。"
    use_sim=1
fi

# ---------- 2. 取数据 ----------

extract_sim() {
    local udid="$1"
    local container
    container=$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data 2>/dev/null || true)
    if [[ -z "$container" || ! -d "$container/Documents/Segments" ]]; then
        echo "✗ 这台模拟器上没有 Athos 的录音目录。先装 App 并录几段。" >&2
        return 1
    fi
    echo "→ 源目录：$container/Documents/Segments"
    cp -R "$container/Documents/Segments/." "$DEST/"
}

extract_device() {
    local udid="$1"
    echo "→ 从真机导出（手表需解锁）…"
    xcrun devicectl device copy from \
        --device "$udid" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source "Documents/Segments" \
        --destination "$DEST"
}

if [[ "$use_sim" == "1" ]]; then
    if [[ -z "$SIM_DEVICE" ]]; then
        echo "✗ 没有正在运行的 watchOS 模拟器。先启动一台（或直接接真机）。" >&2
        exit 1
    fi
    echo "→ 目标设备：模拟器 $SIM_DEVICE"
    extract_sim "$SIM_DEVICE"
else
    if [[ -z "$REAL_DEVICE" ]]; then
        cat <<'EOF'
✗ 没找到可导出的设备。按顺序检查：
  1. 手表已解锁（锁屏状态 devicectl 连不上）
  2. 手表「设置 → 隐私与安全性 → 开发者模式」已打开
  3. 数据线接着 iPhone，且手表在充电或与电脑同一 Wi-Fi
  4. Xcode → Window → Devices and Simulators 里能看到这只表

不依赖本脚本的手动导出：
  Xcode → Window → Devices and Simulators → 选中手表 → 选中 Athos
  → 齿轮菜单 → Download Container… → 得到的 .xcappdata 右键「显示包内容」
  → AppData/Documents/Segments 就是全部录音。

只想看模拟器的数据：
  ./tools/pull-recordings.sh ./export --sim
EOF
        exit 1
    fi
    echo "→ 目标设备：$REAL_DEVICE"
    extract_device "$REAL_DEVICE"
fi

# ---------- 3. 生成清单 ----------

COUNT=$(find "$DEST" -name '*.m4a' | wc -l | tr -d ' ')
if [[ "$COUNT" == "0" ]]; then
    echo "✗ 导出目录里没有 .m4a。设备上可能还没录到东西。"
    exit 1
fi

python3 - "$DEST" <<'PY'
import json, os, sys, csv, datetime

dest = sys.argv[1]
rows = []
# startedAt 是 Date.timeIntervalSinceReferenceDate（2001-01-01 UTC 起算），
# 必须加上该基准的时间戳再交给 fromtimestamp 转本地时区，否则整体差 8 小时。
REFERENCE_EPOCH = 978307200

# 以 .m4a 为准遍历：没有 sidecar 的分段（App 被强杀时最后一段）也必须出现在清单里，
# 否则「导出目录里有文件、清单里没有」会让后续转写静默漏掉内容。
for name in sorted(os.listdir(dest)):
    if not name.endswith(".m4a"):
        continue
    audio = os.path.join(dest, name)
    sidecar = audio[:-4] + ".json"
    size = os.path.getsize(audio)

    meta = None
    if os.path.exists(sidecar):
        try:
            meta = json.load(open(sidecar))
        except Exception:
            meta = None

    if meta:
        started = datetime.datetime.fromtimestamp(meta.get("startedAt", 0) + REFERENCE_EPOCH)
        duration = round(meta.get("duration", 0), 2)
        size = meta.get("bytes", size)
        status = "ok"
    else:
        # seg-20261116-201225-235.m4a → 20261116-201225
        parts = name.split("-")
        stamp = parts[1] + "-" + parts[2] if len(parts) >= 3 else None
        try:
            started = datetime.datetime.strptime(stamp, "%Y%m%d-%H%M%S")
        except Exception:
            started = datetime.datetime.fromtimestamp(os.path.getmtime(audio))
        duration = 0.0
        status = "未完成"

    rows.append({
        "file": name,
        "started_at": started.strftime("%Y-%m-%d %H:%M:%S"),
        "duration_s": duration,
        "bytes": size,
        "status": status,
    })

rows.sort(key=lambda r: r["started_at"])
out = os.path.join(dest, "index.csv")
with open(out, "w", newline="") as fh:
    writer = csv.DictWriter(fh, fieldnames=["file", "started_at", "duration_s", "bytes", "status"])
    writer.writeheader()
    writer.writerows(rows)

ok_rows = [r for r in rows if r["status"] == "ok"]
broken = len(rows) - len(ok_rows)
total_s = sum(r["duration_s"] for r in ok_rows)
total_b = sum(r["bytes"] for r in rows)
print(f"✓ {len(rows)} 段 · 可播放 {len(ok_rows)} 段 · 共 {total_s:.1f} 秒 · {total_b/1024:.0f} KB")
if broken:
    print(f"  ⚠ {broken} 段未完成（无索引，播不了），清单里 status 标为「未完成」")
print(f"  清单：{out}")
if rows:
    print(f"  最早：{rows[0]['started_at']}  最新：{rows[-1]['started_at']}")
PY

echo "  试听：afplay \"$DEST\"/*.m4a"
echo "  单段：afinfo \"$DEST/<文件名>\" | grep duration"
