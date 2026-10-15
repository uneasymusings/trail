import Foundation

/// A folder Trail suggests for a file, and why.
public struct Destination: Hashable, Sendable, Codable {
    public var path: String
    public var reason: String
    /// The on-device model chose this one among the candidates.
    public var byModel: Bool

    public init(path: String, reason: String, byModel: Bool) {
        self.path = path
        self.reason = reason
        self.byModel = byModel
    }

    public var name: String { (path as NSString).lastPathComponent }

    /// The folder's name, with its parent when the parent says something: "Taxes 2026",
    /// but "portfolio/public" rather than a bare "public".
    public var label: String {
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let containers: Set<String> = ["Documents", "Desktop", "Downloads", "Developer", "Pictures", "Music", "Movies",
                                       "com~apple~CloudDocs", "Mobile Documents", "CloudStorage", ""]
        let home = (TrailPaths.home as NSString).lastPathComponent
        return containers.contains(parent) || parent == home ? name : "\(parent)/\(name)"
    }

    public var displayPath: String {
        let home = TrailPaths.home
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// A new loose file on the Desktop or in Downloads, with where it probably belongs.
public struct InboxItem: Identifiable, Hashable, Sendable {
    public var file: FileRecord
    public var arrived: Date
    /// Best first. Empty until Trail has looked at the file, or when nothing fits.
    public var destinations: [Destination]
    /// Whether Trail has looked at the file yet.
    public var isRead: Bool
    /// What the file is, in a line: the model's note, or the start of its text.
    public var gist: String?

    public var id: Int { file.id }
    public var suggestion: Destination? { destinations.first }
}

/// New loose files on the Desktop and in Downloads, each with a suggestion for where it belongs.
///
/// Trail never moves anything by itself. It reads a new file, looks for where files like it live
/// in the graph, and waits for you to say yes, pick another folder, or keep it where it is.
/// What you decide is remembered: it's the strongest hint for the next file like it.
public final class Inbox: @unchecked Sendable {
    let db: Database
    let search: SearchEngine
    let rules: () -> ScopeRules
    let home: String

    /// Files only count once they've sat for a while, so the screenshot you're about to paste
    /// somewhere isn't flagged the moment you take it.
    public static let settle: TimeInterval = 10 * 60
    /// Only files that arrived in the last week. Older clutter stays out of the count.
    static let window: TimeInterval = 7 * 86_400
    /// Installers and partial downloads aren't things you file away.
    static let skippedExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "app", "crdownload", "download", "part", "partial"]

    init(db: Database, search: SearchEngine, home: String = TrailPaths.home, rules: @escaping () -> ScopeRules) {
        self.db = db
        self.search = search
        self.home = home
        self.rules = rules
    }

    var folders: [String] { [home + "/Desktop", home + "/Downloads"] }

    func isLoose(_ path: String) -> Bool {
        folders.contains((path as NSString).deletingLastPathComponent)
    }

    // MARK: - Arrivals

    /// Adds new loose files, and notices files you've put away yourself, which teaches it too.
    /// Returns the ids of files that still need reading.
    @discardableResult
    func refresh(now: Date = Date()) throws -> [Int] {
        try db.transaction {
            for row in try db.query("""
                SELECT i.file_id, f.path, f.deleted_at FROM inbox i JOIN files f ON f.id = i.file_id
                WHERE i.status = 'waiting'
                """) {
                let id = row.int("file_id")!, path = row.string("path")!
                if row.double("deleted_at") != nil {
                    try db.run("UPDATE inbox SET status = 'gone', decided_at = ? WHERE file_id = ?", now, id)
                } else if !isLoose(path) {
                    try record(id, status: "moved", destination: (path as NSString).deletingLastPathComponent, now: now)
                }
            }
            for folder in folders {
                let rows = try db.query("""
                    SELECT id, path, ext, max(modified, coalesce(created, 0)) AS arrived FROM files
                    WHERE path >= ? AND path < ? AND deleted_at IS NULL AND kind != 'collection'
                      AND max(modified, coalesce(created, 0)) > ?
                    """, folder + "/", folder + "/\u{10FFFF}", now.addingTimeInterval(-Self.window))
                for row in rows where isLoose(row.string("path")!) && !Self.skippedExtensions.contains(row.string("ext")!.lowercased()) {
                    try db.run("INSERT OR IGNORE INTO inbox (file_id, arrived, status) VALUES (?, ?, 'waiting')",
                               row.int("id")!, row.double("arrived")!)
                }
            }
        }
        return try db.query("SELECT file_id FROM inbox WHERE status = 'waiting' AND read_at IS NULL ORDER BY arrived DESC")
            .compactMap { $0.int("file_id") }
    }

    /// Files waiting to be sorted, newest first. `includeSettling` also returns ones that
    /// arrived in the last few minutes.
    public func items(now: Date = Date(), includeSettling: Bool = false) throws -> [InboxItem] {
        let cutoff = includeSettling ? now : now.addingTimeInterval(-Self.settle)
        return try db.query("""
            SELECT \(fileColumns), i.arrived, i.destinations, i.gist, i.read_at FROM inbox i
            JOIN files f ON f.id = i.file_id LEFT JOIN projects p ON p.id = f.project_id
            WHERE i.status = 'waiting' AND f.deleted_at IS NULL AND i.arrived <= ?
            ORDER BY i.arrived DESC
            """, cutoff).map { row in
            let destinations = row.string("destinations").flatMap { try? JSONDecoder().decode([Destination].self, from: Data($0.utf8)) } ?? []
            return InboxItem(file: FileRecord(row: row), arrived: row.date("arrived") ?? .distantPast,
                             destinations: destinations, isRead: row.double("read_at") != nil, gist: row.string("gist"))
        }
    }

    public func count(now: Date = Date()) -> Int {
        (try? db.scalarInt("""
            SELECT count(*) FROM inbox i JOIN files f ON f.id = i.file_id
            WHERE i.status = 'waiting' AND f.deleted_at IS NULL AND i.arrived <= ?
            """, now.addingTimeInterval(-Self.settle))) ?? 0
    }

    func record(_ id: Int, status: String, destination: String? = nil, now: Date = Date()) throws {
        try db.run("UPDATE inbox SET status = ?, destination = ?, decided_at = ? WHERE file_id = ?", status, destination, now, id)
    }

    // MARK: - Where it belongs

    /// Reads a file and works out where it probably belongs. The model, when there is one,
    /// chooses among folders the graph already found, so it can only suggest real places.
    func read(_ id: Int, intelligence: Intelligence?) async throws {
        guard let file = try search.file(id: id) else { return }
        let arrived = try db.query("SELECT arrived FROM inbox WHERE file_id = ?", id).first?.date("arrived") ?? file.modified
        // Only a few files arrive at a time, so screenshots get the slower, accurate OCR.
        let text = autoreleasepool { TextExtractor.excerpt(path: file.path, kind: file.kind, accurate: true) }
        var destinations = try candidates(for: file, text: text, arrived: arrived)
        if let intelligence, destinations.count > 1,
           let chosen = await intelligence.chooseFolder(for: file, text: text, from: destinations.map(\.path), home: home),
           destinations.indices.contains(chosen) {
            var pick = destinations.remove(at: chosen)
            pick.byModel = true
            destinations.insert(pick, at: 0)
        }
        let gist = file.summary ?? text.map { String($0.prefix(140)) }
        let json = String(decoding: try JSONEncoder().encode(destinations), as: UTF8.self)
        try db.run("UPDATE inbox SET destinations = ?, gist = ?, read_at = ? WHERE file_id = ?", json, gist, Date(), id)
    }

    /// Folders where this file would fit, best first, from three kinds of evidence in the graph:
    /// where files like it live, where you were working when it arrived, and where you put
    /// similar files before.
    func candidates(for file: FileRecord, text: String?, arrived: Date) throws -> [Destination] {
        var votes: [String: (score: Double, reasons: [(Double, String)])] = [:]
        func vote(_ folder: String, _ score: Double, _ reason: String) {
            guard isGoodHome(folder) else { return }
            var entry = votes[folder] ?? (0, [])
            entry.score += score
            entry.reasons.append((score, reason))
            votes[folder] = entry
        }

        // 1. Files like it: search the graph with its distinctive words.
        let words = Self.distinctiveWords(name: file.name, host: file.sourceHost, text: text)
        if !words.isEmpty {
            var plan = QueryPlan(text: words.joined(separator: " "), keywords: words)
            plan.newestFirst = false
            let hits = try search.search(plan, limit: 40, correctTypos: false).hits
                .filter { $0.file.id != file.id && !isLoose($0.file.path) && ![.code, .data, .collection].contains($0.file.kind) }
            var examples: [String: [String]] = [:]
            for (rank, hit) in hits.prefix(25).enumerated() {
                let folder = (hit.file.path as NSString).deletingLastPathComponent
                examples[folder, default: []].append(hit.file.name)
                let names = examples[folder]!.prefix(2).joined(separator: " and ")
                vote(folder, hit.coverage / (1 + Double(rank) * 0.25), "Like \(names) there")
            }
        }

        // 2. What you were doing when it arrived.
        // Code projects don't count: a screenshot isn't a website asset because you were coding.
        let session = try db.query("""
            SELECT f.path FROM files f LEFT JOIN projects p ON p.id = f.project_id
            WHERE f.deleted_at IS NULL AND f.id != ? AND f.kind NOT IN ('code', 'data', 'collection')
              AND (p.kind IS NULL OR p.kind != 'code') AND f.modified BETWEEN ? AND ?
            """, file.id, arrived.addingTimeInterval(-45 * 60), arrived.addingTimeInterval(45 * 60))
        let sessionFolders = Dictionary(grouping: session.compactMap { $0.string("path") }.filter { !isLoose($0) }) {
            ($0 as NSString).deletingLastPathComponent
        }
        for (folder, paths) in sessionFolders {
            vote(folder, 0.5 * min(1, Double(paths.count) / 3), "You were working there when it arrived")
        }

        // 3. Where you put files like it before.
        let decisions = try db.query("""
            SELECT i.destination, f.name, f.ext, f.source_url FROM inbox i JOIN files f ON f.id = i.file_id
            WHERE i.status = 'moved' AND i.destination IS NOT NULL ORDER BY i.decided_at DESC LIMIT 200
            """)
        let family = Self.family(file.name)
        for decision in decisions {
            let destination = decision.string("destination")!
            let host = decision.string("source_url").flatMap { URL(string: $0)?.host() }?.replacingOccurrences(of: "www.", with: "")
            if let host, host == file.sourceHost {
                vote(destination, 1.2, "Where your last download from \(host) went")
            } else if decision.string("ext")?.lowercased() == (file.name as NSString).pathExtension.lowercased(),
                      let family, Self.family(decision.string("name")!) == family {
                vote(destination, 0.8, "Where you put the last \(family) files")
            }
        }

        // Alternatives need real support, not one stray word in common.
        let ranked = votes.sorted { $0.value.score > $1.value.score }
        let floor = (ranked.first?.value.score ?? 0) * 0.3
        return ranked.filter { $0.value.score >= floor }.prefix(4).map { folder, entry in
            Destination(path: folder, reason: entry.reasons.max { $0.0 < $1.0 }!.1, byModel: false)
        }
    }

    /// A folder worth suggesting: real, yours, not hidden, not inside an app or build output, and
    /// not the Desktop or Downloads the file is leaving.
    func isGoodHome(_ folder: String) -> Bool {
        guard folder.hasPrefix(home + "/"), !folders.contains(folder) else { return false }
        let relative = folder.dropFirst(home.count + 1)
        if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") || ["node_modules", "src", "Sources", "build", "dist"].contains(String($0)) }) {
            return false
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        // Generated output (renders, exports) that Trail folded into one entry is no place for your files.
        let generated = (try? db.query("SELECT 1 FROM files WHERE kind = 'collection' AND deleted_at IS NULL AND (path = ? OR ? LIKE path || '/%') LIMIT 1", folder, folder)) ?? []
        return generated.isEmpty && rules().shouldIndex(folder + "/file.pdf")
    }

    /// Words that say what a file is: from its name (minus "Screenshot", dates and the like),
    /// the site it came from, and the words its text uses most.
    static func distinctiveWords(name: String, host: String?, text: String?) -> [String] {
        let generic: Set<String> = ["screenshot", "screen", "shot", "img", "image", "photo", "scan", "scanned", "document",
                                    "file", "download", "downloads", "untitled", "copy", "final", "draft", "new", "at", "pm", "am",
                                    "www", "com", "org", "net", "io", "co", "app", "mail", "drive", "docs", "pdf", "png", "jpg",
                                    "jpeg", "heic", "the", "and", "for"]
        func keep(_ word: String) -> Bool {
            word.count >= 3 && !word.allSatisfy(\.isNumber) && !generic.contains(word) && !QueryParser.stopWords.contains(word)
        }
        var words: [String] = []
        for word in SearchEngine.nameWords((name as NSString).deletingPathExtension).map(\.word) where keep(word) && word.contains(where: \.isLetter) {
            if !words.contains(word) { words.append(word) }
        }
        for part in (host ?? "").lowercased().split(separator: ".").map(String.init) where keep(part) && !words.contains(part) {
            words.append(part)
        }
        if let text {
            let counts = text.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 && keep($0) }
                .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            for (word, _) in counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).prefix(6)
            where !words.contains(word) {
                words.append(word)
            }
        }
        return Array(words.prefix(10))
    }

    /// The kind of name a file has, for remembering habits: "Screenshot 2026-10-14 at…" and
    /// "IMG_4021" are families; "Pitch v3" isn't.
    static func family(_ name: String) -> String? {
        let first = name.lowercased().split { !$0.isLetter }.first.map(String.init) ?? ""
        return ["screenshot", "screen", "img", "image", "scan", "invoice", "receipt", "statement", "photo", "recording"].contains(first) ? first : nil
    }
}
