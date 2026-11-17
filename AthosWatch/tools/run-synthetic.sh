#!/bin/bash
# 在已启动的 watchOS 模拟器上跑一遍「门控 → 切段 → 写盘」全链路。
# 灌 12 秒合成信号（2s 静音 → 3s 人声 → 4s 静音 → 3s 人声），不需要麦克风。
#
#   bash tools/run-synthetic.sh                 # 默认等 20 秒
#   bash tools/run-synthetic.sh 30              # 等 30 秒
#   bash tools/run-synthetic.sh 20 -sensitivity 6   # 额外参数原样传给 App
#
# 前提：模拟器已在运行，且已用 tools/preview.sh 装过一次（或本脚本会自行构建安装）。

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BUNDLE_ID="com.kakaqiang.athos"
WAIT_SECONDS="${1:-20}"
shift || true
# bash 3.2 在 set -u 下展开空数组会报 unbound variable，先判长度再拼。
LAUNCH_ARGS=(-synthetic)
EXTRA_NOTE=""
if [[ $# -gt 0 ]]; then
    LAUNCH_ARGS+=("$@")
    EXTRA_NOTE="，额外参数: $*"
fi

UDID=$(xcrun simctl list devices booted 2>/dev/null \
    | grep -i "watch" | grep "Booted" | head -1 \
    | sed -E 's/.*\(([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\).*/\1/')

if [[ -z "$UDID" ]]; then
    echo "❌ 没有正在运行的 watchOS 模拟器。先执行：bash tools/preview.sh"
    exit 1
fi
echo "✅ 模拟器: $UDID"

APP=$(find build-sim/Build/Products -maxdepth 2 -name "*.app" -print 2>/dev/null | head -1)
if [[ -z "$APP" ]]; then
    echo "==> 还没有产物，先构建"
    xcodebuild -project AthosWatch.xcodeproj -scheme AthosWatch \
        -destination "id=$UDID" -derivedDataPath build-sim \
        -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 \
        | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head -10
    APP=$(find build-sim/Build/Products -maxdepth 2 -name "*.app" -print | head -1)
fi
[[ -z "$APP" ]] && { echo "❌ 构建产物不存在"; exit 1; }

echo "==> 安装"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
xcrun simctl install "$UDID" "$APP" || exit 1

echo "==> 启动合成信号（约 ${WAIT_SECONDS}s，含 12s 音频 + 收尾）${EXTRA_NOTE}"
TRACE_BEFORE=0
CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null)
if [[ -n "$CONTAINER" && -f "$CONTAINER/Documents/athos-trace.log" ]]; then
    TRACE_BEFORE=$(wc -l < "$CONTAINER/Documents/athos-trace.log" | tr -d ' ')
fi

xcrun simctl launch "$UDID" "$BUNDLE_ID" "${LAUNCH_ARGS[@]}" >/dev/null
sleep "$WAIT_SECONDS"

CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null)
if [[ -z "$CONTAINER" ]]; then
    echo "❌ 取不到容器路径"
    exit 1
fi

echo
echo "=== 本次门控轨迹 ==="
if [[ -f "$CONTAINER/Documents/athos-trace.log" ]]; then
    sed -n "$((TRACE_BEFORE + 1)),\$p" "$CONTAINER/Documents/athos-trace.log" \
        | grep -E "gate (opened|closed|rotated)|pass end" || echo "（本次没有开关门事件）"
else
    echo "（没有 trace 文件，检查是否带 -synthetic 启动）"
fi

echo
echo "=== 产出文件 ==="
SEG="$CONTAINER/Documents/Segments"
if [[ -d "$SEG" ]]; then
    for f in "$SEG"/*.m4a; do
        [[ -f "$f" ]] || continue
        DUR=$(afinfo "$f" 2>/dev/null | awk '/estimated duration/{print $3}')
        printf "  %-34s %8s B  %ss\n" "$(basename "$f")" "$(stat -f%z "$f")" "${DUR:-?}"
    done
else
    echo "  （没有 Segments 目录）"
fi

echo
echo "导出到本机：make export   （或 bash tools/pull-recordings.sh ./export）"
