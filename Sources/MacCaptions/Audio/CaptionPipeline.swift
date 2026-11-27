import Foundation
import AVFoundation
import Speech

/// One speech-recognition pipeline per audio source.
final class CaptionPipeline {
    typealias ResultHandler = @MainActor (_ text: String, _ isFinal: Bool) -> Void

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    let format: AVAudioFormat
    /// Receives the converted 16 kHz mono audio (what the recognizer hears) — used for recording.
    var recordTap: ((AVAudioPCMBuffer) -> Void)?
    private let cont: AsyncStream<AnalyzerInput>.Continuation
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var converterSrc: AVAudioFormat?
    private(set) var framesIn = 0

    init(locale: Locale, onResult: @escaping ResultHandler) async throws {
        transcriber = SpeechTranscriber(locale: locale,
                                        transcriptionOptions: [],
                                        reportingOptions: [.volatileResults, .fastResults],   // fastResults: ~1 s updates instead of ~4 s
                                        attributeOptions: [])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }
        analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "MacCaptions", code: 1, userInfo: [NSLocalizedDescriptionKey: "No compatible speech audio format"])
        }
        format = f
        // Bounded: if the recognizer ever stalls, keep only the newest ~50 s of audio instead of growing without limit.
        let (seq, c) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(600))
        cont = c
        let transcriber = self.transcriber
        resultsTask = Task {
            do {
                for try await r in transcriber.results {
                    await onResult(String(r.text.characters), r.isFinal)
                }
            } catch { /* stream ended */ }
        }
        try await analyzer.start(inputSequence: seq)
    }

    /// Feed PCM in any format (multi-channel voice-processing input uses channel 0).
    func feed(_ input: AVAudioPCMBuffer) {
        var buf = input
        if input.format.channelCount > 2, let src = input.floatChannelData,
           let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.format.sampleRate, channels: 1, interleaved: false),
           let mono = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: input.frameLength) {
            mono.frameLength = input.frameLength
            memcpy(mono.floatChannelData![0], src[0], Int(input.frameLength) * MemoryLayout<Float>.size)
            buf = mono
        }
        if converter == nil || converterSrc != buf.format {
            converter = AVAudioConverter(from: buf.format, to: format)
            converterSrc = buf.format
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
        var consumed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return buf
        }
        guard err == nil, out.frameLength > 0 else { return }
        framesIn += Int(out.frameLength)
        recordTap?(out)
        cont.yield(AnalyzerInput(buffer: out))
    }

    /// Close the sentence being recognised right now (used when a source is switched off mid-sentence): the recognizer
    /// then reports the real final result itself, so the line is not duplicated later.
    func flush() async { try? await analyzer.finalize(through: nil) }

    /// finalizeAndFinishThroughEndOfInput() never returns if no audio was fed, and can stall — time-box it, and always
    /// release the analyzer afterwards.
    func finish(timeout: TimeInterval = 4) async {
        cont.finish()
        let analyzer = self.analyzer
        if framesIn > 0 {
            let done = Flag()
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput(); done.set() }
            let deadline = Date().addingTimeInterval(timeout)
            while !done.value && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        }
        await analyzer.cancelAndFinishNow()          // no-op if already finished; frees the analyzer if it was stuck
        resultsTask?.cancel()
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
    func set() { lock.lock(); v = true; lock.unlock() }
}
