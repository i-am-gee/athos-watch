import Foundation

/// 时长 → 主屏上那个走秒的数。
///
/// 为什么和列表头不一样：`SegmentsView` 头部那行是汇总读数（`12′34″`），
/// 一眼扫过就行；主屏这个是计时器，`12:34` 更像秒表直觉，配合
/// `.monospacedDigit()` 每秒跳动时宽度也不会抖。
///
/// 纯函数，`make gate` 里直接断言，不需要起模拟器。
enum ClockText {

    /// 秒 → `mm:ss`，满一小时变 `h:mm:ss`。
    ///
    /// 负数、NaN、无穷一律归零：这个数来自音频帧计数和文件时长之和，
    /// 真出了异常宁可显示 `00:00`，也不要在表盘上闪出 `nan` 或一长串负号。
    static func short(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
