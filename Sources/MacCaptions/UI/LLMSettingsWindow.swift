import AppKit
import SwiftUI

@MainActor
final class LLMSettingsWindowController {
    static let shared = LLMSettingsWindowController()
    private var window: NSWindow?
    private var service: LLMService?

    func configure(service: LLMService) { self.service = service }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "LLM translation"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: LLMSettingsView(settings: Settings.shared, service: service ?? LLMService()))
            w.center()
            window = w
        }
        // A menu bar app has no Edit menu, which is what normally makes ⌘C / ⌘V work in text fields.
        EditMenu.installIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Invisible main menu that provides the standard editing shortcuts (needed to paste an API key).
@MainActor
enum EditMenu {
    static func installIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu(title: "MacCaptions"); main.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(); editItem.submenu = edit; main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
