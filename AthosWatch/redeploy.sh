#!/bin/bash
set -euo pipefail

# 用法：./redeploy.sh <手表 UDID>
# 获取 UDID：xcrun devicectl list devices
#
# 这个脚本的存在理由：免费 Apple ID 的签名 7 天过期，过期后 App 打不开，
# 需要重新构建 + 安装。用 ⌘R 也行，但脚本更快，适合每周重复一次。
#
# 注意：手表没有数据接口，安装实际经由配对的 iPhone 中转。
# 首次部署前必须已完成：两台设备开启开发者模式、Xcode 登录 Apple ID、
# 工程 Signing 选择 Personal Team。详见 README。

WATCH_UDID="${1:-}"
SCHEME="AthosWatch"

if [ -z "$WATCH_UDID" ]; then
  echo "用法：./redeploy.sh <手表 UDID>"
  echo ""
  echo "先运行下面这条命令，找到你的手表："
  echo "  xcrun devicectl list devices"
  exit 1
fi

echo "==> 1/4 生成工程"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
else
  echo "    未安装 xcodegen，跳过（请确认 AthosWatch.xcodeproj 已存在）"
fi

echo "==> 2/4 构建（Debug / watchOS）"
xcodebuild \
  -project AthosWatch.xcodeproj \
  -scheme "$SCHEME" \
  -destination "platform=watchOS,id=$WATCH_UDID" \
  -derivedDataPath build \
  -configuration Debug \
  build

echo "==> 3/4 定位产物"
APP_PATH="build/Build/Products/Debug-watchos/Athos.app"
if [ ! -d "$APP_PATH" ]; then
  APP_PATH=$(find build/Build/Products -maxdepth 3 -name "*.app" -print | head -n 1)
fi
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  echo "    未找到 .app 产物，构建可能失败。请回看上面的 xcodebuild 输出。"
  exit 1
fi
echo "    $APP_PATH"

echo "==> 4/4 安装到手表"
if xcrun devicectl device install app --device "$WATCH_UDID" "$APP_PATH"; then
  echo "✅ 已安装。到手表上打开 Athos，首次启动若提示「未受信任的开发者」，"
  echo "   在手表 设置 → 通用 → VPN 与设备管理 中信任你的 Apple ID。"
else
  echo "⚠️  devicectl 安装失败（watchOS 经 iPhone 中转，devicectl 支持不稳定）。"
  echo "   请回到 Xcode，选择手表为运行目标，直接按 ⌘R。"
  exit 1
fi
