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
        let (cnOK, cnCost, cnNote) = await probeTwice(via: socks, url: "https://www.baidu.com", timeout: 15)
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
                                                             timeout: 15)
            results.append(Result(
                title: "国外网站（经隧道）",
                ok: foreignOK,
                note: foreignOK ? String(format: "%.0f 毫秒 · 隧道正常", fCost * 1000)
                                : "失败：\(fNote)"))
        }

        return results
    }
}
