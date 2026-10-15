import AppKit
import Observation
import TrailCore

/// Drives the panel: instant results on every keystroke, then a model-refined answer
/// once you pause.
@Observable @MainActor
final class SearchModel {
    var query = "" {
        didSet { if query != oldValue { schedule() } }
    }
    private(set) var response: SearchResponse?
    private(set) var isThinking = false
    var selection = 0
    /// Only keyboard moves scroll the list; hovering never does.
    private(set) var selectionFromKeyboard = false
    /// The panel can open under a resting pointer. Hover selects only after the mouse really moves.
    var pointerMoved = false
    /// When set, the panel shows this file's neighbourhood in the graph instead of results.
    private(set) var detail: (file: FileRecord, related: Related)?
    var focusToken = 0

    let app: AppModel
    private var quickTask: Task<Void, Never>?
    private var askTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
    }

    var hits: [SearchHit] { response?.hits ?? [] }

    /// Files shown in the list right now, for keyboard navigation.
    var visibleFiles: [FileRecord] {
        if let detail {
            return detail.related.versions + detail.related.sameSession + detail.related.sameTopics + detail.related.sameProject
        }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return homeFiles
        }
        return hits.map(\.file)
    }

    /// The newest file from each recently active project, shown before you type.
    var homeFiles: [FileRecord] {
        Array(app.recentProjects.compactMap(\.latest.first).prefix(6))
    }

    var selectedFile: FileRecord? {
        let files = visibleFiles
        return files.indices.contains(selection) ? files[selection] : nil
    }

    func prepare() {
        app.refresh(force: true)
        app.engine?.intelligence.prewarm()
        focusToken += 1
    }

    func didHide() {
        pointerMoved = false
        detail = nil
        query = ""
        selection = 0
    }

    private func schedule() {
        quickTask?.cancel()
        askTask?.cancel()
        isThinking = false
        detail = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let engine = app.engine, !text.isEmpty else {
            response = nil
            selection = 0
            return
        }

        quickTask = Task {
            let result = await Task.detached(priority: .userInitiated) { engine.quickSearch(text) }.value
            guard !Task.isCancelled else { return }
            response = result
            selection = 0
        }

        // Only questions are worth the model's time; single words are already handled well.
        let words = text.split(separator: " ").count
        guard words >= 3, engine.intelligence.isReady else { return }
        askTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isThinking = true
            let result = await engine.ask(text)
            guard !Task.isCancelled else { return }
            isThinking = false
            let selectedID = selectedFile?.id
            response = result
            selection = result.hits.firstIndex { $0.file.id == selectedID } ?? 0
        }
    }

    // MARK: - Actions

    func moveSelection(_ delta: Int) {
        let count = visibleFiles.count
        guard count > 0 else { return }
        selectionFromKeyboard = true
        selection = (selection + delta + count) % count
    }

    func hover(_ index: Int) {
        guard pointerMoved else { return }
        selectionFromKeyboard = false
        selection = index
    }

    func openSelection(reveal: Bool) -> Bool {
        guard let file = selectedFile else { return false }
        open(file, reveal: reveal)
        return true
    }

    func open(_ file: FileRecord, reveal: Bool = false) {
        app.engine?.recordOpen(file)
        if reveal || file.kind == .app {
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        } else {
            NSWorkspace.shared.open(file.url)
        }
    }

    func copyPath() {
        guard let file = selectedFile else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
    }

    func toggleDetail() {
        if detail != nil {
            detail = nil
            selection = 0
            return
        }
        guard let file = selectedFile, let engine = app.engine,
              let related = try? engine.search.related(to: file) else { return }
        detail = (file, related)
        selection = 0
    }
}
