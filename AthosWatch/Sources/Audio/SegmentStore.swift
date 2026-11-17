import AVFoundation
import Foundation

/// 读取并管理 Documents/Segments 下的录音分段。
/// 只依赖 sidecar JSON，不读音频本身，所以列表刷新很便宜。
@MainActor
final class SegmentStore: ObservableObject {

    @Published private(set) var segments: [SegmentInfo] = []
    @Published private(set) var totalBytes: Int = 0
    @Published private(set) var totalDuration: Double = 0
    /// 目录里到底有多少文件（可能远多于列表展示条数）
    @Published private(set) var totalCount: Int = 0

    /// 一次最多列多少条。手表屏幕滚动几十条已经是极限，也避免卡顿。
    let displayLimit = 60

    let directory: URL

    init() {
        directory = SegmentInfo.directory
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []

        // 以音频文件本身为准，而不是以 sidecar 为准。
        // 反面教材：App 被强杀时最后一段的 json 根本没写出来，只读 json 会让这段
        // 29KB 的残废文件在界面上完全消失——用户既看不到也删不掉，只能等它占空间。
        let audioFiles = files
            .filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }

        let decoder = JSONDecoder()
        var entries: [SegmentInfo] = []
        var bytes = 0
        var seconds = 0.0

        for url in audioFiles {
            let sidecar = url.deletingPathExtension().appendingPathExtension("json")
            var info: SegmentInfo

            if let data = try? Data(contentsOf: sidecar),
               let decoded = try? decoder.decode(SegmentInfo.self, from: data) {
                info = decoded
            } else {
                // 没有元数据：从文件名取时间，从文件本身验证可读性
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let started = SegmentInfo.date(fromFileName: url.lastPathComponent)
                    ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? Date(timeIntervalSince1970: 0)
                let readable = (try? AVAudioFile(forReading: url)).map { file in
                    Double(file.length) / file.processingFormat.sampleRate
                }
                info = SegmentInfo(
                    url: url,
                    startedAt: started,
                    duration: readable ?? 0,
                    bytes: size,
                    isDamaged: readable == nil
                )
            }

            bytes += info.bytes
            seconds += info.duration
            if entries.count < displayLimit {
                entries.append(info)
            }
        }

        totalCount = audioFiles.count
        totalBytes = bytes
        totalDuration = seconds
        // 损坏段置顶：它占空间、播不了、只能靠左滑删，埋在一堆正常段中间等于没人发现
        segments = entries.sorted {
            if $0.isDamaged != $1.isDamaged { return $0.isDamaged }
            return $0.startedAt > $1.startedAt
        }
    }

    var damagedCount: Int {
        segments.filter(\.isDamaged).count
    }

    /// 删除一段：音频和 sidecar 一起清掉，避免列表与磁盘不一致
    func delete(_ info: SegmentInfo) {
        try? FileManager.default.removeItem(at: info.url)
        let sidecar = info.url.deletingPathExtension().appendingPathExtension("json")
        try? FileManager.default.removeItem(at: sidecar)
        reload()
    }

    func deleteDamaged() {
        for info in segments where info.isDamaged { delete(info) }
    }

    func deleteAll() {
        for info in segments { delete(info) }
    }
}

/// 试听：手表扬声器或已连接的蓝牙耳机。
@MainActor
final class SegmentPlayer: NSObject, ObservableObject {

    @Published private(set) var playingURL: URL?

    private var player: AVAudioPlayer?

    func toggle(_ url: URL) {
        if playingURL == url {
            stop()
            return
        }
        stop()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
        guard let created = try? AVAudioPlayer(contentsOf: url) else { return }
        created.delegate = self
        created.play()
        player = created
        playingURL = url
    }

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

extension SegmentPlayer: AVAudioPlayerDelegate {}
