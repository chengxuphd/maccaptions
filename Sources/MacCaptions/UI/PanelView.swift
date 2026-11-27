import SwiftUI

/// One caption: speaker label in a fixed column; English and Chinese share the same left edge.
struct LineRow: View {
    let line: CaptionLine
    var fontSize: Double = 13
    var awaitsLLM = false          // "LLM" mode: a finished sentence shows "…" until the LLM answers
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(line.source.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(line.source == .mic ? Color.blue : Color.orange)
                if line.zhRefined {
                    Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(.secondary)
                        .help("Translated by the LLM")
                }
            }
            .frame(width: 34, alignment: .leading)
            .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.en).font(.system(size: fontSize)).opacity(line.isFinal ? 1 : 0.6)
                if !line.zh.isEmpty {
                    Text(line.zh).font(.system(size: fontSize, weight: .medium)).opacity(line.isFinal ? 1 : 0.75)
                } else if line.zhMissing {
                    Text("—").font(.system(size: fontSize)).foregroundStyle(.secondary).help("The LLM gave no translation")
                } else if awaitsLLM && line.isFinal {
                    Text("…").font(.system(size: fontSize)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Record button: separate from Start/Stop captions. Works at any time, also during a session.
struct RecordBar: View {
    @ObservedObject var engine: CaptionEngine
    @ObservedObject var recorder: SessionRecorder
    @ObservedObject var settings: Settings

    private func clock(_ s: Double) -> String { String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60) }

    var body: some View {
        HStack(spacing: 10) {
            Button { engine.toggleRecording() } label: {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let total = recorder.elapsed()
                    HStack(spacing: 6) {
                        Image(systemName: settings.recordAudio ? "stop.circle.fill" : "record.circle")
                            .foregroundStyle(.red)
                        Text(settings.recordAudio
                             ? (recorder.isRecording ? "Recording  \(clock(total))" : "Recording on")
                             : "Record audio")
                    }
                }
            }
            .controlSize(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.recordAudio
                     ? (engine.running ? "Saving mic + system audio. Click to stop." : "Will record when captions start.")
                     : "Audio not being saved. Text is always saved.")
                    .font(.caption).foregroundStyle(.secondary)
                if let url = recorder.sessionURL {
                    Button("Show session in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            Spacer()
        }
    }
}

/// Content of the menu bar panel.
struct PanelView: View {
    static let size = CGSize(width: 480, height: 630)
    @ObservedObject var engine: CaptionEngine
    @ObservedObject var store: TranscriptStore
    @ObservedObject var settings: Settings

    private var liveTextHelp: String {
        if settings.translationMode != .llm { return "Translate sentences while they are still being spoken (Apple)" }
        return settings.llmConfig.allowsLiveTranslation
            ? "Your local model translates sentences while they are being spoken (keeps it busier)"
            : "Only with a local model: a cloud service would be asked, and charged, about once a second"
    }

    private var liveTextAvailable: Bool { settings.translationMode != .llm || settings.llmConfig.allowsLiveTranslation }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(engine.running ? "Stop captions" : "Start captions") { engine.toggle() }
                    .keyboardShortcut(.defaultAction)
                Text(engine.displayStatus)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Button("Clear") { store.clear() }
                Button("Quit") { (NSApp.delegate as? AppDelegate)?.quit() }
            }

            // Independent source switches: each one really stops/starts that capture (also while a session runs).
            HStack(spacing: 22) {
                Toggle(isOn: $settings.micEnabled) { Label("Microphone", systemImage: settings.micEnabled ? "mic.fill" : "mic.slash") }
                Toggle(isOn: $settings.sysEnabled) { Label("System audio", systemImage: settings.sysEnabled ? "speaker.wave.2.fill" : "speaker.slash") }
                Spacer()
            }
            .toggleStyle(.switch)
            .onChange(of: settings.micEnabled) { _, _ in engine.applySourceSettings() }
            .onChange(of: settings.sysEnabled) { _, _ in engine.applySourceSettings() }

            RecordBar(engine: engine, recorder: engine.recorder, settings: settings)

            VStack(alignment: .leading, spacing: 4) {
                Text("Menu bar text").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $settings.menuBarMode) {
                    ForEach(MenuBarMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            TranslationBar(settings: settings, llm: engine.llm)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Toggle("Floating window", isOn: $settings.showWindow)
                    Toggle("Translate live text", isOn: $settings.partialTranslation)
                        .disabled(!liveTextAvailable)
                        .help(liveTextHelp)
                }
                GridRow {
                    Button("Window style…") { StyleWindowController.shared.show() }
                    Color.clear.frame(height: 0)
                }
                GridRow {
                    Toggle("Hide mic echo", isOn: $settings.hideEcho)
                        .help("Hides mic lines that just repeat what the system audio said (compares the words)")
                    Toggle("Apple echo cancel", isOn: $settings.echoCancel)
                        .help("Apple voice processing on the mic. Removes more echo but slightly lowers other audio. Applies when the microphone is switched on.")
                }
            }

            HStack(spacing: 8) {
                Text("Live update").font(.caption).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
                Slider(value: $settings.liveInterval, in: 1...6, step: 1)
                Text(settings.liveInterval <= 1 ? "fastest" : "every \(Int(settings.liveInterval)) s")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            }
            .disabled(!liveTextAvailable || !settings.partialTranslation)
            .help("How often the Chinese is updated while someone is still speaking. “Fastest” follows the speech recognition, about once a second. Finished sentences are not affected.")

            HStack(spacing: 8) {
                Text("Menu bar width").font(.caption).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
                Slider(value: $settings.menuBarWidth, in: 160...1000, step: 10)
                Text("\(Int(settings.menuBarWidth))").font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            }

            if store.hiddenEchoCount > 0 && settings.hideEcho {
                Text("\(store.hiddenEchoCount) mic line(s) hidden as echo of system audio")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Divider()

            TranscriptView(store: store, awaitsLLM: settings.translationMode == .llm)
        }
        .padding(14)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .onChange(of: settings.hideEcho) { _, on in engine.setEchoFilter(on) }
    }
}
