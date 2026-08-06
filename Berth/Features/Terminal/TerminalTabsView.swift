import SwiftData
import SwiftUI

/// 右侧终端区:标签条 + 当前会话终端 + 断线横幅。
struct TerminalTabsView: View {
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.openWindow) private var openWindow
    /// 终端区实测宽度:标题栏行(chips+按钮)按它定宽,才能让标签区铺满整个标题栏
    /// (toolbar 的分段布局不给 navigation 项撑满的机会,只能显式给宽)
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        @Bindable var manager = sessionManager
        VStack(spacing: 0) {
            if sessionManager.tabs.isEmpty {
                emptyState
            } else if let tab = sessionManager.selectedTab {
                if tab.isBroadcasting {
                    broadcastBanner
                }
                HStack(spacing: 0) {
                    // 单 pane 不显示焦点边框(只有分屏时才需要区分)
                    PaneTreeView(
                        node: tab.root,
                        focusedID: tab.focusedID,
                        showsFocus: tab.root.leafIDs().count > 1,
                        broadcasting: tab.isBroadcasting
                    ) { id in
                        sessionManager.focusPane(id)
                    }
                    if let session = sessionManager.selected {
                        // SFTP/Docker/服务器信息是 SSH 专属能力,本地 Shell 会话不挂载
                        if sessionManager.isSFTPVisible, !session.spec.isLocal {
                            Divider().overlay(ThemeStore.shared.current.borderColor)
                            SFTPPanelView(session: session) {
                                sessionManager.isSFTPVisible = false
                            }
                            .id(session.id)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                        if sessionManager.isDockerPanelVisible, !session.spec.isLocal {
                            Divider().overlay(ThemeStore.shared.current.borderColor)
                            DockerPanelView(session: session) {
                                sessionManager.isDockerPanelVisible = false
                            }
                            .id(session.id)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                        if sessionManager.isInspectorVisible, !session.spec.isLocal {
                            Divider().overlay(ThemeStore.shared.current.borderColor)
                            ServerInfoInspector(session: session) {
                                sessionManager.isInspectorVisible = false
                            }
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                        if sessionManager.isSnippetsPanelVisible {
                            Divider().overlay(ThemeStore.shared.current.borderColor)
                            SnippetsPanelView {
                                sessionManager.isSnippetsPanelVisible = false
                            }
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                        if sessionManager.isAIPanelVisible {
                            Divider().overlay(ThemeStore.shared.current.borderColor)
                            AIChatPanelView(session: session) {
                                sessionManager.isAIPanelVisible = false
                            }
                            .id(session.id)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }
                if let session = sessionManager.selected {
                    StatusBarView(session: session)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ThemeStore.shared.current.chromeBackground)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            contentWidth = width
        }
        // 顶部统一一行:标签 chips 靠左伸展 | 面板按钮组钉右(会话信息胶囊移入底部状态栏,
        // 给标签让位)。toolbar 的分段布局不让单个 item 撑满,所以按终端区实测宽度显式定宽,
        // 行内用 Spacer 自己排布。
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    if !sessionManager.tabs.isEmpty { toolbarRow }
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    if !sessionManager.tabs.isEmpty { toolbarRow }
                }
            }
        }
        .alert(
            "关闭分屏「\(sessionManager.pendingCloseSession?.spec.label ?? "")」?",
            isPresented: Binding(
                get: { manager.pendingCloseSession != nil },
                set: { if !$0 { manager.pendingCloseSession = nil } }
            )
        ) {
            Button("断开并关闭", role: .destructive) {
                if let session = sessionManager.pendingCloseSession {
                    sessionManager.closePane(session)
                }
                manager.pendingCloseSession = nil
            }
            Button("取消", role: .cancel) { manager.pendingCloseSession = nil }
        } message: {
            Text(sessionManager.pendingCloseSession?.spec.isLocal == true
                ? String(localized: "该分屏有正在运行的本地 Shell。")
                : String(localized: "该分屏有活跃的 SSH 连接。"))
        }
        .alert(
            "关闭标签页?",
            isPresented: Binding(
                get: { manager.pendingCloseTab != nil },
                set: { if !$0 { manager.pendingCloseTab = nil } }
            )
        ) {
            Button("断开并关闭", role: .destructive) {
                if let tab = sessionManager.pendingCloseTab {
                    sessionManager.closeTab(tab)
                }
                manager.pendingCloseTab = nil
            }
            Button("取消", role: .cancel) { manager.pendingCloseTab = nil }
        } message: {
            Text({
                let firstLeaf = sessionManager.pendingCloseTab?.root.firstLeaf
                let isLocal = firstLeaf.flatMap { sessionManager.session($0) }?.spec.isLocal == true
                return isLocal
                    ? String(localized: "该标签页含正在运行的本地 Shell(可能有多个分屏)。")
                    : String(localized: "该标签页含活跃的 SSH 连接(可能有多个分屏)。")
            }())
        }
    }

    /// 标题栏整行:chips 靠左伸展占满剩余宽度,面板按钮组钉右。宽度取终端区实测值,
    /// 留出 navigation 项自身的左右边距
    private var toolbarRow: some View {
        HStack(spacing: 8) {
            tabChips
            Spacer(minLength: 8)
            panelButtons
        }
        .frame(width: max(contentWidth - 28, 0))
    }

    /// 标签 chips(标题栏左侧):每个标签一枚 chip(含嵌套分屏);两端渐隐,选中自动滚入;
    /// 「+」新建菜单跟在最后一个 chip 后(Chrome 式),随标签一起滚动
    private var tabChips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(sessionManager.tabs) { tab in
                        TerminalTabChip(
                            tab: tab,
                            focusedSession: sessionManager.session(tab.focusedID),
                            paneCount: tab.root.leafIDs().count,
                            isSelected: tab.id == sessionManager.selectedTabID,
                            select: { sessionManager.selectTab(tab.id) },
                            close: { sessionManager.requestCloseTab(tab) }
                        )
                        .id(tab.id)
                    }
                    newTabMenu
                }
                .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 12)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 12)
                }
            )
            .onChange(of: sessionManager.selectedTabID) { _, selected in
                guard let selected else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(selected, anchor: .center) }
            }
        }
    }

    /// 「+」新建菜单:本地 Shell / 复制当前连接 / 快速连接
    private var newTabMenu: some View {
        Menu {
            Button {
                _ = sessionManager.open(spec: .localShell())
            } label: {
                Label(String(localized: "新建本地 Shell"), systemImage: "terminal")
            }
            Button {
                sessionManager.duplicateCurrent()
            } label: {
                Label(String(localized: "复制当前连接为新标签"), systemImage: "plus.square.on.square")
            }
            .disabled(sessionManager.selected == nil)
            Button {
                QuickConnectController.shared.toggle()
            } label: {
                Label(String(localized: "快速连接…"), systemImage: "bolt.fill")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("新建标签页(本地 Shell / 快速连接)")
    }

    /// Safari 式按钮组(标题栏右侧):一个大胶囊容器,内含各个圆形悬停按钮
    private var panelButtons: some View {
        HStack(spacing: 2) {
            PanelIconButton(
                symbol: "sparkles",
                help: String(localized: "AI 助手(⌘⇧A)"),
                tint: sessionManager.isAIPanelVisible ? ThemeStore.shared.current.accentColor : nil
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    sessionManager.isAIPanelVisible.toggle()
                }
            }
            PanelIconButton(
                symbol: "curlybraces",
                help: String(localized: "命令片段(⌘⇧S)"),
                tint: sessionManager.isSnippetsPanelVisible ? ThemeStore.shared.current.accentColor : nil
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    sessionManager.isSnippetsPanelVisible.toggle()
                }
            }
            // SSH 专属面板按钮:本地 Shell 会话不显示
            if sessionManager.selected?.spec.isLocal != true {
                PanelIconButton(
                    symbol: "folder",
                    help: String(localized: "SFTP 文件(⌘⇧F)"),
                    tint: sessionManager.isSFTPVisible ? ThemeStore.shared.current.accentColor : nil
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        sessionManager.isSFTPVisible.toggle()
                    }
                }
                PanelIconButton(
                    symbol: "shippingbox",
                    help: String(localized: "Docker 状态"),
                    tint: sessionManager.isDockerPanelVisible ? ThemeStore.shared.current.accentColor : nil
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        sessionManager.isDockerPanelVisible.toggle()
                    }
                }
                PanelIconButton(
                    symbol: "sidebar.right",
                    help: String(localized: "服务器信息(⌘I)"),
                    tint: sessionManager.isInspectorVisible ? ThemeStore.shared.current.accentColor : nil
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        sessionManager.isInspectorVisible.toggle()
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(ThemeStore.shared.current.elevatedBackground)
                .overlay(Capsule().stroke(ThemeStore.shared.current.borderColor, lineWidth: 1))
        )
    }

    /// 广播模式横幅:提示所有分屏同步接收键入
    private var broadcastBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 10))
            Text("广播输入:键入同步到当前标签所有分屏")
                .font(.system(size: 11, weight: .medium))
            Spacer()
            Button("停止") { sessionManager.toggleBroadcast() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.85))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("点击左侧主机开始连接")
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    QuickConnectController.shared.toggle()
                } label: {
                    Label(String(localized: "快速连接"), systemImage: "bolt.fill")
                }
                Button {
                    _ = sessionManager.open(spec: .localShell())
                } label: {
                    Label(String(localized: "本地 Shell"), systemImage: "terminal")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.top, 6)
            Text(verbatim: "⌘K · ⇧⌘T")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 分屏树递归视图:叶子=一个终端 pane(可点按聚焦、聚焦有强调边框),分支=按方向二分
private struct PaneTreeView: View {
    let node: PaneNode
    let focusedID: UUID
    var showsFocus: Bool = true
    var broadcasting: Bool = false
    let onFocus: (UUID) -> Void
    @Environment(SessionManager.self) private var sessionManager

    var body: some View {
        switch node {
        case .leaf(let sid):
            if let session = sessionManager.session(sid) {
                TerminalPaneView(session: session)
                    .id(sid)
                    .overlay(
                        Rectangle()
                            .stroke(borderColor(sid), lineWidth: broadcasting ? 1.5 : 1.5)
                            .allowsHitTesting(false)
                    )
                    // 点非聚焦 pane 时先聚焦(不吞掉终端本身的交互)
                    .onTapGesture { if sid != focusedID { onFocus(sid) } }
            } else {
                Color.clear
            }
        case .branch(_, let axis, let first, let second):
            let layout = axis == .horizontal
                ? AnyLayout(HStackLayout(spacing: 1))
                : AnyLayout(VStackLayout(spacing: 1))
            layout {
                PaneTreeView(node: first, focusedID: focusedID, showsFocus: showsFocus, broadcasting: broadcasting, onFocus: onFocus)
                Rectangle()
                    .fill(ThemeStore.shared.current.borderColor)
                    .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
                PaneTreeView(node: second, focusedID: focusedID, showsFocus: showsFocus, broadcasting: broadcasting, onFocus: onFocus)
            }
        }
    }

    private func borderColor(_ sid: UUID) -> Color {
        // 广播时所有 pane 橙色边框;否则仅聚焦 pane 强调色边框
        if broadcasting { return .orange.opacity(0.7) }
        if showsFocus, sid == focusedID { return ThemeStore.shared.current.accentColor.opacity(0.55) }
        return .clear
    }
}

private struct TerminalTabChip: View {
    let tab: PaneTab
    let focusedSession: TerminalSession?
    let paneCount: Int
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false
    /// 双击/右键重命名:行内 TextField 编辑,回车/失焦提交,Esc 取消
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    /// 自定义名优先;否则跟随聚焦会话(主机打码规则不变)
    private var displayTitle: String {
        if let custom = tab.customTitle, !custom.isEmpty { return custom }
        return focusedSession.map { PrivacyMode.shared.maskHost(in: $0.spec.label, hostname: $0.spec.hostname) } ?? String(localized: "终端")
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
            if isRenaming {
                TextField("", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: max(64, CGFloat(renameDraft.count) * 7 + 14))
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand {
                        isRenaming = false
                        focusedSession?.focusTerminal()
                    }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused, isRenaming { commitRename() }
                    }
            } else {
                Text(displayTitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            if paneCount > 1 {
                Text("\(paneCount)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .help("\(paneCount) 个分屏")
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isSelected ? 0.7 : 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(isSelected ? ThemeStore.shared.current.accentSoft : (isHovering ? Color.primary.opacity(0.06) : .clear))
        )
        .overlay(
            Capsule()
                .stroke(isSelected ? ThemeStore.shared.current.accentColor.opacity(0.35) : .clear, lineWidth: 1)
        )
        .foregroundStyle(isSelected ? .primary : .secondary)
        .contentShape(Capsule())
        .animation(.easeOut(duration: 0.12), value: isHovering)
        // 事件层用真 NSView:标题栏里 SwiftUI 手势抢不过窗口拖拽(macOS 15),
        // 且双 tap 组合会给单击加判定延迟。重命名时撤掉,让 TextField 接点击;
        // 尾部让出 × 按钮的响应区
        .overlay {
            if !isRenaming {
                ChipMouseLayer(onPress: select, onDoubleClick: startRename)
                    .padding(.trailing, (isHovering || isSelected) ? 26 : 0)
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(String(localized: "重命名标签")) { startRename() }
            if tab.customTitle != nil {
                Button(String(localized: "恢复默认名称")) { tab.customTitle = nil }
            }
            Divider()
            Button(String(localized: "关闭标签页"), role: .destructive, action: close)
        }
    }

    private func startRename() {
        renameDraft = tab.customTitle ?? displayTitle
        isRenaming = true
        // TextField 要等下一个 runloop 挂上视图层级,focus 才生效
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customTitle = trimmed.isEmpty ? nil : trimmed
        isRenaming = false
        focusedSession?.focusTerminal()
    }

    private var stateColor: Color {
        switch focusedSession?.state {
        case .idle, .none: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .disconnected(let reason):
            return reason == .userInitiated ? .gray : .red
        }
    }
}

/// chip 的 AppKit 事件层:标题栏里的 SwiftUI 手势在 macOS 15 抢不过窗口拖拽,
/// 用真 NSView 接管 —— 按下即选中(无双击判定延迟)、双击改名、掐断标题栏拖窗。
private struct ChipMouseLayer: NSViewRepresentable {
    let onPress: () -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> MouseView {
        let view = MouseView()
        update(view)
        return view
    }

    func updateNSView(_ view: MouseView, context: Context) {
        update(view)
    }

    private func update(_ view: MouseView) {
        view.onPress = onPress
        view.onDoubleClick = onDoubleClick
    }

    final class MouseView: NSView {
        var onPress: (() -> Void)?
        var onDoubleClick: (() -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }
        /// 后台窗口点标签一击即选(原生标签栏行为),不用先点一下激活窗口
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// 自己不出菜单:返回 nil 让右键沿响应链交给 SwiftUI 的 .contextMenu
        override func menu(for event: NSEvent) -> NSMenu? { nil }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick?()
            } else {
                onPress?()  // 首击已选中,连击改名正好落在已选中的标签上
            }
        }
    }
}

/// 单个会话面板:终端 + 顶部状态/断线横幅 + ⌘F 搜索 + 主机密钥确认
struct TerminalPaneView: View {
    @Bindable var session: TerminalSession
    @Environment(SessionManager.self) private var sessionManager
    @Environment(\.modelContext) private var modelContext

    @State private var searchModel = TerminalSearchModel()
    @State private var isSearchActive = false
    @State private var dropModel = TerminalDropUploadModel()
    @State private var isDropTargeted = false
    @State private var editingHost: Host?
    @State private var confirmingDelete = false
    /// 最近一次断线原因;非 nil 即挂着断线卡片。连上才清空,重连失败只换文案不重挂
    @State private var lastDisconnect: TerminalSession.DisconnectReason?
    /// 最近一次尝试结束的时间 —— 重连失败时错误文案一字不变,没有它用户看不出点动过
    @State private var lastAttemptAt: Date?
    /// 保证转圈至少可见一会儿:EHOSTUNREACH 是瞬时失败,不兜底的话按钮闪都不闪
    @State private var isRetryingVisibly = false

    private var isConnecting: Bool {
        if case .connecting = session.state { return true }
        return false
    }

    private var showsRetrySpinner: Bool { isConnecting || isRetryingVisibly }

    private func retry() {
        isRetryingVisibly = true
        session.connect()
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            isRetryingVisibly = false // 还没连完的话由 isConnecting 接着转
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            hostStrip
            ZStack(alignment: .top) {
                TerminalHostView(terminalView: session.terminalView)
                    .padding(.leading, 8)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: ThemeStore.shared.current.backgroundNSColor))

                banner

                disconnectCard
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 10)
                    // 只在卡片进出时动;重连失败不该重放一遍入场动画
                    .animation(.spring(response: 0.38, dampingFraction: 0.82), value: lastDisconnect == nil)

            if isSearchActive {
                HStack {
                    Spacer()
                    TerminalSearchBar(model: searchModel) {
                        isSearchActive = false
                        searchModel.update(query: "")
                        session.focusTerminal()
                    }
                    .padding(.trailing, 12)
                }
            }

            TerminalDropOverlay(model: dropModel)
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                // 分流:本地 Shell 按 Terminal.app 惯例把路径写进命令行;SSH 会话走 SFTP 上传
                if session.spec.isLocal {
                    return insertDroppedPaths(providers)
                }
                return dropModel.handleDrop(providers, session: session)
            }
            .onChange(of: isDropTargeted) { _, targeted in
                guard !session.spec.isLocal else { return }
                targeted ? dropModel.dragEntered(session: session) : dropModel.dragExited()
            }
        }
        .sheet(item: $dropModel.pendingBatch) { batch in
            DropDestinationSheet(batch: batch, model: dropModel, session: session)
        }
        .confirmationDialog(
            "远端已有同名文件",
            isPresented: Binding(
                get: { dropModel.pendingOverwrite != nil },
                set: { if !$0 { dropModel.pendingOverwrite = nil } }
            ),
            presenting: dropModel.pendingOverwrite
        ) { pending in
            Button("覆盖", role: .destructive) {
                dropModel.resolveOverwrite(pending, overwrite: true, session: session)
            }
            Button("跳过同名文件") {
                dropModel.resolveOverwrite(pending, overwrite: false, session: session)
            }
            Button("取消", role: .cancel) {}
        } message: { pending in
            Text("目标目录 \(pending.directory) 已存在:\(pending.conflicts.joined(separator: "、"))")
        }
        .task {
            // 启动恢复出来的标签是 idle 的(见 restoreSessions),切到哪个才连哪个
            if case .idle = session.state { session.connect() }
        }
        .onChange(of: session.state) { _, state in
            switch state {
            case .disconnected(let reason):
                lastDisconnect = reason
                lastAttemptAt = Date()
            case .connected:
                lastDisconnect = nil
                lastAttemptAt = nil
            case .connecting, .idle: break // 重连中:卡片留着,按钮转圈
            }
        }
        .onChange(of: sessionManager.searchRequestToken) { _, _ in
            // 只有当前选中会话响应 ⌘F
            guard session.id == sessionManager.selectedID else { return }
            searchModel.terminalView = session.terminalView
            isSearchActive = true
        }
        .sheet(
            item: $session.hostKeyPrompt,
            onDismiss: { session.resolveHostKeyPrompt(accepted: false) }
        ) { prompt in
            HostKeyPromptSheet(prompt: prompt, session: session)
        }
        .sheet(item: $editingHost) { host in
            HostEditorView(host: host, defaultGroupID: nil, onConnect: { updated in
                // 用新配置重连:关掉失败的会话,重新解析 spec 开新会话(旧 spec 冻结了改动前的认证方式)
                sessionManager.closePane(session)
                let all = ((try? modelContext.fetch(FetchDescriptor<Host>())) ?? [updated]) + SSHConfigService.shared.mirrorHosts
                updated.lastConnectedAt = Date()
                _ = sessionManager.open(spec: HostSpec.resolve(updated, in: all))
            })
        }
        .confirmationDialog(
            "删除主机「\(session.spec.label)」?",
            isPresented: $confirmingDelete
        ) {
            Button("删除", role: .destructive) { deleteHost() }
            Button("取消", role: .cancel) { confirmingDelete = false }
        } message: {
            Text(deleteWarning)
        }
    }

    /// 本地 Shell 的拖拽:把文件路径(转义后)写进命令行,多个文件按拖入顺序空格分隔
    private func insertDroppedPaths(_ providers: [NSItemProvider]) -> Bool {
        let items = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !items.isEmpty else { return false }
        Task { @MainActor in
            var paths: [String] = []
            for provider in items {
                let url: URL? = await withCheckedContinuation { cont in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        cont.resume(returning: url)
                    }
                }
                if let url { paths.append(url.path) }
            }
            guard !paths.isEmpty else { return }
            session.sendText(paths.map(BerthTerminalView.shellEscaped).joined(separator: " ") + " ")
        }
        return true
    }

    private var deleteWarning: String {
        let hostID = session.spec.hostID
        let all = ((try? modelContext.fetch(FetchDescriptor<Host>())) ?? []) + SSHConfigService.shared.mirrorHosts
        if all.first(where: { $0.id == hostID })?.source == .sshConfig {
            return String(localized: "会修改你的 ~/.ssh/config 文件(自动备份为 config.berth-backup),系统 ssh 也会随之生效。")
        }
        return String(localized: "Keychain 中保存的凭据会一并删除,此操作不可撤销。")
    }

    /// 删除主机并关闭该会话;config 镜像从 ~/.ssh/config 移除(自动备份)
    private func deleteHost() {
        let hostID = session.spec.hostID
        let all = ((try? modelContext.fetch(FetchDescriptor<Host>())) ?? []) + SSHConfigService.shared.mirrorHosts
        if let host = all.first(where: { $0.id == hostID }) {
            if host.source == .sshConfig {
                SSHConfigService.shared.removeHostFromConfig(alias: host.label)
            } else {
                KeychainStore.deleteSecrets(for: host.id)
                modelContext.delete(host)
                // 显式保存,让侧栏 @Query 立即刷新
                try? modelContext.save()
            }
        }
        sessionManager.closePane(session)
    }

    /// 断线横幅的编辑入口:托管主机直接编辑;config 镜像优先复用已转换的托管主机,
    /// 否则给一份未入库的副本(保存时才入库,取消不留脏数据)
    private func editHost() {
        let hostID = session.spec.hostID
        let all = ((try? modelContext.fetch(FetchDescriptor<Host>())) ?? []) + SSHConfigService.shared.mirrorHosts
        guard let host = all.first(where: { $0.id == hostID }) else { return }
        if host.source == .sshConfig {
            if let existing = all.first(where: {
                $0.source != .sshConfig
                    && $0.hostname == host.hostname
                    && $0.port == host.port
                    && $0.username == host.username
            }) {
                editingHost = existing
            } else {
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
        } else {
            editingHost = host
        }
    }

    /// 非生产主机若设了标签色,顶部一条细色带区分环境(生产环境改由标题胶囊变红提示)
    @ViewBuilder
    private var hostStrip: some View {
        let tag = TagColor(rawValue: session.spec.tagColorRaw) ?? .none
        if !session.spec.isProduction, tag != .none {
            Rectangle()
                .fill(tag.color)
                .frame(height: 3)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var banner: some View {
        switch session.state {
        case .connecting(let detail):
            bannerBody(color: .yellow) {
                ProgressView()
                    .controlSize(.mini)
                Text(detail)
            }
        case .idle, .connected, .disconnected:
            EmptyView()
        }
    }

    /// 断线呈现:紧凑居中卡片(原生 alert 布局)—— 图标内联标题,文案左对齐,按钮右对齐。
    /// 挂载条件是 `lastDisconnect` 而不是当前 state:重连期间卡片留在原地换成进度条,
    /// 否则一失败就是「卡片滑走 → 再从上面滑回来」,点几次重连眼睛要花。
    @ViewBuilder
    private var disconnectCard: some View {
        if let reason = lastDisconnect {
            let accent: Color = reason == .userInitiated ? .secondary : .red
            let theme = ThemeStore.shared.current
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "bolt.slash.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(accent)
                    Text(PrivacyMode.shared.maskHost(in: session.spec.label, hostname: session.spec.hostname))
                        .font(.system(size: 16, weight: .semibold))
                    Spacer(minLength: 0)
                }
                Text(session.spec.isLocal
                    ? LocalShell.resolvedShellPath()
                    : "\(session.spec.username)@\(PrivacyMode.shared.mask(session.spec.hostname))")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // 重连期间不换文案:进度只体现在按钮上,卡片高度纹丝不动。
                // 换成进度行会让按钮整排上跳再弹回,点几次就是一片残影
                Text(reason.message ?? String(localized: "连接已断开"))
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let lastAttemptAt {
                    Text("最近尝试 \(lastAttemptAt.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                if session.isAutoReconnectScheduled {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("自动重连中(第 \(session.reconnectAttempt) 次)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("停止") { session.cancelAutoReconnect() }
                            .controlSize(.small)
                        Spacer()
                    }
                }
                HStack(spacing: 10) {
                    // 本地 Shell 没有主机记录,删除/编辑不适用
                    if !session.spec.isLocal {
                        Button(role: .destructive) {
                            confirmingDelete = true
                        } label: {
                            Text("删除")
                                .font(.system(size: 13.5))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(showsRetrySpinner)
                        Button {
                            editHost()
                        } label: {
                            Text("编辑主机")
                                .font(.system(size: 13.5))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(showsRetrySpinner)
                    }
                    Button(action: retry) {
                        // 转圈期间按钮本身不置灰 —— 置灰的 ProgressView 看着像卡死。
                        // 靠 allowsHitTesting 挡住重复点击
                        ZStack {
                            Text("立即重连")
                                .opacity(showsRetrySpinner ? 0 : 1)
                            if showsRetrySpinner {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                        }
                        .font(.system(size: 13.5))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .allowsHitTesting(!showsRetrySpinner)
                }
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
                .padding(.top, 4)
            }
            .padding(18)
            .frame(width: 340)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.elevatedBackground))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.borderColor, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func bannerBody(color: Color, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
        )
        .padding(.top, 8)
    }
}
