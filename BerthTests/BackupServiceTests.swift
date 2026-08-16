import SwiftData
import XCTest
@testable import Berth

@MainActor
final class BackupServiceTests: XCTestCase {

    func testExportIncludesSavedManagedHostAndExcludesSSHConfigMirror() throws {
        // 测试宿主带 CloudKit entitlement,不显式关掉同步的话内存库会尝试接 CloudKit 并崩溃
        let schema = Schema([Host.self, HostGroup.self, PortForward.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let group = HostGroup(name: "Production")
        let managed = Host(label: "API", hostname: "api.example.com", username: "deploy", group: group)
        let configMirror = Host(label: "Local alias", hostname: "127.0.0.1", username: "me", source: .sshConfig)
        context.insert(group)
        context.insert(managed)
        context.insert(configMirror)
        try context.save()

        let data = try BackupService.export(context: context)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(BackupService.Backup.self, from: data)

        XCTAssertEqual(backup.groups.map(\.id), [group.id])
        XCTAssertEqual(backup.hosts.map(\.id), [managed.id])
    }
}
