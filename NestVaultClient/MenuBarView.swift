import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var api:      APIService
    @EnvironmentObject var store:    ConfigStore
    @EnvironmentObject var schedule: ScheduleManager
    @Environment(\.openWindow)   private var openWindow
    @Environment(\.openSettings) private var openSettings

    @State private var isRefreshing = false

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ───────────────────────────────────────────────
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(
                            colors: [Color(hex: "4F8EF7"), Color(hex: "7B5EA7")],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 30, height: 30)
                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("NestVault")
                        .font(.headline)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(api.isConnected ? Color.green : Color.red)
                            .frame(width: 5, height: 5)
                        Text(api.isConnected ? L("menubar.connected") : L("menubar.disconnected"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
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
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                }
                .buttonStyle(.plain)
                .help(LocalizedStringKey("menubar.refresh"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            // ── Active Manual Progress ───────────────────────────────
            if let runner = schedule.activeManualRunner {
                let profile = store.profiles.first { $0.id == schedule.activeManualProfileId }
                MenuRunnerCard(runner: runner, name: profile?.name, badge: "menubar.manual_badge")
            }

            // ── Active Queue Progress ────────────────────────────────
            if let queue = schedule.activeQueue {
                MenuQueueCard(queue: queue)
            }

            // ── Active Schedule Progress ─────────────────────────────
            if let runner = schedule.activeRunner {
                let profile = store.profiles.first { $0.id == schedule.currentProfileId }
                MenuRunnerCard(runner: runner, name: profile?.name, badge: nil)
            }

            // ── Stats Mini Row ───────────────────────────────────────
            HStack(spacing: 0) {
                MiniStatView(
                    value: "\(api.backups.count)",
                    label: "menubar.stat.backups",
                    icon: "externaldrive",
                    color: .blue
                )
                Rectangle().fill(.separator).frame(width: 1)
                MiniStatView(
                    value: "\(api.globalStats.totalVersions)",
                    label: "menubar.stat.versions",
                    icon: "clock.arrow.circlepath",
                    color: .purple
                )
                Rectangle().fill(.separator).frame(width: 1)
                MiniStatView(
                    value: api.globalStats.formattedSize,
                    label: "menubar.stat.storage",
                    icon: "internaldrive",
                    color: .orange
                )
            }
            .frame(height: 60)
            .background(.background.secondary)

            Divider()

            // ── Backups List ─────────────────────────────────────────
            if api.backups.isEmpty {
                HStack {
                    Image(systemName: "externaldrive.trianglebadge.exclamationmark")
                        .foregroundStyle(.secondary)
                    Text(api.isConnected ? LocalizedStringKey("menubar.no_backups") : LocalizedStringKey("menubar.no_connection"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
            } else {
                VStack(spacing: 0) {
                    ForEach(api.backups.prefix(5)) { backup in
                        HStack(spacing: 8) {
                            Image(systemName: "externaldrive.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
                                .frame(width: 18)

                            Text(backup.label)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)

                            Spacer()

                            VStack(alignment: .trailing, spacing: 1) {
                                Text(backup.formattedSize)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let date = backup.lastVersionDate {
                                    Text(date.formatted(.relative(presentation: .named)))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)

                        if backup.label != api.backups.prefix(5).last?.label {
                            Divider().padding(.leading, 40)
                        }
                    }

                    if api.backups.count > 5 {
                        Text(L("menubar.more", api.backups.count - 5))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 6)
                    }
                }
            }

            Divider()

            // ── Actions ──────────────────────────────────────────────
            VStack(spacing: 0) {
                MenuBarActionButton(label: "menubar.open", icon: "macwindow") {
                    NSApp.setActivationPolicy(.regular)
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }

                MenuBarActionButton(label: "menubar.settings", icon: "gear") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }

                Divider().padding(.horizontal, 10)

                MenuBarActionButton(label: "menubar.quit", icon: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.bottom, 4)
        }
        .frame(width: 290)
        .onAppear {
            Task {
                await api.checkHealth()
                await api.fetchBackups()
            }
        }
    }

}

// MARK: - Progress Cards
// Child views with @ObservedObject: MenuBarView itself doesn't observe the
// runner/queue, so inline cards froze at whatever state the menu opened with.
// Each card also owns its running-status gate and trailing Divider.

private struct MenuRunnerCard: View {
    @ObservedObject var runner: BackupRunner
    let name:  String?
    let badge: String?

    var body: some View {
        if runner.status == .running {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.blue)
                        .symbolEffect(.pulse)
                    Text(name ?? "NestVault")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if let badge {
                        Text(LocalizedStringKey(badge))
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                    }
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
                let detail = runner.currentFile.isEmpty
                    ? runner.phaseDescription : runner.currentFile
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.blue.opacity(0.06))
            Divider()
        }
    }
}

private struct MenuQueueCard: View {
    @ObservedObject var queue: BackupQueue

    var body: some View {
        if queue.status == .running, let runner = queue.currentRunner {
            MenuQueueCardContent(queue: queue, runner: runner)
            Divider()
        }
    }
}

private struct MenuQueueCardContent: View {
    @ObservedObject var queue:  BackupQueue
    @ObservedObject var runner: BackupRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle.fill")
                    .foregroundStyle(.purple)
                    .symbolEffect(.pulse)
                Text("queue.title")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(max(0, queue.currentIndex + 1))/\(queue.items.count)")
                    .font(.caption2)
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                Text("\(Int(queue.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: queue.progress)
                .progressViewStyle(.linear)
                .tint(.purple)
            let detail = runner.currentFile.isEmpty
                ? runner.phaseDescription : runner.currentFile
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.purple.opacity(0.05))
    }
}

// MARK: - Mini Stat
struct MiniStatView: View {
    let value: String
    let label: String
    let icon:  String
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(LocalizedStringKey(label))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Action Button
struct MenuBarActionButton: View {
    let label:  String
    let icon:   String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .frame(width: 16)
                Text(LocalizedStringKey(label))
                    .font(.subheadline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
