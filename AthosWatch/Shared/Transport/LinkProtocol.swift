import Foundation

/// 手表 ↔ 手机之间到底传什么。
///
/// 三条通道刻意分开用，不图省事合并成一条：
///
///   - **音频**走 `transferFile`：只有它能搬文件，而且是排队 + 断点友好的，
///     对端不在前台也会在合适时机送达。手表录完一段就扔进去，不必管手机在不在。
///   - **转写文本**走 `transferUserInfo`：体积小，但必须在手表下次抬腕时还在，
///     不能用 `sendMessage`（对端不可达就直接丢）。
///   - **账本快照**走 `updateApplicationContext`：系统只保留最新一份，旧的自然被覆盖。
///     这正是账本想要的语义——手机不需要知道第 3 版长什么样，只需要当前这版。
enum LinkKey {
    /// 三处都用同一个 payload key，值是 JSON 编码后的 Data。
    /// 不把字段摊进字典：`updateApplicationContext` 只认 property list，
    /// 摊开会遇到 Date/enum 的转换问题，包一层 Data 反而干净。
    static let payload = "athos.payload"
    /// 小段音频直接塞在字典通道里传（见 `smallPayloadLimit`）
    static let audio = "athos.audio"
    /// 放在 metadata 里，用来在文件还没解包时就能在日志里读出来
    static let kind = "athos.kind"
    static let segmentKind = "segment"

    /// 字典通道（`transferUserInfo`）单条上限约 65KB。
    /// 留 8KB 给元数据，剩下的才放音频。
    ///
    /// 为什么不用一条 `transferFile` 通吃：真机上 `transferFile` 是对的，
    /// 但模拟器上它不会真的投递（日志里连 `handleIncomingFile` 都不出现），
    /// 链路就完全没法验证。而 24kbps 下 56KB ≈ 18 秒，
    /// 日常一句「我周五前把报价发给小李」也就 15KB——绝大多数段根本不需要走文件通道。
    static let smallPayloadLimit = 56_000
}

/// 一段录音的身份。文件名是两端唯一的对齐键——
/// 手表沙盒路径重装就变，文件名（含毫秒时间戳）不会。
struct SegmentDescriptor: Codable, Hashable, Identifiable {
    /// `seg-20261117-152430-318.m4a`
    let id: String
    let startedAt: Date
    let duration: Double
    let bytes: Int
}

/// 转写出来的一句话，带它在音频里的真实位置。
///
/// 这个 `start` 不是估算的：`SFSpeechRecognizer` 的 `SFTranscriptionSegment`
/// 本身就带 `timestamp`，所以首页那个播放键能真的跳到这句话开始的地方。
struct TranscriptChunk: Codable, Hashable {
    let start: Double
    let duration: Double
    let text: String
}

struct TranscriptEnvelope: Codable {
    let segmentID: String
    let startedAt: Date
    let chunks: [TranscriptChunk]
    /// 实际用了哪个引擎（"on-device" / "server"），排查识别质量时要用
    let engine: String
    let finishedAt: Date

    var plainText: String {
        chunks.map(\.text).joined(separator: " ")
    }
}

/// 手表端账本的完整快照。手机拿到它就能画出和手表一模一样的首页。
struct LedgerSnapshot: Codable {
    let commitments: [Commitment]
    let utterances: [Utterance]
    let generatedAt: Date
}

/// 手机 → 手表的动作指令。
///
/// 为什么必须有这条反向通道：判断的真相在手表，手机只是镜像。
/// 用户在手机首页点了「确认」，如果只改手机本地，手表下一次推快照就会
/// 把它盖回「待确认」——同一个动作在两个地方都发生，就必须有一个地方说了算。
/// 这里让手表说了算，手机负责把动作送过去。
struct LinkCommand: Codable {
    enum Action: String, Codable {
        case confirm
        case drop
        case complete
    }

    let action: Action
    let commitmentID: UUID
    let at: Date
}

/// 从文件名里读出这段录音的起始时间。
///
/// 两端都要用：手表靠它给没有 sidecar 的残段补元数据，手机靠它在重放 Inbox 时
/// 还原「这句话是什么时候说的」。放在 Shared 里，规则就只存在一份。
enum SegmentStamp {

    static func date(from fileName: String) -> Date? {
        // 必须先去掉扩展名。文件名是 seg-20261117-153609-000.m4a，
        // 直接 split 的话第三段是 "000.m4a"，拼出来的时间戳永远解析失败——
        // 而这个函数失败是静默的（返回 nil 就走别的分支），
        // 症状是「没有 sidecar 的段永远不会被补发、重放时全部跳过」。
        let base = (fileName as NSString).deletingPathExtension
        let parts = base.split(separator: "-")
        guard parts.count >= 4 else { return nil }
        return formatter.date(from: "\(parts[1])-\(parts[2])-\(parts[3])")
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}

enum LinkPayload {
    /// 毫秒时间戳。不用 `deferredToDate`：它是 Double 的 reference date 秒数，
    /// 日志里读不出来；也不丢精度。
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    static func pack<T: Encodable>(_ value: T) -> Data? {
        try? encoder.encode(value)
    }

    static func unpack<T: Decodable>(_ data: Data, as type: T.Type) -> T? {
        try? decoder.decode(type, from: data)
    }

    /// 包成 WCSession 认识的字典
    static func envelope<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = pack(value) else { return nil }
        return [LinkKey.payload: data]
    }
}
