import AVFoundation
import Foundation

/// 单段录音文件。使用 AAC 24 kbps 单声道，约 10.5 MB/小时。
/// 每段独立成文件，目的是让「崩溃 / 没电 / 被系统杀掉」最多只丢最后一段。
final class SegmentWriter {

    let url: URL
    let startedAt: Date
    private var file: AVAudioFile?
    private var scratch: AVAudioPCMBuffer?
    /// 攒批时长。每 20ms 直接调一次 AVAudioFile.write 会让 AAC 每包都带固定开销，
    /// 实测码率被顶到 60–80 kbps（配置是 24 kbps），存储成本翻两三倍。
    private let flushSeconds: Double = 0.5
    private(set) var framesWritten: AVAudioFramePosition = 0
    private let sampleRate: Double

    init(directory: URL, format: AVAudioFormat) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.startedAt = Date()
        self.sampleRate = format.sampleRate
        self.url = directory.appendingPathComponent(Self.fileName(for: startedAt, directory: directory))

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 24_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        self.file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.scratch = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(format.sampleRate * flushSeconds)
        )
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard file != nil,
              let source = buffer.floatChannelData?[0] else { return }

        framesWritten += AVAudioFramePosition(buffer.frameLength)

        guard let scratch,
              let destination = scratch.floatChannelData?[0] else { return }
        let capacity = Int(scratch.frameCapacity)
        let total = Int(buffer.frameLength)

        var offset = 0
        while offset < total {
            let used = Int(scratch.frameLength)
            let take = min(capacity - used, total - offset)
            guard take > 0 else { break }
            destination.advanced(by: used).update(from: source.advanced(by: offset), count: take)
            scratch.frameLength += AVAudioFrameCount(take)
            offset += take
            if Int(scratch.frameLength) >= capacity {
                flushScratch()
            }
        }
    }

    /// 把攒够的 PCM 一次性交给编码器
    private func flushScratch() {
        guard let file, let scratch, scratch.frameLength > 0 else { return }
        do {
            try file.write(from: scratch)
        } catch {
            // 写盘失败通常意味着磁盘满。保留已写内容，不再重试本次缓冲。
            self.file = nil
        }
        scratch.frameLength = 0
    }

    var duration: Double {
        sampleRate > 0 ? Double(framesWritten) / sampleRate : 0
    }

    /// 关闭文件并写一份 sidecar 元数据，便于后续上传时不必重新解封装读时长
    @discardableResult
    func close() -> SegmentInfo {
        flushScratch()
        file = nil
        // 摘掉 AVAudioFile 预留的 ~23KB free 原子，否则短句的存储开销会翻好几倍
        MP4Compactor.compact(url: url)
        let info = SegmentInfo(url: url, startedAt: startedAt, duration: duration, bytes: byteSize)
        SegmentInfo.writeSidecar(info)
        return info
    }

    private var byteSize: Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    /// 文件名精确到毫秒。只用秒会导致「切段恰好落在同一秒」时相互覆盖，
    /// 这在音频回放或高速灌数据时是真实发生的。
    private static func fileName(for date: Date, directory: URL) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let base = "seg-\(formatter.string(from: date))"
        var candidate = "\(base).m4a"
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(counter).m4a"
            counter += 1
        }
        return candidate
    }
}

struct SegmentInfo: Codable, Identifiable {
    var id: String { url.lastPathComponent }
    let url: URL
    let startedAt: Date
    let duration: Double
    let bytes: Int
    /// 没写完就被杀掉的分段：文件在、moov 没落盘，打不开也播不了，只能删
    var isDamaged: Bool = false

    /// sidecar 里**只存文件名**。曾经的实现存绝对路径，App 一重装容器 UUID 就变，
    /// 整库侧写文件全部指向已删除的目录——列表看着有 12 段，点进去一段都打不开。
    private enum CodingKeys: String, CodingKey {
        case fileName
        case startedAt
        case duration
        case bytes
        /// 兼容旧版本写入的绝对路径
        case url
    }

    static var directory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Segments", isDirectory: true)
    }

    init(url: URL, startedAt: Date, duration: Double, bytes: Int, isDamaged: Bool = false) {
        self.url = url
        self.startedAt = startedAt
        self.duration = duration
        self.bytes = bytes
        self.isDamaged = isDamaged
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name: String
        if let stored = try container.decodeIfPresent(String.self, forKey: .fileName) {
            name = stored
        } else {
            // 旧格式：拿到绝对路径，只保留文件名部分
            let legacy = try container.decode(String.self, forKey: .url)
            name = URL(string: legacy)?.lastPathComponent
                ?? URL(fileURLWithPath: legacy).lastPathComponent
        }
        self.url = Self.directory.appendingPathComponent(name)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.duration = try container.decode(Double.self, forKey: .duration)
        self.bytes = try container.decode(Int.self, forKey: .bytes)
        self.isDamaged = false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url.lastPathComponent, forKey: .fileName)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(duration, forKey: .duration)
        try container.encode(bytes, forKey: .bytes)
    }

    static func writeSidecar(_ info: SegmentInfo) {
        let sidecar = info.url.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? JSONEncoder().encode(info) else { return }
        try? data.write(to: sidecar, options: .atomic)
    }

    /// 文件名形如 seg-20261116-193459-258.m4a，解析出起始时间
    static func date(fromFileName name: String) -> Date? {
        let parts = name.split(separator: "-")
        guard parts.count >= 4 else { return nil }
        let stamp = "\(parts[1])-\(parts[2])-\(parts[3])"
        return fileNameFormatter.date(from: stamp)
    }

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()
}
