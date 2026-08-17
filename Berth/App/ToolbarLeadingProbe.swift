import AppKit
import SwiftUI

/// macOS 15 没有 ToolbarSpacer,标签条 + 按钮组合成单个 NSToolbarItem 自己排版。
/// 布局采用 Xcode 式「可伸缩中区」:把 item 钉成 stretchable(minSize 小、maxSize 大),
/// NSToolbar 会把工具条的全部剩余宽度分给它 —— item 内部的 Spacer 再把按钮组推到
/// 右缘。宽度不需要任何测量,侧栏收放/窗口缩放由 AppKit 自己分配,天然收敛。
///
/// 为什么要下到 AppKit 钉尺寸:SwiftUI 把内容的固定/理想宽当成 item 的最小尺寸报给
/// NSToolbar,放不下就把**整条 item 折进溢出菜单**,标签和按钮一起消失(issue #14);
/// 且折走之后不会因为变窄自动放回来。minSize 钉小之后放不下只会压窄,永远折不走。
/// minSize/maxSize 虽标 deprecated,但「可伸缩 item」恰恰只有它能表达,有意为之。
struct ToolbarStretchPin: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { PinView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class PinView: NSView {
        private var pinned = false

        override func layout() {
            super.layout()
            // setMinSize 会触发 _itemChanged,布局过程中同步调用直接抛异常,必须推出去
            guard !pinned else { return }
            DispatchQueue.main.async { [weak self] in self?.pinItemSizes() }
        }

        private func pinItemSizes() {
            guard !pinned, let window, let toolbar = window.toolbar else { return }
            var ancestors: [NSView] = []
            var node: NSView? = self
            while let view = node {
                ancestors.append(view)
                node = view.superview
            }
            guard let item = toolbar.items.first(where: { candidate in
                candidate.view.map { ancestors.contains($0) } ?? false
            }), let view = item.view else { return }
            let height = view.fittingSize.height
            item.minSize = NSSize(width: 260, height: height)
            item.maxSize = NSSize(width: 20000, height: height)
            pinned = true
        }
    }
}
