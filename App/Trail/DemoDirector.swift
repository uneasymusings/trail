import AppKit
import SwiftUI

/// Plays a scripted scene for the README recordings (`scripts/demo/record.sh`).
/// Only active when `TRAIL_DEMO` points at a scene file. The panel is shown without taking
/// keyboard focus and the "typing" is simulated, so recording never steals your keyboard.
@MainActor
final class DemoDirector {
    struct Scene: Decodable {
        var steps: [Step]
    }

    struct Step: Decodable {
        var wait: Double?
        var show: Bool?
        var hide: Bool?
        var type: String?
        var clear: Bool?
        var key: String?
        var toast: String?
        /// Show or hide the sort panel, or press a key in it: "down", "tab", "return", "keep", "undo".
        var sort: String?
        /// "show" or "hide" the map, or the name of a node to hover.
        var map: String?
    }

    static var sceneURL: URL? {
        ProcessInfo.processInfo.environment["TRAIL_DEMO"].map { URL(fileURLWithPath: $0) }
    }

    static var isActive: Bool { sceneURL != nil }

    /// "x,y,width,height" in screen points from the top-left of the main display.
    static var stageRect: NSRect {
        let numbers = (ProcessInfo.processInfo.environment["TRAIL_DEMO_STAGE"] ?? "")
            .split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let screen = NSScreen.screens.first?.frame ?? .zero
        guard numbers.count == 4 else {
            return NSRect(x: screen.midX - 450, y: screen.midY - 300, width: 900, height: 620)
        }
        // Flip from top-left coordinates to AppKit's bottom-left ones.
        return NSRect(x: numbers[0], y: screen.maxY - numbers[1] - numbers[3], width: numbers[2], height: numbers[3])
    }

    private let panel: SearchPanelController
    private let sort: SortPanelController
    private let map: MapWindowController
    private let toast: ToastController
    private let model: AppModel
    private var stage: NSWindow?
    private var stageRect = NSRect.zero

    init(panel: SearchPanelController, sort: SortPanelController, map: MapWindowController, toast: ToastController, model: AppModel) {
        self.panel = panel
        self.sort = sort
        self.map = map
        self.toast = toast
        self.model = model
    }

    func run() {
        guard let url = Self.sceneURL, let data = try? Data(contentsOf: url),
              let scene = try? JSONDecoder().decode(Scene.self, from: data) else {
            FileHandle.standardError.write("trail: couldn't read demo scene\n".data(using: .utf8)!)
            NSApp.terminate(nil)
            return
        }
        let rect = Self.stageRect
        stageRect = rect
        showStage(rect)
        panel.anchor = rect
        sort.anchor = rect
        toast.anchor = rect

        Task {
            for step in scene.steps { await play(step) }
        }
    }

    private func play(_ step: Step) async {
        if let wait = step.wait { try? await Task.sleep(for: .seconds(wait)) }
        if step.show == true { panel.show(takeFocus: false) }
        if step.hide == true { panel.hide() }
        if step.clear == true { panel.search.query = "" }
        if let text = step.type {
            for character in text {
                panel.search.query.append(character)
                // Uneven, like real typing.
                try? await Task.sleep(for: .milliseconds(Int.random(in: 45...95) + (character == " " ? 40 : 0)))
            }
        }
        switch step.key {
        case "down": panel.search.moveSelection(1)
        case "up": panel.search.moveSelection(-1)
        case "tab": panel.search.toggleDetail()
        default: break
        }
        switch step.map {
        case nil: break
        case "show":
            map.show(in: stageRect.insetBy(dx: 30, dy: 30), activate: false)
            map.float()
        case "hide": map.hide()
        case "none": map.model.hover(named: nil)
        case let name?: map.model.hover(named: name)
        }
        switch step.sort {
        case "show": sort.show(takeFocus: false)
        case "hide": sort.hide()
        case "down": sort.sort.moveSelection(1)
        case "tab": sort.sort.cycleChoice()
        case "return": sort.sort.move()
        case "keep": sort.sort.keep()
        case "undo": sort.sort.undo()
        default: break
        }
        switch step.toast {
        case "first-run":
            toast.show(title: "Trail is mapping your files", lines: ["⌥Space to search. It lives in the menu bar."], loading: true) {}
        case "map-ready":
            let files = model.stats?.files ?? 0, projects = model.stats?.projects ?? 0
            toast.show(title: "Your map is ready", lines: ["\(files.formatted()) files · \(projects.formatted()) projects", "⌥Space to search"]) {}
        default: break
        }
    }

    /// A soft gradient behind the panel, standing in for a desktop.
    private func showStage(_ rect: NSRect) {
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isOpaque = true
        window.contentView = NSHostingView(rootView: DemoStage())
        window.orderFrontRegardless()
        stage = window
    }
}

struct DemoStage: View {
    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.62, 0.42], [1, 0.5], [0, 1], [0.45, 1], [1, 1]],
            colors: [
                Color(red: 0.11, green: 0.16, blue: 0.42), Color(red: 0.18, green: 0.36, blue: 0.66), Color(red: 0.5, green: 0.65, blue: 0.85),
                Color(red: 0.14, green: 0.24, blue: 0.55), Color(red: 0.36, green: 0.56, blue: 0.84), Color(red: 0.66, green: 0.78, blue: 0.93),
                Color(red: 0.16, green: 0.18, blue: 0.43), Color(red: 0.42, green: 0.44, blue: 0.77), Color(red: 0.89, green: 0.72, blue: 0.79),
            ]
        )
        .ignoresSafeArea()
    }
}
