import AppKit
import SwiftUI

/// The panel's "Translation" section: which engine is used, where sentences are sent, and whether the LLM is working.
struct TranslationBar: View {
    @ObservedObject var settings: Settings
    @ObservedObject var llm: LLMTranslator
    @State private var keyMissing = false

    /// The Keychain item this setup needs, if it needs one.
    private var requiredAccount: String? {
        guard settings.useLLM, settings.llmProvider.needsAPIKey,
              let endpoint = try? LLMEndpoint.parse(settings.llmProfile.baseURL) else { return nil }
        return KeychainStore.account(provider: settings.llmProvider, endpoint: endpoint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Translation").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Picker("", selection: $settings.translationMode) {
                    ForEach(TranslationMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Button("Set") { LLMSettingsWindowController.shared.show() }
                    .help("LLM settings: provider, model, context and glossary")
            }
            if settings.useLLM {
                let line = status
                Text(line.text).font(.caption).foregroundStyle(line.warning ? Color.orange : .secondary)
                    .lineLimit(2).help(line.text)
            }
        }
        // Asked away from the main thread: the Keychain can be busy while macOS shows a prompt.
        .task(id: "\(requiredAccount ?? "")#\(settings.llmKeyVersion)") {
            guard let account = requiredAccount else { keyMissing = false; return }
            keyMissing = !(await Task.detached { KeychainStore.exists(account) }.value)
        }
    }

    private var status: (text: String, warning: Bool) {
        let config = settings.llmConfig
        let endpoint: LLMEndpoint
        do { endpoint = try LLMEndpoint.parse(config.profile.baseURL) }
        catch { return ("LLM is not set up: \(error)", true) }
        if config.profile.model.trimmingCharacters(in: .whitespaces).isEmpty { return ("No model chosen. Press Set.", true) }
        if keyMissing {
            return ("No API key for \(endpoint.host). Press Set to add one.", true)
        }
        let name = config.profile.model
        let online = endpoint.scope == .internet
        let place = online ? "☁︎ sentences are sent to \(endpoint.hostAndPort)" : "on \(endpoint.destination)"
        let only = settings.translationMode == .llm
        let fallback = only ? "No translation right now" : "Showing Apple's translation"
        switch llm.health {
        case .idle: return ("\(name) · \(place)", online)          // orange: a reminder that text leaves this Mac
        case .warmingUp: return ("\(name) · \(place) · getting ready…", online)
        case .ok:
            var s = "\(name) · \(place)"
            if llm.translated > 0 { s += " · last \(String(format: "%.1f", Double(llm.lastMilliseconds) / 1000)) s · \(llm.translated) done" }
            if llm.skipped > 0 { s += only ? " · \(llm.skipped) not translated" : " · \(llm.skipped) kept Apple's" }
            if llm.totalTokens > 0 { s += " · \(llm.totalTokens) tokens" }
            return (s, online)
        case .trouble(let why): return ("\(fallback) — \(name): \(why)", true)
        case .paused(let why): return ("LLM paused for a moment. \(fallback) — \(why)", true)
        }
    }
}
