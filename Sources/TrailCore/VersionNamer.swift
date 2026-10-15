import Foundation

/// Reduces file names to a "stem" so that `Pitch v2.key`, `Pitch (1).key` and `pitch_final.key`
/// all land on `pitch` and can be linked into one version chain.
public enum VersionNamer {
    private static let markers: [NSRegularExpression] = [
        #"\s*\(\d+\)$"#,                                         // "Report (1)"
        #"[\s_\-]+copy(\s*\d+)?$"#,                              // "Report copy 2"
        #"[\s_\-.]+v(er(sion)?)?\s*\d+([._]\d+)*$"#,             // "Report_v2", "Report v1.3"
        #"[\s_\-.]+(final|draft|rev(ision)?\s*\d*|edited|edit|updated|latest|wip|fixed|backup|bak|old|new|revised|clean)$"#,
        #"[\s_\-.]*\d{4}[\-_.]?\d{2}[\-_.]?\d{2}([\s_\-T]?\d{2}[.:\-]?\d{2}([.:\-]?\d{2})?)?$"#, // dates and timestamps
        #"[\s_\-.]*\d{1,2}[\-_.]\d{1,2}[\-_.]\d{2,4}$"#,          // "3-14-26"
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let separators = try! NSRegularExpression(pattern: #"[\s_\-.]+"#)

    /// Names too generic to tie files together.
    private static let genericPrefixes = [
        "untitled", "screenshot", "screen shot", "screen recording", "img", "dsc", "image", "photo",
        "document", "new document", "readme", "index", "main", "file", "download", "scan", "audio",
        "video", "recording", "export", "output", "test", "temp", "notes", "new recording",
    ]

    public struct Result: Equatable {
        public var stem: String
        public var hasMarker: Bool
    }

    public static func stem(for fileName: String) -> Result? {
        let base = (fileName as NSString).deletingPathExtension
        var current = base
        var changed = true
        while changed {
            changed = false
            for marker in markers {
                let range = NSRange(current.startIndex..., in: current)
                let replaced = marker.stringByReplacingMatches(in: current, range: range, withTemplate: "")
                if replaced != current, !replaced.isEmpty {
                    current = replaced
                    changed = true
                }
            }
        }
        let normalized = separators
            .stringByReplacingMatches(in: current, range: NSRange(current.startIndex..., in: current), withTemplate: " ")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard normalized.count >= 3,
              !genericPrefixes.contains(where: { normalized == $0 || normalized.hasPrefix($0 + " ") }),
              normalized.contains(where: \.isLetter) else { return nil }
        return Result(stem: normalized, hasMarker: current != base)
    }
}
