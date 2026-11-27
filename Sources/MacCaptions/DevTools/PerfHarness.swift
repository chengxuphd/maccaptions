#if DEVTOOLS
import AppKit
import AVFoundation
import SwiftUI
import Darwin

// Developer / test tooling. NOT part of the shipped app: compiled only with
//   swift build -Xswiftc -DDEVTOOLS
// Everything here is driven by MACCAPTIONS_* environment variables and never touches saved settings permanently.

/// Test-only helpers (activated by environment variables; no effect in normal use).
///   MACCAPTIONS_FEED=<audio file>   feed this file into the system-audio pipeline at real-time pace
///                                      instead of capturing devices (silent, repeatable measurements)
///   MACCAPTIONS_STATS_FILE=<path>   write CPU / memory stats there when the app quits
///   MACCAPTIONS_SHOWWINDOW=1        show the floating window (without changing saved settings)
enum PerfHarness {
    static let launched = Date()
    static var env: [String: String] { ProcessInfo.processInfo.environment }

    /// MACCAPTIONS_TIMELINE=1: print when things happen, in seconds since launch, to find where caption delay comes from.
    static func timeline(_ event: String, _ detail: String) {
        guard env["MACCAPTIONS_TIMELINE"] != nil else { return }
        print(String(format: "TL %.3f %@ %@", Date().timeIntervalSince(launched), event, detail)); fflush(stdout)
    }

    /// Mono/any → interleaved stereo Float32 (the layout the system tap delivers), to exercise that path.
    static func interleavedStereo(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: src.format.sampleRate, channels: 2, interleaved: true),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: src.frameLength),
              let ch = src.floatChannelData else { return src }
        out.frameLength = src.frameLength
        let d = out.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        for i in 0..<Int(src.frameLength) { d[2 * i] = ch[0][i]; d[2 * i + 1] = ch[0][i] }
        return out
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func threadCount() -> Int {
        var list: thread_act_array_t?
        var n = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &list, &n) == KERN_SUCCESS else { return -1 }
        if let list { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(n) * MemoryLayout<thread_t>.size)) }
        return Int(n)
    }

    static func writeStats() {
        guard let path = env["MACCAPTIONS_STATS_FILE"] else { return }
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        let cpu = Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
        let wall = Date().timeIntervalSince(launched)
        let text = String(format: "wall %.1fs  cpu %.2fs  avgCPU %.1f%% of one core  peakRSS %.0f MB  footprint %.0f MB  threads %d\n",
                          wall, cpu, cpu / wall * 100, Double(u.ru_maxrss) / 1_048_576, footprintMB(), threadCount())
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

extension CaptionEngine {
    /// Feeds an audio file into the system-audio pipeline in real time (on a background thread, like the tap does).
    func startFileFeedIfRequested() {
        _ = PerfHarness.launched                                   // start the wall clock at launch
        guard let path = PerfHarness.env["MACCAPTIONS_FEED"] else { return }
        feedMode = true
        Task { @MainActor in
            if PerfHarness.env["MACCAPTIONS_AUTOSTART"] == nil { await start() }
            for _ in 0..<200 where sysPipeline == nil || !running { try? await Task.sleep(for: .milliseconds(100)) }   // wait for the session
            guard let sys = sysPipeline, let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
                NSLog("FEED: could not start (pipeline or file missing)"); return
            }
            NSLog("FEED: started, \(file.length) frames @ \(file.processingFormat.sampleRate) Hz")
            let fmt = file.processingFormat
            let chunk = AVAudioFrameCount(fmt.sampleRate * 0.085)          // ≈ one tap buffer (85 ms)
            Task.detached(priority: .userInitiated) {
                while file.framePosition < file.length {
                    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { break }
                    do { try file.read(into: buf, frameCount: chunk) } catch { break }
                    if buf.frameLength == 0 { break }
                    sys.feed(PerfHarness.env["MACCAPTIONS_FEED_INTERLEAVED"] != nil ? PerfHarness.interleavedStereo(buf) : buf)
                    PerfHarness.timeline("FED", String(format: "%.3f", Double(file.framePosition) / fmt.sampleRate))   // audio position
                    try? await Task.sleep(for: .milliseconds(85))
                }
                NSLog("FEED: finished")
            }
        }
    }
}
#endif
