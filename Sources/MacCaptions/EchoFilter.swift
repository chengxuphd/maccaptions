import Foundation

/// Text-level detection of "mic line is just the system audio heard through the speakers".
enum EchoFilter {
    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "twenty": "20", "hundred": "100",
    ]
    private static let stopwords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "to", "of", "and", "in", "it", "its", "i", "you",
        "he", "she", "we", "they", "that", "this", "for", "on", "with", "as", "at", "but", "or", "not", "so", "do",
        "um", "uh", "oh", "ah", "yeah", "okay", "ok", "my", "your", "me", "have", "has", "had", "if", "just", "like",
    ]

    /// Lowercased content words; number words → digits; stopwords removed.
    static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { numberWords[$0] ?? $0 }
            .filter { !stopwords.contains($0) }
    }

    private static func editDistanceAtMostOne(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > 1 { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1; if edits > 1 { return false }
            if a.count > b.count { i += 1 } else if a.count < b.count { j += 1 } else { i += 1; j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }

    static func matches(_ token: String, in pool: Set<String>) -> Bool {
        if pool.contains(token) { return true }
        guard token.count >= 5 else { return false }
        return pool.contains { $0.count >= 5 && editDistanceAtMostOne(token, $0) }
    }

    /// Fraction of the mic line's content words that also appear in the nearby system speech.
    /// Needs ≥ 3 content words; otherwise returns nil (too short to judge safely).
    static func echoFraction(mic: String, systemPool: Set<String>) -> Double? {
        let t = tokens(mic)
        guard t.count >= 3, !systemPool.isEmpty else { return nil }
        return Double(t.filter { matches($0, in: systemPool) }.count) / Double(t.count)
    }

    static let threshold = 0.7
}
