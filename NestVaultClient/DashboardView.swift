import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var api: APIService
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var schedule: ScheduleManager
    @EnvironmentObject var activity: ActivityLog
    @Binding var selection: NavItem?

    @State private var isRefreshing = false
    @State private var showQueue = false
    @AppStorage("dashboard.showOthers") private var showOthers = false

    var stats: GlobalStats { api.globalStats }

    // MARK: - Local ↔ server join
    //
    // The label is free text and the only join key between a local profile and a server
    // backup. Match trimmed and case-insensitively: a stray case edit would otherwise
    // make a backup jump silently into "others", which reads to the user as data loss.

    private func joinKey(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var machineRows: [MachineBackupRow] {
        let byLabel = Dictionary(api.backups.map { (joinKey($0.label), $0) },
                                 uniquingKeysWith: { a, b in
                                     a.versionCount >= b.versionCount ? a : b
                                 })
        // Preserves the user's own ordering from ConfigStore.move — sorting by date here
        // would silently discard an explicit preference.
        return store.profiles.map { p in
            MachineBackupRow(profile: p,
                             summary: p.label.isEmpty ? nil : byLabel[joinKey(p.label)])
        }
    }

    private var otherBackups: [BackupSummary] {
        let mine = Set(store.profiles.map { joinKey($0.label) }).subtracting([""])
        return api.backups
            .filter { !mine.contains(joinKey($0.label)) }
            .sorted { ($0.lastVersionDate ?? .distantPast) > ($1.lastVersionDate ?? .distantPast) }
    }

    private var canRunQueue: Bool {
        api.isConnected && schedule.activeQueue == nil && !schedule.isRunningScheduled
            && machineRows.contains(where: { $0.isRunnable })
    }

    private var recentEvents: [ActivityEvent] { Array(activity.recent.prefix(3)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {

                // ── Header ──────────────────────────────────────────────
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("dashboard.title")
                            .font(.largeTitle.bold())
                        Text("NestVault \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        isRefreshing = true
                        Task {
                            await api.checkHealth()
                            await api.fetchBackups()
                            isRefreshing = false
                        }
                    } label: {
                        Label(L("dashboard.refresh"), systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .disabled(isRefreshing)
                }

                // ── Connection Banner ────────────────────────────────────
                if !api.isConnected {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("dashboard.server_unreachable")
                                .font(.subheadline.weight(.semibold))
                            Text(api.connectionError ?? L("dashboard.check_settings"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.orange.opacity(0.35), lineWidth: 1))
                }

                // ── Stats Grid ───────────────────────────────────────────
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                    StatCard(title: "dashboard.stat.backups",          value: "\(stats.totalBackups)",       icon: "externaldrive",          color: .blue)
                    StatCard(title: "dashboard.stat.versions",           value: "\(stats.totalVersions)",      icon: "clock.arrow.circlepath", color: .purple)
                    StatCard(title: "dashboard.stat.files",          value: stats.totalFiles.formatted(),  icon: "doc.on.doc",             color: .green)
                    StatCard(title: "dashboard.stat.storage",     value: stats.formattedSize,           icon: "internaldrive",          color: .orange)
                }

                // ── This Machine ─────────────────────────────────────────
                machineSection

                // ── Recent Activity ──────────────────────────────────────
                recentActivitySection

                // ── Other Backups on the Server ──────────────────────────
                othersSection

                // ── How It Works ─────────────────────────────────────────
                VStack(alignment: .leading, spacing: 12) {
                    Text("dashboard.how_it_works")
                        .font(.headline)

                    HStack(spacing: 14) {
                        InfoCard(
                            icon: "arrow.up.to.line.compact",
                            color: .blue,
                            title: "dashboard.info.versions.title",
                            bodyText: "dashboard.info.versions.body"
                        )
                        InfoCard(
                            icon: "doc.badge.arrow.up",
                            color: .green,
                            title: "dashboard.info.dedup.title",
                            bodyText: "dashboard.info.dedup.body"
                        )
                        InfoCard(
                            icon: "doc.on.doc",
                            color: .blue,
                            title: "dashboard.info.deleted.title",
                            bodyText: "dashboard.info.deleted.body"
                        )
                        InfoCard(
                            icon: "lock.shield",
                            color: .purple,
                            title: "dashboard.info.isolation.title",
                            bodyText: "dashboard.info.isolation.body"
                        )
                    }
                }
            }
            .padding(28)
        }
        .sheet(isPresented: $showQueue) {
            BackupQueueSheet()
                .environmentObject(api)
                .environmentObject(store)
                .environmentObject(schedule)
                .environmentObject(activity)
        }
    }

    // MARK: - This Machine

    private var machineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("dashboard.machine.title")
                    .font(.headline)
                Text(L("dashboard.machine.subtitle", machineRows.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if api.isLoadingBackups {
                    ProgressView().controlSize(.small)
                }
                if let queue = schedule.activeQueue, queue.status == .running {
                    DashboardQueueStrip(queue: queue)
                } else {
                    Button {
                        showQueue = true
                    } label: {
                        Label(L("dashboard.machine.run_all"), systemImage: "play.circle")
                            .font(.subheadline)
                    }
                    .disabled(!canRunQueue)
                }
            }

            if store.profiles.isEmpty {
                VStack(spacing: 12) {
                    PlaceholderView(title: "dashboard.machine.empty",
                                    icon: "externaldrive.badge.plus",
                                    description: "dashboard.machine.empty_hint")
                    Button("dashboard.machine.go_configure") { selection = .configs }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5), lineWidth: 1))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(machineRows.enumerated()), id: \.element.id) { idx, row in
                        MachineBackupRowView(row: row)
                        if idx < machineRows.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5), lineWidth: 1))
            }
        }
    }

    // MARK: - Recent Activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("dashboard.recent.title")
                    .font(.headline)
                Spacer()
                Button("dashboard.recent.see_all") { selection = .activity }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                    .disabled(activity.events.isEmpty)
            }

            if recentEvents.isEmpty {
                Text("dashboard.recent.empty")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5), lineWidth: 1))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recentEvents.enumerated()), id: \.element.id) { idx, event in
                        CompactActivityRow(event: event)
                        if idx < recentEvents.count - 1 {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5), lineWidth: 1))
            }
        }
    }

    // MARK: - Others

    @ViewBuilder
    private var othersSection: some View {
        if !otherBackups.isEmpty {
            let total = otherBackups.reduce(Int64(0)) { $0 + $1.totalSizeBytes }
            DisclosureGroup(isExpanded: $showOthers) {
                VStack(spacing: 0) {
                    ForEach(Array(otherBackups.enumerated()), id: \.element.id) { idx, backup in
                        BackupRowView(backup: backup)
                        if idx < otherBackups.count - 1 {
                            Divider().padding(.leading, 52)
                        }
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5), lineWidth: 1))
                .padding(.top, 8)
            } label: {
                HStack {
                    Text("dashboard.others.title")
                        .font(.headline)
                    Text(L("dashboard.others.subtitle", otherBackups.count,
                           ByteCountFormatter.string(fromByteCount: total, countStyle: .file)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Machine Row Model

/// A local profile paired with its server counterpart, if the server has one yet.
struct MachineBackupRow: Identifiable {
    let profile: BackupProfile
    let summary: BackupSummary?
    var id: UUID { profile.id }

    var isRunnable: Bool {
        profile.enabled && !profile.label.isEmpty && !profile.sourcePath.isEmpty
    }
}

// MARK: - Machine Row

struct MachineBackupRowView: View {
    @EnvironmentObject var api: APIService
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var schedule: ScheduleManager

    let row: MachineBackupRow
    @State private var showRunner = false

    private var profile: BackupProfile { row.profile }
    private var activeRunner: BackupRunner? { schedule.anyRunner(for: profile.id) }
    private var busyElsewhere: Bool { schedule.isBusy(label: profile.label) }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(statusTint.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: statusGlyph)
                    .font(.system(size: 15))
                    .foregroundStyle(statusTint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 120, alignment: .leading)

            Spacer(minLength: 8)

            if let runner = activeRunner {
                RowLiveProgress(runner: runner)
                    .frame(maxWidth: 240)
            } else {
                metrics
            }

            Button(activeRunner != nil ? L("dashboard.machine.view") : L("dashboard.machine.run")) {
                showRunner = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(runDisabled)
            .help(runHelp)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(profile.enabled ? 1 : 0.55)
        .sheet(isPresented: $showRunner) {
            // Identical to the presentation in BackupConfigsView so manual runs keep a
            // single code path, including re-attaching to an already-running backup.
            BackupRunnerSheet(profile: profile, api: api,
                              existingRunner: schedule.runnerIfActive(for: profile.id))
        }
    }

    // MARK: Pieces

    private var metrics: some View {
        HStack(spacing: 20) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.summary.map { "\($0.versionCount)" } ?? "—")
                    .font(.subheadline.weight(.medium))
                Text("dashboard.stat.versions_label")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.summary?.formattedSize ?? "—")
                    .font(.subheadline.weight(.medium))
                Text("general.storage")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .trailing, spacing: 2) {
                if let last = profile.lastRun ?? row.summary?.lastVersionDate {
                    Text(last.formatted(.relative(presentation: .named)))
                        .font(.caption.weight(.medium))
                } else {
                    Text("dashboard.machine.never_run")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text("dashboard.last_run")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 96, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 2) {
                if let next = schedule.nextRun(for: profile) {
                    Text(next.formatted(.relative(presentation: .named)))
                        .font(.caption.weight(.medium))
                } else {
                    Text("—").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Text("dashboard.machine.next_run")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 96, alignment: .trailing)
        }
    }

    private var subtitle: String {
        if profile.label.isEmpty { return L("dashboard.machine.no_label") }
        if row.summary == nil    { return L("dashboard.machine.not_on_server", profile.label) }
        return profile.label
    }

    private var statusGlyph: String {
        if activeRunner != nil { return "arrow.up.circle.fill" }
        switch profile.lastRunStatus {
        case "done":      return "checkmark.circle.fill"
        case "skipped":   return "bolt.circle.fill"
        case "failed":    return "xmark.circle.fill"
        case "cancelled": return "stop.circle.fill"
        default:          return "circle.dashed"
        }
    }

    private var statusTint: Color {
        if activeRunner != nil { return .blue }
        switch profile.lastRunStatus {
        case "done":      return .green
        case "skipped":   return .teal
        case "failed":    return .red
        case "cancelled": return .orange
        default:          return .secondary
        }
    }

    private var runDisabled: Bool {
        if activeRunner != nil { return false }          // "View" always works
        return !row.isRunnable || !api.isConnected || busyElsewhere
    }

    private var runHelp: String {
        if activeRunner != nil          { return "" }
        if profile.label.isEmpty        { return L("dashboard.machine.no_label") }
        if profile.sourcePath.isEmpty   { return L("dashboard.machine.no_source") }
        if !profile.enabled             { return L("dashboard.machine.disabled") }
        if !api.isConnected             { return L("dashboard.server_unreachable") }
        if busyElsewhere                { return L("dashboard.machine.busy") }
        return ""
    }
}

// MARK: - Live Progress
//
// Its own view with @ObservedObject: the parent only observes ScheduleManager, so
// reading runner.progress inline would freeze the bar at its first rendered value.
// Same fix already applied in MenuBarView and BackupQueueView.

private struct RowLiveProgress: View {
    @ObservedObject var runner: BackupRunner

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if runner.isIndeterminatePhase {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                ProgressView(value: runner.progress)
                    .progressViewStyle(.linear)
            }
            Text(runner.phaseDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Queue Strip

private struct DashboardQueueStrip: View {
    @ObservedObject var queue: BackupQueue

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: queue.progress)
                .progressViewStyle(.linear)
                .frame(width: 110)
            Text("\(queue.doneCount)/\(queue.items.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Compact Activity Row

struct CompactActivityRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: event.glyph)
                .font(.system(size: 14))
                .foregroundStyle(event.tint)
                .frame(width: 20)
            Text(event.profileName)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let chip = event.counterChips.first {
                HStack(spacing: 4) {
                    Text("\(chip.value)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(chip.tint)
                    Text(LocalizedStringKey(chip.key))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(event.date.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }
}

// MARK: - Stat Card
struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(color)
            }
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(LocalizedStringKey(title))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(color.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - Backup Row
struct BackupRowView: View {
    let backup: BackupSummary

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(backup.label)
                    .font(.subheadline.weight(.semibold))
                if let client = backup.clientName, client != backup.label {
                    Text(client)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 20) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(backup.versionCount)")
                        .font(.subheadline.weight(.medium))
                    Text("dashboard.stat.versions_label")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(backup.formattedSize)
                        .font(.subheadline.weight(.medium))
                    Text("general.storage")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let date = backup.lastVersionDate {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(date.formatted(.relative(presentation: .named)))
                            .font(.caption.weight(.medium))
                        Text("dashboard.last_version")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 90, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Info Card
struct InfoCard: View {
    let icon: String
    let color: Color
    let title: String
    let bodyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(color)
            }
            Text(LocalizedStringKey(title))
                .font(.subheadline.weight(.semibold))
            Text(LocalizedStringKey(bodyText))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4), lineWidth: 1))
    }
}
