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
    @EnvironmentObject var api:   APIService
    @EnvironmentObject var store: ConfigStore
    @EnvironmentObject var activity: ActivityLog
    @State private var selection: NavItem? = .dashboard

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SidebarView(selection: $selection)
        } detail: {
            switch selection {
            case .dashboard, .none: DashboardView(selection: $selection)
            case .backups:          BackupsView()
            case .configs:          BackupConfigsView()
            case .activity:         ActivityView()
            case .cleanup:          CleanupView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        // Consumes the navigation intent set by a notification tap or a "see all" button.
        .onChange(of: activity.wantsActivityTab) { _, want in
            guard want else { return }
            selection = .activity
            activity.wantsActivityTab = false
        }
        .onAppear {
            // The window may have opened after the tap that set the intent.
            if activity.wantsActivityTab {
                selection = .activity
                activity.wantsActivityTab = false
            }
        }
    }
}

// MARK: - Sidebar
struct SidebarView: View {
    @EnvironmentObject var api: APIService
    @EnvironmentObject var activity: ActivityLog
    @Binding var selection: NavItem?

    var body: some View {
        VStack(spacing: 0) {
            // Logo / Brand
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

            Divider()

            // Nav items
            List(NavItem.allCases, selection: $selection) { item in
                Label(LocalizedStringKey(item.rawValue), systemImage: item.icon)
                    .tag(item)
                    // .badge(Int) renders nothing at 0, so no conditional view needed.
                    .badge(item == .activity ? min(activity.unreadCount, 99) : 0)
                    .padding(.vertical, 2)
            }
            .listStyle(.sidebar)

            Spacer(minLength: 0)

            Divider()

            // Connection status
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
        .navigationSplitViewColumnWidth(min: 170, ideal: 200)
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
