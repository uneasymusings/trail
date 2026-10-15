import Foundation

/// Turns a `QueryPlan` into ranked results. Everything here is plain SQLite, so it answers in
/// milliseconds; the model only ever shapes the plan.
public final class SearchEngine: @unchecked Sendable {
    let db: Database

    init(db: Database) {
        self.db = db
    }

    public func search(_ plan: QueryPlan, limit: Int = 30, now: Date = Date(), correctTypos: Bool = true) throws -> SearchResponse {
        var plan = plan
        let corrections = correctTypos ? try self.correctTypos(&plan) : [:]
        var response = try run(plan, limit: limit, now: now)

        // "On Monday" is often off by a day. Widen a day window once before loosening anything else.
        if response.hits.isEmpty, let days = plan.days {
            var wider = plan
            wider.days = max(0, days.lowerBound - 2)...(days.upperBound + 2)
            response = try run(wider, limit: limit, now: now)
            response.plan = plan
        }

        // Kind, time and origin are guesses about what you meant. When they rule out everything,
        // loosen them one at a time rather than show nothing.
        if response.hits.isEmpty, !plan.keywords.isEmpty {
            var loose = plan
            for step in 0..<3 where response.hits.isEmpty {
                switch step {
                case 0:
                    guard loose.timeframe != .any || loose.days != nil else { continue }
                    loose.timeframe = .any
                    loose.days = nil
                case 1:
                    guard !loose.kinds.isEmpty else { continue }
                    // Two readings of "the deck for investors": files about investors of any kind,
                    // and the newest decks whatever they're called. Show both; the model, if it's
                    // asked, chooses between them.
                    var kindOnly = loose
                    kindOnly.keywords = []
                    loose.kinds = []
                    response = try run(loose, limit: limit, now: now)
                    let decks = try run(kindOnly, limit: 5, now: now).hits.filter { hit in !response.hits.contains { $0.id == hit.id } }
                    response.hits = Array(response.hits.prefix(5)) + decks.map { var hit = $0; hit.coverage = 0; return hit } + Array(response.hits.dropFirst(5))
                    response.answer = nil
                    continue
                default:
                    guard loose.origin != nil else { continue }
                    loose.origin = nil
                }
                response = try run(loose, limit: limit, now: now)
            }
            response.plan = plan
        }
        // The index holds word stems ("syllabu"); show each fix as the word appears in the results.
        let shown = corrections.compactMapValues { stem -> String? in
            let seen = response.hits.prefix(5).flatMap { Self.nameWords($0.file.name + " " + $0.file.displayPath).map(\.word) }
            return seen.filter { $0.hasPrefix(stem) }.min { $0.count < $1.count } ?? stem
        }.filter { $0.key.lowercased() != $0.value }
        if !shown.isEmpty {
            response.correctedText = shown.reduce(plan.text) {
                $0.replacingOccurrences(of: $1.key, with: $1.value, options: .caseInsensitive)
            }
        }
        return response
    }

    private func run(_ plan: QueryPlan, limit: Int, now: Date) throws -> SearchResponse {
        var filters = ["f.deleted_at IS NULL"]
        var arguments: [Any?] = []
        if !plan.kinds.isEmpty {
            filters.append("f.kind IN (\(plan.kinds.map { _ in "?" }.joined(separator: ",")))")
            arguments += plan.kinds.map(\.rawValue)
        }
        if let interval = plan.interval(now: now) {
            filters.append("f.modified >= ? AND f.modified < ?")
            arguments += [interval.start, min(interval.end, Date.distantFuture)]
        }
        if let origin = plan.origin {
            filters.append("f.origin = ?")
            arguments.append(origin.rawValue)
        }
        // Edits in the last month. Kept free of literals so the statement cache can reuse it.
        let columns = """
            \(fileColumns), f.opens, f.opened_at,
            (SELECT count(*) FROM events e WHERE e.file_id = f.id AND e.at > unixepoch() - 2592000) AS edits
            """
        let whereFilters = filters.joined(separator: " AND ")

        var candidates: [Int: Candidate] = [:]
        guard !plan.keywords.isEmpty else {
            // Nothing to match: the newest files, or for "the big one", the biggest. Folded
            // folders count files, not bytes, so they sit out size questions.
            let order = plan.size == nil ? "f.modified DESC" : plan.size! > 0 ? "f.size DESC" : "f.size ASC"
            let sized = plan.size == nil ? "" : " AND f.kind != 'collection'"
            let rows = try db.query("""
                SELECT \(columns) FROM files f LEFT JOIN projects p ON p.id = f.project_id
                WHERE \(whereFilters)\(sized) ORDER BY \(order) LIMIT ?
                """, arguments: arguments + [limit * 4])
            for row in rows { candidates[row.int("id")!] = Candidate(row: row, coverage: 1) }
            return try respond(plan, candidates: Array(candidates.values), limit: limit, now: now)
        }

        let keywords = plan.keywords
        let last = keywords.count - 1
        // Names, folders and notes: the word being typed is a prefix. Text inside documents:
        // whole words, plus a prefix once the word being typed is long enough to mean something.
        let nameTerms = keywords.enumerated().map { Self.ftsTerm($1, prefix: $0 == last) }
        let bodyTerms = keywords.enumerated().map { $1.count >= 3 ? Self.ftsTerm($1, prefix: $0 == last && $1.count >= 4) : nil }

        // Which files contain each word, in the name, folders or notes or in the text. Rowids
        // only, so this stays cheap even for words in thousands of files.
        let sets: [Set<Int>] = keywords.count == 1 ? [] : try keywords.indices.map { index in
            var ids = Set(try db.ids("SELECT rowid FROM search WHERE search MATCH ?", arguments: [nameTerms[index]]))
            if let body = bodyTerms[index] { ids.formUnion(try db.ids("SELECT rowid FROM body WHERE body MATCH ?", arguments: [body])) }
            return ids
        }
        func coverage(_ id: Int) -> Double {
            sets.isEmpty ? 1 : Double(sets.filter { $0.contains(id) }.count) / Double(sets.count)
        }

        func add(_ rows: [Row], from table: String) {
            for row in rows {
                let id = row.int("id")!
                let rank = -(row.double("rank") ?? 0)
                var candidate = candidates[id] ?? Candidate(row: row, coverage: coverage(id))
                if table == "search" { candidate.nameRank = max(candidate.nameRank, rank) } else { candidate.bodyRank = max(candidate.bodyRank, rank) }
                candidates[id] = candidate
            }
        }
        func ranked(_ table: String, _ match: String) throws -> [Row] {
            let weights = table == "search" ? "10.0, 3.0, 2.0, 3.0, 6.0" : "1.0"
            // Scoring every match of a word that's in thousands of files is slow and tells little
            // apart; take the newest of them instead, as equally good text matches.
            let common = try db.ids("SELECT rowid FROM \(table) WHERE \(table) MATCH ? LIMIT \(Self.commonMatches)", arguments: [match]).count >= Self.commonMatches
            let rank = common ? "-1.0" : "bm25(\(table), \(weights))"
            return try db.query("""
                SELECT \(columns), \(rank) AS rank
                FROM \(table) JOIN files f ON f.id = \(table).rowid LEFT JOIN projects p ON p.id = f.project_id
                WHERE \(table) MATCH ? AND \(whereFilters)
                ORDER BY \(common ? "f.modified DESC" : "rank") LIMIT 300
                """, arguments: [match] + arguments)
        }
        // 1. Every word in the name, folders or notes.
        add(try ranked("search", nameTerms.joined(separator: " AND ")), from: "search")
        // 2. Every word, some of them only inside the document ("climate paper": "paper" in the
        //    name, "climate" in the text).
        let bodyAny = bodyTerms.compactMap { $0 }.joined(separator: " OR ")
        if keywords.count == 1, !bodyAny.isEmpty {
            add(try ranked("body", bodyAny), from: "body")
        } else if !sets.isEmpty {
            let rest = sets.dropFirst().reduce(sets[0]) { $0.intersection($1) }.subtracting(candidates.keys)
            if !rest.isEmpty {
                // They contain every word, so they're good matches; scoring each against the text
                // would mean walking every match of the commonest word.
                let rows = try db.query("""
                    SELECT \(columns), -0.5 AS rank FROM files f LEFT JOIN projects p ON p.id = f.project_id
                    WHERE f.id IN (SELECT value FROM json_each(?)) AND \(whereFilters)
                    ORDER BY f.modified DESC LIMIT 300
                    """, arguments: ["[" + rest.map(String.init).joined(separator: ",") + "]"] + arguments)
                add(rows, from: "body")
            }
        }
        // 3. Some of the words, when all of them found too little.
        if candidates.count < limit, keywords.count > 1 {
            add(try ranked("search", keywords.map { Self.ftsTerm($0, prefix: true) }.joined(separator: " OR ")), from: "search")
            if !bodyAny.isEmpty { add(try ranked("body", bodyAny), from: "body") }
        }
        return try respond(plan, candidates: Array(candidates.values), limit: limit, now: now)
    }

    private func respond(_ plan: QueryPlan, candidates: [Candidate], limit: Int, now: Date) throws -> SearchResponse {
        let hits = rank(candidates, plan: plan, now: now)
        let collapsed = Array(try collapseVersions(hits, keywords: plan.keywords).prefix(limit))
        return SearchResponse(plan: plan, hits: collapsed, projects: try matchingProjects(plan.keywords),
                              answer: Self.answer(for: plan, hits: collapsed), refinedByModel: false)
    }

    /// Above this many matches a word counts as common (see `ranked`).
    static let commonMatches = 2_500

    struct Candidate {
        var file: FileRecord
        /// bm25 against names, folders and notes, and against document text; higher is better.
        var nameRank = 0.0
        var bodyRank = 0.0
        /// Share of the keywords this file contains somewhere.
        var coverage: Double
        var opens: Int
        var openedAt: Date?
        var edits: Int

        init(row: Row, coverage: Double) {
            file = FileRecord(row: row)
            self.coverage = coverage
            opens = row.int("opens") ?? 0
            openedAt = row.date("opened_at")
            edits = row.int("edits") ?? 0
        }
    }

    /// Blends how well the text matches with signals about the file itself. The weights are tuned
    /// against `SearchQualityTests`; change them there first.
    private func rank(_ candidates: [Candidate], plan: QueryPlan, now: Date) -> [SearchHit] {
        let bestName = candidates.map(\.nameRank).max() ?? 0
        let bestBody = candidates.map(\.bodyRank).max() ?? 0
        let latest = plan.newestFirst || plan.keywords.isEmpty
        let forms = KeywordForms(plan.keywords)
        let sizes = candidates.filter { $0.file.kind != .collection }.map { log(Double(max(1, $0.file.size))) }
        let (smallest, largest) = (sizes.min() ?? 0, sizes.max() ?? 0)
        return candidates.map { candidate -> SearchHit in
            let file = candidate.file
            // A match in the name or folders counts for more than one somewhere in the text.
            let text = max(bestName > 0 ? candidate.nameRank / bestName : 0, bestBody > 0 ? 0.6 * candidate.bodyRank / bestBody : 0)
            let name = Self.nameMatch(file, forms: forms)
            let ageDays = max(0, now.timeIntervalSince(file.modified)) / 86_400
            let recency = exp(-ageDays / 30)
            let opened = candidate.openedAt.map { min(1, log2(1 + Double(candidate.opens)) / 3) * exp(-now.timeIntervalSince($0) / 86_400 / 60) } ?? 0
            let edited = min(1, log2(1 + Double(candidate.edits)) / 4)
            let prior = plan.kinds.isEmpty ? Self.prior(file.kind) : 1

            var score = latest
                ? 0.10 * text + 0.15 * candidate.coverage + 0.15 * name + 0.10 * prior + 0.50 * recency
                : 0.20 * text + 0.20 * candidate.coverage + 0.25 * name + 0.20 * prior + 0.15 * recency
            score += 0.20 * opened + 0.04 * edited
            if let preference = plan.size, largest > smallest, file.kind != .collection {
                let bigness = (log(Double(max(1, file.size))) - smallest) / (largest - smallest)
                score += 0.30 * (preference > 0 ? bigness : 1 - bigness)
            }
            return SearchHit(file: file, score: score, versionCount: 1, coverage: candidate.coverage)
        }
        // A file with every word you typed beats one with only some of them, however recent.
        .sorted { $0.coverage != $1.coverage ? $0.coverage > $1.coverage : $0.score > $1.score }
    }

    /// Trail is for the things you make and keep. When a document and a source file share a
    /// name, the document is more likely the one you mean; the source file is a click away in
    /// your editor.
    static func prior(_ kind: FileKind) -> Double {
        switch kind {
        case .document, .pdf, .presentation, .spreadsheet, .design, .model3d, .video, .audio, .collection: 1
        case .text: 0.8
        case .image: 0.6
        case .archive, .app: 0.5
        case .other: 0.3
        case .code, .data: 0
        }
    }

    /// Keywords split and stemmed once per search, for `nameMatch`.
    struct KeywordForms {
        /// Per keyword: its parts ("w-2" → w, 2), each with its rough stem, and whether a part
        /// may match the start of a longer word.
        let keywords: [[(part: String, stem: String, prefix: Bool)]]

        init(_ keywords: [String]) {
            self.keywords = keywords.enumerated().map { index, keyword in
                keyword.split { !$0.isLetter && !$0.isNumber }.map { part in
                    let part = String(part)
                    return (part, SearchEngine.roughStem(part), index == keywords.count - 1 || part.count >= 4)
                }
            }
        }
    }

    /// The share of keywords found in the file's name, falling back to its project's name at a
    /// discount. Matching the name is the strongest sign you meant this file.
    static func nameMatch(_ file: FileRecord, keywords: [String]) -> Double {
        nameMatch(file, forms: KeywordForms(keywords))
    }

    static func nameMatch(_ file: FileRecord, forms: KeywordForms) -> Double {
        guard !forms.keywords.isEmpty else { return 0 }
        let nameWords = Self.nameWords(file.name)
            + AppNames.forExtension((file.name as NSString).pathExtension).map { ($0, $0) }
        var projectWords: [(word: String, stem: String)]?
        func matches(_ keyword: [(part: String, stem: String, prefix: Bool)], in words: [(word: String, stem: String)]) -> Bool {
            keyword.allSatisfy { part in
                words.contains { $0.word == part.part || $0.stem == part.stem || (part.prefix && $0.word.hasPrefix(part.part)) }
            }
        }
        var score = 0.0
        for keyword in forms.keywords {
            if matches(keyword, in: nameWords) {
                score += 1
            } else {
                if projectWords == nil { projectWords = file.projectName.map(Self.nameWords) ?? [] }
                if matches(keyword, in: projectWords!) { score += 0.6 }
            }
        }
        return score / Double(forms.keywords.count)
    }

    /// The words people would type for a file name, lowercased, with their rough stems:
    /// "CS161_Syllabus-v2.pdf" → cs161, cs, 161, syllabus, v2, v, 2, pdf, and "W-2" also as "w2".
    /// The same words `Indexer.nameTerms` puts in the index, without building strings to parse.
    static func nameWords(_ name: String) -> [(word: String, stem: String)] {
        var words: [String] = [], runs: [String] = []
        // Fast path for plain ASCII names, which are nearly all of them: work on bytes.
        if name.utf8.allSatisfy({ $0 < 128 }) {
            let bytes = Array(name.utf8)
            let lowered = bytes.map { $0 >= 65 && $0 <= 90 ? $0 | 0x20 : $0 }
            func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
            func isAlphanumeric(_ byte: UInt8) -> Bool { isDigit(byte) || (byte | 0x20 >= 97 && byte | 0x20 <= 122) }
            var runStart = -1, pieceStart = -1
            func text(_ range: Range<Int>) -> String { String(decoding: lowered[range], as: UTF8.self) }
            func close(at end: Int) {
                guard runStart >= 0 else { return }
                words.append(text(pieceStart..<end))
                if pieceStart != runStart {
                    let whole = text(runStart..<end)
                    if !words.contains(whole) { words.append(whole) }
                }
                runs.append(text(runStart..<end))
                runStart = -1
            }
            for index in bytes.indices {
                let byte = bytes[index]
                guard isAlphanumeric(byte) else { close(at: index); continue }
                if runStart < 0 {
                    runStart = index
                    pieceStart = index
                } else {
                    let previous = bytes[index - 1]
                    let lowerToUpper = previous >= 97 && previous <= 122 && byte >= 65 && byte <= 90
                    if lowerToUpper || isDigit(previous) != isDigit(byte) {
                        words.append(text(pieceStart..<index))
                        pieceStart = index
                    }
                }
            }
            close(at: bytes.count)
            for (left, right) in zip(runs, runs.dropFirst())
            where (left.utf8.allSatisfy(isDigit) && !right.utf8.contains(where: isDigit)) || (!left.utf8.contains(where: isDigit) && right.utf8.allSatisfy(isDigit)) {
                words.append(left + right)
            }
            return words.map { ($0, roughStem($0)) }
        }
        var run = String.UnicodeScalarView(), piece = String.UnicodeScalarView()
        func endPiece() {
            if !piece.isEmpty { words.append(String(piece)); piece = String.UnicodeScalarView() }
        }
        func endRun() {
            endPiece()
            guard !run.isEmpty else { return }
            let text = String(run)
            runs.append(text)
            if !words.contains(text) { words.append(text) }
            run = String.UnicodeScalarView()
        }
        var previous: Unicode.Scalar.Properties?
        for scalar in name.unicodeScalars {
            let properties = scalar.properties
            let isLetter = properties.isAlphabetic, isDigit = properties.numericType != nil
            guard isLetter || isDigit else { endRun(); previous = nil; continue }
            if let previous, (previous.isLowercase && properties.isUppercase) || previous.isAlphabetic != isLetter { endPiece() }
            if properties.isUppercase {
                run.append(contentsOf: properties.lowercaseMapping.unicodeScalars)
                piece.append(contentsOf: properties.lowercaseMapping.unicodeScalars)
            } else {
                run.append(scalar)
                piece.append(scalar)
            }
            previous = properties
        }
        endRun()
        for (left, right) in zip(runs, runs.dropFirst())
        where (left.allSatisfy(\.isLetter) && right.allSatisfy(\.isNumber)) || (left.allSatisfy(\.isNumber) && right.allSatisfy(\.isLetter)) {
            words.append(left + right)
        }
        return words.map { ($0, roughStem($0)) }
    }

    /// Plural and verb endings off, enough to compare words without the full Porter stemmer.
    static func roughStem(_ word: String) -> String {
        for suffix in ["ies", "es", "s", "ing", "ed"] where word.count > suffix.count + 2 && word.hasSuffix(suffix) {
            return String(word.dropLast(suffix.count)) + (suffix == "ies" ? "y" : "")
        }
        return word
    }

    // MARK: - Typos

    /// Replaces keywords that match nothing with the closest word in the index ("thermla" →
    /// "thermal"). Returns what it changed, so the panel can say so.
    private func correctTypos(_ plan: inout QueryPlan) throws -> [String: String] {
        var corrections: [String: String] = [:]
        for (index, keyword) in plan.keywords.enumerated() where keyword.count >= 4 && keyword.allSatisfy(\.isLetter) {
            // A real word that just isn't in your files is not a typo. One whose stem is real
            // ("syllabis" → "syllabi") only gets a very close fix.
            guard try !isIndexed(keyword), !EnglishWords.contains(keyword),
                  let fix = try closestTerm(to: keyword, maxDistance: EnglishWords.contains(Self.roughStem(keyword)) ? 1 : nil)
            else { continue }
            plan.keywords[index] = fix
            corrections[keyword] = fix
        }
        return corrections
    }

    /// Whether any indexed word starts with `word` or its stem. Asks the vocabulary rather than
    /// the index, which is much cheaper for common words.
    private func isIndexed(_ word: String) throws -> Bool {
        // Index words are stems ("claud" for "claude"), so look at words sharing all but the
        // last two letters: the word is indexed if one of them starts it or starts with it.
        let base = String(word.prefix(max(3, word.count - 2)))
        for vocabulary in ["search_terms", "body_terms"] {
            let terms = try db.query("SELECT term FROM \(vocabulary) WHERE term >= ? AND term < ? LIMIT 200", base, base + "\u{10FFFF}")
                .compactMap { $0.string("term") }
            if terms.contains(where: { $0.hasPrefix(word) || word.hasPrefix($0) }) { return true }
        }
        return false
    }

    /// The most common indexed word within one edit (two for long words) of `word`, from names
    /// first, then document text. Index words are stemmed, so the comparison also tries `word`
    /// with its ending removed.
    private func closestTerm(to word: String, maxDistance: Int? = nil) throws -> String? {
        guard let first = word.unicodeScalars.first, let next = UnicodeScalar(first.value + 1) else { return nil }
        let allowed = min(word.count >= 7 ? 2 : 1, maxDistance ?? 2)
        let forms = Set([word, Self.roughStem(word), String(word.dropLast())]).map { Array($0.utf8) }
        for vocabulary in ["search_terms", "body_terms"] {
            var best: (term: String, distance: Int, documents: Int)?
            for row in try db.query("SELECT term, doc FROM \(vocabulary) WHERE term >= ? AND term < ?", String(first), String(next)) {
                guard let term = row.string("term") else { continue }
                let bytes = Array(term.utf8)
                guard abs(bytes.count - word.utf8.count) <= allowed + 1 else { continue }
                let distance = forms.map { Self.editDistance($0, bytes, limit: allowed) }.min() ?? .max
                guard distance <= allowed, term.allSatisfy(\.isLetter) else { continue }
                let documents = row.int("doc") ?? 0
                if best == nil || distance < best!.distance || (distance == best!.distance && documents > best!.documents) {
                    best = (term, distance, documents)
                }
            }
            if let best { return best.term }
        }
        return nil
    }

    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        editDistance(Array(a.utf8), Array(b.utf8), limit: limit)
    }

    /// Optimal string alignment distance: insertions, deletions, substitutions and swapped
    /// neighbours each cost 1. Gives up early once the distance must exceed `limit`.
    static func editDistance(_ a: [UInt8], _ b: [UInt8], limit: Int) -> Int {
        guard abs(a.count - b.count) <= limit else { return limit + 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], previous2[j - 2] + 1)
                }
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > limit { return limit + 1 }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[b.count]
    }

    /// Shows each version chain once, as its newest file, with a count of the others. If you
    /// named a particular version ("pitch v2", "paper draft"), that one stays.
    private func collapseVersions(_ hits: [SearchHit], keywords: [String]) throws -> [SearchHit] {
        var seenChains: Set<Int> = []
        var result: [SearchHit] = []
        for hit in hits {
            guard let chain = hit.file.chainID else { result.append(hit); continue }
            guard seenChains.insert(chain).inserted else { continue }
            let versions = try db.query("""
                SELECT \(fileColumns) FROM files f LEFT JOIN projects p ON p.id = f.project_id
                WHERE f.chain_id = ? AND f.deleted_at IS NULL ORDER BY f.modified DESC
                """, chain).map(FileRecord.init(row:))
            var collapsed = hit
            if let newest = versions.first,
               Self.nameMatch(newest, keywords: keywords) >= Self.nameMatch(hit.file, keywords: keywords) {
                collapsed.file = newest
            }
            collapsed.versionCount = max(1, versions.count)
            result.append(collapsed)
        }
        return result
    }

    private func matchingProjects(_ keywords: [String]) throws -> [ProjectSummary] {
        let words = keywords.filter { $0.count >= 3 }
        guard !words.isEmpty else { return [] }
        let condition = words.map { _ in "p.name LIKE ?" }.joined(separator: " OR ")
        let rows = try db.query("""
            SELECT p.id, p.name, p.root, p.kind, p.last_active,
                (SELECT count(*) FROM files WHERE project_id = p.id AND deleted_at IS NULL) AS file_count
            FROM projects p WHERE \(condition) ORDER BY p.last_active DESC LIMIT 3
            """, arguments: words.map { "%\($0)%" })
        return try rows.map { row in
            let id = row.int("id")!
            return ProjectSummary(id: id, name: row.string("name")!, root: row.string("root")!,
                                  kind: row.string("kind")!, lastActive: row.date("last_active")!,
                                  fileCount: row.int("file_count") ?? 0, latest: try latestFiles(project: id, limit: 3))
        }
    }

    // MARK: - Navigation

    public func latestFiles(project: Int, limit: Int) throws -> [FileRecord] {
        try db.query("""
            SELECT \(fileColumns) FROM files f LEFT JOIN projects p ON p.id = f.project_id
            WHERE f.project_id = ? AND f.deleted_at IS NULL ORDER BY f.modified DESC LIMIT ?
            """, project, limit).map(FileRecord.init(row:))
    }

    /// Projects with recent activity and their newest files — "pick up where you left off".
    public func recentProjects(limit: Int = 6, filesEach: Int = 3) throws -> [ProjectSummary] {
        let rows = try db.query("""
            SELECT p.id, p.name, p.root, p.kind, max(f.modified) AS last_active, count(*) AS file_count
            FROM files f JOIN projects p ON p.id = f.project_id
            WHERE f.deleted_at IS NULL AND f.modified > ?
            GROUP BY p.id ORDER BY last_active DESC LIMIT ?
            """, Date().addingTimeInterval(-60 * 86_400), limit)
        return try rows.map { row in
            let id = row.int("id")!
            return ProjectSummary(id: id, name: row.string("name")!, root: row.string("root")!,
                                  kind: row.string("kind")!, lastActive: row.date("last_active")!,
                                  fileCount: row.int("file_count") ?? 0, latest: try latestFiles(project: id, limit: filesEach))
        }
    }

    public func recentFiles(limit: Int = 20) throws -> [FileRecord] {
        try db.query("""
            SELECT \(fileColumns) FROM files f LEFT JOIN projects p ON p.id = f.project_id
            WHERE f.deleted_at IS NULL ORDER BY f.modified DESC LIMIT ?
            """, limit).map(FileRecord.init(row:))
    }

    /// The neighbourhood of one file in the graph.
    public func related(to file: FileRecord, limit: Int = 8) throws -> Related {
        let versions = try file.chainID.map {
            try db.query("""
                SELECT \(fileColumns) FROM files f LEFT JOIN projects p ON p.id = f.project_id
                WHERE f.chain_id = ? AND f.deleted_at IS NULL ORDER BY f.modified DESC
                """, $0).map(FileRecord.init(row:))
        } ?? []

        // Files touched within 30 minutes of this one's last change.
        let window: TimeInterval = 30 * 60
        let session = try db.query("""
            SELECT \(fileColumns) FROM files f LEFT JOIN projects p ON p.id = f.project_id
            WHERE f.id != ? AND f.deleted_at IS NULL AND f.modified BETWEEN ? AND ?
            ORDER BY abs(f.modified - ?) LIMIT ?
            """, file.id, file.modified.addingTimeInterval(-window), file.modified.addingTimeInterval(window),
            file.modified, limit).map(FileRecord.init(row:))

        let topics = try db.query("""
            SELECT \(fileColumns), count(*) AS shared FROM file_tags mine
            JOIN file_tags theirs ON theirs.tag_id = mine.tag_id AND theirs.file_id != mine.file_id
            JOIN files f ON f.id = theirs.file_id LEFT JOIN projects p ON p.id = f.project_id
            WHERE mine.file_id = ? AND f.deleted_at IS NULL
            GROUP BY f.id ORDER BY shared DESC, f.modified DESC LIMIT ?
            """, file.id, limit).map(FileRecord.init(row:))

        let project = try file.projectID.map { try latestFiles(project: $0, limit: limit + 1).filter { $0.id != file.id } } ?? []

        let versionIDs = Set(versions.map(\.id))
        return Related(versions: versions,
                       sameSession: session.filter { !versionIDs.contains($0.id) },
                       sameTopics: topics.filter { !versionIDs.contains($0.id) },
                       sameProject: Array(project.prefix(limit)))
    }

    public func file(id: Int) throws -> FileRecord? {
        try db.query("SELECT \(fileColumns) FROM files f LEFT JOIN projects p ON p.id = f.project_id WHERE f.id = ?", id)
            .first.map(FileRecord.init(row:))
    }

    public func file(path: String) throws -> FileRecord? {
        try db.query("SELECT \(fileColumns) FROM files f LEFT JOIN projects p ON p.id = f.project_id WHERE f.path = ?", path)
            .first.map(FileRecord.init(row:))
    }

    // MARK: - Helpers

    /// Quotes a keyword for FTS5. A prefix term also matches longer words ("therm" finds "thermal").
    /// "w-2" becomes a phrase, matching "W-2.pdf".
    static func ftsTerm(_ keyword: String, prefix: Bool) -> String {
        "\"\(keyword.replacingOccurrences(of: "\"", with: ""))\"" + (prefix ? "*" : "")
    }

    /// A one-line answer built from the top result, no model needed.
    /// `chosen` means the model picked the top hit as the answer to the question.
    static func answer(for plan: QueryPlan, hits: [SearchHit], chosen: Bool = false) -> String? {
        // Only a file with every word earns a one-line answer; a partial match is just a lead.
        guard let top = hits.first, chosen || (top.coverage == 1 && (plan.newestFirst || hits.count == 1)) else { return nil }
        var line = "\(top.file.name) — \(RelativeTime.describe(top.file.modified))"
        if let project = top.file.projectName { line += " in \(project)" }
        if top.versionCount > 1 { line += " (newest of \(top.versionCount) versions)" }
        return line
    }
}

public enum RelativeTime {
    public static func describe(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}


