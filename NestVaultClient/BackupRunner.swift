import Foundation
import CryptoKit

private let systemIgnoredNames: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini"]

@MainActor
final class BackupRunner: ObservableObject {

    // MARK: - State
    @Published var status: RunStatus = .idle
    @Published var entries: [LogEntry] = []
    @Published var progress: Double = 0
    @Published var stats = Stats()
    @Published var currentFile = ""
    @Published var runPhase: RunPhase = .idle
    @Published var phaseProcessed = 0
    @Published var phaseTotal = 0

    enum RunStatus { case idle, running, done, failed, cancelled }
    enum RunPhase  { case idle, preparing, scanning, checking, processing, finalizing }

    /// Human-readable label for the current phase, used by the runner sheet, menu bar and queue.
    var phaseDescription: String {
        switch runPhase {
        case .idle:       return ""
        case .preparing:  return L("runner.phase.preparing")
        case .scanning:   return L("runner.phase.scanning", phaseProcessed)
        case .checking:   return L("runner.phase.checking_simple")
        case .processing: return L("runner.phase.processing", phaseProcessed, phaseTotal)
        case .finalizing: return L("runner.phase.finalizing")
        }
    }

    /// Phases without a meaningful fraction — views should show an indeterminate bar.
    var isIndeterminatePhase: Bool {
        switch runPhase {
        case .preparing, .scanning, .checking, .finalizing: return true
        default: return false
        }
    }

    /// True after a full backup completes; false when smart skip was used (absorb-only).
    /// Used by ScheduleManager to decide whether to update lastFullBackupDate.
    @Published var wasFullBackup: Bool = true

    struct LogEntry: Identifiable {
        let id   = UUID()
        let text: String
        let kind: Kind
        enum Kind { case info, success, warning, error }
    }

    struct Stats {
        var uploaded = 0, registered = 0, cached = 0, ignored = 0, errors = 0
        var inherited = 0
    }

    private enum FileAction {
        case skip
        case cachedRegister(sha256: String)   // mtime+size cache hit — counted as "cached"
        case register(sha256: String)          // contentExists = true
        case upload                            // contentExists = false
    }

    fileprivate struct ScannedFile {
        let url: URL
        let mtime: Double
        let size: Int64
    }

    private struct HashedFile {
        let url: URL
        let serverPath: String
        let sha256: String
        let size: Int64
        let mtime: Double
    }

    private struct WorkItem {
        let action: FileAction
        let url: URL
        let serverPath: String
        let mtime: Double
        let units: Double
    }

    private let api: APIService
    private var isCancelled = false
    private var session = URLSession(configuration: .default)
    private var scanTask: Task<([ScannedFile], Int, Int), Error>?
    var runTask: Task<Void, Never>?

    private let maxRetries = 3
    private let batchSize  = 100

    // Work-unit model: progress is weighted by estimated cost in "byte-equivalents".
    // A server round-trip (register/check) costs rtUnit bytes; hashing a byte costs
    // hashCostFactor of uploading it. Zero-byte files get a floor so they still move the bar.
    private let rtUnit: Double         = 200_000
    private let hashCostFactor: Double = 0.25
    private let minFileWork: Double    = 32_768

    // Execution-segment bookkeeping (set up before phase 2 runs)
    private var execStart: Double      = 0   // progress value where the transfer segment begins
    private var execUnitsTotal: Double = 1
    private var execUnitsDone: Double  = 0

    // UI throttles: published progress/stats update at most ~10×/s. Two independent
    // gates — addExecUnits (progress bar) fires on every item completion and would
    // otherwise always leave the shared gate "just consumed", starving the counter
    // updates in the transfer loop (x of y stuck at 0).
    private var lastUITick    = Date.distantPast
    private var lastStatsTick = Date.distantPast

    init(api: APIService) { self.api = api }

    // MARK: - Progress helpers

    /// Consumes the progress-bar tick. Returns true at most every `interval` seconds.
    private func uiTickDue(_ interval: TimeInterval = 0.1) -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastUITick) >= interval else { return false }
        lastUITick = now
        return true
    }

    /// Consumes the counters/stats tick — independent of the progress-bar tick.
    private func statsTickDue(_ interval: TimeInterval = 0.1) -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastStatsTick) >= interval else { return false }
        lastStatsTick = now
        return true
    }

    /// Publishes progress (monotonic within a run) and mirrors it to the Dock.
    private func publishProgress(_ value: Double) {
        let v = min(1, max(value, progress))
        progress = v
        DockProgress.shared.update(progress: v)
    }

    /// Adds byte-equivalent units completed in the transfer segment (may be negative
    /// when a failed upload's partial bytes are rolled back) and updates the bar.
    /// No-ops once the run is no longer active so late delegate callbacks can't
    /// resurrect the Dock progress after done/cancel.
    func addExecUnits(_ units: Double) {
        guard status == .running else { return }
        execUnitsDone += units
        let frac = min(1, max(0, execUnitsDone) / execUnitsTotal)
        if uiTickDue() {
            publishProgress(execStart + (1 - execStart) * frac)
        }
    }

    func cancel() {
        guard status == .running else { return }
        isCancelled = true
        status = .cancelled
        scanTask?.cancel()
        runTask?.cancel()   // makes URLSession.shared + Task.sleep in finalizeVersion exit instantly
        session.invalidateAndCancel()
        log(L("runner.cancel_requested"), .warning)
    }

    // MARK: - Run

    func run(profile: BackupProfile) async {
        session        = URLSession(configuration: .default)
        status         = .running
        isCancelled    = false
        scanTask       = nil
        entries        = []
        stats          = Stats()
        progress       = 0
        runPhase       = .preparing
        phaseProcessed = 0
        phaseTotal     = 0
        execUnitsDone  = 0
        execUnitsTotal = 1
        lastUITick     = .distantPast
        lastStatsTick  = .distantPast
        wasFullBackup  = true
        var serverError = false

        let label  = profile.label
        let source = profile.sourcePath

        log(L("runner.starting", label), .info)
        log(L("runner.source", source), .info)

        // 1. Create / open backup
        do {
            try await createBackup(label: label)
            log(L("runner.backup_registered"), .success)
        } catch {
            log(L("runner.backup_register_error", error.localizedDescription), .error)
            DockProgress.shared.update(progress: nil)
            status = .failed; return
        }

        // 2. Create version
        let versionKey: String
        do {
            versionKey = try await createVersion(label: label)
            log(L("runner.version_created", versionKey), .success)
        } catch {
            log(L("runner.version_create_error", error.localizedDescription), .error)
            status = .failed; return
        }

        // 3. Previous version cache (mtime+size fast path — avoids SHA-256 for unchanged files)
        let (cache, prevDoneKey) = await fetchPreviousVersionCache(label: label)
        if !cache.isEmpty { log(L("runner.cache_loaded", cache.count), .info) }

        // Local hash cache — persists sha256 across runs; eliminates re-hashing for unchanged files
        let hashCache = LocalHashCache(label: label)
        await hashCache.load()
        let hashCacheCount = await hashCache.count
        if hashCacheCount > 0 { log(L("runner.hashcache_loaded", hashCacheCount), .info) }

        // 4. Walk filesystem (off main actor — avoids blocking UI for large directories)
        //    Also captures mtime+size via URL resource values in one kernel pass,
        //    so the classification step below needs no extra attributesOfItem calls.
        let excludes = profile.excludes
        let scannedFiles: [ScannedFile]
        var scanSkippedByExclude = 0
        var scanSkippedByType    = 0
        runPhase = .scanning
        do {
            scanTask = Task.detached(priority: .userInitiated) { [weak self] in
                let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
                var files: [ScannedFile] = []
                var byExclude = 0
                var byType    = 0
                var lastReported = 0
                // BFS with contentsOfDirectory — avoids FileManager.enumerator stopping
                // silently mid-tree on certain macOS app contexts (enumerator was yielding
                // only ~1915 of 5136 items despite errorHandler returning true).
                var queue: [URL] = [URL(fileURLWithPath: source, isDirectory: true)]
                while !queue.isEmpty {
                    if Task.isCancelled { break }
                    let dir = queue.removeLast()
                    let items = (try? FileManager.default.contentsOfDirectory(
                        at: dir,
                        includingPropertiesForKeys: Array(resourceKeys),
                        options: []
                    )) ?? []
                    for url in items {
                        let name = url.lastPathComponent
                        if excludes.contains(name) || systemIgnoredNames.contains(name) {
                            byExclude += 1; continue
                        }
                        let rv = try? url.resourceValues(forKeys: resourceKeys)
                        if rv?.isDirectory == true {
                            if rv?.isSymbolicLink != true { queue.append(url) }
                            continue
                        }
                        if rv?.isRegularFile != true {
                            byType += 1; continue
                        }
                        let mtime = rv?.contentModificationDate?.timeIntervalSince1970 ?? 0
                        let size  = Int64(rv?.fileSize ?? 0)
                        files.append(ScannedFile(url: url, mtime: mtime, size: size))
                        if files.count - lastReported >= 250 {
                            lastReported = files.count
                            let n = files.count
                            Task { @MainActor [weak self] in
                                if self?.runPhase == .scanning { self?.phaseProcessed = n }
                            }
                        }
                    }
                }
                return (files, byExclude, byType)
            }
            (scannedFiles, scanSkippedByExclude, scanSkippedByType) = try await scanTask!.value
            scanTask = nil
        } catch {
            scanTask = nil
            log(L("runner.source_unreadable", source), .error)
            await finalizeVersion(label: label, versionKey: versionKey, ok: false)
            DockProgress.shared.update(progress: nil)
            status = .failed; return
        }

        phaseProcessed = scannedFiles.count
        log(L("runner.files_found", scannedFiles.count), .info)
        if scanSkippedByExclude > 0 || scanSkippedByType > 0 {
            log(L("runner.scan_skipped", scanSkippedByExclude, scanSkippedByType), .info)
        }

        if isCancelled {
            await finalizeVersion(label: label, versionKey: versionKey, ok: false)
            progress = 0; currentFile = ""; status = .cancelled
            DockProgress.shared.update(progress: nil)
            log(L("runner.cancelled"), .warning); return
        }

        // Smart skip: if enabled, 0 local changes detected, and last full backup is within 7 days,
        // skip classify/execute/sync and absorb directly from the previous version.
        if profile.smartSkip, let prevDoneKey {
            runPhase   = .checking
            phaseTotal = 0
            let noChanges = await hashCache.allUnchanged(scanned: scannedFiles)
            let overdue   = profile.lastFullBackupDate.map {
                Date().timeIntervalSince($0) > 7 * 86_400
            } ?? true   // nil = never ran a full backup → must run full
            // Guard: prevDoneKey's file count must match the current scan. Without this check, a
            // failed backup can leave hashCache with more entries than prevDoneKey's version has,
            // causing smart skip to absorb a stale (smaller) version and silently drop new files.
            let prevCountMatches = cache.count == scannedFiles.count

            if noChanges && !overdue && prevCountMatches {
                log(L("runner.smart_skip_detected", scannedFiles.count), .info)
                wasFullBackup = false
                runPhase = .finalizing
                do {
                    let result = try await api.absorb(
                        session: session, label: label,
                        versionKey: versionKey, sourceVersionKey: prevDoneKey)
                    stats.inherited = result.inherited
                    log(L("runner.absorb_done", result.inherited, result.skipped), .success)
                } catch let err as NSError where (500..<600).contains(err.code) {
                    log(L("runner.absorb_server_error", err.localizedDescription), .error)
                    serverError = true
                } catch {
                    log(L("runner.absorb_error", error.localizedDescription), .warning)
                }
                await finalizeVersion(label: label, versionKey: versionKey, ok: !serverError)
                let walkedPaths = Set(scannedFiles.map { $0.url.path })
                await hashCache.prune(keepingPaths: walkedPaths)
                await hashCache.save()
                progress = 1.0; currentFile = ""; status = .done
                DockProgress.shared.update(progress: nil)
                DockProgress.shared.bounce()
                log("─────────────────────────────────────", .info)
                log(L("runner.summary", 0, 0, stats.inherited, 0, 0), .success)
                return
            }

            if overdue && noChanges {
                log(L("runner.smart_skip_forced_full"), .info)
            }
        }

        // 5. Build server path list (needed for sync later)
        let serverPaths: [String] = scannedFiles.map { file in
            let url = file.url
            guard !profile.prefix.isEmpty else { return url.path }
            let rel = url.path.hasPrefix(source)
                ? String(url.path.dropFirst(source.count))
                : "/" + url.lastPathComponent
            return profile.prefix.hasSuffix("/")
                ? profile.prefix + rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                : profile.prefix + rel
        }

        let accumulator = StatsAccumulator()

        // ── PHASE 1: Classify ────────────────────────────────────────────────

        let useBatch = api.supportsBatch()
        if useBatch { log(L("runner.batch_mode"), .info) }

        // Split into cache hits and files that need hashing — one actor hop for the
        // whole file list (a per-file await here costs 2 MainActor↔actor hops per file).
        let (fastEntries, slowEntries) = await hashCache.classify(
            scanned: scannedFiles, serverPaths: serverPaths, serverCache: cache)

        if isCancelled {
            await finalizeVersion(label: label, versionKey: versionKey, ok: false)
            progress = 0; currentFile = ""; status = .cancelled
            DockProgress.shared.update(progress: nil)
            log(L("runner.cancelled"), .warning); return
        }

        log(L("runner.classifying", fastEntries.count, slowEntries.count), .info)

        // ── Pipelined processing: hash → check → transfer ────────────────────
        // A producer hashes slow files and classifies them against the server in
        // batches while the executor registers/uploads concurrently — CPU (hash)
        // and network (check/upload) overlap instead of running as strict phases.
        //
        // Progress is a single pool of byte-equivalent units covering all three
        // stages. Slow files are assumed to be uploads until the server says
        // otherwise; the avoided cost is credited at classification time, so the
        // bar never moves backward.
        let slowExecEst = slowEntries.reduce(0.0) { $0 + max(Double($1.size), rtUnit) }
        let hashWork    = slowEntries.reduce(0.0) { $0 + max(Double($1.size), minFileWork) } * hashCostFactor
        let checkOps    = useBatch
            ? Double((slowEntries.count + batchSize - 1) / batchSize)
            : Double(slowEntries.count)

        execStart      = 0
        execUnitsTotal = max(hashWork + checkOps * rtUnit + slowExecEst
                             + Double(fastEntries.count) * rtUnit, 1)
        execUnitsDone  = 0
        runPhase       = .processing
        phaseTotal     = slowEntries.count + fastEntries.count
        phaseProcessed = 0
        currentFile    = ""

        let (workStream, workCont) = AsyncStream.makeStream(of: WorkItem.self)
        let producer = Task { [weak self] in
            await self?.produceWork(slowEntries: slowEntries, fastEntries: fastEntries,
                                    label: label, versionKey: versionKey,
                                    useBatch: useBatch, hashCache: hashCache,
                                    accumulator: accumulator, continuation: workCont)
        }
        await executeWork(stream: workStream,
                          concurrencyLimit: max(1, profile.workers),
                          label: label, versionKey: versionKey,
                          accumulator: accumulator)
        await producer.value

        let finalStats = await accumulator.snapshot()
        stats.uploaded   = finalStats.uploaded
        stats.registered = finalStats.registered
        stats.cached     = finalStats.cached
        stats.ignored    = finalStats.ignored
        stats.errors     = finalStats.errors

        if isCancelled {
            await finalizeVersion(label: label, versionKey: versionKey, ok: false)
            progress = 0; currentFile = ""; status = .cancelled
            DockProgress.shared.update(progress: nil)
            log(L("runner.cancelled"), .warning); return
        }

        // 6. Sync
        runPhase = .finalizing
        publishProgress(1.0)
        do {
            let synced = try await syncVersion(label: label,
                                               versionKey: versionKey,
                                               paths: serverPaths)
            if synced { log(L("runner.sync_done"), .success) }
        } catch let err as NSError where (500..<600).contains(err.code) {
            log(L("runner.sync_server_error", err.localizedDescription), .error)
            serverError = true
        } catch {
            log(L("runner.sync_skipped", error.localizedDescription), .warning)
        }

        // 7. Absorb (accumulative mode — must run before finalize, while version is still "running")
        if profile.accumulate {
            if prevDoneKey == nil {
                log(L("runner.accumulate_no_prev"), .info)
            } else if stats.errors > 0 {
                log(L("runner.accumulate_skipped_errors"), .warning)
            } else if let prevDoneKey {
                do {
                    let result = try await api.absorb(
                        session: session, label: label,
                        versionKey: versionKey, sourceVersionKey: prevDoneKey)
                    stats.inherited = result.inherited
                    log(L("runner.absorb_done", result.inherited, result.skipped), .success)
                } catch let err as NSError where (500..<600).contains(err.code) {
                    log(L("runner.absorb_server_error", err.localizedDescription), .error)
                    serverError = true
                } catch {
                    log(L("runner.absorb_error", error.localizedDescription), .warning)
                }
            }
        }

        // 8. Finalize
        await finalizeVersion(label: label, versionKey: versionKey, ok: stats.errors == 0 && !serverError)

        // Persist hash cache pruned to the current file set
        let walkedPaths = Set(scannedFiles.map { $0.url.path })
        await hashCache.prune(keepingPaths: walkedPaths)
        await hashCache.save()

        progress    = 1.0
        currentFile = ""
        status      = .done
        DockProgress.shared.update(progress: nil)
        DockProgress.shared.bounce()
        log("─────────────────────────────────────", .info)
        log(L("runner.summary",
              stats.uploaded, stats.registered, stats.cached, stats.ignored, stats.errors), .success)
    }

    // MARK: - Pipeline

    /// Producer: yields cache hits immediately, then hashes slow files in parallel,
    /// classifying them against the server in batches as hashes complete. Everything
    /// it emits is consumed concurrently by `executeWork`.
    private func produceWork(
        slowEntries: [(url: URL, serverPath: String, size: Int64, mtime: Double)],
        fastEntries: [(url: URL, serverPath: String, sha256: String, mtime: Double)],
        label: String, versionKey: String,
        useBatch: Bool, hashCache: LocalHashCache,
        accumulator: StatsAccumulator,
        continuation: AsyncStream<WorkItem>.Continuation
    ) async {
        defer { continuation.finish() }

        // Cache hits need no hashing/checking — the executor starts registering
        // them while hashing is still running.
        for f in fastEntries {
            continuation.yield(WorkItem(action: .cachedRegister(sha256: f.sha256),
                                        url: f.url, serverPath: f.serverPath,
                                        mtime: f.mtime, units: rtUnit))
        }

        guard !slowEntries.isEmpty else { return }

        func yieldClassified(_ h: HashedFile, needsUpload: Bool, contentExists: Bool) {
            let action: FileAction
            let units:  Double
            if !needsUpload {
                action = .skip;                       units = rtUnit
            } else if contentExists {
                action = .register(sha256: h.sha256); units = rtUnit
            } else {
                action = .upload;                     units = max(Double(h.size), rtUnit)
            }
            if case .upload = action {} else {
                // The progress pool assumed an upload for this file — credit the avoided cost.
                addExecUnits(max(Double(h.size), rtUnit) - rtUnit)
            }
            continuation.yield(WorkItem(action: action, url: h.url,
                                        serverPath: h.serverPath, mtime: h.mtime,
                                        units: units))
        }

        func classifyIndividually(_ h: HashedFile) async {
            let checkBody = try? JSONSerialization.data(withJSONObject: [
                "backup_label": label,
                "version_key":  versionKey,
                "original_path": h.serverPath,
                "sha256": h.sha256,
                "size":   Int(h.size),
                "mtime":  h.mtime
            ] as [String: Any])
            guard let body = checkBody,
                  let req  = try? api.buildRequest("/check", method: "POST", body: body),
                  let (data, _) = try? await session.data(for: req),
                  let resp = try? JSONDecoder().decode(CheckResponse.self, from: data)
            else {
                yieldClassified(h, needsUpload: true, contentExists: false); return
            }
            yieldClassified(h, needsUpload: resp.needsUpload, contentExists: resp.contentExists)
        }

        func classify(_ batch: [HashedFile]) async {
            guard !batch.isEmpty else { return }
            if useBatch {
                let items = batch.map {
                    CheckBatchItem(originalPath: $0.serverPath, sha256: $0.sha256,
                                   size: Int($0.size), mtime: $0.mtime)
                }
                do {
                    let results = try await api.checkBatch(
                        session: session, label: label,
                        versionKey: versionKey, items: items)
                    for (idx, result) in results.enumerated() {
                        yieldClassified(batch[idx],
                                        needsUpload: result.needsUpload,
                                        contentExists: result.contentExists)
                    }
                } catch {
                    log(L("runner.batch_check_error", error.localizedDescription), .warning)
                    for h in batch {
                        yieldClassified(h, needsUpload: true, contentExists: false)
                    }
                }
                addExecUnits(rtUnit)   // one check round-trip completed
            } else {
                for h in batch {
                    guard !isCancelled else { return }
                    await classifyIndividually(h)
                    addExecUnits(rtUnit)
                }
            }
        }

        // Hash in parallel; classify in batches as results arrive.
        var pendingBatch: [HashedFile] = []
        let hashConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount)
        await withTaskGroup(of: HashedFile?.self) { group in
            var inFlight = 0
            var index    = 0

            while index < slowEntries.count || inFlight > 0 {
                while inFlight < hashConcurrency && index < slowEntries.count {
                    guard !isCancelled else { break }
                    let entry = slowEntries[index]
                    index   += 1
                    inFlight += 1
                    group.addTask { [weak self] in
                        guard let self else { return nil }
                        do {
                            let (sha256, _) = try await self.computeSHA256Streaming(url: entry.url)
                            return HashedFile(url: entry.url, serverPath: entry.serverPath,
                                             sha256: sha256, size: entry.size, mtime: entry.mtime)
                        } catch {
                            if !(error is CancellationError) {
                                await accumulator.recordError()
                                await MainActor.run {
                                    self.log(L("runner.file_error", entry.url.path,
                                               error.localizedDescription), .error)
                                }
                            }
                            return nil
                        }
                    }
                }
                if isCancelled && inFlight == 0 { break }
                if inFlight > 0, let result = await group.next() {
                    inFlight -= 1
                    if let hf = result {
                        await hashCache.set(path: hf.url.path, mtime: hf.mtime,
                                            size: hf.size, sha256: hf.sha256)
                        addExecUnits(max(Double(hf.size), minFileWork) * hashCostFactor)
                        pendingBatch.append(hf)
                        if pendingBatch.count >= batchSize {
                            let batch = pendingBatch
                            pendingBatch = []
                            await classify(batch)
                        }
                    }
                }
            }
        }
        if !isCancelled {
            await classify(pendingBatch)
        }
    }

    /// Executor: consumes work items as the producer emits them, keeping at most
    /// `concurrencyLimit` transfers in flight.
    private func executeWork(
        stream: AsyncStream<WorkItem>,
        concurrencyLimit: Int,
        label: String, versionKey: String,
        accumulator: StatsAccumulator
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var inFlight  = 0
            var completed = 0

            for await item in stream {
                guard !isCancelled else { break }
                if inFlight >= concurrencyLimit {
                    await group.next()
                    inFlight  -= 1
                    completed += 1
                    await refreshExecCounters(completed: completed, accumulator: accumulator)
                }
                group.addTask { [weak self] in
                    guard let self else { return }
                    do {
                        let actionStr = try await self.executeActionWithRetry(
                            item.action, url: item.url,
                            label: label, versionKey: versionKey,
                            serverPath: item.serverPath, mtime: item.mtime,
                            units: item.units)
                        await accumulator.record(action: actionStr)
                    } catch {
                        if !(error is CancellationError) {
                            await accumulator.recordError()
                            await MainActor.run {
                                self.log(L("runner.file_error", item.url.path,
                                           error.localizedDescription), .error)
                            }
                        }
                    }
                }
                inFlight += 1
            }
            while inFlight > 0 {
                await group.next()
                inFlight  -= 1
                completed += 1
                await refreshExecCounters(completed: completed, accumulator: accumulator)
            }
            phaseProcessed = completed
        }
    }

    /// Throttled refresh of the "x of y" counter and the stats row during execution.
    /// Progress units themselves are credited inside executeAction.
    private func refreshExecCounters(completed: Int, accumulator: StatsAccumulator) async {
        guard statsTickDue() else { return }
        phaseProcessed = completed
        let s = await accumulator.snapshot()
        stats.uploaded   = s.uploaded
        stats.registered = s.registered
        stats.cached     = s.cached
        stats.ignored    = s.ignored
        stats.errors     = s.errors
    }

    // MARK: - Action Execution

    private func executeActionWithRetry(
        _ action: FileAction,
        url: URL, label: String, versionKey: String,
        serverPath: String, mtime: Double, units: Double
    ) async throws -> String {
        var currentAction = action
        var lastError: Error?
        for attempt in 1...maxRetries {
            guard !isCancelled else { throw CancellationError() }
            do {
                return try await executeAction(currentAction, url: url, label: label,
                                               versionKey: versionKey,
                                               serverPath: serverPath, mtime: mtime,
                                               units: units)
            } catch {
                lastError = error
                guard !isCancelled, attempt < maxRetries else { break }
                // Register-only returned 400 "content not found in storage" — server lost the
                // cached file. Escalate to a full upload instead of retrying the same action.
                if (error as NSError).code == 400 {
                    switch currentAction {
                    case .cachedRegister, .register:
                        currentAction = .upload
                    default: break
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(500_000_000) * UInt64(attempt))
            }
        }
        throw lastError ?? CancellationError()
    }

    private func executeAction(
        _ action: FileAction,
        url: URL, label: String, versionKey: String,
        serverPath: String, mtime: Double, units: Double
    ) async throws -> String {
        guard !isCancelled else { throw CancellationError() }
        let pathB64 = Data(serverPath.utf8).base64EncodedString()

        switch action {
        case .skip:
            addExecUnits(units)
            return "ignore"

        case .cachedRegister(let sha256), .register(let sha256):
            var req = try api.buildRequest("/upload", method: "POST", body: nil)
            req.timeoutInterval = 300
            req.setValue(label,         forHTTPHeaderField: "X-Backup-Label")
            req.setValue(versionKey,    forHTTPHeaderField: "X-Version-Key")
            req.setValue(pathB64,       forHTTPHeaderField: "X-Original-Path")
            req.setValue(String(mtime), forHTTPHeaderField: "X-Mtime")
            req.setValue(sha256,        forHTTPHeaderField: "X-Content-Sha256")
            let (respData, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let msg = String(data: respData, encoding: .utf8) ?? "(sem mensagem)"
                throw NSError(domain: "NestVault", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) — \(msg.prefix(300))"])
            }
            addExecUnits(units)
            if case .cachedRegister = action { return "cached" }
            return "register"

        case .upload:
            currentFile = url.lastPathComponent
            var req = try api.buildRequest("/upload", method: "POST", body: nil)
            // Large files can take a long time to encrypt/store server-side after the body is
            // fully received — use a generous idle timeout so the server has room to process.
            req.timeoutInterval = 3600
            req.setValue(label,                      forHTTPHeaderField: "X-Backup-Label")
            req.setValue(versionKey,                 forHTTPHeaderField: "X-Version-Key")
            req.setValue(pathB64,                    forHTTPHeaderField: "X-Original-Path")
            req.setValue(String(mtime),              forHTTPHeaderField: "X-Mtime")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            // Streams sent-byte deltas into the progress bar while the body uploads;
            // on failure the partial credit is rolled back so retries don't double-count.
            let progressDelegate = UploadProgressDelegate { [weak self] delta in
                Task { @MainActor [weak self] in self?.addExecUnits(Double(delta)) }
            }
            var succeeded = false
            defer {
                if !succeeded {
                    let reported = progressDelegate.totalReported
                    if reported > 0 { addExecUnits(-Double(reported)) }
                }
            }
            let (respData, response) = try await session.upload(for: req, fromFile: url,
                                                                delegate: progressDelegate)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let msg = String(data: respData, encoding: .utf8) ?? "(sem mensagem)"
                throw NSError(domain: "NestVault", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) — \(msg.prefix(300))"])
            }
            succeeded = true
            addExecUnits(units - Double(progressDelegate.totalReported))
            return "upload"
        }
    }

    // MARK: - API Helpers

    private func createBackup(label: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "label": label,
            "client_name": ProcessInfo.processInfo.hostName
        ])
        var req = try api.buildRequest("/backups", method: "POST", body: body)
        req.timeoutInterval = 20
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return }
        if http.statusCode == 409 { return }
        if !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "(sem mensagem)"
            throw NSError(domain: "NestVault", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                            "HTTP \(http.statusCode) — \(msg.prefix(200))"])
        }
    }

    private func createVersion(label: String) async throws -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let versionKey = formatter.string(from: Date())
        let body = try JSONSerialization.data(withJSONObject: ["version_key": versionKey])
        var req  = try api.buildRequest("/backups/\(label.urlSafe)/versions", method: "POST", body: body)
        req.timeoutInterval = 20
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "(sem mensagem)"
            throw NSError(domain: "NestVault", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                            "HTTP \(http.statusCode) — \(msg.prefix(200))"])
        }
        if let r = try? JSONDecoder().decode(VersionCreatedResponse.self, from: data) {
            return r.version.versionKey
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ver  = json["version"] as? [String: Any],
           let key  = ver["version_key"] as? String { return key }
        return versionKey
    }

    private func fetchPreviousVersionCache(label: String) async -> (cache: [String: FileCache], prevDoneKey: String?) {
        guard let versions = try? await api.fetchVersions(label: label),
              let doneVersion = versions.first(where: { $0.isDone })
        else { return ([:], nil) }
        guard let files = try? await api.fetchFiles(label: label, versionKey: doneVersion.versionKey) else {
            log(L("runner.cache_load_failed"), .warning)
            return ([:], doneVersion.versionKey)
        }
        var cache: [String: FileCache] = [:]
        cache.reserveCapacity(files.count)
        for file in files {
            cache[file.originalPath] = FileCache(
                sha256: file.sha256,
                mtime:  file.mtime ?? 0,
                size:   file.size
            )
        }
        return (cache, doneVersion.versionKey)
    }

    private func syncVersion(label: String, versionKey: String, paths: [String]) async throws -> Bool {
        let body = try JSONSerialization.data(withJSONObject: [
            "backup_label": label,
            "version_key":  versionKey,
            "existing_paths": paths
        ] as [String: Any])
        var req = try api.buildRequest("/sync", method: "POST", body: body)
        req.timeoutInterval = 120
        let (data, _) = try await session.data(for: req)
        let resp = try? JSONDecoder().decode(SyncResponse.self, from: data)
        return resp?.synced ?? false
    }

    private func finalizeVersion(label: String, versionKey: String, ok: Bool) async {
        guard let body = try? JSONSerialization.data(withJSONObject: ["status": ok ? "done" : "failed"]),
              var req  = try? api.buildRequest(
                  "/backups/\(label.urlSafe)/versions/\(versionKey.urlSafe)",
                  method: "PATCH", body: body)
        else { return }
        req.timeoutInterval = 30

        for attempt in 1...3 {
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return
                }
            } catch { }
            if attempt < 3 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        log(L("runner.finalize_failed"), .warning)
    }

    // MARK: - SHA-256

    private func computeSHA256Streaming(url: URL) async throws -> (sha256: String, size: Int) {
        return try await Task.detached(priority: .userInitiated) {
            let bufferSize = 4_194_304  // 4 MB — fewer syscalls, better throughput than 1 MB
            guard let stream = InputStream(url: url) else {
                throw NSError(domain: "NestVault", code: -1,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Não foi possível abrir: \(url.path)"])
            }
            stream.open()
            defer { stream.close() }

            var hasher    = SHA256()
            var totalSize = 0
            let buffer    = UnsafeMutableRawBufferPointer.allocate(byteCount: bufferSize, alignment: 1)
            defer { buffer.deallocate() }

            while stream.hasBytesAvailable {
                let read = stream.read(
                    buffer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    maxLength: bufferSize)
                if read < 0 {
                    throw stream.streamError ?? NSError(domain: "NestVault", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Erro de leitura: \(url.path)"])
                }
                if read == 0 { break }
                // Update directly from raw buffer — avoids allocating a Data per chunk
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer.baseAddress, count: read))
                totalSize += read
            }

            let sha256 = hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
            return (sha256, totalSize)
        }.value
    }

    // MARK: - Log

    private let maxLogEntries = 2000

    private func log(_ text: String, _ kind: LogEntry.Kind) {
        entries.append(LogEntry(text: text, kind: kind))
        // Cap with hysteresis so trimming is amortized (removeFirst is O(n)) —
        // an error storm on a huge tree would otherwise grow the list unbounded
        // and degrade the whole UI.
        if entries.count > maxLogEntries + 500 {
            entries.removeFirst(entries.count - maxLogEntries)
        }
    }
}

// MARK: - Local Hash Cache (persists sha256 across runs to skip re-hashing unchanged files)

private actor LocalHashCache {
    private struct Entry: Codable {
        let mtime:  Double
        let size:   Int64
        let sha256: String
    }

    private var store: [String: Entry] = [:]
    private let fileURL: URL

    var count: Int { store.count }

    init(label: String) {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NestVaultClient", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let safe = label.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? label
        fileURL = appSupport.appendingPathComponent("\(safe)_hashcache.json")
    }

    func load() {
        guard let data    = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        store = decoded
    }

    func set(path: String, mtime: Double, size: Int64, sha256: String) {
        store[path] = Entry(mtime: mtime, size: size, sha256: sha256)
    }

    /// Splits the scanned files into cache hits (fast: sha256 already known) and files
    /// that need hashing (slow), in a single actor hop for the whole list.
    /// Server-cache hits are absorbed into the local cache as a side effect.
    func classify(
        scanned: [BackupRunner.ScannedFile],
        serverPaths: [String],
        serverCache: [String: FileCache]
    ) -> (fast: [(url: URL, serverPath: String, sha256: String, mtime: Double)],
          slow: [(url: URL, serverPath: String, size: Int64, mtime: Double)]) {
        var fast: [(url: URL, serverPath: String, sha256: String, mtime: Double)] = []
        var slow: [(url: URL, serverPath: String, size: Int64, mtime: Double)]   = []
        for (file, serverPath) in zip(scanned, serverPaths) {
            // Local disk cache (fastest: avoids hash computation and server round-trip)
            if let e = store[file.url.path], e.mtime == file.mtime, e.size == file.size {
                fast.append((file.url, serverPath, e.sha256, file.mtime))
                continue
            }
            // Server version cache
            if let cached = serverCache[serverPath], cached.mtime == file.mtime, cached.size == file.size {
                fast.append((file.url, serverPath, cached.sha256, file.mtime))
                store[file.url.path] = Entry(mtime: file.mtime, size: file.size, sha256: cached.sha256)
                continue
            }
            slow.append((file.url, serverPath, file.size, file.mtime))
        }
        return (fast, slow)
    }

    /// Smart-skip detection: true when every scanned file has an exact mtime+size match
    /// in the cache and the counts line up — again a single hop for the whole list.
    func allUnchanged(scanned: [BackupRunner.ScannedFile]) -> Bool {
        guard scanned.count == store.count, !store.isEmpty else { return false }
        for file in scanned {
            guard let e = store[file.url.path], e.mtime == file.mtime, e.size == file.size
            else { return false }
        }
        return true
    }

    func prune(keepingPaths paths: Set<String>) {
        store = store.filter { paths.contains($0.key) }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Upload Progress Delegate

/// Per-task URLSession delegate that forwards sent-byte deltas (throttled to ≥2 MB steps)
/// so large uploads move the progress bar while the body is still being sent.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var reported: Int64 = 0
    private let minStep: Int64  = 2_000_000
    private let onDelta: @Sendable (Int64) -> Void

    init(onDelta: @escaping @Sendable (Int64) -> Void) { self.onDelta = onDelta }

    /// Total bytes already credited to the progress bar for this task.
    var totalReported: Int64 {
        lock.lock(); defer { lock.unlock() }
        return reported
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        lock.lock()
        let delta = totalBytesSent - reported
        guard delta >= minStep else { lock.unlock(); return }
        reported = totalBytesSent
        lock.unlock()
        onDelta(delta)
    }
}

// MARK: - FileCache (mtime+size fast path)

private struct FileCache {
    let sha256: String
    let mtime: Double
    let size: Int64
}

// MARK: - Stats Accumulator (actor — thread-safe parallel counting)

private actor StatsAccumulator {
    private var uploaded   = 0
    private var registered = 0
    private var cached     = 0
    private var ignored    = 0
    private var errors     = 0

    func record(action: String) {
        switch action {
        case "upload":   uploaded   += 1
        case "register": registered += 1
        case "cached":   cached     += 1
        default:         ignored    += 1
        }
    }

    func recordError() { errors += 1 }

    struct Snapshot { var uploaded, registered, cached, ignored, errors: Int }
    func snapshot() -> Snapshot {
        Snapshot(uploaded: uploaded, registered: registered, cached: cached,
                 ignored: ignored, errors: errors)
    }
}

// MARK: - Helpers

private extension String {
    var urlSafe: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
