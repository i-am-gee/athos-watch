import SwiftUI

struct RootView: View {

    @StateObject private var controller = RecordingController()

    private var isRecording: Bool { controller.gateState == .recording }

    var body: some View {
        ScrollView {
            VStack(spacing: 3) {
                StatusDialView(
                    isRunning: controller.isRunning,
                    isRecording: isRecording,
                    levelDBFS: controller.levelDBFS
                )

                LevelMeterView(
                    levelDBFS: controller.levelDBFS,
                    noiseFloorDBFS: controller.noiseFloorDBFS,
                    openThresholdDBFS: controller.openThresholdDBFS
                )

                HStack(spacing: 4) {
                    MetricCell(label: "占空比", value: String(format: "%.0f%%", controller.dutyCycle * 100))
                    MetricCell(label: "已录", value: Self.formatDuration(controller.recordedSeconds))
                    MetricCell(label: "段数", value: "\(controller.segmentCount)")
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))

                if controller.droppedBuffers > 0 {
                    Text("已丢弃 \(controller.droppedBuffers) 个缓冲（磁盘写入跟不上）")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }

                Button {
                    controller.toggle()
                } label: {
                    Label(
                        controller.isRunning ? "停止" : "开始监听",
                        systemImage: controller.isRunning ? "stop.fill" : "mic.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .tint(controller.isRunning ? .red : .green)

                HStack(spacing: 8) {
                    NavigationLink {
                        SegmentsView()
                    } label: {
                        Label("录音", systemImage: "waveform")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.5))

                    NavigationLink {
                        SettingsView(controller: controller)
                    } label: {
                        Label("阈值", systemImage: "slider.horizontal.3")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
        }
        .containerBackground(Color.black, for: .navigation)
        .alert("提示", isPresented: alertBinding) {
            Button("知道了", role: .cancel) { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { controller.errorMessage != nil },
            set: { if !$0 { controller.errorMessage = nil } }
        )
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        return minutes > 0 ? "\(minutes)′\(remainder)″" : "\(remainder)″"
    }
}

struct SettingsView: View {

    @ObservedObject var controller: RecordingController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("开场阈值")
                        .font(.system(size: 12, weight: .medium))
                    Text("高于噪声底 \(Int(controller.sensitivityOffsetDB)) dB")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("转动表冠调节。调低更灵敏，但会录进更多噪声、更费电。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 3) {
                    Text("收场驻留 \(String(format: "%.1f", controller.closeDwellSeconds)) 秒")
                        .font(.system(size: 12, weight: .medium))
                    Stepper("", value: $controller.closeDwellSeconds, in: 0.5...6, step: 0.5)
                        .labelsHidden()
                    Text("停顿短于该值不会切段。调大减少碎片，但会增加占空比。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("实时估算")
                        .font(.system(size: 12, weight: .medium))
                    row("当前噪声底", String(format: "%.0f dBFS", controller.noiseFloorDBFS))
                    row("当前门限", String(format: "%.0f dBFS", controller.openThresholdDBFS))
                    row("占空比", String(format: "%.0f%%", controller.dutyCycle * 100))
                    row("功耗估算", String(format: "%.2f%%/h", controller.estimatedPctPerHour))
                }
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("参数")
        .digitalCrownRotation(
            $controller.sensitivityOffsetDB,
            from: 6,
            through: 24,
            by: 1,
            sensitivity: .low,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
        }
    }
}
