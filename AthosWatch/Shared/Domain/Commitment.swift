import Foundation

/// 答应到什么程度。这是产品的第二个关键判断：
/// 「要不周五发？」和「我周五前发」都提到周五，但前者不能直接变成待办。
enum CommitmentStrength: String, Codable {
    /// 提议、征询（「要不…」「要不要…」「我可以帮你…」）
    case offer
    /// 有保留（「应该可以」「尽量」「看情况」）
    case tentative
    /// 明确承诺（「我周五前发」「就这么定」）
    case firm

    var label: String {
        switch self {
        case .offer: return "提议"
        case .tentative: return "有保留"
        case .firm: return "明确承诺"
        }
    }
}

enum CommitmentStatus: String, Codable {
    /// 还躺在「待你确认」里，不进提醒事项
    case needsConfirmation
    case active
    case done
    case dropped
    /// 被后来的话整体取代（不是改期，是换了一件事）
    case superseded

    var label: String {
        switch self {
        case .needsConfirmation: return "待确认"
        case .active: return "进行中"
        case .done: return "已完成"
        case .dropped: return "已放弃"
        case .superseded: return "已被取代"
        }
    }
}

enum ConfirmationSource: String, Codable {
    /// 用户亲手点的「确认」
    case user
    /// 后来的话把模糊说法说实了
    case restated
}

enum RevisionChange: Codable, Equatable {
    case created(due: Date?, strength: CommitmentStrength)
    case dueChanged(from: Date?, to: Date?)
    case strengthChanged(from: CommitmentStrength, to: CommitmentStrength)
    case confirmed(by: ConfirmationSource)
    case statusChanged(from: CommitmentStatus, to: CommitmentStatus)
}

/// 一次变更，永远挂着它的来源原句。首页点开一条承诺，看到的就是这些。
struct Revision: Identifiable, Codable, Equatable {
    let id: UUID
    let at: Date
    /// 触发这次变更的原话。用户手点确认时为 nil（那一次没有说话）
    let utteranceID: UUID?
    let change: RevisionChange

    init(id: UUID = UUID(), at: Date, utteranceID: UUID?, change: RevisionChange) {
        self.id = id
        self.at = at
        self.utteranceID = utteranceID
        self.change = change
    }

    /// 一句话说清这次改了什么，给时间线用
    var summary: String {
        switch change {
        case .created(let due, let strength):
            return due.map { "提出：\(strength.label)，截止 \(Self.day.string(from: $0))" }
                ?? "提出：\(strength.label)，未定时间"
        case .dueChanged(let from, let to):
            let a = from.map(Self.day.string(from:)) ?? "未定"
            let b = to.map(Self.day.string(from:)) ?? "未定"
            return "改期：\(a) → \(b)"
        case .strengthChanged(let from, let to):
            return "语气变化：\(from.label) → \(to.label)"
        case .confirmed(let by):
            return by == .user ? "你确认了这条" : "后来的话把它说实了"
        case .statusChanged(let from, let to):
            return "状态：\(from.label) → \(to.label)"
        }
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE HH:mm"
        return f
    }()
}

/// 一条承诺（待办）。日期可以变、语气可以变，但始终是同一条，历史不丢。
struct Commitment: Identifiable, Codable, Equatable {
    let id: UUID
    /// 动作短语，去掉时间和语气词后的核心，例如「把报价发给小李」
    var action: String
    /// 谁答应的。对方提的请求、我还没接，就不是我的承诺
    var promisor: Speaker
    /// 答应给谁，例如「小李」
    var promisee: String?
    var due: Date?
    var strength: CommitmentStrength
    var status: CommitmentStatus
    var revisions: [Revision]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        action: String,
        promisor: Speaker,
        promisee: String?,
        due: Date?,
        strength: CommitmentStrength,
        status: CommitmentStatus,
        revisions: [Revision],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.action = action
        self.promisor = promisor
        self.promisee = promisee
        self.due = due
        self.strength = strength
        self.status = status
        self.revisions = revisions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 答复时说的截止时间。复盘里「答应时没确认交付时间」的判定口径，
    /// 看的是这个而不是当前 due——当前 due 可能已经被改过三次了。
    var originDue: Date? {
        for revision in revisions {
            if case .created(let due, _) = revision.change { return due }
        }
        return due
    }

    var hadDueAtCreation: Bool { originDue != nil }

    var rescheduleCount: Int {
        revisions.reduce(0) { count, revision in
            if case .dueChanged = revision.change { return count + 1 }
            return count
        }
    }

    var wasRescheduled: Bool { rescheduleCount > 0 }

    /// 所有相关原话，按时间排序
    var utteranceIDs: [UUID] {
        revisions.compactMap(\.utteranceID)
    }

    /// 我答应的、已经确认进待办的。
    /// 待确认的不算——「要不周五发？」在我点头之前不该出现在待办清单里，
    /// 否则「我答应了什么」立刻变成一堆我自己都没答应的事。
    var isOpenMine: Bool {
        promisor.isMe && status == .active
    }

    /// 我说的、但还等我确认的
    var awaitingMyConfirmation: Bool {
        promisor.isMe && status == .needsConfirmation
    }

    mutating func apply(_ change: RevisionChange, at time: Date, utteranceID: UUID?) {
        revisions.append(Revision(at: time, utteranceID: utteranceID, change: change))
        updatedAt = time
        switch change {
        case .created(let due, let strength):
            self.due = due
            self.strength = strength
        case .dueChanged(_, let to):
            self.due = to
        case .strengthChanged(_, let to):
            self.strength = to
        case .confirmed:
            if status == .needsConfirmation { status = .active }
        case .statusChanged(_, let to):
            status = to
        }
    }
}
