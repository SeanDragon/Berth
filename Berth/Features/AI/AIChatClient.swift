import Foundation

/// AI 对话后端的统一接口。对话历史一律用 Anthropic 的 content-block 形状表达
/// (text / tool_use / tool_result),OpenAI 兼容后端在自己内部做双向翻译,
/// 这样 AIChatController 不必关心接的是哪种网关。
protocol AIChatClient: Sendable {
    /// 一轮请求的最终结果:assistant 消息的 content 块(原样回传下一轮)+ 停止原因
    typealias Turn = AIChatTurn

    func complete(
        system: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        onTextDelta: @escaping (String) -> Void
    ) async throws -> Turn
}

struct AIChatTurn {
    var content: [[String: Any]]
    /// "tool_use" / "end_turn" / "max_tokens" / "refusal"
    var stopReason: String?
}

struct AIChatError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 两种后端共用的接入点配置
struct AIClientConfig {
    var apiKey: String
    var baseURL: URL
    var model: String

    /// 拼接接口路径。路径里任一段是版本号(`…/v1`、GLM 的 `/api/paas/v4`、DeepInfra 的
    /// `/v1/openai`、Gemini 的 `/v1beta/openai`、方舟的 `/api/v3`)就视为完整 API 根,
    /// 按原样接;否则补 `/v1` —— 裸域名如此,Groq 的 `/openai`、OpenRouter 的 `/api`
    /// 这种「有路径但没版本号」的前缀也如此。
    func endpoint(path: String) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let pathComponents = (URL(string: base)?.path ?? "").split(separator: "/")
        let isVersioned = pathComponents.contains {
            $0.range(of: #"^v\d+[a-z]*$"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return URL(string: base + (isVersioned ? path : "/v1" + path)) ?? baseURL
    }
}
