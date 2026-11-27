import Foundation
import AVFoundation

/// Writes AAC audio segments off the audio thread. Safe to call `write` from any thread.
final class AudioSegmentWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "maccaptions.audiowriter")
    private var file: AVAudioFile?

    func open(url: URL, format: AVAudioFormat) throws {
        try queue.sync {
            file = try AVAudioFile(forWriting: url,
                                   settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                              AVSampleRateKey: format.sampleRate,
                                              AVNumberOfChannelsKey: 1,
                                              AVEncoderBitRateKey: 32000],
                                   commonFormat: format.commonFormat,
                                   interleaved: format.isInterleaved)
        }
    }
    func write(_ buf: AVAudioPCMBuffer) { queue.async { [self] in try? file?.write(from: buf) } }
    func close() { queue.sync { file = nil } }   // queued writes drain first; AVAudioFile finalizes on release
}

struct LineRecord: Codable {
    var start: Double       // seconds from session start
    var end: Double
    var speaker: String     // "Me" | "Them"
    var en: String
    var zh: String
    var engine: String      // what produced `zh`: "apple-translation", "llm:<provider>/<model>", or "none" (empty `zh`)
    var zhApple: String? = nil    // Apple's translation, kept when the LLM's replaced it
    var recording: Bool     // this speaker's audio track was being recorded when the sentence finished
    var echo: Bool          // mic line judged to be the system audio heard through the speakers
}

private struct SegmentInfo: Codable { var track: String; var file: String; var startOffset: Double; var endOffset: Double? }
private struct SessionInfo: Codable {
    var startedAt: String
    var endedAt: String?
    var language: String
    var echoCancel: Bool
    var translationEngine: String
    var segments: [SegmentInfo]
}

/// One session = one Start→Stop. Text is always saved; each audio track (mic / system) is recorded in its own
/// numbered segments, opened and closed independently, so every file's length matches its recorded offsets.
@MainActor
final class SessionRecorder: ObservableObject {
    @Published private(set) var isRecording = false      // any track currently open
    @Published private(set) var sessionURL: URL?
    /// Set when saving fails (e.g. disk full). The app keeps captioning; the UI shows this.
    @Published private(set) var lastError: String?
    /// Changes with every session; delayed writes from an earlier session are dropped.
    private(set) var sessionID = UUID()

    private let writers: [Source: AudioSegmentWriter] = [.mic: AudioSegmentWriter(), .system: AudioSegmentWriter()]
    func writer(for s: Source) -> AudioSegmentWriter { writers[s]! }

    private var sessionStart = Date()
    private var info = SessionInfo(startedAt: "", endedAt: nil, language: "en → zh-Hans", echoCancel: false, translationEngine: "apple-translation", segments: [])
    private var segmentNumber: [Source: Int] = [.mic: 0, .system: 0]
    private var closedForStop = Set<Source>()      // tracks that were recording when Stop was pressed
    private var openIndex: [Source: Int] = [:]
    private var openSince: [Source: Date] = [:]
    private var accumulated: [Source: Double] = [.mic: 0, .system: 0]
    private var jsonl: FileHandle?
    private var md: FileHandle?

    static var documentsFolder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var rootFolder: URL {
        #if DEVTOOLS
        if let o = rootOverride { return o }          // test sessions never go into the user's folder
        #endif
        return documentsFolder.appendingPathComponent("MacCaptions")
    }

    /// Versions 0.1.0 and 0.1.1 saved to "~/Documents/LiveCaptions". Move that folder to the new name, once — but only if
    /// it clearly contains MacCaptions sessions (every item is a folder with a session.json) and the new folder does not
    /// exist yet, so nothing of anyone else's is ever touched or overwritten.
    static func migrateLegacyFolder(in documents: URL) {
        let fm = FileManager.default
        let old = documents.appendingPathComponent("LiveCaptions"), new = documents.appendingPathComponent("MacCaptions")
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path),
              let items = try? fm.contentsOfDirectory(atPath: old.path).filter({ $0 != ".DS_Store" }), !items.isEmpty,
              items.allSatisfy({ fm.fileExists(atPath: old.appendingPathComponent($0).appendingPathComponent("session.json").path) })
        else { return }
        try? fm.moveItem(at: old, to: new)
    }

    #if DEVTOOLS
    static var rootOverride: URL? { ProcessInfo.processInfo.environment["MACCAPTIONS_ROOT"].map { URL(fileURLWithPath: $0) } }
    #endif

    private func offset() -> Double { Date().timeIntervalSince(sessionStart) }
    func isOpen(_ s: Source) -> Bool { openIndex[s] != nil }

    /// Seconds of audio recorded so far (the longer of the two tracks).
    func elapsed() -> Double {
        [Source.mic, .system].map { s in accumulated[s, default: 0] + (openSince[s].map { Date().timeIntervalSince($0) } ?? 0) }.max() ?? 0
    }

    func beginSession(echoCancel: Bool, translationEngine: String = "apple-translation") throws {
        #if DEVTOOLS
        if Self.rootOverride == nil { Self.migrateLegacyFolder(in: Self.documentsFolder) }
        #else
        Self.migrateLegacyFolder(in: Self.documentsFolder)
        #endif
        sessionID = UUID(); lastError = nil
        sessionStart = Date()
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
        var url = Self.rootFolder.appendingPathComponent(f.string(from: sessionStart))
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = Self.rootFolder.appendingPathComponent("\(f.string(from: sessionStart))_\(n)"); n += 1 }
        try FileManager.default.createDirectory(at: url.appendingPathComponent("audio"), withIntermediateDirectories: true)
        sessionURL = url
        for name in ["transcript.jsonl", "transcript.md"] {
            FileManager.default.createFile(atPath: url.appendingPathComponent(name).path, contents: nil)
        }
        jsonl = try FileHandle(forWritingTo: url.appendingPathComponent("transcript.jsonl"))
        md = try FileHandle(forWritingTo: url.appendingPathComponent("transcript.md"))
        safeWrite(md, Data("# Live captions — \(f.string(from: sessionStart))\n\n".utf8))
        info = SessionInfo(startedAt: ISO8601DateFormatter().string(from: sessionStart), endedAt: nil,
                           language: "en → zh-Hans", echoCancel: echoCancel, translationEngine: translationEngine, segments: [])
        segmentNumber = [.mic: 0, .system: 0]; accumulated = [.mic: 0, .system: 0]
        openIndex = [:]; openSince = [:]; isRecording = false; closedForStop = []
        writeInfo()
    }

    func openTrack(_ s: Source, format: AVAudioFormat) {
        guard let url = sessionURL, !isOpen(s) else { return }
        segmentNumber[s, default: 0] += 1
        let name = (s == .mic ? "mic" : "system") + String(format: "_%03d.m4a", segmentNumber[s]!)
        do { try writer(for: s).open(url: url.appendingPathComponent("audio/\(name)"), format: format) }
        catch { NSLog("Recording \(s) failed to start: \(error)"); return }
        info.segments.append(SegmentInfo(track: s == .mic ? "mic" : "system", file: "audio/\(name)", startOffset: offset(), endOffset: nil))
        openIndex[s] = info.segments.count - 1
        openSince[s] = Date()
        isRecording = true
        writeInfo()
    }

    func closeTrack(_ s: Source) {
        guard let idx = openIndex[s] else { return }
        writer(for: s).close()
        info.segments[idx].endOffset = offset()
        if let since = openSince[s] { accumulated[s, default: 0] += Date().timeIntervalSince(since) }
        openIndex[s] = nil; openSince[s] = nil
        isRecording = !openIndex.isEmpty
        writeInfo()
    }

    func reportError(_ message: String) { lastError = message }

    func closeAllTracks() { closeTrack(.mic); closeTrack(.system) }

    /// Taken at the moment a sentence is finished (not when it is written, which happens seconds later).
    func stamp(for source: Source) -> (end: Double, recording: Bool, session: UUID) {
        (offset(), isOpen(source) || closedForStop.contains(source), sessionID)     // sentences finished while stopping still count
    }

    /// Stop pressed: close the tracks now (so file lengths match the captured audio) but remember what was recording.
    func closeAllTracksForStop() {
        for s in [Source.mic, .system] where isOpen(s) { closedForStop.insert(s) }
        closeAllTracks()
    }

    private func safeWrite(_ handle: FileHandle?, _ data: Data) {
        guard let handle else { return }
        do { try handle.write(contentsOf: data) }      // throws on error (disk full…) instead of crashing
        catch { lastError = "Could not save transcript: \(error.localizedDescription)" }
    }

    func append(source: Source, start: Date, end: Double, recording: Bool, session: UUID, en: String, zh: String, echo: Bool,
                engine: String = "apple-translation", zhApple: String? = nil) {
        guard session == sessionID, jsonl != nil else { return }      // late write from a finished session → drop
        let s = start.timeIntervalSince(sessionStart)
        let rec = LineRecord(start: s, end: end, speaker: source.label, en: en, zh: zh,
                             engine: engine, zhApple: zhApple, recording: recording, echo: echo)
        if let data = try? JSONEncoder().encode(rec) { safeWrite(jsonl, data + Data("\n".utf8)) }
        guard !echo else { return }          // echo lines stay in the jsonl (flagged) but not in the readable transcript
        let t = max(0, Int(s))
        let stamp = String(format: "%02d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
        safeWrite(md, Data("**[\(stamp)] \(source.label):** \(en)\n\n> \(zh.isEmpty ? "(not translated)" : zh)\n\n".utf8))
    }

    func endSession() {
        closeAllTracks()
        info.endedAt = ISO8601DateFormatter().string(from: Date())
        writeInfo()
        try? jsonl?.close(); try? md?.close(); jsonl = nil; md = nil
    }

    private func writeInfo() {
        guard let url = sessionURL else { return }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(info) {
            do { try data.write(to: url.appendingPathComponent("session.json"), options: .atomic) }
            catch { lastError = "Could not save session info: \(error.localizedDescription)" }
        }
    }
}
