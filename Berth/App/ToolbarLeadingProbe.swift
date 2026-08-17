import AppKit
import SwiftUI

/// macOS 15 没有 ToolbarSpacer,标签条 + 按钮组只能合成单个 NSToolbarItem 自己排版,
/// 宽度得贴着工具条剩余空间给。可用空间没有公开 API,而左边红绿灯 + 侧栏按钮占多宽
/// 随系统版本和侧栏收放变 —— 猜小了右侧留白,**猜大一点点 NSToolbar 就把整个 item
/// 折进溢出菜单**,标签和按钮一起消失(issue #14)。
///
/// 两道防线:
/// 1. 不猜左边缘 —— 往 item 最前面贴一个零占位探针,直接量它落在窗口坐标里的 x;
/// 2. 右边距万一还是给窄了,探针会发现自己被摘出窗口(折进溢出菜单的 item 视图不在
///    标题栏里),于是退让一档重来,直到 item 回到工具条上。
///
/// 注意:给 HStack 加 `.frame(minWidth:idealWidth:maxWidth:)` 让 item「可压缩」是没用的,
/// SwiftUI 把 ideal 宽当成 item 的最小尺寸报给 NSToolbar,照样整条折走(实测)。
@MainActor
@Observable
final class ToolbarLeadingMetrics {
    /// item 左边缘在窗口坐标中的 x;nil = 尚未量到,调用方先用保守估计
    var originX: CGFloat?
    /// 观察到溢出后追加的右边距,只增不减(翻倍退让,一两档就够)
    var overflowBackoff: CGFloat = 0
    /// 验收注入:量准之后人为把宽度撑爆,检验 item 只会被压窄而不会整条消失(issue #14)
    var debugOvershoot: CGFloat = 0
    /// 当前在世的探针 —— SwiftUI 重建 item 时旧探针也会离开窗口,别把那当成溢出
    @ObservationIgnored weak var activeProbe: NSView?

    private static let backoffCap: CGFloat = 480

    /// 返回 false = 已退到头,调用方别再接力重试了
    @discardableResult
    func backOffFromOverflow() -> Bool {
        guard overflowBackoff < Self.backoffCap else { return false }
        overflowBackoff = min(max(overflowBackoff * 2, 24), Self.backoffCap)
        return true
    }
}

/// 挂在合成 item 左边缘的零占位探针(走 background,不参与布局)。
struct ToolbarLeadingProbe: NSViewRepresentable {
    let metrics: ToolbarLeadingMetrics

    func makeNSView(context: Context) -> NSView { ProbeView(metrics: metrics) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ProbeView)?.scheduleReport()
    }

    private final class ProbeView: NSView {
        private let metrics: ToolbarLeadingMetrics
        /// 已发布的值:layout 每帧都会来,只有真变了才回写,免得和 SwiftUI 互相触发
        private var published: CGFloat?
        private var overflowCheckPending = false

        init(metrics: ToolbarLeadingMetrics) {
            self.metrics = metrics
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleReport()
        }

        override func layout() {
            super.layout()
            report()
        }

        /// 侧栏收放/工具条重建都是带动画的,稳定态要等动画收尾再补量一次
        func scheduleReport() {
            report()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.report() }
        }

        /// 量得到 = item 好端端排在标题栏上;量不到 = 它被折进了溢出菜单
        /// (那种 item 的视图留在层级里但没有 window,坐标是负的)。
        private func report() {
            if let window, window.toolbar != nil, window.styleMask.contains(.titled) {
                let x = convert(bounds, to: nil).minX
                if x > 40, x < window.frame.width - 120 {
                    metrics.activeProbe = self
                    // setMinSize 会触发 _itemChanged,布局过程中调用直接抛异常崩溃,
                    // 必须推出 layout() 再动工具条
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let window = self.window else { return }
                        self.pinItemSizes(in: window)
                    }
                    log("ok x=\(x)")
                    guard published.map({ abs($0 - x) > 1 }) ?? true else { return }
                    published = x
                    // layout 期间改 @Observable 会撞上 SwiftUI 的更新周期,推到下个 runloop
                    DispatchQueue.main.async { [metrics] in metrics.originX = x }
                    return
                }
            }
            scheduleOverflowCheck()
        }

        /// 量不到还有个良性来源:SwiftUI 重建 item 时,旧探针会在新探针接班前空转一拍。
        /// 所以等一下再看 —— 只有确认没有任何探针挂在窗口上,才认定是真溢出。
        private func scheduleOverflowCheck() {
            guard !overflowCheckPending else { return }
            overflowCheckPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                self.overflowCheckPending = false
                if let active = self.metrics.activeProbe, active !== self, active.window != nil { return }
                guard self.window == nil else { return }
                self.log("overflow detected, backoff=\(self.metrics.overflowBackoff)")
                // 脱离窗口后就收不到 layout 回调了,得自己接力:退让一档 → 等重排 →
                // 还没回来就再退一档;退到头就停,别空转定时器
                if self.metrics.backOffFromOverflow() {
                    self.scheduleOverflowCheck()
                }
            }
        }

        /// 关键一步:SwiftUI 把 item 的固定宽当成最小尺寸报给 NSToolbar,放不下就整条
        /// 折进溢出菜单(而且折走之后不会因为变窄再放回来 —— 事后补救没用)。
        /// 所以在 AppKit 层把 minSize 钉小:放不下时它只能被压窄,标签和按钮始终在条上。
        /// minSize/maxSize 虽标记 deprecated,但「压缩而不是折叠」恰恰只有它能表达,
        /// 有意为之;每帧 layout 都会重钉,窗口缩放后 maxSize 跟着当前 fitting 宽走。
        private func pinItemSizes(in window: NSWindow) {
            guard let toolbar = window.toolbar else { return }
            var ancestors: [NSView] = []
            var node: NSView? = self
            while let view = node {
                ancestors.append(view)
                node = view.superview
            }
            guard let item = toolbar.items.first(where: { candidate in
                candidate.view.map { ancestors.contains($0) } ?? false
            }), let view = item.view else { return }
            let fitting = view.fittingSize
            let maxWidth = max(fitting.width, Self.minimumItemWidth)
            guard item.minSize.width != Self.minimumItemWidth || item.maxSize.width != maxWidth else { return }
            item.minSize = NSSize(width: Self.minimumItemWidth, height: fitting.height)
            item.maxSize = NSSize(width: maxWidth, height: fitting.height)
            log("pinned item min=\(item.minSize) max=\(item.maxSize)")
        }

        private static let minimumItemWidth: CGFloat = 260

        private func log(_ message: String) {
            guard let path = ProcessInfo.processInfo.environment["BERTH_TOOLBAR_LOG"] else { return }
            let line = message + "\n"
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}
