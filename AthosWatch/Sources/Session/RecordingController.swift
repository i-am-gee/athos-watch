import AVFoundation
import Combine
import Foundation

@MainActor
final class RecordingController: ObservableObject {

    // MARK: 运行状态
    @Published private(set) var isRunning = false
    @Published private(set) var gateState: GateState = .idle
    @Published private(set) var levelDBFS: Float = -80
    @Published private(set) var noiseFloorDBFS: Float = -60
    @Published private(set) var openThresholdDBFS: Float = -48
    @Published private(set) var dutyCycle: Double = 0
    @Published private(set) var recordedSeconds: Double = 0
    /// 当前这一段的已录时长，用于主屏那圈进度弧
    @Published private(set) var segmentSeconds: Double = 0
    @Published private(set) var segmentCount: Int = 0
    @Published private(set) var droppedBuffers: Int = 0
    @Published private(set) var estimatedPctPerHour: Double = 0
    @Published var errorMessage: String?

    /// 开场阈值相对噪声底的偏移，表冠可调。调低更灵敏但更费电、更容易录进噪声。
    @Published var sensitivityOffsetDB: Float = 12 { didSet { pushConfig() } }

    /// 收场驻留时长，句子间的停顿短于该值不会切段
    @Published var closeDwellSeconds: Double = 2.0 { didSet { pushConfig() } }

    private let capture = AudioCaptureEngine()
    private var config = SonicGateConfig()
    private var ledger = PowerLedger()
    private var ticker: Timer?
    private var interruptionObserver: NSObjectProtocol?

    init() {
        bind()
        observeInterruptions()
        #if DEBUG
        // 仅用于模拟器自动化验证：以 -autostart 启动时自动开始监听
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-autostart") {
            Task { await start() }
        }
        if args.contains("-synthetic") {
            Task { await startSynthetic() }
        }
        if args.contains("-transcribeTest") {
            Task { await Self.runTranscribeProbe() }
        }
        #endif
    }

    #if DEBUG
    /// 探针：对最新一段录音跑系统语音识别，结果写 Documents/transcribe-probe.log。
    /// 目的只有一个——确认 watchOS 上这条转写路径真的能用，而不是查文档查出来的。
    static func runTranscribeProbe() async {
        let dir = SegmentInfo.directory
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard let latest = files.last else {
            probeLog("没有可转写的文件")
            return
        }

        let name = latest.lastPathComponent
        do {
            let result = try await RemoteTranscriber.transcribe(url: latest)
            probeLog("转写 OK \(name) → \(result.text.prefix(120))")
            for todo in result.todos {
                probeLog("  待办：\(todo.title)  截止=\(todo.due.map { "\($0)" } ?? "无")")
            }
        } catch {
            probeLog("转写 FAIL \(name) → \(error.localizedDescription)")
        }

        // 说明：手表端无法写提醒事项。watchOS SDK 里 EKEventStore 的
        // saveReminder / saveEvent / saveCalendar / commit 全部标了 __WATCHOS_PROHIBITED，
        // 所以「手表自己建待办」在系统层面就不成立，只能由服务端或 iPhone 侧落。
    }

    static func probeLog(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = SegmentInfo.directory
            .deletingLastPathComponent()
            .appendingPathComponent("transcribe-probe.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
        print("[PROBE] \(message)")
    }
    #endif

    #if DEBUG
    /// 模拟器验证通路：合成音频不经过麦克风，因此不弹权限框。
    /// 目的是把「门控 → 切段 → AAC 写盘」这条链路单独跑通，不让权限对话框卡住自动化。
    private func startSynthetic() async {
        AudioCaptureEngine.trace("startSynthetic args=\(ProcessInfo.processInfo.arguments)")
        pushConfig()
        // 注意：这里绝对不能启动引擎。模拟器没有麦克风，tap 会持续产出全零缓冲，
        // 每帧电平 -140 dBFS 判定为静音，把门控的 aboveSeconds 反复清零，
        // 导致合成语音永远累积不满驻留时间。
        ledger.begin()
        recordedSeconds = 0
        segmentCount = 0
        droppedBuffers = 0
        isRunning = true
        startTicker()
        try? await Task.sleep(nanoseconds: 300_000_000)
        capture.runSyntheticPass()
    }
    #endif

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    // MARK: - 对外操作

    func toggle() {
        if isRunning {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard !isRunning else { return }
        guard await requestMicrophonePermission() else {
            errorMessage = "麦克风权限被拒绝，请到「设置 → 隐私 → 麦克风」中允许 Athos。"
            return
        }

        pushConfig()
        do {
            try capture.start()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        ledger.begin()
        recordedSeconds = 0
        segmentCount = 0
        droppedBuffers = 0
        isRunning = true
        startTicker()
    }

    func stop() {
        guard isRunning else { return }
        capture.stop()
        stopTicker()
        isRunning = false
        gateState = .idle
        dutyCycle = 0
    }

    // MARK: - 权限

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    // MARK: - 事件绑定

    private func bind() {
        capture.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .level(let reading), .opened(let reading), .closed(let reading), .rotated(let reading):
                self.apply(reading)
            }
        }

        capture.onSegment = { [weak self] info in
            guard let self else { return }
            self.ledger.noteSegment(duration: info.duration)
            self.recordedSeconds = self.ledger.recordedSeconds
            self.segmentCount = self.ledger.segmentCount
        }

        capture.onError = { [weak self] message in
            self?.errorMessage = message
        }
    }

    private func apply(_ reading: GateReading) {
        gateState = reading.state
        levelDBFS = reading.levelDBFS
        noiseFloorDBFS = reading.noiseFloorDBFS
        openThresholdDBFS = reading.openThresholdDBFS
        dutyCycle = reading.dutyCycle
        droppedBuffers = capture.droppedBuffers
        // 已录时长要含「当前这段还没关闭」的部分，否则录音中会一直显示 0
        recordedSeconds = ledger.recordedSeconds
            + (reading.state == .recording ? reading.segmentSeconds : 0)
        segmentSeconds = reading.state == .recording ? reading.segmentSeconds : 0
    }

    private func pushConfig() {
        config.openAboveFloorDB = sensitivityOffsetDB
        config.closeDwellSeconds = closeDwellSeconds
        capture.updateConfig(config)
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.estimatedPctPerHour = self.ledger.estimatedBatteryRate()
                self.dutyCycle = self.ledger.dutyCycle()
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: - 中断

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleInterruption(notification)
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            // 来电或他人抢麦：录音已经物理中断，如实标记而不是假装还在录
            gateState = .idle
            errorMessage = "录音被来电或其他应用中断，已保留中断前的内容。"
        case .ended:
            guard isRunning else { return }
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                AVAudioSession.InterruptionOptions(rawValue: $0)
            }
            if options?.contains(.shouldResume) ?? true {
                capture.resumeAfterInterruption()
                errorMessage = nil
            }
        @unknown default:
            break
        }
    }
}
