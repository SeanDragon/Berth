import XCTest
@testable import Berth

/// AI 助手的当前目录感知:exec 包装脚本的自动 cd 与探测输出解析。
final class AIWorkingDirectoryTests: XCTestCase {

    private let marker = "__TEST_EXIT__"

    func testCommandScriptWithoutDirectoryHasNoCd() {
        let script = TerminalSession.aiCommandScript("ls -la", startingDirectory: nil, marker: marker)
        XCTAssertFalse(script.contains("cd "))
        XCTAssertTrue(script.contains("ls -la"))
        XCTAssertTrue(script.contains(marker))
    }

    func testCommandScriptAutoCdsBeforeCommand() {
        let script = TerminalSession.aiCommandScript("ls", startingDirectory: "/var/log", marker: marker)
        let cdIndex = try! XCTUnwrap(script.range(of: "cd '/var/log' || exit"))
        let cmdIndex = try! XCTUnwrap(script.range(of: "\nls"))
        XCTAssertLessThan(cdIndex.lowerBound, cmdIndex.lowerBound, "cd 必须在命令之前")
    }

    /// 目录名含单引号/空格时必须正确转义,否则会拼出可注入的脚本
    func testCommandScriptQuotesDirectory() {
        let script = TerminalSession.aiCommandScript(
            "pwd", startingDirectory: "/tmp/it's a dir", marker: marker
        )
        XCTAssertTrue(script.contains("cd '/tmp/it'\\''s a dir' || exit"))
    }

    func testProbeParsingFiltersAndDedupes() {
        let output = """
        /var/log

        /home/dev
        readlink: missing operand
        /var/log
        relative/path
        \t/opt/app\u{20}
        """
        XCTAssertEqual(
            TerminalSession.parseWorkingDirectoryProbe(output),
            ["/var/log", "/home/dev", "/opt/app"]
        )
    }

    func testProbeParsingEmptyOutput() {
        XCTAssertEqual(TerminalSession.parseWorkingDirectoryProbe(""), [])
        XCTAssertEqual(TerminalSession.parseWorkingDirectoryProbe("\n\n"), [])
    }
}
