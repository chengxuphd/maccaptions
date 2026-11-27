import Foundation

/// Holds finished sentences until their translations are in, then writes them strictly in the order they were spoken.
///
/// A sentence is written once (a) the echo-settling delay has passed, (b) Apple's translation has arrived, and
/// (c) the LLM, if one was asked, has answered or given up. `flushAll` writes whatever exists, so stopping or
/// shutting down never loses a line to a slow model. As a last resort no sentence waits longer than `maxWait`,
/// so one translation that never comes back cannot hold back everything spoken after it.
@MainActor
final class CommitQueue {
    private struct Entry {
        let id: Int
        let notBefore: Date
        let latest: Date
        var apple: String?
        var waitingForLLM: Bool
        var llm: LLMResult?
        let write: (_ apple: String, _ llm: LLMResult?) -> Void
    }

    private var entries: [Entry] = []
    private var nextID = 0
    private var timer: Task<Void, Never>?
    private let delay: TimeInterval

    private let maxWait: TimeInterval

    /// `maxWait` is longer than the LLM's own worst case (waiting + running at the highest time limit).
    init(delay: TimeInterval, maxWait: TimeInterval = 75) { self.delay = delay; self.maxWait = maxWait }

    var count: Int { entries.count }

    func add(expectsLLM: Bool, write: @escaping (_ apple: String, _ llm: LLMResult?) -> Void) -> Int {
        nextID += 1
        entries.append(Entry(id: nextID, notBefore: Date().addingTimeInterval(delay), latest: Date().addingTimeInterval(maxWait),
                             apple: nil, waitingForLLM: expectsLLM, write: write))
        pump()
        return nextID
    }

    func setApple(_ id: Int, _ text: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].apple = text
        pump()
    }

    func setLLM(_ id: Int, _ result: LLMResult?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].llm = result
        entries[i].waitingForLLM = false
        pump()
    }

    func flushAll() {
        timer?.cancel(); timer = nil
        let all = entries; entries = []
        for e in all { e.write(e.apple ?? "", e.llm) }
    }

    private func pump() {
        while let head = entries.first,
              (head.apple != nil && !head.waitingForLLM && Date() >= head.notBefore) || Date() >= head.latest {
            entries.removeFirst()
            head.write(head.apple ?? "", head.llm)
        }
        // Translations arrive through the setters; the timer covers the echo delay and the last-resort limit.
        timer?.cancel(); timer = nil
        if let head = entries.first {
            let next = head.notBefore > Date() ? head.notBefore : head.latest
            let wait = max(0, next.timeIntervalSinceNow)
            timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait + 0.01))
                if !Task.isCancelled { self?.pump() }
            }
        }
    }
}
