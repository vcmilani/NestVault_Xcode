import Foundation

// MARK: - Activity Event
//
// One completed operation — a backup, a restore, a queue run or a cleanup.
// Every stored property is a `let` of a Sendable type so the struct is implicitly
// Sendable and can cross into `ActivityStore` (an actor) without a copy dance.

struct ActivityEvent: Identifiable, Codable, Hashable {

    enum Kind: String, Codable { case backup, restore, queue, cleanup }
    enum Trigger: String, Codable { case manual, scheduled, queued }

    /// `.skipped` means the run completed via smart skip (absorb-only, nothing uploaded).
    enum Outcome: String, Codable { case done, failed, cancelled, skipped }

    struct Counters: Codable, Hashable {
        // Backup
        var uploaded = 0, registered = 0, cached = 0, ignored = 0, errors = 0, inherited = 0
        // Restore
        var restored = 0, skipped = 0
        // Queue
        var itemsDone = 0, itemsFailed = 0
        var bytes: Int64 = 0

        /// True when nothing worth showing happened — used to hide the chip row.
        var isEmpty: Bool {
            uploaded == 0 && registered == 0 && cached == 0 && ignored == 0 && errors == 0
                && inherited == 0 && restored == 0 && skipped == 0
                && itemsDone == 0 && itemsFailed == 0
        }
    }

    /// A captured log line. Deliberately without an id — these are stored by the
    /// hundreds and a UUID per line would triple the JSON for no benefit.
    struct LogLine: Codable, Hashable {
        enum Kind: String, Codable { case info, success, warning, error }
        let text: String
        let kind: Kind
    }

    let id: UUID
    let schemaVersion: Int
    let startedAt: Date
    /// Completion time — the sort and grouping key.
    let date: Date
    let kind: Kind
    let trigger: Trigger
    /// nil for restores and for events with no owning profile.
    let profileId: UUID?
    /// Snapshot, not a lookup: profiles get renamed and deleted, history must not rot.
    let profileName: String
    let label: String
    let outcome: Outcome
    let counters: Counters
    /// versionKey for backup/restore, "3/5" for a queue run.
    let detail: String?
    let logExcerpt: [LogLine]

    static let currentSchemaVersion = 1

    var duration: TimeInterval { max(0, date.timeIntervalSince(startedAt)) }

    init(id: UUID = UUID(),
         schemaVersion: Int = ActivityEvent.currentSchemaVersion,
         startedAt: Date,
         date: Date = Date(),
         kind: Kind,
         trigger: Trigger,
         profileId: UUID?,
         profileName: String,
         label: String,
         outcome: Outcome,
         counters: Counters,
         detail: String? = nil,
         logExcerpt: [LogLine] = []) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.startedAt = startedAt
        self.date = date
        self.kind = kind
        self.trigger = trigger
        self.profileId = profileId
        self.profileName = profileName
        self.label = label
        self.outcome = outcome
        self.counters = counters
        self.detail = detail
        self.logExcerpt = logExcerpt
    }

    // Custom decoder: uses decodeIfPresent for everything except the three fields that
    // define an event's identity. Synthesized Codable throws on a missing key, which
    // would make adding one field in a future version wipe the user's whole history.
    // Same reason and same shape as BackupProfile.init(from:) in Models.swift.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decode(UUID.self, forKey: .id)
        date          = try c.decode(Date.self, forKey: .date)
        kind          = try c.decode(Kind.self, forKey: .kind)
        schemaVersion = try c.decodeIfPresent(Int.self,      forKey: .schemaVersion) ?? 1
        startedAt     = try c.decodeIfPresent(Date.self,     forKey: .startedAt) ?? date
        trigger       = try c.decodeIfPresent(Trigger.self,  forKey: .trigger) ?? .manual
        profileId     = try c.decodeIfPresent(UUID.self,     forKey: .profileId)
        profileName   = try c.decodeIfPresent(String.self,   forKey: .profileName) ?? ""
        label         = try c.decodeIfPresent(String.self,   forKey: .label) ?? ""
        outcome       = try c.decodeIfPresent(Outcome.self,  forKey: .outcome) ?? .done
        counters      = try c.decodeIfPresent(Counters.self, forKey: .counters) ?? Counters()
        detail        = try c.decodeIfPresent(String.self,   forKey: .detail)
        logExcerpt    = try c.decodeIfPresent([LogLine].self, forKey: .logExcerpt) ?? []
    }
}

// MARK: - Log Excerpt

/// Condenses a full run log down to something worth persisting: every problem line,
/// plus enough tail context to see how the run ended.
enum ActivityExcerpt {
    static let maxProblems = 30
    static let maxTail     = 10
    static let maxChars    = 500

    // Unlabelled tuple elements on purpose: Swift does not convert
    // [(String, Kind)] to [(text: String, kind: Kind)], so labels here would force
    // every caller to build the labelled form explicitly.
    static func make(_ lines: [(String, ActivityEvent.LogLine.Kind)])
        -> [ActivityEvent.LogLine] {

        guard !lines.isEmpty else { return [] }

        var keep = Set<Int>()
        var problems = 0
        for (i, line) in lines.enumerated() where line.1 == .warning || line.1 == .error {
            guard problems < maxProblems else { break }
            keep.insert(i)
            problems += 1
        }
        for i in max(0, lines.count - maxTail)..<lines.count { keep.insert(i) }

        // Original order, so the excerpt still reads like a log.
        return keep.sorted().map { i in
            let t = lines[i].0
            let clipped = t.count > maxChars ? String(t.prefix(maxChars)) + "…" : t
            return ActivityEvent.LogLine(text: clipped, kind: lines[i].1)
        }
    }
}

// MARK: - Activity Log

@MainActor
final class ActivityLog: ObservableObject {

    /// Newest first — `append` inserts at 0 and trimming drops from the tail, which
    /// keeps both operations cheap even at the cap.
    @Published private(set) var events: [ActivityEvent] = []

    /// Stored, not computed: a computed property reading UserDefaults would not
    /// republish and the sidebar badge would silently go stale.
    @Published private(set) var unreadCount: Int = 0

    /// Navigation intent, set by a notification tap or a "see all" button and consumed
    /// by ContentView. Sticky on purpose so a tap works even with the window closed.
    @Published var wantsActivityTab = false
    @Published var focusEventId: UUID?

    /// Escape hatch for AppDelegate's notification-tap handler, which has no access to
    /// the SwiftUI environment. Weak so it never keeps the log alive on its own.
    static weak var shared: ActivityLog?

    private let maxEvents = 400
    /// Trim only once we're this far over the cap, so a steady stream of events doesn't
    /// pay for an array copy on every single append.
    private let trimSlack = 50

    private let store = ActivityStore()
    private let lastSeenKey = "activity.lastSeenDate"
    private var lastSeen: Date

    init() {
        lastSeen = UserDefaults.standard.object(forKey: lastSeenKey) as? Date ?? .distantPast
        // Synchronous, like ConfigStore.load() — avoids an empty→populated flash in the
        // sidebar badge on launch.
        events = ActivityStore.loadSync()
        recomputeUnread()
        ActivityLog.shared = self
    }

    // MARK: - Mutation

    func append(_ event: ActivityEvent) {
        events.insert(event, at: 0)
        if events.count > maxEvents + trimSlack {
            events.removeLast(events.count - maxEvents)
        }
        recomputeUnread()
        persist()
    }

    func markAllSeen() {
        guard unreadCount > 0 else { return }
        lastSeen = events.first?.date ?? Date()
        UserDefaults.standard.set(lastSeen, forKey: lastSeenKey)
        unreadCount = 0
    }

    func clearAll() {
        events.removeAll()
        lastSeen = Date()
        UserDefaults.standard.set(lastSeen, forKey: lastSeenKey)
        unreadCount = 0
        persist()
    }

    // MARK: - Read

    /// The latest few, for the Dashboard strip and the menu bar.
    var recent: ArraySlice<ActivityEvent> { events.prefix(5) }

    var unreadHasFailure: Bool {
        events.prefix(unreadCount).contains { $0.outcome == .failed }
    }

    // MARK: - Helpers

    private func recomputeUnread() {
        // Events are newest-first, so this stops at the first already-seen one.
        unreadCount = events.prefix { $0.date > lastSeen }.count
    }

    private func persist() {
        let snapshot = events
        Task { await store.save(snapshot) }
    }
}

// MARK: - Persistence
//
// A JSON file in Application Support, not UserDefaults: at the cap this is hundreds of
// KB, and UserDefaults is a preferences plist rewritten whole through cfprefsd on every
// write. Mirrors LocalHashCache (BackupRunner.swift), which already owns this directory.

private actor ActivityStore {

    private static var fileURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NestVaultClient", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("activity.json")
    }

    func save(_ events: [ActivityEvent]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(events) else { return }
        try? data.write(to: ActivityStore.fileURL, options: .atomic)
    }

    nonisolated static func loadSync() -> [ActivityEvent] {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([ActivityEvent].self, from: data) else {
            // Keep the unreadable file instead of overwriting it — a corrupt history is
            // still the only copy of what happened.
            let backup = url.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return []
        }
        return decoded
    }
}
