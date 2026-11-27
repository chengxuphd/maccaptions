import Foundation

/// Cleans a model's reply and decides whether it can be trusted as a caption. A rejected reply is simply not used:
/// the Apple translation stays on screen.
enum LLMOutput {
    enum Rejection: Error, Equatable, CustomStringConvertible {
        case empty, truncated, onlyThinking, notChinese, tooLong, chatter, repeatedPrompt
        var description: String {
            switch self {
            case .empty: "empty reply"
            case .truncated: "reply was cut off"
            case .onlyThinking: "the model only returned its reasoning (choose a model whose thinking can be turned off)"
            case .notChinese: "reply was not Chinese"
            case .tooLong: "reply was far longer than a translation"
            case .chatter: "the model talked instead of translating"
            case .repeatedPrompt: "the model repeated the context or its instructions"
            }
        }
    }

    static func clean(_ raw: String, source: String, finishReason: String? = nil) throws -> String {
        var s = removeThinking(raw)
        let hadThinking = s != raw
        // Chat-template markers that some local servers leave in the text.
        s = s.replacingOccurrences(of: "<[|｜][^<>]{1,40}[|｜]>|</?(?:end_of_turn|start_of_turn|s)>|<end_of_turn>|<start_of_turn>",
                                   with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            var lines = s.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            s = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        s = s.replacingOccurrences(of: "^(?:(?:中文)?(?:翻译|译文)(?:结果)?|(?:Chinese )?Translation)\\s*[:：]\\s*",
                                   with: "", options: [.regularExpression, .caseInsensitive])
        // Some models (Gemma 4 does this often) start their answer by repeating the prompt's own "Translate:" label.
        if source.range(of: "^\\s*translat", options: [.regularExpression, .caseInsensitive]) == nil {
            s = s.replacingOccurrences(of: "^Translate\\s*[:：]\\s*", with: "", options: [.regularExpression, .caseInsensitive])
        }
        // "好的，以下是翻译：…" – keep only the translation (unless the speaker really said something about a translation).
        if source.range(of: "translat", options: .caseInsensitive) == nil {
            s = s.replacingOccurrences(of: "^(?:(?:好的|当然|没问题)[，,。！!]?\\s*)?(?:以下|下面|这)(?:是|为)[^:：\\n]{0,12}(?:翻译|译文)(?:结果)?\\s*[:：]\\s*",
                                       with: "", options: .regularExpression)
        }
        s = unquote(s, source: source)
        s = singleLine(s)

        if finishReason == "length" { throw Rejection.truncated }
        if s.isEmpty { throw hadThinking ? Rejection.onlyThinking : Rejection.empty }
        if s.range(of: "作为一个?(?:AI|人工智能)|^(?:Here(?:'s| is)|Sure[,!]|Certainly|Of course|The translation)",
                   options: [.regularExpression, .caseInsensitive]) != nil,
           source.range(of: "(?i)\\bAI\\b|artificial intelligence|^(?:here|sure|certainly|of course|the translation)",
                        options: .regularExpression) == nil {
            throw Rejection.chatter
        }
        // A Chinese translation is normally shorter in characters than its English source.
        if s.count > max(40, Int(Double(source.count) * 1.2)) { throw Rejection.tooLong }
        // Names, numbers or code may legitimately stay as they are, so only longer sentences must contain Chinese.
        let words = source.split(whereSeparator: { !$0.isLetter }).count
        if words >= 3 && !s.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { throw Rejection.notChinese }
        return s
    }

    /// Small translation models sometimes translate the background sentences too, or echo the prompt's headings.
    /// The length check catches the obvious cases; this catches short ones, which would otherwise be saved as captions.
    static func repeatsPrompt(raw: String, cleaned: String, source: String, hadContext: Bool, style: PromptStyle) -> Bool {
        let headings = "背景信息\\s*[:：\\]】]|[\\[【](?:背景信息|源文本|原文)[\\]】]|\\[(?:Background|Source)|Background Information|请将以下(?:文本|内容)|Earlier sentences\\s*[:：]"
        if cleaned.range(of: headings, options: .regularExpression) != nil,
           source.range(of: "(?i)background|source", options: .regularExpression) == nil { return true }
        // Translation models answer with exactly one line.
        if style == .hyMT && removeThinking(raw).split(whereSeparator: \.isNewline)
            .filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count > 1 { return true }
        // With context in the prompt, clearly more sentences than were spoken means earlier ones came along.
        guard hadContext else { return false }
        func sentences(_ s: String) -> Int {                  // "12.5" and "p.m. Pacific" are not sentence ends
            let pattern = "[。！？!?]+|(?<=[A-Za-z]{2})\\.(?=\\s|$)"
            return (try? NSRegularExpression(pattern: pattern))?.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) ?? 0
        }
        return sentences(cleaned) >= max(1, sentences(source)) + 2
    }

    /// Removes reasoning blocks, including ones that span lines, never close, or have lost their opening tag.
    static func removeThinking(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "(?s)<think(?:ing)?>.*?</think(?:ing)?>", with: "", options: .regularExpression)
        if let r = out.range(of: "</think(?:ing)?>", options: [.regularExpression, .backwards]) { out = String(out[r.upperBound...]) }
        if let r = out.range(of: "<think(?:ing)?>", options: .regularExpression) { out = String(out[..<r.lowerBound]) }
        return out
    }

    /// Strips quotes that wrap the whole reply, unless the source was quoted too.
    private static func unquote(_ s: String, source: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」"), ("'", "'")]
        guard s.count >= 2, let first = s.first, let last = s.last,
              !source.trimmingCharacters(in: .whitespaces).hasPrefix("\""),
              !source.trimmingCharacters(in: .whitespaces).hasPrefix("“") else { return s }
        for (a, b) in pairs where first == a && last == b {
            let inner = s.dropFirst().dropLast()
            if !inner.contains(a) && !inner.contains(b) { return String(inner).trimmingCharacters(in: .whitespaces) }
        }
        return s
    }

    /// Captions are one line. Chinese text is joined without a space; Latin text with one.
    private static func singleLine(_ s: String) -> String {
        var out = ""
        for part in s.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            if let a = out.last, let b = part.first, a.isASCII, b.isASCII { out += " " }
            out += part
        }
        return out
    }
}
