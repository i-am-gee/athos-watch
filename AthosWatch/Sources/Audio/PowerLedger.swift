import Foundation

/// 功耗模型。所有系数都是「每小时消耗百分之几电量」，
/// 需要用真机实测校准后写回，不要直接用于对外宣传。
public struct PowerModel: Sendable {

    /// 手表日常待机 + 通知 + 心率的基线消耗
    public var baselinePctPerHour: Double = 2.4

    /// 音频会话常开（麦克风 + ADC + 引擎跑 VAD）的固定开销。
    /// 这一项是「无论如何都省不掉」的底价，也是本方案最容易被高估的地方。
    public var enginePctPerHour: Double = 1.1

    /// 满占空比时，编码 + 写盘 + 转写预处理带来的增量开销
    public var writeDeltaPctPerHour: Double = 1.6

    public init() {}

    public func percentPerHour(dutyCycle: Double) -> Double {
        let duty = min(max(dutyCycle, 0), 1)
        return baselinePctPerHour + enginePctPerHour + writeDeltaPctPerHour * duty
    }

    public func remainingHours(dutyCycle: Double, batteryPercent: Double = 100) -> Double {
        let rate = percentPerHour(dutyCycle: dutyCycle)
        guard rate > 0 else { return .infinity }
        return batteryPercent / rate
    }

    /// 与「连续录音」相比省下的比例，用于向用户解释 VAD 的价值
    public func savingVersusContinuous(dutyCycle: Double) -> Double {
        let continuous = percentPerHour(dutyCycle: 1)
        let actual = percentPerHour(dutyCycle: dutyCycle)
        guard continuous > 0 else { return 0 }
        return max(0, 1 - actual / continuous)
    }
}

/// 会话账本：记录本次会话的时长、写盘量、占空比，并给出功耗与存储预估。
public struct PowerLedger: Sendable {

    public var model: PowerModel
    public var startedAt: Date?
    public private(set) var recordedSeconds: Double = 0
    public private(set) var segmentCount: Int = 0

    /// 24 kbps 单声道约合每小时 10.5 MB
    public var megabytesPerHour: Double = 10.5

    public init(model: PowerModel = PowerModel()) {
        self.model = model
    }

    public mutating func begin(at date: Date = Date()) {
        startedAt = date
        recordedSeconds = 0
        segmentCount = 0
    }

    public mutating func noteSegment(duration seconds: Double) {
        recordedSeconds += max(0, seconds)
        segmentCount += 1
    }

    public func sessionSeconds(now: Date = Date()) -> Double {
        guard let startedAt else { return 0 }
        return max(0, now.timeIntervalSince(startedAt))
    }

    public func dutyCycle(now: Date = Date()) -> Double {
        let total = sessionSeconds(now: now)
        guard total > 0 else { return 0 }
        return min(1, recordedSeconds / total)
    }

    public func estimatedMegabytes(now: Date = Date()) -> Double {
        recordedSeconds / 3600 * megabytesPerHour
    }

    public func estimatedBatteryRate(now: Date = Date()) -> Double {
        model.percentPerHour(dutyCycle: dutyCycle(now: now))
    }
}
