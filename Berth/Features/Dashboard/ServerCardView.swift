import SwiftUI

/// 仪表盘上的一台服务器。
/// 在线时:CPU 环 + 内存/磁盘条 + CPU 走势 + 一行网络/负载/运行时长;
/// 不在线时:不画假的空表盘,直接把原因和下一步动作摆出来。
struct ServerCardView: View {
    let state: ServerMonitor.HostState
    let theme: TerminalTheme
    let onConnect: () -> Void
    let onAuthorize: () -> Void

    @State private var hovering = false

    private var reading: ServerMetricsReading? { state.reading }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if state.reading != nil {
                metrics
            } else {
                placeholder
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.elevatedBackground)
                .shadow(color: .black.opacity(hovering ? 0.20 : 0.10), radius: hovering ? 9 : 5, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                // 生产主机整卡描红边:和终端里的生产警戒同一套语言
                .stroke(state.isProduction ? Color.red.opacity(0.45) : theme.borderColor, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onTapGesture(count: 2) { onConnect() }
        .help(String(localized: "双击连接 \(state.label)"))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            OSBadge(osName: state.osName)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if state.isProduction {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                            .help("生产环境")
                    }
                    Text(PrivacyMode.shared.mask(state.label))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(PrivacyMode.shared.mask(state.address))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if hovering {
                Button(action: onConnect) {
                    Image(systemName: "apple.terminal")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentColor)
                .help("连接这台主机")
                .transition(.opacity)
            }
            statusPill
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch state.status {
        case .online:
            StatusPill(color: .green, text: String(localized: "在线"))
                .help(onlineHelp)
        case .connecting:
            StatusPill(color: .yellow, text: String(localized: "连接中"))
        case .idle:
            StatusPill(color: .gray, text: String(localized: "待采集"))
        case .offline(let reason):
            StatusPill(color: .red, text: String(localized: "离线"))
                .help(reason)
        case .needsAuthorization:
            StatusPill(color: .orange, text: String(localized: "需授权"), symbol: "lock.fill")
        case .needsInteraction:
            StatusPill(color: .orange, text: String(localized: "需确认"), symbol: "hand.raised.fill")
        }
    }

    private var onlineHelp: String {
        var parts: [String] = []
        if let latency = state.latency {
            parts.append(String(localized: "采集耗时 \(Int(latency * 1000)) ms"))
        }
        if state.borrowsSession {
            parts.append(String(localized: "复用已打开的终端连接"))
        }
        if let hostname = reading?.hostname, !hostname.isEmpty {
            parts.append(PrivacyMode.shared.mask(hostname))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 指标

    @ViewBuilder
    private var metrics: some View {
        if let reading {
            HStack(alignment: .center, spacing: 12) {
                MetricRing(fraction: reading.cpuFraction, caption: "CPU")
                VStack(alignment: .leading, spacing: 7) {
                    MetricBar(
                        label: String(localized: "内存"),
                        fraction: reading.memFraction,
                        detail: memoryDetail(reading)
                    )
                    if let disk = reading.primaryDisk {
                        MetricBar(
                            label: diskLabel(disk),
                            fraction: disk.fraction,
                            detail: "\(MetricFormat.kilobytes(disk.usedKB)) / \(MetricFormat.kilobytes(disk.totalKB))"
                        )
                    }
                    if let swap = reading.swapFraction, swap > 0.01 {
                        MetricBar(
                            label: String(localized: "交换"),
                            fraction: swap,
                            detail: MetricFormat.kilobytes(reading.swapUsedKB)
                        )
                    }
                }
            }

            sparklineRow(reading)
            footer(reading)
        }
    }

    private func sparklineRow(_ reading: ServerMetricsReading) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("CPU 走势")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(historySpan)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.quaternary)
            }
            Sparkline(values: state.history.map(\.cpu), color: theme.accentColor)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.03))
                )
        }
    }

    private func footer(_ reading: ServerMetricsReading) -> some View {
        HStack(spacing: 10) {
            // ↓↑ 箭头本身就是身份标识,不靠颜色区分收发
            statChip(symbol: "arrow.down", text: MetricFormat.rate(reading.netRxRate), help: String(localized: "下行速率"))
            statChip(symbol: "arrow.up", text: MetricFormat.rate(reading.netTxRate), help: String(localized: "上行速率"))
            if !reading.load.isEmpty {
                statChip(
                    symbol: "gauge.with.dots.needle.33percent",
                    text: String(format: "%.2f", reading.load[0]),
                    help: String(localized: "负载 \(MetricFormat.load(reading.load)) · \(reading.cpuCount) 核")
                )
            }
            Spacer(minLength: 0)
            if let temperature = MetricFormat.temperature(reading.temperatureC) {
                statChip(symbol: "thermometer.medium", text: temperature, help: String(localized: "CPU 温度"))
            }
            statChip(
                symbol: "clock",
                text: MetricFormat.uptime(reading.uptimeSeconds),
                help: String(localized: "运行时长")
            )
        }
        .lineLimit(1)
    }

    private func statChip(symbol: String, text: String, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .help(help)
    }

    // MARK: - 无数据时

    @ViewBuilder
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state.status {
            case .connecting, .idle:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(state.status == .connecting ? "正在连接…" : "等待采集…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            case .offline(let reason):
                reasonText(reason)
                Button(action: onConnect) {
                    Label("在终端里连接", systemImage: "apple.terminal")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .needsAuthorization:
                reasonText(String(localized: "这台主机用密钥认证。「使用密钥前要求 Touch ID」开着时,后台采集需要你先授权一次。"))
                Button(action: onAuthorize) {
                    Label("授权后台监控", systemImage: "touchid")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            case .needsInteraction(let reason):
                reasonText(reason)
                Button(action: onConnect) {
                    Label("在终端里连接", systemImage: "apple.terminal")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .online:
                // 已在线但还没拿到第一份样本
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("读取资源信息…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
    }

    private func reasonText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 文案

    private func memoryDetail(_ reading: ServerMetricsReading) -> String {
        guard let used = reading.memUsedKB, let total = reading.memTotalKB else { return "—" }
        return "\(MetricFormat.kilobytes(used)) / \(MetricFormat.kilobytes(total))"
    }

    private func diskLabel(_ disk: ServerMetricsSample.DiskUsage) -> String {
        disk.mount == "/" ? String(localized: "磁盘") : String(localized: "磁盘 \(disk.mount)")
    }

    /// 走势覆盖的时间跨度(采样间隔 × 点数),让人知道这条线代表多久
    private var historySpan: String {
        guard let first = state.history.first?.at, let last = state.history.last?.at,
              last.timeIntervalSince(first) >= 60 else { return "" }
        let minutes = Int(last.timeIntervalSince(first) / 60)
        return String(localized: "近 \(minutes) 分钟")
    }
}
