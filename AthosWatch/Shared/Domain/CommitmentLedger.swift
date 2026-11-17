import Foundation

/// 承诺账本。纯值类型，不依赖 SwiftUI、不碰网络，可以在命令行里一句句喂进去验证。
///
/// 设计上刻意区分「原话」和「结论」两条流：原话只进不出，结论可以反复推翻。
/// 用户改一次判断不该丢掉任何一句录音。
struct CommitmentLedger {

    struct Decision: Identifiable {
        let id = UUID()
        let utterance: Utterance
        let outcome: MergeOutcome
        let at: Date
    }

    private(set) var commitments: [Commitment] = []
    private(set) var utterances: [Utterance] = []
    private(set) var decisions: [Decision] = []

    private var merger = CommitmentMerger()

    init(merger: CommitmentMerger = CommitmentMerger()) {
        self.merger = merger
    }

    // MARK: 写入

    /// 喂一句原话，返回这次判定的结果。所有后续状态都由这个结果推导。
    @discardableResult
    mutating func ingest(_ utterance: Utterance) -> MergeOutcome {
        utterances.append(utterance)
        let outcome = merger.merge(utterance, existing: commitments)

        switch outcome {
        case .created(let commitment):
            commitments.append(commitment)

        case .dueUpdated(let id, let from, let to):
            if let index = commitments.firstIndex(where: { $0.id == id }) {
                commitments[index].apply(
                    .dueChanged(from: from, to: to),
                    at: utterance.recordedAt,
                    utteranceID: utterance.id
                )
            }

        case .confirmed(let id):
            if let index = commitments.firstIndex(where: { $0.id == id }) {
                commitments[index].apply(
                    .confirmed(by: .restated),
                    at: utterance.recordedAt,
                    utteranceID: utterance.id
                )
            }

        case .ignored:
            break
        }

        decisions.append(Decision(utterance: utterance, outcome: outcome, at: utterance.recordedAt))
        return outcome
    }

    /// 用户手点「确认」。这一步之后才允许写入提醒事项。
    mutating func confirm(_ id: UUID, at time: Date = Date()) {
        guard let index = commitments.firstIndex(where: { $0.id == id }) else { return }
        commitments[index].apply(.confirmed(by: .user), at: time, utteranceID: nil)
    }

    mutating func setStatus(_ id: UUID, to status: CommitmentStatus, at time: Date = Date()) {
        guard let index = commitments.firstIndex(where: { $0.id == id }) else { return }
        let from = commitments[index].status
        guard from != status else { return }
        commitments[index].apply(.statusChanged(from: from, to: status), at: time, utteranceID: nil)
    }

    // MARK: 读取

    func commitment(id: UUID) -> Commitment? {
        commitments.first { $0.id == id }
    }

    func utterance(id: UUID) -> Utterance? {
        utterances.first { $0.id == id }
    }

    /// 某条承诺的所有原话，按时间正序。界面上的「两句原话都能回听」就是它。
    func utterances(for commitment: Commitment) -> [Utterance] {
        commitment.revisions
            .sorted { $0.at < $1.at }
            .compactMap { revision in revision.utteranceID.flatMap(utterance(id:)) }
    }

    /// 「我答应了什么」的默认视图：我的、还活着的
    var myOpen: [Commitment] {
        commitments
            .filter(\.isOpenMine)
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    /// 对方提的、我还没回应
    var awaitingMyReply: [Commitment] {
        commitments.filter { !$0.promisor.isMe && $0.status == .needsConfirmation }
    }

    /// 我含糊说过的，等我点头
    var needsConfirmation: [Commitment] {
        commitments
            .filter(\.awaitingMyConfirmation)
            .sorted { $0.createdAt > $1.createdAt }
    }

    var completed: [Commitment] {
        commitments.filter { $0.status == .done }
    }
}
