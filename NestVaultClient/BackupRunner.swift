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

    enum RunStatus { case idle, running, done, failed, cancelled }

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
        var total = 0, uploaded = 0, registered = 0, cached = 0, ignored = 0, errors = 0
        var inherited = 0, skipped = 0
    }

    private enum FileAction {
        case skip
        case cachedRegister(sha256: String)   // mtime+size cache hit — counted as "cached"
        case register(sha256: String)          // contentExists = true
        case upload                            // contentExists = false
    }

    private struct ScannedFile {
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

    private let api: APIService
    private var isCancelled = false
    private var session = URLSession(configuration: .default)

    private let maxRetries = 3
    private let batchSize  = 100

    init(api: APIService) { self.api = api }

    func cancel() {
        guard status == .running else { return }
        isCancelled = true
        session.invalidateAndCancel()
        log(L("runner.cancel_requested"), .warning)
    }

    // MARK: - Run

    func run(profile: BackupProfile) async {
        session        = URLSession(configuration: .default)
        status         = .running
        isCancelled    = false
        entries        = []
        stats          = Stats()
        progress       = 0
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
        do {
            scannedFiles = try await Task.detached(priority: .userInitiated) {
                let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
                guard let enumerator = FileManager.default.enumerator(
                    at: URL(fileURLWithPath: source),
                    includingPropertiesForKeys: Array(resourceKeys),
                    options: []
                ) else {
                    throw NSError(domain: "NestVault", code: -1, userInfo: [:])
                }
                var files: [ScannedFile] = []
                while let url = enumerator.nextObject() as? URL {
                    if excludes.contains(url.lastPathComponent) || systemIgnoredNames.contains(url.lastPathComponent) {
                        enumerator.skipDescendants(); continue
                    }
                    let rv = try? url.resourceValues(forKeys: resourceKeys)
                    // Skip directories, symlinks-to-directories, and anything that isn't a plain regular file
                    if rv?.isSymbolicLink == true && rv?.isDirectory == true {
                        enumerator.skipDescendants(); continue
                    }
                    if rv?.isRegularFile != true { continue }
                    let mtime = rv?.contentModificationDate?.timeIntervalSince1970 ?? 0
                    let size  = Int64(rv?.fileSize ?? 0)
                    files.append(ScannedFile(url: url, mtime: mtime, size: size))
                }
                return files
            }.value
        } catch {
            log(L("runner.source_unreadable", source), .error)
            await finalizeVersion(label: label, versionKey: versionKey, ok: false)
            DockProgress.shared.update(progress: nil)
            status = .failed; return
        }

        stats.total = scannedFiles.count
        log(L("runner.files_found", scannedFiles.count), .info)

        // Smart skip: if enabled, 0 local changes detected, and last full backup is within 7 days,
        // skip classify/execute/sync and absorb directly from the previous version.
        if profile.smartSkip, let prevDoneKey {
            let noChanges = await detectNoChanges(scanned: scannedFiles, hashCache: hashCache)
            let overdue   = profile.lastFullBackupDate.map {
                Date().timeIntervalSince($0) > 7 * 86_400
            } ?? true   // nil = never ran a full backup → must run full

            if noChanges && !overdue {
                log(L("runner.smart_skip_detected", scannedFiles.count), .info)
                wasFullBackup = false
                do {
                    let result = try await api.absorb(
                        session: session, label: label,
                        versionKey: versionKey, sourceVersionKey: prevDoneKey)
                    stats.inherited = result.inherited
                    stats.skipped   = result.skipped
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

        // Split into cache hits and files that need hashing
        var fastEntries: [(url: URL, serverPath: String, sha256: String, mtime: Double)] = []
        var slowEntries: [(url: URL, serverPath: String, size: Int64, mtime: Double)] = []

        for (file, serverPath) in zip(scannedFiles, serverPaths) {
            guard !isCancelled else { break }
            // Local disk cache (fastest: avoids hash computation and server round-trip)
            if let sha256 = await hashCache.lookup(path: file.url.path, mtime: file.mtime, size: file.size) {
                fastEntries.append((file.url, serverPath, sha256, file.mtime))
                continue
            }
            // Server version cache
            if let cached = cache[serverPath], cached.mtime == file.mtime, cached.size == file.size {
                fastEntries.append((file.url, serverPath, cached.sha256, file.mtime))
                await hashCache.set(path: file.url.path, mtime: file.mtime, size: file.size, sha256: cached.sha256)
                continue
            }
            slowEntries.append((file.url, serverPath, file.size, file.mtime))
        }

        if isCancelled {
            await finalizeVersion(label: label, versionKey: versionKey, ok: false)
            progress = 0; currentFile = ""; status = .cancelled
            DockProgress.shared.update(progress: nil)
            log(L("runner.cancelled"), .warning); return
        }

        log(L("runner.classifying", fastEntries.count, slowEntries.count), .info)

        // Hash slow files in parallel
        var hashedFiles: [HashedFile] = []
        let totalSlow = slowEntries.count
        let phase1Weight = totalSlow > 0 ? 0.4 : 0.0

        let hashConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount)
        await withTaskGroup(of: HashedFile?.self) { group in
            var inFlight = 0
            var index    = 0
            var done     = 0

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
                if inFlight > 0, let result = await group.next() {
                    inFlight -= 1
                    done     += 1
                    if let hf = result {
                        hashedFiles.append(hf)
                        await hashCache.set(path: hf.url.path, mtime: hf.mtime,
                                            size: hf.size, sha256: hf.sha256)
                    }
                    progress    = Double(done) / Double(max(totalSlow, 1)) * phase1Weight
                    currentFile = result?.url.lastPathComponent ?? ""
                    DockProgress.shared.update(progress: progress)
                }
            }
        }

        if isCancelled {
            await finalizeVersion(label: label, versionKey: versionKey, ok: false)
            progress = 0; currentFile = ""; status = .cancelled
            DockProgress.shared.update(progress: nil)
            log(L("runner.cancelled"), .warning); return
        }

        // Classify hashed files via batch or individual /check
        var actionMap: [String: (action: FileAction, url: URL, mtime: Double)] = [:]

        if useBatch && !hashedFiles.isEmpty {
            let batches = stride(from: 0, to: hashedFiles.count, by: batchSize)
                .map { Array(hashedFiles[$0..<min($0 + batchSize, hashedFiles.count)]) }
            for batch in batches {
                guard !isCancelled else { break }
                let items = batch.map {
                    CheckBatchItem(originalPath: $0.serverPath, sha256: $0.sha256,
                                   size: Int($0.size), mtime: $0.mtime)
                }
                do {
                    let results = try await api.checkBatch(
                        session: session, label: label,
                        versionKey: versionKey, items: items)
                    for (idx, result) in results.enumerated() {
                        let item = items[idx]; let h = batch[idx]
                        if !result.needsUpload {
                            actionMap[item.originalPath] = (.skip, h.url, h.mtime)
                        } else if result.contentExists {
                            actionMap[item.originalPath] = (.register(sha256: item.sha256), h.url, h.mtime)
                        } else {
                            actionMap[item.originalPath] = (.upload, h.url, h.mtime)
                        }
                    }
                } catch {
                    log(L("runner.batch_check_error", error.localizedDescription), .warning)
                    for h in batch {
                        actionMap[h.serverPath] = (.upload, h.url, h.mtime)
                    }
                }
            }
        } else {
            // Fallback: individual /check per file
            for h in hashedFiles {
                guard !isCancelled else { break }
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
                    actionMap[h.serverPath] = (.upload, h.url, h.mtime); continue
                }
                if !resp.needsUpload {
                    actionMap[h.serverPath] = (.skip, h.url, h.mtime)
                } else if resp.contentExists {
                    actionMap[h.serverPath] = (.register(sha256: h.sha256), h.url, h.mtime)
                } else {
                    actionMap[h.serverPath] = (.upload, h.url, h.mtime)
                }
            }
        }

        // ── PHASE 2: Execute actions ─────────────────────────────────────────

        struct WorkItem {
            let action: FileAction
            let url: URL; let serverPath: String; let mtime: Double
        }

        var workItems: [WorkItem] = []
        for f in fastEntries {
            workItems.append(WorkItem(action: .cachedRegister(sha256: f.sha256),
                                      url: f.url, serverPath: f.serverPath, mtime: f.mtime))
        }
        for (path, entry) in actionMap {
            workItems.append(WorkItem(action: entry.action, url: entry.url,
                                      serverPath: path, mtime: entry.mtime))
        }

        let totalWork        = workItems.count
        let concurrencyLimit = max(1, profile.workers)
        let phase2Start      = phase1Weight

        await withTaskGroup(of: Void.self) { group in
            var inFlight        = 0
            var index           = 0
            var completedPhase2 = 0

            while index < workItems.count || inFlight > 0 {
                while inFlight < concurrencyLimit && index < workItems.count {
                    guard !isCancelled else { break }
                    let item = workItems[index]
                    index   += 1
                    inFlight += 1

                    group.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            let actionStr = try await self.executeActionWithRetry(
                                item.action, url: item.url,
                                label: label, versionKey: versionKey,
                                serverPath: item.serverPath, mtime: item.mtime)
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
                        await MainActor.run {
                            self.currentFile = item.url.lastPathComponent
                        }
                    }
                }

                if isCancelled && inFlight == 0 { break }

                if inFlight > 0 {
                    await group.next()
                    inFlight -= 1
                    completedPhase2 += 1
                    progress = phase2Start + Double(completedPhase2) / Double(max(totalWork, 1)) * (1.0 - phase2Start)
                    DockProgress.shared.update(progress: progress)
                    let s = await accumulator.snapshot()
                    stats.uploaded   = s.uploaded
                    stats.registered = s.registered
                    stats.cached     = s.cached
                    stats.ignored    = s.ignored
                    stats.errors     = s.errors
                }
            }
        }

        if isCancelled {
            await finalizeVersion(label: label, versionKey: versionKey, ok: false)
            progress = 0; currentFile = ""; status = .cancelled
            DockProgress.shared.update(progress: nil)
            log(L("runner.cancelled"), .warning); return
        }

        // 6. Sync
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
                    stats.skipped   = result.skipped
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

    // MARK: - Smart Skip Detection

    private func detectNoChanges(
        scanned: [ScannedFile],
        hashCache: LocalHashCache
    ) async -> Bool {
        let cacheCount = await hashCache.count
        guard scanned.count == cacheCount, cacheCount > 0 else { return false }
        for file in scanned {
            guard await hashCache.lookup(
                path: file.url.path, mtime: file.mtime, size: file.size
            ) != nil else { return false }
        }
        return true
    }

    // MARK: - Action Execution

    private func executeActionWithRetry(
        _ action: FileAction,
        url: URL, label: String, versionKey: String,
        serverPath: String, mtime: Double
    ) async throws -> String {
        var currentAction = action
        var lastError: Error?
        for attempt in 1...maxRetries {
            guard !isCancelled else { throw CancellationError() }
            do {
                return try await executeAction(currentAction, url: url, label: label,
                                               versionKey: versionKey,
                                               serverPath: serverPath, mtime: mtime)
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
        serverPath: String, mtime: Double
    ) async throws -> String {
        guard !isCancelled else { throw CancellationError() }
        let pathB64 = Data(serverPath.utf8).base64EncodedString()

        switch action {
        case .skip:
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
            if case .cachedRegister = action { return "cached" }
            return "register"

        case .upload:
            var req = try api.buildRequest("/upload", method: "POST", body: nil)
            // Large files can take a long time to encrypt/store server-side after the body is
            // fully received — use a generous idle timeout so the server has room to process.
            req.timeoutInterval = 3600
            req.setValue(label,                      forHTTPHeaderField: "X-Backup-Label")
            req.setValue(versionKey,                 forHTTPHeaderField: "X-Version-Key")
            req.setValue(pathB64,                    forHTTPHeaderField: "X-Original-Path")
            req.setValue(String(mtime),              forHTTPHeaderField: "X-Mtime")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (respData, response) = try await session.upload(for: req, fromFile: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let msg = String(data: respData, encoding: .utf8) ?? "(sem mensagem)"
                throw NSError(domain: "NestVault", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) — \(msg.prefix(300))"])
            }
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

    private func log(_ text: String, _ kind: LogEntry.Kind) {
        entries.append(LogEntry(text: text, kind: kind))
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

    func lookup(path: String, mtime: Double, size: Int64) -> String? {
        guard let e = store[path], e.mtime == mtime, e.size == size else { return nil }
        return e.sha256
    }

    func set(path: String, mtime: Double, size: Int64, sha256: String) {
        store[path] = Entry(mtime: mtime, size: size, sha256: sha256)
    }

    func prune(keepingPaths paths: Set<String>) {
        store = store.filter { paths.contains($0.key) }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: fileURL, options: .atomic)
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
