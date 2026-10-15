# How Trail works

Trail is three thin shells (a menu-bar app, a widget and a CLI) around one engine, `TrailCore`. The engine is a Swift package with no dependencies beyond macOS: FSEvents to watch, SQLite to store, FoundationModels to read.

```
                ┌──────────────── TrailCore ────────────────────────────────────────┐
 FSEvents ─────►│ Watcher ─► Indexer ─► Database (SQLite, WAL, FTS5) ◄─ SearchEngine │◄── panel · CLI
 (whole ~)      │  1.5 s      │  ▲                                     ▲          │
                │  batches    ▼  │                                     │          │
                │      FileInspector · ProjectResolver · VersionNamer  QueryParser │
                │                                                      Intelligence│◄── on-device model
                │ TextExtractor ─► Intelligence.note() ─► summary + tags (idle)   │
                └──────────────────────────────────────────────┬───────────────────┘
                                                               ▼
                                                 widget-snapshot.json ─► WidgetKit
```

## Design goals

1. **Instant.** Typing must never wait on disk or on the model. The search as you type is pure SQLite and finishes in about 5 ms.
2. **Small.** One SQLite file. No embeddings or vector store, and no resident model. On a heavy Mac, 400,000 files on disk index into 49,000 entries and 33 MB, and the app's footprint while watching is about 40 MB.
3. **Quiet.** Background priority while scanning, model work only when idle and not on low power, no windows on launch.
4. **Private.** No network. The model is Apple's on-device Foundation Model.

## The graph

Nodes and edges live in ordinary tables. Edges are columns (`project_id`, `chain_id`) and one join table (`file_tags`) rather than a generic edge table, so every common question is a single indexed lookup.

| Table | Holds | Edges |
|---|---|---|
| `files` | path, name, kind, size, inode, created/modified, origin, source URL, summary | `project_id` → projects, `chain_id` → version chain, `stem` for matching versions |
| `projects` | root folder, name, kind (`code` or `folder`), last active | |
| `tags`, `file_tags` | topic tags written by the model | file ↔ tag |
| `events` | created / modified / moved, throttled to one per file per 10 minutes | file → time |
| `search` | FTS5 over name, path terms, summary, tags, project | `rowid` = file id |
| `meta` | last FSEvents ID, scan state, schema flags | |

Schema versions run through `PRAGMA user_version` (`Schema.swift`). Version 2 switched the full-text tokenizer to `porter unicode61`, so "taxes" finds "tax". The migration drops the FTS table and the engine refills it on a background queue.

## Watching and indexing

**Watcher** (`Watcher.swift`). One FSEvents stream over the configured roots, with file-level events and `IgnoreSelf`. Events are coalesced for 1.5 s into a batch: a set of paths, plus a "rescan" flag when macOS says a subtree must be rescanned. The last event ID is stored after each batch. On the next launch the stream starts from that ID, so changes made while Trail was closed are replayed rather than rescanned.

**First scan** (`Indexer.backfill`). An explicit-stack directory walk with an `autoreleasepool` per folder. It writes 400 items per transaction and runs at `.background` QoS with `enforceQoS`, which keeps it on efficiency cores. Files older than `backfillDays` (365) are skipped. When it finishes, the engine compacts the database and releases the scan's caches.

**Scope** (`ScopeRules.swift`). Hidden files, `node_modules`, build folders, caches, logs, temp files, in-progress downloads and app bundles are skipped. So is all of `~/Library` except iCloud Drive (`Mobile Documents/com~apple~CloudDocs`) and `CloudStorage` (Dropbox, Google Drive, OneDrive).

**Per file** (`FileInspector.swift`). One `lstat` plus two extended attributes:
- `kMDItemWhereFroms`: the URL a download came from.
- `com.apple.quarantine`: the app that brought the file in.

Origin is classified from these and from path markers:
- **AI:** the quarantine app or source host belongs to an AI tool, or the path contains `/.claude/`, `/Claude/`, `/.cursor/` and the like.
- **Download:** there's a source URL, or the quarantine app is a browser, AirDrop, Messages, Slack or similar.
- **Local:** everything else. Sandboxed editors such as Preview and Keynote also tag files they save, which is why "has a quarantine tag" alone doesn't mean downloaded.

**Moves.** When a new path appears with the same inode and size as a file whose old path is gone, the row is moved instead of deleted and re-added. Notes, tags and history survive renames.

## Heuristics

**Projects** (`ProjectResolver.swift`). Walking up from a file:
1. A git root wins.
2. Otherwise the innermost folder with a project marker (`package.json`, `Package.swift`, `Cargo.toml`, `pyproject.toml`, `go.mod` and so on).
3. Otherwise the first non-container folder below a container. Containers are folders like Documents, Desktop, Downloads, iCloud Drive and Developer, so `~/Documents/Taxes 2026/W-2.pdf` belongs to "Taxes 2026".

Marker lookups and results are cached per folder during a scan and released afterwards.

**Versions** (`VersionNamer.swift`). A file's *stem* is its name with version markers removed:
- copy numbers: `(1)`, `copy 2`
- versions: `v2`, `version 3`
- states: `final`, `draft`, `edited`, `updated`, `wip`, `backup`, `old`, `new`, `rev 2`
- trailing dates and timestamps: `2026-10-14`, `20261014`, `3-14-26`

Word markers need a separator before them, so "Overfinal.pdf" keeps its name. Generic stems like "untitled", "screenshot", "image" and "notes" never chain. Two files join a chain (`chain_id`) when they share a stem and kind, sit in the same folder or project, and at least one name carries a version marker. Search shows each chain once, as its newest member with a count.

**Generated output.** Two rules keep machine-made folders from flooding the graph:
- *Burst folders*: 20+ files whose creation times (10th to 90th percentile) fall within 10 minutes. Exports, renders and screenshot runs look like this. The folder becomes one `collection` entry ("thermal-hero: 48 files, mostly PNG images") plus its 3 newest files.
- *Large bulky trees*: 3,000+ files that are at least 85% images, data or archives. The tree is folded into one entry. If one child folder holds 90% or more of the files, the fold steps down into it, so a project's `docs/` stays visible while a `docs/verification/` folder of 100,000 test screenshots collapses.

Downloads, Desktop and Documents are never collapsed.

## Search

Search runs as a pipeline. Each stage can return on its own.

1. **Parse** (`QueryParser.swift`, about 0.1 ms). Rules turn text into a `QueryPlan`:
   - *keywords* (after removing stop words and filler)
   - *kinds* ("deck" → presentation, "pdfs" → pdf)
   - *timeframe* ("last week", "yesterday")
   - *origin* ("downloaded", "ai")
   - *newestFirst* ("latest", "last", "recent")
2. **Retrieve** (`SearchEngine.swift`). FTS5 with column weights `bm25(name 10, terms 3, summary 2, tags 3, project 6)`. It tries all keywords with AND, then falls back to OR. Kind, time and origin filters are SQL predicates on `files`. A question with no keywords ("what was I working on today?") skips the full-text index and reads recent activity.
3. **Rank.** `score = (1 − w) · relevance/best + w · e^(−age/21 days)`, where `w` is 0.75 for "latest" or no-keyword questions and 0.3 otherwise.
4. **Collapse.** Version chains fold into their newest file. Matching projects are shown as chips.
5. **Answer.** A deterministic one-liner: "Pitch v3.key: 14 minutes ago in Thermal (newest of 3 versions)", or for activity questions "Today you were mostly in Thermal, portfolio and Claude".

The panel runs stages 1–5 on every keystroke. After a 350 ms pause on a question of 3+ words it also asks the model:

6. **Refine** (`Intelligence.refine`). `LanguageModelSession` with a `@Generable` `PlanOutput` struct, guided enums for kind, timeframe and origin, and temperature 0. The model's plan is merged into the rule-based one, then checked:
   - Kind words it echoed back as keywords are dropped.
   - A timeframe is kept only if the question mentions time; small models like to invent "this week".
   - If the refined search comes back empty, the instant results stay.

The answer line is never written by the model. An earlier version let it summarize activity, and it confidently invented what a project was about from its folder name alone. The facts in the answer come from the graph.

## Notes (enrichment)

While the Mac is idle, the engine takes up to 8 files at a time that have no note yet. It backs off on low power or a serious or critical thermal state, and waits 400 ms between files. `TextExtractor` pulls an excerpt:
- plain text: up to 16 KB, skipping binary files;
- PDFs: the first 3 pages through PDFKit;
- docx and rtf: via `NSAttributedString`;
- pptx and xlsx: text runs from their zip archives;
- images: Vision's fast text recognition.

`Intelligence.note` returns a one-sentence summary and up to 5 tags. That takes about 1.5 s per file. Tags longer than 30 characters or containing `/` are thrown away, because the model sometimes returns paths. Notes feed the full-text index, so a file can be found by what's in it.

## The app

- **Panel.** A borderless, non-activating `NSPanel` (like Spotlight). It takes keyboard focus without activating the app and hides when it loses focus. The content is SwiftUI with Liquid Glass (`.glassEffect`). ASCII appears only in loading states: a braille spinner while the model reads, a shade-block bar while mapping, and the answer line decoding in from `01/+:`. All of them hold still with Reduce Motion.
- **Hotkey.** Carbon's `RegisterEventHotKey`, which still needs no Accessibility permission.
- **Widget.** WidgetKit can't read the database from its sandbox. The app writes a small JSON snapshot to the shared app-group folder (at most once a minute) and asks WidgetKit to reload (at most every 2 minutes).
- **URL scheme.** `trail://ask?q=`, `open?path=`, `reveal?path=`. `open` only opens files that are in the index, and it reveals apps and scripts in Finder instead of running them.
- **Permissions.** Full Disk Access is checked by trying to open `~/Library/Application Support/com.apple.TCC/TCC.db`, which only works with that permission.

## Testing

`swift test` runs Swift Testing suites against throwaway home folders:
- version naming and query parsing;
- scope rules;
- indexing: versions, projects, renames, deletes, folders moved in, notes;
- collections and large-tree folding;
- the v1 → v2 stemming migration.

CI runs them on GitHub's `macos-26` runners and builds the app on every push. Tagged pushes also build a DMG and publish a release.

## Demo recordings

`make demo` regenerates the README GIFs without showing anyone's real files:
1. `scripts/demo/make-home.swift` builds a made-up home folder: a startup pitch with three deck versions, taxes, a Lisbon trip, downloads with real `WhereFroms` and quarantine tags, a git project, and a burst of renders.
2. The CLI indexes that folder. `TRAIL_USER_HOME` makes the engine treat it as `~`, so paths read `~/Documents/Thermal`.
3. The app runs with `TRAIL_DEMO=<scene.json>` and plays the scene: show the panel, type with uneven timing, press keys. It never takes keyboard focus, so you can keep working while it records.
4. `scripts/demo/capture.swift` records the region with ScreenCaptureKit, without the pointer, and ffmpeg turns it into a GIF.
