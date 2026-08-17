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

    /// 递归删除:文件与符号链接先删(链接删自身),目录按最深优先,root 最后
    func testDirectoryDeletePlanOrdersDeepestFirst() async throws {
        typealias Item = SFTPBrowser.DownloadTreeEntry
        let tree: [String: [Item]] = [
            "/srv/junk": [
                Item(name: "a.txt", kind: .file, size: 1),
                Item(name: "link", kind: .symlink, size: 1),
                Item(name: "sub", kind: .directory, size: 0),
            ],
            "/srv/junk/sub": [
                Item(name: "deep", kind: .directory, size: 0),
                Item(name: "b.txt", kind: .file, size: 1),
            ],
            "/srv/junk/sub/deep": [],
        ]

        let plan = try await SFTPBrowser.makeDirectoryDeletePlan(remoteRoot: "/srv/junk") { path in
            tree[path] ?? []
        }

        XCTAssertEqual(plan.removals, ["/srv/junk/a.txt", "/srv/junk/link", "/srv/junk/sub/b.txt"])
        XCTAssertEqual(plan.directories, ["/srv/junk/sub/deep", "/srv/junk/sub", "/srv/junk"])
    }

    func testDirectoryUploadPlanRecursesAndSkipsSymlinks() throws {
        typealias Item = SFTPBrowser.UploadTreeEntry
        let root = URL(fileURLWithPath: "/local/project")
        let tree: [String: [Item]] = [
            "/local/project": [
                Item(name: "README.md", kind: .file, size: 12),
                Item(name: "empty", kind: .directory, size: 0),
                Item(name: "link", kind: .symlink, size: 8),
                Item(name: "nested", kind: .directory, size: 0),
            ],
            "/local/project/empty": [],
            "/local/project/nested": [
                Item(name: "data.bin", kind: .file, size: 32),
                Item(name: "deeper", kind: .directory, size: 0),
            ],
            "/local/project/nested/deeper": [
                Item(name: "zero", kind: .file, size: 0),
            ],
        ]
        var listedPaths: [String] = []

        let plan = try SFTPBrowser.makeDirectoryUploadPlan(localRoot: root) { url in
            listedPaths.append(url.path)
            return tree[url.path] ?? []
        }

        XCTAssertEqual(listedPaths, [
            "/local/project",
            "/local/project/empty",
            "/local/project/nested",
            "/local/project/nested/deeper",
        ])
        XCTAssertEqual(plan.directories, [[], ["empty"], ["nested"], ["nested", "deeper"]])
        XCTAssertEqual(plan.files.map(\.relativeComponents), [
            ["README.md"],
            ["nested", "data.bin"],
            ["nested", "deeper", "zero"],
        ])
        XCTAssertEqual(plan.files.map(\.localURL.path), [
            "/local/project/README.md",
            "/local/project/nested/data.bin",
            "/local/project/nested/deeper/zero",
        ])
        XCTAssertEqual(plan.totalBytes, 44)
        XCTAssertEqual(plan.skippedSymlinks, 1)
    }

    /// 真实文件系统:symlink 指向目录时 isDirectory 会随目标为真,必须先判 symlink,
    /// 否则会跟着链接把树外内容传上去(甚至循环)。
    func testListLocalDirectoryClassifiesSymlinkBeforeDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("berth-upload-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("dirlink"),
            withDestinationURL: sub
        )

        let entries = try SFTPBrowser.listLocalDirectory(root)

        XCTAssertEqual(entries.map(\.name), ["a.txt", "dirlink", "sub"])
        XCTAssertEqual(entries.first { $0.name == "a.txt" }?.kind, .file)
        XCTAssertEqual(entries.first { $0.name == "a.txt" }?.size, 5)
        XCTAssertEqual(entries.first { $0.name == "dirlink" }?.kind, .symlink)
        XCTAssertEqual(entries.first { $0.name == "sub" }?.kind, .directory)
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
