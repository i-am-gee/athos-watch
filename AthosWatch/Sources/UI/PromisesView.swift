import SwiftUI

/// 手表上的「我答应了什么」。
///
/// 这一页的内容全部由手表自己算出来——手机只提供「这段录音说了哪些字」。
/// 所以即使手机不在身边，刚说完一句「我周五前把报价发给小李」，
/// 抬腕就能在这里看到它。
struct PromisesView: View {

    @StateObject private var model = WatchLedger.shared
    @StateObject private var link = WatchLink.shared
    @StateObject private var library = SegmentStore()

    private var isEmpty: Bool {
        model.mine.isEmpty && model.pending.isEmpty
    }

    var body: some View {
        List {
            if isEmpty {
                emptyState
            } else {
                if !model.pending.isEmpty {
                    Section("等你点头") {
                        ForEach(model.pending) { commitment in
                            row(commitment, needsConfirmation: true)
                        }
                    }
                }

                if !model.mine.isEmpty {
                    Section("接下来") {
                        ForEach(model.mine) { commitment in
                            row(commitment, needsConfirmation: false)
                        }
                    }
                }
            }

            Section {
                linkStatus
            }
        }
        .navigationTitle("答应了什么")
        .onAppear {
            library.reload()
            link.syncPending()
        }
    }

    // MARK: 行

    private func row(_ commitment: Commitment, needsConfirmation: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.title(for: commitment))
                .font(.system(size: 14, weight: .medium))
                .lineLimit(2)

            HStack(spacing: 4) {
                Text(dueText(commitment.due))
                    .foregroundStyle(needsConfirmation ? Color.orange : Color.cyan)
                if commitment.wasRescheduled {
                    Text("改\(commitment.rescheduleCount)次")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            // 待确认的才需要「确认」；已经在进行的，滑一下是「做完了」
            if needsConfirmation {
                Button {
                    model.confirm(commitment)
                } label: {
                    Label("确认", systemImage: "checkmark")
                }
                .tint(.green)
            } else {
                Button {
                    model.complete(commitment)
                } label: {
                    Label("完成", systemImage: "checkmark.circle")
                }
                .tint(.green)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                model.dismiss(commitment)
            } label: {
                Label("不是", systemImage: "xmark")
            }
        }
    }

    // MARK: 空态

    /// 空的时候不能只说「没有」。要说清楚为什么没有——
    /// 是没录到，还是录了但手机没回，还是回了但听不出承诺。三种情况用户要做的事完全不同。
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(library.totalCount == 0 ? "还没有录音" : "还没听出承诺")
                .font(.system(size: 14, weight: .medium))
            Text(diagnosis)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    private var diagnosis: String {
        guard library.totalCount > 0 else { return "抬腕说一句「我周五前把报价发给小李」试试。" }
        if link.pendingCount > 0 {
            return "有 \(link.pendingCount) 段还没送到手机，连上手机后会自动补发。"
        }
        if !link.isReachable {
            return "已有 \(library.totalCount) 段录音。手机不在附近时，转写要等连上才做。"
        }
        return "已有 \(library.totalCount) 段录音，手机正在转写。"
    }

    private var linkStatus: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(link.isReachable ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(statusLine)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var statusLine: String {
        if !link.isActivated { return "蓝牙未连接" }
        if link.pendingCount > 0 { return "待发送 \(link.pendingCount) 段" }
        return link.isReachable ? "手机已连接" : "手机不在附近"
    }

    // MARK: 时间文案

    /// 手表屏幕放不下「10月17日 周五 18:00」。这里只保留能做出决定的那部分信息：
    /// 今天/明天说时刻，本周内说周几，更远才说日期。
    ///
    /// 「只有日期没有时刻」要说成「周五前」而不是「周五 23:59」——
    /// 解析器把纯日期补成当天 23:59（这是对的口径），但那是实现细节，
    /// 念给用户听的时候得还原成他原本说的那件事。
    private func dueText(_ due: Date?) -> String {
        guard let due else { return "没定时间" }
        let calendar = Calendar.current
        let dayOnly = calendar.component(.hour, from: due) == 23
            && calendar.component(.minute, from: due) == 59
        let suffix = dayOnly ? "前" : ""

        if calendar.isDateInToday(due) {
            return dayOnly ? "今天" : "今天 " + Self.hourMinute.string(from: due)
        }
        if calendar.isDateInTomorrow(due) {
            return dayOnly ? "明天前" : "明天 " + Self.hourMinute.string(from: due)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()),
                                           to: calendar.startOfDay(for: due)).day ?? 0
        if days > 0 && days < 7 {
            return Self.weekday.string(from: due) + suffix
        }
        return Self.monthDay.string(from: due) + suffix
    }

    private static let hourMinute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let monthDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}
