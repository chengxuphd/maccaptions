import Foundation
import AVFoundation

@MainActor
final class CaptionEngine: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "Idle"

    let store = TranscriptStore()
    let recorder = SessionRecorder()
    let settings = Settings.shared
    private let translator = TranslationCoordinator()
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
    private var recorderObserver: Any?
    private var lastDeviceRestart = [Source: Date]()
    private var pendingCommits = 0    // finished sentences waiting to be written to disk
    /// Wait before writing a sentence so the echo filter can see the matching system audio (it arrives ~1 s later).
    private let commitDelay: Duration = .milliseconds(2500)

    /// Status line shown in the UI, including any saving problem.
    var displayStatus: String { recorder.lastError.map { status + " · ⚠ " + $0 } ?? status }

    init() {
        recorderObserver = recorder.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    func toggle() { Task { running ? await stop() : await start() } }

    // MARK: Start / stop

    func start() async {
        guard !running, !busy else { return }
        busy = true; defer { busy = false }
        status = "Starting…"
        if let err = await translator.prepare() { status = err; return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
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
        do { try recorder.beginSession(echoCancel: settings.echoCancel) }
        catch { recorder.reportError("saving is off — \(error.localizedDescription)") }
        mic.recordTap = { [recorder] in recorder.writer(for: .mic).write($0) }
        sys.recordTap = { [recorder] in recorder.writer(for: .system).write($0) }
        running = true
        applySourceSettings()
    }

    func stop() async {
        guard running, !busy else { return }
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
        // Wait until every finished sentence has been translated and written (each waits `commitDelay`).
        let deadline = Date().addingTimeInterval(8)
        try? await Task.sleep(for: .milliseconds(300))
        while pendingCommits > 0 && Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
        recorder.endSession()
        micPipeline = nil; sysPipeline = nil
        running = false
        status = "Stopped"
    }

    /// Immediate, synchronous shutdown of capture and files (system shutdown / logout).
    func emergencyClose() {
        stopping = true
        stopCaptures()
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
        guard let id = store.update(source: source, text: text, isFinal: isFinal) else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = store.line(id: id)
        if !isFinal && line?.isEcho == true { return }            // hidden echo: don't spend a translation on it
        let started = line?.start ?? Date()
        let echoNow = line?.isEcho ?? false
        // Stamp the end time / recording state NOW (the write happens seconds later).
        let stamp = isFinal ? recorder.stamp(for: source) : nil
        if isFinal { pendingCommits += 1 }
        translator.request(id: id, text: clean, isFinal: isFinal, partialsEnabled: settings.partialTranslation, store: store,
                           onFinal: { [weak self] zh in
            guard let self, let stamp else { return }
            Task { @MainActor in
                defer { self.pendingCommits -= 1 }
                try? await Task.sleep(for: self.commitDelay)
                let echo = self.store.line(id: id)?.isEcho ?? echoNow      // line may be gone after Clear
                self.recorder.append(source: source, start: started, end: stamp.end, recording: stamp.recording,
                                     session: stamp.session, en: clean, zh: zh, echo: echo)
            }
        })
    }
}
