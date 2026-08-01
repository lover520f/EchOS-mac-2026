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
                    app.checkForUpdatesAtStartup()
                }
        }
        .defaultSize(width: 735, height: 758)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
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
        NSApp.setActivationPolicy(cfg.showDockIcon ? .regular : .accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI 在纯 swiftc 构建（没有 Xcode 工程）下有时会把窗口收成很小一块，
        // 这里在主窗口出现后按内容需要的尺寸强制铺开并居中。
        DispatchQueue.main.async {
            guard let win = NSApp.windows.first(where: { $0.contentView != nil }) else { return }
            // 只定宽度和最小尺寸；高度交给 ContentView 的 syncWindowHeight
            // 按当前内容算，免得两处各设一套值互相覆盖
            win.setContentSize(NSSize(width: 735, height: 774))
            // minSize 只挡"窗口被拖得太小"：拉到 758（规则收起时内容所需高度）
            // 就停，底部操作行和日志不会被窗口底边盖住
            win.minSize = NSSize(width: 735, height: 758)
            win.delegate = self
            win.center()
            win.makeKeyAndOrderFront(nil)
            // 内容区顶部已经有居中的 EchOS 标题，标题栏再显示一次就重复了
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
        }
    }

    /// ContentView 算出的内容所需高度。窗口手动缩放时不能比它矮，
    /// 否则底部操作行和日志会被窗口底边盖住。
    static var minContentHeight: CGFloat = 758

    // 拖拽窗口时强制高度不能低于内容所需高度（minSize 之外的兜底）
    @objc func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let floor = max(Self.minContentHeight, sender.minSize.height)
        guard frameSize.height < floor - 0.5 else { return frameSize }
        var s = frameSize
        s.height = floor
        return s
    }

    // 移动/缩放窗口时，底边不许越过可见区域底部（否则日志会被 Dock 遮住）
    @objc func windowDidMove(_ notification: Notification) { clampBottom(notification.object as? NSWindow) }
    @objc func windowDidResize(_ notification: Notification) { clampBottom(notification.object as? NSWindow) }

    private func clampBottom(_ win: NSWindow?) {
        guard let win, let screen = win.screen else { return }
        let minY = screen.visibleFrame.minY
        guard win.frame.minY < minY - 0.5 else { return }
        var f = win.frame
        f.origin.y = minY
        win.setFrame(f, display: true)
    }

    // 关窗口不退出：代理继续在后台跑，靠菜单栏图标控制
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // 点红色关闭按钮：只隐藏窗口，不销毁。
    // 若真的 close，SwiftUI 的 WindowGroup 会在 App 被激活时（比如点菜单栏
    // 「检查更新」）自动把主窗口恢复出来，弹独立更新对话框时就会多带出主页面。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // 退出前一定要把系统代理还原回去，否则用户会"断网"
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { state?.shutdown() }
    }
}
