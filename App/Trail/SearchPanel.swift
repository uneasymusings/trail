import AppKit
import SwiftUI
import TrailCore

/// A borderless floating panel that takes keyboard focus without activating the app,
/// like Spotlight. It hides itself when you click elsewhere.
final class SearchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SearchPanelController: NSObject, NSWindowDelegate {
    private let panel: SearchPanel
    private let search: SearchModel

    static let size = NSSize(width: 720, height: 600)

    init(model: AppModel) {
        search = SearchModel(app: model)
        panel = SearchPanel(contentRect: NSRect(origin: .zero, size: Self.size))
        super.init()
        let host = NSHostingView(rootView: SearchView(model: search, app: model, dismiss: { [weak self] in self?.hide() }))
        host.sizingOptions = []
        panel.contentView = host
        panel.delegate = self
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show(query: String? = nil) {
        if let query { search.query = query }
        search.prepare()
        position()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.panel.orderOut(nil)
                self?.search.didHide()
            }
        })
    }

    /// Centered on the screen with the pointer, a little above the middle.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: frame.midX - Self.size.width / 2,
                             y: frame.maxY - frame.height * 0.18 - Self.size.height)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}
