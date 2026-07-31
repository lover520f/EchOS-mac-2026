import Foundation

/// 一个网络服务（Wi-Fi / Ethernet ...）上三类代理的原始状态
struct ProxyBackup: Codable {
    struct Entry: Codable {
        var enabled: Bool = false
        var server: String = ""
        var port: Int = 0
    }
    var service: String
    var web: Entry = Entry()        // HTTP
    var secureWeb: Entry = Entry()  // HTTPS
    var socks: Entry = Entry()      // SOCKS
}

/// 用 networksetup 接管 / 还原 macOS 系统代理，替代 v2rayN 的「自动配置系统代理」。
///
/// 设计上把"还原"看得比"接管"更重要：备份在接管前写入 UserDefaults，
/// 即使 App 崩溃或被强杀，下次启动也能把用户原来的代理设置还原回去。
enum SystemProxy {
    private static let tool = "/usr/sbin/networksetup"
    private static let backupKey = "SystemProxyBackup"
    private static let activeKey = "SystemProxyActive"

    /// 当前是否处于"已接管"状态（跨进程持久，用于崩溃后自愈）
    static var isActive: Bool {
        get { UserDefaults.standard.bool(forKey: activeKey) }
        set { UserDefaults.standard.set(newValue, forKey: activeKey) }
    }

    @discardableResult
    private static func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let edata = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: edata, encoding: .utf8) ?? ""
            let sout = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "SystemProxy", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                            "networksetup \(args.joined(separator: " ")) 失败: \(msg.isEmpty ? sout : msg)"])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 所有已启用的网络服务（跳过名字前带 * 的禁用项）
    static func networkServices() throws -> [String] {
        let out = try run(["-listallnetworkservices"])
        return out.split(separator: "\n").dropFirst()   // 第一行是说明文字
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    private static func parseEntry(_ text: String) -> ProxyBackup.Entry {
        var e = ProxyBackup.Entry()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Enabled": e.enabled = (parts[1].lowercased() == "yes")
            case "Server":  e.server = parts[1]
            case "Port":    e.port = Int(parts[1]) ?? 0
            default: break
            }
        }
        return e
    }

    static func readBackup() throws -> [ProxyBackup] {
        var result: [ProxyBackup] = []
        for svc in try networkServices() {
            var b = ProxyBackup(service: svc)
            b.web = parseEntry((try? run(["-getwebproxy", svc])) ?? "")
            b.secureWeb = parseEntry((try? run(["-getsecurewebproxy", svc])) ?? "")
            b.socks = parseEntry((try? run(["-getsocksfirewallproxy", svc])) ?? "")
            result.append(b)
        }
        return result
    }

    /// 接管系统代理。socks / http 任一为 nil 表示该类型不接管。
    /// 返回过程中的提示信息（例如某个网络服务设置失败）。
    static func enable(socks: (host: String, port: Int)?,
                       http: (host: String, port: Int)?) throws -> [String] {
        guard socks != nil || http != nil else {
            throw NSError(domain: "SystemProxy", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "监听地址里没有可用的 socks5/http 端口，无法接管系统代理"])
        }

        // 只在尚未接管时备份，避免把我们自己设的值覆盖掉用户的原始设置。
        // 但如果标记说"已接管"而备份却不见了（配置被清过、换过机器），
        // 那就必须补一次备份，否则待会儿还原时无据可依。
        let hasBackup = UserDefaults.standard.data(forKey: backupKey) != nil
        if !isActive || !hasBackup {
            let backup = try readBackup()
            guard !backup.isEmpty else {
                throw NSError(domain: "SystemProxy", code: -2, userInfo: [
                    NSLocalizedDescriptionKey: "读不到当前网络设置，为安全起见没有接管系统代理"])
            }
            if let data = try? JSONEncoder().encode(backup) {
                UserDefaults.standard.set(data, forKey: backupKey)
                UserDefaults.standard.synchronize()
            }
        }

        var warnings: [String] = []
        let services = try networkServices()
        guard !services.isEmpty else {
            throw NSError(domain: "SystemProxy", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "读不到任何网络服务，无法设置系统代理"])
        }

        for svc in services {
            do {
                if let s = socks {
                    try run(["-setsocksfirewallproxy", svc, s.host, String(s.port)])
                    try run(["-setsocksfirewallproxystate", svc, "on"])
                }
                if let h = http {
                    try run(["-setwebproxy", svc, h.host, String(h.port)])
                    try run(["-setwebproxystate", svc, "on"])
                    try run(["-setsecurewebproxy", svc, h.host, String(h.port)])
                    try run(["-setsecurewebproxystate", svc, "on"])
                }
            } catch {
                warnings.append("网络服务「\(svc)」设置失败：\(error.localizedDescription)")
            }
        }

        // 读回验证。networksetup 有可能返回成功却什么也没改（权限被拦、
        // 服务列表为空等），只信返回码的话，日志会报"已接管"而浏览器
        // 其实根本没走代理 —— 用户看到的就是"软件说好了但打不开网页"。
        let after = (try? readBackup()) ?? []
        let applied = after.contains { b in
            if let s = socks { return b.socks.enabled && b.socks.server == s.host && b.socks.port == s.port }
            if let h = http { return b.web.enabled && b.web.server == h.host && b.web.port == h.port }
            return false
        }
        guard applied else {
            isActive = false
            throw NSError(domain: "SystemProxy", code: -4, userInfo: [
                NSLocalizedDescriptionKey: "系统代理设置没有生效（命令已执行但设置未改变）。请到「系统设置 → 网络 → 详细信息 → 代理」手动把 SOCKS 代理设为 \(socks.map { "\($0.host):\($0.port)" } ?? "本地端口")"])
        }

        isActive = true
        return warnings
    }

    /// 还原到接管之前的状态。
    ///
    /// 关键：没有备份时**什么都不做**。早先这里会退化成"把所有代理关掉"，
    /// 结果在标记与备份不一致的情况下（比如标记还在、备份已丢），
    /// 直接把用户自己配的代理给关了 —— 用户的感受就是莫名其妙断网。
    /// 宁可留着不动，也不能拿用户的网络设置去赌。
    @discardableResult
    static func restore() -> [String] {
        var warnings: [String] = []
        guard let data = UserDefaults.standard.data(forKey: backupKey),
              let backups = try? JSONDecoder().decode([ProxyBackup].self, from: data),
              !backups.isEmpty else {
            isActive = false
            return ["没有找到接管前的备份，为避免误改，本次没有改动任何系统代理设置。"]
        }

        for b in backups {
            func apply(_ e: ProxyBackup.Entry, set: String, state: String) {
                do {
                    // 地址必须无条件写回：哪怕这项原本是关着的，也不能把我们的
                    // 30000/30001 留在里面 —— 否则用户哪天手动打开代理，
                    // 连的是一个早就没人监听的端口，排查起来毫无头绪。
                    if !e.server.isEmpty && e.port > 0 {
                        try run([set, b.service, e.server, String(e.port)])
                    }
                    // networksetup 设置地址时会顺手把开关打开，所以状态要放在后面收尾。
                    try run([state, b.service, e.enabled ? "on" : "off"])
                } catch {
                    warnings.append("还原「\(b.service)」失败：\(error.localizedDescription)")
                }
            }
            apply(b.socks, set: "-setsocksfirewallproxy", state: "-setsocksfirewallproxystate")
            apply(b.web, set: "-setwebproxy", state: "-setwebproxystate")
            apply(b.secureWeb, set: "-setsecurewebproxy", state: "-setsecurewebproxystate")
        }
        isActive = false
        return warnings
    }

    /// 供界面展示：当前系统 SOCKS 代理指向哪里
    static func currentSummary() -> String {
        guard let svcs = try? networkServices(), let first = svcs.first else { return "未知" }
        let socks = parseEntry((try? run(["-getsocksfirewallproxy", first])) ?? "")
        let web = parseEntry((try? run(["-getwebproxy", first])) ?? "")
        var parts: [String] = []
        if socks.enabled { parts.append("SOCKS \(socks.server):\(socks.port)") }
        if web.enabled { parts.append("HTTP \(web.server):\(web.port)") }
        return parts.isEmpty ? "未启用" : parts.joined(separator: " / ")
    }
}
