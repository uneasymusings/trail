import Foundation

/// Decides which paths belong in the graph. Everything here is plain string work so it can run
/// on every file-system event without touching the disk.
public struct ScopeRules: Sendable {
    public let roots: [String]
    let home: String
    let exclusions: [String]
    /// Folders inside ~/Library that hold real user files (iCloud Drive, Dropbox, Google Drive…).
    let libraryAllowList: [String]

    static let skippedFolderNames: Set<String> = [
        "node_modules", "DerivedData", "Pods", "Carthage", "__pycache__", "venv", "env",
        "site-packages", "bower_components", "vendor", "build", "dist", "out", "target",
        "Caches", "Cache", "Logs", "tmp", "temp", "xcuserdata", "Applications",
        "Photos Library.photoslibrary", "$RECYCLE.BIN",
    ]

    static let skippedExtensions: Set<String> = [
        "log", "tmp", "temp", "swp", "swo", "crdownload", "part", "download", "partial",
        "lock", "pyc", "pyo", "o", "d", "class", "dylib", "so", "a", "lnk", "ds_store",
        "localized", "icloud", "xcuserstate", "map", "sublime-workspace",
        // Libraries and developer bundles: packages, but not documents anyone looks for.
        "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "aplibrary", "lrdata",
        "xcodeproj", "xcworkspace", "xcassets", "bundle", "framework", "lproj", "kext", "plugin",
        "appex", "dsym", "nib", "storyboardc", "scnassets", "pkg", "mpkg", "scriptd",
    ]

    public init(config: TrailConfig, home: String = NSHomeDirectory()) {
        self.home = home
        let expand = { (path: String) in
            (path == "~" ? home : path.hasPrefix("~/") ? home + path.dropFirst(1) : path).trimmingTrailingSlash
        }
        self.roots = config.roots.map(expand)
        self.exclusions = config.excludedPaths.map(expand)
        self.libraryAllowList = [
            home + "/Library/Mobile Documents/com~apple~CloudDocs",
            home + "/Library/CloudStorage",
        ]
    }

    /// Whether a file (or package such as `.key` or `.logicx`) should be indexed.
    public func shouldIndex(_ path: String) -> Bool {
        guard isInScope(path) else { return false }
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix(".") || name.hasPrefix("~$") || name.hasPrefix(".~lock") { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        if Self.skippedExtensions.contains(ext) { return false }
        // Skip anything that sits inside a skipped folder.
        let parent = (path as NSString).deletingLastPathComponent
        return isFolderInScope(parent)
    }

    /// Whether to look inside a folder during a scan.
    public func shouldDescend(into path: String) -> Bool {
        isInScope(path) && isFolderInScope(path)
    }

    private func isInScope(_ path: String) -> Bool {
        guard roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return false }
        if exclusions.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
        let library = home + "/Library"
        if path == library || path.hasPrefix(library + "/") {
            return libraryAllowList.contains { path == $0 || path.hasPrefix($0 + "/") }
                || libraryAllowList.contains { $0.hasPrefix(path + "/") }
        }
        return true
    }

    private func isFolderInScope(_ folder: String) -> Bool {
        // Only check components below the root so a root inside e.g. ~/build still works.
        guard let root = roots.first(where: { folder == $0 || folder.hasPrefix($0 + "/") }) else { return false }
        let relative = folder.dropFirst(root.count)
        for component in relative.split(separator: "/") {
            if component.hasPrefix(".") || Self.skippedFolderNames.contains(String(component)) { return false }
            // Don't descend into bundles like Foo.app/Contents or Library.photoslibrary.
            let ext = (component as NSString).pathExtension.lowercased()
            if !ext.isEmpty, Self.packageExtensions.contains(ext) { return false }
        }
        return true
    }

    /// Bundles that look like folders on disk but are one document to the user.
    static let packageExtensions: Set<String> = [
        "app", "pages", "numbers", "key", "rtfd", "logicx", "band", "fcpbundle", "photoslibrary",
        "musiclibrary", "tvlibrary", "imovielibrary", "xcodeproj", "xcworkspace", "xcassets",
        "bundle", "framework", "playground", "sketch", "graffle", "scriptd", "workflow", "lproj",
        "pkg", "mpkg", "kext", "plugin", "appex", "dsym", "nib", "storyboardc", "scnassets",
        "rcproject", "reality", "usdz", "aplibrary", "lrdata", "lrcat-data", "cocatalog", "cosessiondb",
    ]
}
