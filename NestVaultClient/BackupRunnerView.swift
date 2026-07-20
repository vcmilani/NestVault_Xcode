import SwiftUI

struct BackupRunnerSheet: View {
    @EnvironmentObject var api:      APIService
    @EnvironmentObject var store:    ConfigStore
    @EnvironmentObject var schedule: ScheduleManager
    @Environment(\.dismiss) private var dismiss

    let profile: BackupProfile
    @StateObject private var runner: BackupRunner
    @State private var lastLogScroll = Date.distantPast

    init(profile: BackupProfile, api: APIService, existingRunner: BackupRunner? = nil) {
        self.profile = profile
        // Re-attach to an already-running backup of this profile instead of creating
        // a second runner (which allowed the same label to run twice in parallel).
        self._runner = StateObject(wrappedValue: existingRunner ?? BackupRunner(api: api))
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ───────────────────────────────────────────────
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "arrow.up.to.line.compact")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.headline)
                    Text("Label: \(profile.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }
            .padding(18)

            Divider()

            // ── Progress ─────────────────────────────────────────────
            if runner.status == .running {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(runner.phaseDescription)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !runner.isIndeterminatePhase {
                            Text("\(Int(runner.progress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if runner.isIndeterminatePhase {
                        ProgressView()
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView(value: runner.progress)
                            .progressViewStyle(.linear)
                    }
                    if !runner.currentFile.isEmpty {
                        Text(runner.currentFile)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                Divider()
            }

            // ── Stats row (when done) ────────────────────────────────
            if runner.status == .done || runner.status == .failed {
                HStack(spacing: 0) {
                    MiniRunStat(value: "\(runner.stats.uploaded)",   label: "runner.stat.uploaded",   color: .blue)
                    Divider()
                    MiniRunStat(value: "\(runner.stats.registered)", label: "runner.stat.registered", color: .green)
                    Divider()
                    MiniRunStat(value: "\(runner.stats.cached)",     label: "runner.stat.cached",     color: .teal)
                    Divider()
                    MiniRunStat(value: "\(runner.stats.ignored)",    label: "runner.stat.ignored",    color: .secondary)
                    Divider()
                    MiniRunStat(value: "\(runner.stats.errors)",     label: "runner.stat.errors",     color: .red)
                    if runner.stats.inherited > 0 {
                        Divider()
                        MiniRunStat(value: "\(runner.stats.inherited)", label: "runner.stat.inherited", color: .indigo)
                    }
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
                    // Throttle: one animated scroll per append queues layout work
                    // that snowballs when the log grows fast (e.g. many file errors).
                    let now = Date()
                    guard now.timeIntervalSince(lastLogScroll) > 0.2 else { return }
                    lastLogScroll = now
                    if let last = runner.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: runner.status) { _, _ in
                    // Always land on the final line when the run settles.
                    if let last = runner.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
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
                }
                if runner.status == .running {
                    Button("runner.stop") {
                        runner.cancel()
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
                Button(runner.status == .idle ? "runner.start" : "runner.run_again") {
                    let task = Task {
                        let current = store.profiles.first(where: { $0.id == profile.id }) ?? profile
                        schedule.registerManualRunner(runner, profileId: current.id)
                        await runner.run(profile: current)
                        schedule.clearManualRunner(runner)
                        if runner.wasFullBackup && runner.status == .done {
                            var updated = current
                            updated.lastFullBackupDate = Date()
                            store.update(updated)
                        }
                        runner.runTask = nil
                    }
                    runner.runTask = task
                }
                .buttonStyle(.borderedProminent)
                .disabled(runner.status == .running || labelBusyElsewhere)
                .help(labelBusyElsewhere ? "runner.label_busy" : "")
            }
            .padding(16)
        }
        .frame(width: 560, height: 500)
    }

    /// Another runner (manual, scheduled or queue) is already backing up this label.
    private var labelBusyElsewhere: Bool {
        schedule.isBusy(label: profile.label, excluding: runner)
    }

    // MARK: - Status Badge
    var statusBadge: some View {
        Group {
            switch runner.status {
            case .idle:
                Text("runner.waiting")
                    .foregroundStyle(.secondary)
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("runner.running")
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

// MARK: - Mini Stat
struct MiniRunStat: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(LocalizedStringKey(label))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Log Kind Helpers
private extension BackupRunner.LogEntry.Kind {
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
