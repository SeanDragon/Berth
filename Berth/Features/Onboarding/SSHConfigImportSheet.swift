import SwiftUI

/// 首次启动的 ssh_config 导入引导,也用作之后的「管理 config 主机」面板。
///
/// 老行为是启动即把整个 config 铺进侧栏,几十条陌生主机糊满一屏,文件里读不懂的地方
/// 也只能靠事后连不上才发现。这里改成:先问一次,勾了哪些显示哪些;读不懂的地方
/// 归到一处折叠展示,而不是变成一串弹窗。
struct SSHConfigImportSheet: View {
    /// true = 首次启动的欢迎形态(文案与按钮不同)
    let isWelcome: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var service = SSHConfigService.shared
    @State private var themeStore = ThemeStore.shared
    @State private var selection: Set<String> = []
    @State private var query = ""
    @State private var isShowingIssues = false
    @State private var didLoadSelection = false

    private var theme: TerminalTheme { themeStore.current }
    private var candidates: [SSHConfigHost] { service.candidates }

    private var filtered: [SSHConfigHost] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return candidates }
        return candidates.filter {
            $0.alias.localizedCaseInsensitiveContains(text)
                || $0.hostname.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.borderColor)
            if candidates.isEmpty {
                emptyState
            } else {
                selectionBar
                hostList
            }
            if !service.issues.isEmpty {
                Divider().overlay(theme.borderColor)
                issuesSection
            }
            Divider().overlay(theme.borderColor)
            footer
        }
        .frame(width: 540, height: 580)
        .background(theme.panelBackground)
        .tint(theme.accentColor)
        // 只作用于本子树:preferredColorScheme 会连带翻掉承载它的窗口
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .interactiveDismissDisabled(isWelcome)
        .task {
            guard !didLoadSelection else { return }
            didLoadSelection = true
            selection = initialSelection()
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isWelcome ? "sailboat.fill" : "doc.text")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(isWelcome ? "欢迎使用 Berth" : "~/.ssh/config 主机")
                    .font(.title3.bold())
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var subtitle: String {
        if candidates.isEmpty {
            return String(localized: "~/.ssh/config 里暂时没有可导入的主机。你可以直接新建主机,或按 ⌘K 粘贴一条 ssh 命令连接。")
        }
        if isWelcome {
            return String(localized: "在 ~/.ssh/config 里找到 \(candidates.count) 个主机。勾选想显示在侧栏的,其余以后可以在设置里再加。Berth 只读这个文件,不会改动它。")
        }
        return String(localized: "勾选要显示在侧栏的主机。Berth 只读 ~/.ssh/config,不会改动它。")
    }

    // MARK: - 列表

    private var selectionBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("筛选", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(theme.elevatedBackground)
                    .overlay(Capsule().stroke(theme.borderColor, lineWidth: 1))
            )
            .frame(maxWidth: 180)

            Spacer()

            Text("已选 \(selection.count)/\(candidates.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("全选") { selection = Set(candidates.map(\.alias)) }
                .buttonStyle(.link)
                .disabled(selection.count == candidates.count)
            Button("全不选") { selection = [] }
                .buttonStyle(.link)
                .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var hostList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(filtered) { entry in
                    row(entry)
                }
                if filtered.isEmpty {
                    Text("没有匹配的主机")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func row(_ entry: SSHConfigHost) -> some View {
        let isOn = selection.contains(entry.alias)
        return HStack(spacing: 10) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.alias)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(detail(entry))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if entry.proxyJump != nil {
                Label("跳板机", systemImage: "arrow.triangle.branch")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("经 ProxyJump \(entry.proxyJump ?? "") 连接")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? theme.accentSoft : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            if isOn { selection.remove(entry.alias) } else { selection.insert(entry.alias) }
        }
    }

    private func detail(_ entry: SSHConfigHost) -> String {
        let user = entry.user ?? NSUserName()
        let port = entry.port ?? 22
        return port == 22 ? "\(user)@\(entry.hostname)" : "\(user)@\(entry.hostname):\(port)"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("没有找到可导入的主机")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 读不懂的地方

    private var issuesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { isShowingIssues.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Text("\(service.issues.count) 处 Berth 读不懂,已跳过")
                        .font(.caption)
                    Image(systemName: isShowingIssues ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isShowingIssues {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(service.issues) { issue in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(issue.line.map { "第 \($0) 行" } ?? "文件")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 56, alignment: .trailing)
                                Text(issue.summary)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 110)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if service.skippedGitHostingCount > 0 {
                Text("已自动跳过 \(service.skippedGitHostingCount) 条 Git 托管别名(github.com 等,没有可用的 shell)。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if selection.count == candidates.count, !candidates.isEmpty {
                Text("全选时,以后 config 里新增的主机也会自动出现在侧栏。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack {
                Button(isWelcome ? "以后再说" : "取消") { skip() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(confirmTitle) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var confirmTitle: String {
        if candidates.isEmpty { return String(localized: "开始使用") }
        if selection.isEmpty { return String(localized: "不显示") }
        return String(localized: "显示这 \(selection.count) 个")
    }

    // MARK: - 行为

    private func initialSelection() -> Set<String> {
        let policy = SSHConfigImportPolicy.shared
        guard policy.hasDecided else { return Set(candidates.map(\.alias)) }
        switch policy.mode {
        case .all: return Set(candidates.map(\.alias))
        case .selected: return policy.selectedAliases.intersection(candidates.map(\.alias))
        case .none: return []
        }
    }

    /// 跳过 = 这次先不显示,但记下已经问过,不再重复打扰
    private func skip() {
        let policy = SSHConfigImportPolicy.shared
        if policy.hasDecided {
            policy.markSeen(candidates.map(\.alias))
        } else {
            policy.apply(mode: .none, selected: [], known: Set(candidates.map(\.alias)))
        }
        dismiss()
    }

    private func confirm() {
        let all = Set(candidates.map(\.alias))
        let mode: SSHConfigImportMode
        if candidates.isEmpty || selection == all {
            mode = .all
        } else if selection.isEmpty {
            mode = .none
        } else {
            mode = .selected
        }
        SSHConfigImportPolicy.shared.apply(mode: mode, selected: selection, known: all)
        dismiss()
    }
}
