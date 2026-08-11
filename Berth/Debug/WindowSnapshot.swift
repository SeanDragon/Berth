import AppKit

/// 窗口自截图:BERTH_WINDOW_SNAPSHOT=<png 路径> 时,启动后延时把主窗口(含标题栏)渲染成 PNG。
/// 走 NSView 自身的 cacheDisplay(app 画自己的视图层级),无需屏幕录制权限;
/// BERTH_SNAPSHOT_OPEN_LOCAL=1 可先开一个本地 Shell 再截;
/// BERTH_SNAPSHOT_SPLIT=0.7 再左右分屏一个本地 Shell 并把分割比例设成 0.7。
/// 给自动化验收看界面用。
@MainActor
enum WindowSnapshot {
    static func runIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        // defaults 参数版(-berth.windowSnapshot <路径>):不带 BERTH_ 环境变量,
        // 不会被启动逻辑当成自动化环境 —— 用于截「真实会话恢复」路径
        guard let path = env["BERTH_WINDOW_SNAPSHOT"]
            ?? UserDefaults.standard.string(forKey: "berth.windowSnapshot") else { return }
        // 值即要开的本地 Shell 数量("1" 开一个,"5" 开五个,方便截多标签布局)
        if let count = Int(env["BERTH_SNAPSHOT_OPEN_LOCAL"] ?? ""), count > 0 {
            try? await Task.sleep(for: .seconds(1))
            for _ in 0..<count {
                _ = SessionManager.shared.open(spec: .localShell())
            }
        }
        // 分屏 + 指定比例:验证分割线拖拽后的布局(issue #11-2)
        if let ratio = Double(env["BERTH_SNAPSHOT_SPLIT"] ?? "") {
            try? await Task.sleep(for: .seconds(1))
            let manager = SessionManager.shared
            manager.splitFocusedLocalShell(axis: .horizontal)
            if let tab = manager.selectedTab, case .branch(let id, _, _, _) = tab.root {
                tab.setRatio(ratio, for: id)
            }
        }
        let delay = Double(env["BERTH_SNAPSHOT_DELAY"] ?? "3") ?? 3
        try? await Task.sleep(for: .seconds(delay))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let frameView = window.contentView?.superview ?? window.contentView else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
