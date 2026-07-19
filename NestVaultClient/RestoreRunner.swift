import Foundation

private let systemIgnoredNames: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini"]

@MainActor
final class RestoreRunner: ObservableObject {

    // MARK: - State
    @Published var status: RunStatus = .idle
    @Published var entries: [LogEntry] = []
    @Published var progress: Double = 0
    @Published var stats = Stats()
    @Published var currentFile = ""

    enum RunStatus { case idle, running, done, failed, cancelled }

    enum OverwritePolicy: String, CaseIterable, Identifiable {
        case keepExisting, overwriteChanged, overwriteAll
        var id: String { rawValue }
    }

    struct Request {
        let label: String
        let versionKey: String
        let files: [VersionFile]
        let destRoot: URL
        let stripPrefix: String        // "" = keep full original path under destRoot
        let policy: OverwritePolicy
        let workers: Int
    }

    struct Stats {
        var total = 0, restored = 0, skipped = 0, errors = 0
        var totalBytes: Int64 = 0, doneBytes: Int64 = 0
    }

    struct LogEntry: Identifiable {
        let id   = UUID()
        let text: String
        let kind: Kind
        enum Kind { case info, success, warning, error }
    }

    struct PlanItem {
        let file: VersionFile
        let destURL: URL
    }

    private let api: APIService
    private var isCancelled = false
    private var session = URLSession(configuration: .default)
    var runTask: Task<Void, Never>?

    private let maxRetries = 3
    private var lastUITick = Date.distantPast

    init(api: APIService) { self.api = api }

    func cancel() {
        guard status == .running else { return }
        isCancelled = true
        status = .cancelled
        runTask?.cancel()
        session.invalidateAndCancel()
        log(L("restore.cancel_requested"), .warning)
    }

    // MARK: - Path planning

    /// Maps a server path to a destination-relative path: strips `stripPrefix` when it
    /// matches, trims leading "/", falls back to the last component when the result
    /// would be empty. `internal static` for testability.
    nonisolated static func relativePath(for originalPath: String, stripPrefix: String) -> String {
        var rel = originalPath
        if !stripPrefix.isEmpty, originalPath.hasPrefix(stripPrefix) {
            rel = String(originalPath.dropFirst(stripPrefix.count))
        }
        while rel.hasPrefix("/") { rel.removeFirst() }
        if rel.isEmpty {
            rel = (originalPath as NSString).lastPathComponent
        }
        return rel
    }

    /// Longest common directory prefix of the files' original paths ("" when none).
    /// Used by choose-folder restores so the destination doesn't recreate /Users/… .
    nonisolated static func commonDirectoryPrefix(of paths: [String]) -> String {
        guard let first = paths.first else { return "" }
        var common = (first as NSString).deletingLastPathComponent
        for path in paths.dropFirst() {
            let dir = (path as NSString).deletingLastPathComponent
            while !common.isEmpty, common != "/",
                  !(dir == common || dir.hasPrefix(common + "/")) {
                common = (common as NSString).deletingLastPathComponent
            }
            if common.isEmpty || common == "/" { return "" }
        }
        return common == "/" ? "" : common
    }

    struct Plan {
        var items: [PlanItem] = []
        var skippedSystem = 0
        var unsafePaths: [String] = []
        var duplicates = 0
    }

    nonisolated static func buildPlan(files: [VersionFile], destRoot: URL, stripPrefix: String) -> Plan {
        var plan = Plan()
        let rootPath = destRoot.standardizedFileURL.path
        var seenDest: [String: Int] = [:]   // destPath -> index in items (last wins)
        for file in files {
            let name = (file.originalPath as NSString).lastPathComponent
            if systemIgnoredNames.contains(name) {
                plan.skippedSystem += 1
                continue
            }
            let rel  = relativePath(for: file.originalPath, stripPrefix: stripPrefix)
            let dest = destRoot.appendingPathComponent(rel).standardizedFileURL
            let destPath = dest.path
            guard destPath == rootPath || destPath.hasPrefix(rootPath + "/") else {
                plan.unsafePaths.append(file.originalPath)
                continue
            }
            let item = PlanItem(file: file, destURL: dest)
            if let idx = seenDest[destPath] {
                plan.items[idx] = item
                plan.duplicates += 1
            } else {
                seenDest[destPath] = plan.items.count
                plan.items.append(item)
            }
        }
        return plan
    }

    // MARK: - Run

    func run(_ request: Request) async {
        session     = URLSession(configuration: .default)
        status      = .running
        isCancelled = false
        entries     = []
        stats       = Stats()
        progress    = 0
        currentFile = ""
        lastUITick  = .distantPast

        log(L("restore.starting", request.label, request.versionKey), .info)
        log(L("restore.dest", request.destRoot.path), .info)

        // Plan phase — path mapping, zip-slip guard, dedupe
        let plan = Self.buildPlan(files: request.files,
                                  destRoot: request.destRoot,
                                  stripPrefix: request.stripPrefix)
        for unsafePath in plan.unsafePaths {
            log(L("restore.unsafe_path", unsafePath), .error)
        }
        if plan.skippedSystem > 0 { log(L("restore.plan_skipped_system", plan.skippedSystem), .info) }
        if plan.duplicates > 0    { log(L("restore.duplicate_paths", plan.duplicates), .warning) }

        stats.total      = plan.items.count
        stats.errors     = plan.unsafePaths.count
        stats.totalBytes = plan.items.reduce(0) { $0 + $1.file.size }
        log(L("restore.files_count", plan.items.count,
              ByteCountFormatter.string(fromByteCount: stats.totalBytes, countStyle: .file)), .info)

        let accumulator = RestoreAccumulator()

        // Execute phase — sliding-window task group, same pattern as BackupRunner
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            var index    = 0
            let limit    = max(1, request.workers)

            while index < plan.items.count || inFlight > 0 {
                while inFlight < limit && index < plan.items.count {
                    guard !isCancelled else { break }
                    let item = plan.items[index]
                    index    += 1
                    inFlight += 1
                    group.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            let outcome = try await self.restoreOne(item, policy: request.policy)
                            await accumulator.record(outcome: outcome, bytes: item.file.size)
                        } catch {
                            if !(error is CancellationError) {
                                await accumulator.record(outcome: .error, bytes: item.file.size)
                                await MainActor.run {
                                    self.log(L("restore.file_error", item.file.originalPath,
                                               error.localizedDescription), .error)
                                }
                            }
                        }
                    }
                }
                if isCancelled && inFlight == 0 { break }
                if inFlight > 0 {
                    await group.next()
                    inFlight -= 1
                    await refreshStats(from: accumulator)
                }
            }
        }

        let final = await accumulator.snapshot()
        stats.restored  = final.restored
        stats.skipped   = final.skipped
        stats.errors    += final.errors
        stats.doneBytes = final.doneBytes

        if isCancelled {
            progress = 0; currentFile = ""
            DockProgress.shared.update(progress: nil)
            log(L("restore.cancelled"), .warning)
            return
        }

        progress    = 1.0
        currentFile = ""
        DockProgress.shared.update(progress: nil)
        DockProgress.shared.bounce()
        log("─────────────────────────────────────", .info)
        if stats.errors > 0 {
            log(L("restore.partial_warning", stats.errors), .warning)
        }
        log(L("restore.summary", stats.restored, stats.skipped, stats.errors),
            stats.errors > 0 ? .warning : .success)
        status = (stats.errors > 0 && stats.restored == 0 && stats.skipped == 0) ? .failed : .done
    }

    // MARK: - Per-file restore

    fileprivate enum Outcome { case restored, skippedIdentical, keptModified, error }

    private func restoreOne(_ item: PlanItem, policy: OverwritePolicy) async throws -> Outcome {
        guard !isCancelled else { throw CancellationError() }
        let fm = FileManager.default

        // Existence check — hash local file, skip when identical
        if policy != .overwriteAll, fm.fileExists(atPath: item.destURL.path) {
            if let (localSha, _) = try? await computeSHA256Streaming(url: item.destURL),
               localSha == item.file.sha256 {
                log(L("restore.skipped_identical", item.file.originalPath), .info)
                return .skippedIdentical
            }
            if policy == .keepExisting {
                log(L("restore.kept_modified", item.file.originalPath), .warning)
                return .keptModified
            }
        }

        currentFile = (item.file.originalPath as NSString).lastPathComponent

        var lastError: Error?
        for attempt in 1...maxRetries {
            guard !isCancelled else { throw CancellationError() }
            do {
                try await downloadAndCommit(item)
                return .restored
            } catch let err as NSError where err.code == 404 || err.code == 410 {
                throw err   // permanent — content unknown/gone server-side
            } catch {
                lastError = error
                guard !isCancelled, attempt < maxRetries else { break }
                try? await Task.sleep(nanoseconds: UInt64(500_000_000) * UInt64(attempt))
            }
        }
        throw lastError ?? CancellationError()
    }

    private func downloadAndCommit(_ item: PlanItem) async throws {
        let req = try api.downloadRequest(fileId: item.file.id)
        let (tmpURL, response) = try await session.download(for: req)

        // Claim the URLSession temp file immediately (rename within the temp dir).
        let staging = tmpURL.deletingLastPathComponent()
            .appendingPathComponent("nestvault-restore-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: tmpURL, to: staging)

        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: staging) } }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = (try? FileHandle(forReadingFrom: staging).read(upToCount: 300))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "(sem mensagem)"
            throw NSError(domain: "NestVault", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) — \(body)"])
        }

        // Integrity — restored bytes must hash to what the server catalogued
        let (sha256, _) = try await computeSHA256Streaming(url: staging)
        guard sha256 == item.file.sha256 else {
            throw NSError(domain: "NestVault", code: -2,
                          userInfo: [NSLocalizedDescriptionKey:
                            L("restore.integrity_failed", item.file.originalPath)])
        }

        // Commit off the main actor — staging may live on another volume (move = copy)
        let dest  = item.destURL
        let mtime = item.file.mtime
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: dest)
            }
            if let mtime {
                try? fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)],
                                      ofItemAtPath: dest.path)
            }
        }.value
        committed = true
    }

    // MARK: - Progress

    private func refreshStats(from accumulator: RestoreAccumulator) async {
        let now = Date()
        guard now.timeIntervalSince(lastUITick) >= 0.1 else { return }
        lastUITick = now
        let s = await accumulator.snapshot()
        stats.restored  = s.restored
        stats.skipped   = s.skipped
        stats.doneBytes = s.doneBytes
        // plan-phase errors (unsafe paths) stay counted on top of execution errors
        let value = Double(s.doneBytes) / Double(max(stats.totalBytes, 1))
        progress = min(1, max(value, progress))
        DockProgress.shared.update(progress: progress)
    }

    // MARK: - Log

    private let maxLogEntries = 2000

    private func log(_ text: String, _ kind: LogEntry.Kind) {
        entries.append(LogEntry(text: text, kind: kind))
        if entries.count > maxLogEntries + 500 {
            entries.removeFirst(entries.count - maxLogEntries)
        }
    }
}

// MARK: - Restore Accumulator (actor — thread-safe parallel counting)

private actor RestoreAccumulator {
    private var restored  = 0
    private var skipped   = 0
    private var errors    = 0
    private var doneBytes: Int64 = 0

    func record(outcome: RestoreRunner.Outcome, bytes: Int64) {
        switch outcome {
        case .restored:                        restored += 1
        case .skippedIdentical, .keptModified: skipped  += 1
        case .error:                           errors   += 1
        }
        doneBytes += bytes
    }

    struct Snapshot { var restored, skipped, errors: Int; var doneBytes: Int64 }
    func snapshot() -> Snapshot {
        Snapshot(restored: restored, skipped: skipped, errors: errors, doneBytes: doneBytes)
    }
}
