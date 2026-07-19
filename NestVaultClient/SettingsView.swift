import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var api:      APIService
    @EnvironmentObject var schedule: ScheduleManager
    @EnvironmentObject var power: PowerMonitor
    @StateObject private var loginItem = LoginItemManager()
    @State private var isTesting = false
    @State private var testMsg: String?
    @State private var testOK   = false
    @State private var showKey  = false

    var body: some View {
        TabView {
            generalTab.tabItem      { Label("settings.general",        systemImage: "gearshape") }
            serverTab.tabItem       { Label("settings.server",         systemImage: "network") }
            queueScheduleTab.tabItem { Label("settings.queue_schedule", systemImage: "calendar.badge.clock") }
            aboutTab.tabItem        { Label("settings.about",          systemImage: "info.circle") }
        }
        .padding(6)
        .frame(width: 540)
        .fixedSize()
    }

    // MARK: - General Tab
    var generalTab: some View {
        Form {
            Section("settings.startup") {
                Toggle("settings.start_on_login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.toggle($0) }
                ))
                if loginItem.requiresApproval {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("settings.requires_approval")
                            .font(.caption)
                        Spacer()
                        Button("settings.open_settings") {
                            loginItem.openSettings()
                        }
                        .controlSize(.small)
                    }
                }
                if let err = loginItem.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            Section("settings.system_status") {
                LabeledContent {
                    HStack(spacing: 6) {
                        Image(systemName: power.isOnLocalNetwork
                              ? "wifi" : "wifi.slash")
                            .foregroundStyle(power.isOnLocalNetwork ? .green : .secondary)
                        Text(power.isOnLocalNetwork
                             ? (power.networkInterface.isEmpty ? "online" : power.networkInterface)
                             : "offline")
                    }
                    .font(.subheadline)
                } label: {
                    Text("settings.network")
                }
                LabeledContent {
                    HStack(spacing: 6) {
                        Image(systemName: power.powerSource == .ac
                              ? "bolt.fill" : "battery.100")
                            .foregroundStyle(power.powerSource == .ac ? .green : .blue)
                        Text(powerSourceLabel)
                    }
                    .font(.subheadline)
                } label: {
                    Text("settings.power")
                }
                if api.backoff.failureCount > 0 {
                    LabeledContent("settings.backoff") {
                        Text(api.backoff.humanReadable)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(6)
    }

    var powerSourceLabel: String {
        switch power.powerSource {
        case .ac:      return L("settings.power.ac", power.batteryPercent)
        case .battery: return L("settings.power.battery", power.batteryPercent)
        case .unknown: return "—"
        }
    }

    // MARK: - Server Tab
    var serverTab: some View {
        Form {
            Section(L("settings.connection")) {
                LabeledContent(L("settings.server_url")) {
                    TextField("http://192.168.1.100:8000", text: $api.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .font(.body.monospaced())
                        .onChange(of: api.serverURL) { _,_ in testMsg = nil }
                }

                LabeledContent(L("settings.api_key")) {
                    HStack {
                        if showKey {
                            TextField("settings.api_key_placeholder", text: $api.apiKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                        } else {
                            SecureField("settings.api_key_placeholder", text: $api.apiKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                        }
                        Button(showKey ? L("settings.hide") : L("settings.show")) {
                            showKey.toggle()
                        }
                        .font(.caption)
                    }
                }

                LabeledContent(L("settings.current_status")) {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(api.isConnected ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                                .frame(width: 18, height: 18)
                            Circle()
                                .fill(api.isConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                        }
                        Text(api.isConnected ? L("common.connected") : (api.connectionError ?? L("common.disconnected")))
                            .foregroundStyle(api.isConnected ? .green : .red)
                            .font(.subheadline)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("settings.save_button") {
                        api.saveSettings()
                        isTesting = true
                        testMsg = nil
                        Task {
                            await api.checkHealth()
                            if api.isConnected {
                                await api.fetchBackups()
                                testOK = true
                                testMsg = L("settings.test_ok", api.backups.count)
                            } else {
                                testOK = false
                                testMsg = api.connectionError ?? L("settings.test_fail")
                            }
                            isTesting = false
                        }
                    }
                    .disabled(isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                }

                if let msg = testMsg {
                    HStack {
                        Image(systemName: testOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(testOK ? .green : .red)
                        Text(msg)
                            .font(.subheadline)
                            .foregroundStyle(testOK ? .green : .red)
                    }
                }
            }

            Section(L("settings.tips_title")) {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsTip(icon: "key.fill",   color: .orange, text: L("settings.tip.api_key"))
                    SettingsTip(icon: "network",    color: .blue,   text: L("settings.tip.server_ip"))
                    SettingsTip(icon: "wifi.slash", color: .red,    text: L("settings.tip.systemd"))
                }
            }
        }
        .formStyle(.grouped)
        .padding(6)
    }

    // MARK: - Queue Schedule Tab

    var queueScheduleTab: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.purple.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.purple)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.queue_sched.title").font(.headline)
                    Text("settings.queue_sched.subtitle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if schedule.queueSchedule.enabled {
                    Text(scheduleSummary)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.purple)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Schedule editor
            ScheduleEditor(schedule: $schedule.queueSchedule)
                .frame(height: 320)

            Divider()

            // Last / next run row
            HStack(spacing: 0) {
                runInfoCell(
                    icon: "clock.arrow.circlepath",
                    label: LocalizedStringKey("settings.queue_sched.last_run"),
                    value: schedule.queueScheduleLastRun.map { Text($0, style: .relative) }
                        ?? Text("settings.queue_sched.never")
                )
                Divider()
                runInfoCell(
                    icon: "clock.badge.checkmark",
                    label: LocalizedStringKey("settings.queue_sched.next_run"),
                    value: schedule.nextQueueRun.map { Text($0, style: .relative) }
                        ?? Text("settings.queue_sched.never")
                )
            }
            .frame(height: 56)
            .background(.background.secondary)
        }
    }

    @ViewBuilder
    private func runInfoCell(icon: String, label: LocalizedStringKey, value: Text) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            value.font(.caption.weight(.medium)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var scheduleSummary: String {
        switch schedule.queueSchedule.frequency {
        case .off:    return L("schedule.summary.off")
        case .hourly: return L("schedule.summary.hourly")
        case .daily:  return L("schedule.summary.daily")
        case .weekly: return L("schedule.summary.weekly")
        case .custom: return L("schedule.summary.custom")
        }
    }

    // MARK: - About Tab
    var aboutTab: some View {
        Form {
            Section("settings.about.app_section") {
                LabeledContent("settings.about.version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                if !api.serverVersion.isEmpty {
                    LabeledContent(L("settings.about.server_version"), value: api.serverVersion)
                }
                LabeledContent(L("settings.about.min_macos"), value: "14.0 (Sonoma)")
                LabeledContent(L("settings.about.server_stack"), value: "FastAPI + SQLite + SHA-256")
            }
            Section("settings.about.repo_section") {
                LabeledContent("GitHub") {
                    Link("vcmilani/backup_files",
                         destination: URL(string: "https://github.com/vcmilani/backup_files")!)
                }
                LabeledContent("API Docs") {
                    Link("settings.about.swagger",
                         destination: URL(string: "\(api.serverURL)/docs")!)
                }
                LabeledContent("settings.about.web_dashboard") {
                    Link("settings.about.open_browser",
                         destination: URL(string: api.serverURL)!)
                }
            }
            Section("settings.about.features_section") {
                LabeledContent("settings.about.dedup")      { Text(L("settings.about.dedup_value")) }
                LabeledContent("settings.about.versioning") { Text("Timestamp ISO 8601") }
                LabeledContent("settings.about.isolation")  { Text(L("settings.about.isolation_value")) }
                LabeledContent("settings.about.cleanup")    { Text(L("settings.about.cleanup_value")) }
            }
        }
        .formStyle(.grouped)
        .padding(6)
    }
}

struct SettingsTip: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 16)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
