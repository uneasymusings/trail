import Foundation

public enum Timeframe: String, CaseIterable, Codable, Sendable {
    case any, today, yesterday, thisWeek = "this week", lastWeek = "last week"
    case thisMonth = "this month", lastMonth = "last month", thisYear = "this year"

    public func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        func start(of component: Calendar.Component, _ date: Date) -> Date {
            calendar.dateInterval(of: component, for: date)!.start
        }
        switch self {
        case .any: return nil
        case .today: return DateInterval(start: start(of: .day, now), end: .distantFuture)
        case .yesterday:
            let today = start(of: .day, now)
            return DateInterval(start: calendar.date(byAdding: .day, value: -1, to: today)!, end: today)
        case .thisWeek: return DateInterval(start: start(of: .weekOfYear, now), end: .distantFuture)
        case .lastWeek:
            let thisWeek = start(of: .weekOfYear, now)
            return DateInterval(start: calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek)!, end: thisWeek)
        case .thisMonth: return DateInterval(start: start(of: .month, now), end: .distantFuture)
        case .lastMonth:
            let thisMonth = start(of: .month, now)
            return DateInterval(start: calendar.date(byAdding: .month, value: -1, to: thisMonth)!, end: thisMonth)
        case .thisYear: return DateInterval(start: start(of: .year, now), end: .distantFuture)
        }
    }
}

/// A structured search. Built instantly by `QueryParser`, then optionally refined by the model.
public struct QueryPlan: Codable, Sendable, Equatable {
    public var text: String
    public var keywords: [String]
    public var kinds: [FileKind]
    public var timeframe: Timeframe
    public var origin: FileOrigin?
    public var newestFirst: Bool

    public init(text: String, keywords: [String] = [], kinds: [FileKind] = [], timeframe: Timeframe = .any,
                origin: FileOrigin? = nil, newestFirst: Bool = false) {
        self.text = text
        self.keywords = keywords
        self.kinds = kinds
        self.timeframe = timeframe
        self.origin = origin
        self.newestFirst = newestFirst
    }

    /// "What was I doing?"-style questions with nothing to match on.
    public var isActivityQuestion: Bool { keywords.isEmpty && kinds.isEmpty && origin == nil }
}

/// Instant, rule-based reading of a question. Good enough to show results while typing.
public enum QueryParser {
    static let timePhrases: [(String, Timeframe)] = [
        ("this week", .thisWeek), ("last week", .lastWeek), ("past week", .thisWeek),
        ("this month", .thisMonth), ("last month", .lastMonth), ("past month", .thisMonth),
        ("this year", .thisYear), ("today", .today), ("tonight", .today), ("this morning", .today),
        ("yesterday", .yesterday),
    ]

    static let kindWords: [String: FileKind] = [
        "pdf": .pdf, "pdfs": .pdf,
        "doc": .document, "docs": .document, "document": .document, "documents": .document, "word": .document,
        "essay": .document, "letter": .document,
        "deck": .presentation, "decks": .presentation, "slides": .presentation, "slide": .presentation,
        "presentation": .presentation, "presentations": .presentation, "keynote": .presentation, "powerpoint": .presentation,
        "sheet": .spreadsheet, "sheets": .spreadsheet, "spreadsheet": .spreadsheet, "spreadsheets": .spreadsheet,
        "excel": .spreadsheet,
        "image": .image, "images": .image, "photo": .image, "photos": .image, "picture": .image, "pictures": .image,
        "screenshot": .image, "screenshots": .image, "png": .image, "jpg": .image,
        "video": .video, "videos": .video, "movie": .video, "clip": .video, "clips": .video,
        "song": .audio, "songs": .audio, "track": .audio, "tracks": .audio, "audio": .audio, "mp3": .audio, "wav": .audio,
        "code": .code, "script": .code, "scripts": .code,
        "zip": .archive, "archive": .archive,
        "psd": .design, "figma": .design,
        "blender": .model3d, "3d": .model3d, "c4d": .model3d,
        "note": .text, "notes": .text, "markdown": .text,
    ]

    /// Kind words that are also likely to appear in file names, so they stay as keywords too.
    static let kindWordsKeptAsKeywords: Set<String> = ["screenshot", "screenshots", "notes", "note", "essay", "letter", "script"]

    static let newestWords: Set<String> = ["latest", "last", "newest", "recent", "recently", "current", "most"]

    static let stopWords: Set<String> = [
        "a", "an", "the", "i", "me", "my", "mine", "we", "our", "us", "you", "your", "it", "its", "is", "are", "was",
        "were", "be", "been", "am", "do", "did", "does", "doing", "done", "have", "had", "has", "can", "could",
        "would", "should", "will", "what", "whats", "what's", "which", "where", "when", "who", "how", "why",
        "for", "on", "of", "to", "in", "at", "by", "from", "with", "about", "into", "and", "or", "that", "this",
        "these", "those", "there", "here", "file", "files", "find", "show", "open", "get", "give", "pull", "up",
        "please", "worked", "working", "work", "edited", "editing", "edit", "saved", "save", "made", "make", "wrote",
        "written", "touched", "version", "versions", "thing", "things", "stuff", "one", "ones", "all", "any",
        "some", "just", "again", "ago", "time", "day", "days", "week", "month", "year", "lately", "where's",
        "folder", "where'd", "put", "look", "looking", "see", "need", "want", "let", "lets", "let's", "im", "i'm",
        "downloaded", "download", "downloads", "ai", "generated", "llm", "by", "was", "that's", "was",
    ]

    public static func parse(_ text: String) -> QueryPlan {
        var lowered = " " + text.lowercased() + " "
        var plan = QueryPlan(text: text)

        for (phrase, timeframe) in timePhrases where lowered.contains(" \(phrase) ") || lowered.contains(" \(phrase)?") {
            plan.timeframe = timeframe
            lowered = lowered.replacingOccurrences(of: phrase, with: " ")
            break
        }

        if lowered.contains("download") { plan.origin = .download }
        if lowered.contains(" ai ") || lowered.contains("ai-generated") || lowered.contains(" llm") || lowered.contains("chatgpt")
            || lowered.contains("made by claude") {
            plan.origin = .ai
        }

        let tokens = lowered
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'.&+#")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'.")) }
            .filter { !$0.isEmpty }

        var keywords: [String] = []
        for token in tokens {
            if newestWords.contains(token) { plan.newestFirst = true; continue }
            if let kind = kindWords[token] {
                if !plan.kinds.contains(kind) { plan.kinds.append(kind) }
                if !kindWordsKeptAsKeywords.contains(token) { continue }
            }
            if stopWords.contains(token) { continue }
            if token.count < 2, !token.allSatisfy(\.isNumber) { continue }
            if !keywords.contains(token) { keywords.append(token) }
        }
        plan.keywords = keywords
        return plan
    }
}
