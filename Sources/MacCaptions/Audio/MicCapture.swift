import Foundation
import AVFoundation

/// Microphone via AVAudioEngine. With `echoCancel`, uses Apple's voice processing so the Mac's own speaker output
/// (the meeting) is removed from the mic signal.
final class MicCapture {
    struct MicError: Error, CustomStringConvertible { let description: String }

    private let engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    /// Called (on the main queue) when macOS changes the audio configuration — a headset is connected, the default
    /// input changes, the Mac wakes from sleep… AVAudioEngine stops itself then, so the owner must restart the mic.
    var onConfigurationChange: (() -> Void)?

    func start(echoCancel: Bool, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        if echoCancel {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            // Don't turn the meeting audio down while the mic is active.
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let fmt = engine.inputNode.outputFormat(forBus: 0)
        // No input device (e.g. a desktop Mac without a mic): installTap would raise an Objective-C exception.
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw MicError(description: "no microphone input device available") }
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in onBuffer(buf) }
        engine.prepare()
        try engine.start()
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    func stop() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        onConfigurationChange = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }
}
