import Foundation
import TrailCore

let usage = """
    trail — a knowledge graph of the files on your Mac

    USAGE
      trail ask "<question>"     Ask in plain words (uses the on-device model when available)
      trail find "<words>"       Instant search, no model
      trail recent [n]           Files you changed most recently
      trail projects             Projects with recent activity
      trail related <path>       Versions, same-session files, shared topics
      trail scan [days]          Scan the home folder (first run, default 365 days)
      trail watch                Keep the graph up to date in the foreground (Ctrl-C to stop)
      trail enrich [n]           Write notes for n files with the on-device model (default 25)
      trail stats                Index size and model status
      trail compact              Fold bulky generated folders into single entries, reclaim space
      trail inbox                New files on the Desktop and in Downloads, and where each belongs

    Data lives in ~/Library/Application Support/Trail (override with TRAIL_HOME).
    """

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(0)
}
let rest = arguments.dropFirst().joined(separator: " ")

let engine: TrailEngine
do {
    engine = try TrailEngine.open()
    engine.prepareSearchIndex()
} catch {
    FileHandle.standardError.write("trail: \(error)\n".data(using: .utf8)!)
    exit(1)
}

let dim = "\u{1B}[2m", bold = "\u{1B}[1m", cyan = "\u{1B}[36m", reset = "\u{1B}[0m"

func printFile(_ file: FileRecord, versions: Int = 1, indent: String = "  ") {
    var meta = [RelativeTime.describe(file.modified)]
    if let project = file.projectName { meta.append(project) }
    if versions > 1 { meta.append("\(versions) versions") }
    if let label = file.origin.label { meta.append(label + (file.sourceHost.map { " · \($0)" } ?? "")) }
    print("\(indent)\(bold)\(file.name)\(reset)  \(dim)\(meta.joined(separator: " · "))\(reset)")
    print("\(indent)\(dim)\(file.displayPath)\(reset)")
    if let summary = file.summary { print("\(indent)\(cyan)\(summary)\(reset)") }
}

func printResponse(_ response: SearchResponse, elapsed: TimeInterval) {
    let plan = response.plan
    var description = ["keywords: \(plan.keywords.joined(separator: ", "))"]
    if !plan.kinds.isEmpty { description.append("kind: \(plan.kinds.map(\.rawValue).joined(separator: ", "))") }
    if plan.timeframe != .any { description.append("time: \(plan.timeframe.rawValue)") }
    if let days = plan.days { description.append(days.lowerBound == days.upperBound ? "\(days.lowerBound) days ago" : "\(days.lowerBound)–\(days.upperBound) days ago") }
    if let size = plan.size { description.append(size > 0 ? "big first" : "small first") }
    if let origin = plan.origin { description.append("origin: \(origin.rawValue)") }
    if plan.newestFirst { description.append("newest first") }
    print("\(dim)\(description.joined(separator: " · "))\(response.refinedByModel ? " · read by model" : "")\(response.pickedByModel ? " · chosen by model" : "") · \(Int(elapsed * 1000)) ms\(reset)\n")
    if let corrected = response.correctedText { print("\(dim)Showing results for\(reset) \(corrected)\n") }
    if let answer = response.answer { print("\(cyan)→ \(answer)\(reset)\n") }
    for project in response.projects {
        print("\(bold)▸ \(project.name)\(reset) \(dim)project · \(project.fileCount) files · active \(RelativeTime.describe(project.lastActive))\(reset)")
    }
    if !response.projects.isEmpty { print() }
    if response.hits.isEmpty { print("  Nothing found.") }
    for hit in response.hits.prefix(10) {
        printFile(hit.file, versions: hit.versionCount)
        print()
    }
}

func run() async {
    switch command {
    case "ask":
        let start = Date()
        let response = await engine.ask(rest)
        printResponse(response, elapsed: Date().timeIntervalSince(start))

    case "find", "search":
        let start = Date()
        let response = engine.quickSearch(rest)
        printResponse(response, elapsed: Date().timeIntervalSince(start))

    case "recent":
        let limit = Int(rest) ?? 15
        for file in (try? engine.search.recentFiles(limit: limit)) ?? [] {
            printFile(file)
            print()
        }

    case "projects":
        for project in (try? engine.search.recentProjects(limit: 15, filesEach: 2)) ?? [] {
            print("\(bold)▸ \(project.name)\(reset) \(dim)\(project.kind) · active \(RelativeTime.describe(project.lastActive))\(reset)")
            for file in project.latest {
                print("    \(file.name) \(dim)\(RelativeTime.describe(file.modified))\(reset)")
            }
        }

    case "related":
        let path = (rest as NSString).expandingTildeInPath
        let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        guard let file = try? engine.search.file(path: (absolute as NSString).standardizingPath) else {
            print("Not in the graph: \(absolute)")
            exit(1)
        }
        printFile(file)
        guard let related = try? engine.search.related(to: file) else { return }
        for (title, files) in [("Versions", related.versions), ("Worked on alongside", related.sameSession),
                               ("Shares topics", related.sameTopics), ("Same project", related.sameProject)] where !files.isEmpty {
            print("\n\(bold)\(title)\(reset)")
            for other in files { print("  \(other.name) \(dim)\(RelativeTime.describe(other.modified)) · \(other.displayPath)\(reset)") }
        }

    case "scan":
        let days = Int(rest) ?? engine.config.backfillDays
        let start = Date()
        let eventID = Watcher.currentEventID
        print("Scanning files changed in the last \(days) days…")
        let count = (try? engine.indexer.backfill(days: days) { count, path in
            print("\r\u{1B}[K\(count) files · \(dim)\((path as NSString).lastPathComponent.prefix(60))\(reset)", terminator: "")
            fflush(stdout)
        }) ?? 0
        try? engine.indexer.prune()
        engine.markFirstScanComplete(eventID: eventID)
        print("\nIndexed \(count) files in \(String(format: "%.1f", Date().timeIntervalSince(start))) s.")
        let readStart = Date()
        let read = engine.readAllDocuments { total in
            print("\r\u{1B}[KReading documents · \(total)", terminator: "")
            fflush(stdout)
        }
        print("\r\u{1B}[KRead \(read) documents in \(String(format: "%.1f", Date().timeIntervalSince(readStart))) s.")

    case "watch":
        print("Watching \(engine.config.roots.joined(separator: ", ")) — Ctrl-C to stop.")
        engine.onChange = { @MainActor in
            if let file = try? engine.search.recentFiles(limit: 1).first {
                print("\(dim)\(Date().formatted(date: .omitted, time: .standard))\(reset) \(file.name) \(dim)\(file.displayPath)\(reset)")
            }
        }
        engine.start()
        while true { try? await Task.sleep(for: .seconds(3600)) }

    case "enrich":
        guard engine.intelligence.isReady else {
            print("On-device model unavailable: \(engine.intelligence.status)")
            exit(1)
        }
        let limit = Int(rest) ?? 25
        let start = Date()
        let done = await engine.enrichNow(limit: limit) { name, note in
            print("\(bold)\(name)\(reset)\n  \(dim)\(note ?? "(no readable text)")\(reset)")
        }
        print("\nNoted \(done) files in \(String(format: "%.1f", Date().timeIntervalSince(start))) s.")

    case "compact":
        let before = engine.stats()
        do { try engine.compact() } catch { print("compact failed: \(error)"); exit(1) }
        let after = engine.stats()
        let format = { (bytes: Int) in ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        print("\(before.files) → \(after.files) entries · \(format(before.databaseBytes)) → \(format(after.databaseBytes))")

    case "inbox":
        let items = (try? await engine.refreshInboxNow()) ?? []
        if items.isEmpty { print("Nothing new on the Desktop or in Downloads.") }
        for item in items {
            print("\(bold)\(item.file.name)\(reset)  \(dim)\(item.file.displayPath) · arrived \(RelativeTime.describe(item.arrived))\(reset)")
            if let gist = item.gist { print("  \(dim)\(gist.prefix(100))\(reset)") }
            if let best = item.suggestion {
                print("  \(cyan)→ \(best.displayPath)\(reset)  \(dim)\(best.reason)\(best.byModel ? " · chosen by model" : "")\(reset)")
                for other in item.destinations.dropFirst() { print("    \(dim)or \(other.displayPath)\(reset)") }
            } else {
                print("  \(dim)No obvious home yet\(reset)")
            }
            print()
        }

    case "stats":
        let stats = engine.stats()
        print("""
            Files        \(stats.files)
            Projects     \(stats.projects)
            With notes   \(stats.enriched)
            Version sets \(stats.chains)
            Database     \(ByteCountFormatter.string(fromByteCount: Int64(stats.databaseBytes), countStyle: .file))
            Model        \(engine.intelligence.status == .ready ? "ready (Apple on-device)" : "\(engine.intelligence.status)")
            """)

    default:
        print(usage)
    }
}

await run()
