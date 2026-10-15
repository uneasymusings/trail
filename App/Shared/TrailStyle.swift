import SwiftUI

/// Trail's look, shared by the app and the widget: plain system glass and semantic colors,
/// SF Mono for small labels, and ASCII only where something is loading.
enum Theme {
    /// The one easing curve, everywhere.
    static let ease = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.4)
    static let quick = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.25)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// "now", "4m", "3h", "2d", "Oct 3" — short enough for a mono column.
    static func age(_ date: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        case ..<(86_400 * 7): return "\(Int(seconds / 86_400))d"
        default:
            let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).year())
        }
    }
}

/// Trail's mark: a short run of dots rising to the right, each stronger than the last.
struct TrailMark: View {
    var size: CGFloat = 14

    var body: some View {
        Canvas { context, canvas in
            for (point, radius, alpha) in TrailMark.dots(in: canvas) {
                var dot = context
                dot.opacity = alpha
                dot.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                         with: .foreground)
            }
        }
        .frame(width: size, height: size)
    }

    /// Dot centers in a top-left-origin square, with radius and opacity.
    static func dots(in size: CGSize) -> [(CGPoint, CGFloat, Double)] {
        let s = min(size.width, size.height)
        return [
            (CGPoint(x: 0.14 * s, y: 0.84 * s), 0.07 * s, 0.35),
            (CGPoint(x: 0.36 * s, y: 0.66 * s), 0.085 * s, 0.55),
            (CGPoint(x: 0.6 * s, y: 0.44 * s), 0.1 * s, 0.8),
            (CGPoint(x: 0.84 * s, y: 0.18 * s), 0.13 * s, 1),
        ]
    }
}
