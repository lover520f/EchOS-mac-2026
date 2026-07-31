import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var renaming = false
    @State private var renameText = ""
    /// 命名/改名的错误提示（重名、空名）
    @State private var nameErrorText = ""
    @State private var showNameError = false
    /// 当前服务器还没保存过就想新建下一个
    @State private var addNewBlocked = false
    @State private var confirmDelete = false
    @State private var rulesExpanded = false
    @State private var ruleSearch = ""
    /// 保存按钮的结果弹窗
    @State private var showSaveResult = false
    @State private var saveResultOK = false
    @State private var saveResultText = ""
    /// 上一次自动算出的高度，用来做增量调整
    @State private var lastAutoHeight: CGFloat = 0

    private let labelWidth: CGFloat = 82

    /// 底部固定区（操作行 + 日志）的高度。写死是为了能反过来算出
    /// 滚动区该有多高 —— 交给 SwiftUI 自动分配时，ScrollView 会按内容
    /// 撑开并溢出到这块区域上，规则一展开就盖住"开机启动"那一行。
    private let bottomBlockHeight: CGFloat = 190

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                titleBar
                    .padding(.horizontal, 16)

                // 配置区按内容自然排布。规则列表已经自己限高了，
                // 整块的最大高度是可预测的，不需要再套一层滚动。
                VStack(alignment: .leading, spacing: 10) {
                    serverGroup
                    coreGroup
                    optionalGroup
                }
                .padding(.horizontal, 16)

                // 固定间隔，不参与空间分配
                Color.clear.frame(height: 10)

                VStack(alignment: .leading, spacing: 10) {
                    actionRow
                    // 日志吃掉窗口拉伸多出来的高度：这里是唯一该变高的地方，
                    // 其余控件都是固定尺寸的，撑大它们没有意义
                    logSection(height: nil)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 16)
                .padding(.bottom, 26)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .frame(minWidth: 720, minHeight: 762)
        .onAppear {
            // 全新安装（还没有配置文件）：直接建一个待起名的服务器并弹命名框，
            // 不显示「还没有服务器」空态 —— 第一次操作就是给服务器起名字。
            if app.config.servers.isEmpty,
               !FileManager.default.fileExists(atPath: AppConfig.fileURL.path) {
                app.addServer()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { syncWindowHeight() }
        }
        .onChange(of: rulesExpanded) { _ in syncWindowHeight() }
        .onChange(of: app.selected?.customRules.count ?? 0) { _ in syncWindowHeight() }
        .onChange(of: app.needsNameInput) { need in
            if need {
                app.needsNameInput = false
                renameText = ""
                renaming = true
            }
        }
        .alert(
            (app.selected?.name.isEmpty ?? true) ? "新建服务器名称" : "重命名服务器",
            isPresented: $renaming
        ) {
            TextField("例如：家庭主路由", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("确定") {
                if let err = app.rename(to: renameText) {
                    nameErrorText = err
                    showNameError = true
                }
            }
        } message: {
            Text((app.selected?.name.isEmpty ?? true)
                 ? "给新服务器起个名字，之后可在任何位置改。"
                 : "输入新名字，回车确认。")
        }
        .alert("无法使用这个名字", isPresented: $showNameError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(nameErrorText)
        }
        .alert("当前服务器状态未确认", isPresented: $addNewBlocked) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请填写完整参数后「保存」。\n如不需要，请「删除」当前服务器。")
        }
        .alert("删除服务器？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { app.deleteSelected() }
        } message: {
            Text(app.config.servers.count <= 1
                 ? "将清空「\(app.selected?.name ?? "")」的配置并重建一个空白服务器，不可撤销。"
                 : "将删除「\(app.selected?.name ?? "")」及其配置，不可撤销。")
        }
        .alert(saveResultOK ? "配置已保存" : "保存失败", isPresented: $showSaveResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(saveResultText)
        }
    }

    private let titleBarHeight: CGFloat = 56

    /// 把窗口高度调到刚好装下当前内容。
    ///
    /// 规则区一展开内容就多出百来像素：窗口不动的话，要么下面留一大片空白
    /// （按最大高度定），要么内容被截断得滚动（按最小高度定）。
    /// 让窗口跟着内容走，两种难看的情况都不会出现。
    private func syncWindowHeight() {
        let ruleCount = app.selected?.customRules.count ?? 0
        // 基准值把底部内边距一起算进去 —— 之前少算了这 16px，
        // 日志框的下边框正好压在窗口底边上，看着就像和底栏重叠了
        var h: CGFloat = 762          // 规则收起时的基准高度
        if rulesExpanded {
            h += 46                   // 规则区标题 + 底部状态行
            h += min(CGFloat(ruleCount), 3) * 33   // 最多算 3 行，再多是内部滚动
        }

        DispatchQueue.main.async {
            guard let win = NSApp.windows.first(where: { $0.contentView != nil }) else { return }
            let current = win.frame.size.height
            guard abs(current - h) > 8 else { return }   // 差不多就别动，免得窗口抖
            var f = win.frame
            f.origin.y += (f.size.height - h)            // 顶边不动，往下长
            f.size.height = h
            win.setFrame(f, display: true, animate: true)
        }
    }

    /// 「保存」按钮：有错不落盘，并弹窗说明原因；成功也弹窗确认。
    private func saveSelected() {
        let err = app.saveCurrentServer()
        saveResultOK = (err == nil)
        saveResultText = err ?? "配置已写入本地。"
        showSaveResult = true
    }

    /// 带底色实心按钮。
    ///
    /// macOS 的 borderedProminent 在窗口失去焦点时会整体变灰，
    /// 这里用固定背景色，失焦也不变色。文字用 .primary，跟随系统模式
    /// （亮色黑字、暗色白字），和「新增/重命名」保持一致。
    private func persistentTint<Label: View>(
        _ color: Color,
        isActive: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .font(.system(size: 13.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(color, in: RoundedRectangle(cornerRadius: 5))
                .opacity(isActive ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isActive)
    }

    // MARK: - 标题栏

    private var titleBar: some View {
        HStack(spacing: 8) {
            Spacer()
            Image(systemName: "cloud.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(colors: [Color.cloudflareOrange, Color.cloudflareOrange.opacity(0.7)],
                                   startPoint: .top, endPoint: .bottom))
            Text("EchOS")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
            Spacer()
        }
        .padding(.top, 6)
        .padding(.bottom, 38)
    }

    // MARK: - 服务器管理

    private var serverGroup: some View {
        group("服务器管理", icon: "server.rack", tint: .blue) {
            HStack(spacing: 8) {
                Text("选择服务器:")
                    .font(.system(size: 12))
                    .frame(width: labelWidth, alignment: .leading)

                if app.config.servers.isEmpty {
                    Text("还没有服务器：点「新增」开始创建")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                } else {
                    Picker("", selection: Binding(
                        get: { app.config.selectedID ?? app.config.servers.first?.id ?? UUID() },
                        set: { app.select($0) }
                    )) {
                        ForEach(Array(app.config.servers.enumerated()), id: \.element.id) { index, s in
                            // 空名按位置编号显示，避免同时出现多个一模一样的「未命名」
                            Text(s.name.isEmpty ? "未命名 \(index + 1)" : s.name).tag(s.id)
                        }
                    }
                    .labelsHidden()
                    // 运行中不置灰、也切不了：切服务器得等停止后，防止连接和配置对不上
                    .allowsHitTesting(!app.isRunning)
                }

                Button("新增") {
                    if !app.hasUncommittedServer {
                        app.addServer()
                    } else {
                        addNewBlocked = true
                    }
                }
                .disabled(app.isRunning)
                .help("还有服务器没保存时不能新增下一个，先保存或删除")
                Button("重命名") {
                    renameText = app.selected?.name ?? ""
                    renaming = true
                }
                .disabled(app.isRunning)
                persistentTint(.green, isActive: !app.isRunning) {
                    saveSelected()
                } label: {
                    Text("保存")
                }
                persistentTint(.red, isActive: !app.isRunning) {
                    confirmDelete = true
                } label: {
                    Text("删除")
                }

                Spacer()

                Button {
                    app.runSelfCheck()
                } label: {
                    Label(app.checking ? "检测中" : "自检", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(app.isRunning && !app.checking ? Color.green : Color.secondary)
                }
                .disabled(!app.isRunning || app.checking)
                .help("手动跑一次并把明细写进日志。\n启动代理后会自动静默自检一次，结果看状态灯。")
            }
        }
    }

    // MARK: - 核心配置

    private var coreGroup: some View {
        group("核心配置", icon: "gearshape.fill", tint: .indigo) {
            VStack(spacing: 9) {
                hostPortRow("服务地址:", host: binding(\.server), port: intBinding(\.serverPort),
                            hostPlaceholder: "xxx.workers.dev")
                hostPortRow("监听地址:", host: binding(\.listen), port: intBinding(\.listenPort),
                            hostPlaceholder: "127.0.0.1")

                HStack(spacing: 8) {
                    Text("分流模式:")
                        .font(.system(size: 12.5))
                        .frame(width: labelWidth, alignment: .leading)

                    ModeSegment(
                        selection: Binding(
                            get: { app.selected?.routeMode ?? .bypassCN },
                            set: { v in app.switchRouteMode(v) }
                        ),
                        disabled: false
                    )
                }
            }
        }
    }

    // MARK: - 高级选项（可选）

    private var optionalGroup: some View {
        group("高级选项", icon: "slider.horizontal.3", tint: .orange) {
            VStack(spacing: 9) {
                row("TOKEN(可选):", binding(\.token), placeholder: "")
                row("优选IP(域名):", binding(\.ip), placeholder: "104.16.158.132")
                presetRow("ECH域名:", binding(\.ech), options: EchPresets.echDomains,
                          placeholder: "cloudflare-ech.com",
                          help: "去哪个域名查 ECH 公钥。注意这不是伪装域名 —— Cloudflare 的 ECH 域名固定是 cloudflare-ech.com。")
                presetRow("DOH服务器:", binding(\.dns), options: EchPresets.dnsServers,
                          placeholder: "dns.alidns.com/dns-query",
                          help: "用来查询 ECH 公钥的 DNS。必须支持 HTTPS 记录查询。")

                Divider().padding(.vertical, 2)
                customRulesSection
            }
        }
    }

    // MARK: - 自定义分流规则

    private var customRulesSection: some View {
        let rules = app.selected?.customRules ?? []
        let shadowed = rules.shadowedIDs
        let filtered = ruleSearch.isEmpty ? rules : rules.filter { r in
            // 搜目标本身、类型名，以及分类的中文标签 ——
            // 用户记得的是"YouTube"，不是 geosite:youtube
            let label = RuleCategory.all.first { $0.value == r.target }?.label ?? ""
            return r.target.localizedCaseInsensitiveContains(ruleSearch)
                || r.kind.title.contains(ruleSearch)
                || label.localizedCaseInsensitiveContains(ruleSearch)
        }

        return DisclosureGroup(isExpanded: $rulesExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                // 规则一多，靠滚动翻找很费劲，给个搜索框
                if rules.count > 3 {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        TextField("搜索规则", text: $ruleSearch)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                        if !ruleSearch.isEmpty {
                            Button {
                                ruleSearch = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }

                // 规则列表自己限高滚动。指望外层容器兜底是不行的：
                // 规则能加任意多条，展开后会把整个配置区顶破，
                // 挤到下面的操作行上（之前就是这么重叠的）。
                if !filtered.isEmpty {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(filtered) { rule in
                                ruleRow(rule, isShadowed: shadowed.contains(rule.id))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    // 高度跟着条数走，最多 3 行；再多就在列表内部滚动，
                    // 不去牵动整页布局 —— 规则区涨一点整页就得重排是很别扭的
                    .frame(height: min(CGFloat(filtered.count), 3) * 33 + 4)
                }

                if !ruleSearch.isEmpty && filtered.isEmpty {
                    Text("没有匹配「\(ruleSearch)」的规则")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                ruleFooter(count: rules.count, shadowedCount: shadowed.count)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text("自定义分流规则")
                    .font(.system(size: 12.5))
                if !rules.isEmpty {
                    Text("\(rules.count) 条")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                if !shadowed.isEmpty {
                    Label("\(shadowed.count) 条重复", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundColor(.orange)
                }
                if app.rulesDirty {
                    Label("待重启", systemImage: "arrow.clockwise")
                        .font(.system(size: 10.5))
                        .foregroundColor(.orange)
                }

                Spacer()

                Button {
                    app.addRule()
                    rulesExpanded = true
                } label: {
                    Label("添加规则", systemImage: "plus").font(.system(size: 11.5))
                }
                .controlSize(.small)
                // 折叠标题整行是点击区，按钮得自己拦下点击，否则会连带展开/收起
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: CustomRule, isShadowed: Bool) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { rule.kind },
                set: { app.updateRule(rule.id, kind: $0) }
            )) {
                ForEach(RuleKind.allCases) { k in Text(k.title).tag(k) }
            }
            .labelsHidden()
            .frame(width: 96)

            if rule.kind == .category {
                Picker("", selection: Binding(
                    get: { rule.target },
                    set: { app.updateRule(rule.id, target: $0) }
                )) {
                    ForEach(RuleCategory.all) { c in Text(c.label).tag(c.value) }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            } else {
                TextField(rule.kind.placeholder, text: Binding(
                    get: { rule.target },
                    set: { app.updateRule(rule.id, target: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 24)
            }

            Picker("", selection: Binding(
                get: { rule.action },
                set: { app.updateRule(rule.id, action: $0) }
            )) {
                Text("直连").tag("direct")
                Text("代理").tag("proxy")
                Text("拦截").tag("block")
            }
            .labelsHidden()
            .frame(width: 82)

            if isShadowed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .help("上面已经有一条同样目标的规则，这条不会生效。\n内核按顺序匹配，先命中的那条说了算。")
            }

            Button {
                app.removeRule(rule.id)
            } label: {
                Image(systemName: "trash").font(.system(size: 11))
            }
            .help("删除这条规则")
        }
        .opacity(isShadowed ? 0.55 : 1)
    }

    @ViewBuilder
    private func ruleFooter(count: Int, shadowedCount: Int) -> some View {
        HStack(spacing: 8) {
            if count == 0 {
                Text("点右上角「添加规则」，选类型后填域名，或直接挑一个网站分类")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else if app.rulesDirty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundColor(.orange)
                Text("规则已保存，重启代理才生效")
                    .font(.system(size: 11)).foregroundColor(.orange)
                Button("立即重启") { app.applyRules() }
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10.5)).foregroundColor(.green)
                Text(app.isRunning ? "规则已生效" : "规则已保存，启动代理后生效")
                    .font(.system(size: 10.5)).foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - 按钮行

    private var actionRow: some View {
        VStack(spacing: 10) {
            // 四个控件统一放一行：左边两个开关，右边两个按钮
            HStack(spacing: 14) {
                Toggle("开机启动", isOn: Binding(
                    get: { app.launchAtLogin },
                    set: { app.setLaunchAtLogin($0) }
                ))
                .help("登录 Mac 后自动打开本软件")

                Toggle("自动设置系统代理", isOn: Binding(
                    get: { app.config.autoSystemProxy },
                    set: { v in app.setAutoSystemProxy(v) }
                ))
                .help("让 Safari / Chrome 等程序走本工具，停止时自动还原你原来的设置。\n运行中切换会立即生效。")

                Spacer()

                persistentTint(.blue, isActive: !app.isRunning && !app.isStarting) {
                    app.start()
                } label: {
                    Label("启动代理", systemImage: "play.fill")
                        .frame(width: 84)
                }
                .keyboardShortcut(.return, modifiers: .command)

                persistentTint(.red, isActive: app.isRunning || app.isStarting) {
                    app.stop()
                } label: {
                    Label("停止代理", systemImage: "stop.fill")
                        .frame(width: 84)
                }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12.5))

            // 运行状态：圆点同时承担"自检结果"的角色
            HStack(spacing: 7) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 10, height: 10)
                    .help(checkTooltip)
                Text(app.statusText)
                    .font(.system(size: 12))
                    .foregroundColor(app.isRunning ? .primary : (app.isStarting ? .secondary : .secondary))
                    .lineLimit(1)
                if app.isRunning || app.isStarting {
                    Text(checkLabel)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .help(checkTooltip)
                }
                Spacer()
            }
        }
    }

    // MARK: - 自检状态呈现

    private var statusDotColor: Color {
        if app.isStarting { return .yellow }
        guard app.isRunning else { return .cloudflareOrange }
        switch app.checkState {
        case .idle:    return .accentColor
        case .running: return .yellow
        case .ok:      return .green
        case .failed:  return .red
        }
    }

    private var checkLabel: String {
        if app.isStarting { return "· 启动中…" }
        switch app.checkState {
        case .idle:    return "· 待检测"
        case .running: return "· 检测中…"
        case .ok:      return "· 自检通过"
        case .failed:  return "· 自检未通过"
        }
    }

    private var checkTooltip: String {
        switch app.checkState {
        case .idle:    return "启动后会自动检测一次"
        case .running: return "正在检测端口、国内直连和隧道…"
        case .ok(let d):     return "自检通过\n\n" + d
        case .failed(let d): return "自检未通过\n\n" + d
        }
    }

    // MARK: - 运行日志

    private func logSection(height: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Button {
                    app.config.logVisible.toggle()
                    app.persist()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: app.config.logVisible ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(app.config.logLevel == .checkOnly ? "自检记录" : "运行日志")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.plain)
                .help(app.config.logVisible ? "点击收起日志" : "点击展开日志")

                Spacer()

                if app.config.logVisible {
                    Picker("", selection: Binding(
                        get: { app.config.logLevel },
                        set: { v in app.config.logLevel = v; app.persist() }
                    )) {
                        ForEach(LogLevel.allCases) { l in Text(l.title).tag(l) }
                    }
                    .labelsHidden()
                    .frame(width: 96)
                    .help("界面日志的详细程度。无论选哪个，日志文件里始终是全量记录。")

                    Button {
                        // 打开当前视图对应的那个文件，而不是永远打开运行日志
                        let url = app.config.logLevel == .checkOnly ? LogFile.checkURL : LogFile.currentURL
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("日志文件", systemImage: "folder")
                    }
                    .help("打开 ~/Library/Application Support/EchOS/logs/\n运行日志 latest.log，自检记录 selfcheck.log")

                    Button {
                        app.clearLog()
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .help("只清空这里显示的内容，日志文件不受影响")
                }
            }
            .controlSize(.small)

            if app.config.logVisible {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(app.displayedLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundColor(color(for: line))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: app.logLines.count) { _ in
                        if let last = app.logLines.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
                .frostedCard()
                // 给了具体高度就用它；给 nil 表示"占满剩余"。
                // 现在配置区是按内容自然排布的，日志吃剩余空间不会再挤到它 ——
                // 早先那次日志涨到 280px 是因为当时配置区套着 ScrollView 在跟它抢空间。
                .frame(minHeight: 84, maxHeight: height ?? .infinity)
            }
        }
    }

    // MARK: - 复用组件

    /// 分组卡片：左侧一个带色的图标块 + 标题，内容区磨砂玻璃
    @ViewBuilder
    private func group<C: View>(_ title: String, icon: String, tint: Color,
                                @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            content()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frostedCard()
        }
    }

    /// 整行：标签 + 撑满的输入框
    @ViewBuilder
    private func row(_ label: String, _ text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .frame(width: labelWidth, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(height: 25)
        }
    }

    /// 半行：标签 + 输入框，用于同一行放两组
    @ViewBuilder
    private func labeled(_ label: String, _ text: Binding<String>,
                         placeholder: String, labelWidth: CGFloat? = nil) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .frame(width: labelWidth ?? self.labelWidth, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(height: 25)
        }
    }

    /// 主机名 + 端口分成两个输入框：端口独立成框，用户就不会因为
    /// 把冒号打成全角"："而连不上，也省得程序去猜他到底想输入什么。
    @ViewBuilder
    private func hostPortRow(_ label: String, host: Binding<String>, port: Binding<Int>,
                             hostPlaceholder: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .frame(width: labelWidth, alignment: .leading)
            TextField(hostPlaceholder, text: host)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 25, maxHeight: 25)
            Text("端口：")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            TextField("", value: port, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(width: 96, height: 25)
                .multilineTextAlignment(.center)
        }
    }

    /// 输入框 + 快捷填入下拉。
    /// 下拉不接管这个字段，只是往输入框里填一个常用值 ——
    /// 做成"选预设"和"自定义"二选一是错的：用户想在预设基础上改一个字，
    /// 就得先切到自定义再重新输入一遍。
    @ViewBuilder
    private func presetRow(_ label: String, _ text: Binding<String>,
                           options: [PresetOption], placeholder: String,
                           help: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .frame(width: labelWidth, alignment: .leading)

            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)

            Menu {
                ForEach(options) { o in
                    Button(o.label) { text.wrappedValue = o.value }
                }
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("从常用列表里挑一个填进去，填完照样能改")

            Image(systemName: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.5))
                .help(help)
        }
    }

    private func intBinding(_ key: WritableKeyPath<ServerConfig, Int>) -> Binding<Int> {
        Binding(
            get: { app.selected?[keyPath: key] ?? 0 },
            set: { v in app.update { $0[keyPath: key] = v } }
        )
    }

    private func binding(_ key: WritableKeyPath<ServerConfig, String>) -> Binding<String> {
        Binding(
            get: { app.selected?[keyPath: key] ?? "" },
            set: { v in app.update { $0[keyPath: key] = v } }
        )
    }

    private func color(for line: String) -> Color {
        if line.contains("失败") || line.contains("错误") || line.contains("error") { return .red }
        if line.contains("[系统代理]") { return .orange }
        if line.contains("[系统]") { return .accentColor }
        return .primary
    }
}
