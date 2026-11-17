import Foundation

/// 每周复盘。核心原则：只统计能回到原话的事实，不做情绪化总结。
///
/// 用户要的那句话——「本周有 3 条任务在答应时没确认交付时间，其中 2 条后来改期」——
/// 就是把两个可数的量放在一起说。它之所以有说服力，是因为每个数字都能点开看到原句。
struct WeeklyReview {

    struct Metrics {
        var created: Int = 0
        /// 答应时就没有截止时间的（originDue == nil）
        var createdWithoutDue: Int = 0
        /// 后来改过期的条数
        var rescheduled: Int = 0
        /// 其中「一开始就没定时间」的
        var rescheduledFromNoDue: Int = 0
        /// 还躺在待确认里的
        var awaitingConfirmation: Int = 0
        /// 对方提的、我还没回应
        var awaitingMyReply: Int = 0
        var done: Int = 0
        var doneLate: Int = 0
        var topCounterparty: (name: String, count: Int)?

        var noDueRate: Double {
            created == 0 ? 0 : Double(createdWithoutDue) / Double(created)
        }

        /// 没定时间的承诺后来被改掉的比例——这是「当场定下时间」的最强论据
        var churnAfterNoDue: Double {
            createdWithoutDue == 0 ? 0 : Double(rescheduledFromNoDue) / Double(createdWithoutDue)
        }
    }

    let weekStart: Date
    let weekEnd: Date
    let metrics: Metrics

    static func compute(
        commitments: [Commitment],
        weekOf reference: Date,
        calendar: Calendar = {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
            c.firstWeekday = 2
            return c
        }()
    ) -> WeeklyReview {
        let weekday = calendar.component(.weekday, from: reference)
        let daysFromMonday = (weekday == 1) ? 6 : weekday - 2
        let startOfDay = calendar.startOfDay(for: reference)
        let start = calendar.date(byAdding: .day, value: -daysFromMonday, to: startOfDay) ?? startOfDay
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start

        var metrics = Metrics()
        var counterparties: [String: Int] = [:]

        for commitment in commitments {
            // 对方提的请求不算我答应的事，但它要单独计数——那是「等我回应」的积压
            if commitment.status == .needsConfirmation && !commitment.promisor.isMe {
                metrics.awaitingMyReply += 1
                continue
            }
            guard commitment.promisor.isMe else { continue }

            let createdInWeek = commitment.createdAt >= start && commitment.createdAt < end
            if createdInWeek {
                metrics.created += 1
                if !commitment.hadDueAtCreation { metrics.createdWithoutDue += 1 }
                if let name = commitment.promisee {
                    counterparties[name, default: 0] += 1
                }
            }

            if commitment.wasRescheduled && commitment.updatedAt >= start && commitment.updatedAt < end {
                metrics.rescheduled += 1
                if !commitment.hadDueAtCreation { metrics.rescheduledFromNoDue += 1 }
            }

            if commitment.status == .needsConfirmation {
                metrics.awaitingConfirmation += 1
            }

            if commitment.status == .done, let due = commitment.due, commitment.updatedAt >= start, commitment.updatedAt < end {
                metrics.done += 1
                if commitment.updatedAt > due { metrics.doneLate += 1 }
            }
        }

        metrics.topCounterparty = counterparties.max { $0.value < $1.value }.map { ($0.key, $0.value) }

        return WeeklyReview(weekStart: start, weekEnd: end, metrics: metrics)
    }

    /// 一句话结论。数字为零时也要说实话，不要为了好看编一句。
    var headline: String {
        guard metrics.created > 0 else {
            return "本周还没有记到承诺。"
        }
        var text = "本周 \(metrics.created) 条承诺"
        if metrics.createdWithoutDue > 0 {
            text += "，其中 \(metrics.createdWithoutDue) 条在答应时没确认交付时间"
            if metrics.rescheduledFromNoDue > 0 {
                text += "，\(metrics.rescheduledFromNoDue) 条后来改期"
            }
            text += "。"
        } else {
            text += "，全部当场定了时间。"
        }
        return text
    }

    /// 基于数据的建议，只在数据足够时才说
    var advice: String? {
        if metrics.createdWithoutDue == 0 { return nil }
        if metrics.churnAfterNoDue >= 0.5 {
            return "没定时间的承诺里，\(Int(metrics.churnAfterNoDue * 100))% 后来都改了。当场把日子定下来，比事后改期省一次沟通。"
        }
        if metrics.awaitingConfirmation > 0 {
            return "还有 \(metrics.awaitingConfirmation) 条停在「待确认」，确认之后才会进提醒事项。"
        }
        return nil
    }
}
