import Network
import XCTest
@testable import Berth

/// AnthropicClient 的 SSE 解析与请求组装:用本地 mock HTTP 服务喂一段与真实
/// Messages API 同形状的流,验证文本增量、tool_use 输入拼装、错误处理。
final class AnthropicClientTests: XCTestCase {

    func testStreamingTextAndToolUse() async throws {
        let sse = """
        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"我看一下"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"磁盘。"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"run_command","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"command\\":"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"df -h /\\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        let server = try MockHTTPServer(status: 200, body: sse)
        defer { server.stop() }

        let client = AnthropicClient(config: .init(apiKey: "test", baseURL: server.baseURL, model: "m"))
        var streamed = ""
        let turn = try await client.complete(
            system: "sys",
            messages: [["role": "user", "content": "磁盘还剩多少"]],
            tools: [],
            onTextDelta: { streamed += $0 }
        )

        XCTAssertEqual(streamed, "我看一下磁盘。")
        XCTAssertEqual(turn.stopReason, "tool_use")
        XCTAssertEqual(turn.content.count, 2)
        XCTAssertEqual(turn.content[0]["type"] as? String, "text")
        XCTAssertEqual(turn.content[0]["text"] as? String, "我看一下磁盘。")
        XCTAssertEqual(turn.content[1]["type"] as? String, "tool_use")
        XCTAssertEqual(turn.content[1]["id"] as? String, "toolu_1")
        // 分片到达的 input_json_delta 拼回完整 JSON 对象
        XCTAssertEqual((turn.content[1]["input"] as? [String: Any])?["command"] as? String, "df -h /")

        // 请求体带上模型、流式开关、system 与工具定义
        let sent = try XCTUnwrap(server.lastRequestJSON)
        XCTAssertEqual(sent["model"] as? String, "m")
        XCTAssertEqual(sent["stream"] as? Bool, true)
        XCTAssertEqual(sent["system"] as? String, "sys")
        XCTAssertEqual(server.lastRequestPath, "/v1/messages")
    }

    /// HTTP 错误按服务端 message 抛出,便于面板直接展示
    func testAPIErrorSurfacesServerMessage() async throws {
        let body = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        let server = try MockHTTPServer(status: 401, body: body)
        defer { server.stop() }

        let client = AnthropicClient(config: .init(apiKey: "bad", baseURL: server.baseURL, model: "m"))
        do {
            _ = try await client.complete(system: "", messages: [], tools: [], onTextDelta: { _ in })
            XCTFail("应当抛出错误")
        } catch {
            XCTAssertEqual(error.localizedDescription, "invalid x-api-key")
        }
    }

    /// 自建中转地址常带 /v1 后缀,不应拼成 /v1/v1/messages
    func testBaseURLWithV1SuffixIsNotDoubled() async throws {
        let server = try MockHTTPServer(status: 200, body: "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
        defer { server.stop() }

        let base = server.baseURL.appendingPathComponent("v1")
        let client = AnthropicClient(config: .init(apiKey: "test", baseURL: base, model: "m"))
        _ = try await client.complete(system: "", messages: [], tools: [], onTextDelta: { _ in })
        XCTAssertEqual(server.lastRequestPath, "/v1/messages")
    }

    /// 末段是版本号就按原样接(智谱 /api/paas/v4、百炼 /compatible-mode/v1);
    /// 否则一律补 /v1 —— 裸域名、以及 Groq /openai、OpenRouter /api 这种无版本号前缀
    func testEndpointAppendsV1UnlessAlreadyVersioned() {
        func path(_ base: String) -> String {
            let config = AIClientConfig(apiKey: "k", baseURL: URL(string: base)!, model: "m")
            return config.endpoint(path: "/chat/completions").path
        }
        XCTAssertEqual(path("https://api.openai.com"), "/v1/chat/completions")
        XCTAssertEqual(path("https://api.openai.com/"), "/v1/chat/completions")
        XCTAssertEqual(path("https://open.bigmodel.cn/api/paas/v4"), "/api/paas/v4/chat/completions")
        XCTAssertEqual(path("https://dashscope.aliyuncs.com/compatible-mode/v1"), "/compatible-mode/v1/chat/completions")
        XCTAssertEqual(path("https://api.groq.com/openai"), "/openai/v1/chat/completions")
        XCTAssertEqual(path("https://openrouter.ai/api"), "/api/v1/chat/completions")
        XCTAssertEqual(path("https://relay.example.com/anthropic"), "/anthropic/v1/chat/completions")
    }
}

/// OpenAI 兼容后端:SSE 解析 + 与 Anthropic content-block 历史的双向翻译。
final class OpenAICompatibleClientTests: XCTestCase {

    func testStreamingTextAndToolCall() async throws {
        let sse = """
        data: {"choices":[{"delta":{"content":"我看一下"},"index":0}]}

        data: {"choices":[{"delta":{"content":"磁盘。"},"index":0}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_9","type":"function","function":{"name":"run_command","arguments":"{\\"command\\":"}}]},"index":0}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"df -h /\\"}"}}]},"index":0}]}

        data: {"choices":[{"delta":{},"finish_reason":"tool_calls","index":0}]}

        data: [DONE]

        """
        let server = try MockHTTPServer(status: 200, body: sse)
        defer { server.stop() }

        let client = OpenAICompatibleClient(config: .init(apiKey: "k", baseURL: server.baseURL, model: "gpt-x"))
        var streamed = ""
        let turn = try await client.complete(
            system: "sys",
            messages: [["role": "user", "content": "磁盘还剩多少"]],
            tools: [[
                "name": "run_command",
                "description": "run it",
                "input_schema": ["type": "object", "properties": [String: Any]()],
            ]],
            onTextDelta: { streamed += $0 }
        )

        XCTAssertEqual(streamed, "我看一下磁盘。")
        XCTAssertEqual(turn.stopReason, "tool_use")
        XCTAssertEqual(turn.content.count, 2)
        XCTAssertEqual(turn.content[1]["type"] as? String, "tool_use")
        XCTAssertEqual(turn.content[1]["id"] as? String, "call_9")
        XCTAssertEqual((turn.content[1]["input"] as? [String: Any])?["command"] as? String, "df -h /")

        // 工具定义翻译成 OpenAI 的 function 形状
        let sent = try XCTUnwrap(server.lastRequestJSON)
        XCTAssertEqual(server.lastRequestPath, "/v1/chat/completions")
        let function = ((sent["tools"] as? [[String: Any]])?.first)?["function"] as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, "run_command")
        XCTAssertNotNil(function?["parameters"])
        // system 走 messages 的第一条
        XCTAssertEqual((sent["messages"] as? [[String: Any]])?.first?["content"] as? String, "sys")
    }

    /// Anthropic 形状的历史(assistant 的 tool_use + user 里的 tool_result)翻译成 OpenAI 的
    /// assistant.tool_calls + role=tool 消息,否则多轮工具调用会对不上号。
    func testHistoryTranslation() throws {
        let history: [[String: Any]] = [
            ["role": "user", "content": "看看磁盘"],
            ["role": "assistant", "content": [
                ["type": "text", "text": "好的"],
                ["type": "tool_use", "id": "call_1", "name": "run_command", "input": ["command": "df -h"]],
            ]],
            ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "call_1", "content": "80% used"],
            ]],
        ]
        let converted = OpenAICompatibleClient.openAIMessages(system: "sys", messages: history)

        XCTAssertEqual(converted.count, 4)
        XCTAssertEqual(converted[0]["role"] as? String, "system")
        XCTAssertEqual(converted[1]["role"] as? String, "user")
        XCTAssertEqual(converted[2]["role"] as? String, "assistant")
        XCTAssertEqual(converted[2]["content"] as? String, "好的")
        let call = (converted[2]["tool_calls"] as? [[String: Any]])?.first
        XCTAssertEqual(call?["id"] as? String, "call_1")
        XCTAssertEqual((call?["function"] as? [String: Any])?["name"] as? String, "run_command")
        XCTAssertEqual(converted[3]["role"] as? String, "tool")
        XCTAssertEqual(converted[3]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(converted[3]["content"] as? String, "80% used")
    }

    /// 网关的错误信息要原样透出(如“This group does not allow /v1/messages dispatch”)
    func testGatewayErrorSurfaces() async throws {
        let body = #"{"error":{"message":"This group does not allow /v1/messages dispatch","type":"invalid_request_error"}}"#
        let server = try MockHTTPServer(status: 403, body: body)
        defer { server.stop() }

        let client = OpenAICompatibleClient(config: .init(apiKey: "k", baseURL: server.baseURL, model: "m"))
        do {
            _ = try await client.complete(system: "", messages: [], tools: [], onTextDelta: { _ in })
            XCTFail("应当抛出错误")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This group does not allow /v1/messages dispatch")
        }
    }
}

/// 极简单连接 HTTP 服务:收一次请求,回固定状态码与响应体。
final class MockHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "mock.http")
    private let lock = NSLock()
    private var _lastRequestBody = Data()
    private var _lastRequestPath = ""

    var baseURL: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }

    var lastRequestPath: String {
        lock.lock(); defer { lock.unlock() }
        return _lastRequestPath
    }

    var lastRequestJSON: [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return try? JSONSerialization.jsonObject(with: _lastRequestBody) as? [String: Any]
    }

    init(status: Int, body: String) throws {
        // 显式绑 127.0.0.1:随机端口 —— 绑 .any 时连回环会 EADDRNOTAVAIL
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data(), status: status, body: body)
        }
        // 必须等到 ready 才拿得到真实端口(此前 listener.port 是 0)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port, port.rawValue != 0 else {
            throw NWError.posix(.EADDRNOTAVAIL)
        }
    }

    func stop() { listener.cancel() }

    /// 读到 header 结束后按 Content-Length 收完 body,再回响应
    private func receive(on connection: NWConnection, buffer: Data, status: Int, body: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if !isComplete { self.receive(on: connection, buffer: buffer, status: status, body: body) }
                return
            }
            let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            let contentLength = header
                .components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let bodyData = buffer[headerEnd.upperBound...]
            guard bodyData.count >= contentLength else {
                if !isComplete { self.receive(on: connection, buffer: buffer, status: status, body: body) }
                return
            }

            self.lock.lock()
            self._lastRequestBody = Data(bodyData.prefix(contentLength))
            self._lastRequestPath = header
                .components(separatedBy: "\r\n").first?
                .split(separator: " ").dropFirst().first.map(String.init) ?? ""
            self.lock.unlock()

            let payload = Data(body.utf8)
            let response = "HTTP/1.1 \(status) OK\r\nContent-Type: text/event-stream\r\nContent-Length: \(payload.count)\r\n\r\n"
            connection.send(content: Data(response.utf8) + payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
