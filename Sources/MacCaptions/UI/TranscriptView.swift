import SwiftUI

/// Whether the transcript should keep showing the newest line, or stay where the reader is.
struct ScrollFollow: Equatable {
    struct Position: Equatable {
        var top: CGFloat              // how far the view is scrolled from the first line
        var content: CGFloat          // height of the whole transcript
        var viewport: CGFloat         // height of the visible part
        var fromEnd: CGFloat { max(0, content - viewport - top) }
    }

    /// This close to the end still counts as "at the latest": less than one line of text.
    static let endZone: CGFloat = 30
    private(set) var following = true

    /// Takes in a change of position or size. Returns true if the view should now move to the end.
    mutating func update(from old: Position, to new: Position, readerIsScrolling: Bool) -> Bool {
        let resized = new.content != old.content || new.viewport != old.viewport
        if new.content <= new.viewport {
            following = true                                      // everything fits: nothing to scroll
        } else if readerIsScrolling {
            following = new.fromEnd <= Self.endZone               // the reader decides
        } else if new.top < old.top - 1 && new.fromEnd > Self.endZone {
            following = false                                     // moved towards older lines (e.g. by the scroll bar)
        } else if !resized && new.fromEnd <= Self.endZone {
            following = true                                      // came back to the end
        }
        // New text only ever makes the view move if it was already following, and never under the reader's fingers.
        return resized && following && !readerIsScrolling && new.fromEnd > 0.5
    }
}

/// The panel's transcript. It follows new lines while you are at the end; scroll up to read and it stays put.
struct TranscriptView: View {
    @ObservedObject var store: TranscriptStore
    var awaitsLLM: Bool

    @State private var follow = ScrollFollow()
    @State private var readerIsScrolling = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.visibleLines) { LineRow(line: $0, awaitsLLM: awaitsLLM).id($0.id) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 6)
            }
            // No `defaultScrollAnchor(.bottom)`: even limited to the initial position it kept pulling the view to the end
            // when SwiftUI had not noticed the reader scroll. The rule below also opens the panel at the newest line.
            .onScrollPhaseChange { _, phase in
                readerIsScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            // Watching the size catches every kind of new text, including a translation arriving under the last line.
            .onScrollGeometryChange(for: ScrollFollow.Position.self) { g in
                ScrollFollow.Position(top: g.contentOffset.y + g.contentInsets.top, content: g.contentSize.height,
                                      viewport: g.containerSize.height)
            } action: { old, new in
                if follow.update(from: old, to: new, readerIsScrolling: readerIsScrolling), let last = store.visibleLines.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
}
