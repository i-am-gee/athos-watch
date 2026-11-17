import EventKit
import Foundation

/// 把一条「已确认」的承诺写进系统提醒事项。
///
/// 严格边界：只有用户亲手点过「确认」的才会走到这里。
/// 手表端不可能做这件事（watchOS 的 EKEventStore 写方法全部标了
/// __WATCHOS_PROHIBITED），所以这是手机端存在的第一个硬理由。
enum ReminderWriter {

    enum Failure: LocalizedError {
        case denied
        case noCalendar
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .denied: return "没有提醒事项权限，无法写入"
            case .noCalendar: return "系统里没有默认的提醒事项列表"
            case .saveFailed(let message): return "写入失败：\(message)"
            }
        }
    }

    static func requestStore() async throws -> EKEventStore {
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { throw Failure.denied }
        return store
    }

    /// 返回系统分配的标识符，便于后续把「已完成」同步回去
    @discardableResult
    static func write(
        title: String,
        notes: String,
        due: Date?,
        store: EKEventStore? = nil
    ) async throws -> String {
        // ?? 的右边是 autoclosure，不能在里面 await
        let eventStore: EKEventStore
        if let store { eventStore = store } else { eventStore = try await requestStore() }
        let store = eventStore

        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw Failure.noCalendar
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = calendar
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
        }

        do {
            try store.save(reminder, commit: true)
        } catch {
            throw Failure.saveFailed(error.localizedDescription)
        }
        return reminder.calendarItemIdentifier
    }

    /// 读回指定标题的提醒，用于自检「到底有没有真的写进去」
    static func find(title: String, store: EKEventStore) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            let predicate = store.predicateForReminders(in: nil)
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).filter { $0.title == title })
            }
        }
    }
}
