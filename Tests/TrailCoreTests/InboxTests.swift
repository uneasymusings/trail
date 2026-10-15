import Foundation
import Testing
@testable import TrailCore

/// Sorting new files: Trail suggests where they belong and never moves anything by itself.
@Suite(.serialized) struct InboxTests {
    /// The benchmark home, plus a few fresh arrivals on the Desktop and in Downloads.
    func home() throws -> QualityHome {
        let box = try QualityHome()
        let hour = 3_600.0
        box.pdf("Downloads/1098-T.pdf", "Form 1098-T Tuition Statement. Tax year 2026. Qualified tuition payments 6,410.", ago: 2 * hour,
                from: "https://portal.university.example.edu/1098t.pdf")
        box.pdf("Downloads/acme-pilot-terms.pdf", "Acme pilot terms. Thermal sensors in two office towers. Pricing per sensor.", ago: 3 * hour,
                from: "https://app.docusign.example.com/acme.pdf")
        box.text("Desktop/sintra notes.md", "Sintra day trip from Lisbon: Pena Palace, then Alfama for dinner.", ago: 4 * hour)
        box.text("Desktop/just saved.md", "Lisbon", ago: 60)
        box.bytes("Downloads/Installer.dmg", ago: 2 * hour)
        try box.indexer.backfill(days: 30)
        return box
    }

    @Test func suggestsWhereSimilarFilesLive() async throws {
        let box = try home()
        let items = try await box.engine.refreshInboxNow(useModel: false)
        func best(_ name: String) -> String? { items.first { $0.file.name == name }?.suggestion?.name }
        #expect(best("1098-T.pdf") == "Taxes 2026")
        #expect(best("acme-pilot-terms.pdf") == "Thermal")
        #expect(best("sintra notes.md") == "Lisbon trip")
        // Installers aren't filed away.
        #expect(!items.contains { $0.file.name == "Installer.dmg" })
    }

    @Test func newFilesSettleBeforeTheyCount() async throws {
        let box = try home()
        _ = try await box.engine.refreshInboxNow(useModel: false)
        let ready = try box.engine.inbox.items()
        #expect(ready.contains { $0.file.name == "1098-T.pdf" })
        #expect(!ready.contains { $0.file.name == "just saved.md" })
        #expect(box.engine.inbox.count() == ready.count)
    }

    @Test func sortingMovesTheFileAndKeepsItsHistory() async throws {
        let box = try home()
        let item = try #require(try await box.engine.refreshInboxNow(useModel: false).first { $0.file.name == "1098-T.pdf" })
        let folder = try #require(item.suggestion?.path)
        let moved = try box.engine.sort(item, to: folder)
        box.engine.waitForIndex()

        #expect(FileManager.default.fileExists(atPath: folder + "/1098-T.pdf"))
        #expect(!FileManager.default.fileExists(atPath: item.file.path))
        // Same node in the graph, now in its new place, and no longer waiting.
        #expect(try box.engine.search.file(path: moved)?.id == item.file.id)
        #expect(try box.engine.search.file(path: moved)?.projectName == "Taxes 2026")
        #expect(try !box.engine.inbox.items().contains { $0.id == item.id })

        try box.engine.undoSort(item, from: moved)
        box.engine.waitForIndex()
        #expect(FileManager.default.fileExists(atPath: item.file.path))
        #expect(try box.engine.inbox.items().contains { $0.id == item.id })
    }

    @Test func keepingStopsAsking() async throws {
        let box = try home()
        let item = try #require(try await box.engine.refreshInboxNow(useModel: false).first)
        box.engine.keep(item)
        box.engine.waitForIndex()
        #expect(try !box.engine.inbox.items().contains { $0.id == item.id })
        #expect(FileManager.default.fileExists(atPath: item.file.path))
    }

    @Test func remembersWhereYouPutThings() async throws {
        let box = try home()
        // You file a download from this site somewhere unexpected...
        let first = try #require(try await box.engine.refreshInboxNow(useModel: false).first { $0.file.name == "acme-pilot-terms.pdf" })
        let school = box.home + "/Documents/School/CS161"
        try box.engine.sort(first, to: school)
        box.engine.waitForIndex()

        // ...so the next one from the same site, with nothing else to go on, goes there too.
        box.pdf("Downloads/doc-48213.pdf", "Signed.", ago: 3_000, from: "https://app.docusign.example.com/next.pdf")
        try box.indexer.apply(paths: [box.home + "/Downloads/doc-48213.pdf"])
        let next = try #require(try await box.engine.refreshInboxNow(useModel: false).first { $0.file.name == "doc-48213.pdf" })
        #expect(next.suggestion?.path == school)
        #expect(next.suggestion?.reason.contains("docusign") == true)
    }

    @Test func filingItYourselfCountsToo() async throws {
        let box = try home()
        let item = try #require(try await box.engine.refreshInboxNow(useModel: false).first { $0.file.name == "sintra notes.md" })
        let destination = box.home + "/Documents/Lisbon trip/sintra notes.md"
        try FileManager.default.moveItem(atPath: item.file.path, toPath: destination)
        try box.indexer.apply(paths: [item.file.path, destination])
        _ = try await box.engine.refreshInboxNow(useModel: false)
        let status = try box.engine.db.query("SELECT status, destination FROM inbox WHERE file_id = ?", item.id).first
        #expect(status?.string("status") == "moved")
        #expect(status?.string("destination") == box.home + "/Documents/Lisbon trip")
    }
}

@Suite struct MapTests {
    @Test func mapLinksProjectsFilesAndTopics() throws {
        let box = try QualityHome()
        // Two projects whose files share a topic, as the model's notes would say.
        for name in ["Pitch v3.key", "Notes from Acme call.md", "itinerary.md"] {
            let file = try #require(try box.engine.search.search(QueryParser.parse(name)).hits.first?.file)
            try box.indexer.setEnrichment(id: file.id, summary: nil, tags: ["travel"])
        }
        let map = try box.engine.search.map(home: box.home)
        let names = Set(map.nodes.filter { $0.kind == .project }.map(\.name))
        #expect(names.isSuperset(of: ["Thermal", "Lisbon trip", "Taxes 2026"]))
        #expect(map.nodes.contains { $0.kind == .file && $0.name == "Pitch v3.key" })
        let travel = try #require(map.nodes.first { $0.kind == .topic && $0.name == "travel" })
        #expect(map.edges.filter { $0.to == travel.id }.count == 2)

        let positions = MapLayout.positions(for: map)
        #expect(positions.count == map.nodes.count)
        #expect(positions.values.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        // Deterministic: the same graph lays out the same way.
        #expect(MapLayout.positions(for: map) == positions)
    }
}
