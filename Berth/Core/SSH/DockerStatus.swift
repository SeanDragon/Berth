import Foundation

/// 远端 Docker 状态快照(inspector 展示,经 exec 通道采集)。
/// 一期只读:容器列表 + compose 分组;不做操作类(启停/日志)。
struct DockerStatus: Equatable {

    enum Availability: Equatable {
        case available
        /// 主机没装 docker —— inspector 整段不显示,不打扰无关用户
        case notInstalled
        /// CLI 在但访问被拒(典型:当前用户不在 docker 组)
        case permissionDenied
        /// daemon 没起来或 socket 不可达
        case daemonUnreachable(String)
    }

    var availability: Availability = .notInstalled
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
    /// docker 的报错经 2>&1 收进正文由解析器分类。
    static let collectionScript = """
    if ! command -v docker >/dev/null 2>&1; then
      printf 'DOCKER_STATE=absent\\n'
      exit 0
    fi
    out=$(docker ps -a --no-trunc --format '{{json .}}' 2>&1)
    if [ $? -ne 0 ]; then
      printf 'DOCKER_STATE=error\\n%s\\n' "$out"
      exit 0
    fi
    printf 'DOCKER_STATE=ok\\n%s\\n' "$out"
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

    func command(containerID: String) -> String {
        "docker \(rawValue) \(Self.sanitized(containerID))"
    }

    static func logsCommand(containerID: String, tail: Int = 200) -> String {
        "docker logs --tail \(tail) \(sanitized(containerID)) 2>&1"
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
        id = (object["ID"] as? String) ?? ""
        name = (object["Names"] as? String) ?? ""
        image = (object["Image"] as? String) ?? ""
        state = (object["State"] as? String) ?? ""
        status = (object["Status"] as? String) ?? ""
        ports = (object["Ports"] as? String) ?? ""
        if let labels = object["Labels"] as? String {
            composeProject = labels.split(separator: ",")
                .first { $0.hasPrefix("com.docker.compose.project=") }
                .map { String($0.dropFirst("com.docker.compose.project=".count)) }
        }
        guard !id.isEmpty || !name.isEmpty else { return nil }
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
