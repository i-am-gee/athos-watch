import SwiftUI

@main
struct AthosWatchApp: App {

    #if DEBUG
    /// 模拟器自动化验证用：带 -openSegments 启动时直接进入录音列表，
    /// 省掉手动点击（simctl 没有点击接口）。
    private var opensSegments: Bool {
        ProcessInfo.processInfo.arguments.contains("-openSegments")
    }
    #endif

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                RootView()
                #if DEBUG
                    .navigationDestination(isPresented: .constant(opensSegments)) {
                        SegmentsView()
                    }
                #endif
            }
        }
    }
}
