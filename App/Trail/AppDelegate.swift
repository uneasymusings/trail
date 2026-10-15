import AppKit
import TrailCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private(set) var panel: SearchPanelController?
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.start()
        let panel = SearchPanelController(model: model)
        self.panel = panel
        registerHotKey()
        model.onHotKeyChange = { [weak self] in self?.registerHotKey() }

        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            model.enableLaunchAtLogin()
            panel.show()
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
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "trail" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            let value = { (name: String) in query?.first { $0.name == name }?.value }
            switch url.host() {
            case "open":
                if let path = value("path") { model.open(path: path, reveal: false) }
            case "reveal":
                if let path = value("path") { model.open(path: path, reveal: true) }
            default:
                panel?.show(query: value("q"))
            }
        }
    }
}
