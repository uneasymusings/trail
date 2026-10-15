# Changelog

## 0.3.0 (2026-10-14)

**Sorting.** New screenshots and downloads on the Desktop and in Downloads get a suggested home. Trail reads each one (on-device OCR for screenshots), finds where similar files live in the graph, notes what you were working on when it arrived and where you put similar files before, and lets the on-device model choose among those real folders. The menu bar shows how many are waiting; ↩ moves, ⇥ picks another folder, ⌫ keeps it, ⌘Z undoes. Nothing moves until you say so, and moved files keep their history in the graph.

**The model answers questions.** For questions of 3 or more words, the on-device model reads the question and the top results (kind, age, folder, project, versions, source, notes) and chooses the one you mean. It answers with a number from the list, so it can't invent a file. It also reads questions people actually ask: "that big file we downloaded about two days ago", "on Monday", "the other day".

**Map.** A view of the knowledge graph: projects and their newest files, the topics they share, where downloads came from, and which projects you work on together.

- App names mean their files: "blender" finds `.blend` scenes, "keynote" `.key` decks, "figma" `.fig` files (used to be a filter for any 3D model, document or design, with the word thrown away).
- Real English words are never "corrected" into something else.

Search, reworked. On a benchmark of 48 everyday questions over a messy made-up home folder, the right file now comes first 47 times (was 22) and is in the top three every time (was 33).

- Searches inside documents: PDFs, Word, text, Markdown, slides and spreadsheets. A background reader indexes the first 6,000 characters of each, newest first, and re-reads files when they change.
- Typos are fixed against your own files ("thermla" → "thermal"), and the panel says so.
- "w2" finds `W-2.pdf` and "1099" finds `1099-INT.pdf`.
- Asking for a particular version ("pitch v2", "paper draft") shows that version instead of the newest.
- A file with every word you typed always ranks above one with only some of them.
- Ranking blends text match, name match, recency and how often you open a file from Trail, and prefers documents over source files that share a name.
- When a kind or time filter ("slides", "last week") would leave nothing, it's loosened rather than showing an empty list.
- The search index keeps no second copy of names and text, so it stays small: adding document text grew a 34 MB index by only a few MB.
- Fixed: reading text in screenshots kept Vision's model (about 200 MB) loaded for as long as there were images to note. Trail now pauses after image batches so the memory is returned.
- `SearchQualityTests` (the benchmark) and an opt-in speed test on a 50,000-entry index: `TRAIL_PERF=1 swift test --filter SearchSpeed`.

## 0.2.0 (2026-10-14)

- Search understands plurals and word forms ("taxes" finds "tax") through FTS5 stemming. Existing indexes migrate on launch, in the background.
- "What was I working on today?" no longer treats "today" as a search word.
- The model can't sneak kind words like "pdfs" back in as keywords.
- After the first scan, and after the stemming migration, Trail compacts its index and releases the scan's caches.
- `make setup`, `make demo` and `make help`.
- A demo mode and recording scripts that produce the README GIFs from a made-up home folder.

## 0.1.0 (2026-10-14)

First release.

- Menu-bar app with a ⌥Space glass search panel, a desktop widget and a `trail` CLI.
- Watches the home folder with FSEvents and replays changes made while it was closed.
- Knowledge graph in SQLite: projects, version chains, origins (downloads, AI tools), tags, activity.
- Generated output (renders, test screenshots) folds into single entries.
- Apple's on-device model reads longer questions and writes one-line notes while idle.
- Quiet first run: a small note under the menu bar, no windows. ASCII motion only while loading.
