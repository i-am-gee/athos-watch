#!/bin/bash
# 构建手机端、装进 iPhone 模拟器、启动并截图。
#
#   bash tools/build-phone.sh            构建 + 安装 + 启动 + 截图
#   bash tools/build-phone.sh --review   直接打开「本周复盘」页再截图
#
# 为什么每次都全量重建：Xcode 27 在增量编译时会话式地让 SwiftUI 的宏插件失效
# （swift-plugin-server produced malformed response / StateMacro not found），
# 报错指向 @State 这一行。清掉 DerivedData 后必过，留下这个判断比反复试错便宜。

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BUNDLE_ID="com.kakaqiang.athos.phone"
DEVICE_NAME="${ATHOS_PHONE_DEVICE:-iPhone 18 Pro}"
SHOT="${2:-/tmp/athos-phone.png}"
LAUNCH_ARGS=()
if [ "${1:-}" = "--review" ]; then
  LAUNCH_ARGS=(-showReview)
  SHOT="/tmp/athos-phone-review.png"
fi

UDID=$(xcrun simctl list devices available 2>/dev/null \
  | grep -F "$DEVICE_NAME (" | head -1 \
  | sed -E 's/.*\(([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\).*/\1/')

if [[ -z "$UDID" ]]; then
  echo "❌ 找不到模拟器「$DEVICE_NAME」。可用设备："
  xcrun simctl list devices available | grep -i iphone | head -10
  exit 1
fi
echo "✅ 模拟器: $DEVICE_NAME ($UDID)"

echo "==> 启动模拟器"
xcrun simctl boot "$UDID" 2>/dev/null || true

echo "==> 生成工程（新增源文件必须重新生成，否则编译时报找不到符号）"
command -v xcodegen >/dev/null 2>&1 && xcodegen generate >/dev/null || echo "    （未装 xcodegen，沿用现有工程）"

echo "==> 生成工程（新增源文件必须重新生成，否则编译时报找不到符号）"
command -v xcodegen >/dev/null 2>&1 && xcodegen generate >/dev/null || echo "    （未装 xcodegen，沿用现有工程）"

echo "==> 清理 DerivedData（绕开 Xcode 27 增量编译的宏插件缺陷）"
rm -rf build-phone

echo "==> 构建 AthosPhone"
xcodebuild -project AthosWatch.xcodeproj -scheme AthosPhone \
  -destination "id=$UDID" -derivedDataPath build-phone \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head -20

APP="build-phone/Build/Products/Debug-iphonesimulator/Athos.app"
if [[ ! -d "$APP" ]]; then
  echo "❌ 没有产物：$APP"
  exit 1
fi

echo "==> 安装"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
xcrun simctl install "$UDID" "$APP" || exit 1

echo "==> 启动 ${LAUNCH_ARGS[*]:-}"
# bash 3.2 在 set -u 下展开空数组会报 unbound variable，用 +"..." 形式保护
xcrun simctl launch "$UDID" "$BUNDLE_ID" ${LAUNCH_ARGS[@]+"${LAUNCH_ARGS[@]}"} >/dev/null || exit 1

sleep 4
xcrun simctl io "$UDID" screenshot "$SHOT" >/dev/null 2>&1 && echo "📸 $SHOT"
