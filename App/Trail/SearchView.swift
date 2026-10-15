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
                    .frame(maxHeight: 380)
                Divider().opacity(0.4)
                footer
            }
        }
        .frame(width: 620)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .shadow(color: .black.opacity(0.14), radius: 20, y: 10)
        .animation(Theme.ease, value: model.hits.map(\.id))
        .animation(Theme.ease, value: model.response?.answer)
    }

    private var hasBody: Bool {
        !model.query.isEmpty || !app.recentProjects.isEmpty || !app.hasFullDiskAccess || app.phase != .watching || app.inboxCount > 0
    }

    // MARK: - Field

    private var searchField: some View {
        HStack(spacing: 14) {
            Group {
                if model.isThinking {
                    BrailleSpinner().font(Theme.mono(18, .medium))
                } else {
                    Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .medium))
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 24)

            TextField("Search, or ask about your files", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .regular))
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
                guard model.selectionFromKeyboard else { return }
                withAnimation(Theme.quick) { proxy.scrollTo(model.selectedFile?.id) }
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if let corrected = model.response?.correctedText {
            Text("Showing results for \(Text(corrected).foregroundStyle(.primary))")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
        }
        if let answer = model.response?.answer {
            AnswerBubble(text: answer, byModel: model.response?.pickedByModel == true)
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
                ShadeBar().font(Theme.mono(11))
                Text("Mapping your files · \(count.formatted())")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .padding(12)
        }
        if app.inboxCount > 0 {
            Button { app.showSort?() } label: {
                HStack(spacing: 10) {
                    Text("\(app.inboxCount)")
                        .font(Theme.mono(11, .semibold))
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Circle().fill(Color.primary.opacity(0.1)))
                    Text("new \(app.inboxCount == 1 ? "file" : "files") on your Desktop and in Downloads")
                        .font(.system(size: 12.5))
                    Spacer()
                    Text("Sort →").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
        }
        if !app.recentProjects.isEmpty {
            SectionHeader("Recent")
            ForEach(Array(model.homeFiles.enumerated()), id: \.element.id) { index, file in
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
            .onHover { if $0 { model.hover(index) } }
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
            KeyHint(keys: "⌘↩", label: "Reveal")
            KeyHint(keys: "⇥", label: model.detail == nil ? "Related" : "Back")
            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 30)
    }
}

// MARK: - Pieces

struct FileRow: View {
    let file: FileRecord
    let versions: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(path: file.path, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if versions > 1 {
                        Text("×\(versions)").font(Theme.mono(10.5)).foregroundStyle(.tertiary)
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
                Text(Theme.age(file.modified))
                    .font(Theme.mono(11))
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
                .fill(isSelected ? Color.primary.opacity(0.08) : .clear)
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
            Text("↳")
                .font(Theme.mono(13, .medium))
                .foregroundStyle(.secondary)
            DecodeText(text: text)
                .font(Theme.mono(12.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if byModel {
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .help("Chosen by the on-device model")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
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
                    .foregroundStyle(.secondary)
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
        .background(.quaternary.opacity(0.5), in: .capsule)
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
            Text(keys).font(Theme.mono(10.5)).foregroundStyle(.secondary)
            if !label.isEmpty { Text(label).font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
    }
}

struct EmptyResults: View {
    let isThinking: Bool

    var body: some View {
        HStack(spacing: 0) {
            if isThinking {
                Text("Thinking")
                LoadingDots().font(Theme.mono(13))
            } else {
                Text("Nothing matches. Try fewer words.")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

struct AccessBanner: View {
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
            Text("Full Disk Access lets Trail see your whole Mac.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Grant…", action: action)
                .controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
