import SwiftUI

/// 终端区底部状态栏:连接状态点 + user@host + 连接时长 + 端口转发 | CPU/内存(5s 轮询)+ 本地时钟 + 终端行列数。
/// 跟随当前选中会话,时钟与时长每秒刷新。
/// 左侧地址区兼任原标题胶囊的职责:SSH 会话点按开合服务器信息面板,生产环境红色警示。
struct StatusBarView: View {
    let session: TerminalSession
    @Environment(SessionManager.self) private var sessionManager

    /// 服务器资源快照(每 5s 经 exec 通道拉取,与 PTY 并存)
    @State private var stats: ServerInfo?

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                sessionInfo(now: context.date)
                if !session.forwardStates.isEmpty {
                    separatorDot
                    Text(forwardText)
                        .foregroundStyle(forwardAllActive ? .secondary : Color.yellow)
                        .help("端口转发状态(详见 ⌘I 信息面板)")
                }
                if let code = session.lastExitCode {
                    separatorDot
                    HStack(spacing: 3) {
                        Image(systemName: code == 0 ? "checkmark" : "xmark")
                        if code != 0 { Text("\(code)") }
                        if let duration = durationText(session.lastCommandDuration) {
                            Text(duration)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(code == 0 ? Color.green : Color.red)
                    .help(code == 0 ? "上条命令成功" : "上条命令退出码 \(code)")
                }

                Spacer()

                if isConnected, let stats {
                    if let cpuText = cpuText(stats) {
                        Text(cpuText)
                            .foregroundStyle(.secondary)
                            .help("1 分钟负载 / 核数(\(stats.load)\(stats.cpuCount > 0 ? " · \(stats.cpuCount) 核" : ""))")
                        separatorDot
                    }
                    if let memText = memText(stats) {
                        Text(memText)
                            .foregroundStyle(.secondary)
                            .help("服务器内存占用(\(stats.memory))")
                        separatorDot
                    }
                    if let diskText = diskText(stats) {
                        Text(diskText)
                            .foregroundStyle(.secondary)
                            .help("根分区已用/总量:\(stats.disk)")
                        separatorDot
                    }
                }
                // .secondary 而非 .tertiary:时钟是会被读的信息,暗色主题下
                // .tertiary(~25% 白)难以辨认;列×行保持 .tertiary 维持层级
                Text(context.date.formatted(date: .omitted, time: .standard))
                    .foregroundStyle(.secondary)
                separatorDot
                Text("\(session.terminalView.getTerminal().cols)×\(session.terminalView.getTerminal().rows)")
                    .foregroundStyle(.tertiary)
                    .help("终端列数 × 行数")
            }
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 28)
            // 悬浮卡片:圆角 + 细描边 + 轻投影,与浮动侧栏气质一致
            .background(
                Capsule()
                    .fill(theme.elevatedBackground)
                    .overlay(Capsule().stroke(theme.borderColor, lineWidth: 1))
                    .shadow(color: .black.opacity(0.22), radius: 7, y: 2)
            )
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 14)
        .task(id: session.id) {
            // 资源轮询:连接中每 5s 拉一次;断开时清空,避免残留旧数据
            while !Task.isCancelled {
                if isConnected {
                    let fetched = await session.fetchServerInfo()
                    guard !Task.isCancelled else { return }
                    stats = fetched
                } else {
                    stats = nil
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var separatorDot: some View {
        Text("·").foregroundStyle(.quaternary)
    }

    /// 左侧连接信息(状态点 + 地址 + 时长)。SSH 会话可点按开合服务器信息面板(⌘I);
    /// 生产环境显示红色三角与红字(原标题胶囊的警戒职责)。
    @ViewBuilder
    private func sessionInfo(now: Date) -> some View {
        let isProd = session.spec.isProduction
        let cluster = HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
            if isProd {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            Text(addressText)
                .foregroundStyle(isProd ? Color.red : Color.secondary)
                .fontWeight(isProd ? .semibold : .regular)
            Text(stateText(now: now))
                .foregroundStyle(.tertiary)
        }
        if session.spec.isLocal {
            cluster
        } else {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    sessionManager.isInspectorVisible.toggle()
                }
            } label: {
                cluster.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(
                isProd
                    ? "⚠️ 生产环境:\(addressText)"
                    : "当前会话:\(addressText) —— 点按查看服务器信息(⌘I)"
            )
        }
    }

    private var isConnected: Bool {
        if case .connected = session.state { return true }
        return false
    }

    private var addressText: String {
        // 本地 Shell 没有 user@host,显示 shell 名(如 zsh)
        if session.spec.isLocal {
            return (LocalShell.resolvedShellPath() as NSString).lastPathComponent
        }
        let port = session.spec.port == 22 ? "" : ":\(session.spec.port)"
        return "\(session.spec.username)@\(PrivacyMode.shared.mask(session.spec.hostname))\(port)"
    }

    private var stateColor: Color {
        switch session.state {
        case .idle: return .gray
        case .connecting: return .yellow
        case .connected: return .green
        case .disconnected(let reason):
            return reason == .userInitiated ? .gray : .red
        }
    }

    private func stateText(now: Date) -> String {
        switch session.state {
        case .idle: return String(localized: "未连接")
        case .connecting: return String(localized: "连接中…")
        case .connected:
            guard let start = session.connectedAt else { return String(localized: "已连接") }
            return String(localized: "已连接 \(durationString(from: start, to: now))")
        case .disconnected(let reason):
            return reason == .userInitiated ? String(localized: "已断开") : String(localized: "连接断开")
        }
    }

    /// 1 分钟负载换算核占比;取不到核数时直接显示负载值
    /// 命令耗时的紧凑格式:0.4s / 2.1s / 1m23s;不足 0.1s 不显示
    private func durationText(_ duration: TimeInterval?) -> String? {
        guard let duration, duration >= 0.1 else { return nil }
        if duration < 60 { return String(format: "%.1fs", duration) }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "\(minutes)m\(seconds)s"
    }

    private func cpuText(_ info: ServerInfo) -> String? {
        guard let load1 = info.loadValues.first else { return nil }
        if info.cpuCount > 0 {
            return "CPU \(Int((load1 / Double(info.cpuCount) * 100).rounded()))%"
        }
        return String(format: String(localized: "负载 %.2f"), load1)
    }

    private func memText(_ info: ServerInfo) -> String? {
        guard let usage = info.memoryUsage, usage.total > 0 else { return nil }
        return String(localized: "内存 \(Int((usage.used / usage.total * 100).rounded()))%")
    }

    private func diskText(_ info: ServerInfo) -> String? {
        guard let percent = info.diskPercent else { return nil }
        return String(localized: "磁盘 \(Int(percent))%")
    }

    private var forwardAllActive: Bool {
        session.forwardStates.values.allSatisfy {
            if case .active = $0 { return true }
            return false
        }
    }

    private var forwardText: String {
        let active = session.forwardStates.values.filter {
            if case .active = $0 { return true }
            return false
        }.count
        return String(localized: "转发 \(active)/\(session.forwardStates.count)")
    }

    private func durationString(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
