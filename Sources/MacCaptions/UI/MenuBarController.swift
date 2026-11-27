import AppKit
import Combine

@MainActor
final class MenuBarController {
    private let item = NSStatusBar.system.statusItem(withLength: 380)
    private let engine: CaptionEngine
    private let panel: PanelWindowController
    private var bag = Set<AnyCancellable>()
    private let font = NSFont.menuBarFont(ofSize: 0)
    private let pad: CGFloat = 6
    private var lastKey = ""          // what is currently drawn; identical updates are skipped (each redraw is costly)
    private var widthCache: [String: CGFloat] = [:]

    init(engine: CaptionEngine) {
        self.engine = engine
        panel = PanelWindowController(engine: engine)
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
        }
        // The text is drawn by us into an image (see `render`): the status-item button applies its own insets, alignment
        // and truncation to a title, which made the Mix divider drift and cut text off early. A custom NSTextField
        // subview was tried too, but made AppKit re-render the item continuously (~39 % CPU while idle).
        // Coalesce bursts (the recognizer reports several changes at once) into at most ~12 redraws per second.
        engine.store.objectWillChange.merge(with: engine.settings.objectWillChange, engine.objectWillChange)
            .throttle(for: .milliseconds(80), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.refresh() }
            .store(in: &bag)
        refresh()
    }

    @objc private func clicked() {
        guard let button = item.button else { return }
        panel.toggle(below: button)
    }

    /// Open the controls even if the menu bar item itself is hidden (crowded / notched menu bar).
    func showPanel() {
        guard let button = item.button, !panel.isShown else { return }
        panel.show(below: button)
    }

    private func width(_ t: String) -> CGFloat {
        if let w = widthCache[t] { return w }
        let w = (t as NSString).size(withAttributes: [.font: font]).width
        if widthCache.count > 400 { widthCache.removeAll() }
        widthCache[t] = w
        return w
    }

    /// Keep the *newest* words (end of the text) when it doesn't fit. Binary search: O(log n) measurements.
    func fit(_ s: String, width avail: CGFloat) -> String {
        if avail <= 0 { return "" }
        if width(s) <= avail { return s }
        let chars = Array(s)
        var lo = 0, hi = chars.count            // smallest start index whose suffix (with "…") fits
        while lo < hi {
            let mid = (lo + hi) / 2
            if width("…" + String(chars[mid...])) <= avail { hi = mid } else { lo = mid + 1 }
        }
        // Don't cut in the middle of a word: if the cut lands inside one, skip ahead to the next space (Latin text only).
        if lo > 0, lo < chars.count, chars[lo - 1].isLetter, chars[lo].isLetter, chars[lo].isASCII {
            var j = lo
            while j < chars.count, !chars[j].isWhitespace, j - lo < 24 { j += 1 }
            if j < chars.count, chars[j].isWhitespace { lo = j + 1 }
        }
        return lo >= chars.count ? "…" : "…" + String(chars[lo...])
    }

    /// What to draw, with every x position decided here (nothing is left to AppKit's title layout).
    struct Layout: Equatable {
        var rec: Bool
        var enText: String      // drawn at enX
        var zhText: String      // drawn at zhX
        var dividerX: CGFloat?  // Mix mode only
        var enX: CGFloat, zhX: CGFloat
        var total: CGFloat
    }

    func layout(en: String, zh: String, mode: MenuBarMode, rec: Bool, total: CGFloat, share: Double, idleText: String) -> Layout {
        let dotW = rec ? width("● ") : 0
        let x0 = pad + dotW
        let avail = total - pad * 2 - dotW
        if en.isEmpty && zh.isEmpty {
            return Layout(rec: rec, enText: fit(idleText, width: avail), zhText: "", dividerX: nil, enX: x0, zhX: x0, total: total)
        }
        switch mode {
        case .en:  return Layout(rec: rec, enText: fit(en, width: avail), zhText: "", dividerX: nil, enX: x0, zhX: x0, total: total)
        case .zh:  return Layout(rec: rec, enText: "", zhText: fit(zh, width: avail), dividerX: nil, enX: x0, zhX: x0, total: total)
        case .mix:
            let sepW = width("│") + 12                                   // divider with a little air on both sides
            let enW = ((avail - sepW) * CGFloat(min(max(share, 0.25), 0.75))).rounded(.down)
            let zhW = avail - sepW - enW
            let dividerX = x0 + enW + 6
            return Layout(rec: rec, enText: fit(en, width: enW), zhText: fit(zh, width: zhW),
                          dividerX: dividerX, enX: x0, zhX: dividerX + width("│") + 6, total: total)
        }
    }

    /// Draws a layout into an image exactly `total` wide. Text is left-anchored and clipped to the item.
    func render(_ l: Layout) -> NSImage {
        let height = NSStatusBar.system.thickness
        let font = self.font
        let pad = self.pad
        let image = NSImage(size: NSSize(width: l.total, height: height), flipped: false) { rect in
            NSBezierPath(rect: rect.insetBy(dx: pad - 2, dy: 0)).addClip()
            func draw(_ s: String, at x: CGFloat, color: NSColor) {
                guard !s.isEmpty else { return }
                let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
                a.draw(at: NSPoint(x: x, y: ((rect.height - a.size().height) / 2).rounded()))
            }
            if l.rec { draw("●", at: pad, color: .systemRed) }
            draw(l.enText, at: l.enX, color: .labelColor)
            if let dx = l.dividerX { draw("│", at: dx, color: .secondaryLabelColor) }
            draw(l.zhText, at: l.zhX, color: .labelColor)
            return true
        }
        image.isTemplate = false
        return image
    }

    private func refresh() {
        let settings = engine.settings
        let visible = settings.showMenuBar
        if item.isVisible != visible { item.isVisible = visible }
        let total = CGFloat(settings.menuBarWidth)
        if item.length != total { item.length = total }      // FIXED width: the item never resizes or shifts

        let line = engine.store.latest
        let en = line?.en ?? ""
        // Chinese must belong to the same sentence as the English. While it is still pending, show "…" (Mix) or the
        // previous sentence's translation (Chinese-only, where an empty bar would flicker).
        let lineZh = line?.zh ?? ""
        let zh: String
        if settings.translationMode == .llm {
            // Chinese only arrives after a sentence ends, usually when the next one has begun: pairing strictly would
            // show "…" almost all the time. So show a recent sentence's translation until this one has its own.
            if !lineZh.isEmpty { zh = lineZh }
            else if line?.zhMissing == true { zh = "—" }
            else { let recent = engine.store.recentZh(); zh = recent.isEmpty && !en.isEmpty ? "…" : recent }
        } else if settings.menuBarMode == .zh {
            zh = lineZh.isEmpty ? engine.store.latestZh : lineZh
        } else {
            zh = lineZh.isEmpty && !en.isEmpty ? "…" : lineZh
        }
        let l = layout(en: en, zh: zh, mode: settings.menuBarMode, rec: engine.recorder.isRecording, total: total,
                       share: settings.menuBarMixShare, idleText: engine.running ? "Listening…" : "MacCaptions")
        let key = "\(l)"
        if key == lastKey { return }                          // nothing visible changed → don't redraw
        lastKey = key
        item.button?.image = render(l)
    }
}
