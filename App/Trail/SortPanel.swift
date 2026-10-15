import AppKit
import Observation
import QuickLookThumbnailing
import SwiftUI
import TrailCore

/// Drives the sort panel: the files waiting on the Desktop and in Downloads, the folder chosen
/// for the selected one, and the last move (for undo). Nothing moves without a key press.
@Observable @MainActor
final class SortModel {
    private(set) var items: [InboxItem] = []
    private(set) var isLoading = false
    var selection = 0
    /// Which suggested folder is chosen for the selected file (⇥ cycles).
    var choice = 0
    private(set) var lastMove: (item: InboxItem, path: String, folder: String)?
    private(set) var error: String?
    private var statusTask: Task<Void, Never>?

    let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    var selected: InboxItem? { items.indices.contains(selection) ? items[selection] : nil }

    var chosen: Destination? {
        guard let selected, selected.destinations.indices.contains(choice) else { return nil }
        return selected.destinations[choice]
    }

    func load() {
        guard let engine = app.engine else { return }
        isLoading = items.isEmpty
        Task.detached(priority: .userInitiated) {
            let items = (try? engine.inbox.items()) ?? []
            await MainActor.run {
                let selectedID = self.selected?.id
                self.items = items
                self.selection = items.firstIndex { $0.id == selectedID } ?? min(self.selection, max(0, items.count - 1))
                if self.selected?.id != selectedID { self.choice = 0 }
                self.isLoading = false
            }
        }
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selection = (selection + delta + items.count) % items.count
        choice = 0
    }

    func select(_ index: Int) {
        guard index != selection else { return }
        selection = index
        choice = 0
    }

    func cycleChoice() {
        guard let count = selected?.destinations.count, count > 1 else { return }
        choice = (choice + 1) % count
    }

    /// Moves the selected file to the chosen folder, or to `folder`.
    func move(to folder: String? = nil) {
        guard let item = selected, let engine = app.engine, let folder = folder ?? chosen?.path else { return }
        do {
            let path = try engine.sort(item, to: folder)
            withAnimation(Theme.ease) {
                items.removeAll { $0.id == item.id }
                selection = min(selection, max(0, items.count - 1))
                choice = 0
            }
            showStatus((item, path, Destination(path: folder, reason: "", byModel: false).label))
        } catch {
            self.error = "Couldn't move \(item.file.name): \(error.localizedDescription)"
        }
    }

    /// Lets you pick any folder, starting where Trail would have put it.
    func chooseFolder() {
        guard let item = selected else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.prompt = "Move Here"
        picker.message = "Where should \(item.file.name) go?"
        picker.directoryURL = URL(fileURLWithPath: chosen?.path ?? TrailPaths.home + "/Documents")
        NSApp.activate()
        guard picker.runModal() == .OK, let url = picker.url else { return }
        move(to: url.path)
    }

    func keep() {
        guard let item = selected, let engine = app.engine else { return }
        engine.keep(item)
        withAnimation(Theme.ease) {
            items.removeAll { $0.id == item.id }
            selection = min(selection, max(0, items.count - 1))
            choice = 0
        }
    }

    func undo() {
        guard let move = lastMove, let engine = app.engine else { return }
        do {
            try engine.undoSort(move.item, from: move.path)
            withAnimation(Theme.ease) {
                items.insert(move.item, at: min(selection, items.count))
                selection = items.firstIndex { $0.id == move.item.id } ?? 0
            }
            lastMove = nil
        } catch {
            self.error = "Couldn't put it back: \(error.localizedDescription)"
        }
    }

    private func showStatus(_ move: (item: InboxItem, path: String, folder: String)) {
        lastMove = move
        error = nil
        statusTask?.cancel()
        statusTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(Theme.quick) { lastMove = nil }
        }
    }

    func didHide() {
        lastMove = nil
        error = nil
    }
}

/// Same kind of panel as search: floats, takes keys without activating the app.
final class SortPanel: SearchPanel {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

@MainActor
final class SortPanelController: NSObject, NSWindowDelegate {
    private let panel: SortPanel
    let sort: SortModel
    var anchor: NSRect?

    static let size = NSSize(width: 660, height: 560)

    init(model: AppModel) {
        sort = SortModel(app: model)
        panel = SortPanel(contentRect: NSRect(origin: .zero, size: Self.size))
        super.init()
        let host = NSHostingView(rootView: SortView(model: sort, dismiss: { [weak self] in self?.hide() }))
        host.sizingOptions = []
        panel.contentView = host
        panel.delegate = self
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
    }

    var isVisible: Bool { panel.isVisible }

    func show(takeFocus: Bool = true) {
        sort.load()
        position()
        panel.alphaValue = 0
        if takeFocus { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
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
                self?.sort.didHide()
            }
        })
    }

    /// ↑↓ select · ↩ move · ⇥ next suggestion · ⌘↩ choose a folder · ⌫ keep here · ⌘Z undo · esc close
    func handle(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 125: sort.moveSelection(1)
        case 126: sort.moveSelection(-1)
        case 48: sort.cycleChoice()
        case 36, 76: command ? sort.chooseFolder() : sort.move()
        case 51, 117: sort.keep()
        case 53: hide()
        default:
            guard command, event.charactersIgnoringModifiers == "z" else { return false }
            sort.undo()
        }
        return true
    }

    private func position() {
        if let anchor {
            panel.setFrame(NSRect(x: anchor.midX - Self.size.width / 2, y: anchor.maxY - 50 - Self.size.height,
                                  width: Self.size.width, height: Self.size.height), display: true)
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: frame.midX - Self.size.width / 2, y: frame.maxY - frame.height * 0.18 - Self.size.height)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        // The folder picker takes focus for a moment; don't vanish behind it.
        if NSApp.modalWindow == nil { hide() }
    }
}

// MARK: - View

struct SortView: View {
    let model: SortModel
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            card
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: SortPanelController.size.width, height: SortPanelController.size.height, alignment: .top)
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            content
                .frame(maxHeight: 400)
            Divider().opacity(0.4)
            footer
        }
        .frame(width: 620)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .shadow(color: .black.opacity(0.14), radius: 20, y: 10)
        .animation(Theme.ease, value: model.items.map(\.id))
        .animation(Theme.quick, value: model.selection)
        // A file finished reading, or arrived, while the panel is open.
        .onChange(of: model.app.changes) { model.load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("New files")
                .font(.system(size: 19, weight: .semibold))
            Text(model.items.isEmpty ? "Desktop and Downloads" : "\(model.items.count) on your Desktop and in Downloads")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Text("Nothing moves until you say so")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 22)
        .frame(height: 58)
    }

    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            VStack(spacing: 10) {
                if model.isLoading {
                    BrailleSpinner().font(Theme.mono(16)).foregroundStyle(.secondary)
                } else {
                    TrailMark().frame(width: 30, height: 30).foregroundStyle(.secondary)
                    Text("All sorted").font(.system(size: 14, weight: .medium))
                    Text("New screenshots and downloads show up here, with where they probably belong.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            SortRow(item: item, isSelected: index == model.selection,
                                    choice: index == model.selection ? model.choice : 0,
                                    choose: { destination in
                                        model.select(index)
                                        model.choice = destination
                                    },
                                    move: { model.select(index); model.move() },
                                    pickFolder: { model.select(index); model.chooseFolder() })
                                .id(item.id)
                                .contentShape(.rect)
                                .onTapGesture { model.select(index) }
                        }
                    }
                    .padding(10)
                }
                .scrollIndicators(.never)
                .onChange(of: model.selection) { withAnimation(Theme.quick) { proxy.scrollTo(model.selected?.id) } }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let move = model.lastMove {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                Text("Moved \(move.item.file.name) to \(move.folder)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Undo") { model.undo() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                KeyHint(keys: "⌘Z", label: "")
            } else if let error = model.error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red).lineLimit(1)
            } else {
                KeyHint(keys: "↩", label: "Move")
                KeyHint(keys: "⇥", label: "Other folder")
                KeyHint(keys: "⌘↩", label: "Choose…")
                KeyHint(keys: "⌫", label: "Keep here")
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 30)
        .transition(.opacity)
    }
}

struct SortRow: View {
    let item: InboxItem
    let isSelected: Bool
    let choice: Int
    let choose: (Int) -> Void
    let move: () -> Void
    let pickFolder: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Thumbnail(path: item.file.path, size: 52)
                .onTapGesture(count: 2) { NSWorkspace.shared.open(item.file.url) }
                .help("Double-click to open")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.file.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(Theme.age(item.arrived))
                        .font(Theme.mono(11))
                        .foregroundStyle(.secondary)
                }
                if let gist = item.gist {
                    Text(gist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(isSelected ? 2 : 1)
                }
                destination
                if isSelected, item.destinations.count > 1 || item.isRead {
                    alternatives
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.08) : .clear)
        }
    }

    @ViewBuilder
    private var destination: some View {
        if !item.isRead {
            HStack(spacing: 6) {
                BrailleSpinner().font(Theme.mono(11))
                Text("Reading…").font(.system(size: 11.5))
            }
            .foregroundStyle(.tertiary)
        } else if let chosen = item.destinations.indices.contains(choice) ? item.destinations[choice] : nil {
            HStack(spacing: 6) {
                Text("→").font(Theme.mono(12, .medium)).foregroundStyle(.secondary)
                Text(chosen.label).font(.system(size: 12, weight: .semibold))
                Text(chosen.reason)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if chosen.byModel {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .help("Chosen by the on-device model")
                }
            }
        } else {
            Text("No obvious home yet. ⌘↩ to choose one.")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
    }

    private var alternatives: some View {
        HStack(spacing: 6) {
            ForEach(Array(item.destinations.enumerated()), id: \.offset) { index, destination in
                Button { index == choice ? move() : choose(index) } label: {
                    Text(destination.label)
                        .font(.system(size: 11.5, weight: index == choice ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(index == choice ? Color.primary.opacity(0.12) : Color.primary.opacity(0.04)))
                }
                .buttonStyle(.plain)
                .help(destination.displayPath)
            }
            Button(action: pickFolder) {
                Text("Choose…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }
}

/// A Quick Look thumbnail (the actual screenshot or first page), falling back to the file icon.
struct Thumbnail: View {
    let path: String
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            } else {
                FileIcon(path: path, size: size * 0.8)
            }
        }
        .frame(width: size, height: size)
        .task(id: path) {
            let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: size, height: size),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
            if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = thumbnail.nsImage
            }
        }
    }
}
