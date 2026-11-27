import Foundation

// MARK: - HTTP

/// Refuses redirects: following one could hand the API key and the transcript to a different server.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class LLMClient: @unchecked Sendable {
    private let session: URLSession            // internet: follows the system's proxy settings
    private let directSession: URLSession      // this Mac and local network: no proxy
    private let lock = NSLock()
    private var refused: [String: Set<String>] = [:]      // per server + model: optional fields it rejected
    private var thinkingChoices: [String: Int] = [:]      // per server + model: which "thinking off" form works

    init(configuration: URLSessionConfiguration = .ephemeral) {       // ephemeral: nothing is cached on disk
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        let direct = configuration.copy() as! URLSessionConfiguration
        direct.connectionProxyDictionary = [:]
        directSession = URLSession(configuration: direct, delegate: NoRedirects(), delegateQueue: nil)
    }

    private func refusedFields(_ key: String) -> Set<String> { lock.lock(); defer { lock.unlock() }; return refused[key] ?? [] }
    private func remember(_ field: String, _ key: String) { lock.lock(); defer { lock.unlock() }; refused[key, default: []].insert(field) }
    func forgetRefusals() { lock.lock(); defer { lock.unlock() }; refused = [:]; thinkingChoices = [:] }
    private func thinkingChoice(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return thinkingChoices[key] ?? 0 }
    private func use(thinkingChoice: Int, _ key: String) { lock.lock(); defer { lock.unlock() }; thinkingChoices[key] = thinkingChoice }
    /// Fields left out because this server refused them (shown by the Test button).
    func droppedFields(for config: LLMConfig) -> [String] {
        guard let e = try? LLMEndpoint.parse(config.profile.baseURL) else { return [] }
        return refusedFields(e.base.absoluteString + "|" + config.profile.model).sorted()
    }

    func chat(config: LLMConfig, apiKey: String?, messages: [ChatMessage], maxTokens: Int, timeout: TimeInterval) async throws -> LLMReply {
        do { return try await exchange(config: config, apiKey: apiKey, messages: messages, maxTokens: maxTokens, timeout: timeout) }
        catch let e as LLMError { throw e.redacted(apiKey) }
    }

    private func exchange(config: LLMConfig, apiKey: String?, messages: [ChatMessage], maxTokens: Int, timeout: TimeInterval) async throws -> LLMReply {
        let endpoint = try parsedEndpoint(config)
        guard !config.profile.model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw LLMError(kind: .config, message: "choose a model name first")
        }
        let cacheKey = endpoint.base.absoluteString + "|" + config.profile.model
        let deadline = Date().addingTimeInterval(timeout)
        for _ in 0..<4 {                       // a refused request costs nothing; each retry changes one thing
            let dropped = refusedFields(cacheKey), choice = thinkingChoice(cacheKey)
            let body = try LLMWire.body(config: config, messages: messages, maxTokens: maxTokens, dropped: dropped, thinkingChoice: choice)
            var request = URLRequest(url: endpoint.chatURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            do {
                let data = try await send(request, to: endpoint, apiKey: apiKey, deadline: deadline)
                return try LLMWire.reply(from: data)
            } catch let e as LLMError where e.kind == .badRequest {
                guard let field = LLMWire.adaptation(for: e.message, body: body), !dropped.contains(field) else { throw e }
                let choices = config.provider.thinkingOffChoices
                if config.profile.disableThinking, choices.indices.contains(choice + 1), choices[choice][field] != nil {
                    use(thinkingChoice: choice + 1, cacheKey)            // try another way of saying "don't think"
                } else {
                    remember(field, cacheKey)
                }
            }
        }
        throw LLMError(kind: .badRequest, message: "the server keeps rejecting the request")
    }

    func listModels(config: LLMConfig, apiKey: String?, timeout: TimeInterval = 15) async throws -> [String] {
        do {
            let endpoint = try parsedEndpoint(config)
            var request = URLRequest(url: endpoint.modelsURL)
            request.httpMethod = "GET"
            let data = try await send(request, to: endpoint, apiKey: apiKey, deadline: Date().addingTimeInterval(timeout))
            return try LLMWire.modelIDs(from: data)
        } catch let e as LLMError { throw e.redacted(apiKey) }
    }

    private func parsedEndpoint(_ config: LLMConfig) throws -> LLMEndpoint {
        do { return try LLMEndpoint.parse(config.profile.baseURL) }
        catch { throw LLMError(kind: .config, message: "\(error)") }
    }

    private func send(_ request: URLRequest, to endpoint: LLMEndpoint, apiKey: String?, deadline: Date) async throws -> Data {
        var request = request
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0.05 else { throw LLMError(kind: .timeout, message: "no answer in time") }
        request.timeoutInterval = remaining
        let session = endpoint.scope == .internet ? self.session : directSession, final = request
        do {
            // URLSession's own timeout only measures silence; some servers send keep-alive bytes, so race a real deadline.
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    let (data, response) = try await session.data(for: final)
                    guard let http = response as? HTTPURLResponse else { throw LLMError(kind: .badResponse, message: "not an HTTP reply") }
                    guard (200..<300).contains(http.statusCode) else {
                        throw LLMWire.failure(status: http.statusCode, data: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
                    }
                    return data
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(remaining))
                    throw LLMError(kind: .timeout, message: "no answer within the time limit")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            if e.code == .timedOut { throw LLMError(kind: .timeout, message: "no answer within the time limit") }
            let host = final.url?.host ?? "the server"
            if e.code == .cannotConnectToHost { throw LLMError(kind: .network, message: "cannot connect to \(host) (is the server running?)") }
            throw LLMError(kind: .network, message: "network problem: \(e.localizedDescription)")
        }
    }
}
