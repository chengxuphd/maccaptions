#if DEVTOOLS
import AppKit
import AVFoundation
import SwiftUI
import Darwin

/// MACCAPTIONS_SELFTEST=1: checks store / echo / LLM logic, prints PASS/FAIL lines, then quits.
@MainActor
func runSelfTests() async {
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
    // 6. Sessions saved by 0.1.0 / 0.1.1 in "LiveCaptions" move to "MacCaptions" — safely.
    let fm = FileManager.default
    func scratch() -> URL { let u = fm.temporaryDirectory.appendingPathComponent("mc-\(UUID().uuidString)"); try? fm.createDirectory(at: u, withIntermediateDirectories: true); return u }
    func touch(_ u: URL) { try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); fm.createFile(atPath: u.path, contents: Data("x".utf8)) }
    let d1 = scratch(); touch(d1.appendingPathComponent("LiveCaptions/2026-01-01_0900/session.json")); touch(d1.appendingPathComponent("LiveCaptions/.DS_Store"))
    SessionRecorder.migrateLegacyFolder(in: d1)
    check("migration: old sessions moved to MacCaptions", fm.fileExists(atPath: d1.appendingPathComponent("MacCaptions/2026-01-01_0900/session.json").path)
          && !fm.fileExists(atPath: d1.appendingPathComponent("LiveCaptions").path))
    let d2 = scratch(); touch(d2.appendingPathComponent("LiveCaptions/holiday-photos/img.jpg"))
    SessionRecorder.migrateLegacyFolder(in: d2)
    check("migration: a foreign 'LiveCaptions' folder is left alone", fm.fileExists(atPath: d2.appendingPathComponent("LiveCaptions/holiday-photos/img.jpg").path)
          && !fm.fileExists(atPath: d2.appendingPathComponent("MacCaptions").path))
    let d3 = scratch(); touch(d3.appendingPathComponent("LiveCaptions/2026-01-01_0900/session.json")); touch(d3.appendingPathComponent("MacCaptions/2026-02-02_1000/session.json"))
    SessionRecorder.migrateLegacyFolder(in: d3)
    check("migration: never overwrites an existing MacCaptions folder", fm.fileExists(atPath: d3.appendingPathComponent("LiveCaptions/2026-01-01_0900/session.json").path)
          && fm.fileExists(atPath: d3.appendingPathComponent("MacCaptions/2026-02-02_1000/session.json").path))
    for d in [d1, d2, d3] { try? fm.removeItem(at: d) }
    await runLLMSelfTests(check)
    await runScrollSelfTests(check)
    print(failed == 0 ? "ALL SELF-TESTS PASSED" : "\(failed) SELF-TEST(S) FAILED")
}
#endif
