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
    /// Days ago, for fuzzier times than `timeframe`: "two days ago" is 1...3, "on Monday" is
    /// exactly that day. 0 is today.
    public var days: ClosedRange<Int>?
    /// "The big file": +1 prefers large files, -1 small ones.
    public var size: Int?

    public init(text: String, keywords: [String] = [], kinds: [FileKind] = [], timeframe: Timeframe = .any,
                origin: FileOrigin? = nil, newestFirst: Bool = false, days: ClosedRange<Int>? = nil, size: Int? = nil) {
        self.text = text
        self.keywords = keywords
        self.kinds = kinds
        self.timeframe = timeframe
        self.origin = origin
        self.newestFirst = newestFirst
        self.days = days
        self.size = size
    }

    /// The time window the plan asks for, if any.
    public func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        if let days {
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -days.upperBound, to: today)!
            let end = calendar.date(byAdding: .day, value: 1 - days.lowerBound, to: today)!
            return DateInterval(start: start, end: end)
        }
        return timeframe.interval(now: now, calendar: calendar)
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
        "doc": .document, "docs": .document, "document": .document, "documents": .document,
        "essay": .document, "letter": .document,
        "deck": .presentation, "decks": .presentation, "slides": .presentation, "slide": .presentation,
        "presentation": .presentation, "presentations": .presentation,
        "sheet": .spreadsheet, "sheets": .spreadsheet, "spreadsheet": .spreadsheet, "spreadsheets": .spreadsheet,
        "image": .image, "images": .image, "photo": .image, "photos": .image, "picture": .image, "pictures": .image,
        "screenshot": .image, "screenshots": .image, "png": .image, "jpg": .image,
        "video": .video, "videos": .video, "movie": .video, "clip": .video, "clips": .video,
        "song": .audio, "songs": .audio, "track": .audio, "tracks": .audio, "audio": .audio, "mp3": .audio, "wav": .audio,
        "code": .code, "script": .code, "scripts": .code,
        "zip": .archive, "archive": .archive,
        "3d": .model3d,
        "note": .text, "notes": .text, "markdown": .text,
    ]

    // App names ("blender", "keynote") are deliberately not kind words: they stay keywords and
    // match that app's files through `AppNames`.

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
        "downloaded", "download", "downloads", "ai", "generated", "llm", "that's",
        "today", "yesterday", "tonight", "morning", "afternoon", "evening", "weekend", "now",
        // Talking, not searching: "that important file, I think we got it like two days ago"
        "important", "think", "thought", "like", "maybe", "probably", "guess", "remember", "recall", "somewhere",
        "actually", "really", "kind", "sort", "got", "something", "anything", "everything", "we're", "i've",
        "i'd", "you're", "it's", "didn't", "don't", "can't", "send", "sent", "sending", "share", "shared", "sharing",
        "use", "used", "using", "took", "take", "taken", "having", "there's", "around",
        "earlier", "other", "big", "bigger", "biggest", "large", "larger", "largest", "huge", "heavy", "massive",
        "small", "smaller", "smallest", "tiny", "size",

    ]

    static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "couple": 2, "a couple": 2, "a couple of": 2, "couple of": 2, "few": 3, "a few": 3, "several": 4,
    ]

    static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// "two days ago", "a couple of weeks ago", "the other day", "last few days", "on monday".
    /// Returns days ago and the text with the phrase removed.
    static func parseDays(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> (ClosedRange<Int>, String)? {
        func remove(_ range: Range<String.Index>) -> String { text.replacingCharacters(in: range, with: " ") }
        let number = #"(\d+|a couple of|a couple|couple of|couple|a few|few|several|an|a|one|two|three|four|five|six|seven|eight|nine|ten)"#
        func count(_ word: String) -> Int? { Int(word) ?? numberWords[word] }
        if let match = text.range(of: number + #" (day|days|week|weeks) ago"#, options: .regularExpression) {
            let words = text[match].split(separator: " ").map(String.init)
            let unitIndex = words.firstIndex { $0.hasPrefix("day") || $0.hasPrefix("week") }!
            guard let n = count(words[..<unitIndex].joined(separator: " ")) else { return nil }
            let fuzzy = words[unitIndex].hasPrefix("week") ? (7 * n - 3)...(7 * n + 3) : max(0, n - 1)...(n + 1)
            return (fuzzy, remove(match))
        }
        if let match = text.range(of: #"(last|past) (few|couple of|couple|several) days"#, options: .regularExpression) {
            return (0...4, remove(match))
        }
        if let match = text.range(of: "the other day") { return (1...6, remove(match)) }
        for (index, day) in weekdays.enumerated() {
            guard let match = text.range(of: #"((last|on|this) )?\#(day)\b"#, options: .regularExpression) else { continue }
            let today = calendar.component(.weekday, from: now) - 1
            var ago = (today - index + 7) % 7
            if ago == 0, text[match].hasPrefix("last") { ago = 7 }
            return (ago...ago, remove(match))
        }
        return nil
    }

    public static func parse(_ text: String, now: Date = Date()) -> QueryPlan {
        var lowered = " " + text.lowercased() + " "
        var plan = QueryPlan(text: text)

        if let (days, rest) = parseDays(lowered, now: now) {
            plan.days = days
            lowered = rest
        }
        let words = Set(lowered.split { !$0.isLetter }.map(String.init))
        if !words.isDisjoint(with: ["big", "bigger", "biggest", "large", "larger", "largest", "huge", "heavy", "massive"]) { plan.size = 1 }
        if !words.isDisjoint(with: ["small", "smaller", "smallest", "tiny"]) { plan.size = -1 }

        for (phrase, timeframe) in timePhrases where plan.days == nil && (lowered.contains(" \(phrase) ") || lowered.contains(" \(phrase)?")) {
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
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'.&+#-")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'.-")) }
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
