import Foundation

/// 说这句话的人。承诺类产品的第一个问题不是「说了什么」，而是「谁说的」——
/// 对方提的请求和我自己给的承诺，在「我答应了什么」里是完全不同的东西。
enum Speaker: Codable, Hashable {
    case me
    case other(name: String?)
    case unknown

    var displayName: String {
        switch self {
        case .me: return "我"
        case .other(let name): return name ?? "对方"
        case .unknown: return "未知说话人"
        }
    }

    var isMe: Bool { if case .me = self { return true }; return false }
}

/// 一句原话。所有结论都必须能回到这里——这是「每句话可回听」的底座。
///
/// 刻意不做成「一条转写 = 一条记录」：手表按声音活动切段，一段里可能有好几句，
/// 所以定位精度到「哪一段 + 段内偏移」，而文本由手机端或服务端补齐。
struct Utterance: Identifiable, Codable, Hashable {
    let id: UUID
    /// 手表产出的 m4a 文件名，不含路径。存绝对路径会在重装后全部失效。
    let segmentFile: String
    /// 在该段音频内的起始秒数
    let offsetInSegment: Double
    let duration: Double
    let recordedAt: Date
    let speaker: Speaker
    let text: String

    init(
        id: UUID = UUID(),
        segmentFile: String,
        offsetInSegment: Double,
        duration: Double,
        recordedAt: Date,
        speaker: Speaker,
        text: String
    ) {
        self.id = id
        self.segmentFile = segmentFile
        self.offsetInSegment = offsetInSegment
        self.duration = duration
        self.recordedAt = recordedAt
        self.speaker = speaker
        self.text = text
    }
}
