import AVFoundation
import Foundation

/// 把录音转成文字。
///
/// **重要事实**：watchOS 没有 Speech 框架（`import Speech` 直接编译失败），
/// 所以「手表自己把语音识别成文字」这条路不成立。手表只能把音频送到别处转写：
///
///   手表 →（HTTP 上传）→ 你的服务 / 云 ASR → 文本 → 手表
///
/// 这个类型只负责「上传 + 取回文本」，不关心对面是自建服务还是云厂商。
/// 服务端约定见 docs/asr-service.md：POST 二进制音频，返回
/// `{"text": "...", "todos": [{"title": "...", "due": "2026-11-17T15:00:00+08:00"}]}`
enum RemoteTranscriber {

    struct Todo {
        let title: String
        let due: Date?
    }

    struct Result {
        let text: String
        let todos: [Todo]
    }

    enum TranscribeError: LocalizedError {
        case notConfigured
        case offline
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "还没配置转写服务地址"
            case .offline: return "手表当前没有网络（离开 iPhone 且非蜂窝版时无法上传）"
            case .badResponse(let reason): return "服务返回异常：\(reason)"
            }
        }
    }

    /// 转写服务地址。真机测试时填 Mac 的局域网地址，例如 http://192.168.1.8:8787/asr
    static var endpoint: URL? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "asrEndpoint"),
                  let url = URL(string: raw) else { return nil }
            return url
        }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: "asrEndpoint") }
    }

    static func transcribe(url: URL) async throws -> Result {
        guard let endpoint else { throw TranscribeError.notConfigured }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(url.lastPathComponent, forHTTPHeaderField: "X-Audio-Name")
        request.timeoutInterval = 120

        let payload = try Data(contentsOf: url)
        let (data, response) = try await URLSession.shared.upload(for: request, from: payload)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TranscribeError.badResponse("HTTP \(code)")
        }

        struct Payload: Decodable {
            struct Item: Decodable {
                let title: String
                let due: String?
            }
            let text: String
            let todos: [Item]?
        }

        guard let decoded = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw TranscribeError.badResponse("JSON 解析失败")
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()

        let todos = (decoded.todos ?? []).map { item in
            Todo(
                title: item.title,
                due: item.due.flatMap { formatter.date(from: $0) ?? fallback.date(from: $0) }
            )
        }
        return Result(text: decoded.text, todos: todos)
    }
}
