import Foundation

/// Anthropic Messages API 极简客户端:URLSession + SSE 流式,无 SDK 依赖。
/// 只覆盖 AI 助手所需的单轮流式请求(含工具定义);对话循环由 AIChatController 驱动。
struct AnthropicClient: AIChatClient {
    typealias Config = AIClientConfig

    let config: Config

    /// 发送一次流式请求。`onTextDelta` 在正文文本增量到达时回调(调用方负责切主线程)。
    func complete(
        system: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        onTextDelta: @escaping (String) -> Void
    ) async throws -> Turn {
        var request = URLRequest(url: config.endpoint(path: "/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 64000,
            "stream": true,
            "system": system,
            "messages": messages,
            "tools": tools,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIChatError(message: String(localized: "无效的服务器响应"))
        }
        guard http.statusCode == 200 else {
            var payload = ""
            for try await line in bytes.lines { payload += line }
            throw AIChatError(message: Self.errorMessage(status: http.statusCode, body: payload))
        }

        // SSE 解析:按 index 累积 content 块,text/thinking/signature 追加,tool_use 输入拼 partial_json
        var blocks: [Int: [String: Any]] = [:]
        var partialJSON: [Int: String] = [:]
        var stopReason: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let json = String(line.dropFirst(6))
            guard let data = json.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "content_block_start":
                guard let index = event["index"] as? Int,
                      let block = event["content_block"] as? [String: Any] else { continue }
                blocks[index] = block
                if block["type"] as? String == "tool_use" { partialJSON[index] = "" }

            case "content_block_delta":
                guard let index = event["index"] as? Int,
                      let delta = event["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { continue }
                guard var block = blocks[index] else { continue }
                switch deltaType {
                case "text_delta":
                    if let text = delta["text"] as? String {
                        block["text"] = ((block["text"] as? String) ?? "") + text
                        onTextDelta(text)
                    }
                case "thinking_delta":
                    if let text = delta["thinking"] as? String {
                        block["thinking"] = ((block["thinking"] as? String) ?? "") + text
                    }
                case "signature_delta":
                    if let sig = delta["signature"] as? String {
                        block["signature"] = ((block["signature"] as? String) ?? "") + sig
                    }
                case "input_json_delta":
                    if let part = delta["partial_json"] as? String {
                        partialJSON[index, default: ""] += part
                    }
                default:
                    break
                }
                blocks[index] = block

            case "content_block_stop":
                guard let index = event["index"] as? Int else { continue }
                if let raw = partialJSON[index] {
                    let parsed = raw.data(using: .utf8)
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    blocks[index]?["input"] = parsed ?? [:]
                }

            case "message_delta":
                if let delta = event["delta"] as? [String: Any],
                   let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }

            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String
                throw AIChatError(message: message ?? String(localized: "AI 服务返回错误"))

            default:
                break
            }
        }

        let content = blocks.keys.sorted().compactMap { blocks[$0] }
        return Turn(content: content, stopReason: stopReason)
    }


    private static func errorMessage(status: Int, body: String) -> String {
        if let data = body.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        switch status {
        case 401: return String(localized: "API Key 无效或已失效,请在设置中检查。")
        case 404: return String(localized: "模型或接口地址不存在,请在设置中检查模型名与 API 地址。")
        case 429: return String(localized: "请求过于频繁,请稍后重试。")
        default: return String(localized: "AI 请求失败(HTTP \(String(status)))")
        }
    }
}
