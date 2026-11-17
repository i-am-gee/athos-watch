#!/bin/bash
set -uo pipefail

# 在 Mac 上的 watchOS 模拟器里预览 Athos。
#   bash tools/preview.sh          构建 + 启动，并截图到 /tmp/athos-preview.png
#   bash tools/preview.sh --shot   仅重新截图（App 已在运行时）
#
# 前提：已安装 watchOS 模拟器运行时
#   xcodebuild -downloadPlatform watchOS

cd "$(dirname "$0")/.." || exit 1

BUNDLE_ID="com.kakaqiang.athos"
SHOT_PATH="/tmp/athos-preview.png"

# ---------- 1. 找运行时 ----------
RUNTIME=$(xcrun simctl list runtimes 2>/dev/null | grep -o 'com\.apple\.CoreSimulator\.SimRuntime\.watchOS-[0-9-]*' | tail -1)
if [ -z "$RUNTIME" ]; then
  echo "❌ 未安装 watchOS 模拟器运行时。请先执行："
  echo "   xcodebuild -downloadPlatform watchOS"
  echo "   或在 Xcode → Settings → Components 中下载 watchOS Simulator"
  exit 1
fi
echo "✅ 运行时: $RUNTIME"

# ---------- 2. 找一个手表模拟器 ----------
UDID=$(xcrun simctl list devices available 2>/dev/null \
  | grep -B0 -A0 "" \
  | awk '/-- watchOS/{f=1; next} /^-- /{f=0} f && /\([0-9A-F-]{36}\)/{print}' \
  | head -1 | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')

if [ -z "$UDID" ]; then
  DEVTYPE=$(xcrun simctl list devicetypes 2>/dev/null | grep -o 'com\.apple\.CoreSimulator\.SimDeviceType\.Apple-Watch[^ )]*' | tail -1)
  if [ -z "$DEVTYPE" ]; then
    echo "❌ 找不到 Apple Watch 设备类型，运行时可能不完整"
    exit 1
  fi
  echo "==> 创建设备: $DEVTYPE"
  UDID=$(xcrun simctl create "Athos Watch" "$DEVTYPE" "$RUNTIME")
  [ -z "$UDID" ] && { echo "❌ 创建模拟器失败"; exit 1; }
fi
echo "✅ 模拟器 UDID: $UDID"

if [ "${1:-}" = "--shot" ]; then
  xcrun simctl io "$UDID" screenshot "$SHOT_PATH" && echo "📸 $SHOT_PATH"
  exit $?
fi

# ---------- 3. 启动模拟器 ----------
echo "==> 启动模拟器"
xcrun simctl boot "$UDID" 2>/dev/null || echo "    （已在运行）"
open -a "$(xcode-select -p)/Applications/Simulator.app" 2>/dev/null || echo "    （模拟器界面已就绪）"
sleep 8

# ---------- 4. 构建（模拟器，无需签名）----------
echo "==> 构建 (watchOS Simulator)"
xcodebuild \
  -project AthosWatch.xcodeproj \
  -scheme AthosWatch \
  -destination "id=$UDID" \
  -derivedDataPath build-sim \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head -20

APP=$(find build-sim/Build/Products -maxdepth 2 -name "*.app" -print | head -1)
if [ -z "$APP" ]; then
  echo "❌ 未找到产物"
  exit 1
fi
echo "✅ 产物: $APP"

# ---------- 5. 安装并启动 ----------
echo "==> 安装"
xcrun simctl install "$UDID" "$APP" || { echo "❌ 安装失败"; exit 1; }

echo "==> 启动"
xcrun simctl launch "$UDID" "$BUNDLE_ID" || echo "⚠️  首次启动可能需要先在界面上点一下 App 图标"

sleep 5
xcrun simctl io "$UDID" screenshot "$SHOT_PATH" && echo "📸 截图: $SHOT_PATH"

cat <<EOF

预览已启动。注意两点：
  1. 模拟器要听到声音，请使用 Mac 的麦克风说话，或播放一段人声录音。
  2. 若界面一直显示「待机」，先点一次「开始监听」，再授予麦克风权限。
     模拟器的权限弹窗在 模拟器菜单 → Features → 或设备设置中确认。
EOF
