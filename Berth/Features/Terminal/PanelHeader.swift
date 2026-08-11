import SwiftUI

/// 终端右侧面板(SFTP 文件 / 服务器信息)的统一头部:紧凑标题 + 图标按钮排。
/// 面板位于标签条下方,不需要窗口顶栏那套 AppLayout 留白。
struct PanelHeader<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            actions
        }
        .frame(height: 34)
        .padding(.leading, 12)
        .padding(.trailing, 8)
    }
}

/// 面板头部图标按钮:统一 24pt 命中区、12pt 图标、悬停底色。
/// 悬停轻微浮起(1.06)+ 按下回缩(0.88),与「选中 = 浮起」同一套物理语言。
struct PanelIconButton: View {
    let symbol: String
    let help: String
    var spinning = false
    /// 激活态颜色(如面板开关的选中态);nil 时用次要色
    var tint: Color?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(
                    spinning ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                    value: spinning
                )
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(hovering ? Color.primary.opacity(0.08) : .clear)
                )
                .scaleEffect(hovering ? 1.06 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableIconStyle())
        .foregroundStyle(tint ?? Color.secondary)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 图标钮按下回缩:.plain 没有任何按压反馈,鼠标按下瞬间给一点物理感
struct PressableIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// 浮起材质胶囊:选中标签 chip、选中主机行共用同一套光影语言 ——
/// 「选中 = 浮起,不用强调色水洗」是全窗一条规则。
/// macOS 26+ 用系统 Liquid Glass(真实折射,与原生 chrome 同材质),
/// 旧系统回退自绘:略亮底 + 投影 + 顶部受光细边
struct RaisedCapsule: View {
    var body: some View {
        let theme = ThemeStore.shared.current
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: .capsule)
        } else {
            Capsule()
                .fill(theme.elevatedBackground.shadow(.drop(
                    color: .black.opacity(theme.isDark ? 0.35 : 0.15),
                    radius: 1.5, y: 1
                )))
                .overlay(
                    Capsule().strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(theme.isDark ? 0.16 : 0.6), .white.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )
        }
    }
}

/// 行/chip 的 AppKit 事件层:SwiftUI 手势在 macOS 15 上抢不过窗口拖拽,
/// 且双击判定会拖慢单击。真 NSView 按下即响应;右键返回 nil 交还 .contextMenu。
/// 可选水平拖拽回调(窗口坐标 ΔX,4pt 死区)驱动标签重排 —— DragGesture 版
/// 只在 macOS 26 生效,AppKit 层新老系统行为一致。
struct PressMouseLayer: NSViewRepresentable {
    let onPress: () -> Void
    /// ⌘ 点按(没给就退回 onPress):侧栏用它「再开一条同主机连接」
    var onCommandPress: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

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
        view.onCommandPress = onCommandPress
        view.onDoubleClick = onDoubleClick
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
    }

    final class MouseView: NSView {
        var onPress: (() -> Void)?
        var onCommandPress: (() -> Void)?
        var onDoubleClick: (() -> Void)?
        var onDragChanged: ((CGFloat) -> Void)?
        var onDragEnded: (() -> Void)?
        private var downX: CGFloat = 0
        private var dragging = false

        override var mouseDownCanMoveWindow: Bool { false }
        /// 后台窗口一击即选(原生列表行为),不用先点一下激活窗口
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// 自己不出菜单:返回 nil 让右键沿响应链交给 SwiftUI 的 .contextMenu
        override func menu(for event: NSEvent) -> NSMenu? { nil }

        override func mouseDown(with event: NSEvent) {
            downX = event.locationInWindow.x
            dragging = false
            if event.clickCount == 2, let onDoubleClick {
                onDoubleClick()
            } else if event.clickCount == 1, event.modifierFlags.contains(.command), let onCommandPress {
                // 仅首击触发:⌘ 双击的第二击(clickCount==2 且无 onDoubleClick)落到这里
                // 会把动作触发两次(侧栏一个手势开出两条连接)
                onCommandPress()
            } else {
                onPress?()  // 首击已选中,拖拽/连击都落在已选中的目标上
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard onDragChanged != nil else { return }
            let delta = event.locationInWindow.x - downX
            // 4pt 死区:点按时的手抖不触发重排
            if !dragging, abs(delta) < 4 { return }
            dragging = true
            onDragChanged?(delta)
        }

        override func mouseUp(with event: NSEvent) {
            if dragging { onDragEnded?() }
            dragging = false
        }
    }
}
