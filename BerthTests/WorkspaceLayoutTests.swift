import XCTest
@testable import Berth

final class WorkspaceLayoutTests: XCTestCase {

    func testRoundTripSingleTab() {
        let host = UUID()
        let layout = WorkspaceLayout(tabs: [.leaf(hostID: host)])
        let restored = WorkspaceLayout.decode(layout.encodedJSON())
        XCTAssertEqual(restored, layout)
        XCTAssertEqual(restored?.hostCount, 1)
        XCTAssertEqual(restored?.tabs.count, 1)
    }

    func testRoundTripNestedSplits() {
        let a = UUID(), b = UUID(), c = UUID()
        // 一个标签:a 与(b 上下分屏 c)左右分屏;外层分割比 0.7
        let layout = WorkspaceLayout(tabs: [
            .split(axis: "h", ratio: 0.7, first: .leaf(hostID: a),
                   second: .split(axis: "v", ratio: nil, first: .leaf(hostID: b), second: .leaf(hostID: c)))
        ])
        let restored = WorkspaceLayout.decode(layout.encodedJSON())
        XCTAssertEqual(restored, layout)
        XCTAssertEqual(restored?.hostCount, 3)
    }

    func testHostCountAcrossTabs() {
        let layout = WorkspaceLayout(tabs: [
            .leaf(hostID: UUID()),
            .split(axis: "h", ratio: nil, first: .leaf(hostID: UUID()), second: .leaf(hostID: UUID())),
        ])
        XCTAssertEqual(layout.tabs.count, 2)
        XCTAssertEqual(layout.hostCount, 3)
    }

    /// ratio 字段是后加的:旧模板 JSON(无 ratio)必须原样解出来,不需要迁移
    func testDecodesLegacyJSONWithoutRatio() {
        let host = UUID()
        let legacy = """
        {"tabs":[{"split":{"axis":"h","first":{"leaf":{"hostID":"\(host.uuidString)"}},"second":{"leaf":{"hostID":"\(UUID().uuidString)"}}}}]}
        """
        let restored = WorkspaceLayout.decode(legacy)
        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.hostCount, 2)
        if case .split(_, let ratio, _, _)? = restored?.tabs.first {
            XCTAssertNil(ratio)
        } else {
            XCTFail("expected split node")
        }
    }

    func testDecodeGarbageReturnsNil() {
        XCTAssertNil(WorkspaceLayout.decode("not json"))
        XCTAssertNil(WorkspaceLayout.decode(""))
    }
}
