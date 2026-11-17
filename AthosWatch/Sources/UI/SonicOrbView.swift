import SwiftUI

/// 主视觉：一圈随声音起伏的声波，中心是唯一的操作按钮。
///
/// 设计取舍：这个视图内部不带任何数字——占空比、段数、实时电平这些是开发期指标，
/// 对「我到底在不在录」毫无帮助，却会占掉 46mm 屏一半面积。
/// 状态只用两样东西表达：颜色和呼吸。唯一被允许留在主屏的数字是录音时长，
/// 由 `RootView` 渲染在球下方，不归这里管。
struct SonicOrbView: View {

    let isRunning: Bool
    let isRecording: Bool
    let levelDBFS: Float
    /// 当前分段进度 0…1，用来画外圈那根弧
    let segmentProgress: Double
    /// 表盘常亮（AOD）时降低亮度并停掉动画，避免整夜耗电
    @Environment(\.isLuminanceReduced) private var dimmed

    private let barCount = 48
    private let radius: CGFloat = 52

    /// -60…0 dBFS → 0…1，低于 -60 视为无声
    private var intensity: Double {
        guard isRunning else { return 0 }
        let clamped = min(max(levelDBFS, -60), 0)
        return Double((clamped + 60) / 60)
    }

    private var accent: Color {
        if !isRunning { return Color(white: 0.55) }
        return isRecording ? Color(red: 0.30, green: 0.92, blue: 0.55) : Color(red: 0.35, green: 0.82, blue: 0.95)
    }

    /// 每根短棒的固有权重。固定 seed 保证每次渲染同一形状——
    /// 全用同一个长度会变成一圈均匀刻度，像一个加载指示器，很廉价。
    private let weights: [Double] = (0..<48).map { index in
        let x = sin(Double(index) * 12.9898) * 43758.5453
        return 0.35 + (x - floor(x)) * 0.65
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: dimmed ? 1 : 1.0 / 30.0, paused: dimmed)) { context in
            let t = dimmed ? 0 : context.date.timeIntervalSinceReferenceDate

            ZStack {
                glow(t: t)
                bars(t: t)
                progressArc
                core
            }
        }
        .compositingGroup()
        .animation(.easeOut(duration: 0.12), value: levelDBFS)
        .animation(.easeInOut(duration: 0.4), value: isRecording)
        .animation(.easeInOut(duration: 0.4), value: isRunning)
    }

    // MARK: 光晕

    private func glow(t: TimeInterval) -> some View {
        // 记录中是快脉冲，仅监听时是极慢的呼吸，待机时几乎不动
        let breath: Double = {
            if !isRunning { return 0.10 }
            let speed = isRecording ? 2.4 : 0.6
            let wave = sin(t * speed) * 0.5 + 0.5
            return isRecording ? 0.30 + wave * 0.45 : 0.16 + wave * 0.18
        }()

        return Circle()
            .fill(accent)
            .frame(width: 120, height: 120)
            .blur(radius: 26)
            .opacity(dimmed ? breath * 0.4 : breath * (0.35 + intensity * 0.65))
            .scaleEffect(1 + intensity * 0.22)
    }

    // MARK: 环形声波

    private func bars(t: TimeInterval) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(isRunning ? 0.07 : 0.05), lineWidth: 0.8)

            ForEach(0..<barCount, id: \.self) { index in
                let angle = Double(index) / Double(barCount) * 360
                // 每个方向错开相位，整圈才会「流动」而不是同涨同落
                let phase = t * 2.6 + Double(index) * 0.48
                let jitter = sin(phase) * 0.5 + 0.5
                let weight = weights[index % weights.count]
                let height = 2.5 + intensity * 17 * weight * (0.55 + jitter * 0.45)

                Capsule()
                    .fill(accent.opacity(isRunning ? 0.45 + weight * 0.5 : 0.20))
                    .frame(width: 2.4, height: height)
                    .offset(y: -(radius + height / 2) + 8)
                    .rotationEffect(.degrees(angle))
            }
        }
        // 记录时整圈极轻微的转动，像在扫描
        .rotationEffect(isRecording && !dimmed ? .degrees(sin(t * 1.2) * 3) : .zero)
    }

    // MARK: 分段进度弧

    private var progressArc: some View {
        Circle()
            .trim(from: 0, to: isRecording ? max(0.002, segmentProgress) : 0)
            .stroke(
                accent.opacity(0.9),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .frame(width: 66, height: 66)
            .rotationEffect(.degrees(-90))
    }

    // MARK: 中心按钮

    private var core: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.17), Color(white: 0.05)],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: 40
                    )
                )
                .overlay(
                    Circle().stroke(
                        LinearGradient(
                            colors: [accent.opacity(0.85), accent.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.4
                    )
                )
                .frame(width: 62, height: 62)

            Image(systemName: isRunning ? "stop.fill" : "waveform")
                .font(.system(size: isRunning ? 17 : 24, weight: .semibold))
                .foregroundStyle(isRunning ? accent : Color(white: 0.82))
                .contentTransition(.symbolEffect(.replace))
        }
    }
}
