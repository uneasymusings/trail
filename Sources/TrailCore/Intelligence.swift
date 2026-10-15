import Foundation
import FoundationModels

/// The on-device model (Apple Intelligence). Used for two small jobs:
/// turning a question into a `QueryPlan`, and writing a one-line note about new files.
/// Nothing leaves the Mac, and Trail works without it — just with less understanding.
public final class Intelligence: @unchecked Sendable {
    public enum Status: Equatable, Sendable {
        case ready
        case unavailable(String)
    }

    public init() {}

    public var status: Status {
        switch SystemLanguageModel.default.availability {
        case .available: return .ready
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .unavailable("Apple Intelligence is turned off")
            case .deviceNotEligible: return .unavailable("This Mac can't run Apple Intelligence")
            case .modelNotReady: return .unavailable("The model is still downloading")
            @unknown default: return .unavailable("The model is unavailable")
            }
        }
    }

    public var isReady: Bool { status == .ready }

    /// Loads the model ahead of a question so the first answer isn't slow.
    public func prewarm() {
        guard isReady else { return }
        LanguageModelSession(instructions: Self.planInstructions).prewarm()
    }

    // MARK: - Questions

    @Generable
    struct PlanOutput {
        @Guide(description: "Distinctive words to search for: names, topics, projects, people. Never filler words like file, latest, worked, find, my, the.")
        var keywords: [String]
        @Guide(description: "The kind of file the user named, or any.", .anyOf(["any", "document", "pdf", "spreadsheet", "presentation", "text", "code", "image", "video", "audio", "design", "3d", "archive"]))
        var kind: String
        @Guide(description: "The time window the user explicitly mentioned. Use any unless the user said a time.", .anyOf(Timeframe.allCases.map(\.rawValue)))
        var timeframe: String
        @Guide(description: "Where the file came from, only if the user said so.", .anyOf(["any", "downloaded", "ai"]))
        var origin: String
        @Guide(description: "True when the user wants the latest, newest, last or most recent file.")
        var newestFirst: Bool
    }

    static let planInstructions = """
        You turn a person's question about the files on their Mac into a search.
        Keep keywords short and exactly as the person wrote them. Do not invent dates or kinds.
        Examples:
        "latest file I worked on for the thermal pitch" -> keywords [thermal, pitch], kind any, timeframe any, newestFirst true
        "pdfs I downloaded last week about taxes" -> keywords [taxes], kind pdf, timeframe last week, origin downloaded
        "the deck for acme" -> keywords [acme], kind presentation, timeframe any, newestFirst false
        """

    /// Refines the rule-based plan. Keeps the rule-based reading where the model adds nothing,
    /// and drops a timeframe the user never mentioned (small models like to invent one).
    public func refine(_ quick: QueryPlan) async -> QueryPlan? {
        guard isReady else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.planInstructions)
            let output = try await session.respond(to: quick.text, generating: PlanOutput.self,
                                                   options: GenerationOptions(temperature: 0)).content
            var plan = quick
            let words: [String] = output.keywords.flatMap { $0.lowercased().split(separator: " ").map(String.init) }
            let keywords = words.filter(Self.isSearchWord)
            if !keywords.isEmpty { plan.keywords = Array(NSOrderedSet(array: keywords)) as? [String] ?? keywords }
            if plan.kinds.isEmpty, let kind = Self.kind(output.kind) { plan.kinds = [kind] }
            if plan.timeframe == .any, let timeframe = Timeframe(rawValue: output.timeframe), timeframe != .any,
               Self.mentionsTime(quick.text) {
                plan.timeframe = timeframe
            }
            if plan.origin == nil {
                plan.origin = output.origin == "downloaded" ? .download : output.origin == "ai" ? .ai : nil
            }
            plan.newestFirst = plan.newestFirst || output.newestFirst
            return plan
        } catch {
            return nil
        }
    }

    /// Drops filler and kind words ("pdfs", "deck") the model sometimes keeps as keywords.
    private static func isSearchWord(_ word: String) -> Bool {
        guard word.count > 1, !QueryParser.stopWords.contains(word), !QueryParser.newestWords.contains(word) else { return false }
        return QueryParser.kindWords[word] == nil || QueryParser.kindWordsKeptAsKeywords.contains(word)
    }

    private static func kind(_ value: String) -> FileKind? {
        value == "3d" ? .model3d : FileKind(rawValue: value)
    }

    private static func mentionsTime(_ text: String) -> Bool {
        let words = ["today", "yesterday", "week", "month", "year", "morning", "tonight", "night", "ago", "since", "recent"]
        let lowered = text.lowercased()
        return words.contains(where: lowered.contains)
    }

    // MARK: - File notes

    @Generable
    struct FileNote {
        @Guide(description: "One plain sentence, at most 18 words, saying what this file is about. No preamble.")
        var summary: String
        @Guide(description: "Two to five short lowercase topic tags, like people, companies, subjects or project names.", .maximumCount(5))
        var tags: [String]
    }

    public enum NoteResult {
        case note(summary: String, tags: [String])
        case skipped
        case rateLimited
    }

    func note(name: String, project: String?, excerpt: String) async -> NoteResult {
        guard isReady else { return .rateLimited }
        let session = LanguageModelSession(instructions: "You write short catalog notes about files so a person can find them later.")
        let prompt = """
            File name: \(name)
            Project: \(project ?? "none")
            Beginning of the file:
            \(excerpt)
            """
        do {
            let note = try await session.respond(to: prompt, generating: FileNote.self,
                                                 options: GenerationOptions(temperature: 0)).content
            return .note(summary: note.summary.trimmingCharacters(in: .whitespacesAndNewlines), tags: note.tags)
        } catch let error as LanguageModelSession.GenerationError {
            if case .rateLimited = error { return .rateLimited }
            return .skipped
        } catch {
            return .skipped
        }
    }
}
