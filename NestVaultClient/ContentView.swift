import SwiftUI

enum NavItem: String, CaseIterable, Identifiable {
    case dashboard    = "nav.dashboard"
    case backups      = "nav.backups"
    case configs      = "nav.my_backups"
    case activity     = "nav.activity"
    case cleanup      = "nav.cleanup"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.33percent"
        case .backups:   return "externaldrive"
        case .configs:   return "arrow.up.to.line.compact"
        case .activity:  return "clock.badge.checkmark"
        case .cleanup:   return "trash.slash"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var api:      APIService
    @EnvironmentObject var store:    ConfigStore
    @EnvironmentObject var activity: ActivityLog
    @State private var selectedTab: NavItem = .dashboard

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(LocalizedStringKey(NavItem.dashboard.rawValue),
                systemImage: NavItem.dashboard.icon, value: NavItem.dashboard) {
                DashboardView(selection: navSelection)
            }
            Tab(LocalizedStringKey(NavItem.backups.rawValue),
                systemImage: NavItem.backups.icon, value: NavItem.backups) {
                BackupsView()
            }
            Tab(LocalizedStringKey(NavItem.configs.rawValue),
                systemImage: NavItem.configs.icon, value: NavItem.configs) {
                BackupConfigsView()
            }
            Tab(LocalizedStringKey(NavItem.activity.rawValue),
                systemImage: NavItem.activity.icon, value: NavItem.activity) {
                ActivityView()
            }
            .badge(min(activity.unreadCount, 99))
            Tab(LocalizedStringKey(NavItem.cleanup.rawValue),
                systemImage: NavItem.cleanup.icon, value: NavItem.cleanup) {
                CleanupView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewSidebarHeader { brandHeader }
        .tabViewSidebarBottomBar { connectionFooter }
        .onChange(of: activity.wantsActivityTab) { _, want in
            guard want else { return }
            selectedTab = .activity
            activity.wantsActivityTab = false
        }
        .onAppear {
            if activity.wantsActivityTab {
                selectedTab = .activity
                activity.wantsActivityTab = false
            }
        }
    }

    // Adapter: DashboardView keeps its existing Binding<NavItem?> signature
    private var navSelection: Binding<NavItem?> {
        Binding(
            get: { selectedTab },
            set: { if let v = $0 { selectedTab = v } }
        )
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(
                        colors: [Color(hex: "4F8EF7"), Color(hex: "7B5EA7")],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                Image(systemName: "externaldrive.badge.checkmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("NestVault")
                    .font(.headline)
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var connectionFooter: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(api.isConnected ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                    .frame(width: 20, height: 20)
                Circle()
                    .fill(api.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(api.isConnected ? "sidebar.connected" : "sidebar.disconnected")
                    .font(.caption.weight(.medium))
                if let err = api.connectionError, !api.isConnected {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(api.serverURL)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                Task {
                    await api.checkHealth()
                    if api.isConnected { await api.fetchBackups() }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("sidebar.reconnect")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Color Hex Helper
extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >>  8) & 0xFF) / 255
        let b = Double( int        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
