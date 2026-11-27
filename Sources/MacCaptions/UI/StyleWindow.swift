import AppKit
import SwiftUI

@MainActor
final class StyleWindowController {
    static let shared = StyleWindowController()
    private var window: NSWindow?
    var windowNumber: Int? { window?.windowNumber }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Caption window style"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: StyleView(settings: Settings.shared))
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
