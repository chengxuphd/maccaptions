import Foundation

struct LLMError: Error, CustomStringConvertible, Equatable {
    enum Kind: Equatable {
        case auth, payment, notFound, badRequest, rateLimited, server, network, timeout, badResponse, rejected, config
        case thinking          // only reasoning came back: every such request costs money and yields nothing
    }
    var kind: Kind
    var message: String
    var retryAfter: Double?
    var description: String { message }

    /// Hides the API key wherever a server may have echoed it, THEN shortens the text (a cut-off key would no
    /// longer match).
    func redacted(_ key: String?) -> LLMError {
        var e = self
        if let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), k.count >= 6 {
            e.message = e.message.replacingOccurrences(of: k, with: "•••")
        }
        if e.message.count > 300 { e.message = String(e.message.prefix(300)) + "…" }
        return e
    }

    /// Retrying the next sentence cannot help until the user (or the account) changes something.
    var needsUserAction: Bool { [.auth, .payment, .notFound, .config].contains(kind) }
}

struct LLMReply: Equatable {
    var content: String
    var finishReason: String?
    var hadReasoning = false
    var totalTokens = 0
}

// MARK: - Building requests and reading replies (pure functions, covered by the self-tests)

enum LLMWire {
    /// Generous enough for a long sentence, small enough to stop a model that rambles.
    static func tokenLimit(for text: String) -> Int { min(1024, max(128, text.count + 64)) }

    /// `dropped` holds fields this server has already refused (see `adaptation`); `thinkingChoice` says which of the
    /// provider's ways of turning thinking off to use.
    static func body(config: LLMConfig, messages: [ChatMessage], maxTokens: Int, dropped: Set<String> = [],
                     thinkingChoice: Int = 0) throws -> [String: Any] {
        let p = config.provider
        var body: [String: Any] = [
            "model": config.profile.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": false,
        ]
        if p.sendsTemperature { body["temperature"] = 0.2 }
        body[p.tokenLimitField] = maxTokens
        if config.profile.disableThinking && p.thinkingOffChoices.indices.contains(thinkingChoice) {
            body.merge(p.thinkingOffChoices[thinkingChoice]) { _, new in new }
        }
        for field in dropped { body[field] = nil }
        // If a server refuses the name of the length limit, use the other name.
        if dropped.contains(p.tokenLimitField) {
            let other = p.tokenLimitField == "max_tokens" ? "max_completion_tokens" : "max_tokens"
            if !dropped.contains(other) { body[other] = maxTokens }
        }
        // The user's own fields come last and win.
        for (k, v) in try extraFields(config.profile.extraJSON) { body[k] = v is NSNull ? nil : v }
        return body
    }

    static func extraFields(_ text: String) throws -> [String: Any] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return [:] }
        func object(_ s: String) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] }
        // macOS may have turned typed quotes into curly ones; straighten them only if the text is not valid as it is.
        guard let obj = object(t) ?? object(t.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")) else {
            throw LLMError(kind: .config, message: "“Extra request JSON” is not a JSON object like {\"top_p\": 0.9} .")
        }
        return obj
    }

    /// Services differ in which optional fields they accept. When one is refused by name, it is left out from then on.
    static let optionalFields = ["chat_template_kwargs", "reasoning_effort", "max_completion_tokens", "max_tokens",
                                 "temperature", "reasoning", "thinking"]

    static func adaptation(for errorMessage: String, body: [String: Any]) -> String? {
        let m = errorMessage.lowercased()
        return optionalFields.first { field in
            body[field] != nil && m.range(of: "(?<![a-z_])\(field)(?![a-z_])", options: .regularExpression) != nil
        }
    }

    static func errorMessage(from data: Data) -> String {
        var message = ""
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let e = obj["error"] as? [String: Any] {
                message = e["message"] as? String ?? ""
                if let meta = e["metadata"] as? [String: Any], let raw = meta["raw"] as? String { message += " — " + raw }
                if let param = e["param"] as? String, !message.contains(param) { message += " (\(param))" }
            } else {
                message = obj["error"] as? String ?? obj["message"] as? String ?? obj["detail"] as? String ?? ""
            }
        }
        if message.isEmpty { message = String(decoding: data.prefix(20_000), as: UTF8.self) }
        return message.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    static func failure(status: Int, data: Data, retryAfter: String?) -> LLMError {
        let kind: LLMError.Kind
        let what: String
        switch status {
        case 401, 403: kind = .auth; what = "the API key was refused"
        case 402: kind = .payment; what = "the account has no credit left"
        case 404: kind = .notFound; what = "model or address not found"
        case 429: kind = .rateLimited; what = "rate limit reached"
        case 400, 422: kind = .badRequest; what = "the server rejected the request"
        case 300..<400: kind = .config; what = "the server redirects elsewhere; enter its final address"
        default: kind = .server; what = "server error"
        }
        let detail = errorMessage(from: data)
        return LLMError(kind: kind, message: "\(what) (HTTP \(status))" + (detail.isEmpty ? "" : ": " + detail),
                        retryAfter: retryAfter.flatMap(Double.init))
    }

    static func reply(from data: Data) throws -> LLMReply {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw LLMError(kind: .badResponse, message: "the server did not return JSON (is the address right?)")
        }
        // Some services report a failure inside a successful (HTTP 200) response.
        if let e = obj["error"], !(e is NSNull) { throw LLMError(kind: .server, message: errorMessage(from: data)) }
        guard let choice = (obj["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any] else {
            throw LLMError(kind: .badResponse, message: "the reply has no message (is this an OpenAI-compatible endpoint?)")
        }
        var content = message["content"] as? String ?? ""
        if content.isEmpty, let parts = message["content"] as? [[String: Any]] {
            content = parts.compactMap { ($0["type"] as? String).map { $0 == "text" } == false ? nil : $0["text"] as? String }.joined()
        }
        let reasoning = ["reasoning_content", "reasoning", "thinking"].contains { !((message[$0] as? String) ?? "").isEmpty }
        #if DEVTOOLS
        if ProcessInfo.processInfo.environment["MACCAPTIONS_LLM_USAGE"] != nil, let u = obj["usage"] as? [String: Any],
           let d = try? JSONSerialization.data(withJSONObject: u, options: [.sortedKeys]) {
            var line = "USAGE \(String(decoding: d, as: UTF8.self))"
            if let p = obj["provider"] as? String { line += " | served by \(p)" }
            print(line)
        }
        #endif
        #if DEVTOOLS
        if ProcessInfo.processInfo.environment["MACCAPTIONS_LLM_RAW"] != nil,
           let d = try? JSONSerialization.data(withJSONObject: choice, options: [.sortedKeys]) {
            print("RAW \(String(decoding: d, as: UTF8.self))")
        }
        #endif
        let tokens = (obj["usage"] as? [String: Any])?["total_tokens"] as? Int ?? 0
        return LLMReply(content: content, finishReason: choice["finish_reason"] as? String, hadReasoning: reasoning, totalTokens: tokens)
    }

    static func modelIDs(from data: Data) throws -> [String] {
        let obj = try? JSONSerialization.jsonObject(with: data)
        let list = (obj as? [String: Any])?["data"] as? [[String: Any]] ?? obj as? [[String: Any]]
        guard let list else { throw LLMError(kind: .badResponse, message: "this server does not offer a model list") }
        return list.compactMap { $0["id"] as? String }.sorted()
    }
}
