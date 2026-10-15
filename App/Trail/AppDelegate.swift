import AppKit
import TrailCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private(set) var panel: SearchPanelController?
    private(set) var sortPanel: SortPanelController?
    private(set) var mapWindow: MapWindowController?
    private var hotKey: HotKey?
    private let toast = ToastController()

    private var demo: DemoDirector?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.start()
        let panel = SearchPanelController(model: model)
        self.panel = panel
        let sortPanel = SortPanelController(model: model)
        self.sortPanel = sortPanel
        model.showSort = { [weak self] in
            self?.panel?.hide()
            self?.sortPanel?.show()
        }
        let mapWindow = MapWindowController(app: model)
        self.mapWindow = mapWindow
        model.showMap = { [weak self] in
            self?.panel?.hide()
            self?.mapWindow?.show()
        }

        if DemoDirector.isActive {
            demo = DemoDirector(panel: panel, sort: sortPanel, map: mapWindow, toast: toast, model: model)
            demo?.run()
            return
        }
        registerHotKey()
        model.onHotKeyChange = { [weak self] in self?.registerHotKey() }

        model.onScanFinished = { [weak self] in self?.announceMapReady() }

        // First launch: a quiet note under the menu bar instead of a window in your face.
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            model.enableLaunchAtLogin()
            toast.show(title: "Trail is mapping your files",
                       lines: ["\(model.hotKey.label) to search. It lives in the menu bar."], loading: true) { [weak self] in
                self?.panel?.show()
            }
        }
    }

    /// Once, after the very first scan.
    private func announceMapReady() {
        guard !UserDefaults.standard.bool(forKey: "announcedMap"), let stats = model.stats else { return }
        UserDefaults.standard.set(true, forKey: "announcedMap")
        toast.show(title: "Your map is ready",
                   lines: ["\(stats.files.formatted()) files · \(stats.projects.formatted()) projects",
                           "\(model.hotKey.label) to search"]) { [weak self] in
            self?.panel?.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.engine?.stop()
    }

    private func registerHotKey() {
        let choice = model.hotKey
        hotKey = HotKey(keyCode: choice.keyCode, modifiers: choice.carbonModifiers) { [weak self] in
            self?.panel?.toggle()
        }
    }

    /// trail://ask?q=…   opens the panel (used by the widget and Shortcuts)
    /// trail://open?path=…   opens an indexed file
    /// trail://sort   opens the sort panel
    /// trail://map   opens the map
    /// trail://hide   closes the panels
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "trail" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let value = { (name: String) in query?.first { $0.name == name }?.value }
            switch url.host() {
            case "open":
                if let path = value("path") { model.open(path: path, reveal: false) }
            case "reveal":
                if let path = value("path") { model.open(path: path, reveal: true) }
            case "hide":
                panel?.hide()
                sortPanel?.hide()
            case "sort":
                model.showSort?()
            case "map":
                model.showMap?()
            default:
                panel?.show(query: value("q"))
            }
        }
    }
}
