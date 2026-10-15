import SwiftUI
import TrailCore

@main
struct TrailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: appDelegate.model, showPanel: { appDelegate.panel?.show() })
        } label: {
            Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath.fill")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}

struct MenuBarContent: View {
    let model: AppModel
    let showPanel: () -> Void

    var body: some View {
        Button("Find…", action: showPanel)
            .keyboardShortcut(model.hotKey.menuKey, modifiers: model.hotKey.menuModifiers)
        Divider()
        Text(model.statusLine)
        if !model.hasFullDiskAccess {
            Button("Grant Full Disk Access…") { model.openFullDiskAccessSettings() }
        }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Trail") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
