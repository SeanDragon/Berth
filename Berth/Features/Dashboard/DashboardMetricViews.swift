import SwiftUI

/// 占用率配色:与 inspector 的 meter 同一口径(七成以内安全、九成以内注意、再往上告警)。
/// 颜色只是强化,数值本身永远同时在场 —— 不靠颜色单独表达状态。
enum MetricPalette {
    static func color(_ fraction: Double?) -> Color {
        guard let fraction else { return .secondary }
        switch fraction {
        case ..<0.7: return .green
        case ..<0.9: return .yellow
        default: return .red
        }
    }

    static let track = Color.primary.opacity(0.09)
}

/// 环形表:一张卡片上的头号数字(CPU 占用)。无数据时画空环 + 「—」,不画 0%。
struct MetricRing: View {
    let fraction: Double?
    let caption: String
    var size: CGFloat = 76

    private var lineWidth: CGFloat { max(5, size * 0.085) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(MetricPalette.track, lineWidth: lineWidth)
            // 接近 0 时不画弧:一个孤零零的圆点看着像渲染残留,中间的「0%」已经说清楚了
            if let fraction, fraction >= 0.01 {
                Circle()
                    .trim(from: 0, to: min(fraction, 1))
                    .stroke(
                        MetricPalette.color(fraction),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: fraction)
            }
            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(fraction.map { "\(Int(($0 * 100).rounded()))" } ?? "—")
                        .font(.system(size: size * 0.30, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    if fraction != nil {
                        Text("%")
                            .font(.system(size: size * 0.16, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(caption)
                    .font(.system(size: size * 0.135, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
            }
        }
        .frame(width: size, height: size)
    }
}

/// 细条形表:标签 + 细条 + 右侧数值(百分比与绝对量都给,只给百分比等于逼人心算)
struct MetricBar: View {
    let label: String
    let fraction: Double?
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Text(MetricFormat.percent(fraction))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(fraction == nil ? .secondary : MetricPalette.color(fraction))
                    .frame(width: 32, alignment: .trailing)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(MetricPalette.track)
                    if let fraction {
                        Capsule()
                            .fill(MetricPalette.color(fraction))
                            .frame(width: max(3, geo.size.width * min(max(fraction, 0), 1)))
                            .animation(.easeOut(duration: 0.4), value: fraction)
                    }
                }
            }
            .frame(height: 4)
        }
    }
}

/// 走势图:固定 0…1 纵轴(跨卡片可直接横向比较,不做各自归一化那种骗人的自动缩放)。
/// 数据点不足两个时留空 —— 一根横线比空白更像在说谎。
struct Sparkline: View {
    let values: [Double?]
    var color: Color = .accentColor
    /// 纵轴上界。nil = 按数据最大值自适应(网络速率没有天然满量程)
    var ceiling: Double? = 1

    var body: some View {
        GeometryReader { geo in
            let points = layout(in: geo.size)
            ZStack {
                if points.count >= 2 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.28), color.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
        }
    }

    /// 缺采样(首轮没有速率)不参与连线:直接跳过,曲线在那儿断开而不是掉到 0
    private func layout(in size: CGSize) -> [CGPoint] {
        let usable = values.enumerated().compactMap { index, value in value.map { (index, $0) } }
        guard usable.count >= 2, values.count >= 2 else { return [] }
        let top = ceiling ?? max(usable.map(\.1).max() ?? 1, 0.0001)
        let stepX = size.width / CGFloat(values.count - 1)
        // 上下各留一个线宽:0% 和 100% 贴边会被描边裁掉一半
        let inset: CGFloat = 1.5
        let plotHeight = max(size.height - inset * 2, 1)
        return usable.map { index, value in
            let ratio = min(max(value / top, 0), 1)
            return CGPoint(x: CGFloat(index) * stepX, y: inset + plotHeight * (1 - ratio))
        }
    }
}

/// 状态胶囊:圆点 + 文字。颜色从不单独承担信息,文字永远在旁边。
struct StatusPill: View {
    let color: Color
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .shadow(color: color.opacity(0.55), radius: 3)
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}
