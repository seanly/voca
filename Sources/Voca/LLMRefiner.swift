import Foundation
import os.log

private let logger = Logger(subsystem: "com.yetone.Voca", category: "LLMRefiner")

private func logToFile(_ message: String) {
    let msg = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Voca.log")
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(msg.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logURL.path, contents: msg.data(using: .utf8))
    }
}

final class LLMRefiner {
    static let shared = LLMRefiner()
    
    // MARK: - UserDefaults Keys
    private enum Keys {
        static let models = "llmModels"
        static let selectedModelId = "selectedLLMModelId"
        static let prompts = "llmPrompts"
        static let selectedPromptId = "selectedLLMPromptId"
        // Legacy keys for migration
        static let legacyEnabled = "llmEnabled"
        static let legacyAPIBaseURL = "llmAPIBaseURL"
        static let legacyAPIKey = "llmAPIKey"
        static let legacyModel = "llmModel"
    }
    
    // MARK: - Properties

    /// All configured models
    var models: [LLMModel] {
        get {
            migrateLegacyConfigIfNeeded()
            guard let data = UserDefaults.standard.data(forKey: Keys.models),
                  let models = try? JSONDecoder().decode([LLMModel].self, from: data) else {
                return []
            }
            return models
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Keys.models)
            }
        }
    }
    
    /// Currently selected model ID
    var selectedModelId: UUID? {
        get {
            UserDefaults.standard.string(forKey: Keys.selectedModelId).flatMap(UUID.init)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: Keys.selectedModelId)
        }
    }
    
    /// Currently active model (selected and enabled, or first enabled as fallback)
    var currentModel: LLMModel? {
        let allModels = models
        guard !allModels.isEmpty else { return nil }

        // Only return selected model if enabled — no silent fallback
        if let selectedId = selectedModelId,
           let selected = allModels.first(where: { $0.id == selectedId && $0.isEnabled }) {
            return selected
        }

        return nil
    }
    
    /// All configured prompts
    var prompts: [Prompt] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Keys.prompts),
                  let prompts = try? JSONDecoder().decode([Prompt].self, from: data) else {
                // Return default preset on first launch
                return Prompt.presets
            }
            return prompts
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Keys.prompts)
            }
        }
    }
    
    /// Currently selected prompt ID
    var selectedPromptId: UUID? {
        get {
            UserDefaults.standard.string(forKey: Keys.selectedPromptId).flatMap(UUID.init)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: Keys.selectedPromptId)
        }
    }
    
    /// Currently active prompt
    var currentPrompt: Prompt? {
        let allPrompts = prompts
        guard !allPrompts.isEmpty else { return nil }
        
        // Try to use selected prompt if enabled
        if let selectedId = selectedPromptId,
           let selected = allPrompts.first(where: { $0.id == selectedId && $0.isEnabled }) {
            return selected
        }
        
        // Fallback to first enabled prompt
        return allPrompts.first { $0.isEnabled }
    }
    
    /// Current system prompt content
    var systemPrompt: String { currentPrompt?.content ?? Prompt.default.content }
    
    private var currentTask: URLSessionDataTask?
    
    // MARK: - Lifecycle
    
    private init() {
        migrateLegacyConfigIfNeeded()
    }
    
    // MARK: - Migration
    
    private var hasMigrated: Bool {
        UserDefaults.standard.bool(forKey: "llmMigrationCompleted")
    }
    
    private func migrateLegacyConfigIfNeeded() {
        guard !hasMigrated,
              UserDefaults.standard.object(forKey: Keys.legacyAPIKey) != nil,
              UserDefaults.standard.object(forKey: Keys.models) == nil else {
            return
        }
        
        // Create model from legacy config
        let legacyModel = LLMModel(
            name: "Default",
            apiBaseURL: UserDefaults.standard.string(forKey: Keys.legacyAPIBaseURL) ?? "https://api.openai.com/v1",
            apiKey: UserDefaults.standard.string(forKey: Keys.legacyAPIKey) ?? "",
            model: UserDefaults.standard.string(forKey: Keys.legacyModel) ?? "gpt-4o-mini",
            isEnabled: UserDefaults.standard.bool(forKey: Keys.legacyEnabled)
        )
        
        // Save as new format
        models = [legacyModel]
        selectedModelId = legacyModel.id
        
        // Mark migration complete
        UserDefaults.standard.set(true, forKey: "llmMigrationCompleted")
        logToFile("Migrated legacy LLM config to new format")
    }
    
    // MARK: - Model Management
    
    func addModel(_ model: LLMModel) {
        var allModels = models
        allModels.append(model)
        models = allModels
        
        // Auto-select if this is the first model
        if selectedModelId == nil {
            selectedModelId = model.id
        }
    }
    
    func updateModel(_ model: LLMModel) {
        var allModels = models
        if let index = allModels.firstIndex(where: { $0.id == model.id }) {
            allModels[index] = model
            models = allModels
        }
    }
    
    func removeModel(id: UUID) {
        var allModels = models
        allModels.removeAll { $0.id == id }
        models = allModels
        
        // Clear selection if removed model was selected
        if selectedModelId == id {
            selectedModelId = allModels.first { $0.isEnabled }?.id
        }
    }
    
    func selectModel(id: UUID) {
        guard models.contains(where: { $0.id == id }) else { return }
        selectedModelId = id
    }
    
    // MARK: - Prompt Management
    
    func addPrompt(_ prompt: Prompt) {
        var allPrompts = prompts
        allPrompts.append(prompt)
        prompts = allPrompts
        
        // Auto-select if this is the first prompt
        if selectedPromptId == nil {
            selectedPromptId = prompt.id
        }
    }
    
    func updatePrompt(_ prompt: Prompt) {
        var allPrompts = prompts
        if let index = allPrompts.firstIndex(where: { $0.id == prompt.id }) {
            allPrompts[index] = prompt
            prompts = allPrompts
        }
    }
    
    func removePrompt(id: UUID) {
        var allPrompts = prompts
        allPrompts.removeAll { $0.id == id }
        prompts = allPrompts
        
        // Clear selection if removed prompt was selected
        if selectedPromptId == id {
            selectedPromptId = allPrompts.first { $0.isEnabled }?.id
        }
    }
    
    func selectPrompt(id: UUID) {
        guard prompts.contains(where: { $0.id == id }) else { return }
        selectedPromptId = id
    }
    
    // MARK: - Refinement

    func refine(_ text: String, force: Bool = false, completion: @escaping (Result<String, Error>) -> Void) {
        guard let model = currentModel, (force || model.isConfigured) else {
            completion(.success(text))
            return
        }
        
        let baseURL = model.apiBaseURL.hasSuffix("/") ? String(model.apiBaseURL.dropLast()) : model.apiBaseURL
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            completion(.failure(RefinerError.invalidURL))
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(model.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        
        let body: [String: Any] = [
            "model": model.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            "temperature": 0.3,
        ]
        
        logToFile("Request: \(url.absoluteString) model=\(model.model)")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        currentTask = URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                logToFile("Network error: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let data else {
                logToFile("No data in response")
                DispatchQueue.main.async { completion(.failure(RefinerError.invalidResponse)) }
                return
            }
            if let raw = String(data: data, encoding: .utf8) {
                logToFile("Response: \(raw)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                logToFile("Failed to parse response")
                DispatchQueue.main.async { completion(.failure(RefinerError.invalidResponse)) }
                return
            }
            let refined = content.removingThinkTags().trimmingCharacters(in: .whitespacesAndNewlines)
            logToFile("Refined: '\(text)' -> '\(refined)'")
            DispatchQueue.main.async { completion(.success(refined)) }
        }
        currentTask?.resume()
    }
    
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }
    
    enum RefinerError: LocalizedError {
        case invalidURL
        case invalidResponse
        
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid API base URL"
            case .invalidResponse: return "Invalid response from LLM API"
            }
        }
    }
}

// MARK: - String Extensions

private extension String {
    /// Removes <think>...</think> tags and their content
    func removingThinkTags() -> String {
        // Pattern to match <think>...</think> (non-greedy match)
        guard let regex = try? NSRegularExpression(pattern: "<think>.*?</think>", options: [.dotMatchesLineSeparators]) else {
            return self
        }
        let range = NSRange(self.startIndex..., in: self)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: "")
    }
}
