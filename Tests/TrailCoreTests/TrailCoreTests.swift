import Foundation
import Testing
@testable import TrailCore

@Suite struct VersionNamerTests {
    @Test(arguments: [
        ("Pitch v2.key", "pitch", true),
        ("Pitch (1).key", "pitch", true),
        ("pitch_final.key", "pitch", true),
        ("Pitch copy 2.key", "pitch", true),
        ("Budget 2026-10-14.xlsx", "budget", true),
        ("Essay draft.docx", "essay", true),
        ("Pitch.key", "pitch", false),
    ])
    func stems(name: String, stem: String, marker: Bool) {
        #expect(VersionNamer.stem(for: name) == .init(stem: stem, hasMarker: marker))
    }

    @Test func keepsWordsThatOnlyEndLikeMarkers() {
        #expect(VersionNamer.stem(for: "semifinal.pdf")?.stem == "semifinal")
        #expect(VersionNamer.stem(for: "photocopy.pdf")?.stem == "photocopy")
        #expect(VersionNamer.stem(for: "dev2.pdf")?.stem == "dev2")
    }

    @Test func ignoresGenericNames() {
        #expect(VersionNamer.stem(for: "Screenshot 2026-10-14 at 10.22.11.png") == nil)
        #expect(VersionNamer.stem(for: "Untitled 3.txt") == nil)
        #expect(VersionNamer.stem(for: "README.md") == nil)
    }
}

@Suite struct QueryParserTests {
    @Test func latestForProject() {
        let plan = QueryParser.parse("What's the latest file I worked on for the thermal pitch?")
        #expect(plan.keywords == ["thermal", "pitch"])
        #expect(plan.newestFirst)
        #expect(plan.timeframe == .any)
    }

    @Test func kindTimeAndOrigin() {
        let plan = QueryParser.parse("pdfs I downloaded last week about taxes")
        #expect(plan.keywords == ["taxes"])
        #expect(plan.kinds == [.pdf])
        #expect(plan.timeframe == .lastWeek)
        #expect(plan.origin == .download)
    }

    @Test func activityQuestion() {
        let plan = QueryParser.parse("what was I working on yesterday")
        #expect(plan.isActivityQuestion)
        #expect(plan.timeframe == .yesterday)
    }

    @Test func screenshotIsKindAndKeyword() {
        let plan = QueryParser.parse("screenshot of the invoice")
        #expect(plan.kinds == [.image])
        #expect(plan.keywords == ["screenshot", "invoice"])
    }
}

@Suite struct ScopeRulesTests {
    let rules = ScopeRules(config: .default, home: "/Users/test")

    @Test func indexesUserFiles() {
        #expect(rules.shouldIndex("/Users/test/Documents/Taxes/w2.pdf"))
        #expect(rules.shouldIndex("/Users/test/Library/Mobile Documents/com~apple~CloudDocs/notes.md"))
        #expect(rules.shouldIndex("/Users/test/Library/CloudStorage/Dropbox/brief.docx"))
    }

    @Test func skipsNoise() {
        #expect(!rules.shouldIndex("/Users/test/Library/Caches/thing.db"))
        #expect(!rules.shouldIndex("/Users/test/code/app/node_modules/x/index.js"))
        #expect(!rules.shouldIndex("/Users/test/code/app/.git/HEAD"))
        #expect(!rules.shouldIndex("/Users/test/Documents/.DS_Store"))
        #expect(!rules.shouldIndex("/Users/test/Downloads/movie.mp4.crdownload"))
        #expect(!rules.shouldIndex("/Users/test/Documents/~$report.docx"))
        #expect(!rules.shouldIndex("/Users/test/Applications/Thing.app/Contents/Info.plist"))
        #expect(!rules.shouldIndex("/Volumes/USB/file.pdf"))
    }

    @Test func descendsOnlyIntoUsefulLibraryFolders() {
        #expect(rules.shouldDescend(into: "/Users/test/Library"))
        #expect(rules.shouldDescend(into: "/Users/test/Library/Mobile Documents"))
        #expect(!rules.shouldDescend(into: "/Users/test/Library/Mail"))
        #expect(!rules.shouldDescend(into: "/Users/test/Library/Mobile Documents/com~apple~Notes"))
    }
}

@Suite struct IndexerTests {
    /// A throwaway home folder with a database beside it.
    final class Sandbox {
        let root: URL
        let home: String
        let engine: TrailEngine

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("trail-tests-\(UUID().uuidString)")
            home = root.appendingPathComponent("home").path
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            let db = try Database(path: root.appendingPathComponent("trail.sqlite").path)
            try Schema.migrate(db)
            var config = TrailConfig.default
            config.roots = [home]
            engine = TrailEngine(db: db, config: config, configURL: root.appendingPathComponent("config.json"))
            engine.indexer.updateRules(ScopeRules(config: config, home: home))
        }

        @discardableResult
        func write(_ relative: String, _ contents: String = "hello", modified: Date = Date()) throws -> String {
            let path = home + "/" + relative
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try contents.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
            return path
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    // Project detection walks up to the real home folder, so the sandbox uses its own resolver home.
    func makeIndexer(_ sandbox: Sandbox) -> Indexer {
        Indexer(db: sandbox.engine.db, rules: ScopeRules(config: sandbox.engine.config, home: sandbox.home), home: sandbox.home)
    }

    @Test func migrationAddsStemmingToAnOldIndex() throws {
        let box = try Sandbox()
        try box.write("Documents/Money/tax-summary.md", "totals")
        let indexer = makeIndexer(box)
        try indexer.backfill(days: 30)
        let search = box.engine.search
        #expect(try search.search(QueryParser.parse("taxes")).hits.first?.file.name == "tax-summary.md")

        // Recreate a v1 index, which had no stemming.
        let db = box.engine.db
        try db.exec("""
            DROP TABLE search;
            CREATE VIRTUAL TABLE search USING fts5(name, terms, summary, tags, project, tokenize = "unicode61 remove_diacritics 2");
            PRAGMA user_version = 1;
            """)
        for row in try db.query("SELECT id FROM files") { try indexer.refreshSearch(row.int("id")!) }
        #expect(try search.search(QueryParser.parse("taxes")).hits.isEmpty)

        try Schema.migrate(db)
        try indexer.rebuildSearchIfNeeded()
        #expect(try db.scalarInt("PRAGMA user_version") == Schema.version)
        #expect(try search.search(QueryParser.parse("taxes")).hits.first?.file.name == "tax-summary.md")
    }

    @Test func scanLinksVersionsAndProjects() throws {
        let box = try Sandbox()
        try box.write("Documents/Thermal/Pitch v1.md", "first", modified: Date().addingTimeInterval(-86_400 * 3))
        try box.write("Documents/Thermal/Pitch v2.md", "second", modified: Date().addingTimeInterval(-3_600))
        try box.write("Documents/Thermal/budget.csv", "a,b")
        try box.write("Developer/app/.git/HEAD", "ref")
        try box.write("Developer/app/src/main.swift", "print()")
        try box.write("Downloads/random.pdf", "%PDF")

        let indexer = makeIndexer(box)
        let count = try indexer.backfill(days: 30)
        #expect(count == 5)

        let search = box.engine.search
        let response = try search.search(QueryParser.parse("latest thermal pitch"))
        #expect(response.hits.first?.file.name == "Pitch v2.md")
        #expect(response.hits.first?.versionCount == 2)
        #expect(response.hits.first?.file.projectName == "Thermal")
        #expect(response.projects.first?.name == "Thermal")

        let code = try search.search(QueryParser.parse("main"))
        #expect(code.hits.first?.file.projectName == "app")

        let loose = try search.search(QueryParser.parse("random"))
        #expect(loose.hits.first?.file.projectName == nil)
    }

    @Test func renameKeepsIdentityAndDeleteHides() throws {
        let box = try Sandbox()
        let old = try box.write("Documents/Notes/idea.md", "an idea")
        let indexer = makeIndexer(box)
        try indexer.apply(paths: [old])
        let id = try #require(try box.engine.search.file(path: old)?.id)

        let new = box.home + "/Documents/Notes/big idea.md"
        try FileManager.default.moveItem(atPath: old, toPath: new)
        try indexer.apply(paths: [old, new])
        #expect(try box.engine.search.file(path: new)?.id == id)

        try FileManager.default.removeItem(atPath: new)
        try indexer.apply(paths: [new])
        #expect(try box.engine.search.search(QueryParser.parse("idea")).hits.isEmpty)
    }

    @Test func movedInFolderIsWalked() throws {
        let box = try Sandbox()
        let outside = box.root.appendingPathComponent("elsewhere/Client Work")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "brief".write(to: outside.appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
        let destination = box.home + "/Documents/Client Work"
        try FileManager.default.createDirectory(atPath: box.home + "/Documents", withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: outside.path, toPath: destination)

        let indexer = makeIndexer(box)
        try indexer.apply(paths: [destination], rescan: [destination])
        #expect(try box.engine.search.file(path: destination + "/brief.md")?.projectName == "Client Work")
    }

    @Test func notesBecomeSearchable() throws {
        let box = try Sandbox()
        let path = try box.write("Documents/misc/scan.txt", "w2 wages")
        let indexer = makeIndexer(box)
        try indexer.apply(paths: [path])
        let id = try #require(try box.engine.search.file(path: path)?.id)
        try indexer.setEnrichment(id: id, summary: "A W-2 tax form for 2025", tags: ["taxes", "irs"])

        let hit = try box.engine.search.search(QueryParser.parse("irs")).hits.first
        #expect(hit?.file.id == id)
        #expect(hit?.file.tags.sorted() == ["irs", "taxes"])
    }
}

@Suite struct CollectionTests {
    @Test func generatedFolderBecomesOneEntry() throws {
        let box = try IndexerTests.Sandbox()
        for index in 0..<40 { try box.write("Developer/app/out-renders/frame-\(index).png", "x") }
        try box.write("Developer/app/.git/HEAD", "ref")
        try box.write("Developer/app/notes.md", "hand written")
        let indexer = Indexer(db: box.engine.db, rules: ScopeRules(config: box.engine.config, home: box.home), home: box.home)
        try indexer.backfill(days: 30)

        let stats = box.engine.stats()
        // 1 collection + its 3 newest frames + notes.md
        #expect(stats.files == 5)
        let hit = try box.engine.search.search(QueryParser.parse("renders")).hits.first
        #expect(hit?.file.kind == .collection)
        #expect(hit?.file.summary == "40 files · mostly PNG images")
    }

    @Test func downloadsIsNeverCollapsed() throws {
        let box = try IndexerTests.Sandbox()
        for index in 0..<25 { try box.write("Downloads/receipt-\(index).pdf", "%PDF") }
        let indexer = Indexer(db: box.engine.db, rules: ScopeRules(config: box.engine.config, home: box.home), home: box.home)
        try indexer.backfill(days: 30)
        #expect(box.engine.stats().files == 25)
    }
}

@Suite struct LargeTreeTests {
    @Test func bulkyTreeCollapsesButProjectRootSurvives() throws {
        let box = try IndexerTests.Sandbox()
        try box.write("Developer/app/.git/HEAD", "ref")
        try box.write("Developer/app/src/main.swift", "print()")
        try box.write("Developer/app/docs/design-notes.md", "hand written")
        // 30 small run folders of screenshots: no single folder is a burst of 20+.
        for run in 0..<30 {
            for frame in 0..<10 { try box.write("Developer/app/docs/verification/run-\(run)/shot-\(frame).png", "x") }
        }
        let indexer = Indexer(db: box.engine.db, rules: ScopeRules(config: box.engine.config, home: box.home), home: box.home)
        try indexer.scan(root: box.home, cutoff: nil, recordEvents: false)
        try indexer.collapseLargeTrees(minimum: 200)

        let hit = try box.engine.search.search(QueryParser.parse("verification")).hits.first { $0.file.kind == .collection }
        #expect(hit?.file.size == 300)
        // main.swift + design-notes.md + collection + its 3 newest screenshots
        #expect(box.engine.stats().files == 6)
        #expect(hit?.file.name == "verification")

        // New files inside the tree don't come back as individual entries.
        let new = try box.write("Developer/app/docs/verification/run-99/shot-0.png", "x")
        try indexer.apply(paths: [new])
        #expect(box.engine.stats().files == 6)
    }
}
