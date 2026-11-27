import AppKit
import SwiftUI

struct LLMSettingsView: View {
    @ObservedObject var settings: Settings
    let service: LLMService

    /// The address being typed. It takes effect only on Return, "Apply", or leaving the field, so that no sentence
    /// is ever sent to a half-typed host.
    @State private var serverDraft = ""
    @State private var serverDraftProvider = LLMProvider.ollama
    @FocusState private var serverFocused: Bool
    @State private var keyDraft = ""
    @State private var keySaved = false
    @State private var keyMessage = ""
    @State private var models: [String] = []
    @State private var modelMessage = ""
    @State private var testResult = ""
    @State private var testFailed = false
    @State private var busy = false

    private var endpoint: Result<LLMEndpoint, Error> { Result { try LLMEndpoint.parse(settings.llmProfile.baseURL) } }
    private var keyAccount: String? {
        (try? endpoint.get()).map { KeychainStore.account(provider: settings.llmProvider, endpoint: $0) }
    }
    private var serverEdited: Bool { serverDraftProvider == settings.llmProvider && serverDraft != settings.llmProfile.baseURL }

    /// Bound to the provider shown when the field was drawn, so a late commit can't land in another provider.
    private func profile<T>(_ keyPath: WritableKeyPath<LLMProfile, T>) -> Binding<T> {
        let provider = settings.llmProvider
        return Binding(get: { (settings.llmProfiles[provider.rawValue] ?? .defaults(for: provider))[keyPath: keyPath] },
                       set: {
                           var p = settings.llmProfiles[provider.rawValue] ?? .defaults(for: provider)
                           p[keyPath: keyPath] = $0
                           settings.llmProfiles[provider.rawValue] = p
                       })
    }

    private func loadServerDraft() {
        serverDraftProvider = settings.llmProvider
        serverDraft = settings.llmProfile.baseURL
    }

    private func applyServer() {
        guard serverEdited else { return }
        var p = settings.llmProfile; p.baseURL = serverDraft; settings.llmProfile = p
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Translation").font(.headline)
                    Picker("", selection: $settings.translationMode) {
                        ForEach(TranslationMode.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                Text(modeExplanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                GroupBox("Service") { serviceBox.padding(6) }
                GroupBox("Context") { contextBox.padding(6) }
                GroupBox("Test") { testBox.padding(6) }
                GroupBox("Advanced") { advancedBox.padding(6) }
            }
            .padding(16)
        }
        .frame(minWidth: 580, minHeight: 720)
        .onAppear { loadServerDraft(); refreshKeyState() }
        .onChange(of: settings.llmProvider) { _, _ in
            keyDraft = ""; keyMessage = ""; models = []; modelMessage = ""; testResult = ""
            loadServerDraft(); refreshKeyState()
        }
        .onChange(of: settings.llmProfile.baseURL) { _, _ in
            keyMessage = ""; models = []; modelMessage = ""; testResult = ""
            loadServerDraft(); refreshKeyState()
        }
    }

    private var modeExplanation: String {
        switch settings.translationMode {
        case .apple:
            "Apple's on-device translation only. The LLM settings below are not used (you can still set up and test them)."
        case .appleLLM:
            "Apple's translation appears first. The LLM's translation replaces it when it arrives. If the LLM is slow, fails or replies with something that isn't a translation, Apple's stays."
        case .llm:
            "The Chinese comes only from the LLM. A local model also translates while a sentence is being spoken (“Translate live text” in the panel); a cloud service is sent finished sentences only. If the LLM fails or falls too far behind, that sentence shows “—” and is saved without a translation."
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).frame(width: 90, alignment: .leading)
            content()
        }
    }

    private var serviceBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Provider") {
                Picker("", selection: $settings.llmProvider) {
                    ForEach(LLMProvider.allCases) { Text($0.label).tag($0) }
                }.labelsHidden()
            }
            Text(settings.llmProvider.help).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            row("Server") {
                TextField("https://…/v1", text: $serverDraft).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    .focused($serverFocused)
                    .onSubmit { applyServer() }
                    .onChange(of: serverFocused) { _, focused in if !focused { applyServer() } }
                if serverEdited { Button("Apply") { applyServer() } }
                Button("Default") { var p = settings.llmProfile; p.baseURL = settings.llmProvider.defaultBaseURL; settings.llmProfile = p }
                    .disabled(settings.llmProvider.defaultBaseURL.isEmpty)
            }
            if serverEdited {
                Text("Not applied yet: press Return or Apply. Until then the previous address is used.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            privacyNote
            row("API key") {
                SecureField(keySaved ? "saved in your Keychain" : (settings.llmProvider.needsAPIKey ? "required" : "usually not needed"),
                            text: $keyDraft)
                    .textFieldStyle(.roundedBorder).onSubmit { saveKey() }
                Button("Save") { saveKey() }.disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || keyAccount == nil)
                Button("Remove") { removeKey() }.disabled(!keySaved)
            }
            Text(keyMessage.isEmpty
                 ? "The key is stored in the macOS Keychain and sent only to this server. After an app update, macOS may ask once for your password to use it: choose Always Allow."
                 : keyMessage)
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            row("Model") {
                TextField(settings.llmProvider.modelHint, text: profile(\.model)).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                if !models.isEmpty {
                    Menu("Choose") {
                        ForEach(models.prefix(400), id: \.self) { m in
                            Button(m) { var p = settings.llmProfile; p.model = m; settings.llmProfile = p }
                        }
                    }.fixedSize()
                }
                Button("List models") { listModels() }.disabled(busy)
            }
            if !modelMessage.isEmpty {
                Text(modelMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var privacyNote: some View {
        switch endpoint {
        case .failure(let error):
            Label(String(describing: error), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        case .success(let e) where e.scope == .internet:
            Label("Cloud service: the text of every finished sentence (from system audio and your microphone), the context sentences, your topic notes and matching glossary terms are sent to \(e.hostAndPort). Audio is never sent. The provider's terms and charges apply.",
                  systemImage: "icloud.and.arrow.up")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .success(let e):
            Label("Text stays on \(e.destination).", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var contextBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper("Earlier sentences sent as context: \(settings.llmContextCount)", value: $settings.llmContextCount, in: 0...10)
            Text("About this conversation (optional): topic, field, names")
            editor($settings.llmTopic, height: 54, placeholder: "e.g. A research meeting about AI agents and large language models.")
            Text("Glossary (optional): one term per line, English = 中文")
            editor($settings.llmGlossary, height: 78, placeholder: "agent = 智能体\ntake it offline = 会后再聊")
            Text("A term is sent only when it appears in the current or an earlier sentence.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func editor(_ text: Binding<String>, height: CGFloat, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text).font(.body).scrollContentBackground(.hidden).padding(4)
            if text.wrappedValue.isEmpty {
                Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
    }

    private var testBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Test translation") { runTest() }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text("Sends two made-up sentences: “\(Self.sampleContext.en)” as context, then “\(Self.sampleText)”")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !testResult.isEmpty {
                Text(testResult).foregroundStyle(testFailed ? Color.orange : Color.primary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var advancedBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Time limit") {
                Slider(value: $settings.llmTimeout, in: 2...30, step: 1)
                Text("\(Int(settings.llmTimeout)) s").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            row("Prompt") {
                Picker("", selection: profile(\.promptStyle)) {
                    ForEach(PromptStyle.allCases) { Text($0.label).tag($0) }
                }.labelsHidden()
            }
            Toggle("Turn off model “thinking” (recommended: it is far too slow for captions)", isOn: profile(\.disableThinking))
            Text("Extra request JSON (merged into each request; a null value removes a field)")
            editor(profile(\.extraJSON), height: 48, placeholder: "{\"temperature\": 0.5}")
        }
    }

    // MARK: Actions

    private func refreshKeyState() {
        guard let account = keyAccount else { keySaved = false; return }
        Task {
            let saved = await Task.detached { KeychainStore.exists(account) }.value
            if account == keyAccount { keySaved = saved }
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let account = keyAccount else { return }
        do {
            try KeychainStore.save(key, account: account)
            keyDraft = ""; keyMessage = "Saved in your Keychain for \(account.split(separator: "@").last.map(String.init) ?? "this server")."
        } catch { keyMessage = "\(error)" }
        keyChanged()
    }

    private func removeKey() {
        guard let account = keyAccount else { return }
        do { try KeychainStore.delete(account); keyMessage = "Key removed." } catch { keyMessage = "\(error)" }
        keyChanged()
    }

    private func keyChanged() {
        refreshKeyState()
        Task { await service.clearKeyCache() }
        settings.llmKeyVersion += 1
        // Nudges the live translator to stop resting after an "API key refused" pause.
        let p = settings.llmProfile; settings.llmProfile = p
    }

    private func listModels() {
        applyServer()
        let config = settings.llmConfig
        busy = true; modelMessage = "Asking the server…"
        Task {
            await service.clearKeyCache()
            do {
                let list = try await service.listModels(for: config)
                if isCurrent(config) {
                    models = list
                    modelMessage = list.isEmpty ? "The server reports no models." : "\(list.count) models. Pick one with “Choose”."
                }
            } catch { if isCurrent(config) { modelMessage = "Could not list models: \(error). You can still type the name." } }
            busy = false
        }
    }

    /// An answer is shown only if provider and address are still the ones that were asked.
    private func isCurrent(_ config: LLMConfig) -> Bool {
        settings.llmProvider == config.provider && settings.llmProfile.baseURL == config.profile.baseURL
    }

    static let sampleContext = ContextLine(speaker: "Them", en: "We have been building AI agents for customer support.")
    static let sampleText = "Let's circle back on how those agents handle refunds after the review."

    private func runTest() {
        applyServer()
        let config = settings.llmConfig
        busy = true; testFailed = false; testResult = "Waiting for the model (the first request can take a while)…"
        Task {
            await service.clearKeyCache()
            let began = Date()
            do {
                let request = TranslationRequest(text: Self.sampleText, context: config.contextCount > 0 ? [Self.sampleContext] : [])
                let r = try await service.engine(for: config).translate(request, timeout: 90)
                let seconds = Date().timeIntervalSince(began)
                var s = "\(r.text)\n\(String(format: "%.1f", seconds)) s"
                if r.tokens > 0 { s += " · \(r.tokens) tokens" }
                let dropped = service.client.droppedFields(for: config)
                if !dropped.isEmpty { s += " · the server refused \(dropped.joined(separator: ", ")), so it was left out" }
                if seconds > config.timeout { s += "\n⚠︎ Slower than the time limit (\(Int(config.timeout)) s). Try again; if it stays slow, use a smaller model." }
                if settings.llmConfig.destinationID == config.destinationID { testResult = s; testFailed = seconds > config.timeout }
            } catch {
                if settings.llmConfig.destinationID == config.destinationID { testFailed = true; testResult = "Failed: \(error)" }
            }
            busy = false
        }
    }
}
