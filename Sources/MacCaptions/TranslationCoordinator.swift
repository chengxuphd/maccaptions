import Foundation
import Translation

/// Apple on-device en → zh-Hans. Protocol-shaped so other engines (local LLM) can replace it later.
@MainActor
final class TranslationCoordinator {
    private var session: TranslationSession?
    private var pending: [UUID: Task<Void, Never>] = [:]
    private let en = Locale.Language(identifier: "en")
    private let zh = Locale.Language(identifier: "zh-Hans")

    /// Returns an error message if translation can't be used.
    func prepare() async -> String? {
        let status = await LanguageAvailability().status(from: en, to: zh)
        guard status == .installed else {
            return "Translation language pack not installed (status: \(status)). Download English and Chinese (Simplified) in System Settings → General → Language & Region → Translation Languages."
        }
        let s = TranslationSession(installedSource: en, target: zh, preferredStrategy: .lowLatency)
        do { try await s.prepareTranslation() } catch { return "Translation prepare failed: \(error)" }
        session = s
        return nil
    }

    func request(id: UUID, text: String, isFinal: Bool, partialsEnabled: Bool, store: TranscriptStore,
                 onFinal: ((String) -> Void)? = nil) {
        guard session != nil else { if isFinal { onFinal?("") }; return }
        if !isFinal && (!partialsEnabled || text.count < 12) { return }
        if pending.count > 64 {       // lines that vanished (Clear / trimmed) never finalize: drop their leftovers
            for (k, t) in pending where store.line(id: k) == nil { t.cancel(); pending[k] = nil }
        }
        pending[id]?.cancel()
        pending[id] = Task { [weak self] in
            guard let self else { return }
            if !isFinal {
                try? await Task.sleep(for: .milliseconds(500))   // debounce in-progress text
                if Task.isCancelled { return }
            }
            do {
                guard let session = self.session else { return }
                let r = try await session.translate(text)
                if Task.isCancelled && !isFinal { return }
                store.setZh(id: id, zh: r.targetText, forEn: text)
                if isFinal { onFinal?(r.targetText) }
            } catch { if isFinal { onFinal?("") } }
            if isFinal { self.pending[id] = nil }
        }
    }
}
