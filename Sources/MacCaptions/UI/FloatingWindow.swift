import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    static let resetCaptionWindowPosition = Notification.Name("MacCaptions.resetCaptionWindowPosition")
}

/// Hosting view that makes the whole caption window draggable and its left/right edges resizable.
/// (SwiftUI content can swallow the mouse events that `isMovableByWindowBackground` relies on, so we do it explicitly.)
final class DragHostingView<Content: View>: NSHostingView<Content> {
    private enum Mode { case move, resizeLeft, resizeRight }
    private var mode = Mode.move
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero
    private let edge: CGFloat = 10
    var onWidthChange: ((CGFloat) -> Void)?
    var onMoved: (() -> Void)?
    var isCentered: () -> Bool = { false }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let p = convert(event.locationInWindow, from: nil)
        mode = p.x > bounds.width - edge ? .resizeRight : (p.x < edge ? .resizeLeft : .move)
        startMouse = NSEvent.mouseLocation
        startFrame = window.frame
        if mode == .move {
            window.performDrag(with: event)                    // runs the drag loop until the button is released
            if window.frame.origin != startFrame.origin { onMoved?() }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, mode != .move else { return }
        let dx = NSEvent.mouseLocation.x - startMouse.x
        var f = startFrame
        // Centred window: both sides move together, so the dragged edge follows the cursor and the window stays centred.
        let k: CGFloat = isCentered() ? 2 : 1
        switch mode {
        case .resizeRight: f.size.width = startFrame.width + k * dx
        case .resizeLeft:  f.size.width = startFrame.width - k * dx
        case .move: return
        }
        let w = min(max(f.size.width, 320), 1600)
        f.size.width = w
        if isCentered() { f.origin.x = startFrame.midX - w / 2 }
        else if mode == .resizeLeft { f.origin.x = startFrame.maxX - w }
        window.setFrame(f, display: true)
        onWidthChange?(w)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas where t.owner === self { removeTrackingArea(t) }
        for r in [NSRect(x: 0, y: 0, width: edge, height: bounds.height),
                  NSRect(x: bounds.width - edge, y: 0, width: edge, height: bounds.height)] {
            addTrackingArea(NSTrackingArea(rect: r, options: [.cursorUpdate, .activeAlways], owner: self, userInfo: nil))
        }
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
}

@MainActor
final class FloatingWindowController {
    private var panel: NSPanel?
    private var host: DragHostingView<LiveFloatingView>?
    private let store: TranscriptStore
    private let settings: Settings
    private var bag = Set<AnyCancellable>()

    init(store: TranscriptStore, settings: Settings) {
        self.store = store; self.settings = settings
        // Re-fit the window to its content whenever text or style changes.
        store.objectWillChange.merge(with: settings.objectWillChange)
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refit() }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: .resetCaptionWindowPosition)
            .sink { [weak self] _ in self?.resetPosition() }
            .store(in: &bag)
    }

    func setVisible(_ visible: Bool) {
        if visible {
            if panel == nil { panel = makePanel() }
            panel?.orderFrontRegardless()
            refit()
        } else {
            panel?.orderOut(nil)
        }
    }

    var frame: NSRect? { panel?.frame }
    var windowNumber: Int? { panel.map { $0.windowNumber } }

    /// Default position: horizontally centred on the screen the window is on, a little above the bottom.
    private func centredOrigin(width: CGFloat, on screen: NSScreen?) -> NSPoint {
        let vf = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vf.midX - width / 2, y: vf.minY + 60)
    }

    /// Back to the default: centred.
    func resetPosition() {
        settings.windowCustomPosition = false
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
        refit()
    }

    /// Size the window to its content. Default mode: always centred horizontally. After the user has dragged it:
    /// the position is kept (bottom edge fixed, so it grows upward).
    private func refit() {
        guard let panel, let host, panel.isVisible else { return }
        panel.ignoresMouseEvents = settings.windowClickThrough
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 10, size.height > 10 else { return }
        var f = panel.frame
        f.size = size
        if !settings.windowCustomPosition { f.origin = centredOrigin(width: size.width, on: panel.screen) }
        if abs(f.width - panel.frame.width) > 0.5 || abs(f.height - panel.frame.height) > 0.5
            || abs(f.origin.x - panel.frame.origin.x) > 0.5 || abs(f.origin.y - panel.frame.origin.y) > 0.5 {
            panel.setFrame(f, display: true)
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: settings.windowWidth, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = false   // dragging is handled by DragHostingView
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let h = DragHostingView(rootView: LiveFloatingView(store: store, settings: settings))
        h.onWidthChange = { [weak self] w in self?.settings.windowWidth = Double(w) }
        h.onMoved = { [weak self] in self?.settings.windowCustomPosition = true }
        h.isCentered = { [weak self] in !(self?.settings.windowCustomPosition ?? false) }
        host = h
        p.contentView = h
        // Default: centred. Only if the user has dragged the window before do we restore their spot.
        let restored = p.setFrameAutosaveName("MacCaptionsFloatingWindow")
        let onScreen = NSScreen.screens.contains(where: { $0.frame.intersects(p.frame) })
        if settings.windowCustomPosition && restored && onScreen {
            // keep the restored origin
        } else {
            settings.windowCustomPosition = false
            p.setFrameOrigin(centredOrigin(width: settings.windowWidth, on: NSScreen.main))
        }
        return p
    }
}
