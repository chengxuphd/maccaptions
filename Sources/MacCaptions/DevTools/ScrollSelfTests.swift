#if DEVTOOLS
import AppKit
import SwiftUI

/// The panel's transcript, tested for real: the panel is built off screen, its scroll position is moved (the user's
/// mouse is not involved), and it is fed lines the way live captioning feeds it.
@MainActor
func runScrollSelfTests(_ check: (String, Bool) -> Void) async {
    await runScrollScenario(announced: false, check)    // moved with no notice at all (the stricter case)
    await runScrollScenario(announced: true, check)     // with AppKit's "user is scrolling" notices, as a real scroll has
    runScrollRuleTests(check)
}

@MainActor
private func runScrollScenario(announced: Bool, _ base: (String, Bool) -> Void) async {
    func check(_ name: String, _ ok: Bool) { base(name + (announced ? "  [announced scroll]" : "  [silent move]"), ok) }
    let engine = CaptionEngine()
    var sentence = 0
    func wait(_ seconds: Double = 0.25) async { try? await Task.sleep(for: .seconds(seconds)) }
    func addFinished(_ count: Int) {
        for _ in 0..<count {
            sentence += 1
            let en = "Sentence \(sentence): we talked about the roadmap, the budget and what has to ship in the next release."
            if let id = engine.store.update(source: .system, text: en, isFinal: true) {
                engine.store.setZh(id: id, zh: "第\(sentence)句：我们讨论了路线图、预算，以及下一个版本必须发布的内容。", forEn: en)
            }
        }
    }
    /// One sentence arriving as in a live session: growing English, a translation, then the finished line.
    func speakOne() async {
        sentence += 1
        var words: [String] = []
        for chunk in ["Sentence \(sentence) is", "being spoken right now and", "it keeps getting longer as", "the speaker talks about the next release"] {
            words.append(chunk)
            let text = words.joined(separator: " ")
            if let id = engine.store.update(source: .system, text: text, isFinal: false) {
                engine.store.setZh(id: id, zh: "正在说的第\(sentence)句，内容越来越长。" + String(repeating: "更多内容。", count: words.count), forEn: text)
            }
            await wait(0.12)
        }
        let done = words.joined(separator: " ") + "."
        if let id = engine.store.update(source: .system, text: done, isFinal: true) {
            engine.store.setZh(id: id, zh: "第\(sentence)句说完了。", forEn: done)
        }
        await wait(0.2)
    }

    addFinished(60)
    let host = NSHostingView(rootView: PanelView(engine: engine, store: engine.store, settings: engine.settings))
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: PanelView.size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: PanelView.size)
    window.orderFrontRegardless()
    await wait(1.0)

    func find(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? v.subviews.flatMap(find) }
    guard let scroll = find(host).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
          let document = scroll.documentView else { check("scroll: found the transcript's scroll view", false); return }
    var clip: NSClipView { scroll.contentView }
    func fromBottom() -> CGFloat {
        document.isFlipped ? document.frame.height - clip.bounds.maxY : clip.bounds.minY
    }
    /// Moves the view the way dragging the scroll bar does, in small steps. Positive = towards older lines.
    /// (SwiftUI ignores synthetic wheel events, so trackpad gestures themselves can only be tried by hand.)
    func wheel(_ points: CGFloat) async {
        func notice(_ name: Notification.Name) { if announced { NotificationCenter.default.post(name: name, object: scroll) } }
        notice(NSScrollView.willStartLiveScrollNotification)
        var left = points
        while abs(left) > 0.5 {
            let step = max(-40, min(40, left))
            let end = max(0, document.frame.height - clip.bounds.height)
            let y = max(0, min(end, clip.bounds.minY - step))
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
            notice(NSScrollView.didLiveScrollNotification)
            left -= step
            await wait(0.03)
        }
        notice(NSScrollView.didEndLiveScrollNotification)
        await wait(0.4)
    }
    func report(_ what: String) {
        if ProcessInfo.processInfo.environment["MACCAPTIONS_SCROLL_TRACE"] != nil {
            print(String(format: "     [%@] from bottom %.0f | top of view at %.0f | content %.0f", what, fromBottom(), clip.bounds.minY, document.frame.height))
        }
    }

    report("opened")
    check("scroll: the panel opens at the newest line", fromBottom() < 30)
    for _ in 0..<3 { await speakOne() }
    report("3 sentences while at the end")
    check("scroll: at the end, it follows new lines", fromBottom() < 30)

    await wheel(500)
    let reading = clip.bounds.minY, distance = fromBottom()
    report("scrolled up")
    check("scroll: the view can be moved back into history", distance > 200)
    for _ in 0..<4 { await speakOne() }
    report("4 sentences while reading history")
    check("scroll: reading history, new lines do not move the view", abs(clip.bounds.minY - reading) < 4)
    check("scroll: ...although the newest lines were added below", fromBottom() > distance + 100)

    await wheel(-6000)
    report("scrolled back down")
    for _ in 0..<2 { await speakOne() }
    report("2 sentences after returning")
    check("scroll: back at the end, it follows again", fromBottom() < 30)

    await wheel(12)                                  // barely moved: still "at the latest"
    await speakOne()
    report("after a nudge of a few points")
    check("scroll: a tiny nudge near the end still counts as being at the end", fromBottom() < 30)

    await wheel(90)                                  // a few lines up: that is reading
    let nearby = clip.bounds.minY
    for _ in 0..<2 { await speakOne() }
    report("after scrolling a few lines up")
    check("scroll: a few lines up is already reading; the view stays", abs(clip.bounds.minY - nearby) < 4)

    engine.store.clear(); await wait(0.5)
    addFinished(30); await wait(0.6)
    report("cleared, then new lines")
    check("scroll: after Clear it follows again", fromBottom() < 30)
    window.orderOut(nil)
}

/// The rules by themselves, including a finger resting on the trackpad, which the scenario above cannot imitate.
private func runScrollRuleTests(_ check: (String, Bool) -> Void) {
    typealias P = ScrollFollow.Position
    func at(_ fromEnd: CGFloat, _ content: CGFloat = 2000) -> P { P(top: content - 300 - fromEnd, content: content, viewport: 300) }
    var f = ScrollFollow()
    check("follow: new text at the end moves the view", f.update(from: at(0), to: P(top: 1700, content: 2060, viewport: 300), readerIsScrolling: false) && f.following)
    check("follow: never while the reader is scrolling", !f.update(from: at(0), to: P(top: 1690, content: 2060, viewport: 300), readerIsScrolling: true) && !f.following)
    check("follow: ...and not afterwards, away from the end", !f.update(from: at(70, 2060), to: P(top: 1690, content: 2120, viewport: 300), readerIsScrolling: false))
    _ = f.update(from: at(70, 2120), to: at(10, 2120), readerIsScrolling: true)
    check("follow: a finger resting at the end: no jump yet, but it follows again", f.following
          && !f.update(from: at(10, 2120), to: P(top: 1810, content: 2180, viewport: 300), readerIsScrolling: true))
    var g = ScrollFollow()
    _ = g.update(from: at(0), to: at(200), readerIsScrolling: false)
    check("follow: moving up without a gesture (scroll bar) also stops following", !g.following)
    _ = g.update(from: at(200), to: at(5), readerIsScrolling: false)
    check("follow: and coming back to the end resumes", g.following)
    var h = ScrollFollow()
    _ = h.update(from: at(0), to: at(200), readerIsScrolling: false)
    _ = h.update(from: at(200), to: P(top: 0, content: 120, viewport: 300), readerIsScrolling: false)
    check("follow: after Clear (everything fits) it follows again", h.following)
    var k = ScrollFollow()
    _ = k.update(from: at(0), to: P(top: 1640, content: 1940, viewport: 300), readerIsScrolling: false)
    check("follow: a line disappearing at the end changes nothing", k.following)
}
#endif
