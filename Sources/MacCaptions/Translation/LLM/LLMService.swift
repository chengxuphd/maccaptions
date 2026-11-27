import Foundation

/// Reads each API key from the Keychain at most once per change of settings, away from the main thread.
actor APIKeyCache {
    private var cache: [String: Result<String?, Error>] = [:]

    func key(_ account: String) throws -> String? {
        if let hit = cache[account] { return try hit.get() }
        let result = Result { try KeychainStore.read(account) }
        cache[account] = result          // a refusal is remembered too, so macOS doesn't prompt for every sentence
        return try result.get()
    }

    func clear() { cache = [:] }
}

/// The shared HTTP client and key cache, used by live captioning and by the settings window.
final class LLMService: Sendable {
    #if DEVTOOLS
    let client = stubbedClientConfigurationIfRequested().map { LLMClient(configuration: $0) } ?? LLMClient()
    #else
    let client = LLMClient()
    #endif
    private let keys = APIKeyCache()

    /// A local model works on one sentence at a time; a cloud service can take a few at once.
    static func concurrency(for config: LLMConfig) -> Int {
        (try? LLMEndpoint.parse(config.profile.baseURL))?.scope == .internet ? 3 : 1
    }

    func settingsChanged() {
        client.forgetRefusals()
        Task { await keys.clear() }
    }

    func clearKeyCache() async { await keys.clear() }

    /// The saved key for this provider at this address, if there is one.
    func apiKey(for config: LLMConfig) async throws -> String? {
        #if DEVTOOLS
        if ProcessInfo.processInfo.environment["MACCAPTIONS_LLM_KEY_FILE"] != nil { return testKey(for: config) }
        #endif
        guard let endpoint = try? LLMEndpoint.parse(config.profile.baseURL) else { return nil }
        let account = KeychainStore.account(provider: config.provider, endpoint: endpoint)
        // Checking for existence never prompts, so people who use no key never see a Keychain dialog.
        guard KeychainStore.exists(account) else {
            if config.provider.needsAPIKey {
                throw LLMError(kind: .config, message: "no API key saved for \(endpoint.host) (press Set)")
            }
            return nil
        }
        do { return try await keys.key(account) }
        catch { throw LLMError(kind: .auth, message: "\(error). Press Set and save the key again.") }
    }

    func engine(for config: LLMConfig) -> ChatCompletionsEngine {
        ChatCompletionsEngine(config: config, client: client, apiKey: { [self] in try await apiKey(for: config) })
    }

    func listModels(for config: LLMConfig) async throws -> [String] {
        try await client.listModels(config: config, apiKey: try await apiKey(for: config))
    }
}
