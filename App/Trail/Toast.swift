import AppKit
import SwiftUI

/// A small note under the menu bar that fades on its own. It never takes focus,
/// so it can't interrupt typing. Click it to open the search panel.
@MainActor
final class ToastController {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    /// When set (demo recordings), the note is centered in this rect instead of sitting under the menu bar.
    var anchor: NSRect?

    static let size = NSSize(width: 320, height: 96)

    func show(title: String, lines: [String], loading: Bool = false, duration: Duration = .seconds(8), onClick: @escaping () -> Void) {
        hide(animated: false)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: ToastView(title: title, lines: lines, loading: loading) { [weak self] in
            self?.hide(animated: true)
            onClick()
        })

        let screen = NSScreen.main ?? NSScreen.screens.first
        if let anchor {
            panel.setFrameOrigin(NSPoint(x: anchor.midX - Self.size.width / 2, y: anchor.midY - Self.size.height / 2))
        } else if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - Self.size.width - 12, y: frame.maxY - Self.size.height - 8))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide(animated: true)
        }
    }

    func hide(animated: Bool) {
        dismissTask?.cancel()
        guard let panel else { return }
        self.panel = nil
        guard animated else { panel.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.6
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}

struct ToastView: View {
    let title: String
    let lines: [String]
    var loading = false
    let onClick: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TrailMark(size: 16)
                .foregroundStyle(.primary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                DecodeText(text: title, duration: 0.6)
                    .font(Theme.mono(12.5, .semibold))
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if loading {
                    ShadeBar(width: 22)
                        .font(Theme.mono(9))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: ToastController.size.width - 12, height: ToastController.size.height - 12, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .contentShape(.rect)
        .onTapGesture(perform: onClick)
        .frame(width: ToastController.size.width, height: ToastController.size.height)
    }
}
