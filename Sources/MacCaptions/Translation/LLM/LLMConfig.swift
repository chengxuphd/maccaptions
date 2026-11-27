import Foundation

/// Where an LLM request goes. Every preset speaks the OpenAI-compatible Chat Completions API; what differs is the
/// address, the name of the output-length field, and how "thinking" is switched off.
enum LLMProvider: String, CaseIterable, Identifiable, Codable {
    case ollama, lmstudio, llamacpp, openrouter, tinker, openai, deepseek, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .ollama: "Ollama (local)"
        case .lmstudio: "LM Studio (local)"
        case .llamacpp: "llama.cpp server (local)"
        case .openrouter: "OpenRouter"
        case .tinker: "Tinker (Thinking Machines)"
        case .openai: "OpenAI"
        case .deepseek: "DeepSeek"
        case .custom: "Custom (OpenAI-compatible)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .ollama: "http://127.0.0.1:11434/v1"
        case .lmstudio: "http://127.0.0.1:1234/v1"
        case .llamacpp: "http://127.0.0.1:9931/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .tinker: "https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1"
        case .openai: "https://api.openai.com/v1"
        case .deepseek: "https://api.deepseek.com"
        case .custom: ""
        }
    }

    /// A small, cheap model that was tested (November 2026), where there is one.
    var defaultModel: String {
        switch self {
        case .ollama: "qwen3.5:4b"
        case .openrouter: "qwen/qwen3.7-flash"
        case .tinker: "Qwen/Qwen3.5-9B"
        default: ""
        }
    }

    var modelHint: String {
        switch self {
        case .ollama: "e.g. qwen3.5:4b"
        case .lmstudio: "the model ID LM Studio shows"
        case .llamacpp: "any name (the server uses the model it loaded)"
        case .openrouter: "e.g. vendor/model-name"
        case .tinker: "e.g. Qwen/Qwen3.5-4B or tinker://…"
        case .openai, .deepseek, .custom: "model name"
        }
    }

    var needsAPIKey: Bool {
        switch self {
        case .openrouter, .tinker, .openai, .deepseek: true
        case .ollama, .lmstudio, .llamacpp, .custom: false
        }
    }

    var help: String {
        switch self {
        case .ollama: "Install Ollama, then run: ollama pull qwen3.5:4b (or qwen3.5:9b: better translations, needs more memory)"
        case .lmstudio: "In LM Studio, load a model and start the local server. If the model keeps “thinking”, turn that off in LM Studio."
        case .llamacpp: "Start llama-server with a GGUF model. Use the port it prints when it starts."
        case .openrouter: "Create an API key on openrouter.ai. “List models” shows what you can use."
        case .tinker: "Tinker's OpenAI-compatible API is in beta. Copy the exact model ID from Tinker's documentation. Pick a model whose thinking can be switched off (Qwen3.5 can; Inkling cannot)."
        case .openai, .deepseek: "Create an API key in the provider's console."
        case .custom: "Any server with an OpenAI-compatible /chat/completions endpoint. Enter the address that ends in /v1."
        }
    }

    /// Name of the "maximum output length" field this service reads.
    var tokenLimitField: String {
        switch self {
        case .tinker, .openai: "max_completion_tokens"
        default: "max_tokens"
        }
    }

    /// Some current OpenAI models reject a temperature value, so none is sent there.
    var sendsTemperature: Bool { self != .openai }

    /// Extra request fields that turn off reasoning, which is far too slow for live captions (and billed).
    /// If a server refuses the first form by name, the next one is tried before the setting is given up.
    var thinkingOffChoices: [[String: Any]] {
        switch self {
        case .ollama, .openai: [["reasoning_effort": "none"]]
        // Tinker: its Qwen models take only false ("none" is refused); Inkling takes "none" but not false.
        case .tinker: [["reasoning_effort": false], ["reasoning_effort": "none"]]
        case .lmstudio, .llamacpp: [["chat_template_kwargs": ["enable_thinking": false]]]
        case .openrouter: [["reasoning": ["effort": "none"]]]
        case .deepseek: [["thinking": ["type": "disabled"]]]
        case .custom: []
        }
    }
}

enum PromptStyle: String, CaseIterable, Identifiable, Codable {
    case auto, chat, hyMT
    var id: String { rawValue }
    var label: String {
        switch self { case .auto: "Automatic"; case .chat: "General model"; case .hyMT: "Hy-MT translation model" }
    }
    func resolved(for model: String) -> PromptStyle {
        guard self == .auto else { return self }
        let m = model.lowercased()
        return ["hy-mt", "hunyuan-mt", "hymt"].contains(where: m.contains) ? .hyMT : .chat
    }
}

/// Settings kept separately for each provider, so switching back and forth loses nothing. API keys are NOT here.
struct LLMProfile: Codable, Equatable {
    var baseURL: String
    var model: String
    var promptStyle: PromptStyle = .auto
    var disableThinking = true
    var extraJSON = ""            // merged into the request body; a null value removes a field

    static func defaults(for p: LLMProvider) -> LLMProfile { LLMProfile(baseURL: p.defaultBaseURL, model: p.defaultModel) }
}

/// Everything one request needs, captured at one moment (settings can change while a session is running).
struct LLMConfig: Equatable {
    var provider: LLMProvider
    var profile: LLMProfile
    var contextCount = 3
    var timeout: Double = 8
    var topic = ""
    var glossary = ""

    /// Live translation sends about one request per second of speech: only for a model on this Mac or the local network.
    var allowsLiveTranslation: Bool {
        (try? LLMEndpoint.parse(profile.baseURL)).map { $0.scope != .internet } ?? false
    }

    /// Where a request goes and which model reads it.
    var destinationID: String { "\(provider.rawValue)|\(profile.baseURL)|\(profile.model)" }

    /// Saved with every sentence, so a transcript always says which engine produced its translation.
    var engineID: String { "llm:\(provider.rawValue)/\(profile.model)" }
}
