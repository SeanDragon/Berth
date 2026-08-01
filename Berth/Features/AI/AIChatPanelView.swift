import SwiftUI

/// 右侧 AI 对话面板:与 SFTP/信息面板同构。对话按会话隔离(AIChatStore),
/// 关闭面板保留历史,关闭会话时清理。
struct AIChatPanelView: View {
    let session: TerminalSession
    let onClose: () -> Void

    @State private var controller: AIChatController
    @State private var draft = ""
    @State private var settings = AISettingsStore.shared
    @FocusState private var inputFocused: Bool

    private var theme: TerminalTheme { ThemeStore.shared.current }

    init(session: TerminalSession, onClose: @escaping () -> Void) {
        self.session = session
        self.onClose = onClose
        _controller = State(initialValue: AIChatStore.shared.controller(for: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: String(localized: "AI 助手")) {
                if !controller.messages.isEmpty {
                    PanelIconButton(symbol: "trash", help: String(localized: "清空对话")) {
                        controller.clear()
                    }
                }
                PanelIconButton(symbol: "xmark", help: String(localized: "关闭")) { onClose() }
            }
            Divider().overlay(theme.borderColor)
            if !settings.isConfigured {
                setupState
            } else if controller.messages.isEmpty {
                emptyState
            } else {
                messageList
            }
            if settings.isConfigured {
                Divider().overlay(theme.borderColor)
                inputBar
            }
        }
        .frame(width: 320)
        .background(theme.panelBackground)
        // 别的设备经 iCloud 钥匙串同步过来的 Key,回到前台时也认
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.messages) { message in
                        AIChatMessageView(message: message, controller: controller, session: session)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(10)
            }
            .onChange(of: controller.messages.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: controller.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // MARK: - 输入栏

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 输入区做成一个明确的输入盒:底色 + 描边,聚焦时描边转强调色,和上方消息流区分开
    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(String(localized: "让 AI 在这台服务器上执行操作…"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { sendDraft() }
                .frame(minHeight: 22, alignment: .leading)
            if controller.isBusy {
                Button {
                    controller.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(theme.accentColor))
                }
                .buttonStyle(.plain)
                .help(String(localized: "停止"))
            } else {
                Button {
                    sendDraft()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(canSend ? Color.white : Color.secondary)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle().fill(canSend ? theme.accentColor : Color.secondary.opacity(0.18))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help(String(localized: "发送(⏎)"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.elevatedBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            inputFocused ? theme.accentColor.opacity(0.7) : theme.borderColor,
                            lineWidth: 1
                        )
                )
        )
        .animation(.easeOut(duration: 0.15), value: inputFocused)
        .padding(10)
        // 点空白处也能聚焦,不必正好点中那一行字
        .contentShape(Rectangle())
        .onTapGesture { inputFocused = true }
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        controller.send(text)
        inputFocused = true
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("用对话操作服务器")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("例如「看看磁盘还剩多少」「nginx 挂了没」。\nAI 建议的命令默认需要你确认后才执行。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private var setupState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("先配置 API Key")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("在设置的「AI 助手」里填入 Anthropic API Key 后即可通过对话操作服务器。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            SettingsLink {
                Text("打开设置…")
            }
            .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }
}

// MARK: - 单条消息

struct AIChatMessageView: View {
    let message: AIChatMessage
    let controller: AIChatController
    let session: TerminalSession

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 32)
                Text(message.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(theme.accentSoft)
                    )
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                // 正文按围栏拆开:段落走行内 Markdown,代码块出可复制/可发送的卡片
                ForEach(Array(AIMarkdownParser.parse(message.text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let text):
                        Text(rendered(text))
                            .font(.system(size: 12.5))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .heading(let level, let text):
                        Text(rendered(text))
                            .font(.system(size: level <= 2 ? 14 : 13, weight: .semibold))
                            .textSelection(.enabled)
                            .padding(.top, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .list(let items):
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(item.marker)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                    Text(rendered(item.text))
                                        .font(.system(size: 12.5))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    case .quote(let text):
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(theme.accentColor.opacity(0.4))
                                .frame(width: 3)
                            Text(rendered(text))
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    case .divider:
                        Divider()
                    case .code(let language, let code):
                        AICodeBlockView(language: language, code: code, session: session)
                    }
                }
                ForEach(message.toolCalls) { call in
                    AIToolCallCard(call: call, controller: controller)
                }
                if let errorText = message.errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if message.text.isEmpty && message.toolCalls.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    /// 尽力渲染 Markdown(行内样式 + 保留换行),失败退回纯文本
    private func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - 代码块

/// AI 给出的命令/代码:等宽卡片 + 复制 + 一键送进当前终端。
/// 送进终端只写入不回车,由用户按 ⏎ 决定是否执行(危险命令走粘贴保护那套确认)。
private struct AICodeBlockView: View {
    let language: String?
    let code: String
    let session: TerminalSession

    @State private var copied = false
    @State private var pendingConfirm = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(language?.lowercased() ?? String(localized: "代码"))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(
                        copied ? String(localized: "已复制") : String(localized: "复制"),
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.system(size: 10))
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? .green : .secondary)
                Button {
                    sendToTerminal()
                } label: {
                    Label(String(localized: "发送到终端"), systemImage: "arrow.turn.down.left")
                        .font(.system(size: 10))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentColor)
                .help(String(localized: "写入终端命令行,不自动回车"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            Divider().overlay(theme.borderColor)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.elevatedBackground)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderColor, lineWidth: 1))
        )
        .confirmationDialog(
            String(localized: "发送到终端?"),
            isPresented: $pendingConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "发送"), role: .destructive) { session.sendText(code) }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(BerthTerminalView.preview(code))
        }
    }

    /// 多行或危险命令按粘贴保护的规矩先确认(生产主机一律确认)
    private func sendToTerminal() {
        let protectionOn = UserDefaults.standard.object(forKey: SettingsKeys.pasteProtection) as? Bool ?? true
        let risky = BerthTerminalView.needsConfirmation(code) || session.spec.isProduction
        if protectionOn, risky {
            pendingConfirm = true
        } else {
            session.sendText(code)
        }
    }
}

// MARK: - 命令卡片

private struct AIToolCallCard: View {
    let call: AIToolCall
    let controller: AIChatController

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 命令行
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Text(call.command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                statusBadge
            }
            .padding(8)

            if call.status == .awaitingApproval {
                Divider().overlay(theme.borderColor)
                HStack(spacing: 8) {
                    if BerthTerminalView.needsConfirmation(call.command) {
                        Label("危险命令", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("拒绝") { controller.deny(call) }
                        .controlSize(.small)
                    Button("运行") { controller.approve(call) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }

            if call.status == .done, !call.output.isEmpty {
                Divider().overlay(theme.borderColor)
                Button {
                    call.isOutputExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: call.isOutputExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(call.isOutputExpanded ? "隐藏输出" : "显示输出")
                            .font(.caption2)
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if call.isOutputExpanded {
                    ScrollView {
                        Text(call.output)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 180)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.elevatedBackground)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.borderColor, lineWidth: 1))
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch call.status {
        case .awaitingApproval:
            Text("待确认")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .done:
            if let code = call.exitCode, code != 0 {
                Text(verbatim: "✕ \(code)")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .help(String(localized: "退出码 \(String(code))"))
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
            }
        case .denied:
            Text("已拒绝")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
