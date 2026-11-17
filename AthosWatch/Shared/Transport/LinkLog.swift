import Foundation

/// 蓝牙链路的日志。
///
/// 模拟器上 `print` 抓不到（`simctl launch --console` 只回放系统日志），
/// 所以链路验证的每一步都写进各自容器里的 `Documents/link.log`，
/// 再用 `simctl get_app_container` 取出来对齐看。手表一份、手机一份，
/// 时间戳用的是同一个时钟，能直接拼成一条时间线。
enum LinkLog {

    static var fileURL: URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("link.log")
    }

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withFractionalSeconds, .withTimeZone]
        return formatter
    }()

    static func write(_ message: String) {
        let line = stamp.string(from: Date()) + "  " + message + "\n"
        guard let data = line.data(using: .utf8) else { return }

        // 不设上限的话，链路调试几天就能把日志写到几十兆，挤掉真正的录音
        if let size = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
           size > 512_000 {
            try? FileManager.default.removeItem(at: fileURL)
        }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: fileURL)
        }
    }

    static func read() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }
}
