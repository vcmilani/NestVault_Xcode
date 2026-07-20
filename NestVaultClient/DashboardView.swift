import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var api: APIService
    @State private var isRefreshing = false

    var stats: GlobalStats { api.globalStats }

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

                // ── Recent Backups ───────────────────────────────────────
                if !api.backups.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("dashboard.active_backups")
                                .font(.headline)
                            Spacer()
                            if api.isLoadingBackups {
                                ProgressView().controlSize(.small)
                            }
                        }

                        VStack(spacing: 0) {
                            ForEach(Array(api.backups.enumerated()), id: \.element.id) { idx, backup in
                                BackupRowView(backup: backup)
                                if idx < api.backups.count - 1 {
                                    Divider().padding(.leading, 52)
                                }
                            }
                        }
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5), lineWidth: 1))
                    }
                }

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
