import Foundation

/// 静音门控的核心参数。所有阈值都以「相对噪声底」表达，而不是绝对分贝，
/// 因为手表的麦克风没有标定过的声压级参考，绝对值在不同佩戴方式下漂移极大。
public struct SonicGateConfig: Sendable {

    /// 高于噪声底多少 dB 判定为有人声（开场阈值）
    public var openAboveFloorDB: Float = 12

    /// 低于噪声底多少 dB 判定为静音（收场阈值，必须小于开场值，形成迟滞）
    public var closeBelowFloorDB: Float = 6

    /// 开场需要连续满足该时长的语音帧，防止关门声、咳嗽、桌面敲击误触发
    public var openDwellSeconds: Double = 0.30

    /// 收场需要连续静音该时长，防止句子间的自然停顿把录音切碎
    public var closeDwellSeconds: Double = 2.0

    /// 绝对静音门限。低于此值无论噪声底多低都不开，用于压制极安静的稳态底噪
    public var absoluteGateDBFS: Float = -55

    /// 单段最长时长，超过则切段。
    /// 定这个值的真正理由是「强杀损失上界」：MP4 的 moov 只在文件关闭时才落盘，
    /// App 被系统杀掉 / 没电，正在写的那一段必定残废。5 分钟的段意味着最多丢 5 分钟，
    /// 120 秒把上界压到 2 分钟，同时不至于让文件数暴涨（容器开销约 1.2 KB/段）。
    public var maxSegmentSeconds: Double = 120

    /// 开录前回吐的预录时长，保证「第一个字」不被切掉
    public var preRollSeconds: Double = 1.5

    /// 噪声底向上跟踪的速率（必须很慢，否则人声会把底噪顶上去）
    public var floorRiseRate: Float = 0.002

    /// 噪声底向下跟踪的速率（快），环境变安静时要迅速跟上
    public var floorFallRate: Float = 0.20

    public var minFloorDBFS: Float = -80
    public var maxFloorDBFS: Float = -35
    public var initialFloorDBFS: Float = -60

    /// 语音的过零率区间。宽带瞬态（关门、餐具碰撞）过零率显著偏高，
    /// 借此在不做 FFT 的前提下滤掉大部分非语音冲击。
    public var speechZeroCrossingRange: ClosedRange<Double> = 0.01...0.35

    public init() {}
}

public enum GateState: String, Sendable {
    case idle
    case recording
}

/// 每帧的输出读数，供 UI 与统计使用
public struct GateReading: Sendable {
    public var levelDBFS: Float
    public var noiseFloorDBFS: Float
    public var openThresholdDBFS: Float
    public var closeThresholdDBFS: Float
    public var zeroCrossingRate: Double
    public var state: GateState
    public var recordingSeconds: Double
    public var sessionSeconds: Double
    public var segmentSeconds: Double

    /// 采集占空比：真正写盘的时长 / 会话总时长。这个数字直接决定省电幅度与云端成本。
    public var dutyCycle: Double {
        sessionSeconds > 0 ? recordingSeconds / sessionSeconds : 0
    }
}

public enum GateEvent: Sendable {
    case level(GateReading)
    case opened(GateReading)
    case closed(GateReading)
    case rotated(GateReading)
}

/// 纯逻辑的静音门控状态机。不依赖 AVFoundation，因此可以在 macOS 上直接编译测试。
public final class SonicGate {

    public var config: SonicGateConfig
    public private(set) var state: GateState = .idle
    public private(set) var noiseFloorDBFS: Float

    private var aboveSeconds: Double = 0
    private var belowSeconds: Double = 0
    private var segmentSeconds: Double = 0
    private var sessionSeconds: Double = 0
    private var recordingSeconds: Double = 0

    public init(config: SonicGateConfig = SonicGateConfig()) {
        self.config = config
        self.noiseFloorDBFS = config.initialFloorDBFS
    }

    public func reset() {
        state = .idle
        noiseFloorDBFS = config.initialFloorDBFS
        aboveSeconds = 0
        belowSeconds = 0
        segmentSeconds = 0
        sessionSeconds = 0
        recordingSeconds = 0
    }

    /// 送入一帧采样，返回本帧产生的事件。帧长建议 20ms。
    public func process(frame samples: [Float], sampleRate: Double) -> GateEvent {
        guard !samples.isEmpty, sampleRate > 0 else {
            return .level(makeReading(level: config.minFloorDBFS, zcr: 0))
        }

        let dt = Double(samples.count) / sampleRate
        sessionSeconds += dt

        let level = Self.levelDBFS(of: samples)
        let zcr = Self.zeroCrossingRate(of: samples)

        updateNoiseFloor(with: level)

        let openAt = max(noiseFloorDBFS + config.openAboveFloorDB, config.absoluteGateDBFS)
        let closeAt = max(noiseFloorDBFS + config.closeBelowFloorDB, config.absoluteGateDBFS - 8)

        switch state {
        case .idle:
            let looksLikeSpeech = level >= openAt && config.speechZeroCrossingRange.contains(zcr)
            aboveSeconds = looksLikeSpeech ? aboveSeconds + dt : 0
            if aboveSeconds >= config.openDwellSeconds {
                state = .recording
                segmentSeconds = 0
                belowSeconds = 0
                return .opened(makeReading(level: level, zcr: zcr))
            }

        case .recording:
            segmentSeconds += dt
            recordingSeconds += dt

            if level < closeAt {
                belowSeconds += dt
            } else {
                belowSeconds = 0
            }

            if belowSeconds >= config.closeDwellSeconds {
                state = .idle
                aboveSeconds = 0
                return .closed(makeReading(level: level, zcr: zcr))
            }

            if segmentSeconds >= config.maxSegmentSeconds {
                segmentSeconds = 0
                return .rotated(makeReading(level: level, zcr: zcr))
            }
        }

        return .level(makeReading(level: level, zcr: zcr))
    }

    // MARK: - 内部

    private func makeReading(level: Float, zcr: Double) -> GateReading {
        GateReading(
            levelDBFS: level,
            noiseFloorDBFS: noiseFloorDBFS,
            openThresholdDBFS: max(noiseFloorDBFS + config.openAboveFloorDB, config.absoluteGateDBFS),
            closeThresholdDBFS: max(noiseFloorDBFS + config.closeBelowFloorDB, config.absoluteGateDBFS - 8),
            zeroCrossingRate: zcr,
            state: state,
            recordingSeconds: recordingSeconds,
            sessionSeconds: sessionSeconds,
            segmentSeconds: segmentSeconds
        )
    }

    /// 噪声底只在「静音态」跟踪。录音期间冻结，否则人声会被当成环境噪声吸收，
    /// 导致阈值上漂、越录越难触发。
    private func updateNoiseFloor(with level: Float) {
        guard state == .idle, level > -120 else { return }
        let target = min(max(level, config.minFloorDBFS), config.maxFloorDBFS)

        if target > noiseFloorDBFS {
            // 疑似语音的帧不参与上行跟踪，否则人声会被吸进噪声底，
            // 导致阈值持续抬高、越录越难触发。
            guard target < noiseFloorDBFS + config.openAboveFloorDB * 0.6 else { return }
            noiseFloorDBFS += (target - noiseFloorDBFS) * config.floorRiseRate
        } else {
            noiseFloorDBFS += (target - noiseFloorDBFS) * config.floorFallRate
        }
    }

    // MARK: - 信号度量

    public static func levelDBFS(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -160 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        let rms = (sum / Float(samples.count)).squareRoot()
        return 20 * log10(max(rms, 1e-7))
    }

    public static func zeroCrossingRate(of samples: [Float]) -> Double {
        guard samples.count > 1 else { return 0 }
        var crossings = 0
        for index in 1..<samples.count {
            let previous = samples[index - 1]
            let current = samples[index]
            if (previous >= 0 && current < 0) || (previous < 0 && current >= 0) {
                crossings += 1
            }
        }
        return Double(crossings) / Double(samples.count - 1)
    }
}
