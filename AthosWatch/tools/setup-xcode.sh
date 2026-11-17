#!/bin/bash
set -uo pipefail

# Xcode 安装后的一次性配置。
# 必须在你自己的终端里运行（需要输入管理员密码，脚本无法代填）：
#   bash tools/setup-xcode.sh

XCODE_PATH="/Applications/Xcode.app"

echo "==> 1/6 检查 Xcode 是否存在"
if [ ! -d "$XCODE_PATH" ]; then
  echo "❌ 未找到 $XCODE_PATH"
  echo "   请先在 App Store 中安装 Xcode（搜索 Xcode，点「获取」）。"
  echo "   若已下载但尚未启动安装，打开 Launchpad 等待其完成。"
  exit 1
fi
echo "    ✅ 已找到"

echo "==> 2/6 将命令行工具指向 Xcode（需要管理员密码）"
sudo xcode-select -s "$XCODE_PATH/Contents/Developer" || {
  echo "❌ 切换失败。若提示 sudo 不可用，请手动执行："
  echo "   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
}

echo "==> 3/6 接受许可协议并完成首次启动"
sudo xcodebuild -license accept 2>/dev/null || echo "    （许可协议此前已接受）"
sudo xcodebuild -runFirstLaunch 2>/dev/null || echo "    （首次启动组件此前已安装）"

echo "==> 4/6 验证版本与 watchOS SDK"
xcodebuild -version || { echo "❌ xcodebuild 仍不可用"; exit 1; }
WATCH_SDK=$(xcrun --sdk watchos --show-sdk-version 2>/dev/null)
if [ -z "$WATCH_SDK" ]; then
  echo "❌ 未找到 watchOS SDK。请在 Xcode → Settings → Components 中下载 watchOS 平台支持。"
else
  echo "    watchOS SDK: $WATCH_SDK"
fi

echo "==> 5/6 生成工程"
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
else
  echo "⚠️  未安装 xcodegen：brew install xcodegen"
fi

echo "==> 6/6 完成"
echo ""
echo "接下来："
echo "  1. open AthosWatch.xcodeproj"
echo "  2. Xcode → Settings → Accounts → 添加 Apple ID"
echo "  3. Target AthosWatch → Signing & Capabilities → Team 选 Personal Team"
echo "  4. Bundle Identifier 改成唯一值，如 com.你的名字.athos"
echo "  5. iPhone 与 Apple Watch 都开启开发者模式"
echo "  6. 手表放充电器、解锁，scheme 选 AthosWatch，目标选你的手表，按 ⌘R"
