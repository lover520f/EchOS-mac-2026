import Foundation

/// 启动后的连通性自检。
///
/// "不能上网"这四个字底下可能藏着完全不同的原因：ECH 公钥没拿到、隧道没建起来、
/// 分流数据没加载、系统代理没生效……光看一屏滚动的日志很难分辨。
/// 这里主动打几个探针，把每一环单独判定，直接告诉用户卡在哪一步。
enum SelfCheck {

    struct Result {
        var title: String
        var ok: Bool
        var note: String
        /// 是否"必须经隧道才通"的探针（国外站点）。本地端口、国内直连
        /// 探针失败可能是别的网络问题，不该拿它来决定回滚系统代理。
        var dependsOnTunnel = false
    }

    /// 通过本地 SOCKS5 访问一个地址，返回是否成功和耗时
    private static func probe(via socks: (host: String, port: Int),
                              url: String, timeout: TimeInterval) async -> (Bool, TimeInterval, String) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        // 让这次请求走我们自己的 SOCKS5，而不是系统代理
        cfg.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy": socks.host,
            "SOCKSPort": socks.port,
            kCFProxyTypeKey as String: kCFProxyTypeSOCKS,
        ]
        let session = URLSession(configuration: cfg)
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "HEAD"
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let start = Date()
        do {
            let (_, resp) = try await session.data(for: req)
            let cost = Date().timeIntervalSince(start)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (code > 0, cost, "HTTP \(code)")
        } catch {
            return (false, Date().timeIntervalSince(start), error.localizedDescription)
        }
    }

    /// 探测一次，失败就再试一次。
    /// 网络抖一下就亮红灯比不检还糟 —— 用户会以为真断了，跑去改配置。
    private static func probeTwice(via socks: (host: String, port: Int),
                                   url: String, timeout: TimeInterval) async -> (Bool, TimeInterval, String) {
        let first = await probe(via: socks, url: url, timeout: timeout)
        if first.0 { return first }
        try? await Task.sleep(nanoseconds: 600_000_000)
        let second = await probe(via: socks, url: url, timeout: timeout)
        return second.0 ? second : (false, second.1, second.2 + "（重试两次均失败）")
    }

    /// 跑一轮完整自检
    static func run(socks: (host: String, port: Int), mode: RouteMode) async -> [Result] {
        var results: [Result] = []

        // 1) 本地端口通不通 —— 不通说明内核没起来
        let portOK = !PortPicker.isFree(socks.port)
        results.append(Result(
            title: "本地代理端口 \(socks.port)",
            ok: portOK,
            note: portOK ? "正在监听" : "没有监听，内核可能没启动成功"))
        guard portOK else { return results }

        // 2) 国内站点：规则模式下应该直连，全局模式下走隧道
        let (cnOK, cnCost, cnNote) = await probeTwice(via: socks, url: "https://www.baidu.com", timeout: 8)
        results.append(Result(
            title: "国内网站（百度）",
            ok: cnOK,
            note: cnOK ? String(format: "%.0f 毫秒", cnCost * 1000)
                       : "失败：\(cnNote)"))

        // 3) 国外站点：这一条最能反映隧道是否真的通。
        // 黑名单模式下 google 也在名单里，同样该走隧道。
        do {
            let (foreignOK, fCost, fNote) = await probeTwice(via: socks,
                                                             url: "https://www.gstatic.com/generate_204",
                                                             timeout: 8)
            results.append(Result(
                title: "国外网站（经隧道）",
                ok: foreignOK,
                note: foreignOK ? String(format: "%.0f 毫秒 · 隧道正常", fCost * 1000)
                                : "失败：\(fNote)",
                dependsOnTunnel: true))
        }

        return results
    }

    /// 预检（代理未启动时手动触发）：不依赖本地 SOCKS 端口，直接测配置里的
    /// 服务端 / DoH 是否可达，人工确认这套配置在启动前"能不能用"。
    /// 隧道实际连的是 优选IP(有则用)/服务地址 : 服务端口；ECH 公钥要靠 DoH 查。
    static func runPreflight(config: ServerConfig) async -> [Result] {
        var results: [Result] = []

        let dialHost = ServerConfig.cleanHost(config.ip.isEmpty ? config.server : config.ip)
        if dialHost.isEmpty {
            results.append(Result(title: "服务端地址", ok: false, note: "未填写服务地址或优选IP"))
        } else {
            let (ok, cost, note) = await tcpCheck(host: dialHost, port: config.serverPort, timeout: 4)
            results.append(Result(
                title: "服务端 \(dialHost):\(config.serverPort)",
                ok: ok,
                note: ok ? String(format: "%.0f 毫秒", cost * 1000) : "失败：\(note)"))
        }

        // DoH 才走 TCP；UDP DNS 没有可测的 TCP 连接
        if let host = dohHost(config.dns) {
            let (ok, cost, note) = await tcpCheck(host: host, port: 443, timeout: 4)
            results.append(Result(
                title: "DoH 服务器 \(host)",
                ok: ok,
                note: ok ? String(format: "%.0f 毫秒", cost * 1000) : "失败：\(note)"))
        } else {
            results.append(Result(title: "DoH 服务器", ok: true, note: "UDP DNS 模式，无需预检"))
        }

        return results
    }

    /// 从 dns 配置里取出 DoH 的 host。只有 https:// 形式的 DoH 有 TCP 可测；
    /// UDP DNS（纯 IP/域名，不带路径）返回 nil。
    static func dohHost(_ raw: String) -> String? {
        let s = ServerConfig.normalizedDoH(raw)
        let lower = s.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://") else { return nil }
        return URL(string: s)?.host
    }

    /// TCP 连通性检测（异步，不占主线程）
    private static func tcpCheck(host: String, port: Int, timeout: TimeInterval) async -> (Bool, TimeInterval, String) {
        let start = Date()
        let (ok, note) = await Task.detached(priority: .userInitiated) {
            Self.blockingTCPConnect(host: host, port: port, timeout: timeout)
        }.value
        return (ok, Date().timeIntervalSince(start), note)
    }

    private static func blockingTCPConnect(host: String, port: Int, timeout: TimeInterval) -> (Bool, String) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let addrs = res else {
            if res != nil { freeaddrinfo(res) }
            return (false, "域名解析失败")
        }
        defer { freeaddrinfo(addrs) }

        // 先试 IPv4 再试 IPv6，和内核 v1.1.8 的 IPv4 优先一致：
        // IPv6 路由不通的网络里，不会卡在 IPv6 上浪费时间。
        var lastNote = "无可用地址"
        for family in [AF_INET, AF_INET6] {
            let r = tryConnect(addrs, family: family, timeout: timeout)
            if r.ok { return (true, "已连通") }
            if r.tried { lastNote = r.note }
        }
        return (false, lastNote)
    }

    /// 尝试某个地址族的所有地址。返回 (是否连通, 是否真的试过, 失败原因)。
    private static func tryConnect(_ addrs: UnsafeMutablePointer<addrinfo>,
                                   family: Int32, timeout: TimeInterval) -> (ok: Bool, tried: Bool, note: String) {
        var cur: UnsafeMutablePointer<addrinfo>? = addrs
        var tried = false
        var note = "连接失败"
        while let n = cur {
            if n.pointee.ai_family == family {
                tried = true
                let fd = socket(n.pointee.ai_family, n.pointee.ai_socktype, n.pointee.ai_protocol)
                if fd >= 0 {
                    let flags = fcntl(fd, F_GETFL)
                    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                    let rc = connect(fd, n.pointee.ai_addr, n.pointee.ai_addrlen)
                    if rc == 0 { close(fd); return (true, true, "已连通") }
                    if errno == EINPROGRESS {
                        // 等 socket 可写 = 连接完成。用 poll 而非 select：
                        // FD_ZERO/FD_SET 是 C 宏，Swift 里没有，poll 是纯函数。
                        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        let sel = poll(&pfd, 1, Int32(timeout * 1000))
                        if sel > 0, pfd.revents & Int16(POLLOUT) != 0 {
                            var soerr: Int32 = 0
                            var len = socklen_t(MemoryLayout<Int32>.size)
                            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len)
                            if soerr == 0 { close(fd); return (true, true, "已连通") }
                            note = String(cString: strerror(soerr))
                        } else if sel == 0 {
                            note = "连接超时"
                        } else {
                            note = "连接失败"
                        }
                    } else {
                        note = String(cString: strerror(errno))
                    }
                    close(fd)
                }
            }
            cur = n.pointee.ai_next
        }
        return (false, tried, note)
    }
}
