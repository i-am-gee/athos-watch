import Foundation

/// 手表端的承诺账本。
///
/// 这是整套产品的判断中枢：手机只把「这段录音说了什么字」送回来，
/// 「谁答应了、答应到什么程度、后来有没有变」全部在手表上算完，
/// 手机拿到的是结论快照。
///
/// 为什么判断放在手表而不是手机：
///   1. 判断用的是 `Shared/Domain` 里那套纯规则，两端都有，放哪都能跑；
///   2. 但原话和录音只在手表上——判断离数据近，就不需要为了「改期能不能对上」
///      把整份历史倒来倒去；
///   3. 手机不在身边时（跑步、开会没带手机），手表仍然能立刻算出「我刚答应了什么」。
@MainActor
final class WatchLedger: ObservableObject {

    static let shared = WatchLedger()

    @Published private(set) var ledger = CommitmentLedger()
    @Published private(set) var lastNote: String?
    @Published private(set) var lastIngestAt: Date?

    private let storeURL: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ledger.json")
    }()

    private init() {
        load()
        // 手机回的每一段转写都走这里。回调在 MainActor 上同步触发，
        // 所以界面上的「我刚才答应了什么」不需要等下一帧。
        WatchLink.shared.onTranscript = { [weak self] transcript in
            self?.ingest(transcript)
        }
        WatchLink.shared.onCommand = { [weak self] command in
            self?.apply(command)
        }
    }

    // MARK: 读取

    var mine: [Commitment] { ledger.myOpen }

    var pending: [Commitment] {
        (ledger.needsConfirmation + ledger.awaitingMyReply)
            .sorted { $0.createdAt > $1.createdAt }
    }

    func title(for commitment: Commitment) -> String {
        if commitment.action.count >= 4 { return commitment.action }
        if let first = ledger.utterances(for: commitment).first { return first.text }
        return commitment.action
    }

    // MARK: 处理转写

    /// 一段转写进来，逐句判成承诺。
    ///
    /// 同一段被重复回传时直接丢弃——不然重连一次，首页就多一条一模一样的承诺。
    func ingest(_ transcript: TranscriptEnvelope) {
        guard !ledger.hasProcessed(segmentID: transcript.segmentID) else {
            LinkLog.write("账本：\(transcript.segmentID) 已处理过，跳过")
            return
        }

        var created = 0
        var updated = 0
        var ignored = 0

        for chunk in transcript.chunks {
            let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // 时间用「段起点 + 段内偏移」，不是转写回来的时刻。
            // 改期判断靠的就是这个顺序：先说周五、十分钟后改周一，
            // 如果两句都盖成同一个时间戳，谁先谁后就丢了。
            let utterance = Utterance(
                segmentFile: transcript.segmentID,
                offsetInSegment: chunk.start,
                duration: chunk.duration,
                recordedAt: transcript.startedAt.addingTimeInterval(chunk.start),
                speaker: .me,
                text: text
            )

            switch ledger.ingest(utterance) {
            case .created: created += 1
            case .dueUpdated: updated += 1
            case .confirmed: updated += 1
            case .ignored: ignored += 1
            }
        }

        lastIngestAt = Date()
        let summary = "新 \(created) · 改 \(updated) · 略 \(ignored)"
        lastNote = summary
        LinkLog.write("账本：\(transcript.segmentID) → \(summary)")

        persist()
        push()
    }

    // MARK: 动作

    /// 手机下发的动作。手表说了算，所以这里改完立刻回推一份新快照，
    /// 手机上的界面就是「点了之后确实变了」而不是「等下再说」。
    func apply(_ command: LinkCommand) {
        switch command.action {
        case .confirm: ledger.confirm(command.commitmentID, at: command.at)
        case .drop: ledger.setStatus(command.commitmentID, to: .dropped, at: command.at)
        case .complete: ledger.setStatus(command.commitmentID, to: .done, at: command.at)
        }
        persist()
        push()
        LinkLog.write("账本：执行指令 \(command.action.rawValue)")
    }

    func confirm(_ commitment: Commitment) {
        ledger.confirm(commitment.id)
        persist()
        push()
        lastNote = "已确认：\(title(for: commitment))"
    }

    func dismiss(_ commitment: Commitment) {
        ledger.setStatus(commitment.id, to: .dropped)
        persist()
        push()
    }

    func complete(_ commitment: Commitment) {
        ledger.setStatus(commitment.id, to: .done)
        persist()
        push()
    }

    // MARK: 同步与持久化

    /// 把手表算出来的结论推给手机。手机端首页就是这份快照的镜像。
    func push() {
        WatchLink.shared.push(ledger)
    }

    private func persist() {
        guard let data = LinkPayload.pack(ledger.snapshot) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let snapshot = LinkPayload.unpack(data, as: LedgerSnapshot.self) else { return }
        ledger = CommitmentLedger(snapshot: snapshot)
        LinkLog.write("账本：从磁盘恢复 \(snapshot.commitments.count) 条承诺")
    }
}
