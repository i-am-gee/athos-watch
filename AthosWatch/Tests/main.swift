import Foundation

// 合成信号验证门控时序：
//   0–2s  宽带静音（白噪声，过零率高，应被 ZCR 过滤）
//   2–5s  类语音（200Hz + 700Hz 正弦叠加，低过零率）
//   5–9s  静音
//   9–12s 类语音
// 预期：约 2.3s 开启、约 7.0s 收场、约 9.3s 再次开启，占空比 ≈ 50%

let sampleRate: Double = 16_000
let frameDuration: Double = 0.02
let frameCount = Int(sampleRate * frameDuration)

var seed: UInt64 = 0x9E3779B97F4A7C15
func noise() -> Float {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    let bits = UInt32(truncatingIfNeeded: seed >> 32)
    return Float(bits) / Float(UInt32.max) - 0.5
}

func makeFrame(at time: Double) -> [Float] {
    var frame = [Float](repeating: 0, count: frameCount)
    let inSpeech = (time >= 2 && time < 5) || (time >= 9 && time < 12)
    for index in 0..<frameCount {
        let t = time + Double(index) / sampleRate
        if inSpeech {
            let value = 0.05 * sin(2 * Double.pi * 200 * t) + 0.03 * sin(2 * Double.pi * 700 * t)
            frame[index] = Float(value) + 0.0005 * noise()
        } else {
            frame[index] = 0.0008 * noise()
        }
    }
    return frame
}

// 参数可以被环境变量覆盖，方便不改代码试阈值：
//   GATE_OPEN=8 GATE_DWELL=1.0 make gate
var config = SonicGateConfig()
let env = ProcessInfo.processInfo.environment
if let raw = env["GATE_OPEN"], let value = Float(raw) { config.openAboveFloorDB = value }
if let raw = env["GATE_CLOSE"], let value = Float(raw) { config.closeBelowFloorDB = value }
if let raw = env["GATE_DWELL"], let value = Double(raw) { config.openDwellSeconds = value }
if let raw = env["GATE_TAIL"], let value = Double(raw) { config.closeDwellSeconds = value }

let gate = SonicGate(config: config)
print(String(format: "阈值配置：开场 +%.0f dB / 收场 -%.0f dB / 开场驻留 %.2fs / 收场驻留 %.1fs",
             config.openAboveFloorDB, config.closeBelowFloorDB,
             config.openDwellSeconds, config.closeDwellSeconds))
print(String(format: "初始噪声底 %.1f dBFS", gate.noiseFloorDBFS))
print("---------------------------------------------")

var time: Double = 0
var lastReading = GateReading(levelDBFS: 0, noiseFloorDBFS: 0, openThresholdDBFS: 0,
                              closeThresholdDBFS: 0, zeroCrossingRate: 0, state: .idle,
                              recordingSeconds: 0, sessionSeconds: 0, segmentSeconds: 0)
let totalSeconds: Double = 12

while time < totalSeconds {
    let event = gate.process(frame: makeFrame(at: time), sampleRate: sampleRate)
    switch event {
    case .opened(let reading):
        lastReading = reading
        print(String(format: "  %.2fs  OPEN   电平 %.1f / 底 %.1f / 门限 %.1f",
                     time, reading.levelDBFS, reading.noiseFloorDBFS, reading.openThresholdDBFS))
    case .closed(let reading):
        lastReading = reading
        print(String(format: "  %.2fs  CLOSE  电平 %.1f / 底 %.1f / 门限 %.1f",
                     time, reading.levelDBFS, reading.noiseFloorDBFS, reading.closeThresholdDBFS))
    case .rotated(let reading):
        lastReading = reading
        print(String(format: "  %.2fs  ROTATE 段长 %.1fs", time, reading.segmentSeconds))
    case .level(let reading):
        lastReading = reading
        if abs(time.rounded() - time) < 0.001 && Int(time) % 2 == 0 {
            print(String(format: "  %.2fs  %-9@ 电平 %.1f / 底 %.1f", time,
                         reading.state.rawValue as NSString, reading.levelDBFS, reading.noiseFloorDBFS))
        }
    }
    time += frameDuration
}

print("---------------------------------------------")
print(String(format: "会话总时长 %.2fs，写盘 %.2fs，占空比 %.1f%%",
             lastReading.sessionSeconds, lastReading.recordingSeconds, lastReading.dutyCycle * 100))

let model = PowerModel()
for duty in [1.0, 0.5, 0.25, 0.15, 0.10] {
    let rate = model.percentPerHour(dutyCycle: duty)
    let hours = model.remainingHours(dutyCycle: duty)
    let saving = model.savingVersusContinuous(dutyCycle: duty) * 100
    print(String(format: "占空比 %3.0f%%  →  %.2f%%/h，满电可用 %.1f 小时，比连续录音省 %.0f%%",
                 duty * 100, rate, hours, saving))
}

// MARK: - 主屏时长格式

print("---------------------------------------------")
print("主屏时长格式（ClockText.short）：")

let clockCases: [(Double, String)] = [
    (0, "00:00"),
    (0.4, "00:00"),
    (9.9, "00:09"),
    (59.9, "00:59"),
    (60, "01:00"),
    (605, "10:05"),
    (3599, "59:59"),
    (3600, "1:00:00"),
    (7384.7, "2:03:04"),
    (-5, "00:00"),
    (-0.001, "00:00"),
    (.nan, "00:00"),
    (.infinity, "00:00"),
]

var clockFailures = 0
for (input, expected) in clockCases {
    let got = ClockText.short(input)
    let ok = got == expected
    if !ok { clockFailures += 1 }
    let inputText = input.isNaN ? "nan" : (input.isInfinite ? "inf" : "\(input)")
    print("  \(ok ? "PASS" : "FAIL")  \(inputText) → \(got)\(ok ? "" : "，期望 \(expected)")")
}

if clockFailures > 0 {
    print("时长格式有 \(clockFailures) 项不符")
    exit(1)
}
print("时长格式全部通过")
