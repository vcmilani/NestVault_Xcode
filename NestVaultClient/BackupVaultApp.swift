import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(windowWillClose),
                       name: NSWindow.willCloseNotification, object: nil)
        nc.addObserver(self, selector: #selector(windowDidBecomeMain),
                       name: NSWindow.didBecomeMainNotification, object: nil)
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        guard isMainAppWindow(window) else { return }
        DispatchQueue.main.async {
            let hasVisibleMain = NSApp.windows.contains {
                $0 != window && self.isMainAppWindow($0) && $0.isVisible
            }
            if !hasVisibleMain {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    @objc private func windowDidBecomeMain(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        guard isMainAppWindow(window) else { return }
        NSApp.setActivationPolicy(.regular)
    }

    private func isMainAppWindow(_ window: NSWindow) -> Bool {
        guard let id = window.identifier?.rawValue else { return false }
        return id.contains("main")
    }

    // MARK: - Notification taps

    /// Tapping a run notification brings the app forward and routes to Activity.
    /// The intent is sticky (ContentView clears it on consumption) so it still works
    /// when the main window is closed at tap time and opened later.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let eventId = (info["eventId"] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            if info["nav"] as? String == "activity" {
                ActivityLog.shared?.focusEventId = eventId
                ActivityLog.shared?.wantsActivityTab = true
            }
            completionHandler()
        }
    }

    /// Show run notifications even while the app is frontmost — the policy on whether
    /// to post one at all already lives in RunRecorder.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct NestVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var api      = APIService()
    @StateObject private var store    = ConfigStore()
    @StateObject private var power    = PowerMonitor()
    @StateObject private var schedule = ScheduleManager()
    @StateObject private var activity = ActivityLog()

    init() {
        // TODO: Remover após algumas versões — migração de com.vcm.backupvault.app
        LegacyMigration.runIfNeeded()
    }

    var body: some Scene {

        // ── Main Window ──────────────────────────────────────────────
        WindowGroup("NestVault", id: "main") {
            ContentView()
                .environmentObject(api)
                .environmentObject(store)
                .environmentObject(power)
                .environmentObject(schedule)
                .environmentObject(activity)
                .frame(minWidth: 960, idealWidth: 1160,
                       minHeight: 640, idealHeight: 780)
                .onAppear {
                    Task {
                        await api.checkHealth()
                        await api.fetchBackups()
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1160, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("app.refresh_backups") {
                    Task { await api.fetchBackups() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("app.check_connection") {
                    Task { await api.checkHealth() }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

        // ── Menu Bar Extra ───────────────────────────────────────────
        MenuBarExtra {
            MenuBarView()
                .environmentObject(api)
                .environmentObject(store)
                .environmentObject(power)
                .environmentObject(schedule)
                .environmentObject(activity)
        } label: {
            let img = api.isConnected
                ? "externaldrive.badge.checkmark"
                : "externaldrive.badge.exclamationmark"
            Image(systemName: img)
                .symbolRenderingMode(.hierarchical)
                .task {
                    schedule.bind(api: api, store: store, power: power, activity: activity)
                    schedule.start()
                    await api.checkHealth()
                    await api.fetchBackups()
                }
        }
        .menuBarExtraStyle(.window)

        // ── Settings ─────────────────────────────────────────────────
        Settings {
            SettingsView()
                .environmentObject(api)
                .environmentObject(store)
                .environmentObject(power)
                .environmentObject(schedule)
                .environmentObject(activity)
        }
    }
}
