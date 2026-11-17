import SwiftUI

struct RootView: View {

    @StateObject private var controller = RecordingController()
    /// 盘上已有录音的总时长，口径与 `SegmentsView` 头部那行完全一致
    @StateObject private var library = SegmentStore()

    private var isRecording: Bool { controller.gateState == .recording }

    /// 三个字就能说完的状态，不需要更多
    private var statusText: String {
        if !controller.isRunning { return "待机" }
        return isRecording ? "记录中" : "在听"
    }

    /// 已入库的总时长 + 正在录但还没落盘的那一段。
    /// 不能只显示 `library.totalDuration`：录着的时候它两分钟才动一次，
    /// 会被当成卡死；也不能只显示本次会话，那会和列表头的数字对不上。
    private var displaySeconds: Double {
        library.totalDuration + (isRecording ? controller.segmentSeconds : 0)
    }

    var body: some View {
        // 必须用 GeometryReader 拿到真实尺寸再显式下发。直接把 ZStack 放在根上时，
        // 它拿到的是「未指定」高度提议，于是缩成内容高度、被根视图居中——Spacer
        // 一个点都分不到，底部入口就永远贴在时长下面（上一版「录音」被挤进可视区
        // 之外也是这个原因，当时靠调小字号绕过去了，其实没修到根）。
        GeometryReader { geo in
            ZStack {
                // 全屏底色跟着状态走，抬腕一眼就知道在不在录
                background

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

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

                    Text(ClockText.short(displaySeconds))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(durationColor)
                        .padding(.top, 1)
                        .accessibilityLabel("已录 \(ClockText.short(displaySeconds))")

                    Spacer(minLength: 0)

                    // 两个入口并排。左「承诺」是产品的主问题（我答应了什么），
                    // 右「录音」是原始素材——日常只点左边，出问题才翻右边。
                    HStack(spacing: 16) {
                        NavigationLink {
                            PromisesView()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.seal")
                                    .font(.system(size: 11))
                                Text("承诺")
                                    .font(.system(size: 11))
                            }
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            SegmentsView()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 11))
                                Text("录音")
                                    .font(.system(size: 11))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(.white.opacity(0.4))
                    .tint(.white.opacity(0.4))
                    .padding(.bottom, 3)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .ignoresSafeArea()
        // 新段落盘后重算总量；从列表页返回时也重算一次（那里可能删过段）
        .onAppear {
            library.reload()
            // 蓝牙通道在这里激活：主屏是唯一必然被创建过的视图，
            // 放这里能保证「录完就发」不需要用户额外点任何东西。
            WatchLink.shared.activate()
        }
        .onChange(of: controller.segmentCount) { _, _ in
            library.reload()
            // 每收一段就往手机丢一段。发不出去也没关系，
            // syncPending 会把没送达的留到下次一起补。
            WatchLink.shared.syncPending()
        }
        .alert("提示", isPresented: alertBinding) {
            Button("知道了", role: .cancel) { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    private var durationColor: Color {
        if !controller.isRunning { return .white.opacity(0.32) }
        return isRecording
            ? Color(red: 0.30, green: 0.92, blue: 0.55)
            : Color(red: 0.35, green: 0.82, blue: 0.95).opacity(0.75)
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
