import Foundation

/// 从一句话里读出的东西。注意这里没有任何「AI」——全是可复现的规则。
///
/// 为什么先写规则而不是直接接大模型：承诺判定错了会静默污染整条账本，
/// 而规则出错是能一条条指出来、加用例修掉的。等到规则覆盖不住的部分
/// 明显浮出来（比如「帮我把那个东西弄一下」），再把 LLM 作为候选生成器
/// 接进来，让它只在「提议 / 有保留 / 明确」这三档之间投票。
struct ParsedPromise: Equatable {
    /// 去掉时间、语气词后的动作核心
    var action: String
    var counterparty: String?
    var due: Date?
    var dueText: String?
    var strength: CommitmentStrength
    var isReschedule: Bool
    var isQuestion: Bool
    var isConfirmation: Bool
    /// 对方在请求我（「你有空帮我看一下吗？」）——这不是我的承诺
    var isRequestToMe: Bool
}

struct PromiseParser {

    var dueParser: ChineseDueParser

    init(dueParser: ChineseDueParser = ChineseDueParser()) {
        self.dueParser = dueParser
    }

    private static let confirmWords = ["好", "行", "可以", "没问题", "就这么定", "收到", "ok", "嗯", "对", "没问题"]
    private static let hedgeWords = ["应该", "尽量", "争取", "看情况", "大概", "可能", "也许", "差不多"]
    private static let offerWords = ["要不", "要不要", "不如", "我可以", "需要我", "帮你", "行吗", "好吗", "可以吗", "怎么样"]
    private static let rescheduleWords = ["改到", "改成", "改一下", "改期", "推到", "推后", "挪到", "延后", "延期", "换到", "调整到", "顺延"]
    private static let requestWords = ["帮你", "帮我看", "麻烦你", "你能不能", "你可以", "你方便", "有空"]

    func parse(_ text: String, reference: Date) -> ParsedPromise {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let due = dueParser.parse(trimmed, reference: reference)

        let isQuestion = trimmed.contains("？") || trimmed.hasSuffix("?")
            || Self.offerWords.contains { trimmed.contains($0) }
        let isConfirmation = isStandaloneConfirmation(trimmed)
        let isReschedule = Self.rescheduleWords.contains { trimmed.contains($0) }
        let isRequestToMe = Self.requestWords.contains { trimmed.contains($0) } && isQuestion

        var strength: CommitmentStrength = .offer
        if isConfirmation {
            strength = .firm
        } else if Self.hedgeWords.contains(where: { trimmed.contains($0) }) {
            strength = .tentative
        } else if isQuestion {
            strength = .offer
        } else if looksLikeFirmCommitment(trimmed) {
            strength = .firm
        }

        return ParsedPromise(
            action: extractAction(trimmed, dueText: due?.matchedText, isReschedule: isReschedule),
            counterparty: extractCounterparty(trimmed),
            due: due?.date,
            dueText: due?.matchedText,
            strength: strength,
            isReschedule: isReschedule,
            isQuestion: isQuestion,
            isConfirmation: isConfirmation,
            isRequestToMe: isRequestToMe
        )
    }

    // MARK: 判定细节

    /// 「好」「行」「就这么定」——整句只表达确认，没有新内容
    private func isStandaloneConfirmation(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: CharacterSet(charactersIn: "，。！!、~ ？?"))
        guard stripped.count <= 6 else {
            // 长句里出现「就这么定」也算确认
            return stripped.contains("就这么定") || stripped.contains("就这么说定")
        }
        return Self.confirmWords.contains(stripped.lowercased()) || stripped == "好"
    }

    private func looksLikeFirmCommitment(_ text: String) -> Bool {
        let verbs = ["发", "交", "给", "做", "回", "确认", "准备", "安排", "整理", "写", "改", "搞定", "处理", "对接", "推进"]
        return verbs.contains { text.contains($0) }
    }

    private func extractAction(_ text: String, dueText: String?, isReschedule: Bool) -> String {
        var result = text
        // 时间片段连着它的截止尾巴一起删：「周五前」要整段去掉，只删「周五」会剩一个「前」
        if let dueText {
            for suffix in ["之前", "以前", "前", ""] {
                let token = dueText + suffix
                if result.contains(token) {
                    result = result.replacingOccurrences(of: token, with: "")
                    break
                }
            }
        }
        for word in Self.rescheduleWords {
            result = result.replacingOccurrences(of: word, with: "")
        }
        // 主语不进动作
        for subject in ["我们", "我", "你", "他", "她"] where result.hasPrefix(subject) {
            result.removeFirst(subject.count)
            break
        }
        for filler in ["吧", "啊", "呢", "哈", "嘛", "的话", "一下"] {
            result = result.replacingOccurrences(of: filler, with: "")
        }
        if result.hasSuffix("前") { result.removeLast() }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "，。！!、~ ？? ").union(.whitespaces))
    }

    /// 从「给/跟/和/向/对 X」里取 X。中文没有词边界，只能用动词表当右边界：
    /// 「给王总回个电话」要的是「王总」，不是「王总回」。
    private func extractCounterparty(_ text: String) -> String? {
        guard let match = text.firstMatch(#"(?:给|跟|和|向|对)\s*([\u4e00-\u9fa5]{2,4})"#),
              let raw = match.group(1) else { return nil }

        let verbBoundary: Set<Character> = ["发", "打", "说", "看", "回", "交", "送", "确", "准",
                                            "同", "处", "搞", "做", "写", "整", "安", "推", "联", "帮"]
        var name = ""
        for character in raw {
            if verbBoundary.contains(character) { break }
            name.append(character)
            if name.count == 3 { break }
        }

        let stopList: Set<String> = ["你", "我", "他", "她", "它", "大家", "他们", "你们", "我们", "这个", "那个"]
        guard name.count >= 2, !stopList.contains(name) else { return nil }
        return name
    }
}
