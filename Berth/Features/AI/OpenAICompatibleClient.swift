import Foundation

/// OpenAI 兼容后端(/v1/chat/completions + function calling)。
///
/// 很多中转网关只放行这一种路由(报错形如 “This group does not allow /v1/messages dispatch”),
/// OpenAI / DeepSeek / Qwen 等也是这套协议。对话历史在 AIChatController 里统一用
/// Anthropic 的 content-block 形状,这里负责请求前后各翻译一次。
struct OpenAICompatibleClient: AIChatClient {
    typealias Config = AIClientConfig

    let config: Config

    func complete(
        system: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        onTextDelta: @escaping (String) -> Void
    ) async throws -> Turn {
        var request = URLRequest(url: config.endpoint(path: "/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        var payload: [String: Any] = [
            "model": config.model,
            "stream": true,
            "messages": Self.openAIMessages(system: system, messages: messages),
        ]
        // 不发 max_tokens:各家模型上限差异大,交给服务端默认更通用
        if !tools.isEmpty {
            payload["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool["name"] as? String ?? "",
                        "description": tool["description"] as? String ?? "",
                        "parameters": tool["input_schema"] as? [String: Any] ?? [:],
                    ],
                ]
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIChatError(message: String(localized: "无效的服务器响应"))
        }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw AIChatError(message: Self.errorMessage(status: http.statusCode, body: body))
        }

        var text = ""
        /// 工具调用按 index 累积:id/name 只在首个分片出现,arguments 逐片拼接
        var calls: [Int: (id: String, name: String, arguments: String)] = [:]
        var finishReason: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if json == "[DONE]" { break }
            guard let data = json.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let error = event["error"] as? [String: Any] {
                throw AIChatError(message: error["message"] as? String ?? String(localized: "AI 服务返回错误"))
            }
            guard let choice = (event["choices"] as? [[String: Any]])?.first else { continue }
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
            guard let delta = choice["delta"] as? [String: Any] else { continue }

            if let chunk = delta["content"] as? String, !chunk.isEmpty {
                text += chunk
                onTextDelta(chunk)
            }
            for call in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                let index = call["index"] as? Int ?? 0
                var entry = calls[index] ?? (id: "", name: "", arguments: "")
                if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
                if let function = call["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty { entry.name = name }
                    if let args = function["arguments"] as? String { entry.arguments += args }
                }
                calls[index] = entry
            }
        }

        var content: [[String: Any]] = []
        if !text.isEmpty {
            content.append(["type": "text", "text": text])
        }
        for index in calls.keys.sorted() {
            guard let call = calls[index] else { continue }
            let input = call.arguments.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            content.append([
                "type": "tool_use",
                // 个别网关不回 id,用 index 兜底,保证 tool_result 能配上
                "id": call.id.isEmpty ? "call_\(index)" : call.id,
                "name": call.name,
                "input": input,
            ])
        }

        let stopReason: String
        if content.contains(where: { $0["type"] as? String == "tool_use" }) {
            stopReason = "tool_use"
        } else if finishReason == "length" {
            stopReason = "max_tokens"
        } else if finishReason == "content_filter" {
            stopReason = "refusal"
        } else {
            stopReason = "end_turn"
        }
        return Turn(content: content, stopReason: stopReason)
    }

    // MARK: - 消息翻译(Anthropic content blocks → OpenAI messages)

    static func openAIMessages(system: String, messages: [[String: Any]]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        if !system.isEmpty {
            result.append(["role": "system", "content": system])
        }
        for message in messages {
            let role = message["role"] as? String ?? "user"
            // 纯文本 user 消息直接过
            if let text = message["content"] as? String {
                result.append(["role": role, "content": text])
                continue
            }
            let blocks = (message["content"] as? [[String: Any]]) ?? []

            if role == "assistant" {
                let text = blocks
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined()
                let toolCalls: [[String: Any]] = blocks
                    .filter { $0["type"] as? String == "tool_use" }
                    .map { block in
                        let input = block["input"] as? [String: Any] ?? [:]
                        let arguments = (try? JSONSerialization.data(withJSONObject: input))
                            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                        return [
                            "id": block["id"] as? String ?? "",
                            "type": "function",
                            "function": [
                                "name": block["name"] as? String ?? "",
                                "arguments": arguments,
                            ],
                        ]
                    }
                var assistant: [String: Any] = ["role": "assistant", "content": text]
                if !toolCalls.isEmpty { assistant["tool_calls"] = toolCalls }
                result.append(assistant)
                continue
            }

            // user 消息里的 tool_result:OpenAI 每条结果是一条独立的 role=tool 消息
            var pendingText = ""
            for block in blocks {
                switch block["type"] as? String {
                case "tool_result":
                    result.append([
                        "role": "tool",
                        "tool_call_id": block["tool_use_id"] as? String ?? "",
                        "content": block["content"] as? String ?? "",
                    ])
                case "text":
                    pendingText += block["text"] as? String ?? ""
                default:
                    break
                }
            }
            if !pendingText.isEmpty {
                result.append(["role": "user", "content": pendingText])
            }
        }
        return result
    }

    private static func errorMessage(status: Int, body: String) -> String {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = object["message"] as? String { return message }
        }
        switch status {
        case 401: return String(localized: "API Key 无效或已失效,请在设置中检查。")
        case 404: return String(localized: "接口地址不存在。若网关只支持某一种格式,请在设置里切换接口格式。")
        case 429: return String(localized: "请求过于频繁,请稍后重试。")
        default: return String(localized: "AI 请求失败(HTTP \(String(status)))")
        }
    }
}
