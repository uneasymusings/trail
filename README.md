<p align="center">
  <img src="App/Trail/Assets.xcassets/AppIcon.appiconset/icon-256.png" width="128" alt="Trail icon">
</p>

<h1 align="center">Trail</h1>

<p align="center">A private map of the files on your Mac. Press <kbd>⌥</kbd><kbd>Space</kbd> and ask.</p>

---

Trail watches your Mac and builds a small knowledge graph of your files as you create, download or save them. You can save them yourself, through an app, or with an AI tool. It records which project each file belongs to, its earlier versions, where it came from, and what it's about. Then it answers questions like:

- *"What's the latest file I worked on for the Thermal pitch?"*
- *"PDFs I downloaded last week about taxes"*
- *"What was I working on yesterday?"*

Results appear as you type, in about 5 ms. Everything stays on your Mac. The only model involved is Apple's on-device model, and the app makes no network calls.

## How it works

```
 FSEvents (whole home folder) ─► filter + batch ─► graph (SQLite + full-text index)
                                                        ▲          │
                         on-device model, idle only ────┘          ▼
                         (one-line notes + tags)          ⌥Space panel · widget · CLI
```

- **Watching:** FSEvents streams every change under your home folder, including iCloud Drive and Dropbox. It replays anything that changed while Trail wasn't running.
- **The graph:** files, projects, version chains, tags and activity events, stored in one SQLite file. On a heavy developer Mac, 400,000 files on disk came to about 47,000 entries and 47 MB.
- **Projects:** a git repository or package folder counts as a project. Otherwise, the first folder inside Documents, Desktop, iCloud and similar places does. For example, `~/Documents/Taxes 2026/w2.pdf` belongs to "Taxes 2026".
- **Versions:** `Pitch v2.key`, `Pitch (1).key`, `pitch_final.key` and `Pitch 2026-10-14.key` are linked into one chain, and searches show the newest.
- **Origin:** downloads are recognized by their source URL or the app that brought them in. Files from AI tools (Claude, ChatGPT, Cursor and others) are recognized by app and folder. macOS doesn't record which process wrote a file, so this is a best guess.
- **Generated output:** a folder of hundreds of renders, screenshots or test artifacts becomes a single entry, such as "verification: 105,410 files, mostly PNG images", plus its three newest files. Your map stays readable.
- **The model:** Apple's on-device Foundation Model. It turns your question into a structured search and writes short notes about new documents when the Mac is idle. A simple built-in parser answers first, so search never waits on the model. Without Apple Intelligence, Trail still works; it just doesn't write notes.

## Install

Requires macOS 26 (Tahoe) on Apple silicon. Apple Intelligence is optional.

```sh
# Homebrew
brew install --cask uneasymusings/trail/trail

# or the install script
curl -fsSL https://raw.githubusercontent.com/uneasymusings/trail/main/scripts/install.sh | bash
```

On first launch Trail puts a small mark in the menu bar, shows a short note in the corner, and starts mapping your files at low priority. It never opens a window on its own. Grant **Full Disk Access** in System Settings → Privacy & Security; without it, macOS asks separately for Desktop, Documents and Downloads.

Releases are not notarized yet, so Homebrew's copy shows macOS's "unidentified developer" warning the first time: open it from System Settings → Privacy & Security → **Open Anyway**. The install script and building from source don't hit this.

### Build from source

Needs Xcode 26 and XcodeGen (`brew install xcodegen`).

```sh
git clone https://github.com/uneasymusings/trail && cd trail
make install                    # ad-hoc signed; everything except the desktop widget
make install TEAM=ABCDE12345    # signed with your Apple Development team; includes the widget
```

The widget reads its data from a shared app-group folder, and macOS only allows that for apps signed with a real team. Your team ID is the `OU` field of your Apple Development certificate.

## Use it

| | |
|---|---|
| <kbd>⌥</kbd><kbd>Space</kbd> | Open or close the panel (you can change this in Settings) |
| <kbd>↑</kbd> <kbd>↓</kbd> | Move through results |
| <kbd>↩</kbd> | Open the file |
| <kbd>⌘</kbd><kbd>↩</kbd> | Show it in Finder |
| <kbd>⇥</kbd> | Related: versions, files edited in the same session, shared topics |
| <kbd>⇧</kbd><kbd>⌘</kbd><kbd>C</kbd> | Copy the path |

**Widget:** right-click the desktop → Edit Widgets → Trail. It shows the latest file in each recent project, with an **Ask** button.

**Shortcuts and links:** `trail://ask?q=invoice` opens the panel with a query.

### Command line

```sh
make install-cli
trail ask "latest file for the portfolio"
trail find golf menu          # instant search, no model
trail recent 20
trail projects
trail related ~/Documents/Pitch\ v3.key
trail stats
trail compact                 # fold bulky generated folders, reclaim space
```

The CLI and the app share the same index in `~/Library/Application Support/Trail`. Set `TRAIL_HOME` to keep a separate one.

## Privacy

- The index is stored only in `~/Library/Application Support/Trail`. Delete that folder to forget everything.
- Trail never uploads anything. The model runs on your Mac through Apple's Foundation Models framework.
- It reads at most the first few kilobytes of documents, PDFs, slides and screenshots (using on-device text recognition) to write notes. It never reads code or data files.
- Caches, hidden folders, `node_modules`, build output, app bundles and `~/Library` are skipped, except iCloud Drive and cloud-storage folders. You can add more folders to skip in Settings → Folders.

## Project layout

```
Sources/TrailCore/    the engine: watcher, indexer, graph, search, model (Swift package, no dependencies)
Sources/trail/        the CLI
Tests/                Swift Testing suites (swift test)
App/                  menu-bar app, search panel, settings, widget (XcodeGen project.yml)
scripts/              icon, DMG and install scripts
Casks/                Homebrew cask template
```

## Releasing

Tag `vX.Y.Z` and push. CI builds an ad-hoc signed DMG and attaches it to a GitHub release. To get rid of the "unidentified developer" warning, notarize the app. That needs a Developer ID certificate from the Apple Developer Program ($99 a year) and the secrets listed in `.github/workflows/ci.yml`. Then update `Casks/trail.rb` with the new version and its sha256.

## Roadmap

- [ ] A downloadable fallback model (LFM2.5-350M via llama.cpp) for Macs without Apple Intelligence
- [ ] Semantic search with on-device embeddings
- [ ] A visual graph view of projects and their files
- [ ] Watching external drives

## License

MIT
