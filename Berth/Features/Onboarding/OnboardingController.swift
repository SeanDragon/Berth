import Foundation
import Observation

/// 决定首次启动要不要弹 ssh_config 导入引导,并给设置页/侧栏一个手动入口。
@MainActor
@Observable
final class OnboardingController {
    static let shared = OnboardingController()

    var isImportPresented = false
    /// 面板是否走欢迎形态(首启一次),影响标题与按钮文案
    private(set) var isWelcome = false

    private init() {}

    /// 主窗口出现时调用。已表过态、或 config 里没东西可导 → 不打扰。
    func startIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        // 调试:老用户机器上引导默认不弹,用它强制看一眼
        if environment["BERTH_FORCE_ONBOARDING"] == "1" {
            isWelcome = true
            isImportPresented = true
            return
        }

        let policy = SSHConfigImportPolicy.shared
        guard !policy.hasDecided else { return }

        // 自动化验收/演示环境保持老行为(全部镜像),不弹任何引导
        if environment.keys.contains(where: { $0.hasPrefix("BERTH_") }) {
            policy.apply(mode: .all, selected: [], known: [])
            return
        }

        guard !SSHConfigService.shared.candidates.isEmpty else {
            // 没有 config(或里面没有可用主机):直接按「以后新增的自动显示」落定
            policy.apply(mode: .all, selected: [], known: [])
            return
        }

        isWelcome = true
        isImportPresented = true
    }

    /// 设置页/侧栏提示行的手动入口
    func presentImportPanel() {
        isWelcome = false
        isImportPresented = true
    }
}
