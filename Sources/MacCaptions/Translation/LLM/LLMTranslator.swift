import Foundation

/// Runs the LLM translations.
///
/// Rules that keep live captions healthy:
/// * Any job may fail (Apple's translation then stays, or in "LLM" mode the sentence is marked untranslated) — but
///   every job reports back exactly once.
/// * A local model handles one sentence at a time. When it falls behind, the oldest waiting sentences are skipped.
/// * Sentences still being spoken can be translated too ("live", used in "LLM" mode with a local model): only the
///   newest words, one request at a time, only when the model is free. A finished sentence always goes first, and
///   takes over a live result for the same words instead of asking again.
/// * Waiting and running jobs both have deadlines (so a hung model can never hold back the saved transcript),
///   and after repeated failures the LLM is rested for a while instead of being hammered.
@MainActor
final class LLMTranslator: ObservableObject {
    enum Health: Equatable {
        case idle                 // nothing has happened yet
        case warmingUp
        case ok
        case trouble(String)      // the last request failed; still trying
        case paused(String)       // resting after failures
    }

    @Published private(set) var health: Health = .idle
    @Published private(set) var translated = 0
    @Published private(set) var skipped = 0
    @Published private(set) var lastMilliseconds = 0
    @Published private(set) var totalTokens = 0

    private struct Job {
        let id: Int
        let queued: Date
        let engine: any TranslationEngine
        let timeout: TimeInterval
        let request: () -> TranslationRequest?        // built when the job starts; nil → no longer wanted
        let done: (LLMResult?) -> Void
    }

    private var waiting: [Job] = []
    private var running: [Int: (task: Task<Void, Never>, watchdog: Task<Void, Never>, done: (LLMResult?) -> Void)] = [:]
    /// Extra time a running job gets beyond its own limit before the queue gives up on it. It covers anything the
    /// engine's limit doesn't, such as a Keychain password prompt left open.
    var watchdogGrace: TimeInterval = 3
    private var nextID = 0
    private var failuresInARow = 0
    private var pausedUntil = Date.distantPast
    private var generation = 0
    var maxConcurrent = 1
    /// "LLM" mode has no Apple translation to fall back on, so a late answer beats none: more sentences may wait,
    /// and for longer, and a pause after failures is shorter.
    var patient = false
    var maxWaiting: Int { patient ? 8 : 3 }
    /// How long a sentence may wait for its turn. It also delays saving the transcript, so it stays well inside
    /// CommitQueue's last-resort limit even with the longest request time limit added.
    func queueLimit(_ timeout: TimeInterval) -> TimeInterval { patient ? 30 : min(timeout, 10) }
    var now: () -> Date = { Date() }                  // replaced by the self-tests

    private struct LiveJob {
        let line: UUID
        let text: String
        let engine: any TranslationEngine
        let timeout: TimeInterval
        let request: () -> TranslationRequest?
        let show: (String) -> Void
    }
    /// A finished sentence waiting for the live request that is already translating its words.
    private struct Adopter {
        let use: (LLMResult) -> Void
        let redo: () -> Void                          // the live request failed: translate the normal way
        let abandon: () -> Void
    }
    private var liveWanted: [LiveJob] = []            // newest text of each unfinished sentence, latest change last
    private var liveCurrent: (token: Int, job: LiveJob, task: Task<Void, Never>, watchdog: Task<Void, Never>)?
    private var adopter: Adopter?
    private var liveFinished: [UUID: (text: String, translation: String)] = [:]
    /// The recognizer reports a burst of updates at once; wait this long so only the last one is sent.
    var liveSettle: TimeInterval = LivePace.settle
    /// The least time between two live requests for the same sentence (the "live update every …" setting).
    var liveSpacing: TimeInterval = 0
    private var liveStarted: [UUID: Date] = [:]
    private var liveTimer: Task<Void, Never>?

    var idle: Bool { waiting.isEmpty && running.isEmpty && adopter == nil }
    var isPaused: Bool { now() < pausedUntil }

    /// New session or new settings: forget failures and counters.
    func reset() {
        cancelAll()
        failuresInARow = 0; pausedUntil = .distantPast
        translated = 0; skipped = 0; lastMilliseconds = 0; totalTokens = 0
        health = .idle
    }

    /// The user changed the provider or its settings: stop resting and try again with the next sentence.
    func configurationChanged(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
        failuresInARow = 0; pausedUntil = .distantPast
        if health != .warmingUp { health = .idle }
    }

    /// Resolves every outstanding job with nil.
    func cancelAll() {
        generation += 1
        let r = running, w = waiting, a = adopter
        running = [:]; waiting = []; adopter = nil
        stopLive()
        liveWanted = []; liveFinished = [:]; liveStarted = [:]
        liveTimer?.cancel(); liveTimer = nil
        a?.abandon()
        for (_, entry) in r { entry.task.cancel(); entry.watchdog.cancel(); entry.done(nil) }
        for job in w { job.done(nil) }
    }

    /// Loads a local model before the first real sentence, and surfaces a wrong key or address right away.
    func warmUp(_ engine: any TranslationEngine, timeout: TimeInterval = 90) {
        guard idle else { return }
        health = .warmingUp
        start(Job(id: newID(), queued: now(), engine: engine, timeout: timeout,
                  request: { TranslationRequest(text: "Good morning, everyone.") }, done: { _ in }), isWarmUp: true)
    }

    /// Translate a finished sentence. `finishing` names the sentence and its final words, so that a live translation
    /// of the same words can be used.
    func submit(engine: any TranslationEngine, timeout: TimeInterval, finishing: (line: UUID, text: String)? = nil,
                request: @escaping () -> TranslationRequest?, done: @escaping (LLMResult?) -> Void) {
        if let finishing {
            liveWanted.removeAll { $0.line == finishing.line }
            let earlier = liveFinished.removeValue(forKey: finishing.line)
            let running = liveCurrent.flatMap { $0.job.line == finishing.line ? $0.job : nil }
            let sameDone = earlier.map { Self.canReuse(live: $0.text, final: finishing.text, translation: $0.translation) } ?? false
            let sameRunning = adopter == nil && (running.map { Self.canReuse(live: $0.text, final: finishing.text, translation: nil) } ?? false)
            if (sameDone || sameRunning) && request() == nil { done(nil); return }      // no longer wanted (an echo)
            if sameDone, let earlier {
                translated += 1; lastMilliseconds = 0
                done(LLMResult(text: earlier.translation, engineID: engine.id, milliseconds: 0))
                pumpLive()
                return
            }
            if sameRunning {
                adopter = Adopter(
                    use: { [weak self] result in self?.translated += 1; self?.lastMilliseconds = result.milliseconds; done(result) },
                    redo: { [weak self] in self?.enqueue(engine: engine, timeout: timeout, request: request, done: done) },
                    abandon: { done(nil) })
                return
            }
            // Live work on this sentence's older words is now pointless: stop it, and don't queue it again.
            if running != nil && adopter == nil { stopLive() }
        }
        enqueue(engine: engine, timeout: timeout, request: request, done: done)
    }

    private func enqueue(engine: any TranslationEngine, timeout: TimeInterval,
                         request: @escaping () -> TranslationRequest?, done: @escaping (LLMResult?) -> Void) {
        if isPaused { skipped += 1; done(nil); return }
        interruptLive()                               // a finished sentence goes first
        let id = newID()
        waiting.append(Job(id: id, queued: now(), engine: engine, timeout: timeout, request: request, done: done))
        Task { [weak self] in
            guard let limit = self?.queueLimit(timeout) else { return }
            try? await Task.sleep(for: .seconds(limit))
            self?.expireWaiting(id)
        }
        while waiting.count > maxWaiting {            // falling behind: the oldest sentence keeps Apple's translation
            skipped += 1
            waiting.removeFirst().done(nil)
        }
        pump()
    }

    private func newID() -> Int { nextID += 1; return nextID }

    /// A sentence that could not even start within the time limit keeps Apple's translation.
    private func expireWaiting(_ id: Int) {
        guard let i = waiting.firstIndex(where: { $0.id == id }) else { return }
        skipped += 1
        waiting.remove(at: i).done(nil)
    }

    private func giveUp(on job: Job, isWarmUp: Bool) {
        guard let entry = running.removeValue(forKey: job.id) else { return }
        entry.task.cancel()
        if !isWarmUp { skipped += 1 }
        record(failure: LLMError(kind: .timeout, message: "no answer within the time limit"), isWarmUp: isWarmUp)
        entry.done(nil)
        pump()
        pumpLive()
    }

    // MARK: - Live translation (sentences still being spoken)

    /// Offers the newest words of an unfinished sentence. `show` receives a translation if one gets made.
    func submitLive(line: UUID, text: String, engine: any TranslationEngine, timeout: TimeInterval,
                    request: @escaping () -> TranslationRequest?, show: @escaping (String) -> Void) {
        if isPaused { return }
        if let c = liveCurrent, c.job.line == line, c.job.text == text { return }
        if liveFinished[line]?.text == text { return }
        liveWanted.removeAll { $0.line == line }
        liveWanted.append(LiveJob(line: line, text: text, engine: engine, timeout: min(timeout, 6), request: request, show: show))
        if liveWanted.count > 4 { liveWanted.removeFirst() }
        Task { [weak self] in
            guard let settle = self?.liveSettle else { return }
            try? await Task.sleep(for: .seconds(settle))
            self?.pumpLive()
        }
    }

    /// Live translation was switched off: drop it, without touching finished sentences.
    func cancelLive() {
        liveWanted = []; liveFinished = [:]
        if adopter == nil { stopLive() }
    }

    private func stopLive() {
        liveCurrent?.task.cancel(); liveCurrent?.watchdog.cancel(); liveCurrent = nil
    }

    private func interruptLive() {
        guard adopter == nil, let c = liveCurrent else { return }
        stopLive()
        // Words from another speaker are still wanted once the finished sentence is done.
        if !liveWanted.contains(where: { $0.line == c.job.line }) { liveWanted.insert(c.job, at: 0) }
    }

    /// Seconds until this sentence may be sent again.
    private func liveDue(_ line: UUID) -> TimeInterval {
        liveStarted[line].map { liveSpacing - Date().timeIntervalSince($0) } ?? 0
    }

    private func pumpLive() {
        guard liveCurrent == nil, adopter == nil, running.isEmpty, waiting.isEmpty, !isPaused, !liveWanted.isEmpty else { return }
        // The most recently changed sentence that is due; if none is yet, come back when the first one will be.
        guard let index = liveWanted.lastIndex(where: { liveDue($0.line) <= 0.01 }) else {
            let soonest = liveWanted.map { liveDue($0.line) }.min() ?? 0
            liveTimer?.cancel()
            liveTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(soonest))
                if !Task.isCancelled { self?.pumpLive() }
            }
            return
        }
        let job = liveWanted.remove(at: index)
        guard var request = job.request() else { pumpLive(); return }
        request.live = true
        if liveStarted.count > 16 { liveStarted = [:] }
        liveStarted[job.line] = Date()
        let token = newID(), sent = request
        let task = Task { [weak self] in
            let began = Date()
            let outcome: Result<(text: String, tokens: Int), Error>
            do { outcome = .success(try await job.engine.translate(sent, timeout: job.timeout)) }
            catch { outcome = .failure(error) }
            self?.liveEnded(token, outcome, milliseconds: Int(Date().timeIntervalSince(began) * 1000))
        }
        let limit = job.timeout + watchdogGrace
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            if !Task.isCancelled {
                self?.liveEnded(token, .failure(LLMError(kind: .timeout, message: "no answer within the time limit")), milliseconds: 0)
            }
        }
        liveCurrent = (token, job, task, watchdog)
    }

    private func liveEnded(_ token: Int, _ outcome: Result<(text: String, tokens: Int), Error>, milliseconds: Int) {
        guard let current = liveCurrent, current.token == token else { return }     // interrupted or cancelled
        current.task.cancel(); current.watchdog.cancel(); liveCurrent = nil
        let waitingSentence = adopter; adopter = nil
        switch outcome {
        case .success(let r):
            failuresInARow = 0; totalTokens += r.tokens; health = .ok
            if let waitingSentence {
                if Self.looksUnfinished(r.text) { waitingSentence.redo() }
                else { waitingSentence.use(LLMResult(text: r.text, engineID: current.job.engine.id, milliseconds: milliseconds)) }
            } else {
                liveFinished[current.job.line] = (current.job.text, r.text)
                if liveFinished.count > 8 { liveFinished = [current.job.line: (current.job.text, r.text)] }
                current.job.show(r.text)
            }
        case .failure(let error):
            // An unusable reply to half a sentence says nothing about the model; a dead or refusing server does.
            if (error as? LLMError)?.kind != .rejected { record(failure: error, isWarmUp: false) }
            waitingSentence?.redo()
        }
        pump()
        pumpLive()
    }

    private static func looksUnfinished(_ translation: String) -> Bool {
        translation.hasSuffix("…") || translation.hasSuffix("...")
    }

    /// May a translation of `live` stand for the finished sentence `final`? Only if the finished text is the same, give
    /// or take capitals and a closing full stop, and (when already known) the translation doesn't trail off.
    /// Punctuation matters: the recognizer sets it when it finishes, and "…add dropout if we don't…" read as one
    /// sentence turned out to be "…add dropout. If we don't…", which means something else.
    static func canReuse(live: String, final: String, translation: String?) -> Bool {
        func key(_ s: String) -> String {
            var t = s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if t.hasSuffix(".") && !t.hasSuffix("..") { t.removeLast() }
            return t
        }
        guard key(live) == key(final) else { return false }
        return translation.map { !looksUnfinished($0) } ?? true
    }

    private func pump() {
        // A live request that a finished sentence is waiting for occupies a slot like any other.
        while running.count + (adopter == nil ? 0 : 1) < maxConcurrent, !waiting.isEmpty {
            let job = waiting.removeFirst()
            if isPaused || now().timeIntervalSince(job.queued) > queueLimit(job.timeout) { skipped += 1; job.done(nil); continue }
            start(job, isWarmUp: false)
        }
    }

    private func start(_ job: Job, isWarmUp: Bool) {
        guard let request = job.request() else { job.done(nil); return }
        let gen = generation
        let task = Task { [weak self] in
            let began = Date()
            let outcome: Result<(text: String, tokens: Int), Error>
            do { outcome = .success(try await job.engine.translate(request, timeout: job.timeout)) }
            catch { outcome = .failure(error) }
            guard let self, gen == self.generation,
                  let entry = self.running.removeValue(forKey: job.id) else { return }   // cancelled or given up: already resolved
            entry.watchdog.cancel()
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            switch outcome {
            case .success(let r):
                self.failuresInARow = 0
                self.totalTokens += r.tokens
                self.health = .ok
                if !isWarmUp { self.translated += 1; self.lastMilliseconds = ms }
                job.done(isWarmUp ? nil : LLMResult(text: r.text, engineID: job.engine.id, milliseconds: ms))
            case .failure(let error):
                if !isWarmUp { self.skipped += 1 }
                self.record(failure: error, isWarmUp: isWarmUp)
                job.done(nil)
            }
            self.pump()
            self.pumpLive()
        }
        let limit = job.timeout + watchdogGrace
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            if !Task.isCancelled { self?.giveUp(on: job, isWarmUp: isWarmUp) }
        }
        running[job.id] = (task, watchdog, job.done)
    }

    private func record(failure error: Error, isWarmUp: Bool) {
        if error is CancellationError { return }
        let e = error as? LLMError ?? LLMError(kind: .network, message: "\(error)")
        if e.kind == .rejected {                      // the server works; this one reply was unusable
            health = .trouble(e.message)
            return
        }
        failuresInARow += 1
        let pause: TimeInterval
        if e.needsUserAction { pause = 60 }
        else if e.kind == .rateLimited { pause = min(max(e.retryAfter ?? 20, 2), 120) }
        else if failuresInARow >= 3 { pause = patient ? 10 : 30 }
        else { pause = 0 }
        if pause > 0 {
            pausedUntil = now().addingTimeInterval(pause)
            health = .paused(e.message)
            let w = waiting; waiting = []
            liveWanted = []
            skipped += w.count
            for job in w { job.done(nil) }
        } else {
            health = .trouble(e.message)
        }
    }
}
