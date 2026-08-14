import Foundation

/// 供应商预设:选一个就填好接口地址、请求格式与常见模型列表,之后都能手改。
/// 绝大多数厂商与中转都兼容 OpenAI 的 /chat/completions,所以只需两种请求格式。
///
/// ⚠️ 模型迭代很快,而且各家越来越少提供「永不过期的别名」(Kimi 停了 kimi-latest,
/// DeepSeek 停了 deepseek-chat/reasoner)。所以模型字段始终允许手填,这里只是常见项;
/// 列表核对于 2026-07-31,过期了照着各家文档改即可。
struct AIProvider: Identifiable, Hashable {
    let id: String
    let name: String
    let baseURL: String
    let format: AISettings.APIFormat
    /// 常见模型(下拉直选);冷门型号在设置里选「自定义…」手填。只收支持工具调用的型号。
    let models: [String]
    /// 申请/查文档的入口,设置页给个链接
    let docsURL: String

    /// 新选中该供应商时预填的模型
    var defaultModel: String { models.first ?? "" }

    static var all: [AIProvider] { vendors + aggregators + local }

    /// 官方 / 云厂商
    static let vendors: [AIProvider] = [
        AIProvider(
            id: "anthropic", name: "Anthropic (Claude)",
            baseURL: "https://api.anthropic.com", format: .anthropic,
            models: ["claude-opus-5", "claude-fable-5", "claude-sonnet-5", "claude-haiku-4-5", "claude-opus-4-8"],
            docsURL: "https://platform.claude.com/docs/en/about-claude/models/overview"
        ),
        AIProvider(
            id: "openai", name: "OpenAI",
            baseURL: "https://api.openai.com", format: .openAI,
            models: ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-4.1", "gpt-4o"],
            docsURL: "https://developers.openai.com/api/docs/models"
        ),
        AIProvider(
            id: "deepseek", name: "DeepSeek 深度求索",
            baseURL: "https://api.deepseek.com", format: .openAI,
            models: ["deepseek-v4-flash", "deepseek-v4-pro"],
            docsURL: "https://api-docs.deepseek.com/zh-cn/quick_start/pricing"
        ),
        AIProvider(
            id: "moonshot", name: "Kimi(月之暗面)",
            baseURL: "https://api.moonshot.cn", format: .openAI,
            models: ["kimi-k3", "kimi-k2.7-code", "kimi-k2.7-code-highspeed", "kimi-k2.6"],
            docsURL: "https://platform.kimi.com/docs/models"
        ),
        AIProvider(
            id: "moonshot-intl", name: "Kimi(国际站)",
            baseURL: "https://api.moonshot.ai", format: .openAI,
            models: ["kimi-k3", "kimi-k2.7-code", "kimi-k2.7-code-highspeed", "kimi-k2.6"],
            docsURL: "https://platform.kimi.ai/docs/api/overview"
        ),
        AIProvider(
            id: "zhipu", name: "智谱 GLM",
            baseURL: "https://open.bigmodel.cn/api/paas/v4", format: .openAI,
            models: ["glm-4.7", "glm-5", "glm-5.2", "glm-5-turbo", "glm-4.7-flash"],
            docsURL: "https://docs.bigmodel.cn/cn/guide/start/model-overview"
        ),
        AIProvider(
            id: "dashscope", name: "阿里云百炼 (通义千问)",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", format: .openAI,
            models: ["qwen3.7-plus", "qwen3.7-max", "qwen3.7-flash", "qwen3.6-flash"],
            docsURL: "https://help.aliyun.com/zh/model-studio/models"
        ),
        AIProvider(
            id: "siliconflow", name: "硅基流动 SiliconFlow",
            baseURL: "https://api.siliconflow.cn", format: .openAI,
            models: [
                "deepseek-ai/DeepSeek-V4-Pro", "deepseek-ai/DeepSeek-V4-Flash",
                "moonshotai/Kimi-K3", "zai-org/GLM-5.2", "Qwen/Qwen3.5-397B-A17B",
            ],
            docsURL: "https://www.siliconflow.com/models"
        ),
        AIProvider(
            id: "groq", name: "Groq",
            baseURL: "https://api.groq.com/openai", format: .openAI,
            models: ["openai/gpt-oss-120b", "openai/gpt-oss-20b", "qwen/qwen3.6-27b"],
            docsURL: "https://console.groq.com/docs/models"
        ),
        AIProvider(
            id: "fireworks", name: "Fireworks AI",
            baseURL: "https://api.fireworks.ai/inference/v1", format: .openAI,
            models: [
                "accounts/fireworks/models/glm-5p2",
                "accounts/fireworks/models/kimi-k2p7-code",
                "accounts/fireworks/models/deepseek-v4-pro",
                "accounts/fireworks/models/minimax-m3",
                "accounts/fireworks/models/kimi-k2p6",
            ],
            docsURL: "https://fireworks.ai/models"
        ),
        AIProvider(
            id: "xai", name: "xAI (Grok)",
            baseURL: "https://api.x.ai", format: .openAI,
            models: ["grok-4.5", "grok-4.3", "grok-build-0.1"],
            docsURL: "https://docs.x.ai/docs/models"
        ),
        AIProvider(
            id: "mistral", name: "Mistral AI",
            baseURL: "https://api.mistral.ai", format: .openAI,
            models: ["mistral-large-latest", "mistral-medium-latest", "mistral-small-latest", "codestral-latest"],
            docsURL: "https://docs.mistral.ai/getting-started/models/models_overview/"
        ),
        AIProvider(
            id: "gemini", name: "Google Gemini",
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", format: .openAI,
            models: ["gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.5-flash-lite", "gemini-2.5-pro"],
            docsURL: "https://ai.google.dev/gemini-api/docs/models"
        ),
        AIProvider(
            id: "cerebras", name: "Cerebras",
            baseURL: "https://api.cerebras.ai", format: .openAI,
            models: ["gpt-oss-120b", "gemma-4-31b"],
            docsURL: "https://inference-docs.cerebras.ai/models/overview"
        ),
        AIProvider(
            id: "ark", name: "火山方舟(豆包)",
            baseURL: "https://ark.cn-beijing.volces.com/api/v3", format: .openAI,
            models: ["doubao-seed-2-1-pro-260628", "doubao-seed-2-1-turbo-260628", "doubao-seed-2-0-pro-260215", "doubao-seed-1-6-251015"],
            docsURL: "https://www.volcengine.com/docs/82379/1330310"
        ),
    ]

    /// 聚合与中转(模型 ID 命名各家不同:AiHubMix/302.AI 直用上游原名;
    /// Together/DeepInfra 用 org/Model 大写混排;Novita 全小写 —— 不可互换)
    static let aggregators: [AIProvider] = [
        AIProvider(
            id: "openrouter", name: "OpenRouter",
            baseURL: "https://openrouter.ai/api", format: .openAI,
            models: [
                "anthropic/claude-opus-5", "openai/gpt-5.6-sol", "x-ai/grok-4.5",
                "google/gemini-3.6-flash", "deepseek/deepseek-v4-pro", "moonshotai/kimi-k3",
            ],
            docsURL: "https://openrouter.ai/models"
        ),
        AIProvider(
            id: "aihubmix", name: "AiHubMix(中转)",
            baseURL: "https://aihubmix.com", format: .openAI,
            models: ["gemini-3.6-flash", "claude-opus-5", "gpt-5.6-sol", "glm-5.2"],
            docsURL: "https://aihubmix.com/models"
        ),
        AIProvider(
            id: "302ai", name: "302.AI(中转)",
            baseURL: "https://api.302.ai", format: .openAI,
            models: ["gemini-3.6-flash", "claude-opus-5", "gpt-5.6-sol", "glm-5.2", "kimi-k3"],
            docsURL: "https://302.ai/pricing/"
        ),
        AIProvider(
            id: "together", name: "Together AI",
            baseURL: "https://api.together.xyz", format: .openAI,
            models: ["zai-org/GLM-5.2", "moonshotai/Kimi-K2.6", "moonshotai/Kimi-K2.7-Code", "openai/gpt-oss-120b"],
            docsURL: "https://docs.together.ai/docs/serverless-models"
        ),
        AIProvider(
            id: "deepinfra", name: "DeepInfra",
            baseURL: "https://api.deepinfra.com/v1/openai", format: .openAI,
            models: ["zai-org/GLM-5.2", "deepseek-ai/DeepSeek-V4-Pro", "moonshotai/Kimi-K2.7-Code", "openai/gpt-oss-120b"],
            docsURL: "https://deepinfra.com/models/text-generation"
        ),
        AIProvider(
            id: "novita", name: "Novita AI",
            baseURL: "https://api.novita.ai/v3/openai", format: .openAI,
            models: ["zai-org/glm-5.2", "moonshotai/kimi-k3", "deepseek/deepseek-v4-pro", "deepseek/deepseek-v3.2"],
            docsURL: "https://novita.ai/models/llm"
        ),
    ]

    /// 本地推理(免 API Key)
    static let local: [AIProvider] = [
        AIProvider(
            id: "ollama", name: "Ollama(本地)",
            baseURL: "http://127.0.0.1:11434/v1", format: .openAI,
            models: ["qwen3.5:9b", "qwen3.5:27b", "qwen3-coder:30b", "gemma4:12b", "granite4.1:8b"],
            docsURL: "https://ollama.com/search?c=tools"
        ),
        AIProvider(
            id: "lmstudio", name: "LM Studio(本地)",
            baseURL: "http://127.0.0.1:1234/v1", format: .openAI,
            models: ["local-model"],
            docsURL: "https://lmstudio.ai/docs"
        ),
    ]

    static let customID = "custom"
    /// 模型下拉里代表「手动输入」的哨兵值
    static let customModelTag = "__berth_custom_model__"

    static func find(_ id: String) -> AIProvider? { all.first { $0.id == id } }

    /// 按当前地址反查预设(用于设置页选中态);对不上就是「自定义」
    static func matching(baseURL: String) -> AIProvider? {
        let normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalized.isEmpty else { return find("anthropic") }
        return all.first {
            $0.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == normalized
        }
    }
}
