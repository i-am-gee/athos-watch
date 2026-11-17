#!/bin/bash
# 手表 → 手机 蓝牙链路端到端验证。
#
# 做四件事，每一步都留下可检查的痕迹：
#   1. 用 macOS 内置语音合成造几段真实的中文语音（不是假数据）
#   2. 塞进手表模拟器的 Documents/Segments，假装是录下来的
#   3. 启动两端，让它们自己握手、传音频、转写、回传、生成承诺
#   4. 把两端的 link.log 拼成一条时间线
#
# 用法：tools/link-test.sh [--no-build] [--keep]
set -eu

cd "$(dirname "$0")/.."

SCHEME=AthosPhone
PHONE_ID=${PHONE_ID:-47EC022C-2E1A-42DA-8362-08B37A8B451A}
WATCH_ID=${WATCH_ID:-6D308C7E-CDFE-4244-B820-BD0059E4FC9B}
PHONE_BUNDLE=com.kakaqiang.athos.phone
WATCH_BUNDLE=com.kakaqiang.athos.phone.watchkitapp

BUILD=1
KEEP=0
FAKE=0
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    --keep) KEEP=1 ;;
    # 没有可用语音识别服务时（模拟器会这样），用已知台词验证后半段：
    # 回传 → 手表判断 → 承诺同步回手机。engine 会标成 injected。
    --fake) FAKE=1 ;;
  esac
done

if [ "$BUILD" = "1" ]; then
  echo "▸ 构建（Xcode 27 的宏插件在增量编译下必挂，所以每次都全量）"
  rm -rf build-phone
  xcodegen generate >/dev/null
  xcodebuild -project AthosWatch.xcodeproj -scheme "$SCHEME" -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath build-phone build \
    2>&1 | grep -E "error:|BUILD " || true
fi

APP=build-phone/Build/Products/Debug-iphonesimulator/Athos.app

echo "▸ 启动模拟器"
xcrun simctl boot "$PHONE_ID" 2>/dev/null || true
xcrun simctl boot "$WATCH_ID" 2>/dev/null || true
xcrun simctl bootstatus "$PHONE_ID" -b >/dev/null 2>&1 || true

echo "▸ 重装"
# 刻意**不** uninstall：watchOS 模拟器上卸掉再装，新包在 LaunchServices 里
# 注册不上（install 返回 0，launch 报 NotFound），而且旧包会残留占位。
# 覆盖安装能保留容器，只要清掉「已发送」记录就能重跑。
xcrun simctl terminate "$WATCH_ID" "$WATCH_BUNDLE" 2>/dev/null || true
xcrun simctl install "$PHONE_ID" "$APP"
xcrun simctl install "$WATCH_ID" "$APP/Watch/Athos.app"
# 装完立刻 launch 会命中 LaunchServices 还没登记完的竞争条件（返回 code 4 NotFound）
sleep 6

echo "▸ 合成中文语音"
VOICE_DIR=/tmp/athos-link-voice
rm -rf "$VOICE_DIR" && mkdir -p "$VOICE_DIR"
# 六句覆盖四条判断规则：承诺、改期、征询、没定时间的活 + 后来改期
LINES=(
  "我周五前把报价发给小李"
  "改到下周一吧"
  "要不周五发"
  "你有空帮我看一下吗"
  "我把合同整理一下"
  "合同整理改到周四吧"
)
INDEX=0
for line in "${LINES[@]}"; do
  INDEX=$((INDEX + 1))
  say -v Tingting -o "$VOICE_DIR/$INDEX.aiff" "$line"
  afconvert -f m4af -d aac -b 32000 "$VOICE_DIR/$INDEX.aiff" "$VOICE_DIR/$INDEX.m4a"
done
echo "  $INDEX 段"

echo "▸ 预热（数据容器要等 App 真正跑过一次才存在）"
xcrun simctl launch "$WATCH_ID" "$WATCH_BUNDLE" >/dev/null 2>&1 || {
  echo "  第一次没起来，等 10 秒重试"
  sleep 10
  xcrun simctl launch "$WATCH_ID" "$WATCH_BUNDLE" >/dev/null
}
sleep 6
xcrun simctl terminate "$WATCH_ID" "$WATCH_BUNDLE" 2>/dev/null || true

# 清掉「已发送」记录：否则补发逻辑会认为这些段早就送过了，一段都不会发
WATCH_DATA=$(xcrun simctl get_app_container "$WATCH_ID" "$WATCH_BUNDLE" data)
rm -f "$WATCH_DATA/Library/Preferences/$WATCH_BUNDLE.plist"
xcrun simctl spawn "$WATCH_ID" killall -9 cfprefsd >/dev/null 2>&1 || true

# 两端的数据都要清干净，否则每次跑都在上一轮的结果上累加：
# 手表的账本会一直加，手机的 Inbox 会把旧段也当成新台词注入。
rm -rf "$WATCH_DATA/Documents/Segments" "$WATCH_DATA/Documents/ledger.json" \
       "$WATCH_DATA/Documents/link.log"
mkdir -p "$WATCH_DATA/Documents/Segments"
PHONE_DATA=$(xcrun simctl get_app_container "$PHONE_ID" "$PHONE_BUNDLE" data 2>/dev/null || true)
if [ -n "${PHONE_DATA:-}" ]; then
  rm -rf "$PHONE_DATA/Documents/Inbox" "$PHONE_DATA/Documents/link.log"
fi

echo "▸ 放进手表沙盒"
WATCH_DATA=$(xcrun simctl get_app_container "$WATCH_ID" "$WATCH_BUNDLE" data)
SEGMENTS="$WATCH_DATA/Documents/Segments"
mkdir -p "$SEGMENTS"
BASE=$(( $(date +%s) - 900 ))
INDEX=0
for line in "${LINES[@]}"; do
  INDEX=$((INDEX + 1))
  TS=$((BASE + (INDEX - 1) * 120))
  NAME="seg-$(date -r "$TS" +%Y%m%d-%H%M%S)-000.m4a"
  cp "$VOICE_DIR/$INDEX.m4a" "$SEGMENTS/$NAME"
  DURATION=$(afinfo "$SEGMENTS/$NAME" | awk '/estimated duration/ {print $3}')
  BYTES=$(stat -f%z "$SEGMENTS/$NAME")
  printf '{"fileName":"%s","startedAt":%d000,"duration":%s,"bytes":%d}' \
    "$NAME" "$TS" "$DURATION" "$BYTES" > "$SEGMENTS/${NAME%.m4a}.json"
  printf '  %-32s %5.2fs  %s\n' "$NAME" "$DURATION" "$line"
done

echo "▸ 授权"
xcrun simctl privacy "$PHONE_ID" grant all "$PHONE_BUNDLE" 2>/dev/null || true
xcrun simctl privacy "$WATCH_ID" grant all "$WATCH_BUNDLE" 2>/dev/null || true

# `simctl privacy` 没有 speech-recognition 这一项，`grant all` 也覆盖不到它：
# 直接跑起来会卡在系统授权框上（模拟器里没人点它），几秒后自动落成 denied。
# 所以只能直接写模拟器自己的 TCC 库，再重启 tccd 让缓存失效。
grant_speech() {
  local DEV=$1 BUNDLE=$2
  local DB="$HOME/Library/Developer/CoreSimulator/Devices/$DEV/data/Library/TCC/TCC.db"
  [ -f "$DB" ] || return 0
  sqlite3 "$DB" "delete from access where service='kTCCServiceSpeechRecognition' and client='$BUNDLE';" 2>/dev/null || true
  sqlite3 "$DB" "insert into access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier, flags, last_modified, pid, pid_version, boot_uuid, last_reminded) values ('kTCCServiceSpeechRecognition','$BUNDLE',0,2,2,1,NULL,NULL,0,'UNUSED',0,strftime('%s','now'),0,0,'UNUSED',strftime('%s','now'));" 2>/dev/null || true
  xcrun simctl spawn "$DEV" launchctl kickstart -k system/com.apple.tccd >/dev/null 2>&1 || true
  echo "  speech → $BUNDLE"
}
grant_speech "$PHONE_ID" "$PHONE_BUNDLE"

echo "▸ 启动"
xcrun simctl terminate "$PHONE_ID" "$PHONE_BUNDLE" 2>/dev/null || true
xcrun simctl terminate "$WATCH_ID" "$WATCH_BUNDLE" 2>/dev/null || true
if [ "$FAKE" = "1" ]; then
  # 用 UserDefaults 而不是启动参数：`simctl launch` 后面跟的参数
  # 在 App 被反复启停时经常传不进去（十次里成两三次），
  # `defaults write` 是唯一每次都生效的开关。
  xcrun simctl spawn "$PHONE_ID" defaults write "$PHONE_BUNDLE" athos.fakeTranscript -bool YES
else
  # 上一次 --fake 留下的开关必须清掉，否则这次会「看起来跑通了但其实没识别」
  xcrun simctl spawn "$PHONE_ID" defaults delete "$PHONE_BUNDLE" athos.fakeTranscript 2>/dev/null || true
fi
xcrun simctl launch "$PHONE_ID" "$PHONE_BUNDLE" >/dev/null
sleep 3
xcrun simctl launch "$WATCH_ID" "$WATCH_BUNDLE" -linkProbe >/dev/null

echo "▸ 等待握手、传输、转写（最多 90 秒）"
if [ "$FAKE" = "1" ]; then
  # 注入模式没有识别耗时，等固定时长即可
  sleep 35
else
  for _ in $(seq 1 30); do
    sleep 3
    PHONE_DATA=$(xcrun simctl get_app_container "$PHONE_ID" "$PHONE_BUNDLE" data)
    if grep -q "转写完成" "$PHONE_DATA/Documents/link.log" 2>/dev/null; then break; fi
  done
fi

PHONE_DATA=$(xcrun simctl get_app_container "$PHONE_ID" "$PHONE_BUNDLE" data)

echo
echo "════════ 手表 link.log ════════"
cat "$WATCH_DATA/Documents/link.log" 2>/dev/null || echo "（空）"
echo
echo "════════ 手机 link.log ════════"
cat "$PHONE_DATA/Documents/link.log" 2>/dev/null || echo "（空）"
echo
echo "════════ 手表算出的承诺 ════════"
cat "$WATCH_DATA/Documents/ledger.json" 2>/dev/null | head -c 2000 || echo "（空）"
echo

if [ "$KEEP" = "0" ]; then
  rm -rf "$VOICE_DIR"
fi
