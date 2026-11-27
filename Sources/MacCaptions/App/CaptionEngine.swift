import Foundation
import AVFoundation
import Combine

@MainActor
final class CaptionEngine: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "Idle"

    let store = TranscriptStore()
    let recorder = SessionRecorder()
    let settings = Settings.shared
    private let translator = TranslationCoordinator()
    private var appleReady = false             // Apple's translator is prepared (not needed in LLM-only mode)
    private var lastMode = Settings.shared.translationMode
    /// The optional LLM: improves Apple's translation, or in "LLM" mode replaces it.
    let llm = LLMTranslator()
    let llmService = LLMService()
    var micPipeline: CaptionPipeline?
    var sysPipeline: CaptionPipeline?
    #if DEVTOOLS
    var feedMode = false          // test harness: don't open real capture devices
    #else
    let feedMode = false
    #endif
    private var micCapture: MicCapture?
    private var tap: SystemAudioTap?
    private var busy = false          // start() or stop() is in progress
    private var stopping = false      // set for the whole stop(): source/recording switches are ignored meanwhile
    private var stopTask: Task<Void, Never>?
    private var recorderObserver: Any?
    private var lastDeviceRestart = [Source: Date]()
    /// Finished sentences waiting to be written to disk, in the order they were spoken. Each waits at least 2.5 s so
    /// the echo filter can see the matching system audio (it arrives ~1 s later).
    private let commits = CommitQueue(delay: 2.5)
    private var sessionBegan = Date()
    private var bag = Set<AnyCancellable>()

    /// Status line shown in the UI, including any saving problem.
    var displayStatus: String { recorder.lastError.map { status + " · ⚠ " + $0 } ?? status }

    init() {
        recorderObserver = recorder.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        observeLLMSettings()
    }

    /// LLM settings can change at any moment; they apply from the next finished sentence.
    private func observeLLMSettings() {
        llm.patient = settings.translationMode == .llm
        settings.$partialTranslation.dropFirst().removeDuplicates().receive(on: RunLoop.main).sink { [weak self] on in
            if !on { self?.llm.cancelLive() }
        }.store(in: &bag)
        settings.$translationMode.dropFirst().removeDuplicates().receive(on: RunLoop.main).sink { [weak self] mode in
            self?.modeChanged(to: mode)
        }.store(in: &bag)
        // A new provider, address or model: sentences still waiting for the OLD one must not be sent there any more,
        // and its late errors must not count against the new one.
        Publishers.CombineLatest(settings.$llmProvider, settings.$llmProfiles)
            .map { provider, profiles in LLMConfig(provider: provider, profile: profiles[provider.rawValue] ?? .defaults(for: provider)).destinationID }
            .removeDuplicates().dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.llm.cancelAll() }
            .store(in: &bag)
        settings.$llmProvider.dropFirst().map { _ in () }
            .merge(with: settings.$llmProfiles.dropFirst().map { _ in () })
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.llmService.settingsChanged()
                self.llm.configurationChanged(maxConcurrent: LLMService.concurrency(for: self.settings.llmConfig))
            }.store(in: &bag)
    }

    private func modeChanged(to mode: TranslationMode) {
        let was = lastMode; lastMode = mode
        llm.patient = mode == .llm
        if mode != .llm { llm.cancelLive() }
        if !mode.usesLLM { llm.reset() } else if !was.usesLLM { prepareLLM() }
        // A session started in LLM-only mode may not have Apple's translator ready yet.
        if mode.usesApple && running && !appleReady {
            Task {
                if let error = await translator.prepare() { status = error } else { appleReady = true }
            }
        }
    }

    /// Called when captions start and when the LLM is switched on during a session.
    private func prepareLLM() {
        llm.reset()
        llmService.settingsChanged()
        guard settings.useLLM, running else { return }
        let config = settings.llmConfig
        llm.maxConcurrent = LLMService.concurrency(for: config)
        llm.warmUp(llmService.engine(for: config))
    }

    func toggle() { Task { running ? await stop() : await start() } }

    // MARK: Start / stop

    func start() async {
        guard !running, !busy else { return }
        busy = true; defer { busy = false }
        status = "Starting…"
        let appleError = await translator.prepare()
        appleReady = appleError == nil
        if let appleError, settings.translationMode.usesApple { status = appleError; return }   // "LLM" mode doesn't need it
        var allowed = feedMode                                   // the test file feed never opens a microphone
        if !allowed { allowed = await AVCaptureDevice.requestAccess(for: .audio) }
        guard allowed else {
            status = "Microphone permission denied (System Settings → Privacy & Security → Microphone)."; return
        }
        var mic: CaptionPipeline?, sys: CaptionPipeline?
        do {
            let locale = Locale(identifier: "en-US")
            mic = try await CaptionPipeline(locale: locale) { [weak self] text, final in self?.handle(.mic, text, final) }
            sys = try await CaptionPipeline(locale: locale) { [weak self] text, final in self?.handle(.system, text, final) }
        } catch {
            status = "Start failed: \(error)"
            await mic?.finish(timeout: 0.5)          // release the first analyzer if the second failed
            return
        }
        guard let mic, let sys else { return }
        micPipeline = mic; sysPipeline = sys
        store.echoFilterEnabled = settings.hideEcho
        // A problem with the save folder must not stop the captions themselves.
        sessionBegan = Date()
        let llmID = settings.llmConfig.engineID
        let engines = switch settings.translationMode {
        case .apple: "apple-translation"
        case .appleLLM: "apple-translation + \(llmID)"
        case .llm: llmID
        }
        do { try recorder.beginSession(echoCancel: settings.echoCancel, translationEngine: engines) }
        catch { recorder.reportError("saving is off — \(error.localizedDescription)") }
        mic.recordTap = { [recorder] in recorder.writer(for: .mic).write($0) }
        sys.recordTap = { [recorder] in recorder.writer(for: .system).write($0) }
        running = true
        applySourceSettings()
        prepareLLM()
    }

    /// Safe to call again while a stop is in progress (e.g. Quit pressed during "Stopping…"): the second caller
    /// waits for the first stop to finish instead of returning early.
    func stop() async {
        if let stopTask { await stopTask.value; return }
        guard running, !busy else { return }
        let task = Task { await performStop() }
        stopTask = task
        await task.value
        stopTask = nil
    }

    private func performStop() async {
        busy = true; stopping = true
        defer { busy = false; stopping = false }
        status = "Stopping…"
        stopCaptures()
        recorder.closeAllTracksForStop()             // file lengths match what was actually captured
        let (m, s) = (micPipeline, sysPipeline)
        await withTaskGroup(of: Void.self) { group in   // finish both recognizers at the same time
            if let m { group.addTask { await m.finish() } }
            if let s { group.addTask { await s.finish() } }
        }
        forceCloseSentence(.mic); forceCloseSentence(.system)
        // Wait until every finished sentence has been translated and written. A slow LLM gets a limited time; after
        // that the sentence is saved with what there is (Apple's translation, or in "LLM" mode the English alone).
        // No sentence is ever dropped.
        let llmDeadline = Date().addingTimeInterval(settings.useLLM ? min(settings.llmTimeout, 8) + 2 : 0)
        let deadline = Date().addingTimeInterval(settings.useLLM ? 12 : 8)
        try? await Task.sleep(for: .milliseconds(300))
        while commits.count > 0 && Date() < deadline {
            if settings.useLLM && Date() >= llmDeadline && !llm.idle { llm.cancelAll() }
            else if settings.useLLM && !llm.idle { status = "Stopping… finishing translations" }
            try? await Task.sleep(for: .milliseconds(100))
        }
        llm.cancelAll()
        commits.flushAll()
        recorder.endSession()
        micPipeline = nil; sysPipeline = nil
        running = false
        status = "Stopped"
    }

    /// Immediate, synchronous shutdown of capture and files (system shutdown / logout).
    func emergencyClose() {
        stopping = true
        stopCaptures()
        llm.cancelAll()
        commits.flushAll()                         // finished sentences still waiting for a translation are saved now
        recorder.endSession()
    }

    private func stopCaptures() {
        micCapture?.stop(); micCapture = nil
        tap?.stop(); tap = nil
    }

    // MARK: Sources & recording (all switchable while running)

    /// Brings the real capture devices in line with the Microphone / System audio switches.
    func applySourceSettings() {
        guard running, !stopping, let mic = micPipeline, let sys = sysPipeline else { return }
        var problems: [String] = []

        if settings.micEnabled, !feedMode, micCapture == nil {
            let m = MicCapture()
            m.onConfigurationChange = { [weak self] in self?.restartCapture(.mic) }
            do { try m.start(echoCancel: settings.echoCancel) { mic.feed($0) }; micCapture = m }
            catch { m.stop(); problems.append("Microphone: \(error)") }
        } else if !settings.micEnabled, let m = micCapture {
            m.stop(); micCapture = nil
            closeSentence(.mic)
        }

        if settings.sysEnabled, !feedMode, tap == nil {
            let t = SystemAudioTap()
            t.onOutputDeviceChange = { [weak self] in self?.restartCapture(.system) }
            do { try t.start { sys.feed($0) }; tap = t }
            catch { problems.append("System audio: \(error)") }
        } else if !settings.sysEnabled, let t = tap {
            t.stop(); tap = nil
            closeSentence(.system)
        }

        syncRecording()

        if !problems.isEmpty { status = problems.joined(separator: " · "); return }
        var parts: [String] = []
        parts.append(micCapture != nil ? "Mic ON" : "Mic off")
        parts.append(tap != nil ? "System ON" : "System off")
        if micCapture != nil && settings.echoCancel { parts.append("echo cancel") }
        status = (micCapture == nil && tap == nil) ? "Both sources are off" : "Listening — " + parts.joined(separator: " · ")
    }

    /// The audio device changed under us (headset connected, default input/output changed, wake from sleep):
    /// the capture has stopped or its format is stale, so tear it down and start it again.
    private func restartCapture(_ source: Source) {
        guard running, !stopping, !busy else { return }
        if let last = lastDeviceRestart[source], Date().timeIntervalSince(last) < 1 { return }   // avoid restart loops
        lastDeviceRestart[source] = Date()
        switch source {
        case .mic:    micCapture?.stop(); micCapture = nil; recorder.closeTrack(.mic)
        case .system: tap?.stop(); tap = nil; recorder.closeTrack(.system)
        }
        applySourceSettings()
    }

    func toggleRecording() {
        settings.recordAudio.toggle()
        syncRecording()
    }

    /// Each track records only while: recording is on AND that source is actually capturing.
    private func syncRecording() {
        guard let mic = micPipeline, let sys = sysPipeline else { return }
        let want = running && !stopping && settings.recordAudio
        for (source, pipe, active) in [(Source.mic, mic, micCapture != nil), (.system, sys, tap != nil || feedMode)] {   // feedMode: test harness feeds the system pipeline
            let on = want && active
            if on && !recorder.isOpen(source) { recorder.openTrack(source, format: pipe.format) }
            if !on && recorder.isOpen(source) { recorder.closeTrack(source) }
        }
    }

    func setEchoFilter(_ on: Bool) { store.echoFilterEnabled = on }

    // MARK: Results

    /// A source was switched off mid-sentence. Ask the recognizer to close that sentence (it then reports the real
    /// final result, so nothing is duplicated); if it never answers, close it ourselves.
    private func closeSentence(_ source: Source) {
        guard store.currentLine(for: source) != nil, let pipe = (source == .mic ? micPipeline : sysPipeline) else { return }
        Task { @MainActor in
            await pipe.flush()
            try? await Task.sleep(for: .milliseconds(1500))
            let stillOff = source == .mic ? !settings.micEnabled : !settings.sysEnabled
            if stillOff { forceCloseSentence(source) }
        }
    }

    private func forceCloseSentence(_ source: Source) {
        if let line = store.currentLine(for: source) { handle(source, line.en, true) }
    }

    private func handle(_ source: Source, _ text: String, _ isFinal: Bool) {
        #if DEVTOOLS
        PerfHarness.timeline(isFinal ? "FINAL" : "PARTIAL", text)
        #endif
        guard let id = store.update(source: source, text: text, isFinal: isFinal) else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = store.line(id: id)
        if !isFinal && line?.isEcho == true { return }            // hidden echo: don't spend a translation on it

        let apple = settings.translationMode.usesApple
        guard isFinal else {                                      // still being spoken
            if apple {
                translator.request(id: id, text: clean, isFinal: false, partialsEnabled: settings.partialTranslation, store: store,
                                   liveSpacing: LivePace.spacing(forSetting: settings.liveInterval))
            }
            else if settings.partialTranslation { translateLive(id: id, text: clean) }
            return
        }

        let started = line?.start ?? Date()
        let echoNow = line?.isEcho ?? false
        // Stamp the end time / recording state NOW (the write happens seconds later).
        let stamp = recorder.stamp(for: source)
        let config: LLMConfig? = settings.useLLM && running ? settings.llmConfig : nil
        let commit = commits.add(expectsLLM: config != nil) { [weak self] appleText, refined in
            guard let self else { return }
            let echo = self.store.line(id: id)?.isEcho ?? echoNow          // line may be gone after Clear
            self.recorder.append(source: source, start: started, end: stamp.end, recording: stamp.recording,
                                 session: stamp.session, en: clean, zh: refined?.text ?? appleText, echo: echo,
                                 engine: refined?.engineID ?? (apple ? "apple-translation" : "none"),
                                 zhApple: refined != nil && apple ? appleText : nil)
        }
        if apple {
            translator.request(id: id, text: clean, isFinal: true, partialsEnabled: settings.partialTranslation, store: store,
                               onFinal: { [commits] zh in commits.setApple(commit, zh) })
        } else {
            // A live translation stays on screen until the finished one arrives. Anything else here is left over
            // from before the mode was switched mid-sentence.
            if store.line(id: id)?.zhLive != true { store.clearTranslation(id: id) }
            commits.setApple(commit, "")
        }
        if let config {
            refine(id: id, source: source, text: clean, config: config, commit: commit, session: stamp.session, onlyLLM: !apple)
        }
    }

    /// "LLM" mode with a local model: translate the words spoken so far. (A cloud service would be asked, and
    /// charged, about once a second, so it only gets finished sentences.)
    private func translateLive(id: UUID, text: String) {
        let config = settings.llmConfig
        guard running, !stopping, config.allowsLiveTranslation,
              text.count >= 8, text.split(separator: " ").count >= 2 else { return }
        let began = sessionBegan
        llm.liveSpacing = LivePace.spacing(forSetting: settings.liveInterval)
        llm.submitLive(line: id, text: text, engine: llmService.engine(for: config), timeout: config.timeout, request: { [weak self] in
            guard let self, let line = self.store.line(id: id), !line.isEcho, !line.isFinal else { return nil }
            return TranslationRequest(text: text, context: self.store.context(before: id, limit: config.contextCount, since: began))
        }, show: { [weak self] zh in
            guard let self, self.settings.translationMode == .llm else { return }
            #if DEVTOOLS
            PerfHarness.timeline("LIVEZH", text)
            PerfHarness.timeline("SHOWN", "live      " + zh)
            #endif
            self.store.setLiveZh(id: id, zh: zh)
        })
    }

    /// Asks the LLM to translate a finished sentence: to improve on Apple's, or (`onlyLLM`) as the only translation.
    private func refine(id: UUID, source: Source, text: String, config: LLMConfig, commit: Int, session: UUID, onlyLLM: Bool) {
        let engine = llmService.engine(for: config)
        let began = sessionBegan
        let submit = { [weak self] in
            guard let self, self.running, self.recorder.sessionID == session, self.settings.useLLM,
                  self.settings.llmConfig.destinationID == config.destinationID else {
                if onlyLLM { self?.store.markUntranslated(id: id, forEn: text) }
                self?.commits.setLLM(commit, nil); return
            }
            self.llm.submit(engine: engine, timeout: config.timeout, finishing: onlyLLM ? (id, text) : nil, request: { [weak self] in
                guard let self, self.store.line(id: id)?.isEcho != true else { return nil }   // echo: not worth a request
                return TranslationRequest(text: text, context: self.store.context(before: id, limit: config.contextCount, since: began))
            }, done: { [weak self] result in
                guard let self else { return }
                #if DEVTOOLS
                if ProcessInfo.processInfo.environment["MACCAPTIONS_LLM_TRACE"] != nil {
                    print("TRACE \(result.map { "\($0.milliseconds) ms" } ?? "no LLM result") | \(text.prefix(40))"); fflush(stdout)
                    PerfHarness.timeline("LLMDONE", text)
                    if let result { PerfHarness.timeline("SHOWN", "finished  " + result.text) }
                }
                #endif
                if let result { self.store.setRefinedZh(id: id, zh: result.text, forEn: text) }
                else if onlyLLM { self.store.markUntranslated(id: id, forEn: text) }
                self.commits.setLLM(commit, result)
            })
        }
        // A mic sentence may turn out to be an echo of the system audio, which is recognised about a second later.
        if source == .mic && tap != nil && settings.hideEcho && !stopping {
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(1500)); submit() }
        } else {
            submit()
        }
    }
}
