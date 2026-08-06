import AppKit
import SwiftData

/// 菜单栏常驻入口(NSStatusItem)。弃用 SwiftUI MenuBarExtra:它的 isInserted
/// 绑定会把用户写入的 false 回写成 true(表现为设置里开关无效),而换 @AppStorage
/// 驱动会在 makeMainMenu → invalidateProperties 里死循环(Termite 同款问题,
/// 上游已验证)。AppKit 状态项 + UserDefaults 通知:开关即时生效,无回写路径。
@MainActor
final class MenuBarItemController: NSObject {
    static let shared = MenuBarItemController()

    private var statusItem: NSStatusItem?
    private var defaultsObserver: (any NSObjectProtocol)?

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.menuBarExtra) as? Bool ?? true
    }

    func start() {
        syncPresence()
        // 设置页改开关后立刻生效(@AppStorage 写 UserDefaults 会发这个通知)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuBarItemController.shared.syncPresence() }
        }
    }

    /// 按开关插入/移除状态项
    private func syncPresence() {
        if isEnabled {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Berth")
            item.button?.image?.isTemplate = true
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - 菜单构建(每次打开重建:会话列表与最近主机都是动态的)

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let manager = SessionManager.shared

        if !manager.sessions.isEmpty {
            menu.addItem(.sectionHeader(title: String(localized: "活跃会话")))
            for session in manager.sessions {
                let sessionID = session.id
                let title = PrivacyMode.shared.maskHost(in: session.spec.label, hostname: session.spec.hostname)
                let item = actionItem(title: title) {
                    NSApp.activate(ignoringOtherApps: true)
                    SessionManager.shared.focusPane(sessionID)
                }
                item.image = Self.dot(for: session)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        menu.addItem(.sectionHeader(title: String(localized: "快速连接")))
        let hosts = allHosts()
        for host in Self.sortedByRecency(hosts).prefix(8) {
            let item = actionItem(title: host.label) {
                NSApp.activate(ignoringOtherApps: true)
                host.lastConnectedAt = Date()
                _ = SessionManager.shared.open(spec: HostSpec.resolve(host, in: hosts))
            }
            item.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: nil)
            menu.addItem(item)
        }
        let local = actionItem(title: String(localized: "本地 Shell")) {
            NSApp.activate(ignoringOtherApps: true)
            _ = SessionManager.shared.open(spec: .localShell())
        }
        local.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        menu.addItem(local)

        menu.addItem(.separator())
        menu.addItem(actionItem(title: String(localized: "打开 Berth")) {
            NSApp.activate(ignoringOtherApps: true)
        })
        menu.addItem(actionItem(title: String(localized: "退出 Berth")) {
            NSApp.terminate(nil)
        })
    }

    /// 托管主机(库)+ config 镜像(内存);演示模式下换内置示例(防录屏/截图泄漏)
    private func allHosts() -> [Host] {
        if UserDefaults.standard.bool(forKey: SettingsKeys.demoMode) {
            return DemoMode.samples
        }
        var stored: [Host] = []
        if let container = SessionManager.shared.modelContainer {
            stored = (try? container.mainContext.fetch(FetchDescriptor<Host>())) ?? []
        }
        return stored + SSHConfigService.shared.mirrorHosts
    }

    /// 最近连接优先,未连过的按列表顺序排在后面
    private static func sortedByRecency(_ hosts: [Host]) -> [Host] {
        hosts.sorted {
            switch ($0.lastConnectedAt, $1.lastConnectedAt) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.sortOrder < $1.sortOrder
            }
        }
    }

    // MARK: - 闭包 → target/action 桥

    private func actionItem(title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(ActionBox.fire), keyEquivalent: "")
        let box = ActionBox(action)
        item.target = box
        item.representedObject = box // 菜单条目持有 box,免得闭包被回收
        return item
    }

    private final class ActionBox: NSObject {
        private let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func fire() { action() }
    }

    // MARK: - 状态点(非模板图,菜单中保留颜色)

    private static let greenDot = makeDot(.systemGreen)
    private static let yellowDot = makeDot(.systemYellow)
    private static let grayDot = makeDot(.tertiaryLabelColor)

    private static func dot(for session: TerminalSession) -> NSImage {
        switch session.state {
        case .connected: return greenDot
        case .connecting: return yellowDot
        case .idle, .disconnected: return grayDot
        }
    }

    private static func makeDot(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 9, height: 9)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension MenuBarItemController: NSMenuDelegate {
    nonisolated func menuWillOpen(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild(menu) }
    }
}
