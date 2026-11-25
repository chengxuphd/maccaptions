#if DEVTOOLS
// Developer / test tooling. NOT part of the shipped app: compiled only with
//   swift build -Xswiftc -DDEVTOOLS
// Everything here is driven by MACCAPTIONS_* environment variables and never touches saved settings permanently.
import AppKit
import AVFoundation
import SwiftUI
import Darwin


/// Test-only helpers (activated by environment variables; no effect in normal use).
///   MACCAPTIONS_FEED=<audio file>   feed this file into the system-audio pipeline at real-time pace
///                                      instead of capturing devices (silent, repeatable measurements)
///   MACCAPTIONS_STATS_FILE=<path>   write CPU / memory stats there when the app quits
///   MACCAPTIONS_SHOWWINDOW=1        show the floating window (without changing saved settings)
enum PerfHarness {
    static let launched = Date()
    static var env: [String: String] { ProcessInfo.processInfo.environment }

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

/// MACCAPTIONS_SELFTEST=1: checks store / echo logic, prints PASS/FAIL lines, then quits.
@MainActor
func runSelfTests() {
    var failed = 0
    func check(_ name: String, _ ok: Bool) { print((ok ? "PASS " : "FAIL ") + name); if !ok { failed += 1 } }

    // 1. Echo is re-decided: a mic line first looks like the system speech, then becomes the user's own sentence.
    let st = TranscriptStore(); st.echoFilterEnabled = true
    st.update(source: .system, text: "We should migrate the payment service to the new cluster", isFinal: true)
    let mic = st.update(source: .mic, text: "migrate the payment service", isFinal: false)!
    check("echo: short repeat of system speech is hidden", st.line(id: mic)?.isEcho == true)
    st.update(source: .mic, text: "migrate the payment service but only after the audit next year", isFinal: false)
    check("echo: line is un-hidden when the speaker keeps talking", st.line(id: mic)?.isEcho == false)
    st.update(source: .mic, text: "migrate the payment service but only after the audit next year", isFinal: true)
    check("echo: final user sentence stays visible", st.visibleLines.contains { $0.id == mic })

    // 2. An empty final result discards the in-progress line (no stale text kept).
    let st2 = TranscriptStore()
    st2.update(source: .system, text: "hello there everyone", isFinal: false)
    st2.update(source: .system, text: "", isFinal: true)
    check("empty final removes the in-progress line", st2.lines.isEmpty && st2.currentLine(for: .system) == nil)
    st2.update(source: .system, text: "a brand new sentence", isFinal: false)
    check("next sentence starts a fresh line", st2.lines.count == 1 && st2.lines[0].en == "a brand new sentence")

    // 3. Switching the echo filter off clears all flags in one go.
    st.echoFilterEnabled = false
    check("filter off clears all echo flags", !st.lines.contains { $0.isEcho })

    // 4. Late translation must not move the display back to an older line.
    let st3 = TranscriptStore()
    let a = st3.update(source: .system, text: "first sentence of the call", isFinal: true)!
    let b = st3.update(source: .system, text: "second sentence is being spoken", isFinal: false)!
    st3.setZh(id: a, zh: "通话的第一句", forEn: "first sentence of the call")
    check("late translation keeps the newest line shown", st3.latest?.id == b)
    st3.setZh(id: a, zh: "过期", forEn: "something else entirely")
    check("stale translation (text changed) is ignored", st3.line(id: a)?.zh == "通话的第一句")

    // 5. Trimming at 1000 lines keeps in-progress bookkeeping valid.
    let st4 = TranscriptStore()
    for i in 0..<1100 { st4.update(source: .system, text: "sentence number \(i) of the long meeting", isFinal: true) }
    let live = st4.update(source: .mic, text: "still talking right now", isFinal: false)!
    check("store capped at 1000 lines", st4.lines.count <= 1001)
    st4.update(source: .mic, text: "still talking right now and more", isFinal: false)
    check("in-progress line survives trimming", st4.line(id: live)?.en == "still talking right now and more")
    print(failed == 0 ? "ALL SELF-TESTS PASSED" : "\(failed) SELF-TEST(S) FAILED")
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
                    try? await Task.sleep(for: .milliseconds(85))
                }
                NSLog("FEED: finished")
            }
        }
    }
}

/// MACCAPTIONS_MEASURE=1: how well does the reserved translation space match the real translation height?
@MainActor
func measureReservation() {
    let st = Settings.shared
    let pairs: [(String, String)] = [
        ("So when we think about larger models, agents these days, there seems to be very different perspectives involved.", "因此，当我们思考更大的模型、如今的代理时，似乎涉及非常不同的观点。"),
        ("Take your time up there.", "在那里慢慢来。"),
        ("Because from here on, you're in the system.", "因为从现在开始，你就在系统中了。"),
        ("Let's circle back on this after the sprint review.", "让我们在冲刺回顾后回顾一下这个问题。"),
        ("We need to align on the roadmap before the Q4 planning.", "我们需要在第四季度规划之前就路线图达成一致。"),
        ("The API returns a 429 error when the rate limit is exceeded.", "当超过速率限制时，API会返回429错误。"),
        ("Can you hear me? I think you're on mute.", "你能听到我说话吗？ 我觉得你静音了。"),
        ("Let's table this for now and take it offline.", "现在让我们暂时放下这个，然后把它下线。"),
        ("And then I think a few years after that the contract net protocol actually talked about how agents divide tasks with each other and negotiate the terms before anything is executed.", "几年后，合同网协议实际上讨论了智能体如何相互分配任务，并在执行任何操作之前协商条款。"),
        ("Yeah.", "是的。"),
    ]
    func h(_ line: CaptionLine, width: CGFloat) -> CGFloat {
        let r = ImageRenderer(content: FloatingCaptionView(lines: [line], settings: st, width: width)); r.scale = 1
        return r.nsImage?.size.height ?? 0
    }
    let saved = (st.windowContent, st.windowFontSize, st.windowEnFontSize)
    st.windowContent = .both; st.windowFontSize = 20; st.windowEnFontSize = 16
    for width in [760.0, 480.0] {
        var same = 0
        print("--- width \(Int(width)) ---")
        for (en, zh) in pairs {
            var pending = CaptionLine(source: .system, en: en); pending.isFinal = true
            var done = pending; done.zh = zh
            let a = h(pending, width: width), b = h(done, width: width)
            if abs(a - b) < 1 { same += 1 }
            print(String(format: "reserved %.0f  actual %.0f  diff %+.0f  | %@", a, b, b - a, String(en.prefix(40))))
        }
        print("exact match: \(same)/\(pairs.count)")
    }
    (st.windowContent, st.windowFontSize, st.windowEnFontSize) = saved
}

/// Renders the real menu bar layout to images and measures where the Mix divider and the text edges land.
@MainActor
func runDividerLayoutTest(_ mb: MenuBarController, outDir: String?) {
    let total: CGFloat = 380
    let ens = ["Hi.", "Take your time up there.", "Let's circle back on this after the sprint review",
               "So when we think about larger models, agents these days, there seems to be very different perspectives involved."]
    let zhs = ["好。", "在那里慢慢来。", "让我们在冲刺回顾后回顾一下这个问题。", "因此，当我们思考更大的模型、如今的智能体时，似乎涉及非常不同的观点。"]

    /// x (pt) of the leftmost and rightmost inked column, and of the tallest ink column (the divider)
    func measure(_ img: NSImage, name: String) -> (left: Double, right: Double, tall: Double) {
        let scale = 4.0
        let w = Int(Double(img.size.width) * scale), h = Int(Double(img.size.height) * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return (-1, -1, -1) }
        rep.size = img.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { img.draw(in: NSRect(origin: .zero, size: img.size)) }
        NSGraphicsContext.restoreGraphicsState()
        if let dir = outDir, let png = rep.representation(using: .png, properties: [:]) {
            // white backdrop so the PNG is viewable
            let flat = NSImage(size: img.size); flat.lockFocus(); NSColor.white.setFill(); NSRect(origin: .zero, size: img.size).fill()
            rep.draw(in: NSRect(origin: .zero, size: img.size)); flat.unlockFocus()
            if let t = flat.tiffRepresentation, let r2 = NSBitmapImageRep(data: t), let p2 = r2.representation(using: .png, properties: [:]) {
                try? p2.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            } else { try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png")) }
        }
        var left = -1, right = -1, tallX = -1, tall = 0
        for x in 0..<w {
            var c = 0
            for y in 0..<h { if let col = rep.colorAt(x: x, y: y), col.alphaComponent > 0.4 { c += 1 } }
            if c > 0 { if left < 0 { left = x }; right = x }
            if c > tall { tall = c; tallX = x }
        }
        return (Double(left) / scale, Double(right) / scale, Double(tallX) / scale)
    }
    func f(_ v: [Double]) -> String { v.map { String(format: "%6.1f", $0) }.joined(separator: " ") }

    var divs: [Double] = [], lefts: [Double] = [], rights: [Double] = []
    for (i, (en, zh)) in zip(ens, zhs).enumerated() {
        let l = mb.layout(en: en, zh: zh, mode: .mix, rec: false, total: total, share: 0.56, idleText: "")
        let m = measure(mb.render(l), name: "mix_\(i)")
        divs.append(m.tall); lefts.append(m.left); rights.append(m.right)
    }
    print("MIX mode, English 3 / 24 / 49 / 113 chars (item width \(Int(total)) pt):")
    print("  divider x      : \(f(divs))   spread \(String(format: "%.1f", (divs.max() ?? 0) - (divs.min() ?? 0))) pt")
    print("  text starts at : \(f(lefts))")
    print("  text ends at   : \(f(rights))   (limit \(Int(total - 4)) pt)")
    var ends: [Double] = []
    for (i, (en, zh)) in zip(ens, zhs).enumerated() {
        let l = mb.layout(en: en, zh: zh, mode: .zh, rec: false, total: total, share: 0.56, idleText: "")
        ends.append(measure(mb.render(l), name: "zh_\(i)").right)
        _ = en
    }
    print("ZH-only mode text ends at: \(f(ends))  → a long sentence fills the item to ~\(Int(total - 6)) pt, short ones stay left")
    let l = mb.layout(en: ens[3], zh: zhs[3], mode: .en, rec: true, total: total, share: 0.56, idleText: "")
    let m = measure(mb.render(l), name: "en_rec_long")
    print("EN-only long with red dot: starts \(String(format: "%.1f", m.left)), ends \(String(format: "%.1f", m.right)) pt")
}

@MainActor
func renderVariants(into dir: String) {
    let st = Settings.shared
    let store = TranscriptStore(); store.loadDemo()
    let saved = (st.windowContent, st.windowEnColorHex, st.windowZhColorHex, st.windowBgColorHex, st.windowBgOpacity,
                 st.windowTextOpacity, st.windowFontSize, st.windowEnFontSize, st.windowBold, st.windowShowSpeaker, st.windowWidth, st.windowNoBackground)
    func snap(_ name: String) {
        let view = FloatingCaptionView(lines: Array(store.visibleLines.suffix(st.windowLines)), settings: st)
            .background(LinearGradient(colors: [.gray, .blue], startPoint: .leading, endPoint: .trailing))
        let r = ImageRenderer(content: view); r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            print("rendered \(name) \(img.size)")
        }
    }
    st.resetWindowStyle(); snap("1_default_both")
    st.windowContent = .zh; st.windowFontSize = 34; st.windowZhColorHex = "#FFE066"; st.windowBgOpacity = 0.35; st.windowShowSpeaker = true
    snap("2_zh_only_big_yellow_lighter_bg")
    st.resetWindowStyle(); st.windowContent = .en; st.windowEnFontSize = 24; st.windowEnColorHex = "#7CFC9A"
    st.windowBgColorHex = "#1B2A4A"; st.windowBgOpacity = 0.9; st.windowBold = true; st.windowWidth = 520
    snap("3_en_only_green_navy_narrow")
    st.resetWindowStyle(); st.windowBgOpacity = 0; st.windowTextOpacity = 0.6
    snap("4_no_background_faded_text")
    st.resetWindowStyle(); st.windowNoBackground = true
    snap("5_no_background_checkbox")
    // restore the user's saved style
    (st.windowContent, st.windowEnColorHex, st.windowZhColorHex, st.windowBgColorHex, st.windowBgOpacity,
     st.windowTextOpacity, st.windowFontSize, st.windowEnFontSize, st.windowBold, st.windowShowSpeaker, st.windowWidth,
     st.windowNoBackground) = saved
}

/// Wires up the environment-variable test hooks. Only exists in DEVTOOLS builds.
@MainActor
func installDevHooks(_ d: AppDelegate) {
    let env = ProcessInfo.processInfo.environment
    let engine = d.engine
    // MACCAPTIONS_AUTOSTART=1 starts capturing immediately.
    if env["MACCAPTIONS_AUTOSTART"] != nil { engine.toggle() }
    engine.startFileFeedIfRequested()
    if env["MACCAPTIONS_SHOWWINDOW"] != nil { d.floating.setVisible(true) }
    // MACCAPTIONS_DEMO=1: sample captions + visible window (does not change saved settings).
    if env["MACCAPTIONS_DEMO"] != nil {
        engine.store.loadDemo()
        d.floating.setVisible(true)
        if env["MACCAPTIONS_DEMO_STYLE"] != nil { StyleWindowController.shared.show() }
    }
    if env["MACCAPTIONS_MEASURE"] != nil { measureReservation(); DispatchQueue.main.async { NSApp.terminate(nil) } }
    // MACCAPTIONS_RENDER=<dir>: render the caption view in several styles to PNG files, then quit.
    if let dir = env["MACCAPTIONS_RENDER"] { renderVariants(into: dir); DispatchQueue.main.async { NSApp.terminate(nil) } }
    // MACCAPTIONS_LAYOUT_TEST=<dir or 1>: where does the Mix divider land for different English lengths?
    if let v = env["MACCAPTIONS_LAYOUT_TEST"] {
        runDividerLayoutTest(d.menuBar, outDir: v.hasPrefix("/") ? v : nil); DispatchQueue.main.async { NSApp.terminate(nil) }
    }
    if env["MACCAPTIONS_SELFTEST"] != nil { runSelfTests(); DispatchQueue.main.async { NSApp.terminate(nil) } }
    // MACCAPTIONS_TOGGLE_REC / _TOGGLE_MIC / _TOGGLE_SYS = "10,20": flip that switch at those seconds.
    func seconds(_ key: String) -> [Double] { (env[key] ?? "").split(separator: ",").compactMap { Double($0) } }
    for t in seconds("MACCAPTIONS_TOGGLE_REC") { DispatchQueue.main.asyncAfter(deadline: .now() + t) { engine.toggleRecording() } }
    for t in seconds("MACCAPTIONS_TOGGLE_MIC") { DispatchQueue.main.asyncAfter(deadline: .now() + t) { engine.settings.micEnabled.toggle(); engine.applySourceSettings() } }
    for t in seconds("MACCAPTIONS_TOGGLE_SYS") { DispatchQueue.main.asyncAfter(deadline: .now() + t) { engine.settings.sysEnabled.toggle(); engine.applySourceSettings() } }
    // MACCAPTIONS_AUTOSTOP=<seconds> quits cleanly after N seconds.
    if let n = Double(env["MACCAPTIONS_AUTOSTOP"] ?? "") { DispatchQueue.main.asyncAfter(deadline: .now() + n) { [weak d] in d?.quit() } }
}

#endif
