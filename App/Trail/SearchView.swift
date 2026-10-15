import SwiftUI
import TrailCore

struct SearchView: View {
    @Bindable var model: SearchModel
    let app: AppModel
    let dismiss: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            card
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: SearchPanelController.size.width, height: SearchPanelController.size.height, alignment: .top)
    }

    private var card: some View {
        VStack(spacing: 0) {
            searchField
            if hasBody {
                Divider().opacity(0.4)
                content
                    .frame(maxHeight: 440)
                Divider().opacity(0.4)
                footer
            }
        }
        .frame(width: 680)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
        .animation(.smooth(duration: 0.22), value: model.hits.map(\.id))
        .animation(.smooth(duration: 0.22), value: model.response?.answer)
    }

    private var hasBody: Bool {
        !model.query.isEmpty || !app.recentProjects.isEmpty || !app.hasFullDiskAccess || app.phase != .watching
    }

    // MARK: - Field

    private var searchField: some View {
        HStack(spacing: 14) {
            Image(systemName: model.isThinking ? "sparkle" : "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(model.isThinking ? AnyShapeStyle(Self.sparkleGradient) : AnyShapeStyle(.secondary))
                .symbolEffect(.pulse, isActive: model.isThinking)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24)

            TextField("What do you want to find?", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .focused($fieldFocused)
                .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                .onKeyPress(.tab) { model.toggleDetail(); return .handled }
                .onKeyPress(.escape) {
                    if model.detail != nil { model.toggleDetail() } else if !model.query.isEmpty { model.query = "" } else { dismiss() }
                    return .handled
                }
                .onKeyPress(keys: [.return]) { press in
                    guard model.openSelection(reveal: press.modifiers.contains(.command)) else { return .ignored }
                    dismiss()
                    return .handled
                }
                .onKeyPress(keys: ["c"]) { press in
                    guard press.modifiers == [.command, .shift] else { return .ignored }
                    model.copyPath()
                    return .handled
                }

            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
        .onAppear { fieldFocused = true }
        .onChange(of: model.focusToken) { fieldFocused = true }
    }

    static let sparkleGradient = LinearGradient(colors: [.purple, .blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let detail = model.detail {
                        detailView(detail.file, detail.related)
                    } else if model.query.isEmpty {
                        home
                    } else {
                        results
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selection) {
                withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(model.selectedFile?.id) }
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if let answer = model.response?.answer {
            AnswerBubble(text: answer, byModel: model.response?.refinedByModel == true)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
        if let projects = model.response?.projects, !projects.isEmpty {
            HStack(spacing: 8) {
                ForEach(projects) { project in
                    ProjectChip(project: project) { NSWorkspace.shared.open(URL(fileURLWithPath: project.root)); dismiss() }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
        }
        if model.hits.isEmpty, model.response != nil {
            EmptyResults(isThinking: model.isThinking)
        }
        ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
            row(hit.file, versions: hit.versionCount, index: index)
        }
    }

    @ViewBuilder
    private var home: some View {
        if !app.hasFullDiskAccess {
            AccessBanner { app.openFullDiskAccessSettings() }
                .padding(.bottom, 8)
        }
        if case .scanning(let count) = app.phase {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Building your map… \(count.formatted()) files so far")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        if !app.recentProjects.isEmpty {
            SectionHeader("Pick up where you left off")
            let files = app.recentProjects.flatMap(\.latest)
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                row(file, versions: 1, index: index)
            }
        }
    }

    @ViewBuilder
    private func detailView(_ file: FileRecord, _ related: Related) -> some View {
        HStack(spacing: 12) {
            FileIcon(path: file.path, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(file.summary ?? file.displayPath).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                if !file.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(file.tags, id: \.self) { TagPill(text: $0) }
                    }
                }
            }
        }
        .padding(12)

        let sections: [(String, [FileRecord])] = [
            ("Versions", related.versions), ("Worked on alongside", related.sameSession),
            ("Shares topics", related.sameTopics), ("Same project", related.sameProject),
        ]
        ForEach(sections.indices, id: \.self) { sectionIndex in
            let (title, files) = sections[sectionIndex]
            let start = sections[..<sectionIndex].reduce(0) { $0 + $1.1.count }
            if !files.isEmpty {
                SectionHeader(title)
                ForEach(Array(files.enumerated()), id: \.offset) { index, other in
                    row(other, versions: 1, index: start + index)
                }
            }
        }
    }

    private func row(_ file: FileRecord, versions: Int, index: Int) -> some View {
        FileRow(file: file, versions: versions, isSelected: index == model.selection)
            .id(file.id)
            .contentShape(.rect)
            .onHover { if $0 { model.selection = index } }
            .onTapGesture {
                model.selection = index
                model.open(file)
                dismiss()
            }
            .contextMenu {
                Button("Open") { model.open(file) }
                Button("Show in Finder") { model.open(file, reveal: true) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.path, forType: .string)
                }
            }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            KeyHint(keys: "↩", label: "Open")
            KeyHint(keys: "⌘↩", label: "Show in Finder")
            KeyHint(keys: "⇥", label: model.detail == nil ? "Related" : "Back")
            KeyHint(keys: "⇧⌘C", label: "Copy path")
            Spacer()
            if case .ready = app.modelStatus {
                Label("On-device", systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 34)
    }
}

// MARK: - Pieces

struct FileRow: View {
    let file: FileRecord
    let versions: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(path: file.path, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if versions > 1 {
                        TagPill(text: "\(versions) versions", systemImage: "square.stack")
                    }
                    if file.origin == .ai {
                        Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(SearchView.sparkleGradient)
                    } else if file.origin == .download {
                        Image(systemName: "arrow.down.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Text(file.summary ?? file.displayPath)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(file.modified, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let project = file.projectName {
                    Text(project)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        }
    }
}

struct FileIcon: View {
    let path: String
    let size: CGFloat
    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Image(nsImage: Self.icon(for: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }

    static func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }
}

struct AnswerBubble: View {
    let text: String
    let byModel: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: byModel ? "sparkles" : "arrow.turn.down.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(byModel ? AnyShapeStyle(SearchView.sparkleGradient) : AnyShapeStyle(.secondary))
            Text(text)
                .font(.system(size: 13.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassEffect(.regular.tint(.accentColor.opacity(0.12)), in: .rect(cornerRadius: 16))
    }
}

struct ProjectChip: View {
    let project: ProjectSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: project.kind == "code" ? "chevron.left.forwardslash.chevron.right" : "folder.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 0) {
                    Text(project.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text("\(project.fileCount) files · \(RelativeTime.describe(project.lastActive))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

struct TagPill: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary.opacity(0.6), in: .capsule)
    }
}

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 5))
            Text(label).font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}

struct EmptyResults: View {
    let isThinking: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: isThinking ? "sparkle" : "questionmark.folder")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(isThinking ? "Thinking…" : "Nothing matches yet")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

struct AccessBanner: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.open.display")
                .font(.system(size: 20))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Let Trail see your whole Mac").font(.system(size: 13, weight: .semibold))
                Text("Full Disk Access lets it map Desktop, Documents, Downloads and iCloud without asking folder by folder. Nothing leaves this Mac.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Settings", action: action)
                .buttonStyle(.glassProminent)
                .controlSize(.small)
        }
        .padding(14)
        .glassEffect(.regular.tint(.accentColor.opacity(0.1)), in: .rect(cornerRadius: 16))
    }
}
