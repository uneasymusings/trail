# Changelog

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
