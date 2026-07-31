import Foundation

/// 开机自启动：往 ~/Library/LaunchAgents 写一个 LaunchAgent 描述文件。
///
/// 没有用 SMAppService，是因为它要求 App 有正式的开发者签名；
/// 本地自己编译出来的 App 只有 ad-hoc 签名，LaunchAgent 这条路不挑签名，更稳。
enum LoginItem {
    static let label = "com.echos.mac"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// App 自身的路径。开发时直接跑可执行文件的情况也能兼容。
    private static var appPath: String {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" ? bundle.path : bundle.path
    }

    static func set(_ enabled: Bool) throws {
        let fm = FileManager.default
        let dir = plistURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        guard enabled else {
            if fm.fileExists(atPath: plistURL.path) {
                // 先从 launchd 卸载，再删文件，避免残留注册项
                _ = try? runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
                try fm.removeItem(at: plistURL)
            }
            return
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        // 立刻注册一次，这样不用等下次登录也能生效（已注册时报错可忽略）
        _ = try? runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}
