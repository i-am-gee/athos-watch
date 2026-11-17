import SwiftUI

/// 录音分段的浏览与试听。
/// 手表上原本没有任何看内容的入口，只能靠 Xcode 下载容器，
/// 这个页面就是补上「录完之后到底录到了什么」这一环。
struct SegmentsView: View {

    @StateObject private var store = SegmentStore()
    @StateObject private var player = SegmentPlayer()

    var body: some View {
        List {
            Section {
                Text("\(store.totalCount) 段 · \(RootView.formatDuration(store.totalDuration)) · \(Self.formatBytes(store.totalBytes))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if store.segments.isEmpty {
                Text("还没有录音。回到首页点中央那个圆球，说话后会自动生成分段。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(store.segments) { info in
                        Button {
                            guard !info.isDamaged else { return }
                            player.toggle(info.url)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: iconName(for: info))
                                    .font(.system(size: 16))
                                    .foregroundStyle(iconColor(for: info))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Self.timeText(info.startedAt))
                                        .font(.system(size: 12, weight: .medium))
                                    Text(subtitle(for: info))
                                        .font(.system(size: 10))
                                        .foregroundStyle(info.isDamaged ? .orange : .secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                if player.playingURL == info.url { player.stop() }
                                store.delete(info)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("最近 \(store.segments.count) 段")
                }

                if store.totalCount > store.segments.count {
                    Text("更早的 \(store.totalCount - store.segments.count) 段未在这里列出，请用电脑导出查看。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("录音")
        .onAppear { store.reload() }
        .onDisappear { player.stop() }
    }

    private func iconName(for info: SegmentInfo) -> String {
        if info.isDamaged { return "exclamationmark.triangle.fill" }
        return player.playingURL == info.url ? "stop.circle.fill" : "play.circle.fill"
    }

    private func iconColor(for info: SegmentInfo) -> Color {
        if info.isDamaged { return .orange }
        return player.playingURL == info.url ? .orange : .green
    }

    private func subtitle(for info: SegmentInfo) -> String {
        if info.isDamaged {
            return "未完成 · \(Self.formatBytes(info.bytes)) · 左滑删除"
        }
        return "\(String(format: "%.1f", info.duration))s · \(Self.formatBytes(info.bytes))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    static func timeText(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func formatBytes(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}
