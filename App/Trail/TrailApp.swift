import SwiftUI
import TrailCore

@main
struct TrailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: appDelegate.model, showPanel: { appDelegate.panel?.show() })
        } label: {
            // A quiet count of new files to sort, instead of notifications.
            if appDelegate.model.inboxCount > 0 {
                Label { Text("\(appDelegate.model.inboxCount)") } icon: { Image(nsImage: TrailApp.menuBarMark) }
                    .labelStyle(.titleAndIcon)
            } else {
                Image(nsImage: TrailApp.menuBarMark)
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }

    /// The trail of dots as a template image, so the menu bar tints it.
    static let menuBarMark: NSImage = {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: true) { rect in
            for (point, radius, alpha) in TrailMark.dots(in: rect.size) {
                NSColor.black.withAlphaComponent(alpha).setFill()
                NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

struct MenuBarContent: View {
    let model: AppModel
    let showPanel: () -> Void

    var body: some View {
        if model.inboxCount > 0 {
            Button("Sort \(model.inboxCount) New \(model.inboxCount == 1 ? "File" : "Files")…") { model.showSort?() }
            Divider()
        }
        Button("Find…", action: showPanel)
            .keyboardShortcut(model.hotKey.menuKey, modifiers: model.hotKey.menuModifiers)
        Button("Map") { model.showMap?() }
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
