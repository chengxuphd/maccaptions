import SwiftUI

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
                            if line.zh.isEmpty && line.zhMissing {
                                Text("—").font(zhFont).foregroundStyle(zhColor.opacity(0.45 * settings.windowTextOpacity))
                            } else if line.zh.isEmpty {
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
