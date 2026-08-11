import Foundation
import SwiftData

/// 会话模板:一组标签页的分屏布局(叶子 = 主机),一键恢复整套工作现场。
@Model
final class Workspace {
    var id: UUID = UUID()
    var name: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date()
    /// WorkspaceLayout 的 JSON 编码
    var layoutJSON: String = "{}"

    init(id: UUID = UUID(), name: String, layoutJSON: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.layoutJSON = layoutJSON
        self.sortOrder = sortOrder
        self.createdAt = Date()
    }
}

/// 模板布局编码:与 PaneNode 同构,叶子存主机 id(恢复时按 id 解析,找不到的跳过)
struct WorkspaceLayout: Codable, Equatable {
    indirect enum Node: Codable, Equatable {
        case leaf(hostID: UUID)
        // axis: "h" | "v";ratio = first 侧占比,nil = 对半。
        // Optional 关联值缺字段时解码为 nil,旧模板 JSON 无需迁移
        case split(axis: String, ratio: Double?, first: Node, second: Node)
    }

    var tabs: [Node]

    var hostCount: Int {
        func count(_ node: Node) -> Int {
            switch node {
            case .leaf: return 1
            case .split(_, _, let a, let b): return count(a) + count(b)
            }
        }
        return tabs.reduce(0) { $0 + count($1) }
    }

    func encodedJSON() -> String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func decode(_ json: String) -> WorkspaceLayout? {
        json.data(using: .utf8).flatMap { try? JSONDecoder().decode(WorkspaceLayout.self, from: $0) }
    }
}
