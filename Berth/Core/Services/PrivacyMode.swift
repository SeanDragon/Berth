import Foundation
import Observation

/// 录屏隐私模式:一键把界面上的主机地址/IP 打码(侧栏、标签 chip、标题栏胶囊、
/// 断线卡片、⌘K/⌘P 列表、菜单栏、服务器信息面板),再点一下恢复。
/// 与「演示模式」互补:演示模式把主机列表换成内置示例,隐私模式给真实会话打码。
@Observable
@MainActor
final class PrivacyMode {
    static let shared = PrivacyMode()

    var isOn: Bool {
        didSet { UserDefaults.standard.set(isOn, forKey: SettingsKeys.privacyMode) }
    }

    private init() {
        isOn = UserDefaults.standard.bool(forKey: SettingsKeys.privacyMode)
    }

    /// 敏感串(hostname/IP)→ 定长圆点,不泄露原文与长度
    func mask(_ value: String) -> String {
        isOn ? String(repeating: "•", count: 6) : value
    }

    /// 把展示串里的 hostname 部分打码(user@host:port、label 回退到地址等场景);
    /// 自定义别名不含地址则原样保留
    func maskHost(in text: String, hostname: String) -> String {
        guard isOn, !hostname.isEmpty else { return text }
        return text.replacingOccurrences(of: hostname, with: String(repeating: "•", count: 6))
    }
}
