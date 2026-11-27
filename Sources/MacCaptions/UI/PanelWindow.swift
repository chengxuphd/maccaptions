import AppKit
import SwiftUI

/// A borderless window that can become key, so buttons/toggles/sliders respond.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Replaces NSPopover (unreliable for menu-bar-only apps): a real panel that activates the app.
@MainActor
final class PanelWindowController: NSObject {
    private var panel: KeyablePanel?
    private let engine: CaptionEngine
    private var lastClosed = Date.distantPast
    var isShown: Bool { panel?.isVisible ?? false }

    init(engine: CaptionEngine) { self.engine = engine }

    func toggle(below button: NSStatusBarButton) {
        if isShown { close(); return }
        if Date().timeIntervalSince(lastClosed) < 0.25 { return }   // click that just dismissed it
        show(below: button)
    }

    func close() { panel?.orderOut(nil); lastClosed = Date() }

    func show(below button: NSStatusBarButton) {
        if panel == nil { panel = makePanel() }
        guard let panel else { return }
        let size = panel.frame.size
        var origin = NSPoint(x: 100, y: 100)
        if let win = button.window {
            let r = win.convertToScreen(button.convert(button.bounds, to: nil))
            origin = NSPoint(x: r.midX - size.width / 2, y: r.minY - size.height - 6)
            if let screen = win.screen ?? NSScreen.main {
                let f = screen.visibleFrame
                origin.x = min(max(origin.x, f.minX + 8), f.maxX - size.width - 8)
                origin.y = max(origin.y, f.minY + 8)
            }
        }
        panel.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> KeyablePanel {
        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: PanelView.size),
                             styleMask: [.borderless, .fullSizeContentView],
                             backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSHostingView(rootView: PanelView(engine: engine, store: engine.store, settings: engine.settings))
        host.frame = NSRect(origin: .zero, size: PanelView.size)
        let bg = NSVisualEffectView(frame: host.frame)
        bg.material = .popover
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        bg.addSubview(host)
        host.autoresizingMask = [.width, .height]
        p.contentView = bg

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        return p
    }
}
