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

    // MARK: - 块级语法(标题/列表/引用/分隔线)

    func testBlankLineSplitsParagraphs() {
        XCTAssertEqual(
            AIMarkdownParser.parse("第一段\n\n第二段"),
            [.text("第一段"), .text("第二段")]
        )
    }

    func testHeadings() {
        XCTAssertEqual(
            AIMarkdownParser.parse("## 排查步骤\n正文"),
            [.heading(level: 2, text: "排查步骤"), .text("正文")]
        )
        // 无空格的 "#标签" 和 7 个 # 都不是标题
        XCTAssertEqual(AIMarkdownParser.parse("#标签"), [.text("#标签")])
        XCTAssertEqual(AIMarkdownParser.parse("####### 太深"), [.text("####### 太深")])
    }

    func testUnorderedList() {
        XCTAssertEqual(
            AIMarkdownParser.parse("- 甲\n* 乙\n+ 丙"),
            [.list(items: [
                AIListItem(marker: "•", text: "甲"),
                AIListItem(marker: "•", text: "乙"),
                AIListItem(marker: "•", text: "丙"),
            ])]
        )
    }

    func testOrderedListKeepsNumbers() {
        XCTAssertEqual(
            AIMarkdownParser.parse("1. 一\n2) 二\n10. 十"),
            [.list(items: [
                AIListItem(marker: "1.", text: "一"),
                AIListItem(marker: "2.", text: "二"),
                AIListItem(marker: "10.", text: "十"),
            ])]
        )
    }

    /// 年份、小数开头的正文不能误判成有序列表
    func testOrderedListFalsePositives() {
        XCTAssertEqual(AIMarkdownParser.parse("2024. 全年总结"), [.text("2024. 全年总结")])
        XCTAssertEqual(AIMarkdownParser.parse("1.5 倍速率"), [.text("1.5 倍速率")])
    }

    func testQuoteJoinsLines() {
        XCTAssertEqual(
            AIMarkdownParser.parse("> 第一行\n> 第二行"),
            [.quote("第一行\n第二行")]
        )
    }

    func testDivider() {
        XCTAssertEqual(AIMarkdownParser.parse("上\n\n---\n\n下"), [.text("上"), .divider, .text("下")])
        XCTAssertEqual(AIMarkdownParser.parse("--"), [.text("--")])
    }

    func testGFMTableAndColumnAlignment() {
        let raw = """
        名称 | 状态 | 占用
        :--- | :---: | ---:
        根目录 | **正常** | 74%
        日志 | 警告 | 91%
        """
        XCTAssertEqual(AIMarkdownParser.parse(raw), [
            .table(AIMarkdownTable(
                headers: ["名称", "状态", "占用"],
                alignments: [.leading, .center, .trailing],
                rows: [
                    ["根目录", "**正常**", "74%"],
                    ["日志", "警告", "91%"],
                ]
            )),
        ])
    }

    func testTableSupportsOuterPipesInlineCodeAndUnevenRows() {
        let raw = """
        | 键 | 值 |
        | --- | --- |
        | 命令 | `printf "a | b"` |
        | 空值 |
        | 多列 | 一 | 忽略 |
        """
        XCTAssertEqual(AIMarkdownParser.parse(raw), [
            .table(AIMarkdownTable(
                headers: ["键", "值"],
                alignments: [.leading, .leading],
                rows: [
                    ["命令", "`printf \"a | b\"`"],
                    ["空值", ""],
                    ["多列", "一"],
                ]
            )),
        ])
    }

    func testPipeTextWithoutSeparatorIsNotTable() {
        XCTAssertEqual(
            AIMarkdownParser.parse("A | B\n这不是分隔行"),
            [.text("A | B\n这不是分隔行")]
        )
    }

    func testCodeBlockTableClassification() {
        XCTAssertTrue(AICodeBlockClassifier.looksLikeTable("""
        +----+--------+
        | ID | 状态   |
        +----+--------+
        | 1  | 正常   |
        +----+--------+
        """))
        XCTAssertTrue(AICodeBlockClassifier.looksLikeTable("""
        名称 | 状态
        --- | ---
        API | 正常
        """))
        XCTAssertTrue(AICodeBlockClassifier.looksLikeTable("""
        ID    名称       状态
        --    ---------- ----
        1     Alice      正常
        """))
        XCTAssertTrue(AICodeBlockClassifier.looksLikeTable("""
        ┌────┬──────┐
        │ ID │ 状态 │
        └────┴──────┘
        """))
        XCTAssertFalse(AICodeBlockClassifier.looksLikeTable("ps aux | grep nginx\ncat app.log | tail"))
    }

    /// 代码块内的 "# 注释"、"- 参数" 不能被当成标题/列表
    func testBlockSyntaxInsideFenceIsLiteral() {
        XCTAssertEqual(
            AIMarkdownParser.parse("```\n# comment\n- flag\n```"),
            [.code(language: nil, code: "# comment\n- flag")]
        )
    }

    func testTerminalPayloadDropsChinesePresentationComments() {
        let code = """
        # 在 Proxmox 宿主机上确认可用内存充足后
        swapoff -a && swapon -a
        """
        XCTAssertEqual(AITerminalPayload.make(from: code), "swapoff -a && swapon -a")
    }

    func testTerminalPayloadPreservesExecutableHashesAndPlainComments() {
        let code = """
        # managed by Berth
        printf '# keep this literal\\n'
        echo done # shell comment
        """
        XCTAssertEqual(AITerminalPayload.make(from: code), code)
    }

    func testBracketedPasteEncoderDoesNotAddEnter() {
        XCTAssertEqual(
            TerminalPasteEncoder.encode("echo one\\necho two", bracketed: true),
            "\u{1b}[200~echo one\\necho two\u{1b}[201~"
        )
        XCTAssertEqual(TerminalPasteEncoder.encode("echo ok", bracketed: false), "echo ok")
    }

    func testMixedDocument() {
        let raw = """
        ## 结论
        磁盘满了。

        > df 输出显示 /var 100%

        处理:
        1. 清日志
        2. 扩容

        ```bash
        du -sh /var/log/*
        ```
        """
        XCTAssertEqual(AIMarkdownParser.parse(raw), [
            .heading(level: 2, text: "结论"),
            .text("磁盘满了。"),
            .quote("df 输出显示 /var 100%"),
            .text("处理:"),
            .list(items: [
                AIListItem(marker: "1.", text: "清日志"),
                AIListItem(marker: "2.", text: "扩容"),
            ]),
            .code(language: "bash", code: "du -sh /var/log/*"),
        ])
    }
}
