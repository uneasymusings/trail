import AppKit
import Observation
import ServiceManagement
import TrailCore
import WidgetKit

/// App-wide state: owns the engine and everything the menu, panel and settings show.
@Observable @MainActor
final class AppModel {
    private(set) var engine: TrailEngine?
    private(set) var startupError: String?
    private(set) var phase: TrailEngine.Phase = .idle
    private(set) var stats: IndexStats?
    private(set) var modelStatus: Intelligence.Status = .unavailable("Starting")
    private(set) var hasFullDiskAccess = AppModel.checkFullDiskAccess()
    private(set) var recentProjects: [ProjectSummary] = []
    private(set) var config: TrailConfig = .default
    /// New files on the Desktop and in Downloads waiting to be sorted (shown on the menu bar).
    private(set) var inboxCount = 0
    /// Bumps whenever the engine reports a change, so open panels can reload.
    private(set) var changes = 0
    /// Opens the sort panel (set by the app delegate).
    var showSort: (() -> Void)?
    /// Opens the map window.
    var showMap: (() -> Void)?

    var onHotKeyChange: (() -> Void)?
    /// Called once the first full scan has finished and fresh stats are in.
    var onScanFinished: (() -> Void)?
    var hotKey: HotKeyChoice = HotKeyChoice(rawValue: UserDefaults.standard.string(forKey: "hotKey") ?? "") ?? .optionSpace {
        didSet {
            UserDefaults.standard.set(hotKey.rawValue, forKey: "hotKey")
            onHotKeyChange?()
        }
    }

    private var lastStatsRefresh = Date.distantPast
    private var lastWidgetReload = Date.distantPast

    func start() {
        do {
            let engine = try TrailEngine.open()
            engine.snapshotURL = DemoDirector.isActive ? nil : Self.widgetSnapshotURL
            engine.onChange = { [weak self] in self?.engineChanged() }
            self.engine = engine
            config = engine.config
            modelStatus = engine.intelligence.status
            engine.start()
            refresh(force: true)
            // Files settle into the count over time, without any event to say so.
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    self?.refreshInboxCount()
                }
            }
        } catch {
            startupError = "Couldn't open the index: \(error)"
        }
    }

    private func engineChanged() {
        changes += 1
        refresh()
        if Date().timeIntervalSince(lastWidgetReload) > 120 {
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Re-reads counts and recent projects. Throttled because indexing can fire often.
    func refresh(force: Bool = false) {
        guard let engine else { return }
        var finishedScan = false
        if case .scanning = phase, engine.phase == .watching { finishedScan = true }
        phase = engine.phase
        hasFullDiskAccess = Self.checkFullDiskAccess()
        modelStatus = engine.intelligence.status
        refreshInboxCount()
        guard force || finishedScan || Date().timeIntervalSince(lastStatsRefresh) > 3 else { return }
        lastStatsRefresh = Date()
        Task.detached(priority: .utility) {
            let stats = engine.stats()
            let projects = (try? engine.search.recentProjects(limit: 6, filesEach: 1)) ?? []
            await MainActor.run {
                self.stats = stats
                self.recentProjects = projects
                if finishedScan { self.onScanFinished?() }
            }
        }
    }

    func refreshInboxCount() {
        guard let engine else { return }
        Task.detached(priority: .utility) {
            let count = engine.config.suggestHomes ? engine.inbox.count() : 0
            await MainActor.run { if self.inboxCount != count { self.inboxCount = count } }
        }
    }

    var statusLine: String {
        if let startupError { return startupError }
        switch phase {
        case .idle: return "Starting…"
        case .scanning(let indexed): return "Scanning… \(indexed.formatted()) files"
        case .watching:
            guard let stats else { return "Watching" }
            return "\(stats.files.formatted()) files · \(stats.projects.formatted()) projects"
        }
    }

    func updateConfig(_ change: (inout TrailConfig) -> Void) {
        guard let engine else { return }
        var config = engine.config
        change(&config)
        engine.updateConfig(config)
        self.config = config
    }

    func rebuildIndex() {
        engine?.rebuild()
        refresh(force: true)
    }

    // MARK: - Files

    /// Opens a file Trail knows about. Links from the widget and the URL scheme go through here,
    /// so only indexed files are opened, and apps or scripts are revealed rather than launched.
    func open(path: String, reveal: Bool) {
        let url = URL(fileURLWithPath: path)
        let known = (try? engine?.search.file(path: path)) ?? nil
        guard let known, FileManager.default.fileExists(atPath: path) else {
            NSSound.beep()
            return
        }
        engine?.recordOpen(known)
        if reveal || [.app, .code, .archive].contains(known.kind) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Permissions and login

    /// The TCC database is readable only with Full Disk Access.
    static func checkFullDiskAccess() -> Bool {
        if DemoDirector.isActive { return true }
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let descriptor = Darwin.open(path, O_RDONLY)
        guard descriptor != -1 else { return false }
        close(descriptor)
        return true
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set { newValue ? enableLaunchAtLogin() : try? SMAppService.mainApp.unregister() }
    }

    func enableLaunchAtLogin() {
        try? SMAppService.mainApp.register()
    }

    // MARK: - Widget

    static var appGroup: String? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "TrailAppGroup") as? String,
              !group.isEmpty else { return nil }
        return group
    }

    static var widgetSnapshotURL: URL? {
        appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }?
            .appendingPathComponent(WidgetSnapshot.fileName)
    }
}
