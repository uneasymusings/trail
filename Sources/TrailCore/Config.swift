import Foundation

/// User settings, stored as JSON next to the database so they're easy to edit by hand.
public struct TrailConfig: Codable, Sendable, Equatable {
    /// Folders Trail watches. Defaults to the home folder.
    public var roots: [String]
    /// Extra folders to ignore (absolute paths, `~` allowed).
    public var excludedPaths: [String]
    /// How far back the first scan reaches.
    public var backfillDays: Int
    /// Summarize new files with the on-device model.
    public var enrichWithModel: Bool

    public static let `default` = TrailConfig(
        roots: ["~"],
        excludedPaths: [],
        backfillDays: 365,
        enrichWithModel: true
    )

    public var expandedRoots: [String] { roots.map(Self.expand) }
    public var expandedExclusions: [String] { excludedPaths.map(Self.expand) }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath.trimmingTrailingSlash
    }

    public static func load(from url: URL) -> TrailConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(TrailConfig.self, from: data) else { return .default }
        return config
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum TrailPaths {
    /// `TRAIL_HOME` overrides the data folder (used by tests and for trying things out).
    public static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["TRAIL_HOME"] {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trail", isDirectory: true)
    }

    public static var database: URL { dataDirectory.appendingPathComponent("trail.sqlite") }
    public static var config: URL { dataDirectory.appendingPathComponent("config.json") }
}

extension String {
    var trimmingTrailingSlash: String {
        count > 1 && hasSuffix("/") ? String(dropLast()) : self
    }
}
