import AppKit
import CoreText
import Foundation
import Testing
@testable import TrailCore

/// A benchmark for search quality: a messy, made-up home folder and the questions people
/// actually type, each with the file they meant. Prints a report and fails if quality drops.
///
///     swift test --filter SearchQuality
@Suite(.serialized) struct SearchQualityTests {
    struct Case: Sendable {
        let query: String
        let expected: @Sendable (FileRecord) -> Bool
        let label: String

        init(_ query: String, _ name: String) {
            self.query = query
            label = name
            expected = { $0.name == name }
        }

        init(_ query: String, label: String, _ expected: @escaping @Sendable (FileRecord) -> Bool) {
            self.query = query
            self.label = label
            self.expected = expected
        }
    }

    static let cases: [Case] = [
        // Names
        Case("pitch deck", "Pitch v3.key"),
        Case("latest thermal pitch", "Pitch v3.key"),
        Case("thermal pitch", "Pitch v3.key"),
        Case("thermal deck", "Pitch v3.key"),
        Case("pitch v2", "Pitch v2.key"),
        Case("investor memo", "Investor memo.docx"),
        Case("memo", "Investor memo.docx"),
        Case("w2", "W-2.pdf"),
        Case("w-2", "W-2.pdf"),
        Case("1099", "1099-INT.pdf"),
        Case("invoice", "invoice-1042.pdf"),
        Case("resume", "Resume 2026.pdf"),
        Case("cover letter stripe", "cover letter - Stripe.docx"),
        Case("virtual memory lecture", "lecture-07-virtual-memory.pdf"),
        Case("lisbon itinerary", "itinerary.md"),
        Case("hotel lisbon", "Hotel booking.pdf"),
        Case("where did I put the hotel booking for lisbon", "Hotel booking.pdf"),
        Case("syllabus", "CS161_Syllabus_Fall2026.pdf"),
        Case("cs161 pset", "pset3.pdf"),
        Case("cs 161 syllabus", "CS161_Syllabus_Fall2026.pdf"),
        Case("budget", "Budget 2026.numbers"),
        Case("notes from the acme call", "Notes from Acme call.md"),
        Case("tax deductions", "Deductions checklist.md"),
        Case("taxes", label: "a file in Taxes 2026") { $0.projectName == "Taxes 2026" },
        Case("final paper draft", "Final paper draft.docx"),
        Case("readme thermal web", label: "thermal-web/README.md") { $0.name == "README.md" && $0.path.contains("thermal-web") },
        Case("button", "Button.tsx"),
        Case("datasheet", "Thermal datasheet.pdf"),
        Case("lisbon photos", label: "a Lisbon photo") { $0.kind == .image && $0.path.contains("Pictures/Lisbon") },

        // Apps: "blender" means your Blender scenes, not every 3D file
        Case("blender", "ship.blend"),
        Case("latest blender file", "ship.blend"),
        Case("blender hero", "hero-scene.blend"),
        Case("keynote", "Pitch v3.key"),
        Case("figma", "Brand board.fig"),
        Case("3d models", label: "a 3D file") { $0.kind == .model3d },

        // Talking, not keywords
        Case("that big file I downloaded about the lease a few weeks ago", "Scan 2026-09-02.pdf"),
        Case("the pdf I downloaded from the bank", "statement-2026-09.pdf"),

        // Still typing
        Case("invoic", "invoice-1042.pdf"),
        Case("itiner", "itinerary.md"),
        Case("deduct", "Deductions checklist.md"),

        // Typos
        Case("thermla pitch", "Pitch v3.key"),
        Case("lisbn hotel", "Hotel booking.pdf"),
        Case("syllabis", "CS161_Syllabus_Fall2026.pdf"),

        // What's inside
        Case("lease", "Scan 2026-09-02.pdf"),
        Case("lease agreement", "Scan 2026-09-02.pdf"),
        Case("boarding pass", "document (3).pdf"),
        Case("invoice figma", "invoice-1042.pdf"),
        Case("page tables", "notes.md"),
        Case("acme pricing", "Notes from Acme call.md"),
        Case("pdfs I downloaded about the lease", "Scan 2026-09-02.pdf"),
        Case("essay on climate", "Final paper.docx"),
        Case("climate paper", "Final paper.docx"),
        Case("bank statement", "statement-2026-09.pdf"),
        Case("battery life sensor", "Thermal datasheet.pdf"),
        Case("operating systems", "CS161_Syllabus_Fall2026.pdf"),
        Case("alfama", label: "a Lisbon trip file") { $0.path.contains("Lisbon trip") },
    ]

    @Test func benchmark() async throws {
        let box = try QualityHome()
        let search = box.engine.search
        var ranks: [(Case, Int?, String)] = []
        let clock = ContinuousClock()
        var slowest = Duration.zero
        for item in Self.cases {
            var response: SearchResponse!
            let elapsed = try clock.measure { response = try search.search(QueryParser.parse(item.query), limit: 10) }
            slowest = max(slowest, elapsed)
            let rank = response.hits.firstIndex { item.expected($0.file) }.map { $0 + 1 }
            ranks.append((item, rank, response.hits.first?.file.name ?? "—"))
        }

        let top1 = ranks.filter { $0.1 == 1 }.count
        let top3 = ranks.filter { ($0.1 ?? 99) <= 3 }.count
        let mrr = ranks.map { $0.1.map { 1.0 / Double($0) } ?? 0 }.reduce(0, +) / Double(ranks.count)
        var report = "\nSearch quality: \(ranks.count) questions\n"
        for (item, rank, top) in ranks {
            let mark = rank == 1 ? "✓" : rank.map { "\($0)" } ?? "✗"
            let detail = rank == 1 ? "" : "   wanted \(item.label), got \(top)"
            report += "  \(mark.padding(toLength: 2, withPad: " ", startingAt: 0)) \(item.query)\(detail)\n"
        }
        report += String(format: "top-1 %d/%d · top-3 %d/%d · MRR %.2f · slowest %@\n",
                         top1, ranks.count, top3, ranks.count, mrr, slowest.formatted(.units(allowed: [.milliseconds])))
        print(report)

        #expect(Double(top1) / Double(ranks.count) >= Self.minimumTop1, "top-1 dropped: \(top1)/\(ranks.count)")
        #expect(Double(top3) / Double(ranks.count) >= Self.minimumTop3, "top-3 dropped: \(top3)/\(ranks.count)")
    }

    static let minimumTop1 = 0.9
    static let minimumTop3 = 0.95
}

/// The made-up home folder behind the benchmark. Busy on purpose: a code project full of
/// recently edited files whose names overlap the questions, a cluttered Downloads folder,
/// and documents whose names say nothing about what's in them.
final class QualityHome {
    let root: URL
    let home: String
    let engine: TrailEngine
    let indexer: Indexer
    private let now = Date()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("trail-quality-\(UUID().uuidString)")
        home = root.appendingPathComponent("home").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let db = try Database(path: root.appendingPathComponent("trail.sqlite").path)
        try Schema.migrate(db)
        var config = TrailConfig.default
        config.roots = [home]
        engine = TrailEngine(db: db, config: config, configURL: root.appendingPathComponent("config.json"), home: home)
        indexer = engine.indexer
        try build()
        try indexer.backfill(days: 365)
        try indexer.collapseLargeTrees()
        while try indexer.readPending(limit: 200) > 0 {}
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private let minute = 60.0, hour = 3_600.0, day = 86_400.0

    private func build() throws {
        // Thermal: a startup pitch with versions.
        bytes("Documents/Thermal/Pitch v1.key", ago: 6 * day)
        bytes("Documents/Thermal/Pitch v2.key", ago: 1 * day + 3 * hour)
        bytes("Documents/Thermal/Pitch v3.key", ago: 14 * minute)
        docx("Documents/Thermal/Investor memo.docx", "Thermal makes low-cost heat-mapping sensors for commercial buildings. We are raising a seed round.", ago: 2 * hour)
        bytes("Documents/Thermal/Market sizing.xlsx", ago: 3 * hour)
        text("Documents/Thermal/Notes from Acme call.md", "# Acme call\n- Pilot in two office towers\n- Pricing: per-sensor lease\n- Send the datasheet", ago: 40 * minute)
        pdf("Documents/Thermal/Thermal datasheet.pdf", "Thermal T1 sensor. Battery life: five years. Range: 30 meters. Mounts on any ceiling.", ago: 5 * day)

        // thermal-web: a busy code project edited minutes ago, with names that overlap the questions.
        text("Developer/thermal-web/.git/HEAD", "ref: refs/heads/main", ago: hour)
        text("Developer/thermal-web/package.json", "{\"name\": \"thermal-web\"}", ago: hour)
        text("Developer/thermal-web/README.md", "# thermal-web\nMarketing site for Thermal.", ago: 3 * day)
        text("Developer/thermal-web/src/components/PitchDeck.tsx", "export function PitchDeck() {}", ago: 30 * minute)
        text("Developer/thermal-web/src/pages/pitch.tsx", "export default function Pitch() {}", ago: 30 * minute)
        text("Developer/thermal-web/src/lib/memo.ts", "export const memo = 1", ago: 20 * minute)
        text("Developer/thermal-web/src/lib/tax.ts", "export const tax = 0.2", ago: 10 * minute)
        text("Developer/thermal-web/src/lib/budget.ts", "export const budget = 1", ago: 12 * minute)
        text("Developer/thermal-web/tests/invoice.test.ts", "test('invoice', () => {})", ago: hour)
        text("Developer/thermal-web/src/components/Button.tsx", "export function Button() {}", ago: 2 * day)
        for (index, name) in ["Hero", "Nav", "Footer", "Card", "Modal", "Pricing", "Sensor", "Hotel", "Lease", "Resume",
                              "Grid", "Stack", "Badge", "Toast", "Avatar", "Menu", "Tabs", "Table", "Chart", "Form"].enumerated() {
            text("Developer/thermal-web/src/components/\(name).tsx", "export function \(name)() {}", ago: Double(index) * 7 * minute + 5 * minute)
        }

        // Taxes
        pdf("Documents/Taxes 2026/W-2.pdf", "Form W-2 Wage and Tax Statement. Employer: Northwind Studio. Wages 84,200.", ago: 12 * day)
        pdf("Documents/Taxes 2026/1099-INT.pdf", "Form 1099-INT Interest Income. Payer: Harbor Savings Bank.", ago: 9 * day)
        text("Documents/Taxes 2026/Deductions checklist.md", "# Deductions\n- Home office\n- Equipment", ago: 8 * day)

        // Downloads: clutter, and files whose names say nothing.
        pdf("Downloads/Scan 2026-09-02.pdf", "Residential Lease Agreement. 41 Elm Street. Landlord and tenant agree to a monthly rent of 2,400.", ago: 40 * day, from: "https://mail.google.com/")
        pdf("Downloads/invoice-1042.pdf", "Invoice 1042. Figma Professional plan, 12 months.", ago: 20 * day, from: "https://figma.com/billing")
        pdf("Downloads/document (3).pdf", "Boarding pass. TAP Air Portugal. Lisbon (LIS). Gate 14. Seat 22A.", ago: 15 * day, from: "https://flytap.com/")
        pdf("Downloads/CS161_Syllabus_Fall2026.pdf", "CS 161 Operating Systems. Fall 2026 syllabus. Grading and office hours.", ago: 50 * day, from: "https://canvas.example.edu/")
        pdf("Downloads/taxi-receipt.pdf", "Ride receipt. Total 23.10.", ago: 2 * day, from: "https://ride.example.com/")
        pdf("Downloads/file-sample_150kB.pdf", "Lorem ipsum dolor sit amet.", ago: 3 * day, from: "https://example.com/")
        pdf("Downloads/statement-2026-09.pdf", "Harbor Savings Bank. Monthly statement for September.", ago: 25 * day, from: "https://harborsavings.example.com/")
        for index in 0..<12 { bytes("Downloads/Screenshot 2026-10-\(String(format: "%02d", index + 1)) at 10.22.\(10 + index).png", ago: Double(index) * day + hour) }
        bytes("Downloads/unnamed.jpg", ago: day)
        bytes("Downloads/IMG_4021.HEIC", ago: 4 * day)

        // School
        pdf("Documents/School/CS161/pset3.pdf", "Problem set 3: scheduling and locks.", ago: 5 * day)
        pdf("Documents/School/CS161/lecture-07-virtual-memory.pdf", "Lecture 7. Virtual memory and paging.", ago: 7 * day)
        text("Documents/School/CS161/notes.md", "# Paging\nPage tables map virtual pages to frames. The TLB caches entries.", ago: 6 * day)
        docx("Documents/School/Writing/Final paper.docx", "Climate adaptation in coastal cities: sea walls, wetlands and managed retreat.", ago: 30 * day)
        docx("Documents/School/Writing/Final paper draft.docx", "Climate adaptation in coastal cities. Draft.", ago: 40 * day)

        // Desktop
        pdf("Desktop/Resume 2026.pdf", "Experience: cofounder at Thermal. Education: computer science.", ago: 10 * day)
        docx("Desktop/resume_old.docx", "Experience: barista.", ago: 200 * day)
        docx("Desktop/cover letter - Stripe.docx", "Dear Stripe hiring team, I'm applying for the new grad role.", ago: 12 * day)

        // Lisbon
        text("Documents/Lisbon trip/itinerary.md", "Day 1: Alfama and the castle. Day 2: Sintra.", ago: 18 * day)
        pdf("Documents/Lisbon trip/Hotel booking.pdf", "Booking confirmation. Hotel Memmo Alfama. Three nights.", ago: 19 * day)
        for index in 0..<30 { bytes("Pictures/Lisbon/IMG_\(1200 + index).HEIC", ago: 16 * day + Double(index) * 3 * hour) }

        // 3D: Blender scenes, plus newer generic models that shouldn't win "blender"
        bytes("Documents/3D/ship.blend", ago: 2 * day)
        bytes("Documents/3D/ship.blend1", ago: 2 * day)
        bytes("Desktop/hero-scene.blend", ago: 5 * day)
        bytes("Downloads/chair.obj", ago: hour)
        bytes("Downloads/helmet.glb", ago: 3 * hour)
        bytes("Downloads/Blender-4.2-shortcuts.png", ago: 30 * day)
        bytes("Documents/Thermal/Brand board.fig", ago: 2 * day)

        // Money
        bytes("Documents/Finances/Budget 2026.numbers", ago: 4 * day)
        bytes("Documents/Finances/budget-template.xlsx", ago: 300 * day)
    }

    // MARK: - Writers

    func url(_ relative: String) -> URL {
        let url = URL(fileURLWithPath: home).appendingPathComponent(relative)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    /// Sets both dates, so a folder of files written in one go doesn't look like a generated burst.
    private func age(_ relative: String, _ seconds: Double) {
        let date = now.addingTimeInterval(-seconds)
        try? FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url(relative).path)
    }

    func text(_ relative: String, _ body: String, ago: Double) {
        try? body.write(to: url(relative), atomically: true, encoding: .utf8)
        age(relative, ago)
    }

    func bytes(_ relative: String, ago: Double) {
        try? Data((0..<2_048).map { _ in UInt8.random(in: 0...255) }).write(to: url(relative))
        age(relative, ago)
    }

    private func docx(_ relative: String, _ body: String, ago: Double) {
        let string = NSAttributedString(string: body)
        if let data = try? string.data(from: NSRange(location: 0, length: string.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]) {
            try? data.write(to: url(relative))
        }
        age(relative, ago)
    }

    func pdf(_ relative: String, _ body: String, ago: Double, from source: String? = nil) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url(relative) as CFURL, mediaBox: &box, nil) else { return }
        context.beginPDFPage(nil)
        let framesetter = CTFramesetterCreateWithAttributedString(
            NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: box.insetBy(dx: 60, dy: 60), transform: nil), nil)
        CTFrameDraw(frame, context)
        context.endPDFPage()
        context.closePDF()
        if let source { downloaded(relative, from: source) }
        age(relative, ago)
    }

    private func downloaded(_ relative: String, from source: String) {
        let target = url(relative).path
        if let plist = try? PropertyListSerialization.data(fromPropertyList: [source], format: .binary, options: 0) {
            _ = plist.withUnsafeBytes { setxattr(target, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, plist.count, 0, 0) }
        }
        let quarantine = "0083;\(String(Int(now.timeIntervalSince1970), radix: 16));Safari;\(UUID().uuidString)"
        _ = quarantine.withCString { setxattr(target, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    }
}

@Suite struct SearchHelperTests {
    @Test(arguments: [("thermla", "thermal", 1), ("lisbn", "lisbon", 1), ("kitten", "sitting", 3), ("same", "same", 0)])
    func editDistance(a: String, b: String, distance: Int) {
        #expect(SearchEngine.editDistance(a, b, limit: 3) == distance)
    }

    @Test func nameWords() {
        let words = SearchEngine.nameWords("CS161_Syllabus-FallTerm v2 W-2.pdf").map(\.word)
        #expect(Set(words).isSuperset(of: ["cs161", "cs", "161", "syllabus", "fallterm", "fall", "term", "v2", "v", "2", "w", "w2", "pdf"]))
        #expect(SearchEngine.nameWords("Résumé.pdf").map(\.word).contains("résumé"))
    }

    @Test func nameTermsJoinLettersAndDigits() {
        #expect(Indexer.nameTerms("W-2.pdf").contains("w2"))
        #expect(Indexer.nameTerms("1099-INT.pdf").contains("1099int"))
    }

    @Test func typoIsCorrectedAndReported() throws {
        let box = try QualityHome()
        let search = box.engine.search
        #expect(try search.search(QueryParser.parse("thermla pitch")).correctedText == "thermal pitch")
        #expect(try search.search(QueryParser.parse("lisbn hotel")).correctedText == "lisbon hotel")
        // Shown as the word in the results, not the stem in the index ("syllabu").
        #expect(try search.search(QueryParser.parse("syllabis")).correctedText == "syllabus")
        // Real words that only differ from the index by their ending aren't "corrected".
        #expect(try search.search(QueryParser.parse("taxes")).correctedText == nil)
        #expect(try search.search(QueryParser.parse("invoic")).correctedText == nil)
        #expect(try search.search(QueryParser.parse("deductions")).correctedText == nil)
        // Nor is a real word that's simply not in these files.
        #expect(try search.search(QueryParser.parse("blended")).correctedText == nil)
        #expect(EnglishWords.contains("blender") && EnglishWords.contains("Important") && !EnglishWords.contains("thermla"))
    }

    @Test func partialMatchGetsNoAnswerLine() throws {
        let box = try QualityHome()
        // "boarding" stems to "board", but no file has both words: no confident answer.
        let response = try box.engine.search.search(QueryParser.parse("latest board pass zzz"))
        #expect(response.answer == nil)
        #expect(try box.engine.search.search(QueryParser.parse("latest thermal pitch")).answer?.hasPrefix("Pitch v3.key") == true)
    }

    @Test func emptyFiltersLoosen() throws {
        let box = try QualityHome()
        // There's no presentation about the lease, but there is a PDF.
        let response = try box.engine.search.search(QueryParser.parse("lease agreement slides"))
        #expect(response.hits.first?.file.name == "Scan 2026-09-02.pdf")
        #expect(response.plan.kinds == [.presentation])
    }

    @Test func openingAFileLiftsIt() throws {
        let box = try QualityHome()
        let before = try box.engine.search.search(QueryParser.parse("resume"))
        let old = try #require(before.hits.first { $0.file.name == "resume_old.docx" })
        for _ in 0..<6 { box.engine.markOpened(id: old.file.id) }
        let after = try box.engine.search.search(QueryParser.parse("resume"))
        #expect(after.hits.firstIndex { $0.file.id == old.file.id }! < before.hits.firstIndex { $0.file.id == old.file.id }!)
    }
}

/// Search speed on an index the size of a busy Mac: 50,000 entries, 12,000 with document text.
/// Opt in, since building it takes a while:  TRAIL_PERF=1 swift test --filter SearchSpeed
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TRAIL_PERF"] != nil))
struct SearchSpeedTests {
    @Test func largeIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trail-speed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try Database(path: root.appendingPathComponent("trail.sqlite").path)
        try Schema.migrate(db)
        let indexer = Indexer(db: db, rules: ScopeRules(config: .default, home: root.path), home: root.path)

        // Made-up words with a natural (Zipf) frequency curve: a word's frequency falls off as
        // 1/rank, the way it does in real text.
        var generator = SystemRandomNumberGenerator()
        let letters = Array("abcdefghijklmnoprstuvwy")
        let vocabulary = Array(Set((0..<45_000).map { _ in String((0..<Int.random(in: 4...9, using: &generator)).map { _ in letters.randomElement()! }) }))
        let harmonic = (1...vocabulary.count).reduce(0.0) { $0 + 1 / Double($1) }
        func word() -> String {
            // Inverse of the cumulative 1/rank curve, close enough for a benchmark.
            let rank = Int(exp(Double.random(in: 0..<1) * harmonic - 0.5772))
            return vocabulary[min(vocabulary.count - 1, max(0, rank - 1))]
        }
        let kinds: [(FileKind, String)] = [(.code, "ts"), (.code, "swift"), (.pdf, "pdf"), (.document, "docx"), (.text, "md"), (.image, "png"), (.data, "json")]
        let now = Date()
        try db.transaction {
            for id in 1...50_000 {
                let (kind, ext) = kinds[id % kinds.count]
                let name = (0..<Int.random(in: 1...3)).map { _ in word() }.joined(separator: " ") + ".\(ext)"
                let path = "\(root.path)/Documents/\(word())/\(word())/\(id)-\(name)"
                try db.run("INSERT INTO files (id, path, name, ext, kind, modified, first_seen) VALUES (?, ?, ?, ?, ?, ?, ?)",
                           id, path, name, ext, kind.rawValue, now.addingTimeInterval(-Double.random(in: 0...(365 * 86_400))), now)
                try indexer.refreshSearch(id)
                if id % 4 == 0 {
                    try db.run("INSERT INTO body (rowid, text) VALUES (?, ?)", id, (0..<Int.random(in: 300...900)).map { _ in word() }.joined(separator: " "))
                }
            }
        }
        try db.exec("VACUUM")

        let search = SearchEngine(db: db)
        // Ranks: 0 is like "the" (never searched), 30 like "project", 300 like "invoice", 3,000 like
        // "lisbon", 30,000 a word in one or two files.
        let veryCommon = vocabulary[0], common = vocabulary[30], mid = vocabulary[300], rare = vocabulary[3_000], unique = vocabulary[30_000]
        let typo = String(mid.prefix(1)) + String(mid.dropFirst(2).prefix(1)) + String(mid.dropFirst(1).prefix(1)) + String(mid.dropFirst(3))
        let queries = [veryCommon, common, mid, rare, unique, "\(common) \(mid)", "\(mid) \(rare)", "\(common) \(mid) \(rare)",
                       String(common.prefix(1)), String(common.prefix(2)), String(mid.prefix(3)), typo, "latest \(mid) pdf", "\(mid) \(unique)zz"]
        let clock = ContinuousClock()
        var times: [(String, Duration)] = []
        for query in queries {
            _ = try search.search(QueryParser.parse(query))   // warm
            let elapsed = try clock.measure { _ = try search.search(QueryParser.parse(query)) }
            times.append((query, elapsed))
        }
        let size = (try FileManager.default.attributesOfItem(atPath: db.path)[.size] as? Int) ?? 0
        print("\nSearch speed, 50,000 entries, index \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
        for (query, elapsed) in times { print("  \(elapsed.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))  \(query)") }
        #expect(times.allSatisfy { $0.1 < .milliseconds(80) }, "a search got slow")
    }
}
