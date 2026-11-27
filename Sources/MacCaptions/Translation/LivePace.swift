import Foundation

/// The pace of live translation (of sentences still being spoken). Finished sentences are never held back.
enum LivePace {
    /// The recognizer reports a burst of changes at once; waiting this long sends only the last of them.
    static let settle: TimeInterval = 0.12

    /// The least time between two updates of one sentence, for the "update every N seconds" setting. The recognizer's
    /// bursts are not exactly a second apart, so a little less than N is required, or every other one would be missed.
    static func spacing(forSetting seconds: Double) -> TimeInterval { seconds <= 1 ? 0 : seconds - 0.35 }

    /// How long to wait before translating the newest text of a sentence whose previous update started at `last`.
    static func wait(last: Date?, spacing: TimeInterval, now: Date) -> TimeInterval {
        max(settle, last.map { spacing - now.timeIntervalSince($0) } ?? 0)
    }
}
