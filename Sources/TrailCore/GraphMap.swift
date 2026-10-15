import Foundation

/// The knowledge graph at a glance: your active projects and their newest files, the topics
/// they share, the sites downloads came from, and which projects you work on together. Built
/// from the same tables search uses, so it's always current.
public struct GraphMap: Sendable {
    public enum NodeKind: String, Sendable { case project, file, topic, source }
    public enum EdgeKind: String, Sendable { case contains, together, topic, source }

    public struct Node: Identifiable, Sendable, Hashable {
        public var id: String
        public var kind: NodeKind
        public var name: String
        /// Files in a project; files on a topic or from a source.
        public var weight: Int
        public var lastActive: Date?
        /// The project folder or file, for opening it.
        public var path: String?
        public var isCode = false
    }

    public struct Edge: Sendable, Hashable {
        public var from: String
        public var to: String
        public var kind: EdgeKind
        /// How strong the link is: shared work sessions, files on the topic, or downloads.
        public var weight: Int
    }

    public var nodes: [Node]
    public var edges: [Edge]

    public init(nodes: [Node], edges: [Edge]) {
        self.nodes = nodes
        self.edges = edges
    }
}

extension SearchEngine {
    /// The map of the most recently active projects and what connects them. Loose files on the
    /// Desktop and in Downloads appear as two hubs of their own.
    public func map(projects limit: Int = 36, filesEach: Int = 4, home: String = TrailPaths.home, now: Date = Date()) throws -> GraphMap {
        let since = now.addingTimeInterval(-180 * 86_400)
        let projectRows = try db.query("""
            SELECT p.id, p.name, p.root, p.kind, max(f.modified) AS last_active, count(*) AS files
            FROM files f JOIN projects p ON p.id = f.project_id
            WHERE f.deleted_at IS NULL AND f.modified > ?
            GROUP BY p.id ORDER BY last_active DESC LIMIT ?
            """, since, limit)
        var nodes = projectRows.map { row in
            GraphMap.Node(id: "p\(row.int("id")!)", kind: .project, name: row.string("name")!, weight: row.int("files") ?? 1,
                          lastActive: row.date("last_active"), path: row.string("root"), isCode: row.string("kind") == "code")
        }
        var edges: [GraphMap.Edge] = []
        var shownFiles: [Int: String] = [:]   // file id → node id of its project or hub

        // Each project's newest files, as satellites.
        for row in projectRows {
            let project = "p\(row.int("id")!)"
            for file in try latestFiles(project: row.int("id")!, limit: filesEach) where file.kind != .collection {
                nodes.append(.init(id: "f\(file.id)", kind: .file, name: file.name, weight: 1, lastActive: file.modified, path: file.path))
                edges.append(.init(from: project, to: "f\(file.id)", kind: .contains, weight: 1))
                shownFiles[file.id] = project
            }
        }
        // The Desktop and Downloads, for files that haven't found a home yet.
        for folder in ["Desktop", "Downloads"] {
            let root = home + "/" + folder
            let loose = try db.query("""
                SELECT \(fileColumns) FROM files f LEFT JOIN projects p ON p.id = f.project_id
                WHERE f.deleted_at IS NULL AND f.path >= ? AND f.path < ? AND f.kind != 'collection' AND f.modified > ?
                ORDER BY f.modified DESC LIMIT 40
                """, root + "/", root + "/\u{10FFFF}", since).map(FileRecord.init(row:))
                .filter { ($0.path as NSString).deletingLastPathComponent == root }
            guard !loose.isEmpty else { continue }
            let hub = "h:\(folder)"
            nodes.append(.init(id: hub, kind: .project, name: folder, weight: loose.count, lastActive: loose.first?.modified, path: root))
            for file in loose.prefix(filesEach + 2) {
                nodes.append(.init(id: "f\(file.id)", kind: .file, name: file.name, weight: 1, lastActive: file.modified, path: file.path))
                edges.append(.init(from: hub, to: "f\(file.id)", kind: .contains, weight: 1))
                shownFiles[file.id] = hub
            }
        }

        let ids = projectRows.compactMap { $0.int("id") }
        let list = "[" + ids.map(String.init).joined(separator: ",") + "]"

        // Worked on together: projects with files changed in the same half hour.
        var together: [String: Int] = [:]
        let buckets = try db.query("""
            SELECT DISTINCT project_id, CAST(modified / 1800 AS INTEGER) AS bucket FROM files
            WHERE deleted_at IS NULL AND modified > ? AND project_id IN (SELECT value FROM json_each(?))
            """, since, list)
        for group in Dictionary(grouping: buckets, by: { $0.int("bucket")! }).values where group.count > 1 {
            let members = group.compactMap { $0.int("project_id") }.sorted()
            for (index, a) in members.enumerated() {
                for b in members[(index + 1)...] { together["p\(a)|p\(b)", default: 0] += 1 }
            }
        }
        for (pair, count) in together where count >= 2 {
            let parts = pair.split(separator: "|").map(String.init)
            edges.append(.init(from: parts[0], to: parts[1], kind: .together, weight: count))
        }

        // Topics the model noted in two or more of these projects' files.
        let tagRows = try db.query("""
            SELECT f.project_id, t.name, count(*) AS files FROM file_tags ft
            JOIN files f ON f.id = ft.file_id JOIN tags t ON t.id = ft.tag_id
            WHERE f.deleted_at IS NULL AND f.project_id IN (SELECT value FROM json_each(?))
            GROUP BY f.project_id, t.name
            """, list)
        let projectNames = Set(nodes.map { $0.name.lowercased() })
        let byTag = Dictionary(grouping: tagRows, by: { $0.string("name")!.lowercased() })
        struct Topic { let tag: String; let rows: [Row]; let files: Int }
        let topics = byTag.map { tag, rows -> Topic in
            Topic(tag: tag, rows: rows, files: rows.reduce(0) { $0 + ($1.int("files") ?? 0) })
        }
        .filter { $0.files >= 2 && !projectNames.contains($0.tag) }   // "thermal" next to Thermal says nothing
        .sorted { (a: Topic, b: Topic) -> Bool in a.rows.count != b.rows.count ? a.rows.count > b.rows.count : a.files > b.files }
        .prefix(18)
        for topic in topics {
            let (tag, rows, files) = (topic.tag, topic.rows, topic.files)
            nodes.append(.init(id: "t:\(tag)", kind: .topic, name: tag, weight: files))
            for row in rows { edges.append(.init(from: "p\(row.int("project_id")!)", to: "t:\(tag)", kind: .topic, weight: row.int("files") ?? 1)) }
        }

        // Where downloads came from: linked to the files shown, or else to their project.
        let sourceRows = try db.query("""
            SELECT id, project_id, source_url FROM files
            WHERE deleted_at IS NULL AND source_url IS NOT NULL AND modified > ?
            ORDER BY modified DESC LIMIT 400
            """, since)
        var bySource: [String: Set<String>] = [:]
        for row in sourceRows {
            guard let host = row.string("source_url").flatMap({ URL(string: $0)?.host() })?.replacingOccurrences(of: "www.", with: "") else { continue }
            let id = row.int("id")!
            if shownFiles[id] != nil {
                bySource[host, default: []].insert("f\(id)")
            } else if let project = row.int("project_id"), ids.contains(project) {
                bySource[host, default: []].insert("p\(project)")
            }
        }
        for (host, targets) in bySource.sorted(by: { $0.value.count > $1.value.count }).prefix(12) {
            nodes.append(.init(id: "s:\(host)", kind: .source, name: host, weight: targets.count))
            for target in targets { edges.append(.init(from: target, to: "s:\(host)", kind: .source, weight: 1)) }
        }
        return GraphMap(nodes: nodes, edges: edges)
    }
}

/// A force-directed layout: linked nodes pull together, everything pushes apart, and the
/// result is fitted into a unit square. Deterministic, so the map doesn't reshuffle each time.
public enum MapLayout {
    public static func positions(for map: GraphMap, iterations: Int = 400) -> [String: SIMD2<Double>] {
        let nodes = map.nodes
        guard !nodes.isEmpty else { return [:] }
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
        // Start on a golden-angle spiral, busiest projects in the middle.
        var position = nodes.indices.map { i -> SIMD2<Double> in
            let angle = Double(i) * 2.399963, radius = sqrt(Double(i) + 0.5) / sqrt(Double(nodes.count))
            return SIMD2(cos(angle), sin(angle)) * radius
        }
        let links = map.edges.compactMap { edge -> (Int, Int, Double)? in
            guard let a = index[edge.from], let b = index[edge.to] else { return nil }
            // Files sit close to their project; other links are looser.
            let spring = switch edge.kind { case .contains: 1.6; case .source: 1.2; case .together, .topic: 1.0 }
            return (a, b, spring * min(3, 1 + log(Double(edge.weight))))
        }
        // Projects and hubs push harder than satellites, so labels get room.
        let mass = nodes.map { $0.kind == .project ? 2.2 : $0.kind == .file ? 0.5 : 1.0 }
        let k = 1.0 / sqrt(Double(nodes.count))
        var temperature = 0.12
        for _ in 0..<iterations {
            var force = [SIMD2<Double>](repeating: .zero, count: nodes.count)
            for i in nodes.indices {
                for j in (i + 1)..<nodes.count {
                    var delta = position[i] - position[j]
                    var distance = (delta * delta).sum().squareRoot()
                    if distance < 1e-4 { delta = SIMD2(1e-3, 0); distance = 1e-3 }
                    let push = delta / distance * (k * k / distance) * mass[i] * mass[j]
                    force[i] += push
                    force[j] -= push
                }
            }
            for (a, b, strength) in links {
                let delta = position[a] - position[b]
                let distance = max(1e-4, (delta * delta).sum().squareRoot())
                let pull = delta / distance * (distance * distance / k) * strength * 0.5
                force[a] -= pull
                force[b] += pull
            }
            for i in nodes.indices {
                force[i] -= position[i] * 1.2 * k   // gravity keeps islands close, so the map isn't mostly gaps
                let length = max(1e-9, (force[i] * force[i]).sum().squareRoot())
                position[i] += force[i] / length * min(length, temperature)
            }
            temperature *= 0.985
        }
        // Fit each axis into 0...1; the view stretches it to its own shape.
        let xs = position.map(\.x), ys = position.map(\.y)
        let minimum = SIMD2(xs.min()!, ys.min()!)
        let span = SIMD2(max(1e-6, xs.max()! - minimum.x), max(1e-6, ys.max()! - minimum.y))
        var fitted = position.map { ($0 - minimum) / span * 0.92 + 0.04 }
        // Project labels sit under their dots and are wide: nudge apart any two that would overlap.
        // A project's files move with it.
        let projects = nodes.indices.filter { nodes[$0].kind == .project }
        var satellites: [Int: [Int]] = [:]
        for edge in map.edges where edge.kind == .contains {
            if let a = index[edge.from], let b = index[edge.to] { satellites[a, default: []].append(b) }
        }
        func shift(_ i: Int, by x: Double) { for j in [i] + satellites[i, default: []] { fitted[j].x += x } }
        for _ in 0..<60 {
            var moved = false
            for (n, a) in projects.enumerated() {
                for b in projects[(n + 1)...] {
                    let dx = fitted[b].x - fitted[a].x, dy = fitted[b].y - fitted[a].y
                    guard abs(dx) < 0.13, abs(dy) < 0.13 else { continue }   // the label hangs below the dot
                    let push = (0.13 - abs(dx)) / 2 * (dx < 0 ? -1 : 1)
                    shift(a, by: -push)
                    shift(b, by: push)
                    moved = true
                }
            }
            if !moved { break }
        }
        return Dictionary(uniqueKeysWithValues: nodes.indices.map { (nodes[$0].id, fitted[$0].clamped(lowerBound: SIMD2(repeating: 0.02), upperBound: SIMD2(repeating: 0.98))) })
    }
}
