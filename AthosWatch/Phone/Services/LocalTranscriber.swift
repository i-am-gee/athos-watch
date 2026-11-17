import Foundation
import Speech

/// 手机侧的系统语音识别。
///
/// 为什么转写只能在手机上做：watchOS 27.2 SDK 里根本没有 `Speech.framework`
/// （`ls .../WatchOS27.2.sdk/System/Library/Frameworks | grep Speech` 无输出），
/// 所以「手表自己把声音变成字」在系统层面不成立。这不是取舍，是边界。
///
/// 用 `SFSpeechRecognizer` 而不是 iOS 26 新的 `SpeechAnalyzer`：
/// 前者在 iOS 27 头文件里仍是 `API_AVAILABLE(ios(10.0))`、未标弃用，
/// 且 `requiresOnDeviceRecognition` 这条路径成熟、不需要先下载语言资产。
/// 等这条链路稳定了再换 `SpeechAnalyzer` 换取更好的长音频与标点。
@MainActor
enum LocalTranscriber {

    /// 复用同一个识别器实例。
    ///
    /// 每段都新建 `SFSpeechRecognizer` 会踩到一个很难查的坑：
    /// 前一个实例还持有着底层资源时，新实例的 task 会直接报
    /// 「Failed to initialize recognizer」——错误发生在 task 启动瞬间，
    /// 看起来像权限问题，其实是实例竞争。
    private static var shared: SFSpeechRecognizer?

    private static func recognizer(_ locale: Locale) -> SFSpeechRecognizer? {
        if let shared, shared.locale == locale { return shared }
        let made = SFSpeechRecognizer(locale: locale)
        shared = made
        return made
    }

    struct Sentence {
        let text: String
        /// 这句话在音频里的起点（秒）。来自 `SFTranscriptionSegment.timestamp`，
        /// 不是按字数估的——首页那个播放键要靠它真的跳到正确位置。
        let start: Double
        let duration: Double
    }

    struct Outcome {
        let sentences: [Sentence]
        let engine: String
    }

    enum TranscribeError: LocalizedError {
        case unauthorized
        case unavailable
        case noSpeech
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .unauthorized: return "语音识别权限被拒绝"
            case .unavailable: return "这台设备的语音识别暂时不可用"
            case .noSpeech: return "这段音频里没识别出文字"
            case .failed(let reason): return "识别失败：\(reason)"
            }
        }
    }

    // MARK: 权限

    static func requestAuthorization() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        switch current {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    // MARK: 转写

    static func transcribe(url: URL, locale: Locale = Locale(identifier: "zh-CN")) async throws -> Outcome {
        guard await requestAuthorization() else { throw TranscribeError.unauthorized }

        // 一次失败就重试一次。系统识别器偶尔会在上一个 task 的资源
        // 还没回收时直接报「Failed to initialize recognizer」，
        // 隔不到一秒再来一次就好了——这种失败不该让用户看到「转写失败」。
        var lastError: Error = TranscribeError.unavailable
        for attempt in 1...2 {
            do {
                return try await run(url: url, locale: locale)
            } catch {
                lastError = error
                if attempt == 1 {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
            }
        }
        throw lastError
    }

    private static func run(url: URL, locale: Locale) async throws -> Outcome {
        guard let recognizer = recognizer(locale), recognizer.isAvailable else {
            throw TranscribeError.unavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        // 语记类的短句用 dictation 更准；不要用 .search，那会把
        // 「我周五前把报价发给小李」里的时间词当搜索关键词砍掉。
        request.taskHint = .dictation
        request.addsPunctuation = true

        // 设备上能跑就在设备上跑：录音不出手机。跑不了才退到系统服务，
        // 并在结果里如实标出来——engine 字段就是给排查用的。
        let onDevice = recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = onDevice
        let engine = onDevice ? "on-device" : "server"

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFSpeechRecognitionResult, Error>) in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result)
                    return
                }
                if let error {
                    resumed = true
                    continuation.resume(throwing: TranscribeError.failed(error.localizedDescription))
                }
            }
        }

        let sentences = group(result.bestTranscription.segments)
        guard !sentences.isEmpty else { throw TranscribeError.noSpeech }
        return Outcome(sentences: sentences, engine: engine)
    }

    // MARK: 聚句

    /// `SFTranscriptionSegment` 在中文里是按词（甚至单字）切的，
    /// 直接把每个 segment 当成一句话，会得到「我 / 周五 / 前 / 把 / 报价 / 发给 / 小李」，
    /// 承诺解析器一句都认不出来。所以这里按停顿和标点重新聚成句子。
    private static func group(_ segments: [SFTranscriptionSegment]) -> [Sentence] {
        guard !segments.isEmpty else { return [] }

        var result: [Sentence] = []
        var buffer = ""
        var start: Double = segments[0].timestamp
        var end: Double = start

        func flush() {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result.append(Sentence(text: text, start: start, duration: max(0.2, end - start)))
            }
            buffer = ""
        }

        for (index, segment) in segments.enumerated() {
            if buffer.isEmpty { start = segment.timestamp }
            buffer += segment.substring
            end = segment.timestamp + segment.duration

            let next = index + 1 < segments.count ? segments[index + 1] : nil
            // 三种断句：句末标点、明显停顿、已经太长
            let endsSentence = segment.substring.last.map { "。！？!?…；;".contains($0) } ?? false
            let longPause = next.map { $0.timestamp - end > 0.55 } ?? false
            let tooLong = buffer.count > 40

            if endsSentence || longPause || tooLong || next == nil {
                // 标点本身留在句子里，承诺解析器靠它判断疑问句
                flush()
            } else if needsSpace(buffer, segment.substring) {
                buffer += " "
            }
        }

        flush()
        return result
    }

    /// 中文按词拼不加空格，英文单词之间要加，否则 "send the quote" 会粘成
    /// "sendthequote"，承诺解析器里的动词表就一个都匹配不上。
    private static func needsSpace(_ buffer: String, _ next: String) -> Bool {
        guard let last = buffer.unicodeScalars.last, let first = next.unicodeScalars.first else { return false }
        return !isCJK(last) && !isCJK(first)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value)
            || (0x3000...0x303F).contains(scalar.value)
            || (0xFF00...0xFFEF).contains(scalar.value)
    }
}
