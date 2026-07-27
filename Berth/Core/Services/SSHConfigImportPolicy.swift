import Foundation
import Observation

/// ~/.ssh/config 里的主机怎么显示在侧栏
enum SSHConfigImportMode: String {
    /// 全部显示,以后 config 新增的也自动出现
    case all
    /// 只显示用户勾选过的别名
    case selected
    /// 一个都不显示
    case none
}

/// 用户对「config 主机怎么显示」的选择。
///
/// 老版本是无条件把整个 config 铺进侧栏 —— 一份几十条的 config 会让首次启动
/// 直接糊满陌生主机。现在改成首启由引导页问一次,选择记在这里。
/// 已经在用的用户不该被这个改动影响:`bootstrap` 认出他们后直接按 `.all` 落定,不弹引导。
@MainActor
@Observable
final class SSHConfigImportPolicy {
    static let shared = SSHConfigImportPolicy()

    private enum Key {
        static let mode = "sshconfig.importMode"
        static let selected = "sshconfig.selectedAliases"
        static let known = "sshconfig.knownAliases"
        static let decided = "sshconfig.decided"
        /// 老版本首启时写下的钥匙串迁移标记:存在即说明这台机器跑过更早的 Berth
        static let legacyLaunchMarker = "migration.keychainSharedGroup.v2"
        static let legacyOpenTabs = "session.openTabs"
    }

    private(set) var mode: SSHConfigImportMode
    /// mode == .selected 时生效的别名白名单
    private(set) var selectedAliases: Set<String>
    /// 用户在引导/管理面板里见过的别名,用于发现「config 后来新增了主机」
    private(set) var knownAliases: Set<String>
    /// 用户是否已就此表过态。未表态时一律不显示 —— 引导页给答案之前侧栏保持干净
    private(set) var hasDecided: Bool

    private let defaults = UserDefaults.standard

    private init() {
        mode = SSHConfigImportMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .all
        selectedAliases = Set(defaults.stringArray(forKey: Key.selected) ?? [])
        knownAliases = Set(defaults.stringArray(forKey: Key.known) ?? [])
        hasDecided = defaults.bool(forKey: Key.decided)
    }

    /// 是否显示某个 config 别名
    func includes(alias: String) -> Bool {
        guard hasDecided else { return false }
        switch mode {
        case .all: return true
        case .selected: return selectedAliases.contains(alias)
        case .none: return false
        }
    }

    /// 老用户识别:跑过更早版本的机器不该被引导页打扰,按老行为(全部显示)直接落定。
    /// `hostCount` 是库里已有的托管主机数,由调用方查好传进来。
    func bootstrap(existingHostCount: Int) {
        guard !hasDecided else { return }
        let usedBefore = defaults.object(forKey: Key.legacyLaunchMarker) != nil
            || !(defaults.stringArray(forKey: Key.legacyOpenTabs) ?? []).isEmpty
            || existingHostCount > 0
        guard usedBefore else { return }
        apply(mode: .all, selected: [], known: [])
    }

    /// 引导页/管理面板的结果落盘
    func apply(mode newMode: SSHConfigImportMode, selected: Set<String>, known: Set<String>) {
        mode = newMode
        selectedAliases = selected
        knownAliases = knownAliases.union(known)
        hasDecided = true
        defaults.set(newMode.rawValue, forKey: Key.mode)
        defaults.set(Array(selected), forKey: Key.selected)
        defaults.set(Array(knownAliases), forKey: Key.known)
        defaults.set(true, forKey: Key.decided)
        SSHConfigService.shared.rebuildMirrors()
    }

    /// config 里出现过、但用户还没在面板上见过的别名(mode == .all 时不提示,反正都显示了)
    func unseenAliases(among aliases: [String]) -> [String] {
        guard hasDecided, mode != .all else { return [] }
        return aliases.filter { !knownAliases.contains($0) }
    }

    /// 用户看过但没勾选:记下来,别再提示
    func markSeen(_ aliases: [String]) {
        knownAliases.formUnion(aliases)
        defaults.set(Array(knownAliases), forKey: Key.known)
    }
}
