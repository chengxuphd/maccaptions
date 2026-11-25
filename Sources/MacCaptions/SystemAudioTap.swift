import Foundation
import AVFoundation
import CoreAudio

/// System output audio via a Core Audio process tap (macOS 14.2+).
/// Uses a tap-only aggregate device (no speaker sub-device): this keeps working when mic voice processing is on.
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "maccaptions.systap", qos: .userInteractive)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    /// Called on the main queue when the default output device changes (headphones, Bluetooth, display speakers…).
    /// The tap's format can change then, so the owner should restart the tap.
    var onOutputDeviceChange: (() -> Void)?

    struct TapError: Error, CustomStringConvertible { let description: String }
    private func check(_ s: OSStatus, _ what: String) throws {
        if s != noErr { throw TapError(description: "\(what) failed (OSStatus \(s))") }
    }

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        do { try startUnchecked(onBuffer: onBuffer) } catch { stop(); throw error }   // never leave a half-built tap behind
    }

    private func startUnchecked(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "MacCaptions tap"
        desc.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "CreateProcessTap")

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "tap format")
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { throw TapError(description: "bad tap format") }

        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacCaptions aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID), "CreateAggregateDevice")

        // The no-copy wrapper is only valid during this callback; that is fine because the consumer converts the audio
        // synchronously into its own buffer. (A previous per-channel copy corrupted interleaved stereo.)
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { _, inData, _, _, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inData, deallocator: nil) else { return }
            onBuffer(buf)
        }, "CreateIOProc")
        try check(AudioDeviceStart(aggID, procID), "DeviceStart")
        watchOutputDevice()
    }

    private func watchOutputDevice() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onOutputDeviceChange?() }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    func stop() {
        if let block = deviceListener {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
            deviceListener = nil
        }
        onOutputDeviceChange = nil
        if let procID { AudioDeviceStop(aggID, procID); AudioDeviceDestroyIOProcID(aggID, procID) }
        procID = nil
        if aggID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggID); aggID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }
}
