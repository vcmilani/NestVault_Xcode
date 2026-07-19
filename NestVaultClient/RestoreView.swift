import SwiftUI
import AppKit

// MARK: - Restore Context (sheet payload)

struct RestoreContext: Identifiable {
    let id = UUID()
    let label: String
    let versionKey: String
    let files: [VersionFile]
    let versionStatusWarning: Bool   // true when the version is not "done"
}

// MARK: - Restore Sheet

struct RestoreSheet: View {
    @EnvironmentObject var store: ConfigStore
    @Environment(\.dismiss) private var dismiss

    let context: RestoreContext
    @StateObject private var runner: RestoreRunner
    @State private var lastLogScroll = Date.distantPast

    private enum DestinationMode: Hashable { case original, folder }
    @State private var destinationMode: DestinationMode = .original
    @State private var chosenFolder: URL?
    @State private var policy: RestoreRunner.OverwritePolicy = .overwriteChanged

    init(context: RestoreContext, api: APIService) {
        self.context = context
        self._runner = StateObject(wrappedValue: RestoreRunner(api: api))
    }

    private var profile: BackupProfile? {
        store.profiles.first { $0.label == context.label && !$0.sourcePath.isEmpty }
    }

    private var totalBytes: Int64 { context.files.reduce(0) { $0 + $1.size } }

    private var destinationResolved: Bool {
        switch destinationMode {
        case .original: return profile != nil
        case .folder:   return chosenFolder != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ───────────────────────────────────────────────
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.green.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.green)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.label)
                        .font(.headline)
                    Text(L("restore.header.info", context.versionKey, context.files.count,
                           ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }
            .padding(18)

            Divider()

            if runner.status == .idle {
                optionsSection
            } else {
                progressSection
            }

            Divider()

            // ── Actions ──────────────────────────────────────────────
            HStack {
                if runner.status == .done || runner.status == .failed || runner.status == .cancelled {
                    Button("common.close") { dismiss() }
                }
                Spacer()
                if runner.status == .idle {
                    Button("common.cancel") { dismiss() }
                    Button("restore.start") { start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!destinationResolved)
                }
                if runner.status == .running {
                    Button("runner.stop") { runner.cancel() }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 500)
        .interactiveDismissDisabled(runner.status == .running)
    }

    // MARK: - Options phase

    private var optionsSection: some View {
        Form {
            if context.versionStatusWarning {
                Label("restore.version_warning", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Picker("restore.dest.label", selection: $destinationMode) {
                Text("restore.dest.original").tag(DestinationMode.original)
                Text("restore.dest.choose").tag(DestinationMode.folder)
            }
            .pickerStyle(.radioGroup)

            switch destinationMode {
            case .original:
                if let profile {
                    Text(profile.sourcePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("restore.no_profile_hint")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            case .folder:
                HStack {
                    Text(chosenFolder?.path ?? L("restore.dest.none"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("restore.dest.choose_btn") { pickFolder() }
                }
            }

            Picker("restore.policy.label", selection: $policy) {
                Text("restore.policy.keep").tag(RestoreRunner.OverwritePolicy.keepExisting)
                Text("restore.policy.overwrite_changed").tag(RestoreRunner.OverwritePolicy.overwriteChanged)
                Text("restore.policy.overwrite_all").tag(RestoreRunner.OverwritePolicy.overwriteAll)
            }
            .pickerStyle(.radioGroup)
        }
        .formStyle(.grouped)
        .onAppear {
            if profile == nil { destinationMode = .folder }
        }
    }

    // MARK: - Progress phase

    private var progressSection: some View {
        VStack(spacing: 0) {
            if runner.status == .running {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("restore.running_label")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(runner.progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: runner.progress)
                        .progressViewStyle(.linear)
                    HStack {
                        if !runner.currentFile.isEmpty {
                            Text(runner.currentFile)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text("\(ByteCountFormatter.string(fromByteCount: runner.stats.doneBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: runner.stats.totalBytes, countStyle: .file))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                Divider()
            }

            if runner.status == .done || runner.status == .failed || runner.status == .cancelled {
                HStack(spacing: 0) {
                    MiniRunStat(value: "\(runner.stats.restored)", label: "restore.stat.restored", color: .blue)
                    Divider()
                    MiniRunStat(value: "\(runner.stats.skipped)",  label: "restore.stat.skipped",  color: .secondary)
                    Divider()
                    MiniRunStat(value: "\(runner.stats.errors)",   label: "restore.stat.errors",   color: .red)
                }
                .frame(height: 56)
                Divider()
            }

            // ── Log ──────────────────────────────────────────────────
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(runner.entries) { entry in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(entry.kind.color)
                                    .frame(width: 5, height: 5)
                                Text(entry.text)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(entry.kind.textColor)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 1)
                            .id(entry.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .frame(minHeight: 200)
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: runner.entries.count) { _, _ in
                    let now = Date()
                    guard now.timeIntervalSince(lastLogScroll) > 0.2 else { return }
                    lastLogScroll = now
                    if let last = runner.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: runner.status) { _, _ in
                    if let last = runner.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories    = true
        panel.canChooseFiles          = false
        panel.canCreateDirectories    = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("restore.dest.choose_btn")
        if panel.runModal() == .OK, let url = panel.url {
            chosenFolder = url
        }
    }

    private func start() {
        let destRoot: URL
        let stripPrefix: String
        switch destinationMode {
        case .original:
            guard let profile else { return }
            destRoot    = URL(fileURLWithPath: profile.sourcePath, isDirectory: true)
            stripPrefix = profile.prefix
        case .folder:
            guard let chosenFolder else { return }
            destRoot    = chosenFolder
            stripPrefix = RestoreRunner.commonDirectoryPrefix(of: context.files.map(\.originalPath))
        }
        let request = RestoreRunner.Request(
            label:       context.label,
            versionKey:  context.versionKey,
            files:       context.files,
            destRoot:    destRoot,
            stripPrefix: stripPrefix,
            policy:      policy,
            workers:     profile?.workers ?? 4)
        runner.runTask = Task {
            await runner.run(request)
            runner.runTask = nil
        }
    }

    // MARK: - Status Badge

    private var statusBadge: some View {
        Group {
            switch runner.status {
            case .idle:
                Text("runner.waiting")
                    .foregroundStyle(.secondary)
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("restore.running")
                        .foregroundStyle(.blue)
                }
            case .done:
                Label("runner.done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Label("runner.failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .cancelled:
                Label("runner.cancelled", systemImage: "stop.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.subheadline.weight(.medium))
    }
}

// MARK: - Log Kind Helpers

private extension RestoreRunner.LogEntry.Kind {
    var color: Color {
        switch self {
        case .info:    return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error:   return .red
        }
    }
    var textColor: Color {
        switch self {
        case .info:    return .primary
        case .success: return .green
        case .warning: return .orange
        case .error:   return .red
        }
    }
}
