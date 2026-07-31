import XCTest
@testable import Berth

final class AIProviderTests: XCTestCase {

    /// 预设是设置页下拉的数据源:id 唯一、都有模型可选、地址合法
    func testPresetsAreWellFormed() {
        let ids = AIProvider.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "供应商 id 不能重复")
        XCTAssertFalse(ids.contains(AIProvider.customID), "「自定义」不该混进预设列表")
        for provider in AIProvider.all {
            XCTAssertFalse(provider.models.isEmpty, "\(provider.id) 缺常见模型")
            XCTAssertEqual(provider.defaultModel, provider.models[0])
            XCTAssertFalse(provider.models.contains(AIProvider.customModelTag))
            let url = URL(string: provider.baseURL)
            XCTAssertNotNil(url?.scheme, "\(provider.id) 地址不合法")
            XCTAssertNotNil(URL(string: provider.docsURL)?.scheme, "\(provider.id) 文档链接不合法")
        }
    }

    /// 每个预设拼出来的接口地址必须是各家文档里那一条(2026-07-31 以无 key 请求逐个探过:
    /// 全部返回 401/400 而非 404)。智谱不在 /v1 下、Groq/OpenRouter 带前缀,最容易拼错。
    func testPresetEndpointsMatchProviderDocs() {
        let expected: [String: String] = [
            "anthropic": "https://api.anthropic.com/v1/messages",
            "openai": "https://api.openai.com/v1/chat/completions",
            "deepseek": "https://api.deepseek.com/v1/chat/completions",
            "moonshot": "https://api.moonshot.cn/v1/chat/completions",
            "moonshot-intl": "https://api.moonshot.ai/v1/chat/completions",
            "zhipu": "https://open.bigmodel.cn/api/paas/v4/chat/completions",
            "dashscope": "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
            "siliconflow": "https://api.siliconflow.cn/v1/chat/completions",
            "openrouter": "https://openrouter.ai/api/v1/chat/completions",
            "groq": "https://api.groq.com/openai/v1/chat/completions",
            "xai": "https://api.x.ai/v1/chat/completions",
            "ollama": "http://127.0.0.1:11434/v1/chat/completions",
            "lmstudio": "http://127.0.0.1:1234/v1/chat/completions",
            "mistral": "https://api.mistral.ai/v1/chat/completions",
            "gemini": "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            "cerebras": "https://api.cerebras.ai/v1/chat/completions",
            "ark": "https://ark.cn-beijing.volces.com/api/v3/chat/completions",
            "aihubmix": "https://aihubmix.com/v1/chat/completions",
            "302ai": "https://api.302.ai/v1/chat/completions",
            "together": "https://api.together.xyz/v1/chat/completions",
            "deepinfra": "https://api.deepinfra.com/v1/openai/chat/completions",
            "novita": "https://api.novita.ai/v3/openai/chat/completions",
        ]
        for provider in AIProvider.all {
            let config = AIClientConfig(apiKey: "k", baseURL: URL(string: provider.baseURL)!, model: "m")
            let path = provider.format == .anthropic ? "/messages" : "/chat/completions"
            XCTAssertEqual(
                config.endpoint(path: path).absoluteString,
                expected[provider.id],
                "\(provider.id) 的接口地址拼错了"
            )
        }
    }

    /// 设置页靠地址反查选中项;Anthropic 走原生格式,其余走 OpenAI 兼容
    func testMatchingByBaseURL() {
        XCTAssertEqual(AIProvider.matching(baseURL: "https://api.deepseek.com")?.id, "deepseek")
        XCTAssertEqual(AIProvider.matching(baseURL: "https://api.deepseek.com/")?.id, "deepseek")
        XCTAssertEqual(AIProvider.matching(baseURL: "")?.id, "anthropic", "空地址按默认 Anthropic 处理")
        XCTAssertNil(AIProvider.matching(baseURL: "https://my-relay.example.com"), "未知地址落到「自定义」")
        XCTAssertEqual(AIProvider.find("anthropic")?.format, .anthropic)
        for provider in AIProvider.all where provider.id != "anthropic" {
            XCTAssertEqual(provider.format, .openAI, "\(provider.id) 应走 OpenAI 兼容")
        }
    }
}
