import SwiftUI

/// 手机端的视觉基调。刻意克制：这是每天要看十几次的账本，不是展示页。
enum Theme {
    static let accent = Color(red: 0.13, green: 0.42, blue: 0.94)
    static let pending = Color(red: 0.90, green: 0.52, blue: 0.10)
    static let rescheduled = Color(red: 0.55, green: 0.35, blue: 0.86)
    static let done = Color(red: 0.42, green: 0.45, blue: 0.50)
    static let card = Color(.secondarySystemGroupedBackground)
    static let page = Color(.systemGroupedBackground)
}

/// 截止时间怎么念。人话优先，绝对时间兜底。
struct DueText {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "zh_CN")
        calendar.firstWeekday = 2
        return calendar
    }

    /// 「今天 18:00」「周五前」「11月25日前」
    ///
    /// 只给日期不给时刻时（口语里大多数情况），末尾统一说成「前」——
    /// 「周五 23:59」是把 23:59 这个实现细节泄漏给了用户。
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let cal = calendar
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        let isEndOfDay = cal.component(.hour, from: date) == 23 && cal.component(.minute, from: date) == 59

        func suffix(_ base: String) -> String {
            isEndOfDay ? base + "前" : base + " " + clockString(date)
        }

        switch days {
        case 0: return isEndOfDay ? "今天内" : "今天 " + clockString(date)
        case 1: return suffix("明天")
        case 2: return suffix("后天")
        case -1: return suffix("昨天")
        case 3...6: return suffix("周\(weekdayName(date))")
        case -6...(-2): return suffix("上周\(weekdayName(date))")
        case 7...13: return suffix("下周\(weekdayName(date))")
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = isEndOfDay ? "M月d日前" : "M月d日 HH:mm"
            return formatter.string(from: date)
        }
    }

    static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    /// 时间线用：「11-17 09:12」
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// 23:59 是「当天结束前」的约定，念出来要还原成人话
    static func clockString(_ date: Date) -> String {
        let cal = calendar
        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        if hour == 23 && minute == 59 { return "当天结束前" }
        return String(format: "%02d:%02d", hour, minute)
    }

    static func weekdayName(_ date: Date) -> String {
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        let weekday = calendar.component(.weekday, from: date)
        return names[(weekday - 1) % 7]
    }
}
