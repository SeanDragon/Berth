import Foundation
import Observation

/// AI 助手配置:API Key 存钥匙串(随 iCloud 钥匙串同步),模型/地址/接口格式存 UserDefaults。
enum AISettings {
    static let defaultModel = "claude-opus-5"
    static let defaultBaseURL = "https://api.anthropic.com"

    /// 钥匙串账户名(命名约定与主机凭据一致)
    static let apiKeyAccount = "ai.anthropic.apiKey"

    /// 请求格式。中转网关常只放行其中一种(典型报错:This group does not allow /v1/messages dispatch)。
    enum APIFormat: String, CaseIterable, Identifiable {
        /// Anthropic 原生 /v1/messages
        case anthropic
        /// OpenAI 兼容 /v1/chat/completions(多数中转、以及 OpenAI/DeepSeek/Qwen 等)
        case openAI

        var id: String { rawValue }

        var label: String {
            switch self {
            case .anthropic: return String(localized: "Anthropic 原生")
            case .openAI: return String(localized: "OpenAI 兼容")
            }
        }
    }

    static var apiKey: String? {
        guard let key = try? KeychainStore.read(account: apiKeyAccount),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var model: String {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.aiModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? defaultModel : raw
    }

    static var baseURL: URL {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.aiBaseURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty, let url = URL(string: raw), url.scheme != nil {
            return url
        }
        return URL(string: defaultBaseURL)!
    }

    static var format: APIFormat {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.aiAPIFormat) ?? ""
        return APIFormat(rawValue: raw) ?? .anthropic
    }

    static var autoRunCommands: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.aiAutoRunCommands)
    }

    /// 本地推理(Ollama / LM Studio 等)不需要 Key
    static var isLocalEndpoint: Bool {
        let host = baseURL.host?.lowercased() ?? ""
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    static var isConfigured: Bool { apiKey != nil || isLocalEndpoint }

    /// 按当前接口格式造对应的客户端;未配置时返回 nil
    static func makeClient() -> AIChatClient? {
        guard isConfigured else { return nil }
        let config = AIClientConfig(apiKey: apiKey ?? "", baseURL: baseURL, model: model)
        switch format {
        case .anthropic: return AnthropicClient(config: config)
        case .openAI: return OpenAICompatibleClient(config: config)
        }
    }
}

/// 是否已配置好的可观察状态:设置页保存后即时刷新 AI 面板(两者在不同窗口,
/// 面板拿不到 @AppStorage 之外的 Keychain 变化)。
@MainActor
@Observable
final class AISettingsStore {
    static let shared = AISettingsStore()

    private(set) var isConfigured = AISettings.isConfigured

    func refresh() { isConfigured = AISettings.isConfigured }
}
