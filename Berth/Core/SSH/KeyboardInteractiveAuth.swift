import Foundation
import NIOCore
import NIOSSH

/// keyboard-interactive(RFC 4256)认证 delegate:堡垒机 MFA 场景(issue #12)。
///
/// 认证顺序:服务器支持 password 且有存储密码 → 先试 password;失败或服务器只给
/// keyboard-interactive → 提交 keyboard-interactive,质询(INFO_REQUEST)按轮应答:
/// - 首个「不回显」的提示在密码未被消费前自动以存储密码作答(堡垒机第一轮基本都是
///   Password:,不该让用户再敲一遍);
/// - 其余提示(MFA 动态码等)经 `prompter` 冒泡给 UI,用户作答;取消 = 认证中止。
///
/// 质询回调发生在 NIO event loop,prompter 内部负责跳主线程。
final class KeyboardInteractiveAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {

    struct Challenge: Sendable {
        struct Prompt: Sendable {
            let text: String
            let echo: Bool
        }
        let title: String
        let instruction: String
        let prompts: [Prompt]
    }

    /// UI 交互:返回与 prompts 同数量、同顺序的应答;nil = 用户取消。
    /// prompter 传 nil = 平台没有质询 UI(iOS 暂未做):自动应答仍可用,
    /// 需要人工输入(MFA 码)时以 promptUnavailable 明确报错,不装作被取消
    typealias Prompter = @Sendable (Challenge) async -> [String]?

    private let username: String
    private let password: String?
    private let prompter: Prompter?
    /// 自动应答只做一次:密码不对时把同一个错密码反复喂回去毫无意义,
    /// 第二轮起原样弹给用户
    private var passwordConsumed = false
    /// password 方法只试一次,失败转 keyboard-interactive
    private var passwordAttempted = false
    /// kbd-int 允许重试:MFA 码敲错一位时服务器发 USERAUTH_FAILURE 并继续提供
    /// keyboard-interactive(OpenSSH 会给到 MaxAuthTries),只试一次会把整条连接
    /// 判死,逼用户为一个笔误全程重连。与 ssh 的 NumberOfPasswordPrompts 一致取 3。
    private var keyboardInteractiveAttempts = 0
    private static let maxKeyboardInteractiveAttempts = 3

    init(username: String, password: String?, prompter: Prompter?) {
        self.username = username
        self.password = password?.isEmpty == false ? password : nil
        self.prompter = prompter
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if !passwordAttempted, let password, availableMethods.contains(.password) {
            passwordAttempted = true
            passwordConsumed = true
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: username, serviceName: "", offer: .password(.init(password: password))
            ))
            return
        }
        if keyboardInteractiveAttempts < Self.maxKeyboardInteractiveAttempts,
           availableMethods.contains(.keyboardInteractive) {
            keyboardInteractiveAttempts += 1
            // 每轮尝试重置自动应答:password 直接失败过 / 上一轮 MFA 码敲错时,
            // 新一轮对话的 Password: 提示仍值得用存储密码自动答一次
            //(两条路径的口令后端可能不同,堡垒机常见;密码本身对、码错的重试更是如此)
            passwordConsumed = false
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: username, serviceName: "", offer: .keyboardInteractive(.init())
            ))
            return
        }
        nextChallengePromise.fail(KeyboardInteractiveAuthError.exhausted)
    }

    func keyboardInteractiveChallenge(
        _ challenge: NIOSSHKeyboardInteractiveChallenge,
        responsePromise: EventLoopPromise<[String]>
    ) {
        // 零提示轮:服务器只是在推进流程(常见于 PAM 链),回空应答即可,不打扰用户
        guard !challenge.prompts.isEmpty else {
            responsePromise.succeed([])
            return
        }

        // 单个不回显提示 + 存储密码未消费 → 自动作答(免得用户重复敲密码)
        if !passwordConsumed, let password,
           challenge.prompts.count == 1, challenge.prompts[0].echo == false {
            passwordConsumed = true
            responsePromise.succeed([password])
            return
        }

        guard let prompter else {
            responsePromise.fail(KeyboardInteractiveAuthError.promptUnavailable)
            return
        }
        let presented = Challenge(
            title: challenge.name,
            instruction: challenge.instruction,
            prompts: challenge.prompts.map { .init(text: $0.prompt, echo: $0.echo) }
        )
        Task {
            if let answers = await prompter(presented), answers.count == presented.prompts.count {
                responsePromise.succeed(answers)
            } else {
                responsePromise.fail(KeyboardInteractiveAuthError.cancelled)
            }
        }
    }
}

/// UI 层的质询呈现(sheet(item:) 用)
struct KeyboardInteractivePrompt: Identifiable {
    let id = UUID()
    let challenge: KeyboardInteractiveAuthDelegate.Challenge
}

enum KeyboardInteractiveAuthError: LocalizedError {
    case exhausted
    case cancelled
    case promptUnavailable

    var errorDescription: String? {
        switch self {
        case .exhausted:
            return String(localized: "服务器拒绝了密码与交互式认证。请检查密码,或确认服务器允许 password / keyboard-interactive 登录。")
        case .cancelled:
            return String(localized: "已取消交互式认证。")
        case .promptUnavailable:
            return String(localized: "服务器要求交互式输入(如 MFA 动态码),当前平台暂不支持该输入界面。")
        }
    }
}
