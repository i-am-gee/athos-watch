import AVFoundation
import Foundation

/// 采集引擎：常开会话 → 逐帧过门控 → 仅在判定有人声时写盘。
///
/// 关键设计：
/// 1. 音频线程只做「转换 + 分帧 + 判定 + 入队」，不做磁盘 I/O；
/// 2. 所有写盘操作在独立串行队列执行，队列积压时丢弃最旧的缓冲并计数；
/// 3. 维护 1.5s 预录环形缓冲，开门瞬间回吐，保证第一个字不被切掉。
final class AudioCaptureEngine {

    enum CaptureError: LocalizedError {
        case formatUnavailable
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .formatUnavailable:
                return "无法建立 16kHz 单声道目标格式"
            case .engineStartFailed(let reason):
                return "音频引擎启动失败：\(reason)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private let gate: SonicGate
    private let writerQueue = DispatchQueue(label: "com.athos.writer", qos: .utility)
    private let directory: URL

    private var converter: AVAudioConverter?
    private var writer: SegmentWriter?
    private var preRoll: [AVAudioPCMBuffer] = []
    private var preRollFrames: AVAudioFramePosition = 0
    private var preRollLimitFrames: AVAudioFramePosition = 0
    private var pendingWrites = 0
    private var frameCounter = 0
    private(set) var droppedBuffers = 0

    /// 回调在主线程
    var onEvent: ((GateEvent) -> Void)?
    var onSegment: ((SegmentInfo) -> Void)?
    var onError: ((String) -> Void)?

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )

    init(gate: SonicGate = SonicGate()) {
        self.gate = gate
        self.directory = SegmentInfo.directory
        // 预录窗口在这里就确定，而不是等 start()：合成信号通路不启动引擎，
        // 若留到 start() 里设置，预录缓冲会永远被裁成 0。
        self.preRollLimitFrames = AVAudioFramePosition(
            1.5 * (Self.targetFormat?.sampleRate ?? 16_000)
        )
    }

    func updateConfig(_ config: SonicGateConfig) {
        gate.config = config
    }

    // MARK: - 生命周期

    func start() throws {
        guard let targetFormat = Self.targetFormat else {
            throw CaptureError.formatUnavailable
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.formatUnavailable
        }
        converter = conv
        preRollLimitFrames = AVAudioFramePosition(1.5 * targetFormat.sampleRate)

        input.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer, targetFormat: targetFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error.localizedDescription)
        }
    }

    func stop() {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        flushWriter()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        gate.reset()
        preRoll.removeAll()
        preRollFrames = 0
    }

    /// 被来电等中断抢占后恢复。不重建 tap，只重启引擎。
    func resumeAfterInterruption() {
        guard !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
        gate.reset()
        preRoll.removeAll()
        preRollFrames = 0
    }

    // MARK: - 音频线程

    private func handle(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converted = convert(buffer, to: targetFormat) else { return }
        process(converted: converted)
    }

    /// 把已转换好的 16k 单声道缓冲送入门控与写盘流程。
    /// 抽出来是为了让合成信号（模拟器验证）走完全相同的链路。
    func process(converted: AVAudioPCMBuffer) {

        // 逐 20ms 帧送入门控
        let framesPerStep = Int(converted.format.sampleRate * 0.02)
        guard let channel = converted.floatChannelData?[0] else { return }
        let total = Int(converted.frameLength)

        var offset = 0
        while offset < total {
            let count = min(framesPerStep, total - offset)
            let frame = Array(UnsafeBufferPointer(start: channel + offset, count: count))
            let event = gate.process(frame: frame, sampleRate: converted.format.sampleRate)

            switch event {
            case .opened:
                Self.trace("gate opened")
                flushPreRollThenOpenSegment(format: converted.format)
                enqueueWrite(converted)
            case .closed:
                Self.trace("gate closed")
                closeSegment()
            case .rotated:
                Self.trace("gate rotated")
                closeSegment()
                openSegment(format: converted.format)
                enqueueWrite(converted)
            case .level:
                // 录音态下每一帧都必须落盘。漏掉这一条会让分段只剩开门那一帧，
                // 表面上「有文件」，实际内容只有 20ms。
                if gate.state == .recording {
                    enqueueWrite(converted)
                }
            }

            frameCounter += 1
            if frameCounter % 5 == 0 {
                let captured = event
                DispatchQueue.main.async { [weak self] in self?.onEvent?(captured) }
            }
            if frameCounter % 50 == 0 {
                let reading = event.reading
                Self.trace(String(format: "lvl=%.1f floor=%.1f open=%.1f zcr=%.3f state=%@",
                                  reading.levelDBFS, reading.noiseFloorDBFS, reading.openThresholdDBFS,
                                  reading.zeroCrossingRate, reading.state.rawValue))
            }
            offset += count
        }

        // 未开门时维护预录环形缓冲
        if gate.state == .idle {
            appendPreRoll(converted)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil { return nil }
        return output.frameLength > 0 ? output : nil
    }

    // MARK: - 预录

    private func appendPreRoll(_ buffer: AVAudioPCMBuffer) {
        guard let copy = copyBuffer(buffer) else { return }
        preRoll.append(copy)
        preRollFrames += AVAudioFramePosition(copy.frameLength)
        while preRollFrames > preRollLimitFrames, let first = preRoll.first {
            preRollFrames -= AVAudioFramePosition(first.frameLength)
            preRoll.removeFirst()
        }
    }

    private func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        for channel in 0..<channels {
            guard let src = buffer.floatChannelData?[channel],
                  let dst = copy.floatChannelData?[channel] else { continue }
            dst.update(from: src, count: Int(buffer.frameLength))
        }
        return copy
    }

    private func flushPreRollThenOpenSegment(format: AVAudioFormat) {
        let buffered = preRoll
        preRoll.removeAll()
        preRollFrames = 0

        writerQueue.async { [weak self] in
            guard let self else { return }
            self.openSegmentLocked(format: format)
            for buffer in buffered {
                self.writer?.write(buffer)
            }
        }
    }

    // MARK: - 写盘（仅在 writerQueue 上调用）

    private func openSegment(format: AVAudioFormat) {
        writerQueue.async { [weak self] in
            self?.openSegmentLocked(format: format)
        }
    }

    private func openSegmentLocked(format: AVAudioFormat) {
        writer?.close()
        do {
            writer = try SegmentWriter(directory: directory, format: format)
        } catch {
            writer = nil
            DispatchQueue.main.async { [weak self] in
                self?.onError?("无法创建录音文件：\(error.localizedDescription)")
            }
        }
    }

    private func enqueueWrite(_ buffer: AVAudioPCMBuffer) {
        // 队列积压过多说明磁盘跟不上，丢弃本缓冲而不是无限堆积
        guard pendingWrites < 40, let copy = copyBuffer(buffer) else {
            droppedBuffers += 1
            return
        }
        pendingWrites += 1
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.writer?.write(copy)
            self.pendingWrites -= 1
        }
    }

    private func closeSegment() {
        writerQueue.async { [weak self] in
            guard let self, let finished = self.writer else { return }
            let info = finished.close()
            self.writer = nil
            guard info.duration >= 0.5 else {
                try? FileManager.default.removeItem(at: info.url)
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.onSegment?(info)
            }
        }
    }

    private func flushWriter() {
        writerQueue.sync {
            _ = self.writer?.close()
            self.writer = nil
        }
    }
    // MARK: - 合成信号（仅模拟器验证用）

    /// 诊断输出：写到 Documents/athos-trace.log，便于模拟器自动化验证后回读。
    /// 仅当带 -synthetic 启动时生效，真机日常运行不产生任何日志文件。
    static func trace(_ message: String) {
        guard ProcessInfo.processInfo.arguments.contains("-synthetic") else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        guard let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = base.appendingPathComponent("athos-trace.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
        print("[ATHOS] \(message)")
    }

    /// 以最快速度灌入一段已知结构的音频，用于验证门控 + 写盘链路。
    /// 结构：2s 静音 → 3s 语音 → 4s 静音 → 3s 语音
    func runSyntheticPass(totalSeconds: Double = 12, speed: Double = 1.0) {
        guard let format = Self.targetFormat else { return }
        Self.trace("synthetic pass begin, total=\(totalSeconds)s speed=\(speed)")
        let sampleRate = format.sampleRate
        let frameLength = Int(sampleRate * 0.02)
        let frameInterval = 0.02 / max(speed, 0.1)

        // 放到后台队列并按实时节奏推进：瞬间灌入会把写盘队列撑爆，
        // 触发丢弃策略，测不出真实行为。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var time: Double = 0
            while time < totalSeconds {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(frameLength)) else { break }
                buffer.frameLength = AVAudioFrameCount(frameLength)
                let inSpeech = (time >= 2 && time < 5) || (time >= 9 && time < 12)
                if let channel = buffer.floatChannelData?[0] {
                    for index in 0..<frameLength {
                        let t = time + Double(index) / sampleRate
                        if inSpeech {
                            channel[index] = Float(0.05 * sin(2 * Double.pi * 200 * t)
                                                 + 0.03 * sin(2 * Double.pi * 700 * t))
                        } else {
                            channel[index] = Float.random(in: -0.0004...0.0004)
                        }
                    }
                }
                self.process(converted: buffer)
                time += 0.02
                usleep(useconds_t(frameInterval * 1_000_000))
            }
            if self.gate.state == .recording {
                self.closeSegment()
            }
            Self.trace("synthetic pass end, dropped=\(self.droppedBuffers)")
            let done = self.onSyntheticFinished
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                done?()
            }
        }
    }

    /// 合成信号跑完后回调（主线程），供界面提示
    var onSyntheticFinished: (() -> Void)?

}

extension GateEvent {
    var reading: GateReading {
        switch self {
        case .level(let r), .opened(let r), .closed(let r), .rotated(let r):
            return r
        }
    }
}
