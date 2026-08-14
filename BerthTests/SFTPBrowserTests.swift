import XCTest
@testable import Berth

@MainActor
final class SFTPBrowserTests: XCTestCase {

    func testDirectoryDownloadPlanRecursesAndSkipsSymlinks() async throws {
        typealias Item = SFTPBrowser.DownloadTreeEntry
        let tree: [String: [Item]] = [
            "/srv/project": [
                Item(name: "empty", kind: .directory, size: 0),
                Item(name: "README.md", kind: .file, size: 12),
                Item(name: "nested", kind: .directory, size: 0),
                Item(name: "outside", kind: .symlink, size: 8),
                Item(name: ".", kind: .directory, size: 0),
            ],
            "/srv/project/empty": [],
            "/srv/project/nested": [
                Item(name: "data.bin", kind: .file, size: 32),
                Item(name: "deeper", kind: .directory, size: 0),
            ],
            "/srv/project/nested/deeper": [
                Item(name: "zero", kind: .file, size: 0),
            ],
        ]
        var listedPaths: [String] = []

        let plan = try await SFTPBrowser.makeDirectoryDownloadPlan(remoteRoot: "/srv/project") { path in
            listedPaths.append(path)
            return tree[path] ?? []
        }

        XCTAssertEqual(listedPaths, [
            "/srv/project",
            "/srv/project/empty",
            "/srv/project/nested",
            "/srv/project/nested/deeper",
        ])
        XCTAssertEqual(plan.directories, [[], ["empty"], ["nested"], ["nested", "deeper"]])
        XCTAssertEqual(plan.files, [
            SFTPBrowser.DownloadTreeFile(
                remotePath: "/srv/project/README.md",
                relativeComponents: ["README.md"],
                size: 12
            ),
            SFTPBrowser.DownloadTreeFile(
                remotePath: "/srv/project/nested/data.bin",
                relativeComponents: ["nested", "data.bin"],
                size: 32
            ),
            SFTPBrowser.DownloadTreeFile(
                remotePath: "/srv/project/nested/deeper/zero",
                relativeComponents: ["nested", "deeper", "zero"],
                size: 0
            ),
        ])
        XCTAssertEqual(plan.totalBytes, 44)
        XCTAssertEqual(plan.skippedSymlinks, 1)
    }

    /// SFTP 服务端通常把大 read 拆成几十 KB 的短包;只有空包才是 EOF。
    func testChunkCopyContinuesAfterShortRead() async throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        let serverPacketSize = 32 * 1024
        var readOffsets: [UInt64] = []
        var downloaded = Data()

        let copied = try await SFTPBrowser.copyDownloadChunks(
            chunkSize: 256 * 1024,
            read: { offset, requestedLength in
                readOffsets.append(offset)
                let start = Int(offset)
                guard start < payload.count else { return Data() }
                let count = min(serverPacketSize, Int(requestedLength), payload.count - start)
                return payload.subdata(in: start..<(start + count))
            },
            write: { downloaded.append($0) }
        )

        XCTAssertEqual(downloaded, payload)
        XCTAssertEqual(copied, UInt64(payload.count))
        XCTAssertEqual(readOffsets.first, 0)
        XCTAssertEqual(readOffsets.last, UInt64(payload.count), "完整写入后还应再读一次空包确认 EOF")
        XCTAssertGreaterThan(readOffsets.count, 2, "首个短包后不能提前结束")
    }
}
