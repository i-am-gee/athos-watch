import AVFoundation
import Foundation
import WatchConnectivity

/// 手机侧的蓝牙通道。
///
/// 它只做两件事，且刻意不做第三件事：
///   1. 收下手表发来的音频段，落到 `Documents/Inbox/`；
///   2. 调系统语音识别转成文字，按句回传手表。
///
/// **不做的**：判断谁答应了什么。那一步在手表上算——
/// 手机只是个「识字的人」，读完把字念回给手表，结论由手表下。
@MainActor
final class PhoneLink: NSObject, ObservableObject {

    static let shared = PhoneLink()

    @Published private(set) var isActivated = false
    @Published private(set) var receivedCount = 0
    @Published private(set) var lastNote: String?
    @Published private(set) var log: [String] = []

    /// 手表推来的账本快照。手机首页就是它的镜像。
    var onSnapshot: ((LedgerSnapshot) -> Void)?

    private var pipeline: Task<Void, Never> = Task {}
    /// 已经转写过的段。重复收到同一段（重连时很常见）不必再识别一遍——
    /// 一次识别要几秒 CPU，而且结果和上次一模一样。
    private var transcribed: Set<String> = []

    private override init() { super.init() }

    var inbox: URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func activate() {
        guard WCSession.isSupported() else {
            LinkLog.write("手机：WCSession 不支持")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        LinkLog.write("手机：activate() 已调用，state=\(session.activationState.rawValue)")

        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-retranscribe") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.replayInbox()
            }
        }
        if args.contains("-fakeTranscript") {
            Task { @MainActor in
                // 等音频真正落地再注入：传输和注入是两条独立路径，
                // 固定等 3 秒经常在文件还没到时就把空列表读走了。
                for _ in 0..<15 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    let files = (try? FileManager.default.contentsOfDirectory(
                        at: self.inbox, includingPropertiesForKeys: nil
                    )) ?? []
                    if files.filter({ $0.pathExtension == "m4a" }).count >= 6 { break }
                }
                self.injectKnownLines()
            }
        }
        #endif
    }

    // MARK: 收文件 → 转写 → 回传

    private func handle(file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        guard let raw = metadata[LinkKey.payload] as? Data,
              let descriptor = LinkPayload.unpack(raw, as: SegmentDescriptor.self) else {
            LinkLog.write("手机：收到文件但解不出段信息 \(file.fileURL.lastPathComponent)")
            return
        }

        // WCSession 传过来的文件放在临时目录，系统随时会清。
        // 先原样搬进自己的 Inbox，再在 Inbox 上转写——转写失败也能重来。
        let destination = inbox.appendingPathComponent(descriptor.id)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: file.fileURL, to: destination)
        } catch {
            LinkLog.write("手机：拷贝失败 \(descriptor.id) → \(error.localizedDescription)")
            return
        }
        accept(descriptor: descriptor, at: destination)
    }

    /// 小段走的是字典通道，音频是 Data 而不是文件 URL。
    /// 落盘之后再走同一条处理路径——两条通道不应该有第二套逻辑。
    private func handleIncoming(_ userInfo: [String: Any]) {
        guard let audio = userInfo[LinkKey.audio] as? Data,
              let raw = userInfo[LinkKey.payload] as? Data,
              let descriptor = LinkPayload.unpack(raw, as: SegmentDescriptor.self) else {
            LinkLog.write("手机：收到字典消息，但里面没有音频")
            return
        }
        let destination = inbox.appendingPathComponent(descriptor.id)
        try? FileManager.default.removeItem(at: destination)
        do {
            try audio.write(to: destination, options: .atomic)
        } catch {
            LinkLog.write("手机：写入失败 \(descriptor.id) → \(error.localizedDescription)")
            return
        }
        LinkLog.write("手机：字典通道收到 \(descriptor.id)  \(audio.count / 1024)KB")
        accept(descriptor: descriptor, at: destination)
    }

    /// 文件已经在 Inbox 里了，接下来是排进转写队列
    private func accept(descriptor: SegmentDescriptor, at destination: URL, force: Bool = false) {
        guard force || !transcribed.contains(descriptor.id) else {
            LinkLog.write("手机：\(descriptor.id) 已转写过，跳过")
            return
        }
        receivedCount += 1
        LinkLog.write(String(
            format: "手机：收下 %@  %.1fs  %dKB",
            descriptor.id, descriptor.duration, descriptor.bytes / 1024
        ))
        appendLog("收到 \(descriptor.id)")

        // 串行排队：SFSpeechRecognizer 并发跑多段会互相抢资源，
        // 而且顺序错了还会让「先答应后改期」的判断颠倒。
        let previous = pipeline
        pipeline = Task { [weak self] in
            await previous.value
            guard let self else { return }
            await self.transcribeAndReply(descriptor: descriptor, at: destination)
        }
    }

    private func transcribeAndReply(descriptor: SegmentDescriptor, at url: URL) async {
        do {
            let outcome = try await LocalTranscriber.transcribe(url: url)
            let chunks = outcome.sentences.map {
                TranscriptChunk(start: $0.start, duration: $0.duration, text: $0.text)
            }
            let envelope = TranscriptEnvelope(
                segmentID: descriptor.id,
                startedAt: descriptor.startedAt,
                chunks: chunks,
                engine: outcome.engine,
                finishedAt: Date()
            )
            guard let payload = LinkPayload.envelope(envelope) else {
                LinkLog.write("手机：转写结果编码失败")
                return
            }
            send(payload, for: descriptor.id)

            transcribed.insert(descriptor.id)
            LinkLog.write("手机：转写完成 \(descriptor.id) → \(chunks.count) 句 [\(outcome.engine)]")
            for chunk in chunks {
                LinkLog.write(String(format: "    %5.2fs  %@", chunk.start, chunk.text))
            }
            appendLog("转写 \(chunks.count) 句 · \(outcome.engine)")
        } catch {
            LinkLog.write("手机：转写失败 \(descriptor.id) → \(error.localizedDescription)")
            appendLog("转写失败：\(error.localizedDescription)")
        }
    }

    /// 回传一段转写。
    ///
    /// 即时通道并要求回执：手表就在旁边，这样「刚说完抬腕就能看到」。
    /// 没回执（手表在后台被挂起、隔着距离）就退回排队通道——
    /// 那条通道保证送达，只是要等手表下次活跃。
    private func send(_ payload: [String: Any], for identifier: String) {
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: { _ in
                LinkLog.write("手机：回传已确认 \(identifier)")
            }, errorHandler: { error in
                LinkLog.write("手机：回传未确认 → \(error.localizedDescription)，改排队")
                WCSession.default.transferUserInfo(payload)
            })
        } else {
            WCSession.default.transferUserInfo(payload)
            LinkLog.write("手机：回传排队 \(identifier)")
        }
    }

    // MARK: 重放

    /// 把 Inbox 里已经收下的段重新转写一遍。
    ///
    /// 两个用途：一是权限刚给上、上一次转写全失败（这在真机上很常见——
    /// 用户第一次点拒绝，后来又去设置里打开了）；二是调试链路时不想重新走一遍蓝牙。
    func replayInbox() {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? [])
            .filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        LinkLog.write("手机：重放 Inbox \(files.count) 段")
        for url in files {
            guard let started = SegmentStamp.date(from: url.lastPathComponent) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var duration = 0.0
            if let file = try? AVAudioFile(forReading: url) {
                let rate = file.processingFormat.sampleRate
                duration = rate > 0 ? Double(file.length) / rate : 0
            }
            accept(
                descriptor: SegmentDescriptor(
                    id: url.lastPathComponent,
                    startedAt: started,
                    duration: duration,
                    bytes: size
                ),
                at: url,
                force: true
            )
        }
    }

    #if DEBUG
    /// 没有可用语音识别服务时的降级验证（模拟器上很常见：系统识别服务
    /// 会在反复重启后进入一直报「Failed to initialize recognizer」的状态）。
    ///
    /// 它验证的是后半段：文本回传 → 手表判断 → 承诺快照 → 手机展示。
    /// 不产生任何识别结果，`engine` 标成 `injected`，日志和界面上一眼能看出
    /// 这不是真识别——绝不能把它当成「转写功能已验证」。
    func injectKnownLines() {
        let lines = [
            "我周五前把报价发给小李",
            "改到下周一吧",
            "要不周五发？",
            "你有空帮我看一下吗？",
            "我把合同整理一下",
            "合同整理改到周四吧",
        ]
        let files = ((try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        LinkLog.write("手机：注入 \(min(lines.count, files.count)) 段已知台词（engine=injected，非识别结果）")
        for (index, url) in files.enumerated() where index < lines.count {
            guard let started = SegmentStamp.date(from: url.lastPathComponent) else { continue }
            let envelope = TranscriptEnvelope(
                segmentID: url.lastPathComponent,
                startedAt: started,
                chunks: [TranscriptChunk(start: 0, duration: 2.0, text: lines[index])],
                engine: "injected",
                finishedAt: Date()
            )
            guard let payload = LinkPayload.envelope(envelope) else { continue }
            send(payload, for: url.lastPathComponent)
        }
    }
    #endif

    // MARK: 下发指令    /// 把「确认 / 放弃 / 完成」送给手表。
    /// 用 `transferUserInfo` 而不是 `sendMessage`：手表多半不在前台，
    /// `sendMessage` 在不可达时直接失败，这个动作却必须最终送达。
    func send(_ command: LinkCommand) {
        guard let payload = LinkPayload.envelope(command) else { return }
        WCSession.default.transferUserInfo(payload)
        LinkLog.write("手机：下发 \(command.action.rawValue)")
    }

    // MARK: 收快照

    private func handle(context: [String: Any]) {
        guard let data = context[LinkKey.payload] as? Data,
              let snapshot = LinkPayload.unpack(data, as: LedgerSnapshot.self) else { return }
        LinkLog.write("手机：收到账本快照 \(snapshot.commitments.count) 条承诺")
        appendLog("账本 \(snapshot.commitments.count) 条")
        onSnapshot?(snapshot)
    }

    private func appendLog(_ line: String) {
        lastNote = line
        log.append(line)
        if log.count > 20 { log.removeFirst(log.count - 20) }
    }
}

// MARK: - WCSessionDelegate

extension PhoneLink: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.isActivated = activationState == .activated
            if let error {
                LinkLog.write("手机：激活失败 \(error.localizedDescription)")
            } else {
                LinkLog.write("手机：激活完成 state=\(activationState.rawValue) reachable=\(session.isReachable) paired=\(session.isPaired) watchApp=\(session.isWatchAppInstalled)")
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let copied = file
        Task { @MainActor in self.handle(file: copied) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let copied = userInfo
        Task { @MainActor in self.handleIncoming(copied) }
    }

    /// 即时通道。必须回执，手表靠它判断「这段到底送到了没有」。
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let copied = message
        Task { @MainActor in
            self.handleIncoming(copied)
            replyHandler(["ok": true])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let copied = applicationContext
        Task { @MainActor in self.handle(context: copied) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            LinkLog.write("手机：可达性变化 reachable=\(session.isReachable)")
        }
    }

    // iOS 侧必须实现这两个，否则切到后台再回来会话就废了
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // 用户换了配对手表。重新激活，否则新表永远连不上。
        WCSession.default.activate()
    }
}
