import Foundation

/// What Trail learns about a file from the file system alone — no reading of contents.
struct Inspection {
    var path: String
    var name: String
    var ext: String
    var kind: FileKind
    var size: Int
    var inode: UInt64
    var created: Date?
    var modified: Date
    var origin: FileOrigin
    var originApp: String?
    var sourceURL: String?
}

enum FileInspector {
    /// Returns nil for folders (other than packages), symlinks and missing files.
    static func inspect(_ path: String) -> Inspection? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()

        if type == S_IFDIR {
            guard ScopeRules.packageExtensions.contains(ext) else { return nil }
        } else if type != S_IFREG {
            return nil
        }

        let modified = Date(timespec: info.st_mtimespec)
        let created = Date(timespec: info.st_birthtimespec)
        let sourceURL = whereFroms(path)?.first { $0.hasPrefix("http") }
        let quarantineApp = quarantineAgent(path)
        let origin = classifyOrigin(path: path, app: quarantineApp, sourceURL: sourceURL)

        return Inspection(
            path: path,
            name: name,
            ext: ext,
            kind: FileKind.from(extension: ext),
            size: type == S_IFDIR ? 0 : Int(info.st_size),
            inode: UInt64(info.st_ino),
            created: created,
            modified: modified,
            origin: origin,
            originApp: quarantineApp,
            sourceURL: sourceURL
        )
    }

    // MARK: - Origin

    static let aiApps = ["claude", "chatgpt", "openai", "cursor", "codex", "copilot", "windsurf", "gemini", "perplexity", "lm studio", "ollama"]
    static let receivingApps = [
        "chrome", "safari", "firefox", "arc", "brave", "edge", "opera", "vivaldi", "orion", "dia",
        "sharingd", "airdrop", "messages", "mail", "slack", "discord", "telegram", "whatsapp", "signal",
        "zoom", "teams", "wetransfer", "transmit", "cyberduck", "filezilla", "spark", "outlook",
    ]
    static let aiPathMarkers = ["/.claude/", "/claude-worktrees/", "/.cursor/", "/.codex/", "/ChatGPT/", "/Claude/"]

    /// The file system never says which process wrote a file, so this is a best guess from the
    /// quarantine tag (set by the app that saved a download) and well-known AI tool folders.
    static func classifyOrigin(path: String, app: String?, sourceURL: String?) -> FileOrigin {
        if let app = app?.lowercased(), aiApps.contains(where: app.contains) { return .ai }
        if let host = sourceURL.flatMap({ URL(string: $0)?.host()?.lowercased() }),
           ["claude.ai", "chatgpt.com", "openai.com", "gemini.google.com", "perplexity.ai"].contains(where: host.hasSuffix) {
            return .ai
        }
        if aiPathMarkers.contains(where: path.contains) { return .ai }
        if sourceURL != nil { return .download }
        // Sandboxed apps (Preview, Keynote…) tag files they save too, so only apps that bring
        // files in from elsewhere count as a download.
        if let app = app?.lowercased(), receivingApps.contains(where: app.contains) { return .download }
        return .local
    }

    // MARK: - Extended attributes

    /// URLs a download came from (`kMDItemWhereFroms`), written by browsers and many apps.
    static func whereFroms(_ path: String) -> [String]? {
        guard let data = xattr(path, "com.apple.metadata:kMDItemWhereFroms") else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String]
    }

    /// The app named in the quarantine tag, e.g. "0083;6527d1a0;Google Chrome;UUID".
    static func quarantineAgent(_ path: String) -> String? {
        guard let data = xattr(path, "com.apple.quarantine"),
              let value = String(data: data, encoding: .utf8) else { return nil }
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count > 2 else { return nil }
        let agent = fields[2].trimmingCharacters(in: .whitespaces)
        return agent.isEmpty ? nil : agent
    }

    private static func xattr(_ path: String, _ name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size < 1_000_000 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read == size ? data : nil
    }
}

extension Date {
    init(timespec: timespec) {
        self.init(timeIntervalSince1970: Double(timespec.tv_sec) + Double(timespec.tv_nsec) / 1_000_000_000)
    }
}
