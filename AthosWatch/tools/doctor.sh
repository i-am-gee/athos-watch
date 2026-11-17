#!/bin/bash
# 体检：现在这台电脑能不能把 Athos 装到手表上，卡在哪一步。
#   bash tools/doctor.sh
#
# 只读检查，不修改任何东西。

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

ok() { printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad() { printf "  \033[31m✗\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }

echo
echo "Athos 环境体检"
echo "──────────────────────────────────────────"

# ---------- 1. Xcode ----------
echo "[1] Xcode"
DEV_DIR=$(xcode-select -p 2>/dev/null)
if [[ "$DEV_DIR" == *"Xcode.app"* ]]; then
    ok "命令行工具指向 $(basename "$(dirname "$(dirname "$DEV_DIR")")")"
else
    bad "命令行工具指向 $DEV_DIR（不是 Xcode）"
    echo "      修：sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

if XV=$(xcodebuild -version 2>/dev/null | head -1); then
    ok "$XV"
else
    bad "xcodebuild 不可用"
fi

echo
echo "[2] watchOS SDK 与模拟器"
if SDK=$(xcodebuild -showsdks 2>/dev/null | grep -E "watchOS [0-9]" | head -1); then
    ok "$(echo "$SDK" | sed 's/^[[:space:]]*//' | awk '{print $1, $2}')"
else
    bad "没有 watchOS SDK"
fi

RUNTIME=$(xcrun simctl list runtimes 2>/dev/null | grep -i "watchOS" | tail -1)
if [[ -n "$RUNTIME" ]]; then
    ok "模拟器运行时 $(echo "$RUNTIME" | sed -E 's/.*watchOS ([0-9.]+).*/watchOS \1/')"
else
    warn "没有 watchOS 模拟器运行时（只影响模拟器预览，不影响真机）"
    echo "      装：xcodebuild -downloadPlatform watchOS"
fi

echo
echo "[3] 工程与工具链"
if command -v xcodegen >/dev/null 2>&1; then
    ok "xcodegen $(xcodegen --version 2>/dev/null | head -1 | awk '{print $NF}')"
else
    warn "未安装 xcodegen（已有 .xcodeproj 时可以先不管）"
    echo "      装：brew install xcodegen"
fi

if [[ -f AthosWatch.xcodeproj/project.pbxproj ]]; then
    ok "工程文件存在"
    SOURCES_MISSING=0
    while IFS= read -r file; do
        base=$(basename "$file")
        grep -q "$base" AthosWatch.xcodeproj/project.pbxproj 2>/dev/null || {
            warn "$base 还没进工程"
            SOURCES_MISSING=1
        }
    done < <(find Sources -name '*.swift')
    [[ "$SOURCES_MISSING" == "1" ]] && echo "      修：make gen（新增 .swift 后必须重新生成工程）"
    [[ "$SOURCES_MISSING" == "0" ]] && ok "Sources 下所有 .swift 都已在工程里"
else
    bad "没有 .xcodeproj"
    echo "      修：make gen"
fi

echo
echo "[4] 签名"
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -c "Apple Development")
if [[ "$IDENTITY" -gt 0 ]]; then
    ok "$IDENTITY 个可用的开发证书"
else
    bad "没有有效的开发证书"
    echo "      两种可能："
    echo "        a) Xcode → Settings → Accounts 没登录 Apple ID"
    echo "        b) 证书存在但链断了（缺 WWDR G3），见 README「证书存在却被判为无效身份」"
fi

TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | grep -oE 'teamID = [A-Z0-9]{10}' | head -1 | awk '{print $3}')
if [[ -n "$TEAM" ]]; then
    ok "Team ID: $TEAM"
    if defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null | grep -q "isFreeProvisioningTeam = 1"; then
        warn "这是免费 Personal Team：证书 7 天过期，到期 App 打不开，需重新 ⌘R 或 redeploy.sh"
    fi
else
    warn "读不到 Team ID（Xcode 里没选中过团队）"
fi

PROJ_TEAM=$(grep -E 'DEVELOPMENT_TEAM:' project.yml | grep -o '"[^"]*"' | tr -d '"')
PROJ_BUNDLE=$(grep -E 'PRODUCT_BUNDLE_IDENTIFIER:' project.yml | grep -o ': .*' | sed 's/: //')
echo "  · 工程里写的是 Team=$PROJ_TEAM  Bundle=$PROJ_BUNDLE"
if [[ -n "$TEAM" && -n "$PROJ_TEAM" && "$TEAM" != "$PROJ_TEAM" ]]; then
    warn "两者不一致，装真机会报签名错误；改 project.yml 后 make gen"
fi

echo
echo "[5] 设备"
REAL=$(xcrun devicectl list devices 2>/dev/null | grep -i watch | grep -vi simulat | head -1)
if [[ -n "$REAL" ]]; then
    ok "真机：$(echo "$REAL" | cut -c1-60)"
else
    warn "没有已连接的 Apple Watch"
    echo "      真机安装需要：解锁手表、放充电器、两台设备开开发者模式、数据线接 iPhone"
fi

SIM=$(xcrun simctl list devices booted 2>/dev/null | grep -i watch | grep Booted | head -1)
if [[ -n "$SIM" ]]; then
    ok "模拟器：已启动"
else
    warn "没有正在运行的 watchOS 模拟器（make sim 会自动起一台）"
fi

echo
echo "──────────────────────────────────────────"
if [[ "$IDENTITY" -gt 0 && -n "$TEAM" && -n "$REAL" ]]; then
    echo "结论：可以装到真机。  下一步 →  ⌘R 或 ./redeploy.sh <手表UDID>"
elif [[ "$IDENTITY" -gt 0 ]]; then
    echo "结论：签名就绪，但没检测到手表。可以先 make sim 看界面。"
else
    echo "结论：只能先跑模拟器（make sim），真机还差签名。"
fi
echo
