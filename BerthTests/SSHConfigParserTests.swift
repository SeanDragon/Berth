import XCTest
@testable import Berth

final class SSHConfigParserTests: XCTestCase {

    func testBasicBlock() {
        let config = """
        Host web
            HostName web.example.com
            User deploy
            Port 2200
        """
        let hosts = SSHConfigParser.parse(config, homeDirectory: "/Users/tester")
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].alias, "web")
        XCTAssertEqual(hosts[0].hostname, "web.example.com")
        XCTAssertEqual(hosts[0].user, "deploy")
        XCTAssertEqual(hosts[0].port, 2200)
    }

    func testHostnameDefaultsToAlias() {
        let hosts = SSHConfigParser.parse("Host bare.example.com\n  User root")
        XCTAssertEqual(hosts[0].hostname, "bare.example.com")
    }

    func testPubkeyDisabledMarksPasswordAuth() {
        let config = """
        Host pw-only
            HostName 10.0.0.9
            PubkeyAuthentication no

        Host kb-only
            HostName 10.0.0.10
            PreferredAuthentications password,keyboard-interactive

        Host normal
            HostName 10.0.0.11
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertTrue(hosts[0].prefersPasswordAuth)
        XCTAssertTrue(hosts[1].prefersPasswordAuth)
        XCTAssertFalse(hosts[2].prefersPasswordAuth)
    }

    func testMultipleAliasesInOneHostLine() {
        let config = """
        Host web api
            HostName shared.example.com
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts.map(\.alias), ["web", "api"])
        XCTAssertEqual(hosts[0].hostname, "shared.example.com")
        XCTAssertEqual(hosts[1].hostname, "shared.example.com")
    }

    func testWildcardBlockAppliesButIsNotListed() {
        let config = """
        Host *
            User fallback
            Port 2222
        Host web
            HostName web.example.com
            Port 22
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts.map(\.alias), ["web"])
        XCTAssertEqual(hosts[0].user, "fallback")
        // ssh 语义:第一次出现的值生效 —— Host * 在前,Port 取 2222
        XCTAssertEqual(hosts[0].port, 2222)
    }

    func testFirstObtainedValueWins() {
        let config = """
        Host web
            HostName first.example.com
        Host web
            HostName second.example.com
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostname, "first.example.com")
    }

    func testNegatedPatternExcludesBlock() {
        let config = """
        Host * !web
            User fallback
        Host web
            HostName web.example.com
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertNil(hosts[0].user)
    }

    func testIdentityFileTildeExpansion() {
        let config = """
        Host web
            IdentityFile ~/.ssh/prod_key
        """
        let hosts = SSHConfigParser.parse(config, homeDirectory: "/Users/tester")
        XCTAssertEqual(hosts[0].identityFile, "/Users/tester/.ssh/prod_key")
    }

    func testProxyJump() {
        let config = """
        Host internal
            HostName 10.0.0.8
            ProxyJump bastion.example.com
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts[0].proxyJump, "bastion.example.com")
    }

    func testGlobalOptionsBeforeAnyHostActAsWildcard() {
        let config = """
        User global
        Host web
            HostName web.example.com
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts[0].user, "global")
    }

    func testMatchBlockSkipped() {
        let config = """
        Host web
            HostName web.example.com
        Match user deploy
            Port 9999
        Host api
            HostName api.example.com
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts.map(\.alias), ["web", "api"])
        XCTAssertNil(hosts[0].port)
        XCTAssertNil(hosts[1].port)
    }

    func testCommentsAndEqualsSyntax() {
        let config = """
        # 生产环境
        Host web
            HostName=web.example.com
            User = deploy
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts[0].hostname, "web.example.com")
        XCTAssertEqual(hosts[0].user, "deploy")
    }

    func testQuotedValue() {
        let config = """
        Host web
            IdentityFile "/Users/tester/my keys/prod"
        """
        let hosts = SSHConfigParser.parse(config)
        XCTAssertEqual(hosts[0].identityFile, "/Users/tester/my keys/prod")
    }

    func testWildcardMatching() {
        XCTAssertTrue(SSHConfigParser.wildcardMatch("web-1", pattern: "web-*"))
        XCTAssertTrue(SSHConfigParser.wildcardMatch("web", pattern: "*"))
        XCTAssertTrue(SSHConfigParser.wildcardMatch("web1", pattern: "web?"))
        XCTAssertFalse(SSHConfigParser.wildcardMatch("web12", pattern: "web?"))
        XCTAssertFalse(SSHConfigParser.wildcardMatch("api", pattern: "web*"))
    }

    // MARK: - 诊断(首次导入引导集中展示,不再静默吞掉)

    func testIncludeAndMatchAreReported() {
        let config = """
        Include ~/.orbstack/ssh/config

        Host web
            HostName web.example.com

        Match host bastion
            User admin
        """
        let result = SSHConfigParser.parseDetailed(config)
        XCTAssertEqual(result.hosts.map(\.alias), ["web"])
        XCTAssertTrue(result.issues.contains { $0.kind == .includeNotExpanded("~/.orbstack/ssh/config") })
        XCTAssertTrue(result.issues.contains { $0.kind == .matchBlockSkipped("host bastion") })
    }

    func testInvalidPortReportedAndFallsBack() {
        let result = SSHConfigParser.parseDetailed("Host web\n  Port 端口\n")
        XCTAssertNil(result.hosts[0].port)
        XCTAssertTrue(result.issues.contains { $0.kind == .invalidPort("端口") })

        let outOfRange = SSHConfigParser.parseDetailed("Host web\n  Port 70000\n")
        XCTAssertNil(outOfRange.hosts[0].port)
        XCTAssertTrue(outOfRange.issues.contains { $0.kind == .invalidPort("70000") })
    }

    func testDuplicateAliasReportedOnce() {
        let config = """
        Host web
            HostName first.example.com

        Host web
            HostName second.example.com
        """
        let result = SSHConfigParser.parseDetailed(config)
        XCTAssertEqual(result.hosts.count, 1)
        // ssh 语义:参数取先出现的
        XCTAssertEqual(result.hosts[0].hostname, "first.example.com")
        XCTAssertEqual(result.issues.filter { $0.kind == .duplicateAlias("web") }.count, 1)
    }

    /// Host 后面没别名时,块内的选项不能漏进全局 Host * 影响其它主机
    func testHostWithoutAliasDoesNotLeakOptions() {
        let config = """
        Host
            User leaked

        Host web
            HostName web.example.com
        """
        let result = SSHConfigParser.parseDetailed(config)
        XCTAssertEqual(result.hosts.map(\.alias), ["web"])
        XCTAssertNil(result.hosts[0].user)
        XCTAssertTrue(result.issues.contains { $0.kind == .hostWithoutAlias })
    }

    func testCleanConfigHasNoIssues() {
        let config = """
        Host web
            HostName web.example.com
            User deploy
            Port 2200
        """
        XCTAssertTrue(SSHConfigParser.parseDetailed(config).issues.isEmpty)
    }

    // MARK: - Include 指令测试

    private func createTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BerthTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }
        return tempDir
    }

    /// Test A: ~/.ssh/conf.d/*.conf 通配与 ~ 展开
    func testIncludeTildeGlobConf() throws {
        let tempHome = try createTempDirectory()
        let sshDir = tempHome.appendingPathComponent(".ssh")
        let confD = sshDir.appendingPathComponent("conf.d")
        try FileManager.default.createDirectory(at: confD, withIntermediateDirectories: true)

        let rootConfig = "Include ~/.ssh/conf.d/*.conf\n"
        let configFile = sshDir.appendingPathComponent("config")
        try rootConfig.write(to: configFile, atomically: true, encoding: .utf8)

        let conf1 = """
        Host 10-home
            HostName home.example.com
            User dev
            Port 2201
        """
        try conf1.write(to: confD.appendingPathComponent("10-home.conf"), atomically: true, encoding: .utf8)

        let conf2 = """
        Host 20-work
            HostName work.example.com
            User workuser
            Port 2202
        """
        try conf2.write(to: confD.appendingPathComponent("20-work.conf"), atomically: true, encoding: .utf8)

        let result = SSHConfigParser.parseFileDetailed(at: configFile.path, homeDirectory: tempHome.path)
        XCTAssertEqual(result.hosts.map(\.alias), ["10-home", "20-work"])
        XCTAssertEqual(result.hosts[0].hostname, "home.example.com")
        XCTAssertEqual(result.hosts[0].user, "dev")
        XCTAssertEqual(result.hosts[0].port, 2201)
        XCTAssertEqual(result.hosts[1].hostname, "work.example.com")
        XCTAssertEqual(result.hosts[1].user, "workuser")
        XCTAssertEqual(result.hosts[1].port, 2202)
        XCTAssertFalse(result.issues.contains { issue in
            if case .includeNotExpanded = issue.kind { return true }
            return false
        })
    }

    /// Test B: 绝对路径单文件 Include
    func testIncludeAbsolutePathSingleFile() throws {
        let tempDir = try createTempDirectory()
        let workConf = tempDir.appendingPathComponent("work.conf")
        let workContent = """
        Host work
            HostName work.example.com
            User workuser
            Port 2222
        """
        try workContent.write(to: workConf, atomically: true, encoding: .utf8)

        let rootConf = tempDir.appendingPathComponent("root.conf")
        let rootContent = "Include \(workConf.path)\n"
        try rootContent.write(to: rootConf, atomically: true, encoding: .utf8)

        let result = SSHConfigParser.parseFileDetailed(at: rootConf.path, homeDirectory: tempDir.path)
        XCTAssertEqual(result.hosts.map(\.alias), ["work"])
        XCTAssertEqual(result.hosts[0].hostname, "work.example.com")
        XCTAssertEqual(result.hosts[0].user, "workuser")
        XCTAssertEqual(result.hosts[0].port, 2222)
        XCTAssertTrue(result.issues.isEmpty)
    }

    /// Test C: glob 字典序与 first-obtained-value 生效
    func testIncludeGlobLexicalOrderAndFirstObtainedValue() throws {
        let tempHome = try createTempDirectory()
        let confD = tempHome.appendingPathComponent(".ssh/conf.d")
        try FileManager.default.createDirectory(at: confD, withIntermediateDirectories: true)

        let file20 = """
        Host web
            HostName second.example.com
            User second
        """
        try file20.write(to: confD.appendingPathComponent("20-second.conf"), atomically: true, encoding: .utf8)

        let file10 = """
        Host web
            HostName first.example.com
            User first
        """
        try file10.write(to: confD.appendingPathComponent("10-first.conf"), atomically: true, encoding: .utf8)

        let rootConfigFile = tempHome.appendingPathComponent(".ssh/config")
        try "Include ~/.ssh/conf.d/*.conf".write(to: rootConfigFile, atomically: true, encoding: .utf8)

        let result = SSHConfigParser.parseFileDetailed(at: rootConfigFile.path, homeDirectory: tempHome.path)
        XCTAssertEqual(result.hosts.count, 1)
        // 10-first.conf 字典序在前,first obtained value 为准
        XCTAssertEqual(result.hosts[0].hostname, "first.example.com")
        XCTAssertEqual(result.hosts[0].user, "first")
        XCTAssertTrue(result.issues.contains { $0.kind == .duplicateAlias("web") })
    }

    /// Test D: 纯文本 parser 依然不访问文件系统,不展开 Include
    func testPureStringParserDoesNotExpandInclude() {
        let config = """
        Include ~/.ssh/conf.d/*.conf

        Host foo
            HostName foo.example.com
        """
        let result = SSHConfigParser.parseDetailed(config)
        XCTAssertEqual(result.hosts.map(\.alias), ["foo"])
        XCTAssertTrue(result.issues.contains { $0.kind == .includeNotExpanded("~/.ssh/conf.d/*.conf") })
    }

    /// Test E: Host 块内的 Include 不支持展开
    func testIncludeInsideHostBlockNotExpanded() throws {
        let tempDir = try createTempDirectory()
        let extraConf = tempDir.appendingPathComponent("foo-extra.conf")
        try "Host extra\n    HostName extra.example.com".write(to: extraConf, atomically: true, encoding: .utf8)

        let rootConf = tempDir.appendingPathComponent("config")
        let rootContent = """
        Host foo
            HostName foo.example.com
            Include \(extraConf.path)
        """
        try rootContent.write(to: rootConf, atomically: true, encoding: .utf8)

        let result = SSHConfigParser.parseFileDetailed(at: rootConf.path, homeDirectory: tempDir.path)
        XCTAssertEqual(result.hosts.map(\.alias), ["foo"])
        XCTAssertTrue(result.issues.contains { $0.kind == .includeNotExpanded(extraConf.path) })
    }

    /// Test F: 递归 Include 不支持展开
    func testRecursiveIncludeNotExpanded() throws {
        let tempDir = try createTempDirectory()
        let secondConf = tempDir.appendingPathComponent("second.conf")
        try "Host second\n    HostName second.example.com".write(to: secondConf, atomically: true, encoding: .utf8)

        let firstConf = tempDir.appendingPathComponent("first.conf")
        let firstContent = """
        Host first
            HostName first.example.com

        Include \(secondConf.path)
        """
        try firstContent.write(to: firstConf, atomically: true, encoding: .utf8)

        let rootConf = tempDir.appendingPathComponent("config")
        try "Include \(firstConf.path)".write(to: rootConf, atomically: true, encoding: .utf8)

        let result = SSHConfigParser.parseFileDetailed(at: rootConf.path, homeDirectory: tempDir.path)
        XCTAssertEqual(result.hosts.map(\.alias), ["first"])
        XCTAssertTrue(result.issues.contains { $0.kind == .includeNotExpanded(secondConf.path) })
    }

    /// Test G: 不存在 / 无匹配 Include 不 crash
    func testIncludeNonExistentPathDoesNotCrash() throws {
        let tempHome = try createTempDirectory()
        let rootConf = tempHome.appendingPathComponent("config")
        let rootContent = """
        Include ~/.ssh/not-found/*.conf

        Host local
            HostName local.example.com
        """
        try rootContent.write(to: rootConf, atomically: true, encoding: .utf8)

        let result = SSHConfigParser.parseFileDetailed(at: rootConf.path, homeDirectory: tempHome.path)
        XCTAssertEqual(result.hosts.map(\.alias), ["local"])
        XCTAssertTrue(result.issues.contains { $0.kind == .includeNotExpanded("~/.ssh/not-found/*.conf") })
    }

    /// Test H: 仅匹配 .conf 文件并跳过子目录与非 .conf 文件
    func testIncludeGlobSkipsNonConfAndDirectories() throws {
        let tempHome = try createTempDirectory()
        let confD = tempHome.appendingPathComponent(".ssh/conf.d")
        try FileManager.default.createDirectory(at: confD, withIntermediateDirectories: true)

        try "Host valid\n    HostName valid.example.com".write(to: confD.appendingPathComponent("10-valid.conf"), atomically: true, encoding: .utf8)
        try "# Ignore me".write(to: confD.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: confD.appendingPathComponent("subdir.conf"), withIntermediateDirectories: true)

        let rootConf = tempHome.appendingPathComponent(".ssh/config")
        try "Include ~/.ssh/conf.d/*.conf".write(to: rootConf, atomically: true, encoding: .utf8)

        let result = SSHConfigParser.parseFileDetailed(at: rootConf.path, homeDirectory: tempHome.path)
        XCTAssertEqual(result.hosts.map(\.alias), ["valid"])
        XCTAssertFalse(result.issues.contains { issue in
            if case .includeNotExpanded = issue.kind { return true }
            return false
        })
    }

    /// Test I: Included Host 接收 Host * fallback 选项
    func testIncludedHostsReceiveWildcardFallbackOptions() throws {
        let tempHome = try createTempDirectory()
        let confD = tempHome.appendingPathComponent(".ssh/conf.d")
        try FileManager.default.createDirectory(at: confD, withIntermediateDirectories: true)

        let hostsConf = """
        Host nas
            HostName nas.example.com
        """
        try hostsConf.write(to: confD.appendingPathComponent("10-hosts.conf"), atomically: true, encoding: .utf8)

        let rootConfig = """
        Include ~/.ssh/conf.d/*.conf

        Host *
            User fallback-user
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
        """
        let configFile = tempHome.appendingPathComponent(".ssh/config")
        try rootConfig.write(to: configFile, atomically: true, encoding: .utf8)

        let result = SSHConfigParser.parseFileDetailed(at: configFile.path, homeDirectory: tempHome.path)
        XCTAssertEqual(result.hosts.count, 1)
        XCTAssertEqual(result.hosts[0].alias, "nas")
        XCTAssertEqual(result.hosts[0].hostname, "nas.example.com")
        XCTAssertEqual(result.hosts[0].user, "fallback-user")
        XCTAssertEqual(result.hosts[0].port, 2222)
        XCTAssertEqual(result.hosts[0].identityFile, "\(tempHome.path)/.ssh/id_ed25519")
        XCTAssertFalse(result.issues.contains { issue in
            if case .includeNotExpanded = issue.kind { return true }
            return false
        })
    }

    /// Test J: Specific values 优先于 fallback,缺省项继承 Host * fallback
    func testIncludedHostSpecificOptionsOverrideWildcardFallback() throws {
        let tempHome = try createTempDirectory()
        let confD = tempHome.appendingPathComponent(".ssh/conf.d")
        try FileManager.default.createDirectory(at: confD, withIntermediateDirectories: true)

        let hostsConf = """
        Host nas
            HostName nas.example.com

        Host server
            HostName server.example.com
            User root
            Port 2200
        """
        try hostsConf.write(to: confD.appendingPathComponent("10-hosts.conf"), atomically: true, encoding: .utf8)

        let rootConfig = """
        Include ~/.ssh/conf.d/*.conf

        Host *
            User fallback-user
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
        """
        let configFile = tempHome.appendingPathComponent(".ssh/config")
        try rootConfig.write(to: configFile, atomically: true, encoding: .utf8)

        let result = SSHConfigParser.parseFileDetailed(at: configFile.path, homeDirectory: tempHome.path)
        XCTAssertEqual(result.hosts.count, 2)

        XCTAssertEqual(result.hosts[0].alias, "nas")
        XCTAssertEqual(result.hosts[0].hostname, "nas.example.com")
        XCTAssertEqual(result.hosts[0].user, "fallback-user")
        XCTAssertEqual(result.hosts[0].port, 2222)
        XCTAssertEqual(result.hosts[0].identityFile, "\(tempHome.path)/.ssh/id_ed25519")

        XCTAssertEqual(result.hosts[1].alias, "server")
        XCTAssertEqual(result.hosts[1].hostname, "server.example.com")
        XCTAssertEqual(result.hosts[1].user, "root")
        XCTAssertEqual(result.hosts[1].port, 2200)
        XCTAssertEqual(result.hosts[1].identityFile, "\(tempHome.path)/.ssh/id_ed25519")

        XCTAssertTrue(result.issues.isEmpty)
    }
}

final class KeychainStoreTests: XCTestCase {

    func testRoundtripAndDelete() throws {
        let account = "unittest.\(UUID().uuidString)"
        try KeychainStore.save("secret-1", account: account)
        XCTAssertEqual(try KeychainStore.read(account: account), "secret-1")

        // 覆盖更新
        try KeychainStore.save("secret-2", account: account)
        XCTAssertEqual(try KeychainStore.read(account: account), "secret-2")

        try KeychainStore.delete(account: account)
        XCTAssertNil(try KeychainStore.read(account: account))

        // 删除不存在的账户不应抛错
        XCTAssertNoThrow(try KeychainStore.delete(account: account))
    }
}
