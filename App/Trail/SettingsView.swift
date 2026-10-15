import SwiftUI
import TrailCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { general }
            Tab("Folders", systemImage: "folder") { folders }
            Tab("About", systemImage: "info.circle") { about }
        }
        .frame(width: 520, height: 420)
        .onAppear {
            NSApp.activate()
            model.refresh(force: true)
        }
    }

    private var general: some View {
        Form {
            Section {
                Toggle("Open Trail at login", isOn: Binding(get: { model.launchesAtLogin }, set: { model.launchesAtLogin = $0 }))
                Picker("Shortcut", selection: $model.hotKey) {
                    ForEach(HotKeyChoice.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("On-device model") {
                LabeledContent("Status") {
                    switch model.modelStatus {
                    case .ready: Label("Apple Intelligence ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .unavailable(let reason): Text(reason).foregroundStyle(.secondary)
                    }
                }
                Toggle("Write short notes about new files", isOn: Binding(
                    get: { model.config.enrichWithModel },
                    set: { value in model.updateConfig { $0.enrichWithModel = value } }))
                Text("Notes and tags make files findable by what's in them. They're written on this Mac, slowly, while you're away from the keyboard, and never in Low Power Mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("New files") {
                Toggle("Suggest where new files belong", isOn: Binding(
                    get: { model.config.suggestHomes },
                    set: { value in model.updateConfig { $0.suggestHomes = value } }))
                Text("New screenshots and downloads on the Desktop and in Downloads get a suggested folder, and the menu bar shows how many are waiting. Nothing moves until you say so.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Index") {
                LabeledContent("Files", value: model.stats?.files.formatted() ?? "—")
                LabeledContent("Projects", value: model.stats?.projects.formatted() ?? "—")
                LabeledContent("With notes", value: model.stats?.enriched.formatted() ?? "—")
                LabeledContent("On disk", value: model.stats.map { ByteCountFormatter.string(fromByteCount: Int64($0.databaseBytes), countStyle: .file) } ?? "—")
                LabeledContent("Full Disk Access") {
                    if model.hasFullDiskAccess {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant…") { model.openFullDiskAccessSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var folders: some View {
        Form {
            Section {
                ForEach(model.config.roots, id: \.self) { root in
                    HStack {
                        Label(root, systemImage: "folder")
                        Spacer()
                        Button(role: .destructive) {
                            model.updateConfig { $0.roots.removeAll { $0 == root } }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(model.config.roots.count == 1)
                    }
                }
                Button("Add Folder…") { pick { path in model.updateConfig { $0.roots.append(path) } } }
            } header: {
                Text("Watched")
            } footer: {
                Text("Trail skips caches, hidden folders, node_modules, build output and app bundles on its own.")
            }

            Section("Ignored") {
                ForEach(model.config.excludedPaths, id: \.self) { path in
                    HStack {
                        Label(path, systemImage: "eye.slash")
                        Spacer()
                        Button(role: .destructive) {
                            model.updateConfig { $0.excludedPaths.removeAll { $0 == path } }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Ignore a Folder…") { pick { path in model.updateConfig { $0.excludedPaths.append(path) } } }
            }

            Section {
                Button("Rebuild Index", role: .destructive) { model.rebuildIndex() }
            } footer: {
                Text("Forgets everything and scans again. Notes are rewritten over time.")
            }
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            Text("Trail").font(.title.bold())
            Text("A private map of the files on your Mac.")
                .foregroundStyle(.secondary)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Link("github.com/uneasymusings/trail", destination: URL(string: "https://github.com/uneasymusings/trail")!)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pick(_ completion: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let home = NSHomeDirectory()
        let path = url.path
        completion(path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path)
    }
}
