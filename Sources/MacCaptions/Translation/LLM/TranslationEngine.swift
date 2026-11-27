import Foundation

/// A translation that is good enough to replace Apple's.
struct LLMResult: Equatable {
    var text: String
    var engineID: String
    var milliseconds: Int
}

/// One engine call. A protocol so the queue can be tested without a network, and so a future built-in model can
/// slot in next to the HTTP one.
protocol TranslationEngine: Sendable {
    var id: String { get }
    /// Returns a cleaned, validated translation, plus the tokens it cost (0 if unknown).
    func translate(_ request: TranslationRequest, timeout: TimeInterval) async throws -> (text: String, tokens: Int)
}

/// Any OpenAI-compatible Chat Completions server, local or cloud.
struct ChatCompletionsEngine: TranslationEngine {
    let config: LLMConfig
    let client: LLMClient
    /// Fetched per request, off the main thread (the Keychain may show a prompt).
    let apiKey: @Sendable () async throws -> String?

    var id: String { config.engineID }

    func translate(_ request: TranslationRequest, timeout: TimeInterval) async throws -> (text: String, tokens: Int) {
        let key = try await apiKey()
        try Task.checkCancellation()          // the job may have been given up while macOS showed a Keychain prompt
        let deadline = Date().addingTimeInterval(timeout)
        let first = try await attempt(request, config: config, key: key, timeout: timeout)
        switch first.outcome {
        case .success(let text): return (text, first.tokens)
        case .failure(let why):
            // A model that only thinks will do so again: a second request would just be paid for too.
            // Neither is worth it for a half-spoken sentence: newer words are about to be sent anyway.
            if why.kind == .thinking || request.live { throw why }
            // Context is the usual reason a small model goes wrong: ask once more with the sentence alone.
            let background = !request.context.isEmpty || !config.topic.isEmpty
            guard background, deadline.timeIntervalSinceNow > 0.5 else { throw why }
            var bare = config; bare.topic = ""
            let second = try await attempt(TranslationRequest(text: request.text), config: bare, key: key,
                                           timeout: deadline.timeIntervalSinceNow)
            return (try second.outcome.get(), first.tokens + second.tokens)
        }
    }

    /// One request. Network and server problems are thrown; an unusable reply is returned as a failure.
    private func attempt(_ request: TranslationRequest, config: LLMConfig, key: String?, timeout: TimeInterval) async throws
        -> (outcome: Result<String, LLMError>, tokens: Int) {
        let reply = try await client.chat(config: config, apiKey: key, messages: LLMPrompt.messages(for: request, config: config),
                                          maxTokens: LLMWire.tokenLimit(for: request.text), timeout: timeout)
        let hadContext = !request.context.isEmpty
        do {
            let text = try LLMOutput.clean(reply.content, source: request.text, finishReason: reply.finishReason)
            if LLMOutput.repeatsPrompt(raw: reply.content, cleaned: text, source: request.text, hadContext: hadContext,
                                       style: config.profile.promptStyle.resolved(for: config.profile.model)) {
                throw LLMOutput.Rejection.repeatedPrompt
            }
            return (.success(text), reply.totalTokens)
        } catch let why as LLMOutput.Rejection {
            let onlyThought = why == .onlyThinking || (reply.hadReasoning && (why == .empty || why == .truncated))
            let error = onlyThought ? LLMError(kind: .thinking, message: LLMOutput.Rejection.onlyThinking.description)
                                    : LLMError(kind: .rejected, message: why.description)
            return (.failure(error), reply.totalTokens)
        }
    }
}
