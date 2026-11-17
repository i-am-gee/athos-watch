import SwiftUI

struct LevelMeterView: View {

    var levelDBFS: Float
    var noiseFloorDBFS: Float
    var openThresholdDBFS: Float

    /// 把 -80…0 dBFS 映射到 0…1，低于 -80 一律压到底
    private func normalized(_ db: Float) -> Double {
        let clamped = min(max(db, -80), 0)
        return Double((clamped + 80) / 80)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let active = levelDBFS >= openThresholdDBFS

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))

                // 电平接近静音底时不画填充，避免在左端留下一个无意义的小色块
                if levelDBFS > -72 {
                    Capsule()
                        .fill(active ? Color.green : Color.white.opacity(0.4))
                        .frame(width: max(3, width * normalized(levelDBFS)))
                }

                Rectangle()
                    .fill(Color.cyan.opacity(0.9))
                    .frame(width: 1.5, height: 16)
                    .offset(x: min(width - 2, width * normalized(noiseFloorDBFS)))

                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 2, height: 18)
                    .offset(x: min(width - 2, max(0, width * normalized(openThresholdDBFS))))
            }
        }
        .frame(height: 18)
    }
}

struct StatusDialView: View {

    var isRunning: Bool
    var isRecording: Bool
    var levelDBFS: Float

    private var ringColor: Color {
        if !isRunning { return .white.opacity(0.25) }
        return isRecording ? .green : .orange
    }

    private var caption: String {
        if !isRunning { return "待机" }
        return isRecording ? "写盘中" : "监听中"
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 7)

            Circle()
                .trim(from: 0, to: max(0.02, CGFloat(min(max((levelDBFS + 80) / 80, 0), 1))))
                .stroke(ringColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))

            VStack(spacing: 1) {
                Text(caption)
                    .font(.system(size: 14, weight: .medium))
                Text(String(format: "%.0f dBFS", levelDBFS))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 64)
        .animation(.easeOut(duration: 0.12), value: levelDBFS)
        .animation(.easeInOut(duration: 0.2), value: isRecording)
    }
}

struct MetricCell: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
