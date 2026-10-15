import Foundation

/// Writes what the file system tells us into the graph: files, their projects, version chains,
/// activity events and the full-text index.
public final class Indexer: @unchecked Sendable {
    let db: Database
    public private(set) var rules: ScopeRules
    let resolver: ProjectResolver
    private var projectIDs: [String: Int] = [:]
    private let lock = NSLock()

    /// How long a run of saves to the same file counts as one "modified" event.
    static let eventWindow: TimeInterval = 10 * 60

    init(db: Database, rules: ScopeRules, home: String = TrailPaths.home) {
        self.db = db
        self.rules = rules
        self.resolver = ProjectResolver(home: home)
    }

    func updateRules(_ rules: ScopeRules) {
        lock.lock(); self.rules = rules; lock.unlock()
    }

    // MARK: - Applying changes

    /// Brings the given paths up to date. Folders in `rescan` are walked as well, which catches
    /// whole folders moved or copied in (the file system reports only the folder itself).
    @discardableResult
    public func apply(paths: Set<String>, rescan: Set<String> = [], recordEvents: Bool = true) throws -> Int {
        loadCollectionsIfNeeded()
        var changed = 0
        for folder in rescan where rules.shouldDescend(into: folder) && treeCollection(containing: folder + "/") == nil {
            changed += try scan(root: folder, cutoff: nil, recordEvents: recordEvents, limit: 20_000)
        }
        var remaining = paths.subtracting(rescan)
        for path in remaining {
            guard let tree = treeCollection(containing: path) else { continue }
            remaining.remove(path)
            try db.run("UPDATE files SET modified = max(modified, ?) WHERE path = ?", Date(), tree)
        }
        let byFolder = Dictionary(grouping: remaining) { ($0 as NSString).deletingLastPathComponent }
        try db.transaction {
            for (folder, group) in byFolder {
                // A folder filling up with generated files becomes one collection entry.
                if collectionFolders.contains(folder) || (group.count >= 8 && isBurstFolder(folder)) {
                    for path in group where !FileManager.default.fileExists(atPath: path) { changed += try markDeleted(path) }
                    changed += try refreshCollection(folder, recordEvents: recordEvents)
                    continue
                }
                for path in group.sorted() { changed += try applyOne(path, recordEvents: recordEvents) }
            }
        }
        return changed
    }

    private func applyOne(_ path: String, recordEvents: Bool) throws -> Int {
        guard FileManager.default.fileExists(atPath: path) else { return try markDeleted(path) }
        guard rules.shouldIndex(path), let inspection = FileInspector.inspect(path) else { return 0 }
        return try upsert(inspection, recordEvents: recordEvents) ? 1 : 0
    }

    /// Walks the roots once and indexes files changed within `days`. Returns the number indexed.
    @discardableResult
    public func backfill(days: Int, progress: ((Int, String) -> Void)? = nil) throws -> Int {
        loadCollectionsIfNeeded()
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var total = 0
        for root in rules.roots {
            let before = total
            total += try scan(root: root, cutoff: cutoff, recordEvents: false) { count, path in
                progress?(before + count, path)
            }
        }
        try collapseLargeTrees()
        return total
    }

    private enum Work {
        case file(String)
        case collection(String)
    }

    private struct Entry {
        var path: String
        var modified: Date
        var created: Date
    }

    /// Walks a tree one folder at a time, so each folder can be judged as a whole (a burst of
    /// generated files becomes a collection), and commits in batches.
    func scan(root: String, cutoff: Date?, recordEvents: Bool, limit: Int = .max,
              progress: ((Int, String) -> Void)? = nil) throws -> Int {
        var stack = [root]
        var work: [Work] = []
        var indexed = 0
        var seen = 0

        func flush() throws {
            guard !work.isEmpty else { return }
            var last = ""
            try db.transaction {
                for item in work {
                    switch item {
                    case .file(let path):
                        last = path
                        if let inspection = FileInspector.inspect(path), try upsert(inspection, recordEvents: recordEvents) {
                            indexed += 1
                        }
                    case .collection(let folder):
                        last = folder
                        indexed += try refreshCollection(folder, recordEvents: recordEvents)
                    }
                }
            }
            progress?(indexed, last)
            work.removeAll(keepingCapacity: true)
        }

        while let folder = stack.popLast() {
            if folder != root, treeCollections.contains(folder) { continue }
            autoreleasepool {
                var subfolders: [String] = []
                let files = entries(in: folder, cutoff: cutoff, subfolders: &subfolders)
                stack += subfolders.reversed()
                if Self.isBurst(files.map(\.created)), !isContainer(folder) {
                    work.append(.collection(folder))
                } else {
                    work += files.map { .file($0.path) }
                }
                seen += files.count
            }
            if work.count >= 400 { try flush() }
            if seen >= limit { break }
        }
        try flush()
        return indexed
    }

    /// The indexable files directly inside a folder. Uses `lstat` and builds paths from the
    /// folder's own spelling, so roots under symlinks (/var → /private/var) stay consistent.
    private func entries(in folder: String, cutoff: Date?, subfolders: inout [String]) -> [Entry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        var files: [Entry] = []
        for name in names where !name.hasPrefix(".") {
            let path = folder + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            let isPackage = type == S_IFDIR && ScopeRules.packageExtensions.contains((name as NSString).pathExtension.lowercased())
            if type == S_IFDIR, !isPackage {
                if rules.shouldDescend(into: path) { subfolders.append(path) }
                continue
            }
            guard type == S_IFREG || isPackage else { continue }
            let modified = Date(timespec: info.st_mtimespec)
            if let cutoff, modified < cutoff { continue }
            guard rules.shouldIndex(path) else { continue }
            files.append(Entry(path: path, modified: modified, created: Date(timespec: info.st_birthtimespec)))
        }
        return files
    }

    // MARK: - Collections

    /// Folders currently stored as one collection entry.
    private var collectionFolders: Set<String> = []
    private var collectionsLoaded = false

    private func loadCollectionsIfNeeded() {
        guard !collectionsLoaded else { return }
        collectionsLoaded = true
        let rows = (try? db.query("SELECT path, ext FROM files WHERE kind = 'collection' AND deleted_at IS NULL")) ?? []
        collectionFolders = Set(rows.filter { $0.string("ext") != "tree" }.compactMap { $0.string("path") })
        treeCollections = Set(rows.filter { $0.string("ext") == "tree" }.compactMap { $0.string("path") })
    }

    /// Whole folder trees stored as one entry (see `collapseLargeTrees`).
    private var treeCollections: Set<String> = []

    private func treeCollection(containing path: String) -> String? {
        guard !treeCollections.isEmpty else { return nil }
        var current = (path as NSString).deletingLastPathComponent
        while current.count > 1 {
            if treeCollections.contains(current) { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Kinds that pile up in machine-made output: renders, screenshots, logs, JSON.
    private static let bulkKinds: Set<String> = ["image", "data", "text", "other", "collection", "video", "audio"]

    /// Finds folder trees with thousands of files that are almost all bulk kinds — test
    /// artifacts, exports, render output — and stores each as a single entry with its three
    /// newest files. Project roots and top-level places like Downloads are never collapsed.
    func collapseLargeTrees(minimum: Int = 3_000, bulkShare: Double = 0.85) throws {
        loadCollectionsIfNeeded()
        var totals: [String: (all: Int, bulk: Int)] = [:]
        let projectRoots = Set(try db.query("SELECT root FROM projects").compactMap { $0.string("root") })
        for row in try db.query("SELECT path, kind FROM files WHERE deleted_at IS NULL") {
            guard let path = row.string("path") else { continue }
            let isBulk = Self.bulkKinds.contains(row.string("kind") ?? "")
            var folder = (path as NSString).deletingLastPathComponent
            while folder.count > 1, !projectRoots.contains(folder), !isContainer(folder) {
                var total = totals[folder] ?? (0, 0)
                total.all += 1
                if isBulk { total.bulk += 1 }
                totals[folder] = total
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        let candidates = totals.filter { $0.value.all >= minimum && Double($0.value.bulk) / Double($0.value.all) >= bulkShare }
        // Start from the outermost candidates, then step down while one subfolder holds nearly
        // everything — so docs/verification is collapsed, not docs with its hand-written notes.
        let outermost = candidates.keys.filter { folder in
            !candidates.keys.contains { $0 != folder && folder.hasPrefix($0 + "/") }
        }
        let roots = Set(outermost.map { folder in
            var current = folder
            while let child = candidates.keys
                .filter({ ($0 as NSString).deletingLastPathComponent == current })
                .max(by: { candidates[$0]!.all < candidates[$1]!.all }),
                Double(candidates[child]!.all) >= 0.9 * Double(candidates[current]!.all) {
                current = child
            }
            return current
        })
        for folder in roots.sorted() {
            try collapseTree(folder, fileCount: candidates[folder]!.all)
        }
    }

    private func collapseTree(_ folder: String, fileCount: Int) throws {
        let inside = "path > ? AND path < ?"
        let range: [Any?] = [folder + "/", folder + "0"]
        let newest = try db.query("SELECT path FROM files WHERE \(inside) AND kind != 'collection' AND deleted_at IS NULL ORDER BY modified DESC LIMIT 3", arguments: range)
            .compactMap { $0.string("path") }
        let sample = try db.query("SELECT path FROM files WHERE \(inside) AND kind != 'collection' LIMIT 2000", arguments: range)
            .compactMap { $0.string("path") }
        let stats = try db.query("SELECT max(modified) AS newest, min(created) AS oldest FROM files WHERE \(inside)", arguments: range).first
        try db.transaction {
            let keep = newest + Array(repeating: "", count: 3 - newest.count)
            let condition = "\(inside) AND path NOT IN (?, ?, ?)"
            try db.run("DELETE FROM search WHERE rowid IN (SELECT id FROM files WHERE \(condition))", arguments: range + keep)
            try db.run("DELETE FROM files WHERE \(condition)", arguments: range + keep)

            var info = stat()
            lstat(folder, &info)
            let collection = Inspection(
                path: folder, name: (folder as NSString).lastPathComponent, ext: "tree", kind: .collection,
                size: fileCount, inode: UInt64(info.st_ino), created: stats?.date("oldest"),
                modified: stats?.date("newest") ?? Date(),
                origin: FileInspector.classifyOrigin(path: folder + "/", app: nil, sourceURL: nil), originApp: nil, sourceURL: nil)
            try upsert(collection, recordEvents: false)
            try db.run("UPDATE files SET ext = 'tree', size = ?, summary = ?, enriched_at = ? WHERE path = ?",
                       fileCount, Self.describeCollection(sample, total: fileCount) + " in subfolders", Date(), folder)
            if let id = try db.scalarInt("SELECT id FROM files WHERE path = ?", folder) { try refreshSearch(id) }
        }
        treeCollections.insert(folder)
        collectionFolders = collectionFolders.filter { !$0.hasPrefix(folder + "/") }
    }

    /// At least 20 files, with 80% of them created within ten minutes of each other: the
    /// signature of a script, export or AI agent rather than a person.
    static func isBurst(_ created: [Date]) -> Bool {
        guard created.count >= 20 else { return false }
        let sorted = created.sorted()
        let low = sorted[sorted.count / 10]
        let high = sorted[sorted.count * 9 / 10 - 1]
        return high.timeIntervalSince(low) < 600
    }

    private func isBurstFolder(_ folder: String) -> Bool {
        var ignored: [String] = []
        return Self.isBurst(entries(in: folder, cutoff: nil, subfolders: &ignored).map(\.created)) && !isContainer(folder)
    }

    /// Top-level places like Downloads are never collapsed, however busy they get.
    private func isContainer(_ folder: String) -> Bool {
        ProjectResolver.containerNames.contains((folder as NSString).lastPathComponent)
    }

    /// Stores a folder as one entry ("1,376 files · mostly PNG images") plus its three newest files.
    @discardableResult
    func refreshCollection(_ folder: String, recordEvents: Bool) throws -> Int {
        var ignored: [String] = []
        let files = entries(in: folder, cutoff: nil, subfolders: &ignored).sorted { $0.modified > $1.modified }
        guard let newest = files.first else { return 0 }
        collectionFolders.insert(folder)

        var info = stat()
        lstat(folder, &info)
        let collection = Inspection(
            path: folder, name: (folder as NSString).lastPathComponent, ext: "", kind: .collection,
            size: files.count, inode: UInt64(info.st_ino), created: files.map(\.created).min(), modified: newest.modified,
            origin: FileInspector.classifyOrigin(path: folder + "/", app: nil, sourceURL: nil), originApp: nil, sourceURL: nil)
        let changed = try upsert(collection, recordEvents: recordEvents)

        // Keep only the three newest files as individual entries.
        let keep = files.prefix(3).map(\.path)
        let padded = keep + Array(repeating: "", count: 3 - keep.count)
        let children = """
            path > ? AND path < ? AND instr(substr(path, ?), '/') = 0 AND path NOT IN (?, ?, ?)
            """
        let arguments: [Any?] = [folder + "/", folder + "0", folder.unicodeScalars.count + 2] + padded
        try db.run("DELETE FROM search WHERE rowid IN (SELECT id FROM files WHERE \(children))", arguments: arguments)
        try db.run("DELETE FROM files WHERE \(children)", arguments: arguments)
        for path in keep {
            if let inspection = FileInspector.inspect(path) { try upsert(inspection, recordEvents: false) }
        }

        if changed {
            try db.run("UPDATE files SET summary = ?, enriched_at = ? WHERE path = ?",
                       Self.describeCollection(files.map(\.path)), Date(), folder)
            if let id = try db.scalarInt("SELECT id FROM files WHERE path = ?", folder) { try refreshSearch(id) }
        }
        return changed ? 1 : 0
    }

    static func describeCollection(_ paths: [String], total: Int? = nil) -> String {
        let extensions = paths.map { ($0 as NSString).pathExtension.lowercased() }
        let counts = Dictionary(grouping: extensions, by: { $0 }).mapValues(\.count)
        var text = "\((total ?? paths.count).formatted()) files"
        if let (ext, count) = counts.max(by: { $0.value < $1.value }), count * 2 > paths.count, !ext.isEmpty {
            let kind = FileKind.from(extension: ext)
            text += " · mostly \(ext.uppercased()) \(kind == .other ? "files" : kind.displayName.lowercased() + "s")"
        }
        return text
    }

    // MARK: - Files

    /// Inserts or updates one file. Returns false when nothing changed.
    @discardableResult
    func upsert(_ file: Inspection, recordEvents: Bool) throws -> Bool {
        let now = Date()
        let project = resolver.project(forFile: file.path)
        var projectID: Int?
        if let project { projectID = try self.projectID(for: project, active: file.modified) }
        let stem = file.kind.isVersioned ? VersionNamer.stem(for: file.name) : nil

        let id: Int
        var event: String?
        var chainID: Int?

        if let existing = try db.query("SELECT id, modified, size, deleted_at, chain_id FROM files WHERE path = ?", file.path).first {
            id = existing.int("id")!
            chainID = existing.int("chain_id")
            let sameContent = abs((existing.double("modified") ?? 0) - file.modified.timeIntervalSince1970) < 0.5
                && existing.int("size") == file.size
            if sameContent, existing.double("deleted_at") == nil { return false }
            try db.run("""
                UPDATE files SET kind = ?, size = ?, inode = ?, modified = ?, project_id = ?, stem = ?,
                    origin = CASE WHEN origin = 'local' THEN ? ELSE origin END,
                    origin_app = coalesce(origin_app, ?), source_url = coalesce(source_url, ?), deleted_at = NULL
                WHERE id = ?
                """, file.kind.rawValue, file.size, file.inode, file.modified, projectID, stem?.stem,
                file.origin.rawValue, file.originApp, file.sourceURL, id)
            event = "modified"
        } else if let moved = try movedFile(file) {
            id = moved.id
            chainID = moved.chainID
            try db.run("""
                UPDATE files SET path = ?, name = ?, ext = ?, kind = ?, size = ?, modified = ?, project_id = ?,
                    stem = ?, deleted_at = NULL
                WHERE id = ?
                """, file.path, file.name, file.ext, file.kind.rawValue, file.size, file.modified, projectID, stem?.stem, id)
            event = "moved"
        } else {
            try db.run("""
                INSERT INTO files (path, name, ext, kind, size, inode, created, modified, first_seen, origin,
                    origin_app, source_url, project_id, stem)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, file.path, file.name, file.ext, file.kind.rawValue, file.size, file.inode, file.created,
                file.modified, now, file.origin.rawValue, file.originApp, file.sourceURL, projectID, stem?.stem)
            id = db.lastInsertID
            event = switch file.origin {
            case .download: "downloaded"
            case .ai: "ai-saved"
            case .local: "created"
            }
        }

        if chainID == nil, let stem {
            try linkVersion(id: id, file: file, stem: stem, projectID: projectID)
        }
        if recordEvents, let event {
            try recordEvent(event, fileID: id, at: event == "moved" ? now : file.modified)
        }
        try refreshSearch(id)
        return true
    }

    /// A file at a new path with the inode, size and name of one whose old path is gone was moved
    /// or renamed. Reusing its row keeps its history and summary.
    private func movedFile(_ file: Inspection) throws -> (id: Int, chainID: Int?)? {
        let candidates = try db.query(
            "SELECT id, path, chain_id FROM files WHERE inode = ? AND size = ? AND path != ? LIMIT 5",
            file.inode, file.size, file.path)
        for row in candidates {
            guard let path = row.string("path"), !FileManager.default.fileExists(atPath: path) else { continue }
            return (row.int("id")!, row.int("chain_id"))
        }
        return nil
    }

    private func linkVersion(id: Int, file: Inspection, stem: VersionNamer.Result, projectID: Int?) throws {
        let folder = (file.path as NSString).deletingLastPathComponent
        let candidates = try db.query("""
            SELECT id, path, name, chain_id, project_id FROM files
            WHERE stem = ? AND kind = ? AND id != ? AND deleted_at IS NULL
            ORDER BY modified LIMIT 50
            """, stem.stem, file.kind.rawValue, id)
        let match = candidates.first { row in
            guard let path = row.string("path"), let name = row.string("name") else { return false }
            let sameFolder = (path as NSString).deletingLastPathComponent == folder
            let sameProject = projectID != nil && row.int("project_id") == projectID
            guard sameFolder || sameProject else { return false }
            return stem.hasMarker || name == file.name || VersionNamer.stem(for: name)?.hasMarker == true
        }
        guard let match, let matchID = match.int("id") else { return }
        let chain = match.int("chain_id") ?? matchID
        try db.run("UPDATE files SET chain_id = ? WHERE id IN (?, ?)", chain, matchID, id)
    }

    @discardableResult
    func markDeleted(_ path: String) throws -> Int {
        // Covers the path itself and, for a folder, everything under it ("/" + 1 == "0").
        try db.run("""
            UPDATE files SET deleted_at = ?
            WHERE deleted_at IS NULL AND (path = ? OR (path >= ? AND path < ?))
            """, Date(), path, path + "/", path + "0")
    }

    private func recordEvent(_ kind: String, fileID: Int, at date: Date) throws {
        if kind == "modified",
           let last = try db.query("SELECT at FROM events WHERE file_id = ? ORDER BY at DESC LIMIT 1", fileID).first?.double("at"),
           date.timeIntervalSince1970 - last < Self.eventWindow {
            return
        }
        try db.run("INSERT INTO events (file_id, kind, at) VALUES (?, ?, ?)", fileID, kind, date)
    }

    // MARK: - Projects

    private func projectID(for project: ProjectResolver.Project, active: Date) throws -> Int {
        lock.lock()
        let cached = projectIDs[project.root]
        lock.unlock()
        if let cached {
            try db.run("UPDATE projects SET last_active = max(last_active, ?) WHERE id = ?", active, cached)
            return cached
        }
        try db.run("""
            INSERT INTO projects (root, name, kind, last_active) VALUES (?, ?, ?, ?)
            ON CONFLICT(root) DO UPDATE SET last_active = max(last_active, excluded.last_active)
            """, project.root, project.name, project.kind, active)
        let id = try db.scalarInt("SELECT id FROM projects WHERE root = ?", project.root)!
        lock.lock(); projectIDs[project.root] = id; lock.unlock()
        return id
    }

    // MARK: - Enrichment

    struct PendingFile {
        var id: Int
        var path: String
        var name: String
        var kind: FileKind
        var projectName: String?
    }

    /// Recent files that have no summary yet, or whose summary is older than their last real edit.
    func pendingEnrichment(limit: Int) throws -> [PendingFile] {
        let kinds = FileKind.allCases.filter(\.isEnrichable).map { "'\($0.rawValue)'" }.joined(separator: ",")
        let rows = try db.query("""
            SELECT f.id, f.path, f.name, f.kind, p.name AS project_name FROM files f
            LEFT JOIN projects p ON p.id = f.project_id
            WHERE f.deleted_at IS NULL AND f.kind IN (\(kinds)) AND f.size < 60000000
              AND (f.enriched_at IS NULL OR f.modified - f.enriched_at > 21600)
              AND f.modified > ?
            ORDER BY f.modified DESC LIMIT ?
            """, Date().addingTimeInterval(-180 * 86_400), limit)
        return rows.map {
            PendingFile(id: $0.int("id")!, path: $0.string("path")!, name: $0.string("name")!,
                        kind: FileKind(rawValue: $0.string("kind")!) ?? .other, projectName: $0.string("project_name"))
        }
    }

    func setEnrichment(id: Int, summary: String?, tags: [String]) throws {
        try db.transaction {
            try db.run("UPDATE files SET summary = ?, enriched_at = ? WHERE id = ?", summary, Date(), id)
            try db.run("DELETE FROM file_tags WHERE file_id = ?", id)
            for tag in Set(tags.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }) where !tag.isEmpty && tag.count <= 30 && !tag.contains("/") {
                try db.run("INSERT INTO tags (name) VALUES (?) ON CONFLICT(name) DO NOTHING", tag)
                try db.run("INSERT OR IGNORE INTO file_tags (file_id, tag_id) SELECT ?, id FROM tags WHERE name = ?", id, tag)
            }
            try refreshSearch(id)
        }
    }

    // MARK: - Search index

    /// Rewrites the full-text row for a file from what's stored about it.
    /// Refills the full-text index after a migration replaced it. Returns whether it did.
    @discardableResult
    func rebuildSearchIfNeeded() throws -> Bool {
        guard db.meta("search_rebuild") != nil else { return false }
        let ids = try db.query("SELECT id FROM files").compactMap { $0.int("id") }
        try db.transaction {
            for id in ids { try refreshSearch(id) }
            try db.run("DELETE FROM meta WHERE key = 'search_rebuild'")
        }
        return true
    }

    func refreshSearch(_ id: Int) throws {
        guard let row = try db.query("SELECT \(fileColumns) FROM files f LEFT JOIN projects p ON p.id = f.project_id WHERE f.id = ?", id).first else { return }
        let file = FileRecord(row: row)
        try db.run("DELETE FROM search WHERE rowid = ?", id)
        try db.run("INSERT INTO search (rowid, name, terms, summary, tags, project) VALUES (?, ?, ?, ?, ?, ?)",
                   id, Self.nameTerms(file.name), Self.contextTerms(for: file), file.summary ?? "",
                   file.tags.joined(separator: " "), file.projectName.map(Self.splitWords) ?? "")
    }

    static func nameTerms(_ name: String) -> String {
        let base = (name as NSString).deletingPathExtension
        let split = splitWords(base)
        return split == base ? name : "\(name) \(split)"
    }

    static func contextTerms(for file: FileRecord) -> String {
        let folders = (file.path as NSString).deletingLastPathComponent
            .split(separator: "/").suffix(3).map { splitWords(String($0)) }
        var parts = folders + [file.kind.synonyms, (file.name as NSString).pathExtension]
        if let host = file.sourceHost { parts.append(host) }
        if let app = file.originApp { parts.append(app) }
        switch file.origin {
        case .download: parts.append("downloaded download")
        case .ai: parts.append("ai generated")
        case .local: break
        }
        return parts.joined(separator: " ")
    }

    /// "ThermalAIapp_v2" → "Thermal AI app v 2": splits camelCase and letter/digit runs.
    static func splitWords(_ text: String) -> String {
        var output = ""
        var previous: Character?
        for character in text {
            if let previous {
                let lowerToUpper = previous.isLowercase && character.isUppercase
                let letterDigit = previous.isLetter && character.isNumber || previous.isNumber && character.isLetter
                if lowerToUpper || letterDigit { output.append(" ") }
            }
            output.append(character == "_" || character == "-" ? " " : character)
            previous = character
        }
        return output
    }

    // MARK: - Maintenance

    /// Forgets files deleted more than 30 days ago and drops orphaned tags and projects.
    public func prune() throws {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        try db.transaction {
            try db.run("DELETE FROM search WHERE rowid IN (SELECT id FROM files WHERE deleted_at < ?)", cutoff)
            try db.run("DELETE FROM files WHERE deleted_at < ?", cutoff)
            try db.run("DELETE FROM events WHERE at < ?", Date().addingTimeInterval(-400 * 86_400))
            try db.run("DELETE FROM tags WHERE id NOT IN (SELECT tag_id FROM file_tags)")
            try db.run("DELETE FROM projects WHERE id NOT IN (SELECT DISTINCT project_id FROM files WHERE project_id IS NOT NULL)")
        }
        lock.lock(); projectIDs.removeAll(); lock.unlock()
    }
}
