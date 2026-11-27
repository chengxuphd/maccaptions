import Foundation
import Translation

/// Apple's on-device en → zh-Hans translation. In the "Apple" and "Apple + LLM" modes it is what appears first, and
/// what stays when the optional LLM (see LLM/) is off, slow or wrong. The "LLM" mode does not use it.
@MainActor
final class TranslationCoordinator {
    private var session: TranslationSession?
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var lastLive: [UUID: Date] = [:]          // when each unfinished sentence was last translated
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
                 liveSpacing: TimeInterval = 0, onFinal: ((String) -> Void)? = nil) {
        guard session != nil else { if isFinal { onFinal?("") }; return }
        if !isFinal && (!partialsEnabled || text.count < 12) { return }
        if pending.count > 64 {       // lines that vanished (Clear / trimmed) never finalize: drop their leftovers
            for (k, t) in pending where store.line(id: k) == nil { t.cancel(); pending[k] = nil; lastLive[k] = nil }
        }
        pending[id]?.cancel()
        pending[id] = Task { [weak self] in
            guard let self else { return }
            if !isFinal {
                // Newer text replaces this task, and it aims for the same moment, so the latest words are what get sent.
                let wait = LivePace.wait(last: self.lastLive[id], spacing: liveSpacing, now: Date())
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
                self.lastLive[id] = Date()
            }
            do {
                guard let session = self.session else { return }
                let r = try await session.translate(text)
                if Task.isCancelled && !isFinal { return }
                #if DEVTOOLS
                if !isFinal { PerfHarness.timeline("APPLEZH", text) }
                #endif
                store.setZh(id: id, zh: r.targetText, forEn: text)
                if isFinal { onFinal?(r.targetText) }
            } catch { if isFinal { onFinal?("") } }
            if isFinal { self.pending[id] = nil; self.lastLive[id] = nil }
        }
    }
}
