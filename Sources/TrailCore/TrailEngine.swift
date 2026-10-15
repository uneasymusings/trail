import Foundation

/// Ties the pieces together: watches the disk, keeps the graph current, enriches files in the
/// background and answers questions. The app and the `trail` CLI both use this.
public final class TrailEngine: @unchecked Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case scanning(indexed: Int)
        case watching
    }

    public private(set) var config: TrailConfig
    public let db: Database
    public let indexer: Indexer
    public let search: SearchEngine
    public let intelligence = Intelligence()

    /// Where to write the widget snapshot (the app sets this to its app-group folder).
    public var snapshotURL: URL?
    /// Called on the main queue after the graph changes.
    public var onChange: (@MainActor @Sendable () -> Void)?
    public private(set) var phase: Phase = .idle

    private var watcher: Watcher?
    private let indexQueue = DispatchQueue(label: "trail.index", qos: .utility)
    private var enrichTask: Task<Void, Never>?
    private var lastSnapshot = Date.distantPast
    private let configURL: URL

    public static func open(at directory: URL = TrailPaths.dataDirectory) throws -> TrailEngine {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("config.json")
        let config = TrailConfig.load(from: configURL)
        if !FileManager.default.fileExists(atPath: configURL.path) { try? config.save(to: configURL) }
        let db = try Database(path: directory.appendingPathComponent("trail.sqlite").path)
        try Schema.migrate(db)
        return TrailEngine(db: db, config: config, configURL: configURL)
    }

    init(db: Database, config: TrailConfig, configURL: URL) {
        self.db = db
        self.config = config
        self.configURL = configURL
        self.indexer = Indexer(db: db, rules: ScopeRules(config: config))
        self.search = SearchEngine(db: db)
    }

    /// Refills the search index if a schema migration replaced it. `start()` does this in the
    /// background; the CLI calls it directly.
    public func prepareSearchIndex() {
        guard (try? indexer.rebuildSearchIfNeeded()) == true else { return }
        try? db.exec("VACUUM; PRAGMA wal_checkpoint(TRUNCATE);")   // the old index's pages are free now
        releaseMemory()
    }

    public var hasCompletedFirstScan: Bool { db.meta("backfill_done") != nil }

    /// Records a scan done outside `start()` so the next start replays changes from `eventID`.
    public func markFirstScanComplete(eventID: UInt64) {
        db.setMeta("backfill_done", ISO8601DateFormatter().string(from: Date()))
        db.setMeta("last_event_id", String(eventID))
    }

    // MARK: - Lifecycle

    /// First run: start watching, then scan. Later runs: replay what changed while we were away.
    public func start() {
        let storedID = db.meta("last_event_id").flatMap(UInt64.init)
        let needsScan = !hasCompletedFirstScan
        let since = needsScan ? Watcher.currentEventID : storedID
        startWatcher(since: since)

        // The first scan runs at background priority (efficiency cores only) so it stays out of the way.
        indexQueue.async(qos: needsScan ? .background : .utility, flags: .enforceQoS) { [self] in
            prepareSearchIndex()
            if needsScan {
                setPhase(.scanning(indexed: 0))
                _ = try? indexer.backfill(days: config.backfillDays) { [weak self] count, _ in
                    self?.setPhase(.scanning(indexed: count))
                }
                db.setMeta("backfill_done", ISO8601DateFormatter().string(from: Date()))
                try? compact()      // reclaim the space the scan churned through
            }
            try? indexer.prune()
            setPhase(.watching)
            writeSnapshot(force: true)
        }
        if config.enrichWithModel { startEnriching() }
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        enrichTask?.cancel()
        enrichTask = nil
    }

    private func startWatcher(since: UInt64?) {
        let watcher = Watcher(roots: indexer.rules.roots, since: since) { [weak self] batch in
            self?.indexQueue.async { self?.handle(batch) }
        }
        watcher.start()
        self.watcher = watcher
    }

    private func handle(_ batch: Watcher.Batch) {
        let changed = (try? indexer.apply(paths: batch.paths, rescan: batch.rescan)) ?? 0
        if batch.lastEventID > 0 { db.setMeta("last_event_id", String(batch.lastEventID)) }
        guard changed > 0 else { return }
        writeSnapshot()
        notify()
    }

    /// Collapses bulky generated folder trees and reclaims disk space.
    /// The first scan builds large caches it won't need again; let them go.
    func releaseMemory() {
        indexer.resolver.invalidate()
        db.releaseMemory()
        malloc_zone_pressure_relief(nil, 0)
    }

    public func compact() throws {
        try indexer.collapseLargeTrees()
        try indexer.prune()
        try db.exec("VACUUM; PRAGMA wal_checkpoint(TRUNCATE);")
        releaseMemory()
    }

    /// Forgets everything and scans again.
    public func rebuild() {
        stop()
        indexQueue.async { [self] in
            try? db.exec("DELETE FROM search; DELETE FROM events; DELETE FROM file_tags; DELETE FROM tags; DELETE FROM files; DELETE FROM projects; DELETE FROM meta;")
            indexer.resolver.invalidate()
            DispatchQueue.main.async { self.start() }
        }
    }

    public func updateConfig(_ config: TrailConfig) {
        let rootsChanged = config.roots != self.config.roots || config.excludedPaths != self.config.excludedPaths
        self.config = config
        try? config.save(to: configURL)
        indexer.updateRules(ScopeRules(config: config))
        if rootsChanged {
            watcher?.stop()
            startWatcher(since: db.meta("last_event_id").flatMap(UInt64.init))
        }
        if config.enrichWithModel, enrichTask == nil { startEnriching() }
        if !config.enrichWithModel { enrichTask?.cancel(); enrichTask = nil }
    }

    private func setPhase(_ phase: Phase) {
        self.phase = phase
        notify()
    }

    private func notify() {
        guard let onChange else { return }
        DispatchQueue.main.async { onChange() }
    }

    // MARK: - Questions

    /// Rule-based only. Fast enough to run on every keystroke.
    public func quickSearch(_ text: String, limit: Int = 30) -> SearchResponse {
        let plan = QueryParser.parse(text)
        return (try? search.search(plan, limit: limit)) ?? .empty(plan)
    }

    /// Lets the on-device model read the question, then searches with its plan.
    public func ask(_ text: String, limit: Int = 30) async -> SearchResponse {
        let quick = QueryParser.parse(text)
        let quickResponse = (try? search.search(quick, limit: limit)) ?? .empty(quick)
        guard let refined = await intelligence.refine(quick), refined != quick else {
            return withActivity(quickResponse)
        }
        var response = (try? search.search(refined, limit: limit)) ?? .empty(refined)
        // A stricter plan that finds nothing is worse than the quick one.
        if response.hits.isEmpty, !quickResponse.hits.isEmpty { return withActivity(quickResponse) }
        response.refinedByModel = true
        return withActivity(response)
    }

    /// For "what was I doing?" questions: which projects the matching files belong to, straight
    /// from the data — instant, and nothing for a model to make up.
    private func withActivity(_ response: SearchResponse) -> SearchResponse {
        guard response.plan.isActivityQuestion, !response.hits.isEmpty else { return response }
        var response = response
        response.answer = Self.describeActivity(response.hits.map(\.file), timeframe: response.plan.timeframe)
        return response
    }

    static func describeActivity(_ files: [FileRecord], timeframe: Timeframe) -> String {
        let counts = Dictionary(grouping: files.compactMap(\.projectName), by: { $0 }).mapValues(\.count)
        let top = counts.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        let when = timeframe == .any ? "Lately" : timeframe.rawValue.prefix(1).uppercased() + timeframe.rawValue.dropFirst()
        guard !top.isEmpty else { return "\(when): \(files.count) loose files, newest \(files[0].name)" }
        let list = top.count == 1 ? top[0] : top.dropLast().joined(separator: ", ") + " and " + top.last!
        return "\(when) you were mostly in \(list) — newest: \(files[0].name)"
    }

    // MARK: - Background notes

    private func startEnriching() {
        enrichTask?.cancel()
        enrichTask = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let pause = await self.enrichBatch()
                try? await Task.sleep(for: .seconds(pause))
            }
        }
    }

    /// Notes a handful of files. Returns how long to wait before the next batch.
    func enrichBatch(size: Int = 8) async -> Double {
        guard intelligence.isReady, phase == .watching else { return 60 }
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical { return 300 }
        guard let pending = try? indexer.pendingEnrichment(limit: size), !pending.isEmpty else { return 60 }

        for file in pending {
            if Task.isCancelled { return 0 }
            guard let excerpt = TextExtractor.excerpt(path: file.path, kind: file.kind) else {
                try? indexer.setEnrichment(id: file.id, summary: nil, tags: [])
                continue
            }
            switch await intelligence.note(name: file.name, project: file.projectName, excerpt: excerpt) {
            case .note(let summary, let tags):
                try? indexer.setEnrichment(id: file.id, summary: summary, tags: tags)
            case .skipped:
                try? indexer.setEnrichment(id: file.id, summary: nil, tags: [])
            case .rateLimited:
                return 120
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        notify()
        return 2
    }

    /// Runs enrichment in the foreground until `limit` files are done (used by the CLI).
    public func enrichNow(limit: Int, progress: (String, String?) -> Void) async -> Int {
        var done = 0
        while done < limit, let pending = try? indexer.pendingEnrichment(limit: min(8, limit - done)), !pending.isEmpty {
            for file in pending {
                let excerpt = TextExtractor.excerpt(path: file.path, kind: file.kind)
                var summary: String?
                var tags: [String] = []
                if let excerpt, case .note(let s, let t) = await intelligence.note(name: file.name, project: file.projectName, excerpt: excerpt) {
                    summary = s
                    tags = t
                }
                try? indexer.setEnrichment(id: file.id, summary: summary, tags: tags)
                progress(file.name, summary.map { "\($0)  [\(tags.joined(separator: ", "))]" })
                done += 1
            }
        }
        return done
    }

    // MARK: - Widget

    private func writeSnapshot(force: Bool = false) {
        guard let snapshotURL, force || Date().timeIntervalSince(lastSnapshot) > 60 else { return }
        lastSnapshot = Date()
        guard let snapshot = makeSnapshot() else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try? FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
    }

    public func makeSnapshot() -> WidgetSnapshot? {
        guard let projects = try? search.recentProjects(limit: 6, filesEach: 1),
              let recent = try? search.recentFiles(limit: 8) else { return nil }
        func item(_ file: FileRecord) -> WidgetSnapshot.Item {
            WidgetSnapshot.Item(name: file.name, path: file.path, project: file.projectName,
                                modified: file.modified, symbol: file.kind.symbol)
        }
        return WidgetSnapshot(
            generated: Date(),
            projects: projects.map { WidgetSnapshot.Project(name: $0.name, lastActive: $0.lastActive, latest: $0.latest.first.map(item)) },
            recent: recent.map(item),
            fileCount: stats().files
        )
    }

    // MARK: - Stats

    public func stats() -> IndexStats {
        let count = { (sql: String) in (try? self.db.scalarInt(sql)) ?? 0 }
        let bytes = ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let size = (try? FileManager.default.attributesOfItem(atPath: db.path + suffix)[.size] as? Int) ?? 0
            return total + size
        }
        return IndexStats(
            files: count("SELECT count(*) FROM files WHERE deleted_at IS NULL"),
            projects: count("SELECT count(*) FROM projects"),
            enriched: count("SELECT count(*) FROM files WHERE summary IS NOT NULL"),
            chains: count("SELECT count(DISTINCT chain_id) FROM files WHERE chain_id IS NOT NULL"),
            databaseBytes: bytes
        )
    }
}
