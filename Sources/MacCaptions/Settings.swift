import Foundation

enum MenuBarMode: String, CaseIterable, Identifiable {
    case en, zh, mix
    var id: String { rawValue }
    var label: String {
        switch self { case .en: "English"; case .zh: "中文"; case .mix: "Mix" }
    }
}

enum WindowContent: String, CaseIterable, Identifiable {
    case both, zh, en
    var id: String { rawValue }
    var label: String {
        switch self { case .both: "English + 中文"; case .zh: "中文 only"; case .en: "English only" }
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var menuBarMode: MenuBarMode { didSet { d.set(menuBarMode.rawValue, forKey: "menuBarMode") } }
    @Published var showMenuBar: Bool { didSet { d.set(showMenuBar, forKey: "showMenuBar") } }
    @Published var showWindow: Bool { didSet { d.set(showWindow, forKey: "showWindow") } }
    /// Apple voice processing on the mic (lowers other audio slightly) — off by default.
    @Published var echoCancel: Bool { didSet { d.set(echoCancel, forKey: "voiceProcessing") } }
    @Published var micEnabled: Bool { didSet { d.set(micEnabled, forKey: "micEnabled") } }
    @Published var sysEnabled: Bool { didSet { d.set(sysEnabled, forKey: "sysEnabled") } }
    /// Hide mic lines that just repeat the system audio (text match).
    @Published var hideEcho: Bool { didSet { d.set(hideEcho, forKey: "hideEcho") } }
    /// Recording is ON at every launch (by design: "record by default"); the button only changes the current run.
    @Published var recordAudio: Bool
    @Published var partialTranslation: Bool { didSet { d.set(partialTranslation, forKey: "partialTranslation") } }
    @Published var windowFontSize: Double { didSet { d.set(windowFontSize, forKey: "windowFontSize") } }
    @Published var windowLines: Int { didSet { d.set(windowLines, forKey: "windowLines") } }
    @Published var menuBarWidth: Double { didSet { d.set(menuBarWidth, forKey: "menuBarWidth") } }
    /// Mix mode: share of the width given to the English part (the divider sits at this fixed position).
    @Published var menuBarMixShare: Double { didSet { d.set(menuBarMixShare, forKey: "menuBarMixShare") } }

    // Floating window style
    @Published var windowContent: WindowContent { didSet { d.set(windowContent.rawValue, forKey: "windowContent") } }
    @Published var windowEnFontSize: Double { didSet { d.set(windowEnFontSize, forKey: "windowEnFontSize") } }
    @Published var windowEnColorHex: String { didSet { d.set(windowEnColorHex, forKey: "windowEnColorHex") } }
    @Published var windowZhColorHex: String { didSet { d.set(windowZhColorHex, forKey: "windowZhColorHex") } }
    @Published var windowTextOpacity: Double { didSet { d.set(windowTextOpacity, forKey: "windowTextOpacity") } }
    @Published var windowBgColorHex: String { didSet { d.set(windowBgColorHex, forKey: "windowBgColorHex") } }
    @Published var windowBgOpacity: Double { didSet { d.set(windowBgOpacity, forKey: "windowBgOpacity") } }
    /// Checkbox: draw no background box at all (just the text).
    @Published var windowNoBackground: Bool { didSet { d.set(windowNoBackground, forKey: "windowNoBackground") } }
    @Published var windowBold: Bool { didSet { d.set(windowBold, forKey: "windowBold") } }
    @Published var windowShowSpeaker: Bool { didSet { d.set(windowShowSpeaker, forKey: "windowShowSpeaker") } }
    @Published var windowWidth: Double { didSet { d.set(windowWidth, forKey: "windowWidth") } }
    @Published var windowClickThrough: Bool { didSet { d.set(windowClickThrough, forKey: "windowClickThrough") } }
    /// false = default: window stays horizontally centred (near the bottom). true = the user dragged it somewhere.
    @Published var windowCustomPosition: Bool { didSet { d.set(windowCustomPosition, forKey: "windowCustomPosition") } }

    private init() {
        d.register(defaults: [
            "menuBarMode": MenuBarMode.zh.rawValue, "showMenuBar": true, "showWindow": false,
            "voiceProcessing": false, "micEnabled": true, "sysEnabled": true, "hideEcho": true, "recordAudio": true, "partialTranslation": true,
            "windowFontSize": 20.0, "windowLines": 3,
            "windowContent": WindowContent.both.rawValue, "windowEnFontSize": 16.0,
            "windowEnColorHex": "#D9D9D9", "windowZhColorHex": "#FFFFFF", "windowTextOpacity": 1.0,
            "windowBgColorHex": "#000000", "windowBgOpacity": 0.72, "windowNoBackground": false, "windowBold": false,
            "windowShowSpeaker": false, "windowWidth": 760.0, "windowClickThrough": false, "windowCustomPosition": false, "menuBarWidth": 380.0, "menuBarMixShare": 0.56,
        ])
        menuBarMode = MenuBarMode(rawValue: d.string(forKey: "menuBarMode") ?? "") ?? .zh
        showMenuBar = d.bool(forKey: "showMenuBar")
        showWindow = d.bool(forKey: "showWindow")
        echoCancel = d.bool(forKey: "voiceProcessing")
        micEnabled = d.bool(forKey: "micEnabled")
        sysEnabled = d.bool(forKey: "sysEnabled")
        hideEcho = d.bool(forKey: "hideEcho")
        recordAudio = true
        partialTranslation = d.bool(forKey: "partialTranslation")
        windowFontSize = d.double(forKey: "windowFontSize")
        windowLines = d.integer(forKey: "windowLines")
        menuBarWidth = d.double(forKey: "menuBarWidth")
        menuBarMixShare = d.double(forKey: "menuBarMixShare")
        windowContent = WindowContent(rawValue: d.string(forKey: "windowContent") ?? "") ?? .both
        windowEnFontSize = d.double(forKey: "windowEnFontSize")
        windowEnColorHex = d.string(forKey: "windowEnColorHex") ?? "#D9D9D9"
        windowZhColorHex = d.string(forKey: "windowZhColorHex") ?? "#FFFFFF"
        windowTextOpacity = d.double(forKey: "windowTextOpacity")
        windowBgColorHex = d.string(forKey: "windowBgColorHex") ?? "#000000"
        windowBgOpacity = d.double(forKey: "windowBgOpacity")
        windowNoBackground = d.bool(forKey: "windowNoBackground")
        windowBold = d.bool(forKey: "windowBold")
        windowShowSpeaker = d.bool(forKey: "windowShowSpeaker")
        windowWidth = d.double(forKey: "windowWidth")
        windowClickThrough = d.bool(forKey: "windowClickThrough")
        windowCustomPosition = d.bool(forKey: "windowCustomPosition")
    }

    func resetWindowStyle() {
        windowContent = .both; windowEnFontSize = 16; windowFontSize = 20
        windowEnColorHex = "#D9D9D9"; windowZhColorHex = "#FFFFFF"; windowTextOpacity = 1
        windowBgColorHex = "#000000"; windowBgOpacity = 0.72; windowNoBackground = false; windowBold = false
        windowShowSpeaker = false; windowWidth = 760; windowLines = 3; windowClickThrough = false
    }
}
