import Foundation

/// What the desktop widget shows. The app writes it to the shared app-group folder; the widget
/// (sandboxed, no database access) only reads this file. Shared verbatim by both targets.
public struct WidgetSnapshot: Codable, Sendable {
    public struct Item: Codable, Sendable, Identifiable, Hashable {
        public var id: String { path }
        public var name: String
        public var path: String
        public var project: String?
        public var modified: Date
        public var symbol: String

        public init(name: String, path: String, project: String?, modified: Date, symbol: String) {
            self.name = name
            self.path = path
            self.project = project
            self.modified = modified
            self.symbol = symbol
        }
    }

    public struct Project: Codable, Sendable, Identifiable, Hashable {
        public var id: String { name }
        public var name: String
        public var lastActive: Date
        public var latest: Item?

        public init(name: String, lastActive: Date, latest: Item?) {
            self.name = name
            self.lastActive = lastActive
            self.latest = latest
        }
    }

    public var generated: Date
    public var projects: [Project]
    public var recent: [Item]
    public var fileCount: Int

    public init(generated: Date, projects: [Project], recent: [Item], fileCount: Int) {
        self.generated = generated
        self.projects = projects
        self.recent = recent
        self.fileCount = fileCount
    }

    public static let fileName = "widget-snapshot.json"

    public static let placeholder = WidgetSnapshot(
        generated: .now,
        projects: [
            Project(name: "Thermal", lastActive: .now.addingTimeInterval(-900),
                    latest: Item(name: "Pitch v3.key", path: "/", project: "Thermal", modified: .now.addingTimeInterval(-900), symbol: "rectangle.on.rectangle")),
            Project(name: "Portfolio", lastActive: .now.addingTimeInterval(-7_200),
                    latest: Item(name: "case-study.md", path: "/", project: "Portfolio", modified: .now.addingTimeInterval(-7_200), symbol: "text.alignleft")),
            Project(name: "Taxes 2026", lastActive: .now.addingTimeInterval(-86_400),
                    latest: Item(name: "W-2.pdf", path: "/", project: "Taxes 2026", modified: .now.addingTimeInterval(-86_400), symbol: "doc.richtext")),
        ],
        recent: [],
        fileCount: 48_201
    )
}
