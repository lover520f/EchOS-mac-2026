import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var config: AppConfig
    @Published var isRunning = false {
        didSet { refreshStatusText() }
    }
    /// 启动中但自检尚未完成。此时内核已在运行，但还在等自检结果。
    /// 只有自检通过（或至少跑完）后才把 isRunning 设为 true。
    @Published var isStarting = false
    @Published var logLines: [String] = []
    /// 自检记录单独一份，切到"自检记录"视图时显示这个
    @Published var checkLines: [String] = []
    @Published var systemProxySummary: String = ""
    @Published var proxyTakenOver = SystemProxy.isActive

    private var process: Process?
    private var stdoutPipe: Pipe?
    private let maxLogLines = 2000

    /// 本次运行实际使用的本地端口（自动挑选，界面上不需要用户填）
    private(set) var activeSocks: (host: String, port: Int)?
    private(set) var activeHTTP: (host: String, port: Int)?

    /// 顶部状态条文字，例如「已连接 · 全局代理已开启」
    @Published var statusText: String = "已停止"

    init() {
        self.config = AppConfig.load()
        // 读进来时可能做过格式迁移（比如把 host:port 拆成两个字段），
        // 立刻回写一次让文件里也是新格式，免得迁移逻辑一直悬着。
        // 全新安装（还没有配置文件）就不写：保持零配置，等用户第一次操作再落盘。
        if FileManager.default.fileExists(atPath: AppConfig.fileURL.path) {
            self.config.save()
        }
        LogFile.startNewSession()
        recoverFromUncleanExit()
        refreshProxySummary()
    }

    /// 上次没能正常退出（被强杀、断电、崩溃）时的自愈：
    /// 1) 内核进程会变成孤儿继续跑，占着端口；
    /// 2) 系统代理停在"已接管"状态，指向一个已经没人监听的端口 —— 用户看起来就是断网。
    /// 两件事都要在启动时收拾干净，否则用户只会觉得"这软件把我网搞坏了"。
    private func recoverFromUncleanExit() {
        var recovered = false

        if KernelPID.killLeftover(expecting: kernelPath()) {
            pendingLogs.append("[系统] 清理了上次残留的内核进程")
            recovered = true
        }

        if SystemProxy.isActive {
            _ = SystemProxy.restore()
            proxyTakenOver = false
            pendingLogs.append("[系统代理] 上次未正常退出，已把系统代理还原回你原来的设置")
            recovered = true
        }

        if recovered { pendingLogs.append("[系统] 环境已恢复正常，可以直接启动") }
    }

    /// init 阶段还没人订阅日志，先攒着，界面出来后再吐出去
    private var pendingLogs: [String] = []

    func flushPendingLogs() {
        guard !pendingLogs.isEmpty else { return }
        pendingLogs.forEach { log($0) }
        pendingLogs.removeAll()
    }

    var selected: ServerConfig? {
        guard let id = config.selectedID else { return config.servers.first }
        return config.servers.first { $0.id == id } ?? config.servers.first
    }

    var selectedIndex: Int? {
        guard let s = selected else { return nil }
        return config.servers.firstIndex { $0.id == s.id }
    }

    func update(_ mutate: (inout ServerConfig) -> Void) {
        guard let idx = selectedIndex else { return }
        mutate(&config.servers[idx])
    }

    /// 保存当前服务器配置到文件。不完整时返回错误原因并拒绝保存，成功返回 nil。
    @discardableResult
    func saveCurrentServer() -> String? {
        guard let idx = selectedIndex else { return "没有选中的服务器" }
        if let err = config.servers[idx].validate() {
            log("[系统] 保存失败：\(err)")
            return err
        }
        config.save()
        log("[系统] 服务器配置已保存")
        return nil
    }

    func addServer() {
        var s = ServerConfig()
        s.name = "服务器 \(config.servers.count + 1)"
        config.servers.append(s)
        config.selectedID = s.id
        // 不立即持久化：新服务器一个字段都没填，跟着「必填」逻辑走 ——
        // 填完整点「保存」才算数。免得导入配置时混进一堆空服务器。
    }

    /// 复制当前服务器：换个优选 IP 试的时候很方便
    func duplicateSelected() {
        guard let cur = selected else { return }
        var copy = cur
        copy.id = UUID()
        copy.name = cur.name + " 副本"
        config.servers.append(copy)
        config.selectedID = copy.id
        config.save()
    }

    func rename(to newName: String) {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        update { $0.name = n }
    }

    func delete(id: UUID) {
        guard let idx = config.servers.firstIndex(where: { $0.id == id }) else { return }
        config.servers.remove(at: idx)

        // 删到一个不剩就补一个空白的。之前是"最后一个不许删"，
        // 可用户想清空重填时只能一个个改字段，很别扭 ——
        // 让他删，然后给个干净的新配置继续填。
        if config.servers.isEmpty {
            var fresh = ServerConfig()
            fresh.name = "服务器 1"
            config.servers = [fresh]
        }
        if config.selectedID == id || !config.servers.contains(where: { $0.id == config.selectedID }) {
            config.selectedID = config.servers.first?.id
        }
        config.save()
    }

    func deleteSelected() {
        guard let s = selected else { return }
        delete(id: s.id)
    }

    func select(_ id: UUID) {
        guard !isRunning && !isStarting else { return }
        config.selectedID = id
        config.save()
    }

    // MARK: - 自定义分流规则

    /// 规则改过但还没重启内核。规则是启动参数，改完不重启等于没改，
    /// 必须让用户看见这个状态，否则他会以为改完就生效了。
    @Published var rulesDirty = false

    func addRule() {
        update { $0.customRules.append(CustomRule()) }
        if isRunning { rulesDirty = true }
    }

    func removeRule(_ id: UUID) {
        update { $0.customRules.removeAll { $0.id == id } }
        if isRunning { rulesDirty = true }
    }

    /// 重启内核让规则生效
    func applyRules() {
        guard isRunning else { rulesDirty = false; return }
        log("[系统] 应用新的分流规则，正在重启代理（会短暂断开）…")
        stop()
        start()
        rulesDirty = false
    }

    func updateRule(_ id: UUID, kind: RuleKind? = nil, target: String? = nil, action: String? = nil) {
        update { cfg in
            guard let i = cfg.customRules.firstIndex(where: { $0.id == id }) else { return }
            if let kind {
                cfg.customRules[i].kind = kind
                // 换了类型，原来填的内容多半对不上了，清掉免得留个无效规则。
                // 切到分类就直接给个默认选项，省得用户面对一个空下拉。
                cfg.customRules[i].target = (kind == .category) ? RuleCategory.all[0].value : ""
            }
            if let target { cfg.customRules[i].target = target }
            if let action { cfg.customRules[i].action = action }
        }
        if isRunning { rulesDirty = true }
    }

    // MARK: - 程序坞图标

    /// 切换程序坞图标显示。默认隐藏，通过菜单栏开关控制。
    /// 状态持久化到配置文件，重启后保持不变。
    func setShowDockIcon(_ show: Bool) {
        config.showDockIcon = show
        config.save()
        applyDockIconPolicy()
        log("[系统] 程序坞图标已\(show ? "显示" : "隐藏")")
    }

    func applyDockIconPolicy() {
        if config.showDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
        NotificationCenter.default.post(name: .dockIconVisibilityChanged, object: config.showDockIcon)
    }

    // MARK: - 开机自启动

    var launchAtLogin: Bool { LoginItem.isEnabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
            log("[系统] 开机自启动已\(on ? "开启" : "关闭")")
        } catch {
            log("[系统] 设置开机自启动失败：\(error.localizedDescription)")
        }
        objectWillChange.send()
    }

    // MARK: - 日志

    func log(_ text: String) {
        // 级别选「关闭」就是真的什么都不记：界面不显示，文件也不写。
        // 代价是出问题时没有记录可查，但这是用户明确要的行为 ——
        // 留一份"看不见但一直在写"的日志更违反直觉。
        guard config.logLevel != .off else { return }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            // 自检结论完全走单独通道，不进运行日志。
            // 它是一次次的结论，混进连续流水只会把两边都搅浑。
            if line.contains("[自检]") {
                checkLines.append(line)
                LogFile.writeCheck(line)
                if checkLines.count > 300 {
                    checkLines.removeFirst(checkLines.count - 300)
                }
                continue
            }

            // 文件留全量，界面按级别过滤：文件是用来事后排查的，
            // 界面是用来当下扫一眼的，两者详略要求不同。
            LogFile.write(line)
            guard LogLevel.classify(line).rank <= config.logLevel.rank else { continue }
            logLines.append(line)
        }
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    /// 清空日志：界面和文件一起清。
    /// 只清界面而留着文件，用户会以为已经清干净了，下次打开日志文件又是一堆旧记录。
    func clearLog() {
        logLines.removeAll()
        checkLines.removeAll()
        LogFile.clear()
    }

    /// 当前视图该显示哪一份记录
    var displayedLines: [String] {
        config.logLevel == .checkOnly ? checkLines : logLines
    }

    // MARK: - 内核进程

    /// 内核 x-tunnel 的位置：优先 App 包内，其次可执行文件同级目录（方便开发时直接跑）
    private func kernelPath() -> String? {
        if let p = Bundle.main.path(forResource: "x-tunnel", ofType: nil),
           FileManager.default.isExecutableFile(atPath: p) { return p }
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("x-tunnel").path
        if FileManager.default.isExecutableFile(atPath: sibling) { return sibling }
        return nil
    }

    func start() {
        guard !isRunning && !isStarting else { return }
        guard let cfg = selected else { log("[系统] 请先新增一个服务器"); return }
        if let err = cfg.validate() { log("[系统] \(err)"); return }
        guard let kernel = kernelPath() else {
            log("[系统] 找不到内核程序 x-tunnel，请确认 App 完整"); return
        }

        // 监听地址由主机名 + 端口拼出来，两个字段在界面上是分开填的
        let listen = cfg.expandedListen

        // 端口预检查只是"提前给个说法"，不该当门禁用。
        // 之前它拦下过明明能启动的情况：bind 说被占用，lsof 却查不到任何监听者，
        // 两个结论对不上，用户就被卡在一句无从下手的报错上。
        // 现在只有 lsof 真的指出占用进程时才拦，其余情况放行 ——
        // 内核自己起不来会给出准确原因，比这里瞎猜强。
        // 同时检查 SOCKS 和 HTTP 两个端口，避免 HTTP 端口被占导致内核无声失败
        let portsToCheck = [
            (ServerConfig.socksEndpoint(in: listen), "SOCKS5"),
            (ServerConfig.httpEndpoint(in: listen), "HTTP")
        ]
        for (ep, label) in portsToCheck {
            guard let s = ep else { continue }
            var free = PortPicker.isFree(s.port)
            for _ in 0..<10 where !free {
                usleep(100_000)
                free = PortPicker.isFree(s.port)
            }
            if !free {
                if let who = PortPicker.occupant(of: s.port) {
                    log("[系统] \(label) 端口 \(s.port) 被 \(who) 占用，请关掉它或改用别的监听端口")
                    return
                }
                log("[系统] \(label) 端口 \(s.port) 预检查未通过（\(PortPicker.lastBindReason)），但没有进程在监听，继续启动")
            }
        }
        activeSocks = ServerConfig.socksEndpoint(in: listen)
        activeHTTP = ServerConfig.httpEndpoint(in: listen)

        // 分流数据随 App 打包，规则模式下才需要
        var geoip: String?, geosite: String?
        if cfg.routeMode.needsGeoData {
            geoip = Bundle.main.path(forResource: "geoip", ofType: "dat")
            geosite = Bundle.main.path(forResource: "geosite", ofType: "dat")
            if geoip == nil || geosite == nil {
                // 这不是"降级运行"就能糊弄过去的事：少了数据，"跳过中国大陆"
                // 会退化成把国内流量也塞进隧道，用户只会觉得又慢又不通。
                log("[分流] 错误：App 内缺少分流数据文件（geoip.dat / geosite.dat）")
                log("[分流] 请改用「全局代理」模式，或重新安装完整版本")
                return
            }
        }

        log("[系统] 正在启动内核进程…")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: kernel)
        p.arguments = cfg.arguments(listen: listen, geoip: geoip, geosite: geosite)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        stdoutPipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.log(text) }
        }

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                self.stdoutPipe = nil
                self.process = nil
                self.isRunning = false
                self.isStarting = false
                self.checkState = .idle
                KernelPID.clear()
                self.log("[系统] 内核已退出（状态码 \(proc.terminationStatus)）")
                if self.proxyTakenOver { self.disableSystemProxy() }
                self.refreshStatusText()
            }
        }

        do {
            try p.run()
        } catch {
            isStarting = false
            checkState = .idle
            log("[系统] 启动内核失败：\(error.localizedDescription)")
            return
        }
        process = p
        KernelPID.record(p.processIdentifier)
        log("[系统] 内核进程已启动（PID \(p.processIdentifier)）")
        if let s = activeSocks { log("[系统] 本地端口 SOCKS5 \(s.host):\(s.port)") }

        // 系统代理先不接管 —— 自检通过后才算真正的"运行中"
        // 但先存好 activeSocks/activeHTTP 供自检使用

        rulesDirty = false
        refreshStatusText()

        // 立即开始自检，不设固定等待。如果内核还没就绪，最多重试 4 次
        isStarting = true
        checkState = .running
        log("[系统] 正在检测代理连通性…")
        Task { @MainActor in
            guard let socks = self.activeSocks, let mode = self.selected?.routeMode else {
                self.checkState = .idle
                self.isStarting = false
                self.isRunning = true
                return
            }

            var lastResults: [SelfCheck.Result] = []
            var succeeded = false

            for attempt in 1...5 {
                guard self.isStarting, self.process?.isRunning == true else {
                    self.isStarting = false
                    return
                }

                self.checkState = .running
                lastResults = await SelfCheck.run(socks: socks, mode: mode)
                let failed = lastResults.filter { !$0.ok }

                if failed.isEmpty {
                    succeeded = true
                    break
                }

                if attempt < 5 {
                    self.log("[系统] 内核尚未就绪，\(2)秒后重试（第 \(attempt) 次）…")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }

            for r in lastResults {
                self.log("[自检] \(r.ok ? "✓" : "✗") \(r.title)：\(r.note)")
            }

            if succeeded {
                let detail = lastResults.map { "\($0.title)：\($0.note)" }.joined(separator: "\n")
                self.checkState = .ok(detail)
            } else {
                let detail = lastResults.filter { !$0.ok }.map { "\($0.title)：\($0.note)" }.joined(separator: "\n")
                self.checkState = .failed(detail)
            }

            self.isRunning = true
            self.isStarting = false
            if self.config.autoSystemProxy {
                self.enableSystemProxy()
            }
        }
    }

    func stop() {
        isStarting = false
        if proxyTakenOver { disableSystemProxy() }
        guard let p = process else { isRunning = false; return }
        p.terminationHandler = nil
        p.terminate()

        // 等它真的退出再往下走。SIGTERM 只是"请你退出"，进程还要一点时间收尾；
        // 之前发完信号就立刻返回，用户切换模式时紧接着点启动，
        // 就会撞上尚未释放的端口，报"端口 30000 已被占用"。
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
            usleep(200_000)
        }

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        process = nil
        isRunning = false
        KernelPID.clear()

        // 等端口真正释放再返回。进程退出和内核放开监听端口之间还有延迟，
        // 光等进程结束不够 —— 紧接着的 start() 会撞上尚未释放的端口，
        // 报一句"端口被占用"，用户只会觉得莫名其妙（切分流模式时最容易撞上）。
        // SOCKS 和 HTTP 两个都要等：只等前者的话，内核仍会因为后者起不来。
        for ep in [activeSocks, activeHTTP].compactMap({ $0 }) {
            for _ in 0..<40 where !PortPicker.isFree(ep.port) {
                usleep(50_000)
            }
        }

        activeSocks = nil
        activeHTTP = nil
        checkState = .idle
        log("[系统] 已停止")
        refreshStatusText()
    }

    func toggle() { (isRunning || isStarting) ? stop() : start() }

    /// 切换分流模式。运行中切换会自动重启内核 ——
    /// 分流规则是启动时作为命令行参数传给内核的，改了不重启根本不会生效；
    /// 要么禁止运行中切换（用户会觉得莫名其妙），要么切了就替他重启。
    func switchRouteMode(_ mode: RouteMode) {
        guard selected?.routeMode != mode else { return }
        update { $0.routeMode = mode }

        guard isRunning else { return }
        log("[系统] 分流模式已切换为「\(mode.title)」，正在重启代理（会短暂断开）…")
        stop()
        start()
    }

    // MARK: - 自检

    /// 自检结果。做成一盏灯而不是往日志里刷 ——
    /// 日志是连续的流水，自检是一次性的结论，混在一起两边都看不清；
    /// 而且用户一旦关掉日志，自检结果也跟着消失了，那自检就白做了。
    enum CheckState: Equatable {
        case idle          // 还没测
        case running       // 正在测
        case ok(String)    // 通过，附一句摘要
        case failed(String) // 失败，附失败原因
    }

    @Published var checkState: CheckState = .idle
    @Published var checking = false

    /// 跑一轮连通性自检。
    /// - silent: 静默模式（启动后自动跑的那次）只更新状态灯，不往日志里写；
    ///   手动点按钮才写日志，那时用户是主动来看细节的。
    func runSelfCheck(silent: Bool = false) {
        guard (isRunning || isStarting), let socks = activeSocks, let mode = selected?.routeMode else {
            if !silent { log("[自检] 请先启动代理") }
            return
        }
        guard !checking else { return }
        checking = true
        checkState = .running
        if !silent { log("[自检] 开始检测…") }

        Task { @MainActor in
            async let probe = SelfCheck.run(socks: socks, mode: mode)
            // 至少让"检测中"显示 800 毫秒。检测本身可能几百毫秒就完了，
            // 灯一闪而过等于没有反馈，用户只会觉得"它根本没检测"。
            async let minShow: Void = Task.sleep(nanoseconds: 800_000_000)
            let results = await probe
            _ = try? await minShow
            if !silent {
                for r in results {
                    log("[自检] \(r.ok ? "✓" : "✗") \(r.title)：\(r.note)")
                }
            }

            let failed = results.filter { !$0.ok }
            if failed.isEmpty {
                // 摘要里带上延迟，一眼能看出快慢
                let detail = results.map { "\($0.title)：\($0.note)" }.joined(separator: "\n")
                checkState = .ok(detail)
                // 通过的结果也进自检记录：只记失败的话，看不出平时延迟是多少，
                // 也就没法判断"今天怎么变慢了"。
                for r in results {
                    log("[自检] ✓ \(r.title)：\(r.note)")
                }
            } else {
                let detail = failed.map { "\($0.title)：\($0.note)" }.joined(separator: "\n")
                checkState = .failed(detail)
                // 失败无论如何都记一笔，而且要带上原因 ——
                // 只写"某项未通过"等于没说，用户照样不知道该查什么。
                for f in failed {
                    log("[自检] ✗ \(f.title)：\(f.note)")
                }
            }
            checking = false
        }
    }

    // MARK: - 系统代理

    func enableSystemProxy() {
        do {
            let warnings = try SystemProxy.enable(socks: activeSocks, http: activeHTTP)
            warnings.forEach { log("[系统代理] \($0)") }
            proxyTakenOver = true
            log("[系统代理] 浏览器等程序已自动走本工具")
        } catch {
            log("[系统代理] 自动设置失败：\(error.localizedDescription)")
        }
        refreshProxySummary()
    }

    /// 切换「自动设置系统代理」。
    ///
    /// 这个开关原来只在点启动的瞬间被读一次，运行中改它没有任何反应 ——
    /// 用户会以为软件坏了。现在做成即时生效：正在运行就立刻接管/还原，
    /// 没运行则只记下偏好，等下次启动时用。
    func setAutoSystemProxy(_ on: Bool) {
        config.autoSystemProxy = on
        config.save()

        guard isRunning else {
            log("[系统代理] 已\(on ? "开启" : "关闭")自动设置，下次启动代理时生效")
            return
        }
        if on {
            enableSystemProxy()
        } else {
            disableSystemProxy()
        }
    }

    func disableSystemProxy() {
        let warnings = SystemProxy.restore()
        warnings.forEach { log("[系统代理] \($0)") }
        proxyTakenOver = false
        log("[系统代理] 已还原为你原来的设置")
        refreshProxySummary()
    }

    func refreshProxySummary() {
        systemProxySummary = SystemProxy.currentSummary()
        refreshStatusText()
    }

    func refreshStatusText() {
        guard isRunning else {
            statusText = isStarting ? "启动中…" : "已停止"
            return
        }
        var t = "运行中"
        if let s = activeSocks { t += " · 本地端口 \(s.port)" }
        // 这里说的是"系统代理有没有被接管"，跟分流模式里的"全局代理"是两回事，
        // 早先都叫"全局代理"，用户会以为分流模式被改了。
        t += proxyTakenOver ? " · 已接管系统代理" : " · 未接管系统代理"
        statusText = t
    }

    /// App 退出前的收尾：停内核 + 还原系统代理，避免把用户网络留在坏状态。
    func shutdown() {
        if proxyTakenOver { SystemProxy.restore() }
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        KernelPID.clear()
        config.save()
        LogFile.close()
    }
}
