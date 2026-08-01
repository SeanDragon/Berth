import XCTest
@testable import Berth

/// 远端 Docker 状态:采集脚本输出解析、compose 分组、端口紧凑化。
final class DockerStatusTests: XCTestCase {

    func testAbsent() {
        let status = DockerStatus(parsing: "DOCKER_STATE=absent\n")
        XCTAssertEqual(status.availability, .notInstalled)
        XCTAssertTrue(status.containers.isEmpty)
    }

    func testPermissionDenied() {
        let status = DockerStatus(parsing: """
        DOCKER_STATE=error
        permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock
        """)
        XCTAssertEqual(status.availability, .permissionDenied)
    }

    func testDaemonUnreachable() {
        let status = DockerStatus(parsing: """
        DOCKER_STATE=error
        Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?
        """)
        guard case .daemonUnreachable(let message) = status.availability else {
            return XCTFail("应为 daemonUnreachable,实际 \(status.availability)")
        }
        XCTAssertTrue(message.contains("Cannot connect"))
    }

    /// fixture 取自真实 `docker ps -a --no-trunc --format '{{json .}}'` 输出(字段结构一致)
    func testParsesRealShapedOutput() {
        let status = DockerStatus(parsing: """
        DOCKER_STATE=ok
        {"Command":"\\"/init\\"","ID":"d29f75bb7021","Image":"lscr.io/linuxserver/openssh-server:latest","Labels":"build_version=x,maintainer=aptalca","Names":"berth-test-sshd","Ports":"127.0.0.1:2222-\\u003e2222/tcp","State":"running","Status":"Up 3 hours"}
        {"Command":"\\"node server.js\\"","ID":"39aee42f8b31","Image":"infra:local","Labels":"com.docker.compose.project.working_dir=/x,com.docker.compose.project=infra,com.docker.compose.service=web","Names":"infra","Ports":"127.0.0.1:8089-\\u003e80/tcp, :::8089-\\u003e80/tcp","State":"running","Status":"Up 17 minutes"}
        {"Command":"\\"sh\\"","ID":"aaa111","Image":"alpine:3","Labels":"","Names":"scratch","Ports":"","State":"exited","Status":"Exited (0) 2 days ago"}
        """)
        XCTAssertEqual(status.availability, .available)
        XCTAssertEqual(status.containers.count, 3)
        XCTAssertEqual(status.runningCount, 2)

        let sshd = status.containers[0]
        XCTAssertEqual(sshd.name, "berth-test-sshd")
        XCTAssertNil(sshd.composeProject, "非 compose 标签不能误判为项目")
        XCTAssertEqual(sshd.displayPorts, "2222→2222/tcp")

        let infra = status.containers[1]
        XCTAssertEqual(infra.composeProject, "infra", "必须精确匹配 project= 而非 project.working_dir=")
        XCTAssertEqual(infra.displayPorts, "8089→80/tcp", "IPv4/IPv6 重复发布要去重")

        XCTAssertFalse(status.containers[2].isRunning)
    }

    func testComposeGroupingKeepsLooseContainersLast() {
        var status = DockerStatus(parsing: """
        DOCKER_STATE=ok
        {"ID":"1","Names":"loose","State":"exited","Status":"","Image":"a","Labels":"","Ports":""}
        {"ID":"2","Names":"web-1","State":"running","Status":"","Image":"b","Labels":"com.docker.compose.project=web","Ports":""}
        {"ID":"3","Names":"web-2","State":"running","Status":"","Image":"c","Labels":"com.docker.compose.project=web","Ports":""}
        """)
        let groups = status.grouped
        XCTAssertEqual(groups.map(\.project), ["web", ""])
        XCTAssertEqual(groups[0].containers.map(\.name), ["web-1", "web-2"])
        XCTAssertEqual(groups[1].containers.map(\.name), ["loose"])
        status = DockerStatus()
        XCTAssertTrue(status.grouped.isEmpty)
    }

    func testUnpublishedPortStaysVerbatim() {
        var container = DockerContainer()
        container.ports = "80/tcp, 443/tcp"
        XCTAssertEqual(container.displayPorts, "80/tcp, 443/tcp")
    }

    func testGarbageLinesIgnored() {
        let status = DockerStatus(parsing: """
        DOCKER_STATE=ok
        not json at all
        {"ID":"1","Names":"ok","State":"running","Status":"","Image":"a","Labels":"","Ports":""}
        """)
        XCTAssertEqual(status.containers.count, 1)
    }

    /// 集成:在本机跑真实采集脚本(与远端 exec 执行的是同一段),解析结果必须自洽。
    /// 本机装了 docker 走 available 路径,没装走 notInstalled —— 两者都算通过。
    func testCollectionScriptRunsForReal() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", DockerStatus.collectionScript]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, "采集脚本必须恒 exit 0")
        let status = DockerStatus(parsing: String(data: data, encoding: .utf8) ?? "")
        switch status.availability {
        case .available:
            // 每个容器至少有名字和状态
            for container in status.containers {
                XCTAssertFalse(container.name.isEmpty)
                XCTAssertFalse(container.state.isEmpty)
            }
        case .notInstalled, .permissionDenied, .daemonUnreachable:
            XCTAssertTrue(status.containers.isEmpty)
        }
    }
}
