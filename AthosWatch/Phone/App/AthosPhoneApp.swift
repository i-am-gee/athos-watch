import SwiftUI

@main
struct AthosPhoneApp: App {
    @StateObject private var store = PromiseStore()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .tint(Theme.accent)
        }
    }
}

struct RootTabView: View {
    /// 支持 -showReview 启动参数：模拟器里没法脚本点击 TabBar，
    /// 直接让复盘页成为首屏，截图和验收才有稳定的入口。
    @State private var selection = ProcessInfo.processInfo.arguments.contains("-showReview") ? 1 : 0

    var body: some View {
        TabView(selection: $selection) {
            PromiseHomeView()
                .tabItem { Label("答应了什么", systemImage: "checkmark.seal.fill") }
                .tag(0)

            ReviewView()
                .tabItem { Label("复盘", systemImage: "chart.bar.doc.horizontal") }
                .tag(1)
        }
    }
}
