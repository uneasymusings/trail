import Foundation

enum Schema {
    static let version = 4

    /// The knowledge graph: files, projects, tags and activity events, plus a full-text index.
    /// Edges are columns (`project_id`, `chain_id`) and join tables (`file_tags`) rather than a
    /// generic edge table, which keeps the common queries to a single indexed lookup.
    static let v1 = """
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);

        CREATE TABLE IF NOT EXISTS projects (
            id INTEGER PRIMARY KEY,
            root TEXT UNIQUE NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            last_active REAL NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY,
            path TEXT UNIQUE NOT NULL,
            name TEXT NOT NULL,
            ext TEXT NOT NULL DEFAULT '',
            kind TEXT NOT NULL,
            size INTEGER NOT NULL DEFAULT 0,
            inode INTEGER,
            created REAL,
            modified REAL NOT NULL,
            first_seen REAL NOT NULL,
            origin TEXT NOT NULL DEFAULT 'local',
            origin_app TEXT,
            source_url TEXT,
            project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
            stem TEXT,
            chain_id INTEGER,
            summary TEXT,
            enriched_at REAL,
            deleted_at REAL
        );
        CREATE INDEX IF NOT EXISTS files_modified ON files(modified DESC);
        CREATE INDEX IF NOT EXISTS files_project ON files(project_id, modified DESC);
        CREATE INDEX IF NOT EXISTS files_chain ON files(chain_id) WHERE chain_id IS NOT NULL;
        CREATE INDEX IF NOT EXISTS files_stem ON files(stem, kind) WHERE stem IS NOT NULL;
        CREATE INDEX IF NOT EXISTS files_inode ON files(inode);

        CREATE TABLE IF NOT EXISTS tags (
            id INTEGER PRIMARY KEY,
            name TEXT UNIQUE NOT NULL COLLATE NOCASE
        );
        CREATE TABLE IF NOT EXISTS file_tags (
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            PRIMARY KEY (file_id, tag_id)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS file_tags_tag ON file_tags(tag_id);

        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY,
            file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS events_at ON events(at DESC);
        CREATE INDEX IF NOT EXISTS events_file ON events(file_id, at DESC);

        CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(
            name, terms, summary, tags, project,
            tokenize = "porter unicode61 remove_diacritics 2"
        );
        """

    /// v3: what's inside documents becomes searchable, in its own `body` index so that matching
    /// names stays fast. Both indexes store only the index, not a second copy of the text
    /// (`contentless_delete`), which keeps them small. Also tracks when a file's text was read
    /// and how often it was opened from Trail. (Stemming, so "taxes" finds "tax", came in v2.)
    static let v3 = """
        DROP TABLE IF EXISTS search;
        CREATE VIRTUAL TABLE search USING fts5(
            name, terms, summary, tags, project,
            content = '', contentless_delete = 1, prefix = '2 3',
            tokenize = "porter unicode61 remove_diacritics 2"
        );
        CREATE VIRTUAL TABLE body USING fts5(
            text,
            content = '', contentless_delete = 1,
            tokenize = "porter unicode61 remove_diacritics 2"
        );
        CREATE VIRTUAL TABLE search_terms USING fts5vocab(search, row);
        CREATE VIRTUAL TABLE body_terms USING fts5vocab(body, row);
        ALTER TABLE files ADD COLUMN read_at REAL;
        ALTER TABLE files ADD COLUMN opens INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE files ADD COLUMN opened_at REAL;
        CREATE INDEX files_unread ON files(modified DESC) WHERE read_at IS NULL AND deleted_at IS NULL;
        INSERT INTO meta (key, value) VALUES ('search_rebuild', '1')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """

    /// v4: app names ("blender" for .blend files) join the indexed terms, and the inbox of new
    /// loose files on the Desktop and in Downloads, with where each probably belongs.
    static let v4 = """
        CREATE TABLE IF NOT EXISTS inbox (
            file_id INTEGER PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
            arrived REAL NOT NULL,
            status TEXT NOT NULL DEFAULT 'waiting',
            destinations TEXT,
            gist TEXT,
            read_at REAL,
            destination TEXT,
            decided_at REAL
        );
        CREATE INDEX IF NOT EXISTS inbox_status ON inbox(status, arrived DESC);
        INSERT INTO meta (key, value) VALUES ('search_rebuild', '1')
            ON CONFLICT(key) DO UPDATE SET value = excluded.value;
        """

    static func migrate(_ db: Database) throws {
        let current = try db.scalarInt("PRAGMA user_version") ?? 0
        if current < 1 { try db.exec(v1) }
        if current < 3 { try db.exec(v3) }
        if current < 4 { try db.exec(v4) }
        if current < version { try db.exec("PRAGMA user_version = \(version)") }
    }
}

extension Database {
    func meta(_ key: String) -> String? {
        (try? query("SELECT value FROM meta WHERE key = ?", key))?.first?.string("value")
    }

    func setMeta(_ key: String, _ value: String) {
        _ = try? run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, value)
    }
}

/// Columns selected wherever a `FileRecord` is built.
let fileColumns = """
    f.id, f.path, f.name, f.kind, f.size, f.modified, f.first_seen, f.origin, f.origin_app,
    f.source_url, f.project_id, p.name AS project_name, f.chain_id, f.summary,
    (SELECT group_concat(t.name, ',') FROM file_tags ft JOIN tags t ON t.id = ft.tag_id WHERE ft.file_id = f.id) AS tag_list
    """

extension FileRecord {
    init(row: Row) {
        self.init(
            id: row.int("id") ?? 0,
            path: row.string("path") ?? "",
            name: row.string("name") ?? "",
            kind: FileKind(rawValue: row.string("kind") ?? "") ?? .other,
            size: row.int("size") ?? 0,
            modified: row.date("modified") ?? .distantPast,
            firstSeen: row.date("first_seen") ?? .distantPast,
            origin: FileOrigin(rawValue: row.string("origin") ?? "") ?? .local,
            originApp: row.string("origin_app"),
            sourceURL: row.string("source_url"),
            projectID: row.int("project_id"),
            projectName: row.string("project_name"),
            chainID: row.int("chain_id"),
            summary: row.string("summary"),
            tags: row.string("tag_list")?.split(separator: ",").map(String.init) ?? []
        )
    }
}
