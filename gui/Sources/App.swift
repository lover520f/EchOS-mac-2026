import SwiftUI
import AppKit

@main
struct ECHApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("EchOS") {
            ContentView()
                .environmentObject(app)
                .onAppear {
                    delegate.state = app
                    app.applyDockIconPolicy()
                    app.flushPendingLogs()
                }
        }
        .defaultSize(width: 790, height: 910)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var state: AppState? {
        didSet {
            guard let state, !statusBarInstalled else { return }
            statusBarInstalled = true
            statusBar.install(state: state)
        }
    }
    private let statusBar = StatusBarController()
    private var statusBarInstalled = false

    // 在窗口出现前读取配置，设好激活策略，避免 dock 图标闪一下或关不掉
    func applicationWillFinishLaunching(_ notification: Notification) {
        let cfg = AppConfig.load()
        if !cfg.showDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI 在纯 swiftc 构建（没有 Xcode 工程）下有时会把窗口收成很小一块，
        // 这里在主窗口出现后按内容需要的尺寸强制铺开并居中。
        DispatchQueue.main.async {
            guard let win = NSApp.windows.first(where: { $0.contentView != nil }) else { return }
            // 只定宽度和最小尺寸；高度交给 ContentView 的 syncWindowHeight
            // 按当前内容算，免得两处各设一套值互相覆盖
            win.setContentSize(NSSize(width: 790, height: 762))
            win.minSize = NSSize(width: 720, height: 762)
            win.center()
            win.makeKeyAndOrderFront(nil)
            // 内容区顶部已经有居中的 EchOS 标题，标题栏再显示一次就重复了
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
        }
    }

    // 关窗口不退出：代理继续在后台跑，靠菜单栏图标控制
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // 退出前一定要把系统代理还原回去，否则用户会"断网"
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { state?.shutdown() }
    }
}
