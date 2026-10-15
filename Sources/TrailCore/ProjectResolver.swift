import Foundation

/// Works out which project a file belongs to.
///
/// 1. A code project: the nearest folder with a project marker, with a git root winning over
///    nested package folders (so a monorepo stays one project).
/// 2. Otherwise a folder project: the first real folder below a "container" such as Documents,
///    Desktop or iCloud Drive — `~/Documents/Taxes 2026/w2.pdf` belongs to "Taxes 2026".
/// 3. Loose files in Downloads or on the Desktop belong to no project.
final class ProjectResolver: @unchecked Sendable {
    struct Project: Hashable {
        var root: String
        var name: String
        var kind: String
    }

    private let home: String
    private var cache: [String: Project?] = [:]
    /// Per folder: (has a project marker, has .git). Saves listing the same parents repeatedly.
    private var markerCache: [String: (marker: Bool, git: Bool)] = [:]
    private let lock = NSLock()

    static let markers: Set<String> = [
        ".git", "package.json", "Package.swift", "pyproject.toml", "Cargo.toml", "go.mod",
        "Gemfile", "pom.xml", "build.gradle", "pubspec.yaml", "composer.json", "deno.json", "project.yml",
    ]
    static let markerExtensions: Set<String> = ["xcodeproj", "xcworkspace", "sln", "uproject", "unity"]

    static let containerNames: Set<String> = [
        "Desktop", "Documents", "Downloads", "Developer", "CODE", "Code", "code", "Projects", "projects",
        "src", "repos", "Repos", "GitHub", "Work", "work", "Sites", "Dropbox", "Google Drive", "My Drive",
        "OneDrive", "Library", "Mobile Documents", "com~apple~CloudDocs", "CloudStorage", "Pictures",
        "Movies", "Music", "Public", "Shared drives", "Experiments",
    ]

    init(home: String = TrailPaths.home) {
        self.home = home
    }

    func project(forFile path: String) -> Project? {
        project(forFolder: (path as NSString).deletingLastPathComponent)
    }

    func project(forFolder folder: String) -> Project? {
        lock.lock()
        if let cached = cache[folder] { lock.unlock(); return cached }
        lock.unlock()

        let result = codeProject(from: folder) ?? folderProject(for: folder)

        lock.lock()
        if cache.count > 50_000 { cache.removeAll() }
        cache[folder] = result
        lock.unlock()
        return result
    }

    func invalidate() {
        lock.lock(); cache.removeAll(); markerCache.removeAll(); lock.unlock()
    }

    private func codeProject(from folder: String) -> Project? {
        var innermost: String?
        var gitRoot: String?
        var current = folder
        while current.hasPrefix(home + "/"), current != home {
            let markers = self.markers(in: current)
            if markers.marker, innermost == nil { innermost = current }
            if markers.git { gitRoot = current }
            current = (current as NSString).deletingLastPathComponent
        }
        guard let root = gitRoot ?? innermost else { return nil }
        return Project(root: root, name: (root as NSString).lastPathComponent, kind: "code")
    }

    private func markers(in folder: String) -> (marker: Bool, git: Bool) {
        lock.lock()
        if let cached = markerCache[folder] { lock.unlock(); return cached }
        lock.unlock()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let result = (
            marker: names.contains { Self.markers.contains($0) || Self.markerExtensions.contains(($0 as NSString).pathExtension) },
            git: names.contains(".git")
        )
        lock.lock()
        if markerCache.count > 100_000 { markerCache.removeAll() }
        markerCache[folder] = result
        lock.unlock()
        return result
    }

    private func folderProject(for folder: String) -> Project? {
        guard folder.hasPrefix(home + "/") else { return nil }
        let components = folder.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        var root = home
        for component in components {
            root += "/" + component
            if Self.containerNames.contains(component) { continue }
            // The CloudStorage provider folder (e.g. "Dropbox-Personal") is a container too.
            if (root as NSString).deletingLastPathComponent.hasSuffix("/CloudStorage") { continue }
            return Project(root: root, name: component, kind: "folder")
        }
        return nil
    }
}
