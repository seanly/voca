import Foundation

/// Represents a single LLM configuration
struct LLMModel: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var apiBaseURL: String
    var apiKey: String
    var model: String
    var isEnabled: Bool
    
    init(
        id: UUID = UUID(),
        name: String,
        apiBaseURL: String,
        apiKey: String = "",
        model: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.apiBaseURL = apiBaseURL
        self.apiKey = apiKey
        self.model = model
        self.isEnabled = isEnabled
    }
    
    var isConfigured: Bool { !apiKey.isEmpty }
}

// MARK: - Presets

extension LLMModel {
    /// Built-in presets for common LLM providers
    static let presets: [LLMModel] = [
        LLMModel(
            name: "OpenAI GPT-4o",
            apiBaseURL: "https://api.openai.com/v1",
            model: "gpt-4o"
        ),
        LLMModel(
            name: "OpenAI GPT-4o-mini",
            apiBaseURL: "https://api.openai.com/v1",
            model: "gpt-4o-mini"
        ),
        LLMModel(
            name: "DeepSeek Chat",
            apiBaseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat"
        ),
        LLMModel(
            name: "SiliconFlow Qwen",
            apiBaseURL: "https://api.siliconflow.cn/v1",
            model: "Qwen/Qwen2.5-72B-Instruct"
        )
    ]
    
    static let `default` = presets[1] // GPT-4o-mini as default
}
