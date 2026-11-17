import Foundation

// 承诺引擎的命令行验证。不依赖 Xcode、不依赖模拟器：
//   swiftc -O Shared/Domain/*.swift Tests/promises.swift -o build-tools/promisecheck

var checks = 0
var failures = 0

func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    checks += 1
    if !passed { failures += 1 }
    let mark = passed ? "PASS" : "FAIL"
    print("  \(mark)  \(label)\(detail.isEmpty ? "" : "   ← \(detail)")")
}

let tz = TimeZone(identifier: "Asia/Shanghai")!
var cal = Calendar(identifier: .gregorian)
cal.timeZone = tz
cal.firstWeekday = 2

func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

let fmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.timeZone = tz
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

func show(_ date: Date?) -> String {
    guard let date else { return "nil" }
    return fmt.string(from: date)
}

let parser = ChineseDueParser(timeZone: tz)
let tuesday = makeDate(2026, 11, 17, 9, 30)
let saturday = makeDate(2026, 11, 21, 9, 30)

print("---------------------------------------------")
print("时间解析（基准 2026-11-17 周二 09:30）")

let dueCases: [(String, String)] = [
    ("我周五前把报价发给小李", "2026-11-20 23:59"),
    ("改到下周一吧", "2026-11-23 23:59"),
    ("明天下午三点发你", "2026-11-18 15:00"),
    ("这个月底给你", "2026-11-30 23:59"),
    ("下周一上午十点前", "2026-11-23 10:00"),
    ("后天中午十二点半", "2026-11-19 12:30"),
    ("11月25号之前", "2026-11-25 23:59"),
    ("我尽量处理一下", "nil"),
    ("你有空帮我看一下吗？", "nil"),
    ("我来看看这个", "nil"),
]

for (text, expected) in dueCases {
    let got = show(parser.parse(text, reference: tuesday)?.date)
    check(text, got == expected, "得到 \(got)，期望 \(expected)")
}

print()
print("时间解析（基准 2026-11-21 周六 09:30）")
let weekendCases: [(String, String)] = [
    ("周五", "2026-11-27 23:59"),
    ("这周五", "2026-11-20 23:59"),
    ("下周一", "2026-11-23 23:59"),
]
for (text, expected) in weekendCases {
    let got = show(parser.parse(text, reference: saturday)?.date)
    check(text, got == expected, "得到 \(got)，期望 \(expected)")
}

// MARK: - 合并语义

print()
print("---------------------------------------------")
print("合并语义：改期不新建")

func utterance(_ text: String, at date: Date, speaker: Speaker = .me, file: String = "seg-0001.m4a") -> Utterance {
    Utterance(
        segmentFile: file,
        offsetInSegment: 0,
        duration: 3,
        recordedAt: date,
        speaker: speaker,
        text: text
    )
}

var ledger = CommitmentLedger()
let first = utterance("我周五前把报价发给小李", at: makeDate(2026, 11, 17, 9, 30))
let outcome1 = ledger.ingest(first)
check("第一句应新建承诺", {
    if case .created = outcome1 { return true }
    return false
}())

let second = utterance("改到下周一吧", at: makeDate(2026, 11, 17, 9, 35), file: "seg-0002.m4a")
let outcome2 = ledger.ingest(second)
check("第二句应合并为改期", {
    if case .dueUpdated = outcome2 { return true }
    return false
}())
check("承诺条数仍为 1（没有新建）", ledger.commitments.count == 1, "实际 \(ledger.commitments.count)")

if let merged = ledger.commitments.first {
    check("截止时间更新为 11-23", show(merged.due) == "2026-11-23 23:59", "得到 \(show(merged.due))")
    check("承诺对象是小李", merged.promisee == "小李", "得到 \(merged.promisee ?? "nil")")
    check("动作里不含时间词", !merged.action.contains("周一") && !merged.action.contains("周五"), merged.action)
    check("两条原话都能回听", ledger.utterances(for: merged).count == 2,
          "实际 \(ledger.utterances(for: merged).count)")
    check("改期次数记为 1", merged.rescheduleCount == 1, "实际 \(merged.rescheduleCount)")
    check("答应的原始时间保留在历史里", merged.originDue != nil)
}

print()
print("合并语义：征询先等确认")

var askLedger = CommitmentLedger()
let ask = utterance("要不周五发报价给小李？", at: makeDate(2026, 11, 17, 10, 0))
askLedger.ingest(ask)
if let pending = askLedger.commitments.first {
    check("「要不…」只进待确认", pending.status == .needsConfirmation, "实际 \(pending.status.rawValue)")
    check("语气判为提议", pending.strength == .offer, "实际 \(pending.strength.rawValue)")
    check("不进「我答应了什么」的活动列表", askLedger.myOpen.isEmpty, "实际 \(askLedger.myOpen.count) 条")
}

let confirm = utterance("好", at: makeDate(2026, 11, 17, 10, 2))
askLedger.ingest(confirm)
check("一句「好」把它转正", askLedger.commitments.first?.status == .active,
      "实际 \(askLedger.commitments.first?.status.rawValue ?? "nil")")
check("转正后出现在活动列表", askLedger.myOpen.count == 1, "实际 \(askLedger.myOpen.count)")

print()
print("合并语义：对方提的不算我答应的")

var requestLedger = CommitmentLedger()
requestLedger.ingest(utterance("你有空帮我看一下吗？", at: makeDate(2026, 11, 17, 11, 0), speaker: .other(name: "小李")))
if let request = requestLedger.commitments.first {
    check("承诺人是对方", !request.promisor.isMe, "实际 \(request.promisor.displayName)")
    check("挂在待我回应里", requestLedger.awaitingMyReply.count == 1)
    check("不计入我的活动承诺", requestLedger.myOpen.isEmpty)
}

print()
print("合并语义：重复的话不叠加")

var dupLedger = CommitmentLedger()
dupLedger.ingest(utterance("我周五前把报价发给小李", at: makeDate(2026, 11, 17, 9, 30)))
let dupOutcome = dupLedger.ingest(utterance("周五之前把报价发给小李", at: makeDate(2026, 11, 17, 9, 40), file: "seg-0002.m4a"))
check("同一件事同一时间不重复记", {
    if case .ignored = dupOutcome { return true }
    return false
}(), "实际 \(dupOutcome)")

// MARK: - 周复盘

print()
print("---------------------------------------------")
print("周复盘：答应的强度决定返工量")

var reviewLedger = CommitmentLedger()
reviewLedger.ingest(utterance("我把合同整理一下", at: makeDate(2026, 11, 17, 10, 0), file: "s1.m4a"))
reviewLedger.ingest(utterance("我给王总回个电话", at: makeDate(2026, 11, 17, 11, 0), file: "s2.m4a"))
reviewLedger.ingest(utterance("我把方案初稿写出来", at: makeDate(2026, 11, 17, 12, 0), file: "s3.m4a"))

let noDueCount = reviewLedger.commitments.filter { !$0.hadDueAtCreation }.count
check("三条都没有当场定时间", noDueCount == 3, "实际 \(noDueCount)")

reviewLedger.ingest(utterance("合同整理改到周四吧", at: makeDate(2026, 11, 18, 10, 0), file: "s4.m4a"))
let reschedule = reviewLedger.ingest(utterance("给王总回电话改到周五吧", at: makeDate(2026, 11, 18, 11, 0), file: "s5.m4a"))
check("第二句应命中改期", {
    if case .dueUpdated = reschedule { return true }
    return false
}(), "实际 \(reschedule)")
check("改期后条数没有增加", reviewLedger.commitments.count == 3, "实际 \(reviewLedger.commitments.count)")

let review = WeeklyReview.compute(commitments: reviewLedger.commitments, weekOf: tuesday, calendar: cal)
print("  结论：\(review.headline)")
if let advice = review.advice { print("  建议：\(advice)") }

check("本周承诺 3 条", review.metrics.created == 3, "实际 \(review.metrics.created)")
check("其中 3 条没定时间", review.metrics.createdWithoutDue == 3, "实际 \(review.metrics.createdWithoutDue)")
check("2 条后来改期", review.metrics.rescheduledFromNoDue == 2, "实际 \(review.metrics.rescheduledFromNoDue)")
check("结论句包含关键数字", review.headline.contains("3 条") && review.headline.contains("2 条"), review.headline)

print()
print("---------------------------------------------")
if failures == 0 {
    print("全部通过（\(checks) 项）")
} else {
    print("\(failures)/\(checks) 项不符")
    exit(1)
}
