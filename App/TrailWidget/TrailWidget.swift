import SwiftUI
import WidgetKit

@main
struct TrailWidgetBundle: WidgetBundle {
    var body: some Widget {
        TrailWidget()
    }
}

struct TrailWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TrailRecentWork", provider: Provider()) { entry in
            TrailWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Trail")
        .description("Pick up where you left off, and ask Trail anything.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct Entry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
    var isPlaceholder = false
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, snapshot: .placeholder, isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(load() ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = load() ?? Entry(date: .now, snapshot: WidgetSnapshot(generated: .now, projects: [], recent: [], fileCount: 0))
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }

    /// Reads the snapshot the app writes to the shared app-group folder.
    private func load() -> Entry? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "TrailAppGroup") as? String,
              let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
              let data = try? Data(contentsOf: folder.appendingPathComponent(WidgetSnapshot.fileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data) else { return nil }
        return Entry(date: .now, snapshot: snapshot)
    }
}

struct TrailWidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    private static let askURL = URL(string: "trail://ask")!

    var body: some View {
        switch family {
        case .systemSmall: small
        default: list(count: family == .systemLarge ? 6 : 3)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            TrailMark(size: 11)
                .foregroundStyle(.secondary)
            Text("Recent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Link(destination: Self.askURL) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                    Text("Ask")
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.quaternary, in: .capsule)
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TrailMark(size: 13)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            if let project = entry.snapshot.projects.first {
                Text(project.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(project.latest?.name ?? "—")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Text(project.lastActive, style: .relative)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Text("What do you want to find?")
                    .font(.system(size: 14, weight: .semibold))
            }
        }
        .widgetURL(Self.askURL)
    }

    private func list(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if entry.snapshot.projects.isEmpty {
                Spacer()
                Text("Trail is mapping your files…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.snapshot.projects.prefix(count)) { project in
                    row(project)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func row(_ project: WidgetSnapshot.Project) -> some View {
        let content = HStack(spacing: 10) {
            Image(systemName: project.latest?.symbol ?? "folder")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(project.latest?.name ?? project.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Text(project.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Theme.age(project.lastActive))
                .font(Theme.mono(10.5))
                .foregroundStyle(.tertiary)
        }
        if let latest = project.latest, var components = URLComponents(string: "trail://open") {
            let _ = components.queryItems = [URLQueryItem(name: "path", value: latest.path)]
            Link(destination: components.url ?? Self.askURL) { content }
        } else {
            content
        }
    }
}

#Preview(as: .systemMedium) {
    TrailWidget()
} timeline: {
    Entry(date: .now, snapshot: .placeholder)
}
