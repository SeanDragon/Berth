import Foundation
import SwiftTerm

/// 本地 Shell 自动化验收:BERTH_LOCAL_AUTOTEST=1 时执行。
///   BERTH_TEST_DUMP=/tmp/local — 结果日志与缓冲区 dump 的基础路径
/// 流程:开本地 Shell → echo 求值校验(排除命令回显误判)→ 分屏(第二个本地会话)
/// → exit 自动关 pane → 自定义 shell 路径(/bin/sh)生效 → 全部关闭。
@MainActor
enum LocalShellAcceptanceTest {

    static func runIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard env["BERTH_LOCAL_AUTOTEST"] == "1",
              let dumpBase = env["BERTH_TEST_DUMP"] else { return }

        var log: [String] = []
        func mark(_ step: String) {
            log.append(step)
            try? log.joined(separator: "\n").write(toFile: dumpBase + ".log", atomically: true, encoding: .utf8)
        }

        // 1. 打开本地 Shell
        let manager = SessionManager.shared
        let session = manager.open(spec: .localShell())
        guard await waitForConnected(session, timeout: 10) else {
            mark("LOCAL_CONNECT_TIMEOUT state=\(session.state)")
            return
        }
        mark("LOCAL_CONNECTED shell=\(LocalShell.resolvedShellPath())")

        // 2. echo 求值:输出 BERTH_LOCAL_42 只能来自 shell 真实求值(命令行里是 $((40+2)))
        try? await Task.sleep(for: .seconds(1))
        session.sendText("echo BERTH_LOCAL_$((40+2))\n")
        try? await Task.sleep(for: .seconds(1))
        let text = bufferText(session)
        mark(text.contains("BERTH_LOCAL_42") ? "ECHO_EVAL_OK" : "ECHO_EVAL_MISSING")
        dump(session, to: dumpBase + ".first")

        // 3. 分屏:应新建第二个本地会话
        manager.splitFocused(axis: .horizontal)
        guard let second = manager.selected, second.id != session.id else {
            mark("SPLIT_NO_SECONDARY")
            return
        }
        guard await waitForConnected(second, timeout: 10) else {
            mark("SPLIT_CONNECT_TIMEOUT state=\(second.state)")
            return
        }
        mark("SPLIT_CONNECTED sessions=\(manager.sessions.count)")

        // 3b. 混合分屏 API:在聚焦 pane 旁再分出一个本地 Shell(pane 树不关心会话类型)
        manager.splitFocusedLocalShell(axis: .vertical)
        guard let third = manager.selected, third.id != second.id,
              await waitForConnected(third, timeout: 10) else {
            mark("LOCAL_SPLIT_FAILED")
            return
        }
        mark("LOCAL_SPLIT_CONNECTED sessions=\(manager.sessions.count)")
        try? await Task.sleep(for: .seconds(1))
        third.sendText("exit\n")
        guard await waitFor(timeout: 5, { manager.sessions.count == 2 }) else {
            mark("LOCAL_SPLIT_EXIT_TIMEOUT sessions=\(manager.sessions.count)")
            return
        }
        mark("LOCAL_SPLIT_EXIT_OK")

        // 4. exit → onShellExit 自动关闭该 pane
        try? await Task.sleep(for: .seconds(1))
        second.sendText("exit\n")
        let closed = await waitFor(timeout: 5) { manager.sessions.count == 1 }
        mark(closed ? "EXIT_CLOSED_PANE" : "EXIT_CLOSE_TIMEOUT sessions=\(manager.sessions.count)")

        // 5. 自定义 shell 路径:/bin/sh 下 echo $0 应输出 -sh(命令行里是未求值的 $0)
        UserDefaults.standard.set("/bin/sh", forKey: SettingsKeys.localShellPath)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKeys.localShellPath) }
        let custom = manager.open(spec: .localShell())
        guard await waitForConnected(custom, timeout: 10) else {
            mark("CUSTOM_SHELL_TIMEOUT state=\(custom.state)")
            return
        }
        try? await Task.sleep(for: .seconds(1))
        custom.sendText("echo shell_is_$0\n")
        try? await Task.sleep(for: .seconds(1))
        let customText = bufferText(custom)
        mark(customText.contains("shell_is_-sh") ? "CUSTOM_SHELL_OK" : "CUSTOM_SHELL_MISMATCH")
        dump(custom, to: dumpBase + ".custom")

        custom.sendText("exit\n")
        _ = await waitFor(timeout: 5) { manager.sessions.count == 1 }

        // 5b. 常见 shell 矩阵(issue #10 回归):zsh/bash 验证作业控制真开
        //(无控制终端时 zsh monitor 为 off),fish 验证能活到执行命令
        //(无控制终端时 fish 启动即退)。marker 带算术求值,防命令回显误判。
        let matrix: [(path: String, probe: String, marker: String)] = [
            ("/bin/zsh", "[[ -o monitor ]] && echo BERTH_JCZSH_$((40+2))\n", "BERTH_JCZSH_42"),
            ("/bin/bash", "[[ -o monitor ]] && echo BERTH_JCBASH_$((40+2))\n", "BERTH_JCBASH_42"),
            ("/opt/homebrew/bin/fish", "echo BERTH_FISH_(math 40+2)\n", "BERTH_FISH_42"),
        ]
        for entry in matrix {
            guard FileManager.default.isExecutableFile(atPath: entry.path) else {
                mark("MATRIX_SKIP \(entry.path)")
                continue
            }
            UserDefaults.standard.set(entry.path, forKey: SettingsKeys.localShellPath)
            let probe = manager.open(spec: .localShell())
            guard await waitForConnected(probe, timeout: 10) else {
                mark("MATRIX_CONNECT_FAIL \(entry.path) state=\(probe.state)")
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
            probe.sendText(entry.probe)
            try? await Task.sleep(for: .seconds(1))
            let passed = bufferText(probe).contains(entry.marker)
            mark(passed ? "MATRIX_OK \(entry.path)" : "MATRIX_FAIL \(entry.path)")
            manager.closePane(probe)
            _ = await waitFor(timeout: 5) { manager.sessions.count == 1 }
            if !passed { return }
        }
        UserDefaults.standard.removeObject(forKey: SettingsKeys.localShellPath)

        // 6. 全部关闭(首个会话 ⌘W 路径)
        manager.closePane(session)
        let allClosed = await waitFor(timeout: 5) { manager.sessions.isEmpty }
        mark(allClosed ? "ALL_DONE" : "CLOSE_INCOMPLETE sessions=\(manager.sessions.count)")
    }

    private static func waitForConnected(_ session: TerminalSession, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .connected = session.state { return true }
            if case .disconnected = session.state { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    private static func waitFor(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    private static func bufferText(_ session: TerminalSession) -> String {
        let terminal = session.terminalView.getTerminal()
        return String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
    }

    private static func dump(_ session: TerminalSession, to path: String) {
        let terminal = session.terminalView.getTerminal()
        try? terminal.getBufferAsData(kind: .normal).write(to: URL(fileURLWithPath: path + ".normal"))
    }
}
