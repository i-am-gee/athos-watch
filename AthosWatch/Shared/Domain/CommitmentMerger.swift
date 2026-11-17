import Foundation

/// 合并决策。每种结果都能在界面上讲清「为什么它被合并/为什么它要等确认」。
enum MergeOutcome: Equatable {
    case created(Commitment)
    /// 同一条承诺的日期被更新——这是「改到下周一吧」应有的结果
    case dueUpdated(commitmentID: UUID, from: Date?, to: Date)
    case confirmed(commitmentID: UUID)
    case ignored(reason: String)

    var keepsHistory: Bool {
        if case .dueUpdated = self { return true }
        return false
    }
}

/// 判断「这句话是在新建一条、修改一条、还是根本不该记」。
///
/// 整个产品的正确性压在这里。四条规则按顺序生效，每一条都对应一句真实口语：
///   1. 只是确认（「好」「就这么定」）      → 把待确认的那条转正
///   2. 改期（「改到下周一吧」）            → 更新同一个 id 的 due，不新建
///   3. 对方在请求我（「你有空帮我看一下吗？」）→ 记成「对方提的」，等我回应
///   4. 征询（「要不周五发？」）            → 记成待确认，绝不直接进提醒事项
struct CommitmentMerger {

    var parser: PromiseParser
    /// 动作相似度阈值。低于这个值就当两件事，宁可多一条也不要错误合并。
    var matchThreshold: Double = 0.40

    init(parser: PromiseParser = PromiseParser()) {
        self.parser = parser
    }

    func merge(_ utterance: Utterance, existing: [Commitment]) -> MergeOutcome {
        let parsed = parser.parse(utterance.text, reference: utterance.recordedAt)

        // 1. 纯确认
        if parsed.isConfirmation {
            let pending = existing
                .filter { $0.status == .needsConfirmation }
                .sorted { $0.updatedAt > $1.updatedAt }
            if let target = pending.first {
                return .confirmed(commitmentID: target.id)
            }
            return .ignored(reason: "听上去是确认，但没有找到待确认的条目")
        }

        // 3. 对方在请求我：这不是我的承诺，先挂在「等你回应」
        if parsed.isRequestToMe, !utterance.speaker.isMe {
            if let duplicate = existing.first(where: {
                $0.status == .needsConfirmation && !$0.promisor.isMe
                    && similarity($0.action, parsed.action) >= 0.7
            }) {
                return .ignored(reason: "同一条请求已经记在待确认里：\(duplicate.action)")
            }
            return .created(makeCommitment(from: utterance, parsed: parsed, promisor: utterance.speaker, status: .needsConfirmation))
        }

        // 2. 改期
        if parsed.isReschedule, let newDue = parsed.due {
            let pool = existing.filter { $0.promisor.isMe && ($0.status == .active || $0.status == .needsConfirmation) }
            let target: Commitment?
            if parsed.action.isEmpty {
                // 「改到下周一吧」通常不重复事项名，取最近动过的那条
                target = pool.sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    return $0.createdAt > $1.createdAt
                }.first
            } else {
                let scored = pool
                    .map { ($0, similarity($0.action, parsed.action)) }
                    .sorted { $0.1 > $1.1 }
                target = scored.first(where: { $0.1 >= matchThreshold })?.0
            }

            guard let target else {
                // 没找到能对上的：当成一条新承诺，但语气按原句判断
                let status: CommitmentStatus = parsed.strength == .firm ? .active : .needsConfirmation
                return .created(makeCommitment(from: utterance, parsed: parsed, promisor: .me, status: status))
            }
            return .dueUpdated(commitmentID: target.id, from: target.due, to: newDue)
        }

        // 4. 征询 / 提议：一律先进待确认
        if parsed.isQuestion || parsed.strength == .offer {
            if parsed.action.isEmpty {
                return .ignored(reason: "没听出具体答应的事")
            }
            return .created(makeCommitment(from: utterance, parsed: parsed, promisor: .me, status: .needsConfirmation))
        }

        // 5. 有保留的承诺也要确认
        if parsed.strength == .tentative {
            if parsed.action.isEmpty {
                return .ignored(reason: "没听出具体答应的事")
            }
            return .created(makeCommitment(from: utterance, parsed: parsed, promisor: .me, status: .needsConfirmation))
        }

        // 6. 明确承诺
        if parsed.strength == .firm, !parsed.action.isEmpty {
            if let duplicate = existing.first(where: {
                $0.status != .dropped && $0.status != .superseded
                    && similarity($0.action, parsed.action) >= 0.75
                    && $0.due == parsed.due
            }) {
                return .ignored(reason: "同一件事、同一个时间已经记过了：\(duplicate.action)")
            }
            return .created(makeCommitment(from: utterance, parsed: parsed, promisor: .me, status: .active))
        }

        return .ignored(reason: "这句话里没有可执行的承诺")
    }

    // MARK: 构造

    private func makeCommitment(
        from utterance: Utterance,
        parsed: ParsedPromise,
        promisor: Speaker,
        status: CommitmentStatus
    ) -> Commitment {
        Commitment(
            action: parsed.action.isEmpty ? utterance.text : parsed.action,
            promisor: promisor,
            promisee: parsed.counterparty,
            due: parsed.due,
            strength: parsed.strength,
            status: status,
            revisions: [
                Revision(
                    at: utterance.recordedAt,
                    utteranceID: utterance.id,
                    change: .created(due: parsed.due, strength: parsed.strength)
                ),
            ],
            createdAt: utterance.recordedAt,
            updatedAt: utterance.recordedAt
        )
    }

    // MARK: 相似度

    /// 中文字符 bigram 的 Jaccard 系数。比编辑距离稳，也不怕语序变化。
    func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = bigrams(lhs)
        let b = bigrams(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private func bigrams(_ text: String) -> Set<String> {
        let chars = Array(text.filter { !$0.isWhitespace && !" ，。！!、~？?".contains($0) })
        guard chars.count >= 2 else { return Set(chars.map(String.init)) }
        var result = Set<String>()
        for index in 0..<(chars.count - 1) {
            result.insert(String(chars[index...(index + 1)]))
        }
        return result
    }
}
