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

1. **Instant.** Typing must never wait on the model. The search as you type is pure SQLite and finishes in 2–17 ms on a heavy Mac.
2. **Small.** One SQLite file. No embeddings or vector store, and no resident model. On a heavy Mac, 400,000 files on disk index into 50,000 entries. With the text of 4,000 documents that comes to 40 MB, and the app's footprint while watching is about 30 MB.
3. **Quiet.** Background priority while scanning and reading, model work only after a minute away from the keyboard and never on low power, no windows on launch.
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
| `body` | FTS5 over the first 6,000 characters of each document | `rowid` = file id |
| `inbox` | new loose files, suggested folders (JSON), what was decided | `file_id` → files, `destination` |
| `meta` | last FSEvents ID, scan state, schema flags | |

Both full-text tables are *contentless* (`content = '', contentless_delete = 1`): they hold the index but no second copy of the text, which is read from `files` or from disk when needed. That keeps the index small. Adding document text to a 34 MB index grew it by only a few MB. `search_terms` and `body_terms` are `fts5vocab` views of the two indexes, used to fix typos.

Schema versions run through `PRAGMA user_version` (`Schema.swift`):
- **v2** switched to the `porter unicode61` tokenizer, so "taxes" finds "tax".
- **v3** made the index contentless, added `body`, and added `read_at`, `opens` and `opened_at` to `files`.
- **v4** added app names to the indexed terms and the `inbox` table.

Migrations drop the full-text tables. The engine refills `search` on a background queue, and the document reader refills `body` after that.

## Watching and indexing

**Watcher** (`Watcher.swift`). One FSEvents stream over the configured roots, with file-level events and `IgnoreSelf`. Events are coalesced for 1.5 s into a batch: a set of paths, plus a "rescan" flag when macOS says a subtree must be rescanned. The last event ID is stored after each batch. On the next launch the stream starts from that ID, so changes made while Trail was closed are replayed rather than rescanned.

**First scan** (`Indexer.backfill`). An explicit-stack directory walk with an `autoreleasepool` per folder. It writes 400 items per transaction and runs at `.background` QoS with `enforceQoS`, which keeps it on efficiency cores. Files older than `backfillDays` (365) are skipped. When it finishes, the engine compacts the database and releases the scan's caches.

**Reading documents** (`Indexer.readPending`). Files whose text changed since it was last read (`read_at IS NULL`) are read 40 at a time, newest first, at background priority, and their text goes into `body`. This covers PDFs, Word and RTF, text and Markdown, pptx and xlsx. Image text is left to the model's notes, because OCR is slow. Batches are queued one at a time, so file changes are handled in between. Editing a file clears `read_at`, and its text is read again.

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

Search runs as a pipeline, in plain SQLite, on every keystroke.

1. **Parse** (`QueryParser.swift`, about 0.1 ms). Rules turn text into a `QueryPlan`:
   - *keywords*, after removing stop words and filler; "w-2" stays one word
   - *kinds* ("deck" → presentation, "pdfs" → pdf)
   - *timeframe* ("last week", "yesterday")
   - *origin* ("downloaded", "ai")
   - *newestFirst* ("latest", "last", "recent")
2. **Fix typos.** A keyword of 4+ letters that no indexed word starts with is swapped for the closest word in the index vocabulary: within one edit, or two for words of 7+ letters, and the most common on a tie. Names are tried first, then document text. The index stores stems ("syllabu"), so the panel shows the fix the way the word appears in the results: "Showing results for syllabus".
3. **Retrieve** (`SearchEngine.swift`) from both indexes, in three passes:
   - *Every word in the name, folders or notes*, ranked by `bm25(name 10, terms 3, summary 2, tags 3, project 6)`. The word being typed is a prefix, and the others are whole (stemmed) words.
   - *Every word, some only in the text*, as in "climate paper": "paper" is in the name, "climate" in the essay. Each word's matching rowids from both tables are intersected in SQL, and the files left over are ranked against `body`. In the text, the word being typed counts as a prefix only from 4 letters on.
   - *Some of the words*, when that found fewer than a page of results. Each file's share of the words is counted.

   Kind, time and origin are SQL filters on `files`. A word in more than 2,500 files is ordered by recency rather than bm25, because scoring thousands of matches is slow and barely tells them apart. A question with no keywords ("what was I working on today?") reads recent activity instead.
4. **Rank.** Files with every word always come first. Within that, scores blend:

   | Signal | Weight | Notes |
   |---|---|---|
   | text match | 0.20 | bm25, normalized; a match in the text counts 0.6 of one in the name |
   | word coverage | 0.20 | share of the keywords found anywhere |
   | name match | 0.25 | share of the keywords in the file name, or 0.6 each in the project name |
   | kind | 0.20 | documents, PDFs, slides, media 1 · text 0.8 · images 0.6 · code and data 0 |
   | recency | 0.15 | e^(−age / 30 days) |
   | opened from Trail | +0.20 | grows with opens, fades over 60 days |
   | recent edits | +0.04 | edit events in the last month |

   "Latest" questions move most of the weight to recency (0.50). The kind prior is the main tie-breaker on a developer's Mac: when `Investor memo.docx` and `memo.ts` both match "memo", the document is usually the one you mean, and the source file is a click away in your editor.
5. **Loosen.** If kind, time or origin filters leave nothing, they're dropped one at a time (time, then kind, then origin). "Lease agreement slides" still finds the lease PDF.
6. **Collapse.** Version chains fold into their newest file, unless you named a particular one ("pitch v2", "paper draft"). Matching projects are shown as chips.
7. **Answer.** A deterministic one-liner: "Pitch v3.key: 14 minutes ago in Thermal (newest of 3 versions)", or for activity questions "Today you were mostly in Thermal, portfolio and Claude".

The panel runs stages 1–7 on every keystroke. After a 350 ms pause on a question of 3+ words it also asks the model:

8. **Refine** (`Intelligence.refine`). `LanguageModelSession` with a `@Generable` `PlanOutput` struct, guided enums for kind, timeframe and origin, and temperature 0. The model's plan is merged into the rule-based one, then checked:
   - Kind words it echoed back as keywords are dropped.
   - A timeframe is kept only if the question mentions time; small models like to invent "this week".
   - If the refined search comes back empty, the instant results stay.

The answer line is never written by the model. An earlier version let it summarize activity, and it confidently invented what a project was about from its folder name alone. The facts in the answer come from the graph.

## Asking the model

Questions of 3 or more words get two model calls after a 350 ms pause, while the instant results stay on screen:

1. **Refine** (above) shapes the plan.
2. **Pick** (`Intelligence.pick`). The model reads the question and the top 8 results as numbered lines of facts from the graph: kind and app, when the file was edited, folder, project, versions, where it was downloaded from, and its note and tags. It returns a number via a `@Generable` struct. Out-of-range answers are ignored, so it can choose a file but never invent one. The chosen file moves to the top, and the deterministic answer line describes it with a ✦.

On an M-series Mac the two calls take about 0.75 s and 0.45 s. Guardrails, each from a real failure:
- The model may not add a kind when you named an app: it read "blender" as "3D".
- Number and time words can't become keywords: "two days ago" once searched for "two" and matched "two firmware engineers".
- When loosening a kind filter, the newest files of that kind stay in the list. Then "the deck we're sending to investors" can still choose the deck over the investor memo.

The parser also understands talk rather than keywords:
- "two days ago" becomes a ±1-day window, and "a couple of weeks ago", "the other day" and "on Monday" work too;
- "big" and "small" sort by size;
- filler like "important", "I think" and "like" is dropped.

Typo correction skips anything in the system word list (`/usr/share/dict/words`, binary-searched in place), because a real word that isn't in your files is not a typo.

## Sorting new files (`Inbox.swift`)

New loose files at the top level of `~/Desktop` and `~/Downloads` (last 7 days, no installers) enter an `inbox` table. They count once they've sat for 10 minutes, so the screenshot you're about to paste isn't flagged.

Each one is read (text, or accurate OCR for images) and gets up to four candidate folders, from three kinds of evidence in the graph:

| Evidence | How | Weight |
|---|---|---|
| Files like it | the file's distinctive words (name minus "Screenshot" and dates, source site, most frequent words in its text) run through search; the folders of the hits vote | coverage ÷ rank |
| What you were doing | folders with files changed within 45 minutes of its arrival, outside code projects | 0.5 |
| Your habits | where earlier files from the same site, or of the same family ("Screenshot…", "IMG_…"), went | 1.2 / 0.8 |

Candidates must be real folders in your home, not hidden, not build output, and not generated folders Trail has folded. Alternatives need at least 30% of the top score. When the model is available, it gets the file (kind, source, first 600 characters) and the candidate folders with a few of their files, and chooses one, again by number. A reason comes with the suggestion: "Like W-2.pdf there", "Where your last download from irs.gov went".

Moves happen only from the sort panel (or `TrailEngine.sort`). The file is moved first and the graph updates on the index queue, so a running scan never blocks the panel. Move detection by inode keeps the file's row, notes and history. The decision is stored, and it's the strongest hint next time. Files you move yourself in Finder count as decisions too. `trail inbox` prints the same suggestions in the terminal.

## The map (`GraphMap.swift`, `MapView.swift`)

`SearchEngine.map()` builds the graph view from the same tables:
- the 36 most recently active projects, with their 4 newest files each;
- the Desktop and Downloads as hubs;
- topics (model tags) found in 2 or more files;
- download sources, linked to the files or projects they ended up in;
- "worked on together" links between projects with changes in the same half hour, at least twice.

`MapLayout` is a deterministic Fruchterman–Reingold layout:
- it starts from a golden-angle spiral;
- files cling to their project, and projects push harder so labels get room;
- 400 iterations take a few milliseconds for a few hundred nodes.

## Notes (enrichment)

Once you've been away from the keyboard and mouse for a minute, the engine takes up to 8 files at a time that have no note yet. It backs off on low power or a serious or critical thermal state, and waits 400 ms between files. `TextExtractor` pulls an excerpt:
- plain text: up to 16 KB, skipping binary files;
- PDFs: the first 3 pages through PDFKit;
- docx and rtf: via `NSAttributedString`;
- pptx and xlsx: text runs from their zip archives;
- images: Vision's fast text recognition.

Images are scaled down to 2,048 px before OCR. Vision keeps its text-recognition model (about 200 MB) in memory until it has been idle for a few seconds, so after a batch with images the engine waits 20 s instead of 2 s, and the memory is returned between batches.

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
- indexing: versions, projects, renames, deletes, folders moved in, notes, re-reading edited documents;
- collections and large-tree folding;
- the v2 → v3 migration;
- **sorting** (`InboxTests`): suggestions from similar files, the 10-minute settle, moves that keep the file's identity, undo, keep, learning from where you put the last download from a site, and noticing files you filed yourself;
- **the map**: projects, files and shared topics, and a deterministic layout;
- **time and talk**: "two days ago", "on Monday", "the other day", and the long, rambling question about a big download;
- **search quality** (`SearchQualityTests`). A messy made-up home folder holds:
  - a startup's pitch deck in three versions;
  - a busy code project whose file names overlap the questions;
  - a cluttered Downloads folder and scans with meaningless names;
  - Blender scenes next to newer generic 3D downloads;
  - coursework, taxes and a trip.

  56 everyday questions each name the file they mean: plain names, app names, half-typed words, typos, rambling questions, and things only inside the document. The suite prints a report and fails below 90% right-first.

```
top-1 55/56 · top-3 56/56 · MRR 0.99 · slowest 3 ms      (0.2.0 on the first 48: top-1 22/48 · top-3 33/48 · MRR 0.57)
```

None of these tests need the on-device model, so they run in CI. The model's choices were checked by hand with `trail ask` and `trail inbox` against the demo home.

The miss is "lease": `Lease.tsx`, a component in the code project, ranks above the scanned lease agreement, which ranks third. It stays in the set as a known trade-off.

`TRAIL_PERF=1 swift test --filter SearchSpeed` builds a 50,000-entry index, 12,500 entries of it with document text and word frequencies that follow a natural curve, and times searches:
- ordinary words, prefixes and multi-word questions: 1–15 ms;
- a word in nearly every file, or a typo: 25–40 ms.

On a real Mac (49,700 entries, 4,000 documents with text), warm searches take 2–17 ms.

Getting there took three fixes, each found by timing the stages:
- **Separate text index.** Document text lives in its own index, so names stay fast to match.
- **Word sets.** Each word's matching rowids come back as plain integers and are combined in Swift. This replaced re-scanning the text index with a list of ids, which SQLite can't push into FTS5.
- **Byte-level names.** File names are tokenized at the byte level for the name-match score.

CI runs them on GitHub's `macos-26` runners and builds the app on every push. Tagged pushes also build a DMG and publish a release.

## Demo recordings

`make demo` regenerates the README GIFs without showing anyone's real files:
1. `scripts/demo/make-home.swift` builds a made-up home folder:
   - a startup pitch with three deck versions;
   - taxes and a Lisbon trip;
   - downloads with real `WhereFroms` and quarantine tags;
   - a screenshot of a ticket confirmation for OCR to read;
   - a git project and a burst of renders.
2. The CLI indexes that folder. `TRAIL_USER_HOME` makes the engine treat it as `~`, so paths read `~/Documents/Thermal`.
3. The app runs with `TRAIL_DEMO=<scene.json>` and plays the scene: show the panel, type with uneven timing, press keys. It never takes keyboard focus, so you can keep working while it records.
4. `scripts/demo/capture.swift` records the region with ScreenCaptureKit, without the pointer, and ffmpeg turns it into a GIF.
