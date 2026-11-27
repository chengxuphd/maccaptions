#if DEVTOOLS
import AppKit
import AVFoundation
import SwiftUI
import Darwin

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

// MARK: - Offscreen screenshots

/// MACCAPTIONS_UI_SHOT=<dir>: draws the menu bar panel and the LLM settings window to PNG files (nothing is shown).
@MainActor
func renderUIShots(into dir: String, engine: CaptionEngine) async {
    func shoot<V: View>(_ view: V, _ size: NSSize, _ name: String) async {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        try? await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        print("rendered \(name)")
    }
    let s = Settings.shared
    engine.store.loadDemo()
    if let first = engine.store.lines.first { engine.store.setRefinedZh(id: first.id, zh: first.zh, forEn: first.en) }
    await shoot(PanelView(engine: engine, store: engine.store, settings: s), NSSize(width: 480, height: 630), "panel_apple")
    s.translationMode = .appleLLM
    await shoot(PanelView(engine: engine, store: engine.store, settings: s), NSSize(width: 480, height: 630), "panel_llm_local")
    await shoot(LLMSettingsView(settings: s, service: engine.llmService), NSSize(width: 580, height: 720), "llm_settings_local")
    s.translationMode = .llm
    let waiting = engine.store.update(source: .system, text: "A finished sentence still waiting for the model.", isFinal: true)
    let failed = engine.store.update(source: .mic, text: "A sentence the model gave no translation for.", isFinal: true)
    if let failed { engine.store.markUntranslated(id: failed, forEn: "A sentence the model gave no translation for.") }
    _ = waiting
    await shoot(PanelView(engine: engine, store: engine.store, settings: s), NSSize(width: 480, height: 630), "panel_llm_only")
    await shoot(LLMSettingsView(settings: s, service: engine.llmService), NSSize(width: 580, height: 720), "llm_settings_llm_only")
    s.translationMode = .appleLLM
    s.llmProvider = .openrouter
    var p = s.llmProfile; p.model = "vendor/model-name"; s.llmProfile = p
    await shoot(PanelView(engine: engine, store: engine.store, settings: s), NSSize(width: 480, height: 630), "panel_llm_cloud")
    await shoot(LLMSettingsView(settings: s, service: engine.llmService), NSSize(width: 580, height: 1150), "llm_settings_cloud_tall")
}
#endif
