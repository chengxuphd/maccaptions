#if DEVTOOLS
import AppKit
import AVFoundation
import SwiftUI
import Darwin

/// Wires up the environment-variable test hooks. Only exists in DEVTOOLS builds.
@MainActor
func installDevHooks(_ d: AppDelegate) {
    let env = ProcessInfo.processInfo.environment
    let engine = d.engine
    // MACCAPTIONS_LLM_PROVIDER / _URL / _MODEL choose the LLM for a full-app test (only in a throw-away settings suite).
    if let name = env["MACCAPTIONS_LLM_PROVIDER"], env["MACCAPTIONS_LLM_BENCH"] == nil, env["MACCAPTIONS_LLM_PING"] == nil, env["MACCAPTIONS_DEFAULTS_SUITE"] != nil,
       let provider = LLMProvider(rawValue: name) {
        engine.settings.llmProvider = provider
        var p = LLMProfile.defaults(for: provider)
        if let u = env["MACCAPTIONS_LLM_URL"] { p.baseURL = u }
        if let m = env["MACCAPTIONS_LLM_MODEL"] { p.model = m }
        engine.settings.llmProfile = p
    }
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
    if env["MACCAPTIONS_SELFTEST"] != nil { Task { await runSelfTests(); fflush(stdout); NSApp.terminate(nil) } }
    if env["MACCAPTIONS_LLM_PING"] != nil { setvbuf(stdout, nil, _IOLBF, 0); Task { await runLLMPing(); fflush(stdout); NSApp.terminate(nil) } }
    if env["MACCAPTIONS_LLM_BENCH"] != nil { setvbuf(stdout, nil, _IOLBF, 0); Task { await runLLMBenchmark(); fflush(stdout); NSApp.terminate(nil) } }
    if env["MACCAPTIONS_LLM_PROBE"] != nil { Task { await runConnectionProbe(); fflush(stdout); NSApp.terminate(nil) } }
    if let dir = env["MACCAPTIONS_UI_SHOT"] {
        precondition(env["MACCAPTIONS_DEFAULTS_SUITE"] != nil, "screenshots change settings: set MACCAPTIONS_DEFAULTS_SUITE")
        Task { await renderUIShots(into: dir, engine: engine); fflush(stdout); NSApp.terminate(nil) }
    }
    // MACCAPTIONS_TOGGLE_REC / _TOGGLE_MIC / _TOGGLE_SYS = "10,20": flip that switch at those seconds.
    func seconds(_ key: String) -> [Double] { (env[key] ?? "").split(separator: ",").compactMap { Double($0) } }
    for t in seconds("MACCAPTIONS_TOGGLE_REC") { DispatchQueue.main.asyncAfter(deadline: .now() + t) { engine.toggleRecording() } }
    for t in seconds("MACCAPTIONS_TOGGLE_MIC") { DispatchQueue.main.asyncAfter(deadline: .now() + t) { engine.settings.micEnabled.toggle(); engine.applySourceSettings() } }
    for t in seconds("MACCAPTIONS_TOGGLE_SYS") { DispatchQueue.main.asyncAfter(deadline: .now() + t) { engine.settings.sysEnabled.toggle(); engine.applySourceSettings() } }
    // MACCAPTIONS_SWITCH_MODEL_AT=<seconds> changes the LLM model (as if the user edited it during a session).
    for t in seconds("MACCAPTIONS_SWITCH_MODEL_AT") {
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { var p = engine.settings.llmProfile; p.model = "switched-model"; engine.settings.llmProfile = p }
    }
    // MACCAPTIONS_MODE_AT="12:llm,20:apple" switches the translation mode at those seconds.
    for step in (env["MACCAPTIONS_MODE_AT"] ?? "").split(separator: ",") {
        let parts = step.split(separator: ":")
        guard parts.count == 2, let t = Double(parts[0]), let mode = TranslationMode(rawValue: String(parts[1])) else { continue }
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { engine.settings.translationMode = mode }
    }
    // MACCAPTIONS_STOP_AT=<seconds> presses "Stop captions" (the app keeps running).
    for t in seconds("MACCAPTIONS_STOP_AT") { DispatchQueue.main.asyncAfter(deadline: .now() + t) { engine.toggle() } }
    // MACCAPTIONS_AUTOSTOP=<seconds> quits cleanly after N seconds.
    if let n = Double(env["MACCAPTIONS_AUTOSTOP"] ?? "") { DispatchQueue.main.asyncAfter(deadline: .now() + n) { [weak d] in d?.quit() } }
}
#endif
