import Foundation
import SwiftUI
import UserNotifications

/// Watches all profiles and runs their backups when their schedule is due.
/// Respects: power source, network reachability, and active backups (no overlap).
@MainActor
final class ScheduleManager: ObservableObject {

    @Published var isRunningScheduled: Bool = false
    @Published var currentProfileId: UUID?
    @Published var lastTickDate: Date = .distantPast

    /// User preference: pause schedule when on battery
    @AppStorage("schedule.pauseOnBattery") var pauseOnBattery: Bool = true

    /// Minimum battery percent required to run on battery (when not paused)
    @AppStorage("schedule.minBatteryPercent") var minBatteryPercent: Int = 50

    private weak var api: APIService?
    private weak var store: ConfigStore?
    private weak var power: PowerMonitor?
    @Published var activeRunner: BackupRunner?

    // Manual single-run tracking
    @Published var activeManualRunner: BackupRunner?
    @Published var activeManualProfileId: UUID?

    // Queue tracking
    @Published var activeQueue: BackupQueue?

    // Schedule anchors: a schedule that never ran fires from when it was enabled,
    // not from the distant past (which made a fresh daily schedule fire immediately
    // instead of at the configured time). Anchors are in-memory on purpose — after
    // the first run, lastRun takes over.
    private var profileAnchors: [UUID: Date] = [:]
    private var queueAnchor = Date()

    // Queue schedule — persisted as JSON in UserDefaults
    @Published var queueSchedule: BackupSchedule {
        didSet {
            queueAnchor = Date()
            guard let data = try? JSONEncoder().encode(queueSchedule) else { return }
            UserDefaults.standard.set(data, forKey: "queue.schedule.config")
        }
    }

    // Last time the scheduled queue fired
    @Published var queueScheduleLastRun: Date? {
        didSet { UserDefaults.standard.set(queueScheduleLastRun, forKey: "queue.schedule.lastRun") }
    }

    /// Next scheduled queue run date (nil if schedule is off)
    var nextQueueRun: Date? {
        guard queueSchedule.enabled else { return nil }
        return queueSchedule.nextRun(after: Date(), lastRun: queueScheduleLastRun ?? queueAnchor)
    }

    private var timer: Timer?

    init() {
        if let data = UserDefaults.standard.data(forKey: "queue.schedule.config"),
           let saved = try? JSONDecoder().decode(BackupSchedule.self, from: data) {
            _queueSchedule = Published(wrappedValue: saved)
        } else {
            _queueSchedule = Published(wrappedValue: BackupSchedule())
        }
        _queueScheduleLastRun = Published(wrappedValue:
            UserDefaults.standard.object(forKey: "queue.schedule.lastRun") as? Date
        )
    }

    func bind(api: APIService, store: ConfigStore, power: PowerMonitor) {
        self.api   = api
        self.store = store
        self.power = power
    }

    func start() {
        BackupNotifier.requestAuthorizationIfNeeded()
        timer?.invalidate()
        // Check every 30 seconds — light enough to be background-friendly
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Fire immediately on start
        Task { @MainActor in tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Tick

    func tick() {
        lastTickDate = Date()
        guard !isRunningScheduled else { return }
        guard activeManualRunner == nil, activeQueue == nil else { return }
        guard let store, let api, let power else { return }

        // Skip if API not connected
        guard api.isConnected else {
            Task { await api.checkHealth() }
            return
        }

        // Skip if on battery and user disabled it (or below threshold)
        if power.powerSource == .battery {
            if pauseOnBattery { return }
            if power.batteryPercent < minBatteryPercent { return }
        }

        // Skip if not on local network
        guard power.isOnLocalNetwork else { return }

        // Maintain anchors: record when each profile's schedule was first seen enabled;
        // drop the anchor when disabled so re-enabling re-anchors at "now".
        for p in store.profiles {
            if p.schedule.enabled {
                if profileAnchors[p.id] == nil { profileAnchors[p.id] = Date() }
            } else {
                profileAnchors[p.id] = nil
            }
        }

        // Queue schedule fires before individual profiles
        if queueSchedule.isDue(now: Date(), lastRun: queueScheduleLastRun ?? queueAnchor) {
            let profiles = store.profiles.filter {
                $0.enabled && !$0.label.isEmpty && !$0.sourcePath.isEmpty
            }
            if !profiles.isEmpty {
                Task { await runScheduledQueue(profiles: profiles) }
                return
            }
        }

        // Find a due individual profile
        let due = store.profiles.first { profile in
            profile.enabled
            && !profile.label.isEmpty
            && !profile.sourcePath.isEmpty
            && profile.schedule.enabled
            && profile.schedule.isDue(now: Date(),
                                      lastRun: profile.lastRun ?? profileAnchors[profile.id])
        }

        guard let profile = due else { return }

        Task { await runScheduled(profile: profile) }
    }

    // MARK: - Scheduled Queue Run

    private func runScheduledQueue(profiles: [BackupProfile]) async {
        guard let api else { return }
        let q = BackupQueue(api: api, profiles: profiles)
        registerQueue(q)
        queueScheduleLastRun = Date()
        await q.run()
        clearQueue(q)
        BackupNotifier.notify(
            title: L("notify.queue_title"),
            body:  L("notify.queue_body", q.doneCount, q.failedCount))
    }

    // MARK: - Individual Profile Run

    private func runScheduled(profile: BackupProfile) async {
        guard let api, let store else { return }

        isRunningScheduled = true
        currentProfileId = profile.id

        let runner = BackupRunner(api: api)
        self.activeRunner = runner
        await runner.run(profile: profile)

        // Persist last run
        var updated = profile
        updated.lastRun = Date()
        switch runner.status {
        case .done:
            updated.lastRunStatus = "done"
            BackupNotifier.notify(
                title: L("notify.done_title"),
                body:  L("notify.done_body", profile.name,
                         runner.stats.uploaded, runner.stats.registered, runner.stats.errors))
        case .failed:
            updated.lastRunStatus = "failed"
            BackupNotifier.notify(
                title: L("notify.failed_title"),
                body:  L("notify.failed_body", profile.name))
        case .cancelled: updated.lastRunStatus = "cancelled"
        default:         updated.lastRunStatus = "unknown"
        }
        if runner.wasFullBackup && runner.status == .done {
            updated.lastFullBackupDate = Date()
        }
        store.update(updated)

        activeRunner = nil
        currentProfileId = nil
        isRunningScheduled = false
    }

    // MARK: - Manual Run Registration

    func registerManualRunner(_ runner: BackupRunner, profileId: UUID) {
        activeManualRunner  = runner
        activeManualProfileId = profileId
    }

    func clearManualRunner(_ runner: BackupRunner) {
        guard activeManualRunner === runner else { return }
        activeManualRunner  = nil
        activeManualProfileId = nil
    }

    // MARK: - Queue Registration

    func registerQueue(_ queue: BackupQueue) {
        activeQueue = queue
    }

    func clearQueue(_ queue: BackupQueue) {
        guard activeQueue === queue else { return }
        activeQueue = nil
    }

    // MARK: - Helpers

    /// Returns the next scheduled individual-profile run, for the menu bar UI.
    func nextScheduledRun() -> (profile: BackupProfile, date: Date)? {
        guard let store else { return nil }
        let candidates: [(BackupProfile, Date)] = store.profiles.compactMap { p in
            guard p.enabled, p.schedule.enabled,
                  let next = p.schedule.nextRun(after: Date(),
                                                lastRun: p.lastRun ?? profileAnchors[p.id])
            else { return nil }
            return (p, next)
        }
        return candidates.min(by: { $0.1 < $1.1 })
    }

    /// Active runner for this profile, if one is running (manual or scheduled) —
    /// lets the runner sheet re-attach instead of creating a duplicate runner.
    func runnerIfActive(for profileId: UUID) -> BackupRunner? {
        if activeManualProfileId == profileId, let r = activeManualRunner, r.status == .running {
            return r
        }
        if currentProfileId == profileId, let r = activeRunner, r.status == .running {
            return r
        }
        return nil
    }

    /// True when a backup for this label is already running somewhere else
    /// (another manual runner, a scheduled runner, or the queue's current item).
    func isBusy(label: String, excluding runner: BackupRunner? = nil) -> Bool {
        if let r = activeManualRunner, r !== runner, r.status == .running,
           labelFor(profileId: activeManualProfileId) == label { return true }
        if let r = activeRunner, r !== runner, r.status == .running,
           labelFor(profileId: currentProfileId) == label { return true }
        if let q = activeQueue, q.status == .running,
           q.currentProfile?.label == label { return true }
        return false
    }

    private func labelFor(profileId: UUID?) -> String? {
        guard let profileId else { return nil }
        return store?.profiles.first(where: { $0.id == profileId })?.label
    }
}

// MARK: - Local Notifications

/// Delivers completion/failure notifications for background (scheduled) backups —
/// the Dock bounce is invisible while the app runs as a menu-bar accessory.
enum BackupNotifier {

    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func notify(title: String, body: String) {
        let content   = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
