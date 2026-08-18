import AppKit
import SwiftUI

/// 抓到承载视图的 NSWindow,套用主题外观并把标题栏并入内容区,得到统一的深色边到边观感。
/// backgroundColor 钉死为主题底色:macOS 深色模式默认会把壁纸颜色渗进窗口材质(desktop tinting),
/// 与主题冷色底冲突,表现为顶部/空白区一条不搭的暖灰。主窗口与独立窗口(密钥)共用。
struct WindowConfigurator: NSViewRepresentable {
    let appearanceName: NSAppearance.Name
    let backgroundColor: NSColor
    /// 独立小窗(密钥)保留标题文字,主窗口隐藏
    var keepsTitle = false
    /// 透明 chrome:窗口非不透明 + 背景透明,让侧栏的 behind-window 毛玻璃透出桌面
    var translucent = false
    /// 给窗口打标记,供跨窗口定位(仪表盘里点「连接」要把主窗口拉到前面)
    var identifier: NSUserInterfaceItemIdentifier?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        if let identifier { window.identifier = identifier }
        window.appearance = NSAppearance(named: appearanceName)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = keepsTitle ? .visible : .hidden
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : backgroundColor
    }
}

/// macOS 15 的 NavigationSplitView 收放侧栏时会重建标题栏区,把 titleVisibility 复位成
/// 可见,窗口标题「Berth」随之冒出来还占一截宽(issue #14)。收放动作后重新藏一次;
/// 动画结束还补一发,防止 AppKit 在动画收尾时再次复位。
/// 同时补钉工具条可伸缩 item(ToolbarStretchPin):重建出的新 item 没钉过,
/// 标签一多整条折进 » 且不再回来;慢机器(Intel)动画更久,多补一发 1.0s。
@MainActor
enum WindowChromeGuard {
    static func reassertHiddenTitle(identifier: NSUserInterfaceItemIdentifier) {
        for delay in [0.0, 0.45, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = NSApp.windows.first(where: { $0.identifier == identifier }) else { return }
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                ToolbarStretchPin.repin(in: window)
            }
        }
    }
}
