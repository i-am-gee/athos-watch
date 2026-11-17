import Foundation

/// 从中文口语里抠出截止时间。
///
/// 刻意做成「宁可解析不出，也不要瞎猜」：解析失败返回 nil，上层会把这条承诺标成
/// 「答应时没确认交付时间」——这恰恰是周复盘要看的东西，不是数据缺陷。
/// 反过来说，猜错一个日期会把整条承诺链污染掉，代价比留空高得多。
struct ChineseDueParser {

    struct Result: Equatable {
        let date: Date
        /// 命中的原文片段，用来在界面上高亮「系统是从哪句抠出时间的」
        let matchedText: String
        /// 有没有给出具体时刻（「下午三点」）。没有则按当日 23:59 处理。
        let hasClockTime: Bool
    }

    var calendar: Calendar

    init(timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "zh_CN")
        // 周一为一周起点，否则「下周一」会算错一天
        calendar.firstWeekday = 2
        self.calendar = calendar
    }

    // MARK: 入口

    func parse(_ text: String, reference: Date) -> Result? {
        let dayAnchor = resolveDayAnchor(in: text, reference: reference)
        let clock = resolveClock(in: text, excluding: dayAnchor?.range)

        guard let day = dayAnchor?.day else {
            // 只说了时刻没说哪天：「三点发」按今天算；今天的这个点已经过了就顺延到明天
            guard let clock else { return nil }
            let startOfToday = calendar.startOfDay(for: reference)
            var candidate = calendar.date(byAdding: .minute, value: clock.minutes, to: startOfToday) ?? reference
            if candidate <= reference {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            return Result(date: candidate, matchedText: clock.text, hasClockTime: true)
        }

        if let clock {
            let startOfDay = calendar.startOfDay(for: day)
            let date = calendar.date(byAdding: .minute, value: clock.minutes, to: startOfDay) ?? startOfDay
            return Result(date: date, matchedText: dayAnchor!.text + clock.text, hasClockTime: true)
        }

        // 只给日期：按当日结束算。「周五前」和「周五」在这个产品里是同一个截止点。
        let endOfDay = calendar.date(
            byAdding: .second, value: 86399,
            to: calendar.startOfDay(for: day)
        ) ?? day
        return Result(date: endOfDay, matchedText: dayAnchor!.text, hasClockTime: false)
    }

    // MARK: 日期锚点

    private struct DayAnchor {
        let day: Date
        let text: String
        let range: Range<String.Index>
    }

    private func resolveDayAnchor(in text: String, reference: Date) -> DayAnchor? {
        // 顺序有讲究：先试最具体的（M月D日），再试周，再试相对日，最后旬/月末。
        if let anchor = monthDay(in: text, reference: reference) { return anchor }
        if let anchor = weekday(in: text, reference: reference) { return anchor }
        if let anchor = relativeDay(in: text, reference: reference) { return anchor }
        if let anchor = monthEdge(in: text, reference: reference) { return anchor }
        return nil
    }

    private func monthDay(in text: String, reference: Date) -> DayAnchor? {
        guard let match = text.firstMatch(#"([0-9]{1,2}|[一二三四五六七八九十]{1,3})月([0-9]{1,2}|[一二三四五六七八九十]{1,3})[日号]"#) else {
            return nil
        }
        guard let month = number(match.group(1)), let day = number(match.group(2)),
              (1...12).contains(month), (1...31).contains(day) else { return nil }

        var components = calendar.dateComponents([.year], from: reference)
        components.month = month
        components.day = day
        guard var date = calendar.date(from: components) else { return nil }
        // 说「1月5日」时若今年已过，通常指明年
        if date < calendar.startOfDay(for: reference) {
            components.year = (components.year ?? 0) + 1
            guard let next = calendar.date(from: components) else { return nil }
            date = next
        }
        return DayAnchor(day: date, text: match.whole, range: match.range)
    }

    private func weekday(in text: String, reference: Date) -> DayAnchor? {
        guard let match = text.firstMatch(#"(下下|下个?|这个?|本)?\s*(?:周|星期|礼拜)\s*([一二三四五六日天])"#) else {
            return nil
        }
        guard let offset = weekdayOffset(match.group(2) ?? "") else { return nil }
        let prefix = match.group(1) ?? ""

        let startOfToday = calendar.startOfDay(for: reference)
        let monday = startOfWeek(for: reference)

        let day: Date
        if prefix.hasPrefix("下下") {
            day = calendar.date(byAdding: .day, value: 14 + offset, to: monday)!
        } else if prefix.hasPrefix("下") {
            day = calendar.date(byAdding: .day, value: 7 + offset, to: monday)!
        } else if prefix.hasPrefix("这") || prefix.hasPrefix("本") {
            day = calendar.date(byAdding: .day, value: offset, to: monday)!
        } else {
            // 不带前缀：「周五」指最近的将来那个周五，今天就是周五则指今天
            var candidate = calendar.date(byAdding: .day, value: offset, to: monday)!
            while candidate < startOfToday {
                candidate = calendar.date(byAdding: .day, value: 7, to: candidate)!
            }
            day = candidate
        }
        return DayAnchor(day: calendar.startOfDay(for: day), text: match.whole, range: match.range)
    }

    private func relativeDay(in text: String, reference: Date) -> DayAnchor? {
        let table: [(String, Int)] = [("大后天", 3), ("后天", 2), ("明天", 1), ("今天", 0)]
        for (word, delta) in table {
            guard let range = text.range(of: word) else { continue }
            let day = calendar.date(byAdding: .day, value: delta, to: calendar.startOfDay(for: reference))!
            return DayAnchor(day: calendar.startOfDay(for: day), text: String(text[range]), range: range)
        }
        return nil
    }

    private func monthEdge(in text: String, reference: Date) -> DayAnchor? {
        guard let match = text.firstMatch(#"(下个?月|这个?月|本月)?\s*(月底|月末|月初)"#) else {
            return nil
        }
        let prefix = match.group(1) ?? ""
        let isEnd = (match.group(2) ?? "").hasSuffix("底") || (match.group(2) ?? "").hasSuffix("末")

        var components = calendar.dateComponents([.year, .month], from: reference)
        if prefix.hasPrefix("下") {
            guard let next = calendar.date(byAdding: .month, value: 1, to: calendar.date(from: components)!) else { return nil }
            components = calendar.dateComponents([.year, .month], from: next)
        }
        guard let firstOfMonth = calendar.date(from: components),
              let dayRange = calendar.range(of: .day, in: .month, for: firstOfMonth) else { return nil }

        let target = isEnd ? dayRange.count : 1
        guard let day = calendar.date(byAdding: .day, value: target - 1, to: firstOfMonth) else { return nil }
        return DayAnchor(day: calendar.startOfDay(for: day), text: match.whole, range: match.range)
    }

    // MARK: 时刻

    private struct Clock {
        /// 从当天 0 点起算的分钟数
        let minutes: Int
        let text: String
    }

    private func resolveClock(in text: String, excluding dayRange: Range<String.Index>?) -> Clock? {
        let pattern = #"(上午|早上|早晨|中午|下午|傍晚|晚上|夜里|凌晨)?\s*([0-9]{1,2}|[一二三四五六七八九十]{1,3})\s*[点时]\s*(半|[0-9]{1,2}\s*分|[一二三四五六七八九十]{1,3}\s*分)?"#
        for match in text.allMatches(pattern) {
            // 「周五」「五月三日」里的数字不能被当成钟点
            if let dayRange, match.range.overlaps(dayRange) { continue }
            guard let hour = number(match.group(2)), (0...24).contains(hour) else { continue }

            var minute = 0
            if let tail = match.group(3) {
                if tail.contains("半") { minute = 30 }
                else if let value = number(tail) { minute = yearSane(value) ? value : 0 }
            }
            guard (0...59).contains(minute) else { continue }

            var normalized = hour % 24
            switch match.group(1) {
            case "下午", "傍晚", "晚上", "夜里":
                if normalized < 12 { normalized += 12 }
            case "中午":
                if normalized < 12 { normalized += 12 }
            case "凌晨":
                if normalized == 12 { normalized = 0 }
            default:
                break
            }
            // 24 点按当天最后一天处理
            if hour == 24 { normalized = 24 }
            return Clock(minutes: normalized * 60 + minute, text: match.whole)
        }
        return nil
    }

    private func yearSane(_ value: Int) -> Bool { (0...59).contains(value) }

    // MARK: 工具

    private func startOfWeek(for date: Date) -> Date {
        let weekday = calendar.component(.weekday, from: date) // 1=周日
        let daysFromMonday = (weekday == 1) ? 6 : weekday - 2
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: -daysFromMonday, to: startOfDay)!
    }

    /// 相对本周一的偏移天数，周一 = 0 … 周日 = 6
    private func weekdayOffset(_ token: String) -> Int? {
        switch token {
        case "一": return 0
        case "二": return 1
        case "三": return 2
        case "四": return 3
        case "五": return 4
        case "六": return 5
        case "日", "天": return 6
        default: return nil
        }
    }

    private func number(_ token: String?) -> Int? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "分 ").union(.whitespaces))
        if trimmed.isEmpty { return nil }
        if let value = Int(trimmed) { return value }
        return chineseNumber(trimmed)
    }

    private func chineseNumber(_ text: String) -> Int? {
        let digits: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
        ]
        if text == "十" { return 10 }
        if let ten = text.firstIndex(of: "十") {
            let tens = text[text.startIndex..<ten]
            let ones = text[text.index(after: ten)...]
            let tensValue = tens.isEmpty ? 1 : (digits[tens.first!] ?? 0)
            let onesValue = ones.isEmpty ? 0 : (digits[ones.first!] ?? 0)
            return tensValue * 10 + onesValue
        }
        guard text.count == 1, let first = text.first else { return nil }
        return digits[first]
    }
}

// MARK: - 正则小工具

struct RegexMatch {
    let whole: String
    let range: Range<String.Index>
    private let groups: [String?]

    init(whole: String, range: Range<String.Index>, groups: [String?]) {
        self.whole = whole
        self.range = range
        self.groups = groups
    }

    /// 1-based，和日常 regex 习惯一致
    func group(_ index: Int) -> String? {
        guard index >= 1, index <= groups.count else { return nil }
        return groups[index - 1]
    }
}

extension String {
    func allMatches(_ pattern: String) -> [RegexMatch] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = self as NSString
        return regex.matches(in: self, range: NSRange(location: 0, length: ns.length)).compactMap { result in
            guard let range = Range(result.range, in: self) else { return nil }
            var groups: [String?] = []
            for index in 1..<result.numberOfRanges {
                if let groupRange = Range(result.range(at: index), in: self) {
                    groups.append(String(self[groupRange]))
                } else {
                    groups.append(nil)
                }
            }
            return RegexMatch(whole: String(self[range]), range: range, groups: groups)
        }
    }

    func firstMatch(_ pattern: String) -> RegexMatch? {
        allMatches(pattern).first
    }
}
