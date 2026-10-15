import Foundation

/// Turns a `QueryPlan` into ranked results. Everything here is plain SQLite, so it answers in
/// milliseconds; the model only ever shapes the plan.
public final class SearchEngine: @unchecked Sendable {
    let db: Database

    init(db: Database) {
        self.db = db
    }

    public func search(_ plan: QueryPlan, limit: Int = 30, now: Date = Date()) throws -> SearchResponse {
        var filters = ["f.deleted_at IS NULL"]
        var arguments: [Any?] = []
        if !plan.kinds.isEmpty {
            filters.append("f.kind IN (\(plan.kinds.map { _ in "?" }.joined(separator: ",")))")
            arguments += plan.kinds.map(\.rawValue)
        }
        if let interval = plan.timeframe.interval(now: now) {
            filters.append("f.modified >= ? AND f.modified < ?")
            arguments += [interval.start, min(interval.end, Date.distantFuture)]
        }
        if let origin = plan.origin {
            filters.append("f.origin = ?")
            arguments.append(origin.rawValue)
        }

        var candidates: [(FileRecord, Double)] = []
        if plan.keywords.isEmpty {
            let rows = try db.query("""
                SELECT \(fileColumns) FROM files f LEFT JOIN projects p ON p.id = f.project_id
                WHERE \(filters.joined(separator: " AND "))
                ORDER BY f.modified DESC LIMIT ?
                """, arguments: arguments + [limit * 4])
            candidates = rows.map { (FileRecord(row: $0), 0) }
        } else {
            // All keywords first; if that finds nothing, any keyword.
            for joiner in [" AND ", " OR "] {
                let match = plan.keywords.map(Self.ftsTerm).joined(separator: joiner)
                let rows = try db.query("""
                    SELECT \(fileColumns), bm25(search, 10.0, 3.0, 2.0, 3.0, 6.0) AS rank
                    FROM search JOIN files f ON f.id = search.rowid LEFT JOIN projects p ON p.id = f.project_id
                    WHERE search MATCH ? AND \(filters.joined(separator: " AND "))
                    ORDER BY rank LIMIT 400
                    """, arguments: [match] + arguments)
                candidates = rows.map { (FileRecord(row: $0), -($0.double("rank") ?? 0)) }
                if !candidates.isEmpty || plan.keywords.count == 1 { break }
            }
        }

        let hits = rank(candidates, plan: plan, now: now)
        let collapsed = try collapseVersions(hits).prefix(limit)
        let projects = try matchingProjects(plan.keywords)
        return SearchResponse(plan: plan, hits: Array(collapsed), projects: projects,
                              answer: Self.answer(for: plan, hits: Array(collapsed)), refinedByModel: false)
    }

    /// Blends text relevance with recency. "Latest" questions lean hard on recency.
    private func rank(_ candidates: [(FileRecord, Double)], plan: QueryPlan, now: Date) -> [SearchHit] {
        let best = candidates.map(\.1).max() ?? 0
        let recencyWeight = plan.newestFirst || plan.keywords.isEmpty ? 0.75 : 0.3
        return candidates.map { file, relevance in
            let ageDays = max(0, now.timeIntervalSince(file.modified)) / 86_400
            let recency = exp(-ageDays / 21)
            let normalized = best > 0 ? relevance / best : 0
            let score = (1 - recencyWeight) * normalized + recencyWeight * recency
            return SearchHit(file: file, score: score, versionCount: 1)
        }
        .sorted { $0.score > $1.score }
    }

    /// Shows each version chain once, as its newest file, with a count of the others.
    private func collapseVersions(_ hits: [SearchHit]) throws -> [SearchHit] {
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
            collapsed.file = versions.first ?? hit.file
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

    /// Quotes a keyword for FTS5 and allows prefix matches ("therm" finds "thermal").
    static func ftsTerm(_ keyword: String) -> String {
        "\"\(keyword.replacingOccurrences(of: "\"", with: ""))\"*"
    }

    /// A one-line answer built from the top result, no model needed.
    static func answer(for plan: QueryPlan, hits: [SearchHit]) -> String? {
        guard let top = hits.first, plan.newestFirst || hits.count == 1 else { return nil }
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
