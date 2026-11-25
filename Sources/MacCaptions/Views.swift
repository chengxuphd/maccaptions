import SwiftUI

/// One caption: speaker label in a fixed column; English and Chinese share the same left edge.
struct LineRow: View {
    let line: CaptionLine
    var fontSize: Double = 13
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.source.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(line.source == .mic ? Color.blue : Color.orange)
                .frame(width: 34, alignment: .leading)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.en).font(.system(size: fontSize)).opacity(line.isFinal ? 1 : 0.6)
                if !line.zh.isEmpty {
                    Text(line.zh).font(.system(size: fontSize, weight: .medium)).opacity(line.isFinal ? 1 : 0.75)
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
    @ObservedObject var engine: CaptionEngine
    @ObservedObject var store: TranscriptStore
    @ObservedObject var settings: Settings

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

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Toggle("Floating window", isOn: $settings.showWindow)
                    Toggle("Translate live text", isOn: $settings.partialTranslation)
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
                Text("Menu bar width").font(.caption).foregroundStyle(.secondary)
                Slider(value: $settings.menuBarWidth, in: 160...1000, step: 10)
                Text("\(Int(settings.menuBarWidth))").font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
            }

            if store.hiddenEchoCount > 0 && settings.hideEcho {
                Text("\(store.hiddenEchoCount) mic line(s) hidden as echo of system audio")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.visibleLines) { LineRow(line: $0).id($0.id) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 6)
                }
                .onChange(of: store.lines.last?.en) { _, _ in
                    if let id = store.visibleLines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .padding(14)
        .frame(width: 480, height: 600, alignment: .topLeading)
        .onChange(of: settings.hideEcho) { _, on in engine.setEchoFilter(on) }
    }
}

/// Keeps the caption window from jittering: it grows at once when more room is needed, but only shrinks after the
/// content has stayed smaller for a while. (Without this the height flips every time a translation re-wraps.)
@MainActor
final class HeightStabilizer: ObservableObject {
    @Published private(set) var minHeight: CGFloat = 0
    private var latest: CGFloat = 0
    private var shrinkTask: Task<Void, Never>?
    private let shrinkDelay: Duration = .seconds(2.5)

    func report(_ h: CGFloat) {
        DispatchQueue.main.async { [self] in
            latest = h
            if h > minHeight + 0.5 {
                minHeight = h
                shrinkTask?.cancel(); shrinkTask = nil
            } else if h < minHeight - 0.5, shrinkTask == nil {
                shrinkTask = Task { [weak self] in
                    try? await Task.sleep(for: self?.shrinkDelay ?? .seconds(2.5))
                    guard !Task.isCancelled, let self else { return }
                    minHeight = latest; shrinkTask = nil
                }
            }
        }
    }
}

private struct NaturalHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Floating caption window content. Used for the real window and for the preview in the style window.
struct FloatingCaptionView: View {
    let lines: [CaptionLine]
    @ObservedObject var settings: Settings
    var width: CGFloat? = nil          // nil → the user's window width
    var placeholder = "Waiting for speech…"
    var minHeight: CGFloat = 0         // from HeightStabilizer (live window only)
    var onNaturalHeight: ((CGFloat) -> Void)? = nil

    private var showEn: Bool { settings.windowContent != .zh }
    private var showZh: Bool { settings.windowContent != .en }

    var body: some View {
        let enColor = Color(hex: settings.windowEnColorHex)
        let zhColor = Color(hex: settings.windowZhColorHex)
        let enFont = Font.system(size: settings.windowEnFontSize, weight: settings.windowBold ? .bold : .regular)
        let zhFont = Font.system(size: settings.windowFontSize, weight: settings.windowBold ? .bold : .medium)

        VStack(alignment: .leading, spacing: 8) {
            if lines.isEmpty {
                Text(placeholder).font(zhFont).foregroundStyle(zhColor.opacity(0.6 * settings.windowTextOpacity))
            }
            ForEach(lines) { line in
                let dim = line.isFinal ? 1.0 : 0.72
                HStack(alignment: .top, spacing: 8) {
                    if settings.windowShowSpeaker {
                        Text(line.source.label)
                            .font(.system(size: max(10, settings.windowEnFontSize * 0.7), weight: .semibold))
                            .foregroundStyle((line.source == .mic ? Color.cyan : Color.orange).opacity(settings.windowTextOpacity))
                            .frame(width: 40, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if showEn {
                            Text(line.en).font(enFont).foregroundStyle(enColor.opacity(dim * settings.windowTextOpacity))
                        }
                        if showZh {
                            if line.zh.isEmpty {
                                // Translation still pending: reserve the room it will need (≈ 1/3 as many Chinese
                                // characters as English ones) so the window doesn't jump when it arrives.
                                ZStack(alignment: .topLeading) {
                                    Text(String(repeating: "国", count: max(2, Int(Double(line.en.count) * 0.33))))
                                        .font(zhFont).hidden()
                                    Text("…").font(zhFont).foregroundStyle(zhColor.opacity(0.45 * settings.windowTextOpacity))
                                }
                            } else {
                                Text(line.zh).font(zhFont).foregroundStyle(zhColor.opacity(dim * settings.windowTextOpacity))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: width ?? CGFloat(settings.windowWidth), alignment: .leading)
        .background(GeometryReader { g in Color.clear.preference(key: NaturalHeightKey.self, value: g.size.height) })
        .onPreferenceChange(NaturalHeightKey.self) { onNaturalHeight?($0) }
        .frame(minHeight: minHeight, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(Color(hex: settings.windowBgColorHex).opacity(settings.windowNoBackground ? 0 : settings.windowBgOpacity)))
    }
}

/// The live (real) window: the newest N visible sentences.
struct LiveFloatingView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var settings: Settings
    @StateObject private var stabilizer = HeightStabilizer()
    var body: some View {
        FloatingCaptionView(lines: Array(store.visibleLines.suffix(settings.windowLines)), settings: settings,
                            minHeight: stabilizer.minHeight, onNaturalHeight: { stabilizer.report($0) })
            .contextMenu {
                Button("Show controls") { (NSApp.delegate as? AppDelegate)?.menuBar.showPanel() }
                Button("Window style…") { StyleWindowController.shared.show() }
                Button("Reset position (centred)") { NotificationCenter.default.post(name: .resetCaptionWindowPosition, object: nil) }
                Button("Hide window") { settings.showWindow = false }
                Divider()
                Button("Quit MacCaptions") { (NSApp.delegate as? AppDelegate)?.quit() }
            }
    }
}

/// Style editor with a live preview.
struct StyleView: View {
    @ObservedObject var settings: Settings

    private func color(_ kp: ReferenceWritableKeyPath<Settings, String>) -> Binding<Color> {
        Binding(get: { Color(hex: settings[keyPath: kp]) }, set: { settings[keyPath: kp] = $0.hexString })
    }
    private static let sample: [CaptionLine] = {
        var a = CaptionLine(source: .system, en: "So when we think about larger models, agents these days, there seems to be very different perspectives.")
        a.zh = "因此，当我们思考更大的模型、如今的智能体时，似乎存在非常不同的观点。"; a.isFinal = true
        var b = CaptionLine(source: .mic, en: "Can you hear me? I think you're on mute.")
        b.zh = "你能听到我说话吗？我觉得你静音了。"
        return [a, b]
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Preview").font(.caption).foregroundStyle(.secondary)
                ZStack {
                    // Checkerboard-ish neutral backdrop so background transparency is visible.
                    LinearGradient(colors: [.gray.opacity(0.5), .blue.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
                    FloatingCaptionView(lines: Self.sample, settings: settings, width: 500)
                }
                .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 10))

                GroupBox("Show") {
                    Picker("", selection: $settings.windowContent) {
                        ForEach(WindowContent.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().padding(4)
                }

                GroupBox("Text") {
                    VStack(alignment: .leading, spacing: 10) {
                        row("English", AnyView(ColorPicker("", selection: color(\.windowEnColorHex), supportsOpacity: false).labelsHidden()),
                            value: $settings.windowEnFontSize, range: 10...60, unit: "pt")
                        row("中文", AnyView(ColorPicker("", selection: color(\.windowZhColorHex), supportsOpacity: false).labelsHidden()),
                            value: $settings.windowFontSize, range: 10...72, unit: "pt")
                        HStack {
                            Text("Text opacity").frame(width: 90, alignment: .leading)
                            Slider(value: $settings.windowTextOpacity, in: 0.2...1)
                            Text("\(Int(settings.windowTextOpacity * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                        HStack(spacing: 20) {
                            Toggle("Bold", isOn: $settings.windowBold)
                            Toggle("Show Me / Them labels", isOn: $settings.windowShowSpeaker)
                        }
                    }.padding(6)
                }

                GroupBox("Background") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("No background (text only)", isOn: $settings.windowNoBackground)
                        Group {
                            HStack {
                                Text("Color").frame(width: 90, alignment: .leading)
                                ColorPicker("", selection: color(\.windowBgColorHex), supportsOpacity: false).labelsHidden()
                                Spacer()
                            }
                            HStack {
                                Text("Transparency").frame(width: 90, alignment: .leading)
                                Slider(value: $settings.windowBgOpacity, in: 0...1)
                                Text("\(Int(settings.windowBgOpacity * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                            }
                        }
                        .disabled(settings.windowNoBackground)
                        .opacity(settings.windowNoBackground ? 0.4 : 1)
                    }.padding(6)
                }

                GroupBox("Window") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Width").frame(width: 90, alignment: .leading)
                            Slider(value: $settings.windowWidth, in: 320...1600, step: 10)
                            Text("\(Int(settings.windowWidth))").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                        Stepper("Sentences shown: \(settings.windowLines)", value: $settings.windowLines, in: 1...8)
                        Text("Default: centred near the bottom of the screen. Drag the window anywhere to place it there; drag its left or right edge to change the width.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Reset position (centred)") {
                            NotificationCenter.default.post(name: .resetCaptionWindowPosition, object: nil)
                        }
                        Toggle("Click-through (the window ignores the mouse)", isOn: $settings.windowClickThrough)
                        Text("With click-through on you can't drag the window; turn it off here to move it.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(6)
                }

                HStack {
                    Toggle("Show caption window", isOn: $settings.showWindow)
                    Spacer()
                    Button("Reset to defaults") { settings.resetWindowStyle() }
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 700)
    }

    private func row(_ title: String, _ picker: AnyView, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            picker
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue)) \(unit)").monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }
}
