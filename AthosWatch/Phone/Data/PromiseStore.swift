import Foundation
import SwiftUI

/// 手机端的账本容器。除了持有一份 `CommitmentLedger`，只做三件事：
/// 喂原话、执行用户的确认/完成动作、把「展开哪条」这种纯 UI 状态放在这里。
///
/// 真正的判断逻辑一律留在 Shared 层，这样它能被命令行断言覆盖到，
/// 而不是只能靠点界面来试。
@MainActor
final class PromiseStore: ObservableObject {

    @Published private(set) var ledger = CommitmentLedger()
    @Published var expandedIDs: Set<UUID> = []
    @Published private(set) var lastDecision: MergeOutcome?
    /// 承诺 id → 提醒事项同步状态（成功或失败原因），只用于界面提示
    @Published private(set) var reminderState: [UUID: String] = [:]
    /// 上层链路的一句话状态：有没有收到手表快照、收到了几段
    @Published private(set) var syncNote: String = "正在连接手表"
    @Published private(set) var lastSyncAt: Date?

    /// 演示模式：界面截图和设计评审用，数据是手写的，不接蓝牙。
    private let isDemo: Bool

    init(seedDemo: Bool = false) {
        isDemo = seedDemo || ProcessInfo.processInfo.arguments.contains("-seedDemo")

        if isDemo {
            seed()
            syncNote = "演示数据"
        } else {
            // 真实模式下，手机首页完全由手表推来的快照驱动。
            // 手机不自己判断——判断的真相在手表，这里只负责显示和落地提醒事项。
            PhoneLink.shared.onSnapshot = { [weak self] snapshot in
                self?.apply(snapshot)
            }
            PhoneLink.shared.activate()
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-reminderProbe") {
            let snapshot = ledger
            Task { await Self.runReminderProbe(snapshot) }
        }
        #endif
    }

    /// 收到手表快照。整体替换而不是合并：
    /// 合并需要一套「谁更新」的规则，而那套规则本身就是判断逻辑，
    /// 判断逻辑只应该有一份，在手表上。
    private func apply(_ snapshot: LedgerSnapshot) {
        guard !isDemo else { return }
        ledger = CommitmentLedger(snapshot: snapshot)
        lastSyncAt = snapshot.generatedAt
        let open = snapshot.commitments.filter(\.isOpenMine).count
        let pending = snapshot.commitments.filter(\.awaitingMyConfirmation).count
        syncNote = pending > 0
            ? "手表传来 \(open) 条，\(pending) 条等你确认"
            : "手表传来 \(open) 条承诺"
    }

    // MARK: 读取

    var mine: [Commitment] { ledger.myOpen }

    var pending: [Commitment] {
        (ledger.needsConfirmation + ledger.awaitingMyReply)
            .sorted { $0.createdAt > $1.createdAt }
    }

    var finished: [Commitment] {
        ledger.commitments
            .filter { $0.status == .done || $0.status == .dropped }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var review: WeeklyReview {
        WeeklyReview.compute(commitments: ledger.commitments, weekOf: Date())
    }

    func utterances(for commitment: Commitment) -> [Utterance] {
        ledger.utterances(for: commitment)
    }

    /// 卡片标题。两种情况下直接用原话，因为此时精简过的动作短语反而更难懂：
    /// 一是太短（「要不发」），二是对方提的请求（原话里的语气本身就是信息）。
    func title(for commitment: Commitment) -> String {
        if !commitment.promisor.isMe, let first = utterances(for: commitment).first {
            return first.text
        }
        if commitment.action.count >= 4 { return commitment.action }
        if let first = utterances(for: commitment).first { return first.text }
        return commitment.action
    }

    // MARK: 动作

    /// 确认 = 变更状态 + 写入提醒事项。先落状态再写系统，
    /// 免得系统写入失败把用户的确认动作也一起回滚掉。
    func confirm(_ commitment: Commitment) {
        ledger.confirm(commitment.id)
        relay(.confirm, commitment)
        Task { await syncToReminders(commitment) }
    }

    /// 把动作送回手表。手表是账本的真相，不告诉它的话，
    /// 下一次快照推过来会把这里刚做的改动原样盖回去。
    private func relay(_ action: LinkCommand.Action, _ commitment: Commitment) {
        guard !isDemo else { return }
        PhoneLink.shared.send(
            LinkCommand(action: action, commitmentID: commitment.id, at: Date())
        )
    }

    private func syncToReminders(_ commitment: Commitment) async {
        let notes = utterances(for: commitment)
            .map { "「\($0.text)」" }
            .joined(separator: "\n")
        do {
            _ = try await ReminderWriter.write(
                title: title(for: commitment),
                notes: notes.isEmpty ? "来自 Athos" : notes,
                due: commitment.due
            )
            reminderState[commitment.id] = "已写入提醒事项"
        } catch {
            reminderState[commitment.id] = error.localizedDescription
        }
    }

    /// 「不是承诺」——不删除原话，只把结论撤掉
    func dismiss(_ commitment: Commitment) {
        ledger.setStatus(commitment.id, to: .dropped)
        relay(.drop, commitment)
    }

    func complete(_ commitment: Commitment) {
        ledger.setStatus(commitment.id, to: .done)
        relay(.complete, commitment)
    }

    func toggleExpanded(_ id: UUID) {
        if expandedIDs.contains(id) { expandedIDs.remove(id) } else { expandedIDs.insert(id) }
    }

    // MARK: 自检

    /// `-reminderProbe` 启动时跑一次：申请权限 → 写一条 → 读回来。
    /// 只打印结果，不改界面，用 `simctl launch --console-pty` 看输出。
    static func runReminderProbe(_ ledger: CommitmentLedger) async {
        probeLog("开始")
        defer { probeLog("结束") }
        do {
            let store = try await ReminderWriter.requestStore()
            probeLog("权限 OK")
            guard let target = ledger.commitments.first(where: { $0.promisor.isMe && $0.status == .active }) else {
                probeLog("没有可写的承诺")
                return
            }
            let identifier = try await ReminderWriter.write(
                title: target.action,
                notes: "来自 Athos 自检",
                due: target.due,
                store: store
            )
            probeLog("写入 OK id=\(identifier)")
            let found = await ReminderWriter.find(title: target.action, store: store)
            probeLog("读回 \(found.count) 条：\(found.map(\.title))")
        } catch {
            probeLog("失败：\(error.localizedDescription)")
        }
    }

    /// 模拟器里 `print` 抓不到（--console 只回放系统日志），
    /// 所以自检结果写进 App 容器的文件，用 simctl get_app_container 取。
    static func probeLog(_ message: String) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("reminder-probe.log")
        let line = ISO8601DateFormatter().string(from: Date()) + "  " + message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: 演示数据

    /// 演示用的对话，按用户的真实场景编排：
    /// 答应 → 改期（同一条）、征询（等你确认）、对方请求（等你回应）、
    /// 三条没定时间的承诺里两条后来改期——正好撑起周复盘那句话。
    private func seed() {
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 2
        calendar.timeZone = .current

        let today = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: now)
        let daysFromMonday = (weekday == 1) ? 6 : weekday - 2
        let monday = calendar.date(byAdding: .day, value: -daysFromMonday, to: today) ?? today

        func slot(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> Date {
            var day = calendar.date(byAdding: .day, value: dayOffset, to: monday) ?? monday
            if day > today { day = today }
            var date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
            if date > now { date = now.addingTimeInterval(-120) }
            return date
        }

        let me: Speaker = .me
        let xiaoli: Speaker = .other(name: "小李")

        var index = 0
        func feed(_ text: String, at date: Date, speaker: Speaker = .me) {
            index += 1
            let utterance = Utterance(
                segmentFile: String(format: "seg-demo-%02d.m4a", index),
                offsetInSegment: 0,
                duration: 3.4,
                recordedAt: date,
                speaker: speaker,
                text: text
            )
            lastDecision = ledger.ingest(utterance)
        }

        // 周一上午：先答应，两分钟后改期——同一条承诺，两句原话都留着
        feed("我周五前把报价发给小李", at: slot(0, 9, 12), speaker: me)
        feed("改到下周一吧", at: slot(0, 9, 14), speaker: me)

        // 周一：一句征询，不该直接变成待办
        feed("要不周五发？", at: slot(0, 10, 5), speaker: me)

        // 周一：对方在请求我，这不是我答应的
        feed("你有空帮我看一下吗？", at: slot(0, 11, 30), speaker: xiaoli)

        // 周二：三件当场没说时间的活，其中两件后来改期
        feed("我把合同整理一下", at: slot(1, 9, 0), speaker: me)
        feed("我给王总回个电话", at: slot(1, 9, 2), speaker: me)
        feed("合同整理改到周四吧", at: slot(1, 16, 40), speaker: me)
        feed("我给运营发个版本", at: slot(2, 10, 20), speaker: me)
        feed("给运营发版本改到周五", at: slot(2, 11, 0), speaker: me)

        // 一条上周的历史承诺，用来演示「已完成」区块；不在本周，不进周复盘
        if let lastWeek = calendar.date(byAdding: .day, value: -7, to: slot(0, 9, 0)) {
            feed("我把周报发给张总", at: lastWeek, speaker: me)
            if let done = ledger.commitments.last {
                ledger.setStatus(done.id, to: .done, at: now.addingTimeInterval(-3600))
            }
        }
    }
}
