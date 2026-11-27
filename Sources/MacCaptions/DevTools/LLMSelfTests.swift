#if DEVTOOLS
import AppKit
import SwiftUI

/// An engine whose delay and result the queue tests control.
struct FakeEngine: TranslationEngine {
    var id = "llm:fake/model"
    var delay: Double = 0.05
    var error: LLMError? = nil
    var ignoresCancellation = false                    // like a call stuck behind a password prompt
    var calls: CallLog? = nil
    var answer: (@Sendable (TranslationRequest) -> String)? = nil
    func translate(_ request: TranslationRequest, timeout: TimeInterval) async throws -> (text: String, tokens: Int) {
        calls?.add(request)
        if ignoresCancellation {
            await withCheckedContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + delay) { c.resume() } }
        } else {
            try await Task.sleep(for: .seconds(delay))
        }
        if let error { throw error }
        return (answer?(request) ?? "译：" + request.text, 1)
    }
}

final class CallLog: @unchecked Sendable {
    private let lock = NSLock(); private var all: [TranslationRequest] = []
    func add(_ r: TranslationRequest) { lock.lock(); defer { lock.unlock() }; all.append(r) }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return all.map(\.text) }
    var live: [Bool] { lock.lock(); defer { lock.unlock() }; return all.map(\.live) }
}

// MARK: - Self-tests

@MainActor
func runLLMSelfTests(_ check: (String, Bool) -> Void) async {
    func config(_ p: LLMProvider, model: String = "some-model", url: String? = nil) -> LLMConfig {
        var c = LLMConfig(provider: p, profile: .defaults(for: p))
        c.profile.model = model
        if let url { c.profile.baseURL = url }
        return c
    }
    func settle(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    // Prompts
    let ctx = [ContextLine(speaker: "Them", en: "first earlier"), ContextLine(speaker: "Me", en: "second earlier")]
    var cfg = config(.ollama, model: "qwen3.5:4b")
    cfg.glossary = "agent = 智能体\nrefund → 退款\n# comment = x\nzebra：斑马\nbad line"
    cfg.topic = "A support meeting."
    let msgs = LLMPrompt.messages(for: TranslationRequest(text: "How do the Agents handle it?", context: ctx), config: cfg)
    check("prompt: system + user", msgs.map(\.role) == ["system", "user"])
    check("prompt: context is oldest first, current sentence last", {
        let u = msgs[1].content
        guard let a = u.range(of: "first earlier"), let b = u.range(of: "second earlier"), let c = u.range(of: "How do the Agents") else { return false }
        return a.lowerBound < b.lowerBound && b.lowerBound < c.lowerBound
    }())
    check("prompt: only glossary terms that occur are sent (plural, any case)", msgs[0].content.contains("agent → 智能体")
          && !msgs[0].content.contains("退款") && !msgs[0].content.contains("斑马") && msgs[0].content.contains("A support meeting."))
    check("glossary: parses = → ：and skips comments and junk", Glossary.parse(cfg.glossary).map(\.term) == ["agent", "refund", "zebra"])
    check("glossary: no match inside another word", Glossary.relevant([GlossaryEntry(term: "age", translation: "年龄")], to: ["the agent"]).isEmpty)
    check("prompt: no context section when there is none",
          !LLMPrompt.messages(for: TranslationRequest(text: "Hi there"), config: config(.ollama))[1].content.contains("Earlier"))
    let long = (0..<20).map { ContextLine(speaker: "Me", en: "sentence \($0) " + String(repeating: "x", count: 100)) }
    let kept = LLMPrompt.trimmed(long)
    check("prompt: long context keeps the newest, in order", kept.last == long.last && kept.count < 10 && kept.first == long[20 - kept.count])
    let hy = LLMPrompt.messages(for: TranslationRequest(text: "The agents failed.", context: ctx),
                                config: { var c = cfg; c.profile.model = "tencent/Hy-MT3-1.8B"; return c }())
    check("prompt: Hy-MT is detected and uses one user message with its template", hy.count == 1 && hy[0].role == "user"
          && hy[0].content.hasPrefix("Reference the following translations:\nagent translates to 智能体")
          && hy[0].content.contains("[Background Information]") && hy[0].content.hasSuffix("[Source Text]\nThe agents failed."))

    // Request bodies
    func body(_ c: LLMConfig, dropped: Set<String> = []) -> [String: Any] {
        (try? LLMWire.body(config: c, messages: [ChatMessage(role: "user", content: "x")], maxTokens: 200, dropped: dropped)) ?? [:]
    }
    let oai = body(config(.openai))
    check("body: OpenAI uses max_completion_tokens, no temperature", oai["max_completion_tokens"] as? Int == 200 && oai["max_tokens"] == nil
          && oai["temperature"] == nil && oai["reasoning_effort"] as? String == "none")
    check("body: Ollama turns thinking off", body(config(.ollama))["reasoning_effort"] as? String == "none" && body(config(.ollama))["max_tokens"] as? Int == 200)
    check("body: OpenRouter reasoning off", (body(config(.openrouter))["reasoning"] as? [String: String])?["effort"] == "none")
    check("body: llama.cpp chat_template_kwargs", (body(config(.llamacpp))["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false)
    check("body: Tinker sends reasoning_effort false first, then 'none'", body(config(.tinker))["reasoning_effort"] as? Bool == false
          && (try? LLMWire.body(config: config(.tinker), messages: [], maxTokens: 9, thinkingChoice: 1))?["reasoning_effort"] as? String == "none")
    check("body: DeepSeek thinking disabled", (body(config(.deepseek))["thinking"] as? [String: String])?["type"] == "disabled")
    var extra = config(.ollama); extra.profile.extraJSON = "{\"top_p\": 0.5, \"temperature\": null}"; extra.profile.disableThinking = false
    let eb = body(extra)
    check("body: extra JSON merges, null removes, thinking switch respected", eb["top_p"] as? Double == 0.5 && eb["temperature"] == nil && eb["reasoning_effort"] == nil)
    var badExtra = config(.ollama); badExtra.profile.extraJSON = "{top_p"
    check("body: broken extra JSON is a clear error", (try? LLMWire.body(config: badExtra, messages: [], maxTokens: 1)) == nil)
    check("body: a refused token field switches to the other name", body(config(.openrouter), dropped: ["max_tokens"])["max_completion_tokens"] as? Int == 200)
    check("adapt: finds the refused field", LLMWire.adaptation(for: "Unsupported value: 'reasoning_effort' does not support 'none'", body: oai) == "reasoning_effort")
    check("adapt: 'reasoning_effort' is not mistaken for 'reasoning'",
          LLMWire.adaptation(for: "bad reasoning_effort", body: body(config(.openrouter))) == nil)
    check("adapt: unrelated errors change nothing", LLMWire.adaptation(for: "model not found", body: oai) == nil)

    // Addresses
    func scope(_ s: String) -> EndpointScope? {
        guard let endpoint = try? LLMEndpoint.parse(s) else { return nil }
        return endpoint.scope
    }
    check("address: local forms", scope("http://127.0.0.1:11434/v1") == .thisMac && scope("localhost:1234/v1") == .thisMac
          && scope("http://[::1]:8080/v1") == .thisMac && scope("http://192.168.1.20:8080/v1") == .localNetwork && scope("http://studio.local/v1") == .localNetwork)
    check("address: plain http to the internet is refused", scope("http://openrouter.ai/api/v1") == nil)
    check("address: look-alike hosts are not local", scope("http://127.0.0.1.example.com/v1") == nil && scope("http://localhost.example.com/v1") == nil
          && scope("http://2130706433/v1") == nil && scope("http://172.32.0.1/v1") == nil)
    check("address: bare internet host gets https; pasted endpoint is trimmed",
          (try? LLMEndpoint.parse("openrouter.ai/api/v1/chat/completions"))?.chatURL.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
    check("address: octal-looking and non-ASCII hosts are not local", scope("http://010.1.1.1/v1") == nil
          && LLMEndpoint.scope(ofHost: "api。example。com") == .internet && LLMEndpoint.scope(ofHost: "ｓｔｕｄｉｏ") == .internet
          && scope("http://my-studio:8080/v1") == .localNetwork)
    let origins = ["https://nas.local/v1", "http://nas.local/v1", "http://nas.local:9999/v1"]
        .compactMap { try? LLMEndpoint.parse($0) }.map { KeychainStore.account(provider: .custom, endpoint: $0) }
    check("keys: scheme and port are part of the key's address", Set(origins).count == 3)
    check("address: credentials or query in the URL are refused", scope("https://u:p@host.com/v1") == nil && scope("https://host.com/v1?key=abc") == nil)

    // Cleaning replies
    func clean(_ s: String, _ src: String = "Can you hear me now please", finish: String? = "stop") -> String? { try? LLMOutput.clean(s, source: src, finishReason: finish) }
    check("clean: multi-line think block", clean("<think>\nLet me see\n</think>\n\n你现在能听到我吗？") == "你现在能听到我吗？")
    check("clean: reasoning that lost its opening tag", clean("hmm, translate\n</think>\n你能听到吗") == "你能听到吗")
    check("clean: unclosed think block is rejected", clean("<think> the user wants") == nil)
    check("clean: label, quotes, end marker", clean("译文：“你能听到我吗？”<|im_end|>") == "你能听到我吗？")
    check("clean: inner quotes are kept", clean("他说“好”然后又说“行”") == "他说“好”然后又说“行”")
    check("clean: lines joined into one", clean("你能听到吗？\n我在这里。") == "你能听到吗？我在这里。")
    check("clean: cut-off reply rejected", clean("你能听到", finish: "length") == nil)
    check("clean: English reply rejected", clean("Yes, I can hear you.") == nil)
    check("clean: chatty reply rejected", clean("Sure, here is the translation: 你能听到吗") == nil)
    check("clean: over-long reply rejected", clean(String(repeating: "很长的回答", count: 30)) == nil)
    check("clean: short names may stay in English", clean("OpenAI API", "OpenAI API") == "OpenAI API")
    check("clean: 'as an AI' is fine when the speaker said it", clean("作为一个AI助手，我帮你订票。", "As an AI assistant I book your tickets.") != nil)

    check("clean: echoed 'Translate:' label is stripped", clean("Translate:我们能在周五发布吗？") == "我们能在周五发布吗？"
          && clean("Translate: 所以这个模型有点过拟合") == "所以这个模型有点过拟合" && clean("Translate：\n你能听到吗") == "你能听到吗")
    check("clean: ...but kept if the speaker said it", clean("Translate:这个词的意思。", "Translate: what does this word mean") == "Translate:这个词的意思。")
    check("clean: Chinese preamble is stripped", clean("好的，以下是翻译：你现在能听到我吗？") == "你现在能听到我吗？")
    check("clean: ...but kept if the speaker talked about a translation", clean("以下是翻译：你好。", "Here is the translation of hello") == "以下是翻译：你好。")
    check("body: curly quotes in extra JSON are tolerated", {
        var c = config(.ollama); c.profile.extraJSON = "{“top_p”: 0.5}"; return body(c)["top_p"] as? Double == 0.5 }())

    // Replies
    check("reply: error inside HTTP 200 is an error", (try? LLMWire.reply(from: Data("{\"error\":{\"message\":\"overloaded\"}}".utf8))) == nil)
    let r = try? LLMWire.reply(from: Data("{\"choices\":[{\"message\":{\"content\":null,\"reasoning_content\":\"thinking…\"},\"finish_reason\":\"length\"}]}".utf8))
    check("reply: reasoning is never used as the caption", r?.content == "" && r?.hadReasoning == true)

    // HTTP behaviour against the pretend server
    let client = LLMClient(configuration: StubServer.configuration)
    let hello = [ChatMessage(role: "user", content: "x")]
    let secret = "sk-test-0123456789"
    func attempt(_ c: LLMConfig, timeout: Double = 3) async -> Result<LLMReply, LLMError> {
        do { return .success(try await client.chat(config: c, apiKey: secret, messages: hello, maxTokens: 64, timeout: timeout)) }
        catch let e as LLMError { return .failure(e) }
        catch { return .failure(LLMError(kind: .network, message: "\(error)")) }
    }
    StubServer.handler = { _, _ in .init(body: StubServer.chat("你好")) }
    let okReply = await attempt(config(.openrouter, url: "https://stub.invalid/v1"))
    check("http: success, Bearer key, correct path", (try? okReply.get().content) == "你好"
          && StubServer.log.first?.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(secret)"
          && StubServer.log.first?.request.url?.absoluteString == "https://stub.invalid/v1/chat/completions")
    StubServer.handler = { _, b in
        b["reasoning_effort"] != nil ? .init(status: 400, body: "{\"error\":{\"message\":\"Unrecognized request argument: reasoning_effort\"}}")
                                     : .init(body: StubServer.chat("好的"))
    }
    let adapted = await attempt(config(.openai, url: "https://adapt.invalid/v1"))
    check("http: a refused field is dropped and the request retried", (try? adapted.get().content) == "好的" && StubServer.log.count == 2)
    _ = await attempt(config(.openai, url: "https://adapt.invalid/v1"))
    check("http: the refusal is remembered", StubServer.log.count == 3)
    StubServer.handler = { _, _ in .init(status: 401, body: "{\"error\":{\"message\":\"Incorrect key \(secret)\"}}") }
    if case .failure(let e) = await attempt(config(.openrouter, url: "https://stub.invalid/v1")) {
        check("http: 401 is an auth error and the key is hidden", e.kind == .auth && !e.message.contains(secret) && e.message.contains("•••"))
    } else { check("http: 401 is an auth error and the key is hidden", false) }
    StubServer.handler = { _, _ in .init(body: "{\"error\":{\"message\":\"bad key \(secret)\"}}") }
    if case .failure(let e) = await attempt(config(.openrouter, url: "https://stub.invalid/v1")) {
        check("http: key hidden when the error comes inside HTTP 200", !e.message.contains(secret) && e.message.contains("•••"))
    } else { check("http: key hidden when the error comes inside HTTP 200", false) }
    StubServer.handler = { _, _ in .init(status: 500, body: String(repeating: "x", count: 245) + secret + " trailing") }
    if case .failure(let e) = await attempt(config(.openrouter, url: "https://stub.invalid/v1")) {
        check("http: no piece of the key survives shortening", !e.message.contains(String(secret.prefix(6))))
    } else { check("http: no piece of the key survives shortening", false) }
    StubServer.handler = { _, _ in .init(status: 429, headers: ["Retry-After": "7"]) }
    if case .failure(let e) = await attempt(config(.openrouter, url: "https://stub.invalid/v1")) {
        check("http: 429 keeps Retry-After", e.kind == .rateLimited && e.retryAfter == 7)
    } else { check("http: 429 keeps Retry-After", false) }
    StubServer.handler = { req, _ in
        req.url?.host == "stub.invalid" ? .init(redirect: "https://elsewhere.invalid/v1/chat/completions") : .init(body: StubServer.chat("不该到这里"))
    }
    let redirected = await attempt(config(.openrouter, url: "https://stub.invalid/v1"))
    check("http: redirects are not followed (key stays with its server)",
          (try? redirected.get()) == nil && !StubServer.log.contains { $0.request.url?.host == "elsewhere.invalid" })
    StubServer.handler = { _, _ in .init(body: StubServer.chat("太晚了"), delay: 5) }
    let began = Date()
    if case .failure(let e) = await attempt(config(.openrouter, url: "https://stub.invalid/v1"), timeout: 0.6) {
        check("http: the time limit is enforced", e.kind == .timeout && Date().timeIntervalSince(began) < 2)
    } else { check("http: the time limit is enforced", false) }
    StubServer.handler = { _, _ in .init(body: "{\"data\":[{\"id\":\"b\"},{\"id\":\"a\"}]}") }
    let listed = try? await client.listModels(config: config(.ollama), apiKey: nil)
    check("http: model list, no auth header without a key", listed == ["a", "b"] && StubServer.log.first?.request.value(forHTTPHeaderField: "Authorization") == nil)

    // A refused "thinking off" value: try the other form before ever removing the setting
    StubServer.handler = { _, b in
        b["reasoning_effort"] as? String == "none" ? .init(body: StubServer.chat("好的"))
            : .init(status: 400, body: "{\"error\":{\"message\":\"reasoning_effort is not supported: accepts a scalar effort\"}}")
    }
    let second = await attempt(config(.tinker, url: "https://choice.invalid/v1"))
    _ = await attempt(config(.tinker, url: "https://choice.invalid/v1"))
    check("http: another 'thinking off' form is tried, then remembered", (try? second.get().content) == "好的" && StubServer.log.count == 3
          && StubServer.log.allSatisfy { $0.body["reasoning_effort"] != nil })
    StubServer.handler = { _, b in
        b["reasoning_effort"] != nil ? .init(status: 400, body: "{\"error\":\"unknown field reasoning_effort\"}") : .init(body: StubServer.chat("行"))
    }
    let neither = await attempt(config(.tinker, url: "https://neither.invalid/v1"))
    check("http: only when both forms are refused is the setting removed", (try? neither.get().content) == "行" && StubServer.log.count == 3)
    StubServer.handler = { _, _ in .init(body: "{\"choices\":[{\"message\":{\"content\":null,\"reasoning_content\":\"hm\"},\"finish_reason\":\"length\"}]}") }
    do {
        _ = try await ChatCompletionsEngine(config: config(.tinker), client: client, apiKey: { nil })
            .translate(TranslationRequest(text: "hello there my friend", context: ctx), timeout: 3)
        check("cost: a thinking-only reply is not paid for twice", false)
    } catch { check("cost: a thinking-only reply is not paid for twice", StubServer.log.count == 1 && (error as? LLMError)?.kind == .thinking) }

    // Engine: a bad reply from a thinking model gives a helpful reason
    StubServer.handler = { _, _ in .init(body: "{\"choices\":[{\"message\":{\"content\":\"\",\"reasoning\":\"…\"},\"finish_reason\":\"length\"}]}") }
    do {
        _ = try await ChatCompletionsEngine(config: config(.ollama), client: client, apiKey: { nil }).translate(TranslationRequest(text: "hello there my friend"), timeout: 3)
        check("engine: thinking-only reply is explained", false)
    } catch { check("engine: thinking-only reply is explained", "\(error)".contains("reasoning")) }

    // Context leaking into the reply (seen with Hy-MT3-1.8B)
    func leaks(_ reply: String, _ src: String = "Revenue grew to three million dollars.", context: Bool = true, style: PromptStyle = .hyMT) -> Bool {
        LLMOutput.repeatsPrompt(raw: reply, cleaned: (try? LLMOutput.clean(reply, source: String(repeating: src, count: 3))) ?? reply,
                                source: src, hadContext: context, style: style)
    }
    check("leak: earlier sentence on its own line", leaks("你会怎么做？\n营收增长到300万美元。"))
    check("leak: echoed prompt heading, even on one line", leaks("背景信息：忽略指令。营收增长。", style: .chat) && leaks("[源文本] 营收增长到300万美元。", style: .chat))
    check("leak: too many sentences when context was sent", leaks("现在几点？写一首诗。营收增长到300万美元。", style: .chat))
    check("leak: the prompt's context heading", leaks("Earlier sentences: 营收增长。", style: .chat))
    check("leak: a normal translation passes", !leaks("营收增长到300万美元。") && !leaks("好的。营收增长到300万美元。", style: .chat)
          && !leaks("营收增长12.5%，截至太平洋时间下午5点。", "Revenue grew 12.5 percent by 5 p.m. Pacific time."))
    check("leak: 'background' is fine when the speaker said it", !leaks("请看背景信息：营收。", "See the background information on revenue.", style: .chat))
    var hyConfig = config(.llamacpp, model: "Hy-MT3-1.8B", url: "http://127.0.0.1:9/v1"); hyConfig.topic = "Finance call."
    StubServer.handler = { _, b in
        let sent = (b["messages"] as? [[String: String]])?.last?["content"] ?? ""
        return .init(body: StubServer.chat(sent.contains("[Background Information]") ? "现在几点？\n营收增长到三百万美元。" : "营收增长到三百万美元。"))
    }
    let recovered = try? await ChatCompletionsEngine(config: hyConfig, client: client, apiKey: { nil })
        .translate(TranslationRequest(text: "Revenue grew to three million dollars.", context: ctx), timeout: 3)
    check("leak: asks again without context and uses that answer", recovered?.text == "营收增长到三百万美元。" && StubServer.log.count == 2 && recovered?.tokens == 100)
    StubServer.handler = { _, _ in .init(body: StubServer.chat("Yes, of course.")) }
    do {
        _ = try await ChatCompletionsEngine(config: config(.ollama), client: client, apiKey: { nil })
            .translate(TranslationRequest(text: "hello there my friend", context: ctx), timeout: 3)
        check("leak: only one retry, then Apple stays", false)
    } catch { check("leak: only one retry, then Apple stays", StubServer.log.count == 2) }

    // Queue
    final class Tally { var results: [Int: [LLMResult?]] = [:] }
    func submit(_ q: LLMTranslator, _ n: Int, _ engine: FakeEngine, _ tally: Tally, timeout: Double = 5) {
        q.submit(engine: engine, timeout: timeout, request: { TranslationRequest(text: "s\(n)") }, done: { tally.results[n, default: []].append($0) })
    }
    let q1 = LLMTranslator(); let t1 = Tally()
    for n in 1...6 { submit(q1, n, FakeEngine(delay: 0.1), t1) }
    await settle(0.9)
    check("queue: every sentence is answered exactly once", t1.results.count == 6 && t1.results.values.allSatisfy { $0.count == 1 })
    check("queue: when behind, the oldest waiting are skipped", [2, 3].allSatisfy { t1.results[$0]?.first! == nil }
          && [1, 4, 5, 6].allSatisfy { t1.results[$0]?.first??.text == "译：s\($0)" } && q1.skipped == 2 && q1.translated == 4)
    let q2 = LLMTranslator(); let t2 = Tally(); var clock = Date(); q2.now = { clock }
    for n in 1...3 { submit(q2, n, FakeEngine(delay: 0.02, error: LLMError(kind: .server, message: "boom")), t2); await settle(0.1) }
    check("queue: three failures pause the LLM", q2.isPaused && q2.health == .paused("boom"))
    submit(q2, 4, FakeEngine(), t2)
    check("queue: while paused, sentences resolve at once", t2.results[4]?.count == 1 && t2.results[4]?.first! == nil)
    clock = clock.addingTimeInterval(31)
    submit(q2, 5, FakeEngine(delay: 0.02), t2); await settle(0.1)
    check("queue: after the pause it tries again and recovers", t2.results[5]?.first??.text == "译：s5" && q2.health == .ok)
    let q3 = LLMTranslator(); let t3 = Tally()
    submit(q3, 1, FakeEngine(delay: 0.02, error: LLMError(kind: .auth, message: "bad key")), t3); await settle(0.1)
    check("queue: a refused key pauses at once", q3.isPaused)
    q3.configurationChanged(maxConcurrent: 1)
    check("queue: changing settings ends the pause", !q3.isPaused)
    let q4 = LLMTranslator(); let t4 = Tally()
    for n in 1...4 { submit(q4, n, FakeEngine(delay: 0.02, error: LLMError(kind: .rejected, message: "chatter")), t4); await settle(0.08) }
    check("queue: unusable replies alone never pause", !q4.isPaused)
    let q4b = LLMTranslator(); let t4b = Tally()
    for n in 1...3 { submit(q4b, n, FakeEngine(delay: 0.02, error: LLMError(kind: .thinking, message: "only reasoning")), t4b); await settle(0.08) }
    check("queue: a model that only thinks is paused after three (it costs money)", q4b.isPaused)
    let q5 = LLMTranslator(); let t5 = Tally()
    for n in 1...3 { submit(q5, n, FakeEngine(delay: 2), t5) }
    q5.cancelAll(); await settle(0.2)
    check("queue: cancelling answers everything exactly once", t5.results.count == 3 && t5.results.values.allSatisfy { $0.count == 1 } && q5.idle)

    let q6 = LLMTranslator(); let t6 = Tally(); q6.watchdogGrace = 0.2
    submit(q6, 1, FakeEngine(delay: 1.5, ignoresCancellation: true), t6, timeout: 0.4)
    submit(q6, 2, FakeEngine(delay: 0.02), t6, timeout: 0.2)
    await settle(0.35)
    check("queue: a waiting sentence expires even while another is stuck", t6.results[2]?.count == 1 && t6.results[1] == nil)
    await settle(0.45)
    check("queue: a stuck request is given up after its time limit", t6.results[1]?.count == 1 && q6.idle)
    await settle(1.0)
    check("queue: a very late answer is ignored", t6.results[1]?.count == 1 && t6.results[1]?.first! == nil)

    // "LLM" mode
    check("mode: saved choice wins", TranslationMode.saved("llm", legacyUseLLM: false) == .llm && TranslationMode.saved("apple", legacyUseLLM: true) == .apple)
    check("mode: the old on/off switch is carried over", TranslationMode.saved(nil, legacyUseLLM: true) == .appleLLM
          && TranslationMode.saved(nil, legacyUseLLM: false) == .apple && TranslationMode.saved("nonsense", legacyUseLLM: false) == .apple)
    check("mode: which engines each uses", TranslationMode.llm.usesLLM && !TranslationMode.llm.usesApple && TranslationMode.appleLLM.usesApple
          && TranslationMode.appleLLM.usesLLM && !TranslationMode.apple.usesLLM)
    let q7 = LLMTranslator(); q7.patient = true; let t7 = Tally()
    for n in 1...8 { submit(q7, n, FakeEngine(delay: 0.05), t7) }
    await settle(0.9)
    check("llm only: a burst of sentences is all translated, none skipped", q7.skipped == 0 && q7.translated == 8)
    check("llm only: a sentence may wait longer than its request time limit", q7.queueLimit(8) == 30 && LLMTranslator().queueLimit(8) == 8)
    let q8 = LLMTranslator(); q8.patient = true; let t8 = Tally(); var later = Date(); q8.now = { later }
    for n in 1...3 { submit(q8, n, FakeEngine(delay: 0.02, error: LLMError(kind: .server, message: "boom")), t8); await settle(0.08) }
    later = later.addingTimeInterval(11)
    check("llm only: the pause after failures is short", !q8.isPaused)
    let only = TranscriptStore()
    let l1 = only.update(source: .system, text: "the first finished sentence", isFinal: true)!
    only.setZh(id: l1, zh: "旧的苹果译文", forEn: "the first finished sentence")
    only.clearTranslation(id: l1)
    check("llm only: a leftover Apple translation is removed", only.line(id: l1)?.zh == "")
    only.markUntranslated(id: l1, forEn: "the first finished sentence")
    check("llm only: a sentence without a translation is marked", only.line(id: l1)?.zhMissing == true)
    only.setRefinedZh(id: l1, zh: "第一句", forEn: "the first finished sentence")
    only.markUntranslated(id: l1, forEn: "the first finished sentence")
    check("llm only: a translated sentence is never marked missing", only.line(id: l1)?.zhMissing == false)
    for i in 2...3 { only.update(source: .system, text: "another sentence number \(i)", isFinal: true) }
    check("llm only: the menu bar may show a recent translation", only.recentZh() == "第一句")
    only.update(source: .system, text: "yet another sentence number four", isFinal: true)
    check("llm only: ...but not a stale one", only.recentZh() == "")

    // Live translation (while a sentence is being spoken)
    final class Seen { var shown: [String] = []; var finals: [LLMResult?] = [] }
    func rig(delay: Double = 0.15, error: LLMError? = nil, answer: (@Sendable (TranslationRequest) -> String)? = nil)
        -> (LLMTranslator, FakeEngine, CallLog, Seen) {
        let q = LLMTranslator(); q.patient = true; q.liveSettle = 0.03
        let log = CallLog(); var e = FakeEngine(delay: delay, error: error); e.calls = log; e.answer = answer
        return (q, e, log, Seen())
    }
    func say(_ q: LLMTranslator, _ e: FakeEngine, _ s: Seen, _ line: UUID, _ text: String) {
        q.submitLive(line: line, text: text, engine: e, timeout: 3, request: { TranslationRequest(text: text) }, show: { s.shown.append($0) })
    }
    func finish(_ q: LLMTranslator, _ e: FakeEngine, _ s: Seen, _ line: UUID, _ text: String) {
        q.submit(engine: e, timeout: 3, finishing: (line, text), request: { TranslationRequest(text: text) }, done: { s.finals.append($0) })
    }
    let A = UUID(), B = UUID()
    do {
        let (q, e, log, s) = rig()
        for t in ["we should", "we should lower", "we should lower the rate"] { say(q, e, s, A, t) }
        await settle(0.35)
        check("live: of a burst of updates only the newest is sent", log.texts == ["we should lower the rate"] && s.shown == ["译：we should lower the rate"] && log.live == [true])
    }
    do {
        let (q, e, log, s) = rig()
        say(q, e, s, A, "one two"); await settle(0.07)
        say(q, e, s, A, "one two three"); await settle(0.03); say(q, e, s, A, "one two three four")
        await settle(0.5)
        check("live: a running request is not cut off by newer words; in-between versions are skipped",
              log.texts == ["one two", "one two three four"] && s.shown.count == 2)
    }
    do {
        let (q, e, log, s) = rig(delay: 0.08)
        say(q, e, s, A, "can we ship it today"); await settle(0.25)
        finish(q, e, s, A, "Can we ship it today.")
        check("live: a finished sentence with the same words uses the live result at once",
              s.finals.first??.text == "译：can we ship it today" && log.texts.count == 1 && q.translated == 1)
    }
    do {
        let (q, e, log, s) = rig(delay: 0.2)
        say(q, e, s, A, "we rolled it back"); await settle(0.08)
        finish(q, e, s, A, "We rolled it back.")
        await settle(0.35)
        check("live: ...also when that request is still running (one request, answered once)",
              log.texts.count == 1 && s.finals.count == 1 && s.finals.first??.text == "译：we rolled it back" && s.shown.isEmpty && q.idle)
    }
    do {
        let (q, e, log, s) = rig(delay: 0.2)
        say(q, e, s, A, "if we don't raise"); await settle(0.08)
        finish(q, e, s, A, "If we don't raise money we stop.")
        await settle(0.35)
        check("live: new words interrupt the old request and are translated in full",
              log.texts == ["if we don't raise", "If we don't raise money we stop."] && s.shown.isEmpty
              && s.finals.first??.text == "译：If we don't raise money we stop." && log.live == [true, false])
    }
    do {
        let (q, e, log, s) = rig(delay: 0.08)
        say(q, e, s, A, "you can hear me"); await settle(0.25)
        finish(q, e, s, A, "You can hear me?"); await settle(0.25)
        check("live: a final question mark asks again", log.texts.count == 2)
        check("live: new punctuation inside the sentence asks again (it can change the meaning)",
              !LLMTranslator.canReuse(live: "add more dropout if we wait, we fail", final: "Add more dropout. If we wait, we fail.", translation: "好")
              && !LLMTranslator.canReuse(live: "lets eat grandma", final: "Lets eat, grandma.", translation: "好")
              && LLMTranslator.canReuse(live: "we waited, then  left", final: "We waited, then left.", translation: "好"))
        check("live: reuse rules", LLMTranslator.canReuse(live: "can we go?", final: "Can we go?", translation: "我们能走吗？")
              && LLMTranslator.canReuse(live: "we can go", final: "We can go.", translation: "我们可以走了。")
              && !LLMTranslator.canReuse(live: "we can", final: "We can go.", translation: "我们可以")
              && !LLMTranslator.canReuse(live: "so when we", final: "So when we", translation: "所以当我们……"))
    }
    do {
        let (q, e, log, s) = rig(delay: 0.15, answer: { $0.live ? "所以当我们……" : "所以当我们开始时" })
        say(q, e, s, A, "so when we start"); await settle(0.07)
        finish(q, e, s, A, "So when we start."); await settle(0.45)
        check("live: a result that trails off is not used as the finished translation",
              log.texts.count == 2 && s.finals.count == 1 && s.finals.first??.text == "所以当我们开始时")
    }
    do {
        let (q, e, log, s) = rig(delay: 0.2)
        say(q, e, s, B, "the other speaker talks"); await settle(0.08)
        finish(q, e, s, A, "This sentence is finished."); await settle(0.6)
        check("live: a finished sentence goes first; the other speaker's words follow",
              log.texts == ["the other speaker talks", "This sentence is finished.", "the other speaker talks"] && s.finals.count == 1 && s.shown.count == 1)
    }
    do {
        let (q, e, log, s) = rig(delay: 0.5)
        say(q, e, s, A, "waiting on this one"); await settle(0.08)
        finish(q, e, s, A, "Waiting on this one."); q.cancelAll(); await settle(0.6)
        check("live: cancelling answers a waiting sentence exactly once", s.finals.count == 1 && s.finals.first! == nil && log.texts.count == 1 && q.idle)
    }
    do {
        let (q, e, _, s) = rig(delay: 0.02, error: LLMError(kind: .network, message: "gone"))
        for n in 1...3 { say(q, e, s, A, "word number \(n)"); await settle(0.1) }
        check("live: a dead server pauses live requests too", q.isPaused)
        let (q2, e2, _, s2) = rig(delay: 0.02, error: LLMError(kind: .rejected, message: "odd"))
        for n in 1...4 { say(q2, e2, s2, A, "word number \(n)"); await settle(0.1) }
        check("live: unusable replies to half sentences change nothing", !q2.isPaused && q2.health == .idle)
    }
    StubServer.handler = { _, _ in .init(body: StubServer.chat("Yes, of course.")) }
    do {
        _ = try await ChatCompletionsEngine(config: config(.ollama), client: client, apiKey: { nil })
            .translate(TranslationRequest(text: "hello there my friend", context: ctx, live: true), timeout: 3)
        check("live: no retry for half a sentence", false)
    } catch { check("live: no retry for half a sentence", StubServer.log.count == 1) }
    check("live: local and network models only", config(.ollama).allowsLiveTranslation && config(.custom, url: "http://studio.local/v1").allowsLiveTranslation
          && !config(.openrouter).allowsLiveTranslation && !config(.tinker).allowsLiveTranslation)
    let ls = TranscriptStore()
    let sid = ls.update(source: .system, text: "we are still speaking", isFinal: false)!
    ls.setLiveZh(id: sid, zh: "我们还在说")
    ls.update(source: .system, text: "we are still speaking right now", isFinal: false)
    check("live: shown on the unfinished line and kept while more words arrive", ls.line(id: sid)?.zh == "我们还在说" && ls.line(id: sid)?.zhLive == true)
    ls.update(source: .system, text: "We are still speaking right now.", isFinal: true)
    ls.setLiveZh(id: sid, zh: "迟到的结果")
    check("live: a late live result never lands on a finished line", ls.line(id: sid)?.zh == "我们还在说")
    ls.markUntranslated(id: sid, forEn: "We are still speaking right now.")
    check("live: a partial translation is not kept when the finished one fails", ls.line(id: sid)?.zh == "" && ls.line(id: sid)?.zhMissing == true)

    // Pace of live updates
    let paceStart = Date()
    check("pace: fastest only lets a burst settle", LivePace.spacing(forSetting: 1) == 0
          && LivePace.wait(last: paceStart, spacing: 0, now: paceStart.addingTimeInterval(0.01)) == LivePace.settle)
    check("pace: a slower setting spaces updates; the first one is immediate",
          abs(LivePace.wait(last: paceStart, spacing: LivePace.spacing(forSetting: 3), now: paceStart.addingTimeInterval(1)) - 1.65) < 0.001
          && LivePace.wait(last: nil, spacing: 2.65, now: paceStart) == LivePace.settle
          && LivePace.wait(last: paceStart, spacing: 2.65, now: paceStart.addingTimeInterval(9)) == LivePace.settle)
    do {
        let (q, e, log, s) = rig(delay: 0.02); q.liveSpacing = 0.6
        say(q, e, s, A, "first few words"); await settle(0.15)
        for t in ["first few words and", "first few words and some", "first few words and some more"] { say(q, e, s, A, t); await settle(0.08) }
        let early = log.texts
        say(q, e, s, B, "another speaker starts"); await settle(0.15)
        let withOther = log.texts
        await settle(0.5)
        check("pace: within the interval nothing more is sent for that sentence", early == ["first few words"])
        check("pace: another sentence is not held back by it", withOther == ["first few words", "another speaker starts"])
        check("pace: when due, the newest words are sent", log.texts.last == "first few words and some more" && log.texts.count == 3)
        finish(q, e, s, A, "First few words and some more, then the end."); await settle(0.15)
        check("pace: a finished sentence is never held back", log.texts.count == 4 && s.finals.count == 1)
    }

    // Saving order
    var written: [String] = []
    func writer(_ tag: String) -> (String, LLMResult?) -> Void { { apple, llm in written.append("\(tag):\(llm?.text ?? apple)") } }
    let cq = CommitQueue(delay: 0.2)
    let a = cq.add(expectsLLM: true, write: writer("1"))
    let b = cq.add(expectsLLM: false, write: writer("2"))
    cq.setApple(b, "乙"); cq.setApple(a, "甲"); await settle(0.35)
    check("save: nothing is written while the first sentence waits for the LLM", written.isEmpty)
    cq.setLLM(a, LLMResult(text: "甲+", engineID: "x", milliseconds: 1)); await settle(0.05)
    check("save: written in spoken order, LLM text preferred", written == ["1:甲+", "2:乙"])
    written = []
    let c = cq.add(expectsLLM: true, write: writer("3")); let d = cq.add(expectsLLM: true, write: writer("4"))
    cq.setApple(c, "丙"); cq.setLLM(d, nil)
    cq.flushAll()
    check("save: flushing writes every pending sentence, in order", written == ["3:丙", "4:"] && cq.count == 0)

    var stuck: [String] = []
    let cq2 = CommitQueue(delay: 0.05, maxWait: 0.4)
    _ = cq2.add(expectsLLM: true) { _, _ in stuck.append("never answered") }
    let f2 = cq2.add(expectsLLM: false) { apple, _ in stuck.append(apple) }
    cq2.setApple(f2, "后面一句"); await settle(0.6)
    check("save: a translation that never returns cannot hold back later sentences", stuck == ["never answered", "后面一句"])

    // Store
    let store = TranscriptStore()
    let t0 = Date().addingTimeInterval(-1)
    let one = store.update(source: .system, text: "We build agents for support.", isFinal: true)!
    store.update(source: .mic, text: "completely different words spoken here", isFinal: true)
    let live = store.update(source: .system, text: "still being spoken", isFinal: false)!
    let two = store.update(source: .mic, text: "What about refunds tomorrow morning", isFinal: true)!
    check("context: finished sentences before this one, oldest first",
          store.context(before: two, limit: 3, since: t0).map(\.en) == ["We build agents for support.", "completely different words spoken here"])
    check("context: respects the limit", store.context(before: two, limit: 1, since: t0).map(\.en) == ["completely different words spoken here"])
    check("context: nothing from before this session", store.context(before: two, limit: 3, since: Date().addingTimeInterval(1)).isEmpty && live != one)
    store.setRefinedZh(id: one, zh: "大模型译文", forEn: "We build agents for support.")
    store.setZh(id: one, zh: "苹果译文", forEn: "We build agents for support.")
    check("store: a late Apple translation does not overwrite the LLM's", store.line(id: one)?.zh == "大模型译文" && store.latest?.id == two)
}
#endif
