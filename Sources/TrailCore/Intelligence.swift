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
            // App names ("blender") mean that app's files, not a kind; the model likes to guess one.
            let asked = Set(quick.text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
            if plan.kinds.isEmpty, asked.isDisjoint(with: AppNames.all), let kind = Self.kind(output.kind) { plan.kinds = [kind] }
            if plan.timeframe == .any, plan.days == nil, let timeframe = Timeframe(rawValue: output.timeframe), timeframe != .any,
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
        guard word.count > 1, !QueryParser.stopWords.contains(word), !QueryParser.newestWords.contains(word),
              QueryParser.numberWords[word] == nil, !QueryParser.weekdays.contains(word),
              !["day", "days", "week", "weeks", "month", "months", "ago", "yesterday", "today"].contains(word) else { return false }
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

    // MARK: - Choosing

    @Generable
    struct Choice {
        @Guide(description: "The number of the one file the person is looking for, or 0 if none of the files fit the question.")
        var file: Int
    }

    static let pickInstructions = """
        You help a person find a file on their Mac. You get their question and a numbered list of \
        candidate files from their index, with what is known about each one.
        Answer with the number of the single file they most likely mean. Match what they named: \
        a project, app, person, company, place or topic. If they name a kind of file (a deck or \
        slides, a PDF, a spreadsheet, a photo or screenshot, a document), choose a file of that kind. \
        When they say latest, last or newest, prefer the most recently edited match. Prefer the person's own documents over \
        source code unless they ask for code. If none of the files fit, answer 0.
        """

    /// Lets the model read the question and the top results and choose the one that answers it.
    /// It can only answer with a number from the list, so it can't invent a file. Returns the
    /// chosen index into `hits`, or nil when the model is unavailable, unsure or out of range.
    public func pick(_ question: String, from hits: [SearchHit], now: Date = Date()) async -> Int? {
        guard isReady, hits.count > 1 else { return nil }
        let list = hits.enumerated().map { index, hit in "\(index + 1). \(Self.describe(hit, now: now))" }.joined(separator: "\n")
        let prompt = """
            Question: \(question)

            Files:
            \(list)
            """
        do {
            let session = LanguageModelSession(instructions: Self.pickInstructions)
            let choice = try await session.respond(to: prompt, generating: Choice.self,
                                                   options: GenerationOptions(temperature: 0)).content
            return (1...hits.count).contains(choice.file) ? choice.file - 1 : nil
        } catch {
            return nil
        }
    }

    /// One line of facts from the graph about a file, for the model.
    static func describe(_ hit: SearchHit, now: Date) -> String {
        let file = hit.file
        let ext = (file.name as NSString).pathExtension
        var kind = file.kind.displayName.lowercased()
        if let app = AppNames.forExtension(ext).first { kind = "\(app) \(kind) file" }
        var facts = ["[\(kind)] \(file.name)", "edited \(RelativeTime.describe(file.modified, now: now))", "in \(file.displayPath)"]
        if let project = file.projectName { facts.append("project \(project)") }
        if hit.versionCount > 1 { facts.append("newest of \(hit.versionCount) versions") }
        switch file.origin {
        case .download: facts.append("downloaded" + (file.sourceHost.map { " from \($0)" } ?? ""))
        case .ai: facts.append("saved by an AI tool")
        case .local: break
        }
        if let summary = file.summary { facts.append("about: \(summary)") }
        if !file.tags.isEmpty { facts.append("topics: \(file.tags.joined(separator: ", "))") }
        return facts.joined(separator: "; ")
    }

    // MARK: - Tidying

    static let folderInstructions = """
        You help a person keep their Mac tidy. A new file arrived on their Desktop or in Downloads. \
        You get what is known about it and a numbered list of their existing folders, each with \
        a few files already in it. Answer with the number of the folder where this file belongs, \
        judging by what the file is about and what the folder holds. If none of them is a good \
        home, answer 0.
        """

    /// Chooses among folders the graph already suggested, so it can only name real places.
    /// Returns an index into `folders`, or nil.
    public func chooseFolder(for file: FileRecord, text: String?, from folders: [String], home: String) async -> Int? {
        guard isReady, folders.count > 1 else { return nil }
        var about = "[\(file.kind.displayName.lowercased())] \(file.name)"
        if let host = file.sourceHost { about += ", downloaded from \(host)" }
        if let summary = file.summary { about += "\nAbout: \(summary)" }
        if let text { about += "\nIt begins: \(text.prefix(600))" }
        let list = folders.enumerated().map { index, folder in
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
                .filter { !$0.hasPrefix(".") }.sorted().prefix(6).joined(separator: ", ")
            let shown = folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder
            return "\(index + 1). \(shown) (holds \(names))"
        }.joined(separator: "\n")
        do {
            let session = LanguageModelSession(instructions: Self.folderInstructions)
            let choice = try await session.respond(to: "File:\n\(about)\n\nFolders:\n\(list)", generating: Choice.self,
                                                   options: GenerationOptions(temperature: 0)).content
            return (1...folders.count).contains(choice.file) ? choice.file - 1 : nil
        } catch {
            return nil
        }
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
