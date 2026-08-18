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
///
/// ⚠️ 钉扎必须可重复:macOS 15 收放侧栏会重建标题栏区,重建出的新 NSToolbarItem
/// 又回到 SwiftUI 报的理想宽,标签一多整条折进 » 且再也不回来(用户反馈,15.6.1
/// 实测复现)。所以按 item 身份跟踪、每次布局都补钉;item 折走后视图不在窗口里,
/// 内部钩子失效 —— 另提供 `repin(in:)` 供侧栏收放钩子从窗口级把它救回来。
/// 兜底:给 item 挂 menuFormRepresentation(标签列表),万一 » 仍短暂出现,
/// 点开也能切标签,而不是一个没用的空菜单。
struct ToolbarStretchPin: NSViewRepresentable {
    /// » 溢出菜单里的标签列表(懒取,菜单展开时才求值)
    var overflowTabs: (() -> [OverflowTab])?
    /// 从溢出菜单选中某个标签
    var onSelectTab: ((UUID) -> Void)?

    struct OverflowTab {
        let id: UUID
        let title: String
        let isSelected: Bool
    }

    func makeNSView(context: Context) -> NSView {
        let view = PinView()
        view.overflowTabs = overflowTabs
        view.onSelectTab = onSelectTab
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let pin = nsView as? PinView else { return }
        pin.overflowTabs = overflowTabs
        pin.onSelectTab = onSelectTab
    }

    /// 窗口级补钉:遍历 toolbar 找到含 PinView 的 item 重新钉扎。
    /// item 被折进 » 后其视图不在窗口层级里(PinView 自己的 layout 不再走),
    /// 只能从外面救;NSToolbarItem.view 始终持有视图,能找到。
    @MainActor
    static func repin(in window: NSWindow?) {
        guard let toolbar = window?.toolbar else { return }
        for item in toolbar.items {
            guard let view = item.view, let pin = findPin(in: view) else { continue }
            pin.pin(item: item, force: true)
        }
    }

    private static func findPin(in view: NSView) -> PinView? {
        if let pin = view as? PinView { return pin }
        for sub in view.subviews {
            if let pin = findPin(in: sub) { return pin }
        }
        return nil
    }

    final class PinView: NSView, NSMenuDelegate {
        var overflowTabs: (() -> [ToolbarStretchPin.OverflowTab])?
        var onSelectTab: ((UUID) -> Void)?
        /// 已钉过的 item(弱持有):同一个 item 不重复设置,换了新 item 立即补钉
        private weak var pinnedItem: NSToolbarItem?

        override func layout() {
            super.layout()
            schedulePin()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 从 » 里被放回窗口 / 标题栏重建挂载,都要重钉
            schedulePin()
        }

        private func schedulePin() {
            // setMinSize 会触发 _itemChanged,布局过程中同步调用直接抛异常,必须推出去
            DispatchQueue.main.async { [weak self] in
                guard let self, let item = self.enclosingToolbarItem() else { return }
                self.pin(item: item, force: false)
            }
        }

        private func enclosingToolbarItem() -> NSToolbarItem? {
            guard let toolbar = window?.toolbar else { return nil }
            var ancestors: [NSView] = []
            var node: NSView? = self
            while let view = node {
                ancestors.append(view)
                node = view.superview
            }
            return toolbar.items.first { candidate in
                candidate.view.map { ancestors.contains($0) } ?? false
            }
        }

        func pin(item: NSToolbarItem, force: Bool) {
            guard force || item !== pinnedItem, let view = item.view else { return }
            let height = max(view.fittingSize.height, 28)
            item.minSize = NSSize(width: 260, height: height)
            item.maxSize = NSSize(width: 20000, height: height)
            item.menuFormRepresentation = makeOverflowMenuItem()
            pinnedItem = item
        }

        // MARK: - » 溢出菜单(标签列表)

        private func makeOverflowMenuItem() -> NSMenuItem {
            let title = String(localized: "标签页")
            let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            menu.delegate = self
            root.submenu = menu
            return root
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            for tab in overflowTabs?() ?? [] {
                let entry = NSMenuItem(title: tab.title, action: #selector(pickTab(_:)), keyEquivalent: "")
                entry.target = self
                entry.state = tab.isSelected ? .on : .off
                entry.representedObject = tab.id
                menu.addItem(entry)
            }
        }

        @objc private func pickTab(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID else { return }
            onSelectTab?(id)
        }
    }
}
