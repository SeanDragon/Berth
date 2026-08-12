import Foundation

/// 连接错误的人话化(M1 基础版,M2 按规格 5.3 覆盖更多场景)
enum SSHErrorMapper {
    static func friendlyMessage(
        for error: Error,
        hostname: String,
        port: Int,
        authMethod: AuthMethodKind? = nil
    ) -> String {
        let raw = String(describing: error)
        // keyboard-interactive 的错误自带人话文案(取消 / 密码+交互式双失败),原样透出
        if let kbi = error as? KeyboardInteractiveAuthError {
            return kbi.errorDescription ?? raw
        }
        if raw.localizedCaseInsensitiveContains("allAuthenticationOptionsFailed")
            || raw.localizedCaseInsensitiveContains("authentication") {
            // 按认证方式给针对性排查提示
            switch authMethod {
            case .password:
                return String(localized: "认证失败:密码不正确,或服务器没有开放该用户的密码登录。")
            case .privateKeyFile, .storedKey, .agent:
                return String(localized: "认证失败:服务器不接受这把密钥。请确认公钥已加入服务器上该用户的 ~/.ssh/authorized_keys,且用户名无误。")
            case nil:
                return String(localized: "认证失败:服务器拒绝了用户名、密码或密钥。")
            }
        }
        // 密钥交换协商失败:双方算法列表无交集(vendor 补丁会在 diagnostics 里带上双方列表)。
        // 已追加 DH group14 / aes128-ctr / RSA host key 兼容,仍失败说明服务器算法更冷门,
        // 把原始列表透出便于 issue 排查。
        if raw.contains("keyExchangeNegotiationFailure") {
            return String(localized: "无法与 \(hostname) 就加密算法达成一致:服务器要求的密钥交换/加密/主机密钥算法不在支持范围内。请把下面的诊断信息反馈给开发者:")
                + "\n" + raw
        }
        if raw.localizedCaseInsensitiveContains("refused") {
            return String(localized: "连不上 \(hostname):\(String(port)):连接被拒绝,检查端口号和 sshd 是否在运行。")
        }
        // EHOSTUNREACH / ENETUNREACH。同网段地址报这个,十有八九是 macOS 15 的本地网络
        // 门禁没放行 —— 系统在网络层就把 connect() 挡了,错误和"真的没路由"长得一模一样。
        if raw.localizedCaseInsensitiveContains("no route to host")
            || raw.localizedCaseInsensitiveContains("host is down")
            || raw.localizedCaseInsensitiveContains("network is unreachable")
            || raw.localizedCaseInsensitiveContains("network is down") {
            if isLocalNetworkAddress(hostname) {
                return String(localized: "连不上 \(hostname):\(String(port)):没有到主机的路由。")
                    + String(localized: "这是局域网地址,多半是 macOS 拦下了本地网络访问 —— 打开「系统设置 › 隐私与安全性 › 本地网络」,把 Berth 的开关打开再试。")
            }
            return String(localized: "连不上 \(hostname):\(String(port)):没有到主机的路由,检查地址、网段和网络连接。")
        }
        // Citadel 的 Disconnected():TCP 已通但服务器在认证完成前关闭了连接。
        // 典型原因是源 IP 触发了服务器的连接频率限制(OpenSSH 9.8+ PerSourcePenalties / fail2ban)。
        if raw.contains("Disconnected") {
            return String(localized: "服务器在握手阶段关闭了连接:多半是本机 IP 触发了 \(hostname) 的连接频率限制")
                + String(localized: "(OpenSSH PerSourcePenalties 或 fail2ban)。请等待几分钟后再试,期间不要反复重连。")
        }
        if raw.localizedCaseInsensitiveContains("timed out") || raw.localizedCaseInsensitiveContains("timeout") {
            return String(localized: "连不上 \(hostname):\(String(port)):连接超时,检查地址、防火墙或网络。")
        }
        if raw.localizedCaseInsensitiveContains("already closed")
            || raw.localizedCaseInsensitiveContains("connection reset")
            || raw.localizedCaseInsensitiveContains("eof") {
            return String(localized: "连接已中断:与 \(hostname) 的会话被关闭。")
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(localized: "连接失败:\(raw)")
    }

    /// 需要本地网络授权才能访问的地址(RFC1918 私网 / 链路本地 / mDNS 名)。
    /// 回环不算 —— 127.0.0.1 不过这道门禁。主机名解析前无从判断,一律按公网处理。
    static func isLocalNetworkAddress(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower.hasSuffix(".local") { return true }
        let parts = lower.split(separator: ".")
        guard parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]),
              parts.allSatisfy({ Int($0) != nil }) else { return false }
        switch (a, b) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
