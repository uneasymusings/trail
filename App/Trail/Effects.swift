import SwiftUI

// Small ASCII motion for moments when something is loading. Everything else stays still.
// Each one holds still with Reduce Motion.

/// Text that resolves out of noise, like a terminal catching up.
struct DecodeText: View {
    let text: String
    var duration: Double = 0.4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var settled = false

    static let noise = Array("01/+:_-")

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: settled || reduceMotion)) { timeline in
            Text(settled || reduceMotion ? text : frame(at: timeline.date))
        }
        .task(id: text) {
            start = .now
            settled = false
            try? await Task.sleep(for: .seconds(duration))
            settled = true
        }
    }

    private func frame(at date: Date) -> String {
        let progress = min(1, date.timeIntervalSince(start) / duration)
        let characters = Array(text)
        let revealed = Int(Double(characters.count) * progress)
        let tick = Int(date.timeIntervalSinceReferenceDate * 30)
        return String(characters.enumerated().map { index, character in
            index < revealed || character == " " ? character : Self.noise[(index * index + index * 3 + tick) % Self.noise.count]
        })
    }
}

struct BrailleSpinner: View {
    static let frames = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.08)) { timeline in
            let index = reduceMotion ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate / 0.08) % Self.frames.count
            Text(String(Self.frames[index]))
        }
    }
}

/// An indeterminate bar of shade blocks: a solid head with a fading tail.
struct ShadeBar: View {
    var width = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: reduceMotion)) { timeline in
            let head = Int(timeline.date.timeIntervalSinceReferenceDate * 12) % (width + 6)
            Text(String((0..<width).map { index -> Character in
                switch head - index {
                case 0: "█"
                case 1, 2: "▓"
                case 3, 4: "▒"
                default: "░"
                }
            }))
        }
    }
}

struct LoadingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { timeline in
            let count = Int(timeline.date.timeIntervalSinceReferenceDate / 0.3) % 4
            Text(String(repeating: ".", count: count) + String(repeating: " ", count: 3 - count))
        }
    }
}
