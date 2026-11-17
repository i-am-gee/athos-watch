#!/bin/bash
set -uo pipefail

# 把 Team ID 与 Bundle Identifier 写进 project.yml，然后重新生成工程。
# 这样下次跑 xcodegen 也不会把签名设置冲掉。
#
# 用法：
#   bash tools/set-team.sh                 # 自动从钥匙串读取 Team ID
#   bash tools/set-team.sh ABCDE12345      # 手动指定 Team ID
#   bash tools/set-team.sh ABCDE12345 com.gee.athos

cd "$(dirname "$0")/.." || exit 1

TEAM="${1:-}"
BUNDLE="${2:-}"

# 1. 解析 Team ID
if [ -z "$TEAM" ]; then
  TEAM=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -i "apple development" \
    | head -n 1 \
    | grep -oE '\([A-Z0-9]{10}\)' \
    | tr -d '()')
fi

if [ -z "$TEAM" ]; then
  cat <<'EOF'
❌ 没找到可用的 Apple Development 证书。

这说明 Xcode 里还没登录 Apple ID，或证书尚未生成。请先：

  1. 打开 Xcode
  2. 菜单栏 Xcode → Settings…（⌘,）
  3. 选 Accounts 标签页
  4. 左下角 + → Apple ID → 登录（需要双重认证）
  5. 登录后选中账号，点右侧 Manage Certificates… → 左下 + → Apple Development

完成后重新运行本脚本。若仍失败，可手动传入 Team ID：
  bash tools/set-team.sh 你的10位TeamID com.你的名字.athos
EOF
  exit 1
fi

echo "✅ Team ID: $TEAM"

# 2. Bundle Identifier
CURRENT=$(grep -E '^\s+PRODUCT_BUNDLE_IDENTIFIER:' project.yml | awk '{print $2}')
if [ -z "$BUNDLE" ]; then
  if [ "$CURRENT" = "com.athos.watch" ]; then
    echo ""
    echo "⚠️  Bundle Identifier 仍是默认值 com.athos.watch，很可能与别人的 App ID 冲突。"
    echo "    建议重跑并指定唯一值，例如："
    echo "    bash tools/set-team.sh $TEAM com.你的名字.athos"
    echo ""
    echo "    仍然继续使用默认值？按回车继续，或 Ctrl-C 中止。"
    read -r _
  fi
  BUNDLE="$CURRENT"
fi

echo "✅ Bundle ID: $BUNDLE"

# 3. 写回 project.yml
/usr/bin/sed -i '' -E "s/DEVELOPMENT_TEAM: \".*\"/DEVELOPMENT_TEAM: \"$TEAM\"/" project.yml
/usr/bin/sed -i '' -E "s/PRODUCT_BUNDLE_IDENTIFIER: .*/PRODUCT_BUNDLE_IDENTIFIER: $BUNDLE/" project.yml

echo "✅ 已写入 project.yml"

# 4. 重新生成工程
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate >/dev/null && echo "✅ 已重新生成 AthosWatch.xcodeproj"
else
  echo "⚠️  未安装 xcodegen，请手动执行 xcodegen generate"
fi

cat <<EOF

下一步：
  open AthosWatch.xcodeproj
  → 顶部 scheme 选 AthosWatch，运行目标选手表
  → ⌘R
EOF
