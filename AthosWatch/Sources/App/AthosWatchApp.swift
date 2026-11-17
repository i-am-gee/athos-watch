import SwiftUI

@main
struct AthosWatchApp: App {

    #if DEBUG
    /// 模拟器自动化验证用：带 -openSegments 启动时直接进入录音列表，
    /// 省掉手动点击（simctl 没有点击接口）。
    private var opensSegments: Bool {
        ProcessInfo.processInfo.arguments.contains("-openSegments")
    }
    /// 同上，直接进「我答应了什么」，用于验收截图
    private var opensPromises: Bool {
        ProcessInfo.processInfo.arguments.contains("-openPromises")
    }
    #endif

    init() {
        // 必须在启动时就建起来。转写回调是在 WatchLedger 的 init 里挂到
        // WatchLink 上的——如果它一直没被创建（用户没点进「承诺」那一页），
        // 手机发回来的文本会被静默丢弃：手机显示「已确认」，手表这边一条承诺都没有。
        _ = WatchLedger.shared

        #if DEBUG
        // 链路自检：不依赖用户点任何东西，启动就把通道拉起来并补发积压的段。
        // 模拟器里没法保证 onAppear 的时机（界面可能立刻被系统挂起），
        // 所以这里显式重试几轮，每轮结果都写进 link.log。
        if ProcessInfo.processInfo.arguments.contains("-linkProbe") {
            Task { @MainActor in
                LinkLog.write("探针：启动")
                WatchLink.shared.activate()
                for round in 1...12 {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    let queued = WatchLink.shared.syncPending()
                    LinkLog.write("探针：第 \(round) 轮 queued=\(queued) pending=\(WatchLink.shared.pendingCount) reachable=\(WatchLink.shared.isReachable)")
                    WatchLedger.shared.push()
                }
            }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                RootView()
                #if DEBUG
                    .navigationDestination(isPresented: .constant(opensSegments)) {
                        SegmentsView()
                    }
                    .navigationDestination(isPresented: .constant(opensPromises)) {
                        PromisesView()
                    }
                #endif
            }
        }
    }
}
