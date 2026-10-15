import AppKit
import Observation
import SwiftUI
import TrailCore

/// The knowledge graph, drawn: projects, the topics and sources they share, and which ones you
/// work on together.
@Observable @MainActor
final class MapModel {
    private(set) var map: GraphMap?
    private(set) var positions: [String: SIMD2<Double>] = [:]
    var hovered: String?
    let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    func load() {
        guard let engine = app.engine else { return }
        Task.detached(priority: .userInitiated) {
            let map = (try? engine.search.map()) ?? GraphMap(nodes: [], edges: [])
            let positions = MapLayout.positions(for: map)
            await MainActor.run {
                withAnimation(Theme.ease) {
                    self.map = map
                    self.positions = positions
                }
            }
        }
    }

    /// Nodes linked to `id`, including itself.
    func neighbourhood(of id: String) -> Set<String> {
        var ids: Set<String> = [id]
        for edge in map?.edges ?? [] where edge.from == id || edge.to == id { ids.insert(edge.from); ids.insert(edge.to) }
        return ids
    }

    /// Hover a node by name (demo recordings).
    func hover(named name: String?) {
        hovered = name.flatMap { name in map?.nodes.first { $0.name.lowercased() == name.lowercased() }?.id }
    }

    func activate(_ node: GraphMap.Node) {
        switch node.kind {
        case .project, .file:
            if let path = node.path { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        case .topic, .source:
            var components = URLComponents(string: "trail://ask")!
            components.queryItems = [URLQueryItem(name: "q", value: node.name)]
            if let url = components.url { NSWorkspace.shared.open(url) }
        }
    }
}

@MainActor
final class MapWindowController: NSObject, NSWindowDelegate {
    let model: MapModel
    private var window: NSWindow?

    init(app: AppModel) {
        model = MapModel(app: app)
    }

    func show(in frame: NSRect? = nil, activate: Bool = true) {
        model.load()
        if window == nil {
            let window = NSWindow(contentRect: frame ?? NSRect(x: 0, y: 0, width: 980, height: 660),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 640, height: 440)
            window.contentView = NSHostingView(rootView: MapView(model: model))
            window.delegate = self
            if frame == nil { window.center() }
            self.window = window
        }
        if let frame { window?.setFrame(frame, display: true) }
        if activate {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    func hide() { window?.orderOut(nil) }

    /// Above the demo stage, which floats.
    func float() { window?.level = .floating }
}

struct MapView: View {
    let model: MapModel
    @State private var pointer: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let frame = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 90, dy: 80)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(in: &context, frame: frame) }
                    .onContinuousHover { phase in
                        if case .active(let point) = phase { model.hovered = node(near: point, frame: frame)?.id } else { model.hovered = nil }
                    }
                    .gesture(SpatialTapGesture().onEnded { value in
                        if let node = node(near: value.location, frame: frame) { model.activate(node) }
                    })
                header
                    .padding(.leading, 28)
                    .padding(.top, 34)
                legend
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(28)
                if model.map?.nodes.isEmpty == true {
                    Text("Your map fills in as Trail learns your projects.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(.ultraThinMaterial)
        .ignoresSafeArea()
        .animation(Theme.quick, value: model.hovered)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TrailMark().frame(width: 16, height: 16).foregroundStyle(.secondary)
                Text("Map").font(.system(size: 20, weight: .semibold))
            }
            if let map = model.map {
                let count = { (kind: GraphMap.NodeKind) in map.nodes.filter { $0.kind == kind }.count }
                let counted = { (n: Int, noun: String) in "\(n) \(noun)\(n == 1 ? "" : "s")" }
                Text([counted(count(.project), "project"), counted(count(.file), "file"), counted(count(.topic), "topic"),
                      counted(count(.source), "source"), counted(map.edges.count, "link")].joined(separator: " · "))
                    .font(Theme.mono(11))
                    .foregroundStyle(.primary.opacity(0.55))
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            LegendItem(symbol: "circle.fill", label: "Project")
            LegendItem(symbol: "smallcircle.filled.circle", label: "File")
            LegendItem(symbol: "circle", label: "Topic")
            LegendItem(symbol: "square", label: "Source")
            LegendItem(symbol: "line.diagonal", label: "Worked on together")
            Spacer()
            Text("Click to open · topics and sources search")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Drawing

    private func point(_ id: String, in frame: CGRect) -> CGPoint? {
        guard let position = model.positions[id] else { return nil }
        return CGPoint(x: frame.minX + position.x * frame.width, y: frame.minY + position.y * frame.height)
    }

    private func radius(_ node: GraphMap.Node) -> CGFloat {
        switch node.kind {
        case .project: 6 + min(13, 2.8 * log(Double(max(1, node.weight))))
        case .file: 3
        case .topic: 4 + CGFloat(min(4, node.weight)) * 0.6
        case .source: 4
        }
    }

    private func node(near point: CGPoint, frame: CGRect) -> GraphMap.Node? {
        model.map?.nodes.min { a, b in
            distance(a, point, frame) < distance(b, point, frame)
        }.flatMap { distance($0, point, frame) < max(16, radius($0) + 6) ? $0 : nil }
    }

    private func distance(_ node: GraphMap.Node, _ point: CGPoint, _ frame: CGRect) -> CGFloat {
        guard let p = self.point(node.id, in: frame) else { return .infinity }
        return hypot(p.x - point.x, p.y - point.y)
    }

    private func draw(in context: inout GraphicsContext, frame: CGRect) {
        guard let map = model.map else { return }
        let focus = model.hovered.map(model.neighbourhood(of:))
        func visible(_ id: String) -> Double { focus == nil || focus!.contains(id) ? 1 : 0.18 }

        for edge in map.edges {
            guard let a = point(edge.from, in: frame), let b = point(edge.to, in: frame) else { continue }
            var path = Path()
            path.move(to: a)
            if edge.kind == .together {
                // Project-to-project links curve gently, so they read as a different kind of line.
                let mid = CGPoint(x: (a.x + b.x) / 2 + (b.y - a.y) * 0.12, y: (a.y + b.y) / 2 - (b.x - a.x) * 0.12)
                path.addQuadCurve(to: b, control: mid)
            } else {
                path.addLine(to: b)
            }
            let strength = min(1, 0.35 + log(Double(edge.weight)) * 0.2)
            let base = switch edge.kind { case .together: 0.6; case .contains: 0.3; case .topic: 0.36; case .source: 0.3 }
            let opacity = base * strength * min(visible(edge.from), visible(edge.to))
            context.stroke(path, with: .color(.primary.opacity(opacity)),
                           style: StrokeStyle(lineWidth: edge.kind == .together ? 1.4 : 0.8, dash: edge.kind == .source ? [2, 3] : []))
        }

        let now = Date()
        for node in map.nodes {
            guard let center = point(node.id, in: frame) else { continue }
            let r = radius(node)
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            let alpha = visible(node.id)
            let isHovered = node.id == model.hovered
            switch node.kind {
            case .project:
                let days = node.lastActive.map { now.timeIntervalSince($0) / 86_400 } ?? 90
                let freshness = 0.35 + 0.6 * exp(-days / 21)
                context.fill(Circle().path(in: rect), with: .color(isHovered ? .accentColor : .primary.opacity(freshness * alpha)))
                if node.isCode {
                    context.stroke(Circle().path(in: rect.insetBy(dx: -3, dy: -3)), with: .color(.primary.opacity(0.25 * alpha)), lineWidth: 0.8)
                }
                let label = Text(node.name).font(.system(size: 11.5, weight: isHovered ? .semibold : .medium))
                    .foregroundStyle(.primary.opacity(alpha))
                context.draw(label, at: CGPoint(x: center.x, y: center.y + r + 9), anchor: .top)
            case .file:
                context.fill(Circle().path(in: rect), with: .color(isHovered ? .accentColor : .primary.opacity(0.45 * alpha)))
                if isHovered {
                    context.draw(Text(node.name).font(.system(size: 11, weight: .medium)),
                                 at: CGPoint(x: center.x + r + 6, y: center.y), anchor: .leading)
                }
            case .topic:
                context.stroke(Circle().path(in: rect), with: .color(isHovered ? .accentColor : .secondary.opacity(alpha)), lineWidth: 1.2)
                do {
                    context.draw(Text(node.name).font(Theme.mono(10)).foregroundStyle(.secondary.opacity(alpha)),
                                 at: CGPoint(x: center.x + r + 5, y: center.y), anchor: .leading)
                }
            case .source:
                context.stroke(RoundedRectangle(cornerRadius: 1.5).path(in: rect), with: .color(isHovered ? .accentColor : .secondary.opacity(alpha * 0.8)), lineWidth: 1)
                if focus != nil && alpha == 1 {
                    context.draw(Text(node.name).font(Theme.mono(9.5)).foregroundStyle(.tertiary),
                                 at: CGPoint(x: center.x + r + 5, y: center.y), anchor: .leading)
                }
            }
        }

        if let hovered = model.hovered, let node = map.nodes.first(where: { $0.id == hovered }), let center = point(hovered, in: frame) {
            if node.kind == .project {
                drawCard(for: node, at: center, in: &context, frame: frame, map: map)
                return
            }
            let detail: String = switch node.kind {
            case .project: "\(node.weight) files" + (node.lastActive.map { " · active \(Theme.age($0))" } ?? "")
            case .file: node.lastActive.map { "edited \(Theme.age($0))" } ?? ""
            case .topic: "topic · \(node.weight) files"
            case .source: "\(node.weight) downloads"
            }
            context.draw(Text(detail).font(Theme.mono(10)).foregroundStyle(.secondary),
                         at: CGPoint(x: center.x, y: center.y - radius(node) - 8), anchor: .bottom)
        }
    }
}

extension MapView {
    /// A hovered project lists its newest files beside it, rather than labelling each dot.
    private func drawCard(for node: GraphMap.Node, at center: CGPoint, in context: inout GraphicsContext, frame: CGRect, map: GraphMap) {
        let files = map.edges.filter { $0.from == node.id && $0.kind == .contains }
            .compactMap { edge in map.nodes.first { $0.id == edge.to } }
        let detail = "\(node.weight) files" + (node.lastActive.map { " · active \(Theme.age($0))" } ?? "")
        let lines: [Text] = [Text(detail).font(Theme.mono(10)).foregroundStyle(.secondary)]
            + files.map { Text($0.name).font(.system(size: 11)).foregroundStyle(.primary.opacity(0.85)) }
        let onRight = center.x < frame.midX + frame.width * 0.2
        let x = onRight ? center.x + radius(node) + 34 : center.x - radius(node) - 34
        let top = center.y - CGFloat(lines.count - 1) * 8
        for (index, line) in lines.enumerated() {
            context.draw(line, at: CGPoint(x: x, y: top + CGFloat(index) * 16), anchor: onRight ? .leading : .trailing)
        }
    }
}

private struct LegendItem: View {
    let symbol: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
