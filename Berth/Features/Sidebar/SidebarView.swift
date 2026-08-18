import AppKit
import SwiftData
import SwiftUI

/// 侧栏(双栏布局的左栏):搜索 + 一个平铺主机列表 + 底部密钥入口。
/// 按用户要求不做分组树:所有主机(托管 + ssh_config 镜像)一列到底,
/// 两行行样式 —— 标题 + user@host 副标题;config 镜像带文档角标。
struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Host.sortOrder) private var storedHosts: [Host]
    @AppStorage(SettingsKeys.demoMode) private var demoMode = false

    /// 托管主机(库)+ config 镜像(内存);演示模式下换内置示例(防录屏/截图泄漏)
    private var allHosts: [Host] {
        demoMode ? DemoMode.samples : storedHosts + SSHConfigService.shared.mirrorHosts
    }

    @AppStorage(SettingsKeys.translucentChrome) private var translucentChrome = true
    @State private var searchText = ""
    /// 键盘/单击选中的主机行
    @State private var selectedHostID: UUID?
    /// 主题配色面板(popover)
    @State private var isThemePanelPresented = false

    // 编辑/删除状态(删除只存快照,不持有模型 —— 模型可能被 config 同步等外部删除,悬空访问会崩溃)
    @State private var editingHost: Host?
    @State private var isCreatingHost = false
    @State private var hostPendingDeletion: PendingHost?
    @State private var configHostPendingDeletion: PendingHost?

    private struct PendingHost: Identifiable {
        let id: UUID
        let label: String
    }

    private var theme: TerminalTheme { ThemeStore.shared.current }

    private var visibleHosts: [Host] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return allHosts }
        return allHosts.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.hostname.localizedCaseInsensitiveContains(query)
                || $0.username.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            configHintRow
            if allHosts.isEmpty {
                emptyState
            } else {
                hostList
            }
            // 底部工具行与右侧悬浮状态栏同一水平线,分隔线画上去反而突兀
            keysRow
        }
        // 透明 chrome:不刷不透明底,让 NavigationSplitView 原生的 behind-window
        // 侧栏毛玻璃透出桌面,只叠 45% 主题 tint 保住配色气质(压黑档留给不透明模式,
        // 叠在玻璃上会发死黑);不透明模式维持原来的 chrome 带色
        .background {
            if translucentChrome {
                Color(nsColor: theme.backgroundNSColor).opacity(0.45).ignoresSafeArea()
            } else {
                theme.sidebarBackground.ignoresSafeArea()
            }
        }
        .task(id: allHosts.count) { updateReachabilityTargets() }
        .sheet(isPresented: $isCreatingHost) {
            HostEditorView(host: nil, defaultGroupID: nil)
        }
        .sheet(item: $editingHost) { host in
            HostEditorView(host: host, defaultGroupID: nil)
        }
        .confirmationDialog(
            "删除主机「\(hostPendingDeletion?.label ?? "")」?",
            isPresented: Binding(
                get: { hostPendingDeletion != nil },
                set: { if !$0 { hostPendingDeletion = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                // 按 id 重新取,模型可能已被外部删除
                if let pending = hostPendingDeletion,
                   let host = allHosts.first(where: { $0.id == pending.id }) {
                    KeychainStore.deleteSecrets(for: host.id)
                    modelContext.delete(host)
                }
                hostPendingDeletion = nil
            }
            Button("取消", role: .cancel) { hostPendingDeletion = nil }
        } message: {
            Text("Keychain 中保存的凭据会一并删除,此操作不可撤销。")
        }
        .confirmationDialog(
            "从 ~/.ssh/config 删除「\(configHostPendingDeletion?.label ?? "")」?",
            isPresented: Binding(
                get: { configHostPendingDeletion != nil },
                set: { if !$0 { configHostPendingDeletion = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let pending = configHostPendingDeletion {
                    SSHConfigService.shared.removeHostFromConfig(alias: pending.label)
                }
                configHostPendingDeletion = nil
            }
            Button("取消", role: .cancel) { configHostPendingDeletion = nil }
        } message: {
            Text("会修改你的 ~/.ssh/config 文件(自动备份为 config.berth-backup),系统 ssh 也会随之生效。")
        }
    }

    /// 搜索框 + 新建主机
    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("搜索主机", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .onSubmit { connectSelectionOrFirst() }
                    .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(theme.elevatedBackground)
                    .overlay(Capsule().stroke(theme.borderColor, lineWidth: 1))
            )

            PanelIconButton(symbol: "plus", help: String(localized: "新建主机")) { isCreatingHost = true }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .onChange(of: searchText) { _, _ in
            if let selected = selectedHostID, !visibleHosts.contains(where: { $0.id == selected }) {
                selectedHostID = visibleHosts.first?.id
            }
        }
    }

    private var hostList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if visibleHosts.isEmpty {
                    Text("没有匹配的主机")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                } else {
                    ForEach(visibleHosts) { host in
                        HostRow(
                            host: host,
                            isSelected: selectedHostID == host.id,
                            theme: theme
                        )
                        // 按下即选中(AppKit 层,无手势判定延迟);⌘ 点按再开一条同主机
                        // 连接;右键仍走 .contextMenu
                        .overlay {
                            PressMouseLayer(
                                onPress: { activate(host) },
                                onCommandPress: { connect(host) }
                            )
                        }
                        .contextMenu { hostMenu(host) }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.return) { connectSelectionOrFirst(); return .handled }
        .onKeyPress(.deleteForward) { requestDeleteSelection(); return .handled }
        .onKeyPress(KeyEquivalent("\u{7F}")) { requestDeleteSelection(); return .handled }
    }

    @ViewBuilder
    private func hostMenu(_ host: Host) -> some View {
        // 单击是「切过去」,这里明确是「再开一条」——同一台主机可以开多个标签
        Button("新建连接(⌘ 点按)") { connect(host) }
        // issue #11:新建连接可选开在当前 pane 的分屏里,而不只有新标签
        if sessionManager.selected != nil {
            Button("在分屏中连接(左右)") { splitConnect(host, axis: .horizontal) }
            Button("在分屏中连接(上下)") { splitConnect(host, axis: .vertical) }
        }
        Button("复制 IP") { copyToPasteboard(host.hostname) }
        Button("复制用户名") { copyToPasteboard(host.username) }
        Button("复制 ssh 命令") { copyToPasteboard(sshCommand(for: host)) }
        if !host.macAddress.isEmpty {
            Button("网络唤醒(Wake-on-LAN)") { wake(host) }
        }
        Divider()
        if host.source == .sshConfig {
            Button("转为托管主机…") { convertToManaged(host) }
            Button("从 config 删除…", role: .destructive) {
                configHostPendingDeletion = PendingHost(id: host.id, label: host.label)
            }
        } else {
            Button("编辑…") { editingHost = host }
            Button("删除…", role: .destructive) {
                hostPendingDeletion = PendingHost(id: host.id, label: host.label)
            }
        }
    }

    /// 底部工具行:左 密钥 + 仪表盘入口,右 主题配色 + 设置(应用级功能放左下角,macOS 惯例)。
    /// 侧栏可以拖到很窄,这行一律用图标 —— 带文字时先被截成「仪…」,反而更难认
    private var keysRow: some View {
        HStack(spacing: 2) {
            PanelIconButton(symbol: "key", help: String(localized: "密钥管理(独立窗口)")) {
                openWindow(id: "keys")
            }
            PanelIconButton(
                symbol: "chart.bar.xaxis",
                help: String(localized: "仪表盘:所有主机的资源状态(⌘0)"),
                tint: sessionManager.isDashboardVisible ? theme.accentColor : nil
            ) {
                withAnimation(.easeOut(duration: 0.18)) {
                    sessionManager.isDashboardVisible.toggle()
                }
            }

            Spacer()

            if let update = UpdateChecker.shared.available {
                PanelIconButton(
                    symbol: "arrow.up.circle.fill",
                    help: String(localized: "新版本 \(update.version) 可用 —— 点击查看"),
                    tint: ThemeStore.shared.current.accentColor
                ) {
                    UpdateChecker.shared.openReleasePage(update)
                }
            }
            PanelIconButton(
                symbol: PrivacyMode.shared.isOn ? "eye.slash.fill" : "eye.slash",
                help: PrivacyMode.shared.isOn
                    ? String(localized: "隐私模式已开启:主机地址已打码,点击恢复")
                    : String(localized: "隐私模式:打码所有主机地址(录屏用)"),
                tint: PrivacyMode.shared.isOn ? ThemeStore.shared.current.accentColor : nil
            ) {
                PrivacyMode.shared.isOn.toggle()
            }
            PanelIconButton(symbol: "paintpalette", help: String(localized: "终端配色")) { isThemePanelPresented.toggle() }
                .popover(isPresented: $isThemePanelPresented, arrowEdge: .top) {
                    ThemePanelView()
                }
            SettingsIconLink()
        }
        .padding(.horizontal, 8)
        // 与右侧终端底部的悬浮状态栏同高同底距,两边内容横向对齐成一条线
        .frame(height: 28)
        .padding(.bottom, 14)
    }

    /// config 里出现了没在导入面板见过的主机时,给一条可点的轻提示(而不是自己冒出来)
    @ViewBuilder
    private var configHintRow: some View {
        let pending = SSHConfigImportPolicy.shared
            .unseenAliases(among: SSHConfigService.shared.candidates.map(\.alias))
        if !pending.isEmpty {
            Button {
                OnboardingController.shared.presentImportPanel()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("ssh_config 新增 \(pending.count) 个主机")
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(theme.accentSoft)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("还没有主机")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                isCreatingHost = true
            } label: {
                Label("新建主机", systemImage: "plus")
            }
            .controlSize(.regular)
            .buttonStyle(.borderedProminent)
            if !SSHConfigService.shared.candidates.isEmpty {
                Button("从 ~/.ssh/config 导入…") {
                    OnboardingController.shared.presentImportPanel()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Text("也可 ⌘K 粘贴 ssh 命令直连")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 行为

    /// 单击行 = 切到这台主机:已经开着就切过去,没开才拨号。
    /// (否则单击连接会让在侧栏上下点几下就攒出一堆同主机标签)
    private func activate(_ host: Host) {
        selectedHostID = host.id
        if let existing = sessionManager.sessions.first(where: { $0.spec.hostID == host.id }) {
            sessionManager.focusPane(existing.id)
            return
        }
        connect(host)
    }

    /// 明确要「再开一个」:⌘ 点按、右键菜单、⌘K 等。总是新拨号,不借用旧连接 ——
    /// 旧会话的 spec 可能已过时(主机编辑后 hostID 不变),借用会静默连到老端点;
    /// 断网后的假活连接(state 还是 connected)借来也只会失败且不自动重连。
    /// 想复用连接开新 PTY 用 ⌘T(复制当前连接)。
    private func connect(_ host: Host) {
        selectedHostID = host.id
        host.lastConnectedAt = Date()
        sessionManager.open(spec: HostSpec.resolve(host, in: allHosts))
    }

    /// issue #11:在当前聚焦 pane 旁分屏连接该主机
    private func splitConnect(_ host: Host, axis: SplitAxis) {
        selectedHostID = host.id
        host.lastConnectedAt = Date()
        sessionManager.splitFocused(axis: axis, spec: HostSpec.resolve(host, in: allHosts))
    }

    /// 网络唤醒:向本机所在子网 + 全局广播发 magic packet
    private func wake(_ host: Host) {
        var broadcasts = ["255.255.255.255"]
        if let subnet = WakeOnLAN.subnetBroadcast(for: host.hostname) {
            broadcasts.insert(subnet, at: 0)
        }
        try? WakeOnLAN.wake(mac: host.macAddress, broadcasts: broadcasts)
    }

    /// 把直连主机(无跳板/无代理)喂给可达性探测
    private func updateReachabilityTargets() {
        let targets = allHosts.map { host in
            (id: host.id, host: host.hostname, port: host.port,
             direct: host.jumpHostID == nil && host.proxy.kind == .none)
        }
        HostReachability.shared.updateTargets(targets)
    }

    /// 回车:有选中连选中,否则连第一个可见结果(搜索场景)
    private func connectSelectionOrFirst() {
        let rows = visibleHosts
        if let selected = selectedHostID, let host = rows.first(where: { $0.id == selected }) {
            activate(host)
        } else if !searchText.isEmpty, let first = rows.first {
            activate(first)
        }
    }

    private func moveSelection(_ delta: Int) {
        let rows = visibleHosts
        guard !rows.isEmpty else { return }
        guard let current = selectedHostID, let index = rows.firstIndex(where: { $0.id == current }) else {
            selectedHostID = delta > 0 ? rows.first?.id : rows.last?.id
            return
        }
        let next = min(max(index + delta, 0), rows.count - 1)
        selectedHostID = rows[next].id
    }

    private func requestDeleteSelection() {
        guard let selected = selectedHostID,
              let host = visibleHosts.first(where: { $0.id == selected }) else { return }
        if host.source == .sshConfig {
            configHostPendingDeletion = PendingHost(id: host.id, label: host.label)
        } else {
            hostPendingDeletion = PendingHost(id: host.id, label: host.label)
        }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func sshCommand(for host: Host) -> String {
        var command = "ssh \(host.username)@\(host.hostname)"
        if host.port != 22 { command += " -p \(host.port)" }
        if host.authMethod == .privateKeyFile, let keyPath = host.privateKeyPath, !keyPath.isEmpty {
            command += " -i \(keyPath)"
        }
        return command
    }

    /// ssh_config 镜像主机 → 可编辑的托管副本
    private func convertToManaged(_ host: Host) {
        // 已转换过 → 直接编辑现有托管主机,不再造副本
        if let existing = allHosts.first(where: {
            $0.source != .sshConfig
                && $0.hostname == host.hostname
                && $0.port == host.port
                && $0.username == host.username
        }) {
            editingHost = existing
            return
        }
        // 未入库的副本:保存时才入库,取消不留脏数据
        editingHost = Host(
            label: host.label,
            hostname: host.hostname,
            port: host.port,
            username: host.username,
            authMethod: host.authMethod,
            privateKeyPath: host.privateKeyPath,
            note: host.note
        )
    }
}

/// 主机行(Termite 同款设计语言):图标列 + 状态竖条 + 13pt 标题 + 10pt 等宽副标题
/// (竖条:连接态 > 可达性 > 标签色);选中 = 浮起材质,不用强调色水洗
private struct HostRow: View {
    let host: Host
    var isSelected = false
    let theme: TerminalTheme
    @Environment(SessionManager.self) private var sessionManager

    @State private var hovering = false
    @State private var reachability = HostReachability.shared

    var body: some View {
        HStack(spacing: 8) {
            // Finder 式图标列:固定宽度对齐成列
            OSBadge(osName: host.osName)
                .frame(width: 20)
            // 状态竖条:连接态 > 可达性 > 标签色,连接中带辉光
            RoundedRectangle(cornerRadius: 1.5)
                .fill(barColor)
                .frame(width: 3, height: 26)
                .shadow(
                    color: {
                        if case .connected = sessionManager.liveState(for: host.id) {
                            return Color.green.opacity(0.6)
                        }
                        return .clear
                    }(),
                    radius: 3
                )
            VStack(alignment: .leading, spacing: 1.5) {
                Text(PrivacyMode.shared.maskHost(in: host.label, hostname: host.hostname))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(PrivacyMode.shared.maskHost(in: host.address, hostname: host.hostname))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if host.source == .sshConfig {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                    .help("来自 ~/.ssh/config(只读)")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        // 选中 = 浮起(与标题栏选中标签同一块材质);悬停只给 6% 底确认目标形状
        .background {
            if isSelected {
                RaisedCapsule()
            } else if hovering {
                Capsule().fill(Color.primary.opacity(0.06))
            }
        }
        .foregroundStyle(isSelected ? .primary : .secondary)
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help("\(PrivacyMode.shared.maskHost(in: host.address, hostname: host.hostname))\(host.lastConnectedAt.map { String(localized: " · 最近连接 ") + $0.formatted(.relative(presentation: .named)) } ?? "")")
    }

    /// 竖条颜色:连接态 > 可达性 > 标签色;全无信息时回落淡灰
    private var barColor: Color {
        switch sessionManager.liveState(for: host.id) {
        case .connected: return .green
        case .connecting: return .yellow
        case .none:
            switch reachability.statuses[host.id] {
            case .reachable: return Color.green.opacity(0.5)
            case .unreachable: return Color.red.opacity(0.4)
            case .unknown, nil:
                return host.tagColor == .none ? Color.gray.opacity(0.18) : host.tagColor.color.opacity(0.45)
            }
        }
    }
}


/// 设置入口:SettingsLink 套 PanelIconButton 同款外观(SettingsLink 不能换成普通 Button,
/// macOS 14+ 打开设置窗口只有这一个受支持入口)
private struct SettingsIconLink: View {
    @State private var hovering = false

    var body: some View {
        SettingsLink {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                )
                .scaleEffect(hovering ? 1.06 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableIconStyle())
        .foregroundStyle(.secondary)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help("设置(⌘,)")
    }
}

/// 通用行悬停底色
private struct RowHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                Capsule()
                    .fill(hovering ? Color.primary.opacity(0.06) : .clear)
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension TagColor {
    var color: Color {
        switch self {
        case .none: return .gray
        case .red: return .red
        case .orange: return .orange
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }
}
