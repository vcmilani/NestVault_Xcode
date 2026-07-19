import Foundation

// MARK: - BackupInfo  (GET /backups, GET /backups/{label})

struct BackupSummary: Codable, Identifiable, Hashable {
    let id: Int
    let label: String
    let clientName: String?
    let prefix: String?
    let status: String?
    let createdAt: String?
    let lastVersion: String?
    let versionCount: Int
    let fileCount: Int
    let totalSizeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case id, label, prefix, status
        case clientName       = "client_name"
        case createdAt        = "created_at"
        case lastVersion      = "last_version"
        case versionCount     = "version_count"
        case fileCount        = "file_count"
        case totalSizeBytes   = "total_size_bytes"
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }
    var lastVersionDate: Date? {
        guard let lv = lastVersion else { return nil }
        return parseISO(lv)
    }
    static func == (lhs: BackupSummary, rhs: BackupSummary) -> Bool { lhs.label == rhs.label }
    func hash(into hasher: inout Hasher) { hasher.combine(label) }
}

// MARK: - VersionInfo  (GET /backups/{label}/versions)

struct BackupVersion: Codable, Identifiable, Hashable {
    let id: Int
    let versionKey: String
    let backupLabel: String
    let status: String
    let createdAt: String?
    let finishedAt: String?
    let fileCount: Int
    let totalSizeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case id, status
        case versionKey     = "version_key"
        case backupLabel    = "backup_label"
        case createdAt      = "created_at"
        case finishedAt     = "finished_at"
        case fileCount      = "file_count"
        case totalSizeBytes = "total_size_bytes"
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
    }
    var date: Date?  { parseISO(versionKey) }
    var isDone: Bool { status == "done" }

    static func == (lhs: BackupVersion, rhs: BackupVersion) -> Bool { lhs.versionKey == rhs.versionKey }
    func hash(into hasher: inout Hasher) { hasher.combine(versionKey) }
}

// MARK: - FileInfo  (GET /files)

struct VersionFile: Codable, Identifiable {
    let id: Int
    let originalPath: String
    let sha256: String
    let size: Int64
    let mtime: Double?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, sha256, size, mtime
        case originalPath = "original_path"
        case createdAt    = "created_at"
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

// MARK: - CheckResponse  (POST /check)

struct CheckResponse: Codable {
    let needsUpload: Bool
    let contentExists: Bool
    let reason: String?
    let fileId: Int?

    enum CodingKeys: String, CodingKey {
        case reason
        case needsUpload   = "needs_upload"
        case contentExists = "content_exists"
        case fileId        = "file_id"
    }
}

// MARK: - Batch Check  (POST /check/batch — server v2.6+)

struct CheckBatchItem: Encodable {
    let originalPath: String
    let sha256: String
    let size: Int
    let mtime: Double

    enum CodingKeys: String, CodingKey {
        case originalPath = "original_path"
        case sha256, size, mtime
    }
}

struct CheckBatchRequest: Encodable {
    let backupLabel: String
    let versionKey: String
    let files: [CheckBatchItem]

    enum CodingKeys: String, CodingKey {
        case backupLabel = "backup_label"
        case versionKey  = "version_key"
        case files
    }
}

struct CheckBatchResultItem: Decodable {
    let needsUpload: Bool
    let contentExists: Bool
    let reason: String
    let fileId: Int?

    enum CodingKeys: String, CodingKey {
        case needsUpload   = "needs_upload"
        case contentExists = "content_exists"
        case reason
        case fileId        = "file_id"
    }
}

// MARK: - SyncResponse  (POST /sync)

struct SyncResponse: Codable {
    let synced: Bool
}

// MARK: - CleanupResponse  (POST /backups/{label}/cleanup)

struct CleanupResult: Codable {
    /// Injected after decode — the server response itself does not include the label.
    var label: String = ""
    let kept: Int
    let versionsRemoved: [String]
    let storageFilesRemoved: Int

    enum CodingKeys: String, CodingKey {
        case kept
        case versionsRemoved     = "versions_removed"
        case storageFilesRemoved = "storage_files_removed"
    }

    var removed: Int { versionsRemoved.count }
}

// MARK: - VersionCreatedResponse  (POST /backups/{label}/versions)

struct VersionCreatedResponse: Codable {
    let created: Bool
    let version: BackupVersion   // full VersionInfo from server
}

// MARK: - Global Stats (computed locally)

struct GlobalStats {
    let totalBackups: Int
    let totalVersions: Int
    let totalFiles: Int
    let totalSize: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }
}


// MARK: - Backup Schedule

struct BackupSchedule: Codable, Hashable, Equatable {
    enum Frequency: String, Codable, CaseIterable, Identifiable {
        case off, hourly, daily, weekly, custom
        var id: String { rawValue }
    }

    var frequency: Frequency = .off
    var hour: Int    = 2          // for daily/weekly (0-23)
    var minute: Int  = 0          // for daily/weekly (0-59)
    var weekday: Int = 1          // for weekly (1=Sun … 7=Sat)
    var customMinutes: Int = 60   // for custom

    var enabled: Bool { frequency != .off }

    /// Computes the next run date given a baseline (typically Date()).
    func nextRun(after baseline: Date = Date(), lastRun: Date? = nil) -> Date? {
        let cal = Calendar.current
        switch frequency {
        case .off:
            return nil
        case .hourly:
            let from = lastRun ?? baseline
            return cal.date(byAdding: .hour, value: 1, to: from) ?? baseline.addingTimeInterval(3600)
        case .custom:
            let from = lastRun ?? baseline
            return cal.date(byAdding: .minute, value: customMinutes, to: from)
                   ?? baseline.addingTimeInterval(TimeInterval(customMinutes * 60))
        case .daily:
            return nextOccurrence(hour: hour, minute: minute, weekday: nil, after: baseline)
        case .weekly:
            return nextOccurrence(hour: hour, minute: minute, weekday: weekday, after: baseline)
        }
    }

    private func nextOccurrence(hour: Int, minute: Int, weekday: Int?, after baseline: Date) -> Date? {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        if let weekday { comps.weekday = weekday }
        return cal.nextDate(after: baseline, matching: comps,
                             matchingPolicy: .nextTime, direction: .forward)
    }

    /// True if a scheduled run is currently due (and the scheduler should fire).
    func isDue(now: Date = Date(), lastRun: Date?) -> Bool {
        guard enabled else { return false }
        guard let next = nextRun(after: lastRun ?? Date.distantPast, lastRun: lastRun)
        else { return false }
        return now >= next
    }
}

// MARK: - Local Backup Profile

struct BackupProfile: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var label: String
    var sourcePath: String
    var excludes: [String]
    var workers: Int
    var prefix: String
    var serverOverride: String
    var enabled: Bool

    // Scheduling (v1.2)
    var schedule: BackupSchedule = BackupSchedule()
    var lastRun: Date?
    var lastRunStatus: String?     // "done" / "failed" / "cancelled"

    // Accumulative mode (v2.8)
    var accumulate: Bool = false

    // Smart skip mode (v3.0)
    var smartSkip: Bool = false
    var lastFullBackupDate: Date?

    init(name: String = L("profile.default_name"), label: String = "", sourcePath: String = "",
         excludes: [String] = [], workers: Int = 4, prefix: String = "",
         serverOverride: String = "", enabled: Bool = true,
         schedule: BackupSchedule = BackupSchedule(),
         lastRun: Date? = nil, lastRunStatus: String? = nil,
         accumulate: Bool = false,
         smartSkip: Bool = false, lastFullBackupDate: Date? = nil) {
        self.name = name; self.label = label; self.sourcePath = sourcePath
        self.excludes = excludes; self.workers = workers; self.prefix = prefix
        self.serverOverride = serverOverride; self.enabled = enabled
        self.schedule = schedule
        self.lastRun  = lastRun
        self.lastRunStatus = lastRunStatus
        self.accumulate = accumulate
        self.smartSkip = smartSkip
        self.lastFullBackupDate = lastFullBackupDate
    }

    // Custom decoder: uses decodeIfPresent for fields added after v1.0 so that
    // existing UserDefaults data (missing those keys) still loads correctly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                 = try c.decode(UUID.self,     forKey: .id)
        name               = try c.decode(String.self,   forKey: .name)
        label              = try c.decode(String.self,   forKey: .label)
        sourcePath         = try c.decode(String.self,   forKey: .sourcePath)
        excludes           = try c.decode([String].self, forKey: .excludes)
        workers            = try c.decode(Int.self,      forKey: .workers)
        prefix             = try c.decode(String.self,   forKey: .prefix)
        serverOverride     = try c.decode(String.self,   forKey: .serverOverride)
        enabled            = try c.decode(Bool.self,     forKey: .enabled)
        schedule           = try c.decodeIfPresent(BackupSchedule.self, forKey: .schedule) ?? BackupSchedule()
        lastRun            = try c.decodeIfPresent(Date.self,           forKey: .lastRun)
        lastRunStatus      = try c.decodeIfPresent(String.self,         forKey: .lastRunStatus)
        accumulate         = try c.decodeIfPresent(Bool.self,           forKey: .accumulate) ?? false
        smartSkip          = try c.decodeIfPresent(Bool.self,           forKey: .smartSkip) ?? false
        lastFullBackupDate = try c.decodeIfPresent(Date.self,           forKey: .lastFullBackupDate)
    }

    func cliCommand(defaultServer: String) -> String {
        let server = serverOverride.isEmpty ? defaultServer : serverOverride
        var parts = [
            "nestvault backup \(sourcePath.isEmpty ? "<pasta>" : sourcePath)",
            "  --label \"\(label.isEmpty ? "<label>" : label)\"",
            "  --server \(server)"
        ]
        if workers != 4 { parts.append("  --workers \(workers)") }
        if !prefix.isEmpty {
            let q = prefix.contains(" ") ? "\"\(prefix)\"" : prefix
            parts.append("  --prefix \(q)")
        }
        if !excludes.isEmpty {
            let exc = excludes.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
            parts.append("  --exclude \(exc)")
        }
        if accumulate { parts.append("  --absorb") }
        return parts.joined(separator: " \\\n")
    }

    init?(cliString raw: String) {
        // Join continuation lines ("foo \\n  --bar" → "foo   --bar")
        let joined = raw.components(separatedBy: "\n").map { line -> String in
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasSuffix("\\") { l = String(l.dropLast()).trimmingCharacters(in: .whitespaces) }
            return l
        }.filter { !$0.isEmpty }.joined(separator: " ")

        let tokens = BackupProfile.tokenize(joined)

        guard let backupIdx = tokens.firstIndex(of: "backup") else { return nil }
        let args = Array(tokens.dropFirst(backupIdx + 1))
        guard !args.isEmpty else { return nil }

        var path = ""
        var parsedLabel = ""
        var parsedServer = ""
        var parsedWorkers = 4
        var parsedPrefix = ""
        var parsedExcludes: [String] = []
        var parsedAccumulate = false
        var seenFlag = false

        var i = 0
        while i < args.count {
            let tok = args[i]
            if tok.hasPrefix("-") {
                seenFlag = true
                switch tok {
                case "--label", "-l":
                    i += 1; if i < args.count { parsedLabel = args[i] }
                case "--server", "-s":
                    i += 1; if i < args.count { parsedServer = args[i] }
                case "--workers", "-w":
                    i += 1; if i < args.count { parsedWorkers = Int(args[i]) ?? 4 }
                case "--prefix", "-p":
                    i += 1; if i < args.count { parsedPrefix = args[i] }
                case "--absorb":
                    parsedAccumulate = true
                case "--exclude", "-e":
                    i += 1
                    while i < args.count && !args[i].hasPrefix("-") {
                        parsedExcludes.append(args[i])
                        i += 1
                    }
                    continue
                default: break
                }
            } else if !seenFlag && path.isEmpty {
                path = tok
            }
            i += 1
        }

        guard !path.isEmpty else { return nil }

        self.init(
            name: parsedLabel.isEmpty ? path : parsedLabel,
            label: parsedLabel,
            sourcePath: path,
            excludes: parsedExcludes,
            workers: parsedWorkers,
            prefix: parsedPrefix,
            serverOverride: parsedServer,
            enabled: true,
            accumulate: parsedAccumulate
        )
    }

    private static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote: Character?
        for ch in input {
            if let q = inQuote {
                if ch == q { inQuote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
            } else if ch.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // Full equality so SwiftUI @State re-renders when any field changes (e.g. toggles).
    // List selection uses Identifiable (id), not ==, so this doesn't break selection.
    static func == (lhs: BackupProfile, rhs: BackupProfile) -> Bool {
        lhs.id             == rhs.id             &&
        lhs.name           == rhs.name           &&
        lhs.label          == rhs.label          &&
        lhs.sourcePath     == rhs.sourcePath     &&
        lhs.excludes       == rhs.excludes       &&
        lhs.workers        == rhs.workers        &&
        lhs.prefix         == rhs.prefix         &&
        lhs.serverOverride == rhs.serverOverride &&
        lhs.enabled        == rhs.enabled        &&
        lhs.accumulate     == rhs.accumulate     &&
        lhs.smartSkip      == rhs.smartSkip
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Absorb  (POST /backups/{label}/versions/{key}/absorb)

struct AbsorbRequest: Encodable {
    let sourceVersionKey: String
    enum CodingKeys: String, CodingKey {
        case sourceVersionKey = "source_version_key"
    }
}

struct AbsorbResponse: Decodable {
    let inherited: Int
    let skipped: Int
}

// MARK: - ISO 8601 parser (handles both ISO and SQLite "YYYY-MM-DD HH:MM:SS")

func parseISO(_ s: String) -> Date? {
    let iso: [ISO8601DateFormatter] = {
        let a = ISO8601DateFormatter(); a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let b = ISO8601DateFormatter(); b.formatOptions = [.withInternetDateTime]
        let c = ISO8601DateFormatter(); c.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return [a, b, c]
    }()
    for f in iso { if let d = f.date(from: s) { return d } }
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    df.locale = Locale(identifier: "en_US_POSIX")
    return df.date(from: s)
}
