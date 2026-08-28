import AppKit
import SwiftTerm

/// 终端字体偏好:字体族(空 = 系统等宽)× 字号。存 UserDefaults,改动即时应用到所有会话。
/// Nerd Font 图标位于 Unicode 私用区,系统等宽字体没有对应字形且无系统回退,
/// 需用户选择自装的 Nerd 字体才能显示。
enum TerminalFontPrefs {
    /// 空字符串 = 系统等宽字体(SF Mono)
    static var family: String {
        UserDefaults.standard.string(forKey: SettingsKeys.terminalFontFamily) ?? ""
    }

    static var size: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: SettingsKeys.terminalFontSize) as? Double ?? 13)
    }

    /// 当前偏好对应的字体;所选字体族已卸载时回落到系统等宽
    static func resolved(size: CGFloat = size) -> NSFont {
        let family = family
        if !family.isEmpty {
            if let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
                return font
            }
            if let font = NSFont(name: family, size: size) {
                return font
            }
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    @MainActor
    static func applyToAllSessions() {
        let font = resolved()
        for session in SessionManager.shared.sessions {
            session.terminalView.font = font
        }
    }

    /// 系统已装的等宽字体族(设置页下拉用),字典序
    static func availableMonospacedFamilies() -> [String] {
        let names = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        var families: Set<String> = []
        for name in names where !name.hasPrefix(".") {
            guard let font = NSFont(name: name, size: 13) else { continue }
            if let family = font.familyName, !family.hasPrefix(".") {
                families.insert(family)
            }
        }
        return families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
