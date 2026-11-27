import SwiftUI

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
