import XCTest
@testable import Berth

final class AIMarkdownParserTests: XCTestCase {

    func testPlainTextOnly() {
        XCTAssertEqual(AIMarkdownParser.parse("磁盘还剩 20%。"), [.text("磁盘还剩 20%。")])
    }

    /// 带语言标记的围栏:语言要摘出来,不能混进代码正文(此前会渲染成 “bash df -h”)
    func testFencedCodeWithLanguage() {
        let raw = """
        查看磁盘:

        ```bash
        df -h
        ```

        就这样。
        """
        XCTAssertEqual(AIMarkdownParser.parse(raw), [
            .text("查看磁盘:"),
            .code(language: "bash", code: "df -h"),
            .text("就这样。"),
        ])
    }

    func testMultipleBlocksAndMultilineCode() {
        let raw = """
        ```bash
        cd /var/log
        tail -n 50 syslog
        ```
        再看权限:
        ```
        ls -l
        ```
        """
        XCTAssertEqual(AIMarkdownParser.parse(raw), [
            .code(language: "bash", code: "cd /var/log\ntail -n 50 syslog"),
            .text("再看权限:"),
            .code(language: nil, code: "ls -l"),
        ])
    }

    /// 流式过程中围栏常常只开不闭,已到达的部分也要按代码块渲染,不能掉字
    func testUnclosedFenceDuringStreaming() {
        XCTAssertEqual(AIMarkdownParser.parse("试试:\n```bash\ndf -h"), [
            .text("试试:"),
            .code(language: "bash", code: "df -h"),
        ])
    }

    func testEmptyFenceProducesNoBlock() {
        XCTAssertEqual(AIMarkdownParser.parse("```bash\n```"), [])
    }
}
