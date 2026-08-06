import Foundation

/// 本地 Shell 会话的 shell 解析:设置里可自定义路径,留空用登录 shell(与 Termite 语义一致)
enum LocalShell {
    /// 当前用户的登录 shell(passwd 记录);读不到时退回 $SHELL → /bin/zsh
    static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let raw = pw.pointee.pw_shell {
            let shell = String(cString: raw)
            if !shell.isEmpty { return shell }
        }
        if let env = ProcessInfo.processInfo.environment["SHELL"], !env.isEmpty {
            return env
        }
        return "/bin/zsh"
    }

    /// 设置项非空则用之(去首尾空白 + 展开 ~),否则登录 shell
    static func resolvedShellPath() -> String {
        let custom = (UserDefaults.standard.string(forKey: SettingsKeys.localShellPath) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !custom.isEmpty else { return loginShell() }
        return NSString(string: custom).expandingTildeInPath
    }
}
