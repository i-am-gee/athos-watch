import AVFoundation
import Foundation
import WatchConnectivity

/// 手表侧的蓝牙通道。
///
/// 职责只有「把录好的段交给手机」和「把手机回的转写收进来」。
/// 判断谁答应了、答应到什么程度，不在这里——那是 `CommitmentLedger` 的事。
///
/// 为什么不做成「录一段发一段」：手表被系统挂起、蓝牙断开、手机没装 App，
/// 这些都太常见了。所以发送是**幂等补发**：每次调用都扫一遍 Segments 目录，
/// 把没发过的按时间正序补上。实时发送和开机补发共用同一条代码路径，
/// 不存在「只有在线时录的那些才传得过去」这种半残状态。
@MainActor
final class WatchLink: NSObject, ObservableObject {

    static let shared = WatchLink()

    @Published private(set) var isActivated = false
    @Published private(set) var isReachable = false
    /// 还没送达手机的段数，底部那行小字用
    @Published private(set) var pendingCount = 0
    @Published private(set) var lastNote: String?

    /// 手机回传一段转写。在 `didReceiveUserInfo` 里同步回调。
    var onTranscript: ((TranscriptEnvelope) -> Void)?

    /// 手机下发的动作（确认 / 放弃 / 完成）
    var onCommand: ((LinkCommand) -> Void)?

    private let sentKey = "athos.link.sentSegments"
    private var sent: Set<String> {
        didSet { UserDefaults.standard.set(Array(sent), forKey: sentKey) }
    }

    private override init() {
        sent = Set(UserDefaults.standard.stringArray(forKey: sentKey) ?? [])
        super.init()
    }

    // MARK: 生命周期

    func activate() {
        guard WCSession.isSupported() else {
            lastNote = "这台设备不支持蓝牙直连"
            LinkLog.write("手表：WCSession 不支持")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        LinkLog.write("手表：activate() 已调用，state=\(session.activationState.rawValue)")
    }

    // MARK: 发送

    /// 扫一遍目录，把没发过的段按时间正序补发给手机。
    /// 返回本次排进队列的段数。
    @discardableResult
    func syncPending() -> Int {
        let session = WCSession.default
        guard session.activationState == .activated else {
            LinkLog.write("同步：session 未激活（state=\(session.activationState.rawValue)），本次跳过")
            recount()
            return 0
        }

        let files = ((try? FileManager.default.contentsOfDirectory(
            at: SegmentInfo.directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? [])
            .filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var queued = 0
        for url in files {
            let name = url.lastPathComponent
            guard !sent.contains(name) else { continue }
            // 手机端要按这个 id 建 utterance，两边对不上就永远合并不了
            guard let info = readInfo(url) else {
                LinkLog.write("同步：跳过读不出元数据的段 \(name)")
                continue
            }
            guard let envelope = LinkPayload.envelope(info) else {
                LinkLog.write("同步：\(name) 编码失败")
                continue
            }
            var metadata = envelope
            metadata[LinkKey.kind] = LinkKey.segmentKind

            // 小段直接塞进消息体，大段才走文件通道。
            // 详见 `LinkKey.smallPayloadLimit`：一句话的音频只有十几 KB，
            // 排队通道反而更绕，即时通道一次就能送到。
            let bytes = (try? Data(contentsOf: url))?.count ?? 0
            if bytes <= LinkKey.smallPayloadLimit, let audio = try? Data(contentsOf: url) {
                var dict = metadata
                dict[LinkKey.audio] = audio
                deliver(dict, name: name, size: bytes, via: session)
            } else {
                session.transferFile(url, metadata: metadata)
                LinkLog.write("同步：文件通道 \(name)  \(bytes / 1024)KB")
                markSent(name)
            }

            queued += 1
            LinkLog.write(String(
                format: "同步：排队 %@  %.1fs %dKB",
                name, info.duration, info.bytes / 1024
            ))
        }

        if queued > 0 {
            lastNote = "已交给手机 \(queued) 段"
        }
        recount()
        return queued
    }

    /// 送一条带音频的字典消息。
    ///
    /// 手机可达时用 `sendMessage` 并要求回执——只有收到回执才算送达。
    /// 这不是为了好看：`transferUserInfo` 在手表模拟器上会立刻回调
    /// 「传输完成」却根本不到手机（手机端日志里连 `handleIncomingUserInfo` 都没有），
    /// 如果拿它当送达依据，录音就会静默丢在「已发送」里再也不重试。
    private func deliver(_ dict: [String: Any], name: String, size: Int, via session: WCSession) {
        guard session.isReachable else {
            session.transferUserInfo(dict)
            LinkLog.write("同步：排队通道 \(name)  \(size / 1024)KB")
            markSent(name)
            return
        }
        session.sendMessage(dict, replyHandler: { _ in
            Task { @MainActor in
                LinkLog.write("同步：即时通道送达 \(name)")
                self.markSent(name)
            }
        }, errorHandler: { error in
            Task { @MainActor in
                LinkLog.write("同步：即时通道失败 \(name) → \(error.localizedDescription)，改排队")
                session.transferUserInfo(dict)
                self.markSent(name)
            }
        })
        LinkLog.write("同步：即时通道 \(name)  \(size / 1024)KB")
    }

    private func markSent(_ name: String) {
        guard !sent.contains(name) else { return }
        sent.insert(name)
        recount()
    }

    /// 把一个段推给手机。`transferFile` 不要求对端在线，
    /// 手机会在可达时收到——这正是我们要的语义，所以这里不判断 reachable。
    private func readInfo(_ url: URL) -> SegmentDescriptor? {
        let sidecar = url.deletingPathExtension().appendingPathExtension("json")
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        if let data = try? Data(contentsOf: sidecar),
           let info = try? LinkPayload.decoder.decode(SegmentInfo.self, from: data) {
            return SegmentDescriptor(
                id: url.lastPathComponent,
                startedAt: info.startedAt,
                duration: info.duration,
                bytes: info.bytes
            )
        }

        // sidecar 没写出来（上一次被强杀）也不能把这段永远留在手表里：
        // 从文件名和文件本身恢复出可用的元数据，照发。
        guard let started = SegmentInfo.date(fromFileName: url.lastPathComponent) else { return nil }
        guard let file = try? AVAudioFile(forReading: url) else {
            // 连时长都读不出来，说明这段本身就是坏的（moov 没落盘）。
            // 仍然发出去：手机端可以从文件头解，解不出也会记一条失败日志，
            // 总比在手表里悄悄占着空间好。
            return SegmentDescriptor(
                id: url.lastPathComponent,
                startedAt: started,
                duration: 0,
                bytes: size
            )
        }
        let rate = file.processingFormat.sampleRate
        return SegmentDescriptor(
            id: url.lastPathComponent,
            startedAt: started,
            duration: rate > 0 ? Double(file.length) / rate : 0,
            bytes: size
        )
    }

    private func recount() {
        let all = ((try? FileManager.default.contentsOfDirectory(
            at: SegmentInfo.directory, includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "m4a" }.map(\.lastPathComponent)
        pendingCount = all.filter { !sent.contains($0) }.count
    }

    // MARK: 推送结论

    /// 把账本快照推给手机。
    ///
    /// 用 `updateApplicationContext` 而不是 `sendMessage`：它只保留最新一份，
    /// 手机在后台、没解锁、没戴表都无所谓——下次激活时拿到的一定是当前状态。
    /// `sendMessage` 在对端不可达时直接失败，账本这种「只要最新」的数据没必要受那个限制。
    func push(_ ledger: CommitmentLedger) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            LinkLog.write("推送：session 未激活，快照留在本地")
            return
        }
        guard let data = LinkPayload.pack(ledger.snapshot) else { return }
        do {
            try session.updateApplicationContext([LinkKey.payload: data])
            LinkLog.write("推送：\(ledger.commitments.count) 条承诺 → 手机")
        } catch {
            LinkLog.write("推送失败：\(error.localizedDescription)")
        }
    }

    // MARK: 接收

    fileprivate func handle(_ userInfo: [String: Any]) {
        guard let data = userInfo[LinkKey.payload] as? Data else {
            LinkLog.write("收到一条消息，但没有 payload")
            return
        }
        // 同一条字典通道里跑两种消息：先试转写，再试指令。
        // 分成两条 key 也行，但那样一改协议就要动两端的 key 表，反而更容易错。
        if let transcript = LinkPayload.unpack(data, as: TranscriptEnvelope.self) {
            LinkLog.write("收到转写 \(transcript.segmentID)  \(transcript.chunks.count) 句  engine=\(transcript.engine)")
            lastNote = "手机回了 \(transcript.chunks.count) 句"
            onTranscript?(transcript)
            return
        }
        if let command = LinkPayload.unpack(data, as: LinkCommand.self) {
            LinkLog.write("收到指令 \(command.action.rawValue)")
            onCommand?(command)
            return
        }
        LinkLog.write("收到 \(data.count) 字节，既不是转写也不是指令")
    }
}

// MARK: - WCSessionDelegate

extension WatchLink: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            self.isActivated = activationState == .activated
            self.isReachable = session.isReachable
            if let error {
                LinkLog.write("激活失败：\(error.localizedDescription)")
            } else {
                LinkLog.write("激活完成 state=\(activationState.rawValue) reachable=\(session.isReachable)")
            }
            // 激活完成时 reachable 往往还是 false，要一秒左右才变 true。
            // 这一刻就发会走排队通道——而排队通道在手表模拟器上不会真的投递，
            // 段会进黑洞并且被标记成「已发送」。等两秒，绝大多数情况都能走即时通道。
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.syncPending()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            LinkLog.write("可达性变化 reachable=\(session.isReachable)")
            if session.isReachable { self.syncPending() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let copied = userInfo
        Task { @MainActor in self.handle(copied) }
    }

    /// 即时通道。手机回传转写时走这条，必须回执——
    /// 手机靠回执判断「手表到底收下了没有」，没收下就改走排队通道。
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let copied = message
        Task { @MainActor in
            self.handle(copied)
            replyHandler(["ok": true])
        }
    }

    /// 发送结果。失败必须从「已发送」里摘掉，否则这段录音会被永久跳过——
    /// 排队时打勾、失败时不撤销，是这类同步最常见的一处静默丢数据。
    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?
    ) {
        let raw = userInfoTransfer.userInfo[LinkKey.payload] as? Data
        let descriptor = raw.flatMap { LinkPayload.unpack($0, as: SegmentDescriptor.self) }
        let identifier = descriptor?.id
        Task { @MainActor in
            if let error {
                if let identifier { self.sent.remove(identifier) }
                LinkLog.write("发送失败 \(identifier ?? "?")：\(error.localizedDescription)")
                self.recount()
            } else {
                LinkLog.write("发送确认 \(identifier ?? "?")")
            }
        }
    }
}
