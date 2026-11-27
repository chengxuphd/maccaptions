import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = CaptionEngine()
    var menuBar: MenuBarController!
    var floating: FloatingWindowController!
    var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(engine: engine)
        LLMSettingsWindowController.shared.configure(service: engine.llmService)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemWillPowerOff(_:)),
                                                          name: NSWorkspace.willPowerOffNotification, object: nil)
        floating = FloatingWindowController(store: engine.store, settings: engine.settings)
        floating.setVisible(engine.settings.showWindow)
        engine.settings.$showWindow.dropFirst().sink { [weak self] in self?.floating.setVisible($0) }.store(in: &bag)
        #if DEVTOOLS
        installDevHooks(self)
        #endif
    }

    private var quitting = false
    private var systemPoweringOff = false

    /// Quit cleanly: stop capture and finalize audio/transcripts FIRST, then terminate.
    /// (Doing the work inside applicationShouldTerminate/.terminateLater starves the main actor.)
    func quit() {
        #if DEVTOOLS
        PerfHarness.writeStats()
        #endif
        guard !quitting else { return }            // a second Cmd-Q while stopping must not re-enter
        quitting = true
        guard engine.running else { NSApp.terminate(nil); return }
        Task { await engine.stop(); NSApp.terminate(nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if systemPoweringOff || !engine.running { return .terminateNow }   // never block logout / shutdown
        quit(); return .terminateCancel                                    // e.g. Cmd-Q while capturing
    }

    /// Shutdown / logout: no time for the gentle stop — close files right now so nothing is left half-written.
    @objc func systemWillPowerOff(_ n: Notification) {
        systemPoweringOff = true
        engine.emergencyClose()
    }

    /// Launching the app again (Finder, Spotlight) opens the controls — the way back if the menu bar item is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar.showPanel()
        return true
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
