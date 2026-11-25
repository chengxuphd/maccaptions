import Foundation

enum Source: String { case mic, system
    var label: String { self == .mic ? "Me" : "Them" }
}

struct CaptionLine: Identifiable, Equatable {
    let id = UUID()
    let source: Source
    let start = Date()
    var updated = Date()
    var en: String
    var zh: String = ""
    var isFinal = false
    /// Mic line that is just the system audio heard through the speakers (hidden from views). Re-decided on every
    /// update while the line is young, so it can be un-hidden if the speaker keeps talking.
    var isEcho = false
}

@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var lines: [CaptionLine] = []
    private var current: [Source: UUID] = [:]
    private(set) var lastUpdated: UUID?

    var echoFilterEnabled = true {
        didSet {
            if echoFilterEnabled { reevaluateEcho() }
            else if lines.contains(where: { $0.isEcho }) {
                lines = lines.map { var l = $0; l.isEcho = false; return l }     // one update, not one per line
            }
        }
    }

    var visibleLines: [CaptionLine] { lines.filter { !$0.isEcho } }
    var hiddenEchoCount: Int { lines.reduce(0) { $0 + ($1.isEcho && $1.isFinal ? 1 : 0) } }
    // Sentences being touched are almost always at the end → search from the end.
    private func index(of id: UUID) -> Int? { lines.lastIndex(where: { $0.id == id }) }
    func line(id: UUID) -> CaptionLine? { index(of: id).map { lines[$0] } }
    func currentLine(for source: Source) -> CaptionLine? { current[source].flatMap(line(id:)) }

    /// Returns the id of the affected line.
    @discardableResult
    func update(source: Source, text: String, isFinal: Bool) -> UUID? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // The recognizer closed the sentence with no text: discard the in-progress line instead of keeping stale text.
            if isFinal, let cur = current[source], let i = index(of: cur) {
                lines.remove(at: i); current[source] = nil
                if lastUpdated == cur { lastUpdated = nil }
            }
            return nil
        }
        let id: UUID
        if let cur = current[source], let i = index(of: cur) {
            lines[i].en = text
            lines[i].isFinal = isFinal
            lines[i].updated = Date()
            if isFinal { current[source] = nil }
            id = cur
        } else {
            var line = CaptionLine(source: source, en: text)
            line.isFinal = isFinal
            lines.append(line)
            if !isFinal { current[source] = line.id }
            if lines.count > 1000 { lines.removeFirst(lines.count - 1000) }
            id = line.id
        }
        lastUpdated = id
        reevaluateEcho()
        return id
    }

    /// Does not move `lastUpdated`: a late translation of an older sentence must not hijack the display.
    func setZh(id: UUID, zh: String, forEn en: String) {
        guard let i = index(of: id), lines[i].en == en else { return }
        lines[i].zh = zh
    }

    /// A mic line is "echo" when most of its content words are in the system speech that overlaps it in time
    /// (±8 s). Re-decided each time while the line is young; finished lines freeze after 8 s.
    private func reevaluateEcho() {
        guard echoFilterEnabled else { return }
        let now = Date()
        let n = lines.count, lo = max(0, n - 40)
        guard lines[lo..<n].contains(where: { $0.source == .system }) else {
            if lines[lo..<n].contains(where: { $0.isEcho && !($0.isFinal && now.timeIntervalSince($0.updated) > 8) }) { unflagYoungEcho(lo, n, now) }
            return
        }
        var copy = lines
        var changed = false
        for i in lo..<n where lines[i].source == .mic {
            let m = lines[i]
            if m.isFinal && now.timeIntervalSince(m.updated) > 8 { continue }
            var pool = Set<String>()
            for j in lo..<n where lines[j].source == .system {
                let s = lines[j]
                if s.start <= m.updated.addingTimeInterval(8) && s.updated >= m.start.addingTimeInterval(-8) {
                    pool.formUnion(EchoFilter.tokens(s.en))
                }
            }
            let echo = (EchoFilter.echoFraction(mic: m.en, systemPool: pool) ?? 0) >= EchoFilter.threshold
            if echo != m.isEcho { copy[i].isEcho = echo; changed = true }
        }
        if changed { lines = copy }
    }

    private func unflagYoungEcho(_ lo: Int, _ n: Int, _ now: Date) {
        var copy = lines
        for i in lo..<n where copy[i].isEcho && !(copy[i].isFinal && now.timeIntervalSince(copy[i].updated) > 8) { copy[i].isEcho = false }
        lines = copy
    }

    /// Newest visible line (the one the menu bar shows).
    var latest: CaptionLine? {
        if let id = lastUpdated, let l = line(id: id), !l.isEcho { return l }
        return lines.last(where: { !$0.isEcho })
    }
    /// Most recent translation of any visible line.
    var latestZh: String { lines.last(where: { !$0.isEcho && !$0.zh.isEmpty })?.zh ?? "" }

    #if DEVTOOLS
    /// Sample content for screenshots/tests (MACCAPTIONS_DEMO=1).
    func loadDemo() {
        let rows: [(Source, String, String, Bool)] = [
            (.system, "So when we think about larger models, agents these days, there seems to be very different perspectives involved.", "因此，当我们思考更大的模型、如今的智能体时，似乎涉及非常不同的观点。", true),
            (.mic, "Can you hear me? I think you're on mute.", "你能听到我说话吗？我觉得你静音了。", true),
            (.system, "Let's circle back on this after the sprint review", "", false),
        ]
        for (src, en, zh, fin) in rows {
            if let id = update(source: src, text: en, isFinal: fin), !zh.isEmpty { setZh(id: id, zh: zh, forEn: en) }
        }
    }
    #endif
    func clear() { lines = []; current = [:]; lastUpdated = nil }
}
