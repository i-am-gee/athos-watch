import SwiftUI

struct RootView: View {

    @StateObject private var controller = RecordingController()

    private var isRecording: Bool { controller.gateState == .recording }

    /// 三个字就能说完的状态，不需要更多
    private var statusText: String {
        if !controller.isRunning { return "待机" }
        return isRecording ? "记录中" : "在听"
    }

    var body: some View {
        ZStack {
            // 全屏底色跟着状态走，抬腕一眼就知道在不在录
            background

            VStack(spacing: 0) {
                SonicOrbView(
                    isRunning: controller.isRunning,
                    isRecording: isRecording,
                    levelDBFS: controller.levelDBFS,
                    segmentProgress: min(1, controller.segmentSeconds / 120)
                )
                .frame(width: 154, height: 154)
                .contentShape(Circle())
                .onTapGesture { controller.toggle() }
                .accessibilityLabel(controller.isRunning ? "停止记录" : "开始监听")
                .accessibilityAddTraits(.isButton)

                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .tracking(3)
                    .foregroundStyle(controller.isRunning ? .white.opacity(0.85) : .white.opacity(0.4))
                    .padding(.top, 2)

                Spacer(minLength: 0)

                NavigationLink {
                    SegmentsView()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11))
                        Text("录音")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .tint(.white.opacity(0.4))
            }
            .padding(.vertical, 6)
        }
        .ignoresSafeArea()
        .alert("提示", isPresented: alertBinding) {
            Button("知道了", role: .cancel) { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    private var background: some View {
        // 待机深灰、监听得偏青、记录中偏绿——颜色比文字先到眼睛
        LinearGradient(
            colors: {
                if !controller.isRunning {
                    return [Color(white: 0.10), Color.black]
                }
                return isRecording
                    ? [Color(red: 0.02, green: 0.14, blue: 0.09), Color.black]
                    : [Color(red: 0.02, green: 0.09, blue: 0.13), Color.black]
            }(),
            startPoint: .top,
            endPoint: .bottom
        )
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
