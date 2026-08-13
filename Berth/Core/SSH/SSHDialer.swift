import Citadel
import Crypto
import Foundation
import LocalAuthentication
import NIOSSH

/// 建立一条到目标主机的 SSH 连接:代理 → 跳板链 → 认证 → known_hosts 校验。
///
/// 终端会话(`TerminalSession`)与仪表盘监控(`ServerMonitor`)共用同一套拨号逻辑,
/// 差别只在交互回调:终端会话弹窗问用户;后台监控一律不弹窗(见 `nonInteractive`),
/// 需要人参与的主机由调用方降级展示,而不是在后台悄悄弹一堆 sheet。
@MainActor
struct SSHDialer {
    struct Outcome {
        let client: SSHClient
        /// 跳板链上的中间 client,必须保活以维持隧道;所有权由调用方(SSHConnection)接管
        let jumpClients: [SSHClient]
    }

    enum DialError: LocalizedError {
        case unsupportedKey
        case missingKeyFile
        case missingStoredKey
        case authenticationGateFailed
        /// 后台监控路径遇到需要人参与的环节(Touch ID / 未知主机密钥 / MFA)
        case needsInteraction(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedKey:
                return String(localized: "无法解析私钥文件:目前支持 OpenSSH 格式的 ed25519 / RSA 私钥。若密钥带 passphrase,请确认已正确填写。")
            case .missingKeyFile:
                return String(localized: "该主机设了密钥认证,但没有指定私钥文件。请在主机设置里选一把密钥,或改用密码认证。")
            case .missingStoredKey:
                return String(localized: "找不到该主机引用的密钥,请在「密钥」页检查或重新选择。")
            case .authenticationGateFailed:
                return String(localized: "身份验证未通过,已取消连接。可在设置中关闭「使用密钥前要求 Touch ID」。")
            case .needsInteraction(let detail):
                return detail
            }
        }
    }

    let spec: HostSpec
    /// 临时直连/自动化验收用:绕过 Keychain 的一次性凭据
    var transientPassword: String?
    var transientPassphrase: String?
    /// 阶段文案(连接跳板机 / 经代理…),终端会话用它更新 state
    var onProgress: (String) -> Void = { _ in }
    /// 未知或变更的主机密钥决策;返回 false 中止连接
    var hostKeyDecision: @Sendable (HostKeyPrompt) async -> Bool
    /// keyboard-interactive 质询(堡垒机 MFA);返回 nil 放弃认证
    var keyboardInteractive: @Sendable (KeyboardInteractiveAuthDelegate.Challenge) async -> [String]?
    /// 用密钥前的门禁(Touch ID)。只在链路上确有密钥认证时调用,抛错即中止
    var keyGate: () async throws -> Void = {}

    /// 后台监控用:任何需要人参与的环节都直接失败,绝不弹窗。
    /// - Parameter allowKeyUse: 用户已在仪表盘显式授权过(过了一次 Touch ID)时为 true。
    static func nonInteractive(spec: HostSpec, allowKeyUse: Bool) -> SSHDialer {
        SSHDialer(
            spec: spec,
            hostKeyDecision: { _ in false },
            keyboardInteractive: { _ in nil },
            keyGate: {
                let gated = UserDefaults.standard.object(forKey: SettingsKeys.requireTouchIDForKeys) as? Bool ?? true
                guard gated, !allowKeyUse else { return }
                throw DialError.needsInteraction(String(localized: "该主机用密钥认证,需先授权后台使用密钥。"))
            }
        )
    }

    /// 链路上(目标 + 各跳板)是否用到私钥
    var usesPrivateKeys: Bool {
        ([spec] + spec.jump).contains { $0.authMethod != .password }
    }

    /// 建立连接:无跳板则直连;有跳板则连最外层跳板后逐跳 jump。
    func dial() async throws -> Outcome {
        // 目标或任一跳板用密钥时,连接前统一过一次门禁(避免链路上多次弹窗)
        if usesPrivateKeys { try await keyGate() }

        guard !spec.jump.isEmpty else {
            return Outcome(client: try await connectEntry(to: spec, useTransient: true), jumpClients: [])
        }

        var jumpClients: [SSHClient] = []
        do {
            // 连最外层跳板
            let first = spec.jump[0]
            onProgress(String(localized: "正在连接跳板机 \(first.hostname):\(String(first.port))…"))
            var current = try await connectEntry(to: first, useTransient: false)
            jumpClients.append(current)

            // 逐跳 jump 到后续跳板
            for hop in spec.jump.dropFirst() {
                onProgress(String(localized: "经跳板机 → \(hop.hostname):\(String(hop.port))…"))
                current = try await current.jump(to: try settings(for: hop, useTransient: false))
                jumpClients.append(current)
            }

            // 最后 jump 到目标本机
            onProgress(String(localized: "经跳板机 → \(spec.hostname):\(String(spec.port))…"))
            let client = try await current.jump(to: try settings(for: spec, useTransient: true))
            return Outcome(client: client, jumpClients: jumpClients)
        } catch {
            // 半截失败时把已建好的跳板连接收掉,别把隧道漏在后台
            let leaked = jumpClients
            Task.detached { for jump in leaked.reversed() { try? await jump.close() } }
            throw error
        }
    }

    /// 最外层 TCP 连接:配了代理就先经代理再交给 Citadel;否则直连。
    private func connectEntry(to hop: HostSpec, useTransient: Bool) async throws -> SSHClient {
        let clientSettings = try settings(for: hop, useTransient: useTransient)
        guard spec.proxy.isEnabled else {
            return try await SSHClient.connect(to: clientSettings)
        }
        onProgress(String(localized: "经代理 \(spec.proxy.host):\(String(spec.proxy.port)) 连接 \(hop.hostname):\(String(hop.port))…"))
        let proxyPassword = spec.proxy.requiresAuth
            ? try KeychainStore.read(account: KeychainStore.proxyPasswordAccount(for: spec.hostID))
            : nil
        let channel = try await ProxyConnector.connect(
            through: spec.proxy,
            proxyPassword: proxyPassword,
            to: hop.hostname,
            port: hop.port
        )
        return try await SSHClient.connect(on: channel, settings: clientSettings)
    }

    private func settings(for hop: HostSpec, useTransient: Bool) throws -> SSHClientSettings {
        let method = try authenticationMethod(for: hop, useTransient: useTransient)
        var settings = SSHClientSettings(
            host: hop.hostname,
            port: hop.port,
            authenticationMethod: { method },
            hostKeyValidator: hostKeyValidator(for: hop)
        )
        settings.algorithms = .berthCompatibility
        return settings
    }

    private func authenticationMethod(for hop: HostSpec, useTransient: Bool) throws -> SSHAuthenticationMethod {
        let transientPW = useTransient ? transientPassword : nil
        let transientPP = useTransient ? transientPassphrase : nil
        switch hop.authMethod {
        case .password:
            let password = try transientPW
                ?? KeychainStore.read(account: KeychainStore.passwordAccount(for: hop.hostID))
                ?? ""
            // password 失败自动转 keyboard-interactive(堡垒机 MFA,issue #12):
            // 第一轮 Password: 提示自动用存储密码作答,MFA 动态码交给 prompter
            let prompter = keyboardInteractive
            let delegate = KeyboardInteractiveAuthDelegate(
                username: hop.username,
                password: password
            ) { challenge in
                await prompter(challenge)
            }
            return .custom(delegate)

        case .privateKeyFile:
            guard let path = hop.privateKeyPath, !path.isEmpty else { throw DialError.missingKeyFile }
            let expanded = NSString(string: path).expandingTildeInPath
            let keyText = try String(contentsOfFile: expanded, encoding: .utf8)
            let passphrase = try transientPP
                ?? KeychainStore.read(account: KeychainStore.passphraseAccount(for: hop.hostID))
            return try Self.keyAuthentication(username: hop.username, keyText: keyText, passphrase: passphrase)

        case .storedKey:
            guard let keyID = hop.keyID,
                  let material = try KeychainStore.read(account: KeychainStore.privateKeyAccount(for: keyID)) else {
                throw DialError.missingStoredKey
            }
            // 生成的密钥存 raw ed25519(base64 32 字节);导入的存 OpenSSH PEM
            if let raw = Data(base64Encoded: material), raw.count == 32,
               let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
                return .ed25519(username: hop.username, privateKey: key)
            }
            let passphrase = try KeychainStore.read(account: KeychainStore.keyPassphraseAccount(for: keyID))
            return try Self.keyAuthentication(username: hop.username, keyText: material, passphrase: passphrase)

        case .agent:
            guard let agent = SSHAgentClient.fromEnvironment() else { throw AgentAuthError.noAgent }
            let identities = (try? agent.listIdentities()) ?? []
            let delegate = AgentAuthDelegate(username: hop.username, agent: agent, identities: identities)
            guard delegate.hasUsableKeys else { throw AgentAuthError.noIdentities }
            return .custom(delegate)
        }
    }

    private func hostKeyValidator(for hop: HostSpec) -> SSHHostKeyValidator {
        let decision = hostKeyDecision
        let validator = InteractiveHostKeyValidator(hostname: hop.hostname, port: hop.port) { prompt in
            await decision(prompt)
        }
        return .custom(validator)
    }

    private static func keyAuthentication(username: String, keyText: String, passphrase: String?) throws -> SSHAuthenticationMethod {
        // 磁盘上的私钥文件常是老式 PKCS#1/PKCS#8 PEM(~/.ssh/id_rsa、云厂商 .pem),
        // 归一化/解密/诊断统一走 parseForAuth(与 iOS、密钥导入同口径)。文件本身不动。
        switch try PrivateKeyFormat.parseForAuth(keyText, passphrase: passphrase).key {
        case .ed25519(let key): return .ed25519(username: username, privateKey: key)
        case .rsa(let key): return .rsa(username: username, privateKey: key)
        }
    }

    /// 规格 5.4:读取私钥用于连接前可要求 Touch ID(设置项,默认开)。
    /// 交互式调用方(终端会话、仪表盘的显式授权按钮)把它接到 `keyGate`。
    static func touchIDGate(reason: String, onProgress: (String) -> Void = { _ in }) async throws {
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.requireTouchIDForKeys) as? Bool ?? true
        guard enabled else { return }
        onProgress(String(localized: "等待身份验证(Touch ID)…"))
        let context = LAContext()
        do {
            // deviceOwnerAuthentication:优先生物识别,失败回退登录密码
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            throw DialError.authenticationGateFailed
        }
    }
}
