import Foundation

public enum FileKind: String, CaseIterable, Codable, Sendable {
    case document, pdf, spreadsheet, presentation, text, code, data
    case image, video, audio, design, model3d, archive, app, collection, other

    public var displayName: String {
        switch self {
        case .document: "Document"
        case .pdf: "PDF"
        case .spreadsheet: "Spreadsheet"
        case .presentation: "Presentation"
        case .text: "Text"
        case .code: "Code"
        case .data: "Data"
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .design: "Design"
        case .model3d: "3D"
        case .archive: "Archive"
        case .app: "App"
        case .collection: "Folder"
        case .other: "File"
        }
    }

    /// SF Symbol used in the UI and widget.
    public var symbol: String {
        switch self {
        case .document: "doc.text"
        case .pdf: "doc.richtext"
        case .spreadsheet: "tablecells"
        case .presentation: "rectangle.on.rectangle"
        case .text: "text.alignleft"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .data: "cylinder.split.1x2"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .design: "paintpalette"
        case .model3d: "cube"
        case .archive: "archivebox"
        case .app: "app"
        case .collection: "square.stack.3d.up"
        case .other: "doc"
        }
    }

    /// Extra words indexed with each file so natural phrasing ("deck", "photo") finds it.
    var synonyms: String {
        switch self {
        case .document: "document doc"
        case .pdf: "pdf"
        case .spreadsheet: "spreadsheet sheet excel table"
        case .presentation: "presentation deck slides"
        case .text: "text note notes"
        case .code: "code"
        case .data: "data"
        case .image: "image photo picture"
        case .video: "video movie clip"
        case .audio: "audio song track music sound"
        case .design: "design"
        case .model3d: "3d model"
        case .archive: "archive"
        case .app: "app application"
        case .collection: "folder collection batch"
        case .other: ""
        }
    }

    /// Kinds whose content is worth summarizing with the model.
    public var isEnrichable: Bool {
        switch self {
        case .document, .pdf, .spreadsheet, .presentation, .text, .image: true
        default: false
        }
    }

    /// Kinds that get linked into version chains. Code has git for that.
    var isVersioned: Bool {
        switch self {
        case .code, .data, .app, .archive, .collection, .other: false
        default: true
        }
    }

    private static let byExtension: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        func add(_ kind: FileKind, _ exts: String) {
            for ext in exts.split(separator: " ") { map[String(ext)] = kind }
        }
        add(.pdf, "pdf")
        add(.document, "doc docx pages rtf rtfd odt wpd")
        add(.spreadsheet, "xls xlsx xlsm numbers ods")
        add(.presentation, "ppt pptx key odp")
        add(.text, "txt md markdown rst org tex text")
        add(.code, "swift py js mjs cjs ts tsx jsx java kt kts c cc cpp cxx h hpp m mm rs go rb php sh zsh bash fish html htm css scss sass less vue svelte sql ipynb lua r dart cs scala ex exs hs ml clj zig glsl metal")
        add(.data, "json yaml yml toml xml csv tsv sqlite sqlite3 db parquet plist ini env geojson")
        add(.image, "png jpg jpeg heic heif gif webp tiff tif bmp svg raw cr2 cr3 nef arw dng avif ico")
        add(.design, "psd ai sketch fig xd indd afdesign afphoto procreate eps")
        add(.model3d, "blend c4d obj fbx stl usdz usd usda glb gltf 3ds max ma mb abc")
        add(.video, "mov mp4 m4v avi mkv webm prproj aep drp fcpbundle mts")
        add(.audio, "mp3 wav aif aiff flac m4a ogg opus alac als logicx ptx band flp mid midi")
        add(.archive, "zip tar gz tgz bz2 xz rar 7z dmg pkg iso")
        add(.app, "app")
        return map
    }()

    public static func from(extension ext: String) -> FileKind {
        byExtension[ext.lowercased()] ?? .other
    }
}

public enum FileOrigin: String, Codable, Sendable {
    case local, download, ai

    public var label: String? {
        switch self {
        case .local: nil
        case .download: "Downloaded"
        case .ai: "AI"
        }
    }
}

public struct FileRecord: Identifiable, Hashable, Codable, Sendable {
    public var id: Int
    public var path: String
    public var name: String
    public var kind: FileKind
    public var size: Int
    public var modified: Date
    public var firstSeen: Date
    public var origin: FileOrigin
    public var originApp: String?
    public var sourceURL: String?
    public var projectID: Int?
    public var projectName: String?
    public var chainID: Int?
    public var summary: String?
    public var tags: [String]

    public var url: URL { URL(fileURLWithPath: path) }

    /// The path with the home directory shortened to `~`.
    public var displayPath: String {
        let home = NSHomeDirectory()
        let parent = (path as NSString).deletingLastPathComponent
        return parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }

    public var sourceHost: String? {
        sourceURL.flatMap { URL(string: $0)?.host() }.map { $0.replacingOccurrences(of: "www.", with: "") }
    }
}

public struct ProjectSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: Int
    public var name: String
    public var root: String
    public var kind: String
    public var lastActive: Date
    public var fileCount: Int
    public var latest: [FileRecord]
}

public struct SearchHit: Identifiable, Hashable, Sendable {
    public var file: FileRecord
    public var score: Double
    /// Number of files in this hit's version chain (1 when it has no versions).
    public var versionCount: Int
    public var id: Int { file.id }
}

public struct SearchResponse: Sendable {
    public var plan: QueryPlan
    public var hits: [SearchHit]
    public var projects: [ProjectSummary]
    public var answer: String?
    public var refinedByModel: Bool

    public static func empty(_ plan: QueryPlan) -> SearchResponse {
        SearchResponse(plan: plan, hits: [], projects: [], answer: nil, refinedByModel: false)
    }
}

public struct Related: Sendable {
    public var versions: [FileRecord]
    public var sameSession: [FileRecord]
    public var sameTopics: [FileRecord]
    public var sameProject: [FileRecord]
}

public struct IndexStats: Sendable {
    public var files: Int
    public var projects: Int
    public var enriched: Int
    public var chains: Int
    public var databaseBytes: Int
}
