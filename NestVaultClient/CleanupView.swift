import SwiftUI

struct CleanupView: View {
    @EnvironmentObject var api: APIService

    @State private var mode:         CleanupMode = .all
    @State private var selectedLabel = ""
    @State private var keepCount     = 5
    @State private var isRunning     = false
    @State private var showConfirm   = false
    @State private var results:      [CleanupResult] = []
    @State private var runError:     String?
    @State private var hasRun        = false

    enum CleanupMode { case all, specific }

    var targetBackups: [BackupSummary] {
        switch mode {
        case .all:      return api.backups
        case .specific: return api.backups.filter { $0.label == selectedLabel }
        }
    }

    var totalWillRemove: Int {
        targetBackups.reduce(0) { $0 + max(0, $1.versionCount - keepCount) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {

                // ── Header ───────────────────────────────────────────
                VStack(alignment: .leading, spacing: 4) {
                    Text("cleanup.title")
                        .font(.largeTitle.bold())
                    Text("cleanup.subtitle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                // ── Config Card ──────────────────────────────────────
                VStack(alignment: .leading, spacing: 20) {
                    // Mode picker
                    VStack(alignment: .leading, spacing: 10) {
                        Label("cleanup.target_label", systemImage: "scope")
                            .font(.headline)
                        Picker("cleanup.target_label", selection: $mode) {
                            Text("cleanup.all_backups").tag(CleanupMode.all)
                            Text("cleanup.specific").tag(CleanupMode.specific)
                        }
                        .pickerStyle(.segmented)

                        if mode == .specific {
                            Picker("Backup", selection: $selectedLabel) {
                                Text("cleanup.select_backup").tag("")
                                ForEach(api.backups) { b in
                                    Text(L("cleanup.label_versions", b.label, b.versionCount)).tag(b.label)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }

                    Divider()

                    // Keep count
                    VStack(alignment: .leading, spacing: 10) {
                        Label("cleanup.keep_label", systemImage: "clock.arrow.circlepath")
                            .font(.headline)

                        HStack(spacing: 16) {
                            Stepper(value: $keepCount, in: 1...100) {
                                Text("\(keepCount)")
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    + Text(" " + L("cleanup.keep_count_fmt", keepCount))
                                    .font(.body)
                            }
                        }

                        Text(String(format: NSLocalizedString("cleanup.keep_desc_full", comment: ""), keepCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    // Preview table
                    if !targetBackups.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("cleanup.preview_title", systemImage: "list.bullet.rectangle")
                                .font(.headline)

                            VStack(spacing: 0) {
                                // Header row
                                HStack {
                                    Text("cleanup.col.label")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text("cleanup.col.current")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 60, alignment: .trailing)
                                    Text("cleanup.col.keep")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 60, alignment: .trailing)
                                    Text("cleanup.col.remove")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 70, alignment: .trailing)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.background.tertiary)

                                Divider()

                                ForEach(Array(targetBackups.enumerated()), id: \.element.id) { idx, backup in
                                    let willRemove = max(0, backup.versionCount - keepCount)
                                    HStack {
                                        HStack(spacing: 6) {
                                            Image(systemName: "externaldrive.fill")
                                                .font(.caption)
                                                .foregroundStyle(.blue)
                                            Text(backup.label)
                                                .font(.subheadline.weight(.medium))
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        Text("\(backup.versionCount)")
                                            .font(.subheadline)
                                            .frame(width: 60, alignment: .trailing)

                                        Text("\(min(backup.versionCount, keepCount))")
                                            .font(.subheadline)
                                            .foregroundStyle(.green)
                                            .frame(width: 60, alignment: .trailing)

                                        Group {
                                            if willRemove > 0 {
                                                Text("−\(willRemove)")
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.red)
                                            } else {
                                                Text("—")
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(width: 70, alignment: .trailing)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(idx % 2 == 0 ? Color.clear : Color.primary.opacity(0.02))

                                    if idx < targetBackups.count - 1 { Divider() }
                                }
                            }
                            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4), lineWidth: 1))

                            // Summary
                            if totalWillRemove > 0 {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                    Text(String(format: NSLocalizedString("cleanup.removed_total", comment: ""), totalWillRemove))
                                        .font(.subheadline)
                                }
                            } else {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("cleanup.removed_none")
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator.opacity(0.4), lineWidth: 1))

                // ── Action Button ────────────────────────────────────
                HStack {
                    Spacer()
                    Button {
                        showConfirm = true
                    } label: {
                        HStack {
                            if isRunning { ProgressView().controlSize(.small) }
                            Label(isRunning ? L("cleanup.start_running") : L("cleanup.start_btn"), systemImage: "trash.slash.fill")
                        }
                        .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(isRunning || totalWillRemove == 0 || (mode == .specific && selectedLabel.isEmpty))
                }

                // ── Error ────────────────────────────────────────────
                if let err = runError {
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        Text(err).font(.subheadline)
                    }
                    .padding(14)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.red.opacity(0.3), lineWidth: 1))
                }

                // ── Results ──────────────────────────────────────────
                if hasRun && !results.isEmpty {
                    let totalRemoved = results.reduce(0) { $0 + $1.removed }
                    let totalFreed   = results.reduce(0) { $0 + $1.storageFilesRemoved }

                    VStack(alignment: .leading, spacing: 16) {
                        Label("cleanup.result_title", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(.green)

                        // Summary stats
                        HStack(spacing: 0) {
                            ResultStat(value: "\(results.count)", label: "cleanup.stat.labels")
                            Divider()
                            ResultStat(value: "\(totalRemoved)", label: "cleanup.stat.removed")
                            Divider()
                            ResultStat(value: "\(totalFreed)", label: "cleanup.stat.freed")
                        }
                        .frame(height: 70)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4), lineWidth: 1))

                        // Per-label results
                        VStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.label) { idx, r in
                                let icon    = r.removed > 0 ? "checkmark.circle.fill" : "minus.circle.fill"
                                let iconClr = r.removed > 0 ? Color.green : Color.secondary
                                let detail  = L("cleanup.result_detail", r.kept, r.removed, r.storageFilesRemoved)
                                HStack(spacing: 10) {
                                    Image(systemName: icon)
                                        .foregroundStyle(iconClr)
                                    Text(r.label)
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    Text(detail)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                if idx < results.count - 1 { Divider() }
                            }
                        }
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4), lineWidth: 1))
                    }
                    .padding(20)
                    .background(.green.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.green.opacity(0.25), lineWidth: 1))
                }
            }
            .padding(28)
        }
        .onAppear { Task { await api.fetchBackups() } }
        .alert("cleanup.confirm_title", isPresented: $showConfirm) {
            Button("common.cancel", role: .cancel) {}
            Button("cleanup.confirm_btn", role: .destructive) { runCleanup() }
        } message: {
            Text(L("cleanup.confirm_msg", totalWillRemove))
        }
    }

    func runCleanup() {
        isRunning = true
        hasRun    = false
        runError  = nil
        results   = []

        Task {
            switch mode {
            case .all:
                let outcome = await api.cleanupAll(keep: keepCount)
                results = outcome.results
                if !outcome.errors.isEmpty {
                    runError = outcome.errors
                        .map { "\($0.label): \($0.message)" }
                        .joined(separator: "\n")
                }
            case .specific:
                do {
                    let r = try await api.cleanup(label: selectedLabel, keep: keepCount)
                    results = [r]
                } catch {
                    runError = error.localizedDescription
                }
            }
            hasRun = !results.isEmpty
            await api.fetchBackups()
            isRunning = false
        }
    }
}

struct ResultStat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text(LocalizedStringKey(label))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
