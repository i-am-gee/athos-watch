# Athos · 一条命令跑一件事
#
#   make promises  承诺引擎自检（时间解析、改期合并、周复盘；不用模拟器）
#   make phone     构建手机端 + 装进 iPhone 模拟器 + 截图
#   make review    同上，直接打开复盘页
#   make doctor    体检：这台电脑能不能装到手表上，卡在哪一步
#   make gate      手表端算法自检（门控、功耗、时长格式）
#   make sim       手表端：构建 + 装到手表模拟器 + 启动 + 截图
#   make run       手表端：跑「门控 → 切段 → 写盘」全链路（合成信号）
#   make export    把手表/模拟器上的录音导到 ./export
#   make device    手表真机目标编译（验证签名前能否编过）
#   make gen       重新生成 .xcodeproj（改了 project.yml 之后必做）
#   make clean     清掉所有构建产物

SHELL := /bin/bash
BUNDLE_ID := com.kakaqiang.athos
SIM_UDID := $(shell xcrun simctl list devices booted 2>/dev/null | grep -i watch | grep Booted | head -1 | sed -E "s/.*\(([0-9A-F-]{36})\).*/\1/")

.PHONY: help promises phone review doctor gate gen sim run export device clean

help:
	@grep -E "^#   make " Makefile | sed "s/^# \{0,1\}//"

# 承诺引擎：纯 Swift，不依赖 Xcode 工程和模拟器
promises:
	@mkdir -p build-tools
	swiftc -O Shared/Domain/*.swift Tests/promises/main.swift -o build-tools/promisecheck
	@./build-tools/promisecheck

phone: gen
	@bash tools/build-phone.sh

review: gen
	@bash tools/build-phone.sh --review

doctor:
	@bash tools/doctor.sh

gate:
	@mkdir -p build-tools
	swiftc -O Sources/Audio/SonicGate.swift Sources/Audio/PowerLedger.swift Sources/Audio/ClockText.swift Tests/main.swift -o build-tools/gatecheck
	@./build-tools/gatecheck

gen:
	@command -v xcodegen >/dev/null 2>&1 && xcodegen generate || echo "（未装 xcodegen，沿用现有 .xcodeproj）"

sim: gen
	@bash tools/preview.sh

run: gen
	@bash tools/run-synthetic.sh

export:
	@bash tools/pull-recordings.sh ./export

device: gen
	xcodebuild -project AthosWatch.xcodeproj -scheme AthosWatch -destination "generic/platform=watchOS" -derivedDataPath build-dev -configuration Debug CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

clean:
	rm -rf build-sim build-dev build-phone build-tools ./export
