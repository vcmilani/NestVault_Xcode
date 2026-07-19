import SwiftUI
import AppKit

// MARK: - Configs View
struct BackupConfigsView: View {
    @EnvironmentObject var api:      APIService
    @EnvironmentObject var store:    ConfigStore
    @EnvironmentObject var schedule: ScheduleManager

    @State private var selected:    BackupProfile?
    @State private var editing:     BackupProfile?
    @State private var showAdd      = false
    @State private var showDelete   = false
    @State private var showQueue    = false
    @State private var showDeleteBackup = false
    @State private var deleteBackupError: String?
    @State private var showImport       = false

    var body: some View {
        HStack(spacing: 0) {

            // ── Left: Profile List ───────────────────────────────────
            VStack(spacing: 0) {
                HStack {
                    Text("mybackups.title")
                        .font(.headline)
                    Spacer()
                    Text("\(store.profiles.count)")
                        .font(.caption)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.secondary.opacity(0.2), in: Capsule())
                        .foregroundStyle(.secondary)
                    Button { showQueue = true } label: {
                        Image(systemName: "play.rectangle.on.rectangle").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("mybackups.run_queue")
                    .disabled(store.profiles.filter { $0.enabled }.isEmpty)
                    Button { showImport = true } label: {
                        Image(systemName: "arrow.down.circle").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("mybackups.import_cmd")
                    Button { showAdd = true } label: {
                        Image(systemName: "plus").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("mybackups.new_config")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                if store.profiles.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("mybackups.none")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button(L("mybackups.add")) { showAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(store.profiles) { profile in
                                ProfileListRow(profile: profile)
                                    .padding(.horizontal, 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected == profile
                                        ? Color.accentColor.opacity(0.15) : Color.clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selected = profile }
                                    .contextMenu {
                                        Button(L("mybackups.edit")) { editing = profile }
                                        Divider()
                                        Button("mybackups.delete_config", role: .destructive) {
                                            selected = profile; showDelete = true
                                        }
                                        Button("mybackups.delete_server", role: .destructive) {
                                            selected = profile; showDeleteBackup = true
                                        }
                                    }
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(width: 220)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // ── Right: Detail ────────────────────────────────────────
            Group {
                if let profile = selected {
                    ProfileDetailView(
                        profile: profile,
                        defaultServer: api.serverURL,
                        onEdit: { editing = profile }
                    )
                } else {
                    PlaceholderView(
                        title: "mybackups.select",
                        icon: "slider.horizontal.3",
                        description: "mybackups.select_hint"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showQueue) {
            BackupQueueSheet()
                .environmentObject(api)
                .environmentObject(store)
                .environmentObject(schedule)
        }
        .alert("mybackups.delete_server_title", isPresented: $showDeleteBackup) {
            Button("common.cancel", role: .cancel) {}
            Button("mybackups.delete_server", role: .destructive) {
                guard let label = selected?.label else { return }
                Task {
                    do {
                        try await api.deleteBackup(label: label)
                        await api.fetchBackups()
                    } catch {
                        deleteBackupError = error.localizedDescription
                    }
                }
            }
        } message: {
            let name = selected?.label ?? ""
            Text(L("mybackups.delete_server_msg", name))
        }
        .sheet(isPresented: $showAdd) {
            ProfileEditorSheet(profile: nil, defaultServer: api.serverURL) { p in
                store.add(p); selected = p
            }
        }
        .sheet(item: $editing) { p in
            ProfileEditorSheet(profile: p, defaultServer: api.serverURL) { updated in
                store.update(updated)
                if selected?.id == updated.id { selected = updated }
            }
        }
        .sheet(isPresented: $showImport) {
            ImportCommandSheet { p in
                store.add(p); selected = p
            }
        }
        .alert("mybackups.delete_config_title", isPresented: $showDelete) {
            Button("common.cancel", role: .cancel) {}
            Button("common.delete",  role: .destructive) {
                if let p = selected { store.delete(p); selected = nil }
            }
        } message: {
            let name = selected?.name ?? ""
            Text(L("mybackups.delete_config_msg", name))
        }
    }
}

// MARK: - Profile List Row
struct ProfileListRow: View {
    let profile: BackupProfile
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(profile.enabled ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.1))
                    .frame(width: 30, height: 30)
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(profile.enabled ? .blue : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                Text(profile.label.isEmpty ? L("mybackups.no_label") : profile.label)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !profile.enabled {
                Image(systemName: "pause.fill")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Profile Detail View
struct ProfileDetailView: View {
    let profile: BackupProfile
    let defaultServer: String
    let onEdit: () -> Void

    @EnvironmentObject var api:      APIService
    @EnvironmentObject var schedule: ScheduleManager
    @State private var showRunner = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {

                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text(profile.name)
                                .font(.title2.bold())
                            if !profile.enabled {
                                Text("mybackups.inactive")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(.secondary.opacity(0.2), in: Capsule())
                            }
                        }
                        Text("Label: \(profile.label.isEmpty ? L("mybackups.not_configured") : profile.label)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("mybackups.edit", action: onEdit)
                        .buttonStyle(.bordered)
                    Button("mybackups.run") { showRunner = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(!profile.enabled || profile.sourcePath.isEmpty || profile.label.isEmpty)
                }

                Divider()

                // Grid of info cards
                if profile.schedule.enabled {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.blue)
                        Text(LocalizedStringKey(scheduleSummary(profile.schedule)))
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        if let last = profile.lastRun {
                            Text("schedule.last_run").font(.caption).foregroundStyle(.secondary)
                            Text(last, style: .relative)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.25), lineWidth: 1))
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ProfileInfoCard(title: L("card.source_folder"), icon: "folder.fill", iconColor: .blue) {
                        Text(profile.sourcePath.isEmpty ? L("card.not_configured") : profile.sourcePath)
                            .font(.body.monospaced()).lineLimit(3)
                            .foregroundStyle(profile.sourcePath.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                    }
                    ProfileInfoCard(title: L("card.server"), icon: "network", iconColor: .green) {
                        Text(profile.serverOverride.isEmpty ? defaultServer : profile.serverOverride)
                            .font(.body.monospaced()).lineLimit(2)
                            .textSelection(.enabled)
                    }
                    ProfileInfoCard(title: L("card.workers"), icon: "cpu", iconColor: .purple) {
                        Text("\(profile.workers) workers")
                            .font(.title3.bold())
                        Text(workersDescription(profile.workers))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ProfileInfoCard(title: L("card.prefix"), icon: "folder.badge.questionmark", iconColor: .orange) {
                        Text(profile.prefix.isEmpty ? L("common.none") : profile.prefix)
                            .font(.body.monospaced())
                            .foregroundStyle(profile.prefix.isEmpty ? .secondary : .primary)
                    }
                    if profile.accumulate {
                        ProfileInfoCard(title: L("card.accumulate"), icon: "arrow.triangle.merge", iconColor: .indigo) {
                            Text("editor.field.accumulate_hint")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                // Excludes
                if !profile.excludes.isEmpty {
                    ProfileInfoCard(title: String(format: L("card.excludes"), profile.excludes.count), icon: "xmark.circle.fill", iconColor: .red) {
                        FlowTagsView(tags: profile.excludes, color: .red)
                    }
                }

                // CLI command preview
                ProfileInfoCard(title: L("card.cli"), icon: "terminal.fill", iconColor: .secondary) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(profile.cliCommand(defaultServer: defaultServer))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Spacer()
                            Button {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(profile.cliCommand(defaultServer: defaultServer), forType: .string)
                            } label: {
                                Label(L("card.cli.copy"), systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showRunner) {
            BackupRunnerSheet(profile: profile, api: api,
                              existingRunner: schedule.runnerIfActive(for: profile.id))
        }
    }

    func scheduleSummary(_ s: BackupSchedule) -> String {
        switch s.frequency {
        case .off:    return "schedule.summary.off"
        case .hourly: return "schedule.summary.hourly"
        case .custom: return "schedule.summary.custom"
        case .daily:  return "schedule.summary.daily"
        case .weekly: return "schedule.summary.weekly"
        }
    }

    func workersDescription(_ n: Int) -> String {
        switch n {
        case 1...2: return L("card.workers_hint_1")
        case 3...5: return L("card.workers_hint_2")
        case 6...8: return L("card.workers_hint_3")
        default:    return L("card.workers_hint_4")
        }
    }
}

// MARK: - Info Card (Detail)
struct ProfileInfoCard<Content: View>: View {
    let title: String
    let icon:  String
    let iconColor: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(iconColor)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4), lineWidth: 1))
    }
}

// MARK: - Flow Tags
struct FlowTagsView: View {
    let tags: [String]
    let color: Color

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 100), spacing: 6)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.3), lineWidth: 1))
            }
        }
    }
}

// MARK: - Profile Editor Sheet
struct ProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let profile:       BackupProfile?
    let defaultServer: String
    let onSave:        (BackupProfile) -> Void

    @State private var draft:      BackupProfile
    @State private var tab         = 0

    init(profile: BackupProfile?, defaultServer: String, onSave: @escaping (BackupProfile) -> Void) {
        self.profile       = profile
        self.defaultServer = defaultServer
        self.onSave        = onSave
        self._draft        = State(initialValue: profile ?? BackupProfile())
    }

    var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.label.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.sourcePath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sheet toolbar
            HStack {
                Button("common.cancel") { dismiss() }
                Spacer()
                Text(profile == nil ? LocalizedStringKey("editor.new") : LocalizedStringKey("editor.edit"))
                    .font(.headline)
                Spacer()
                Button("common.save") { onSave(draft); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(16)

            Divider()

            // Tab picker
            Picker("", selection: $tab) {
                Label("editor.tab.general",   systemImage: "info.circle").tag(0)
                Label("editor.tab.server",    systemImage: "network").tag(1)
                Label("editor.tab.schedule",  systemImage: "clock").tag(2)
                Label("editor.tab.excludes",  systemImage: "xmark.circle").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Tab content
            Group {
                if tab == 0 {
                    Form {
                        Section("editor.section.identification") {
                            TextField("editor.field.name", text: $draft.name)
                            TextField("editor.field.label", text: $draft.label)
                                .font(.body.monospaced())
                            Toggle("editor.field.enabled", isOn: $draft.enabled)
                        }
                        Section("editor.section.source") {
                            HStack {
                                TextField("editor.field.source_path", text: $draft.sourcePath)
                                    .font(.body.monospaced())
                                Button("editor.field.pick") { pickFolder() }.fixedSize()
                            }
                            TextField("editor.field.prefix", text: $draft.prefix)
                                .font(.body.monospaced())
                        }
                    }
                    .formStyle(.grouped)
                } else if tab == 1 {
                    Form {
                        Section("editor.section.server") {
                            TextField("editor.field.server_url", text: $draft.serverOverride)
                                .font(.body.monospaced())
                            if draft.serverOverride.isEmpty {
                                Text(L("editor.field.server_using_default", defaultServer))
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(L("editor.field.server_using", draft.serverOverride))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Section("editor.section.performance") {
                            HStack {
                                Text("editor.workers_label")
                                Spacer()
                                TextField("4", value: $draft.workers, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 60)
                                    .font(.body.monospacedDigit())
                                    .onChange(of: draft.workers) { _, v in
                                        if v < 1  { draft.workers = 1 }
                                        if v > 16 { draft.workers = 16 }
                                    }
                            }
                            Text("\(L("editor.workers_range")) \(workersHint(draft.workers))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Section("editor.section.mode") {
                            Toggle("editor.field.accumulate", isOn: $draft.accumulate)
                            Text("editor.field.accumulate_hint")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle("editor.field.smart_skip", isOn: $draft.smartSkip)
                            Text("editor.field.smart_skip_hint")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .formStyle(.grouped)
                } else if tab == 2 {
                    ScheduleEditor(schedule: $draft.schedule)
                } else {
                    ExcludesEditor(excludes: $draft.excludes)
                }
            }
        }
        .frame(width: 540, height: 480)
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = L("editor.panel.title")
        panel.prompt = L("editor.panel.prompt")
        NSApp.activate(ignoringOtherApps: true)
        // begin (non-blocking) lets SwiftUI process state changes properly
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            draft.sourcePath = url.path
        }
    }

    func workersHint(_ n: Int) -> String {
        switch n {
        case 1...2: return L("editor.workers_hint_1")
        case 3...5: return L("editor.workers_hint_2")
        case 6...8: return L("editor.workers_hint_3")
        default:    return L("editor.workers_hint_4")
        }
    }
}

// MARK: - Excludes Editor (uses local @State for guaranteed re-render)

struct ExcludesEditor: View {
    @Binding var excludes: [String]
    @State private var local: [String] = []
    @State private var newExclude = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("editor.excludes.title").font(.headline)
                Spacer()
                Text(L("editor.excludes.count", local.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            HStack {
                TextField("editor.excludes.placeholder", text: $newExclude)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(add)
                Button("editor.excludes.add_btn", action: add)
                    .disabled(newExclude.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
            Divider()
            if local.isEmpty {
                Spacer()
                Text("editor.excludes.none")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(local.indices, id: \.self) { i in
                            row(at: i)
                            Divider()
                        }
                    }
                }
            }
        }
        .onAppear {
            local = excludes
        }
        .onChange(of: local) { _, newValue in
            excludes = newValue
        }
    }

    @ViewBuilder
    private func row(at i: Int) -> some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(local[i]).font(.body.monospaced())
            Spacer()
            Button {
                guard i < local.count else { return }
                local.remove(at: i)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func add() {
        let t = newExclude.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !local.contains(t) else { return }
        local.append(t)
        newExclude = ""
    }
}

// MARK: - Import Command Sheet

struct ImportCommandSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onImport: (BackupProfile) -> Void

    @State private var commandText = ""
    @State private var parsed: BackupProfile?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("common.cancel") { dismiss() }
                Spacer()
                Text("import.title").font(.headline)
                Spacer()
                Button("import.confirm") {
                    if let p = parsed { onImport(p); dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(parsed == nil)
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("import.paste_hint")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextEditor(text: $commandText)
                    .font(.caption.monospaced())
                    .frame(minHeight: 100, maxHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 1))
                    .onChange(of: commandText) { _, new in
                        parsed = BackupProfile(cliString: new)
                    }

                if let p = parsed {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("import.preview_title", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            ImportPreviewRow(key: "import.field.label",  value: p.label.isEmpty ? "-" : p.label)
                            ImportPreviewRow(key: "import.field.source", value: p.sourcePath)
                            ImportPreviewRow(key: "import.field.server", value: p.serverOverride.isEmpty ? L("import.default_server") : p.serverOverride)
                            if p.workers != 4 {
                                ImportPreviewRow(key: "import.field.workers", value: "\(p.workers)")
                            }
                            if !p.excludes.isEmpty {
                                ImportPreviewRow(key: "import.field.excludes", value: p.excludes.joined(separator: ", "))
                            }
                            if p.accumulate {
                                ImportPreviewRow(key: "import.field.absorb", value: L("import.field.absorb_on"))
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.2), lineWidth: 1))
                } else if !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("import.parse_error", systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()
            }
            .padding(16)
        }
        .frame(width: 460, height: 360)
    }
}

private struct ImportPreviewRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(LocalizedStringKey(key))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(2)
        }
    }
}
