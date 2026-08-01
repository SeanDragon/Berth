import SwiftUI

/// 独立 Docker 面板:远端容器状态,compose 项目分组,只读(一期不做启停/日志)。
/// 打开时拉取,之后每 8 秒静默刷新(仅面板打开期间;数据没变不重绘)。
struct DockerPanelView: View {
    let session: TerminalSession
    let onClose: () -> Void

    @State private var status: DockerStatus?
    @State private var isLoading = false

    private var theme: TerminalTheme { ThemeStore.shared.current }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Docker") {
                PanelIconButton(symbol: "arrow.clockwise", help: String(localized: "刷新"), spinning: isLoading) {
                    Task { await refresh() }
                }
                PanelIconButton(symbol: "xmark", help: String(localized: "关闭")) { onClose() }
            }
            Divider().overlay(theme.borderColor)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 290)
        .background(theme.panelBackground)
        .task(id: session.id) {
            await refresh()
            // 面板打开期间低频跟进,静默刷新不闪加载态
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, case .connected = session.state else { continue }
                if let fresh = await session.fetchDockerStatus(), !Task.isCancelled, fresh != status {
                    status = fresh
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if case .connected = session.state {
            if let status {
                switch status.availability {
                case .notInstalled:
                    placeholder(icon: "shippingbox", text: String(localized: "这台主机没有安装 Docker。"))
                case .permissionDenied:
                    placeholder(
                        icon: "lock",
                        text: String(localized: "无权访问 Docker:当前用户可能不在 docker 组。在服务器上执行 `sudo usermod -aG docker $USER` 后重新登录即可。")
                    )
                case .daemonUnreachable(let message):
                    placeholder(icon: "bolt.slash", text: String(localized: "Docker 守护进程不可达:\(message)"))
                case .available:
                    summaryRow(status)
                    if status.containers.isEmpty {
                        Text("没有容器。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(status.grouped, id: \.project) { group in
                            if !group.project.isEmpty {
                                Label(group.project, systemImage: "square.stack.3d.up")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                            }
                            ForEach(group.containers) { container in
                                containerCard(container)
                            }
                        }
                    }
                }
            } else if isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("读取中…").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            placeholder(icon: "wifi.slash", text: String(localized: "未连接"))
        }
    }

    private func summaryRow(_ status: DockerStatus) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("运行中 \(status.runningCount)")
                    .font(.caption.monospacedDigit())
            }
            HStack(spacing: 5) {
                Circle().fill(.gray).frame(width: 7, height: 7)
                Text("共 \(status.containers.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }

    /// 单个容器的卡片:圆角底色分块,名称/镜像/状态/端口
    private func containerCard(_ container: DockerContainer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stateColor(container.state))
                    .frame(width: 8, height: 8)
                Text(container.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .textSelection(.enabled)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(container.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Text(container.image)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if !container.displayPorts.isEmpty {
                Text(container.displayPorts)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(theme.elevatedBackground)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.borderColor, lineWidth: 1))
        )
    }

    private func placeholder(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "running": return .green
        case "paused", "restarting", "removing": return .yellow
        case "dead": return .red
        default: return .gray // exited / created
        }
    }

    private func refresh() async {
        guard case .connected = session.state else {
            status = nil
            return
        }
        isLoading = true
        let fetched = await session.fetchDockerStatus()
        guard !Task.isCancelled else { return }
        status = fetched
        isLoading = false
    }
}
