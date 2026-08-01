import XCTest
@testable import Berth

/// 检查更新的纯逻辑:版本比较、tag 规整、GitHub API 响应解析。
final class UpdateCheckerTests: XCTestCase {

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("1.5.0", than: "1.4.0"))
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.4.1", than: "1.4.0"))
        // 段数不齐短侧补 0
        XCTAssertTrue(UpdateChecker.isNewer("1.4.0.1", than: "1.4.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.4", than: "1.4.0"))
        // 相同与更旧
        XCTAssertFalse(UpdateChecker.isNewer("1.4.0", than: "1.4.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.3.9", than: "1.4.0"))
        // 预发布后缀忽略
        XCTAssertFalse(UpdateChecker.isNewer("1.4.0-beta", than: "1.4.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.5.0-rc1", than: "1.4.0"))
    }

    func testTagNormalization() {
        XCTAssertEqual(UpdateChecker.normalizedTag("v1.4.0"), "1.4.0")
        XCTAssertEqual(UpdateChecker.normalizedTag("V2.0"), "2.0")
        XCTAssertEqual(UpdateChecker.normalizedTag(" 1.4.0 "), "1.4.0")
    }

    /// fixture 与 GitHub Releases API 真实字段一致
    func testParsesLatestReleaseResponse() throws {
        let json = """
        {"tag_name": "v1.5.0", "html_url": "https://github.com/xinghelee/Berth/releases/tag/v1.5.0", "name": "Berth 1.5.0", "draft": false}
        """
        let update = try XCTUnwrap(UpdateChecker.parseLatestRelease(Data(json.utf8)))
        XCTAssertEqual(update.version, "1.5.0")
        XCTAssertEqual(update.pageURL.absoluteString, "https://github.com/xinghelee/Berth/releases/tag/v1.5.0")
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(UpdateChecker.parseLatestRelease(Data("not json".utf8)))
        XCTAssertNil(UpdateChecker.parseLatestRelease(Data("{}".utf8)))
        XCTAssertNil(UpdateChecker.parseLatestRelease(Data(#"{"tag_name": "v"}"#.utf8)))
    }
}
