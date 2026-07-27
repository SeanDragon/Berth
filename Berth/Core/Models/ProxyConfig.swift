import Foundation

enum ProxyKind: String, Codable, CaseIterable, Identifiable {
    case none
    case http    // HTTP CONNECT
    case socks5
    var id: String { rawValue }

    /// 已本地化的显示名 —— 必须在这里取,调用点拿到的是成品字符串。
    /// 裸字面量在 `Text(kind.label)` 里不会走本地化(SwiftUI 只对字面量自动提取),
    /// 英文界面会漏出中文(issue #1)。同 PortForwardKind.label。
    var label: String {
        switch self {
        case .none: return String(localized: "不使用")
        case .http: return "HTTP CONNECT"
        case .socks5: return "SOCKS5"
        }
    }
}

/// 连接 SSH 服务器时先经过的代理。用户名/密码可选(存 Keychain)。
/// 作为 Host 的内嵌值存储(展开为几个字段,避免 SwiftData 关系开销)。
struct ProxyConfig: Codable, Equatable, Sendable {
    var kind: ProxyKind = .none
    var host: String = ""
    var port: Int = 1080
    var username: String = ""
    /// 是否需要认证(密码存 Keychain,按 host.id 引用)
    var requiresAuth: Bool = false

    var isEnabled: Bool { kind != .none && !host.isEmpty }
}
