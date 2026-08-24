import Foundation

/// 远端 Docker/Podman 状态快照(inspector 展示,经 exec 通道采集)。
/// 一期只读:容器列表 + compose 分组;不做操作类(启停/日志)。
struct DockerStatus: Equatable {

    enum Runtime: String, Equatable {
        case docker
        case podman

        var executable: String { rawValue }
        var displayName: String { rawValue.capitalized }
    }

    enum Availability: Equatable {
        case available
        /// 主机没装 Docker 或 Podman —— inspector 整段不显示,不打扰无关用户
        case notInstalled
        /// 运行时 CLI 在但访问被拒
        case permissionDenied
        /// Docker/Podman 服务没起来或 socket 不可达
        case daemonUnreachable(String)
    }

    var availability: Availability = .notInstalled
    var runtime: Runtime = .docker
    var containers: [DockerContainer] = []

    var runningCount: Int { containers.filter(\.isRunning).count }

    /// compose 项目分组(组内保持 docker ps 原序,即最新在前);
    /// 非 compose 容器归入空名组,排最后。
    var grouped: [(project: String, containers: [DockerContainer])] {
        var order: [String] = []
        var buckets: [String: [DockerContainer]] = [:]
        for container in containers {
            let key = container.composeProject ?? ""
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(container)
        }
        return order
            .sorted { ($0.isEmpty ? 1 : 0, "") < ($1.isEmpty ? 1 : 0, "") }
            .map { ($0, buckets[$0] ?? []) }
    }

    /// 采集脚本:保证 exit 0(Citadel executeCommand 对非零退出会抛错),
    /// 两个运行时的报错经 2>&1 收进正文由解析器分类。
    static let collectionScript = """
    docker_error=""
    podman_error=""
    docker_candidate=0
    podman_candidate=0

    if command -v docker >/dev/null 2>&1; then
      docker_candidate=1
      docker_version=$(docker --version 2>&1)
      if printf '%s' "$docker_version" | grep -qi podman && command -v podman >/dev/null 2>&1; then
        docker_candidate=0
      fi
    fi
    if command -v podman >/dev/null 2>&1; then podman_candidate=1; fi

    if [ "$docker_candidate" -eq 1 ]; then
      out=$(docker ps -a --no-trunc --format '{{json .}}' 2>&1)
      if [ $? -eq 0 ]; then
        printf 'DOCKER_STATE=ok\\nDOCKER_RUNTIME=docker\\n%s\\n' "$out"
        exit 0
      fi
      docker_error="$out"
    fi

    if [ "$podman_candidate" -eq 1 ]; then
      out=$(podman ps -a --no-trunc --format '{{json .}}' 2>&1)
      if [ $? -eq 0 ]; then
        printf 'DOCKER_STATE=ok\\nDOCKER_RUNTIME=podman\\n%s\\n' "$out"
        exit 0
      fi
      podman_error="$out"
    fi

    if [ "$docker_candidate" -eq 0 ] && [ "$podman_candidate" -eq 0 ]; then
      printf 'DOCKER_STATE=absent\\n'
    else
      printf 'DOCKER_STATE=error\\n%s\\n%s\\n' "$docker_error" "$podman_error"
    fi
    exit 0
    """

    init() {}

    init(parsing text: String) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)[...]
        guard let stateLine = lines.first else { return }
        lines = lines.dropFirst()
        switch stateLine.trimmingCharacters(in: .whitespaces) {
        case "DOCKER_STATE=absent":
            availability = .notInstalled
        case "DOCKER_STATE=ok":
            availability = .available
            if let runtimeLine = lines.first, runtimeLine.hasPrefix("DOCKER_RUNTIME=") {
                let value = runtimeLine.dropFirst("DOCKER_RUNTIME=".count)
                runtime = Runtime(rawValue: String(value)) ?? .docker
                lines = lines.dropFirst()
            }
            containers = lines.compactMap { DockerContainer(jsonLine: String($0)) }
        case "DOCKER_STATE=error":
            let message = lines.joined(separator: " ")
            if message.localizedCaseInsensitiveContains("permission denied") {
                availability = .permissionDenied
            } else {
                availability = .daemonUnreachable(String(message.prefix(200)))
            }
        default:
            availability = .notInstalled
        }
    }
}

/// 容器管理动作(二期:启动/停止/重启;删除属危险操作,刻意不做)
enum DockerAction: String, CaseIterable {
    case start, stop, restart

    /// 展示用动词
    var label: String {
        switch self {
        case .start: return String(localized: "启动")
        case .stop: return String(localized: "停止")
        case .restart: return String(localized: "重启")
        }
    }

    /// 容器 ID 白名单过滤(docker 的 ID/名称字符集),防注入
    static func sanitized(_ id: String) -> String {
        id.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
    }

    func command(containerID: String, runtime: DockerStatus.Runtime = .docker) -> String {
        "\(runtime.executable) \(rawValue) \(Self.sanitized(containerID))"
    }

    static func logsCommand(
        containerID: String,
        tail: Int = 200,
        runtime: DockerStatus.Runtime = .docker
    ) -> String {
        "\(runtime.executable) logs --tail \(tail) \(sanitized(containerID)) 2>&1"
    }
}

struct DockerContainer: Equatable, Identifiable {
    var id = ""
    var name = ""
    var image = ""
    /// running / exited / paused / restarting / created / dead / removing
    var state = ""
    /// 人话状态,如 "Up 3 hours"、"Exited (0) 2 days ago"
    var status = ""
    var ports = ""
    var composeProject: String?

    var isRunning: Bool { state == "running" }

    init() {}

    /// `docker ps --format '{{json .}}'` 的一行
    init?(jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        id = (object["ID"] as? String) ?? (object["Id"] as? String) ?? ""
        if let value = object["Names"] as? String {
            name = value
        } else if let values = object["Names"] as? [String] {
            name = values.first ?? ""
        }
        image = (object["Image"] as? String) ?? ""
        state = (object["State"] as? String) ?? ""
        status = (object["Status"] as? String) ?? ""
        if status.isEmpty { status = state.capitalized }
        ports = Self.parsePorts(object["Ports"])
        if let labels = object["Labels"] as? String {
            composeProject = labels.split(separator: ",")
                .first { $0.hasPrefix("com.docker.compose.project=") }
                .map { String($0.dropFirst("com.docker.compose.project=".count)) }
        } else if let labels = object["Labels"] as? [String: String] {
            composeProject = labels["com.docker.compose.project"]
        }
        guard !id.isEmpty || !name.isEmpty else { return nil }
    }

    private static func parsePorts(_ value: Any?) -> String {
        if let value = value as? String { return value }
        guard let values = value as? [[String: Any]] else { return "" }
        return values.compactMap { port in
            guard let containerPort = port["container_port"] as? Int,
                  let protocolName = port["protocol"] as? String else { return nil }
            if let hostPort = port["host_port"] as? Int, hostPort > 0 {
                return "\(hostPort)→\(containerPort)/\(protocolName)"
            }
            return "\(containerPort)/\(protocolName)"
        }.joined(separator: ", ")
    }

    /// 端口的紧凑展示:"0.0.0.0:8080->80/tcp, :::8080->80/tcp" → "8080→80/tcp";
    /// 未发布的 "80/tcp" 原样保留;IPv4/IPv6 重复项去重。
    var displayPorts: String {
        var seen = Set<String>()
        var parts: [String] = []
        for raw in ports.split(separator: ",") {
            let segment = raw.trimmingCharacters(in: .whitespaces)
            guard !segment.isEmpty else { continue }
            let compact: String
            if let arrow = segment.range(of: "->") {
                let host = segment[..<arrow.lowerBound]
                let container = segment[arrow.upperBound...]
                let hostPort = host.split(separator: ":").last.map(String.init) ?? String(host)
                compact = "\(hostPort)→\(container)"
            } else {
                compact = segment
            }
            if seen.insert(compact).inserted { parts.append(compact) }
        }
        return parts.joined(separator: ", ")
    }
}
