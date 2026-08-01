import XCTest
@testable import Berth

/// 拖放上传的纯逻辑:冲突检测、~ 展开、路径拼接。
@MainActor
final class TerminalDropUploadTests: XCTestCase {

    func testConflictingNamesKeepsLocalOrder() {
        XCTAssertEqual(
            TerminalDropUploadModel.conflictingNames(
                localNames: ["a.txt", "b.txt", "c.txt"],
                remoteNames: ["c.txt", "a.txt", "unrelated"]
            ),
            ["a.txt", "c.txt"]
        )
        XCTAssertEqual(
            TerminalDropUploadModel.conflictingNames(localNames: ["a"], remoteNames: []),
            []
        )
    }

    func testExpandTilde() {
        XCTAssertEqual(TerminalDropUploadModel.expandTilde("~", home: "/home/dev"), "/home/dev")
        XCTAssertEqual(TerminalDropUploadModel.expandTilde("~/www", home: "/home/dev"), "/home/dev/www")
        XCTAssertEqual(TerminalDropUploadModel.expandTilde("/var/log", home: "/home/dev"), "/var/log")
        // "~abc" 不是 ~ 语法,原样保留
        XCTAssertEqual(TerminalDropUploadModel.expandTilde("~abc", home: "/home/dev"), "~abc")
    }

    func testJoin() {
        XCTAssertEqual(TerminalDropUploadModel.join("/", "a.txt"), "/a.txt")
        XCTAssertEqual(TerminalDropUploadModel.join("/var/www", "a.txt"), "/var/www/a.txt")
    }
}
