import Foundation
import Observation

/// 一条聊天消息(用户或 AI)。assistant 消息的正文流式追加,工具调用以卡片形式挂在消息下。
@MainActor
@Observable
final class AIChatMessage: Identifiable {
    enum Role { case user, assistant }

    let id = UUID()
    let role: Role
    var text: String
    var toolCalls: [AIToolCall] = []
    /// 请求失败时的错误说明(展示在消息底部)
    var errorText: String?

    init(role: Role, text: String = "") {
        self.role = role
        self.text = text
    }
}

/// AI 请求执行的一条服务器命令(run_command 工具调用)
@MainActor
@Observable
final class AIToolCall: Identifiable {
    enum Status {
        case awaitingApproval
        case running
        case done
        case denied
    }

    let id: String
    let command: String
    var status: Status
    var output = ""
    var exitCode: Int?
    var isOutputExpanded = false

    init(id: String, command: String, status: Status) {
        self.id = id
        self.command = command
        self.status = status
    }
}

/// 每个终端会话一份的 AI 对话控制器:维护 UI 消息与 API 消息历史,驱动
/// 请求 → 工具调用(经用户确认)→ 回传结果 的循环。命令经会话的 SSH 连接
/// 在独立 exec 通道上执行,不影响终端 PTY。
@MainActor
@Observable
final class AIChatController {
    private(set) var messages: [AIChatMessage] = []
    private(set) var isBusy = false

    private weak var session: TerminalSession?
    private let spec: HostSpec
    /// API 侧对话历史(原始 content 块,thinking/tool_use 原样回传)
    @ObservationIgnored private var apiMessages: [[String: Any]] = []
    @ObservationIgnored private var approvals: [String: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?

    /// 单条用户消息最多允许的 请求→工具 循环轮数(防失控)
    private static let maxLoops = 12
    /// 回传给模型的单条命令输出上限(超出截断中段)
    private static let maxToolOutputChars = 12000

    init(session: TerminalSession) {
        self.session = session
        self.spec = session.spec
    }

    // MARK: - 对外操作

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        guard let client = AISettings.makeClient() else { return }

        messages.append(AIChatMessage(role: .user, text: trimmed))
        apiMessages.append(["role": "user", "content": trimmed])
        isBusy = true
        task = Task { [weak self] in
            await self?.runLoop(client: client)
            self?.isBusy = false
        }
    }

    /// 终端选中的报错/输出:包成一条带上下文的提问发出去
    func askAbout(_ selection: String) {
        let prompt = String(localized: "解释下面这段终端输出,如果是报错请给出原因和修复办法:")
            + "\n\n```\n" + selection + "\n```"
        send(prompt)
    }

    /// 停止当前请求(取消网络流;待确认的命令按拒绝处理)
    func stop() {
        task?.cancel()
        for (id, continuation) in approvals {
            approvals[id] = nil
            continuation.resume(returning: false)
        }
    }

    func clear() {
        stop()
        messages = []
        apiMessages = []
    }

    func approve(_ call: AIToolCall) { resolveApproval(call, allowed: true) }
    func deny(_ call: AIToolCall) { resolveApproval(call, allowed: false) }

    private func resolveApproval(_ call: AIToolCall, allowed: Bool) {
        guard let continuation = approvals[call.id] else { return }
        approvals[call.id] = nil
        continuation.resume(returning: allowed)
    }

    // MARK: - 请求循环

    private func runLoop(client: AIChatClient) async {
        for _ in 0..<Self.maxLoops {
            let assistant = AIChatMessage(role: .assistant)
            messages.append(assistant)

            let turn: AIChatTurn
            do {
                turn = try await client.complete(
                    system: systemPrompt(),
                    messages: apiMessages,
                    tools: [Self.runCommandTool],
                    onTextDelta: { delta in
                        Task { @MainActor in assistant.text += delta }
                    }
                )
            } catch is CancellationError {
                assistant.errorText = String(localized: "已停止")
                return
            } catch {
                if Task.isCancelled {
                    assistant.errorText = String(localized: "已停止")
                } else {
                    assistant.errorText = error.localizedDescription
                }
                return
            }

            // 以最终结果为准覆盖流式文本(网络中断时流式文本可能不完整)
            let fullText = turn.content
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            if !fullText.isEmpty { assistant.text = fullText }
            apiMessages.append(["role": "assistant", "content": turn.content])

            let toolUses = turn.content.filter {
                $0["type"] as? String == "tool_use" && $0["name"] as? String == "run_command"
            }

            switch turn.stopReason {
            case "tool_use" where !toolUses.isEmpty:
                var results: [[String: Any]] = []
                for use in toolUses {
                    guard let useID = use["id"] as? String else { continue }
                    let command = ((use["input"] as? [String: Any])?["command"] as? String) ?? ""
                    let result = await executeToolCall(id: useID, command: command, message: assistant)
                    results.append(result)
                }
                // 全部 tool_result 放进同一条 user 消息
                apiMessages.append(["role": "user", "content": results])
                if Task.isCancelled { return }
                continue
            case "refusal":
                if assistant.text.isEmpty {
                    assistant.errorText = String(localized: "AI 出于安全策略拒绝了这次请求。")
                }
                return
            case "max_tokens":
                assistant.errorText = String(localized: "回复超长被截断,可让 AI 继续。")
                return
            default:
                if assistant.text.isEmpty && assistant.toolCalls.isEmpty {
                    assistant.errorText = String(localized: "AI 没有返回内容。")
                }
                return
            }
        }
        messages.last?.errorText = String(localized: "已达到单次对话的命令轮数上限,请继续对话让 AI 接着做。")
    }

    /// 执行一条 run_command:按需等待用户确认 → SSH exec → 组装 tool_result
    private func executeToolCall(id: String, command: String, message: AIChatMessage) async -> [String: Any] {
        func result(_ text: String, isError: Bool = false) -> [String: Any] {
            ["type": "tool_result", "tool_use_id": id, "content": text, "is_error": isError]
        }

        guard !command.isEmpty else {
            return result("Empty command.", isError: true)
        }

        // 自动执行开着也拦危险命令;生产主机一律确认
        let needsApproval = !AISettings.autoRunCommands
            || BerthTerminalView.needsConfirmation(command)
            || spec.isProduction
        let call = AIToolCall(id: id, command: command, status: needsApproval ? .awaitingApproval : .running)
        message.toolCalls.append(call)

        if needsApproval {
            let allowed = await withCheckedContinuation { continuation in
                approvals[id] = continuation
            }
            guard allowed else {
                call.status = .denied
                return result("User declined to run this command. Ask before trying an alternative.")
            }
            call.status = .running
        }

        guard let session, let outcome = await session.runAICommand(command) else {
            call.status = .done
            call.output = String(localized: "会话未连接,无法执行命令。")
            return result("Not connected to the server; the command was not run.", isError: true)
        }

        call.output = outcome.output
        call.exitCode = outcome.exitCode
        call.status = .done

        var text = Self.truncated(outcome.output)
        if let code = outcome.exitCode {
            text += "\n[exit code: \(code)]"
        }
        return result(text, isError: (outcome.exitCode ?? 0) != 0)
    }

    /// 超长输出截中段,保留头尾(模型侧;UI 展示完整输出)
    private static func truncated(_ output: String) -> String {
        guard output.count > maxToolOutputChars else { return output }
        let head = output.prefix(maxToolOutputChars * 3 / 4)
        let tail = output.suffix(maxToolOutputChars / 4)
        return head + "\n…[output truncated, \(output.count) chars total]…\n" + tail
    }

    // MARK: - 提示词与工具定义

    private func systemPrompt() -> String {
        var lines: [String] = [
            "You are the built-in server-operations assistant of Berth, a macOS SSH client.",
            "Current SSH session: \(spec.username)@\(spec.hostname):\(spec.port) (labeled \"\(spec.label)\").",
            "Use the run_command tool to run shell commands on that server; it returns merged stdout/stderr and the exit code.",
            "Rules:",
            "- Reply in the user's language, concise and direct.",
            "- Commands must be non-interactive: never use TUIs (top/vim/less/htop); use flags like `top -b -n 1`, `--no-pager`, `-y` instead.",
            "- Prefer read-only inspection first. Before destructive actions (delete, restart services, edit configs), explain the impact.",
            "- Output may be truncated; run narrower follow-up commands when you need more.",
        ]
        if spec.isProduction {
            lines.append("- ⚠️ This host is marked as PRODUCTION. Be extra careful; avoid risky changes unless explicitly asked.")
        }
        if let cwd = session?.currentRemoteDirectory {
            lines.append("The user's terminal working directory is \(cwd) (your commands start from the login directory, not there).")
        }
        return lines.joined(separator: "\n")
    }

    private static let runCommandTool: [String: Any] = [
        "name": "run_command",
        "description": "Run a non-interactive shell command on the connected SSH server. Returns merged stdout/stderr and the exit code. Commands run via `sh -c` in a fresh exec channel (no state is kept between calls; use absolute paths or chain with `cd dir && …`).",
        "input_schema": [
            "type": "object",
            "properties": [
                "command": [
                    "type": "string",
                    "description": "The shell command to execute.",
                ],
            ],
            "required": ["command"],
        ],
    ]
}

/// 会话 id → 对话控制器:面板关闭再开保留历史,会话关闭时清理
@MainActor
final class AIChatStore {
    static let shared = AIChatStore()
    private var controllers: [UUID: AIChatController] = [:]

    func controller(for session: TerminalSession) -> AIChatController {
        if let existing = controllers[session.id] { return existing }
        let controller = AIChatController(session: session)
        controllers[session.id] = controller
        return controller
    }

    func remove(_ sessionID: UUID) {
        controllers[sessionID]?.stop()
        controllers[sessionID] = nil
    }
}
