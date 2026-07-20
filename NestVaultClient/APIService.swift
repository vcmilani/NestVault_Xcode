import Foundation
import Security

// MARK: - APIService-only response types

struct HealthResponse: Decodable {
    let status: String
    let version: String
    let time: String
}

struct VersionDeletedResponse: Decodable {
    let status: String
    let versionKey: String
    let filesRemovedFromStorage: Int

    enum CodingKeys: String, CodingKey {
        case status
        case versionKey               = "version_key"
        case filesRemovedFromStorage  = "files_removed_from_storage"
    }
}

// MARK: - Backoff

struct BackoffState {
    var failureCount: Int = 0
    var nextRetry: Date?  = nil

    var humanReadable: String {
        guard let next = nextRetry else { return "" }
        let secs = Int(next.timeIntervalSinceNow)
        if secs <= 0 { return L("backoff.ready") }
        return L("backoff.next", secs)
    }
}

// MARK: - APIService

@MainActor
final class APIService: ObservableObject {
    @Published var serverURL: String = UserDefaults.standard.string(forKey: "server_url") ?? "http://192.168.1.100:8000"
    @Published var apiKey:    String
    @Published var isConnected: Bool = false
    @Published var connectionError: String? = nil
    @Published var isLoadingBackups: Bool = false
    @Published var backups: [BackupSummary] = []
    @Published var serverVersion: String = ""
    @Published var backoff = BackoffState()

    var globalStats: GlobalStats {
        GlobalStats(
            totalBackups:  backups.count,
            totalVersions: backups.reduce(0) { $0 + $1.versionCount },
            totalFiles:    backups.reduce(0) { $0 + $1.fileCount },
            totalSize:     backups.reduce(0) { $0 + $1.totalSizeBytes }
        )
    }

    init() {
        if let stored = KeychainStore.string(for: "api_key") {
            apiKey = stored
        } else if let legacy = UserDefaults.standard.string(forKey: "api_key"), !legacy.isEmpty {
            // One-time migration: pre-Keychain builds kept the key in UserDefaults (plaintext).
            apiKey = legacy
            KeychainStore.set(legacy, for: "api_key")
            UserDefaults.standard.removeObject(forKey: "api_key")
        } else {
            apiKey = ""
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(serverURL, forKey: "server_url")
        KeychainStore.set(apiKey, for: "api_key")
    }

    // MARK: - Batch Support

    func supportsBatch() -> Bool {
        let parts = serverVersion.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return (parts[0], parts[1]) >= (2, 6)
    }

    /// /register/batch exists from server 7.8 — older servers fall back to
    /// one register request per file.
    func supportsBatchRegister() -> Bool {
        let parts = serverVersion.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return false }
        return (parts[0], parts[1]) >= (7, 8)
    }

    func registerBatch(
        session: URLSession,
        label: String,
        versionKey: String,
        items: [RegisterBatchItem]
    ) async throws -> RegisterBatchResponse {
        let body = try JSONEncoder().encode(
            RegisterBatchRequest(backupLabel: label, versionKey: versionKey, files: items))
        var req = try buildRequest("/register/batch", method: "POST", body: body)
        req.timeoutInterval = 60
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw apiError(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(RegisterBatchResponse.self, from: data)
    }

    func checkBatch(
        session: URLSession,
        label: String,
        versionKey: String,
        items: [CheckBatchItem]
    ) async throws -> [CheckBatchResultItem] {
        let body = try JSONEncoder().encode(
            CheckBatchRequest(backupLabel: label, versionKey: versionKey, files: items))
        var req = try buildRequest("/check/batch", method: "POST", body: body)
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw apiError(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode([CheckBatchResultItem].self, from: data)
    }

    // MARK: - Health

    func checkHealth() async {
        do {
            var req  = try buildRequest("/health", method: "GET", body: nil)
            req.timeoutInterval = 5
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                let health = try JSONDecoder().decode(HealthResponse.self, from: data)
                isConnected    = true
                serverVersion  = health.version
                connectionError = nil
                backoff.failureCount = 0
                backoff.nextRetry    = nil
            } else {
                throw URLError(.badServerResponse)
            }
        } catch {
            isConnected     = false
            connectionError = error.localizedDescription
            backoff.failureCount += 1
        }
    }

    // MARK: - Backups

    func fetchBackups() async {
        isLoadingBackups = true
        defer { isLoadingBackups = false }
        do {
            var req = try buildRequest("/backups", method: "GET", body: nil)
            req.timeoutInterval = 20
            let (data, _) = try await URLSession.shared.data(for: req)
            backups = try JSONDecoder().decode([BackupSummary].self, from: data)
        } catch {
            // Silently fail — caller can check isConnected
        }
    }

    func deleteBackup(label: String) async throws {
        var req = try buildRequest("/backups/\(label.urlSafe)", method: "DELETE", body: nil)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw apiError(http.statusCode, msg)
        }
    }

    // MARK: - Off-main decoding

    /// Decodes on a background task. APIService is MainActor-isolated, so decoding
    /// large payloads (a version's full file list) inline would hitch the UI.
    nonisolated private static func decodeDetached<T: Decodable & Sendable>(
        _ type: T.Type, from data: Data
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(T.self, from: data)
        }.value
    }

    // MARK: - Versions

    func fetchVersions(label: String) async throws -> [BackupVersion] {
        var req = try buildRequest("/backups/\(label.urlSafe)/versions", method: "GET", body: nil)
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try await Self.decodeDetached([BackupVersion].self, from: data)
    }

    func fetchVersionDetail(label: String, versionKey: String) async throws -> BackupVersion {
        let req = try buildRequest(
            "/backups/\(label.urlSafe)/versions/\(versionKey.urlSafe)",
            method: "GET", body: nil)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(BackupVersion.self, from: data)
    }

    func deleteVersion(label: String, versionKey: String) async throws -> VersionDeletedResponse {
        var req = try buildRequest(
            "/backups/\(label.urlSafe)/versions/\(versionKey.urlSafe)",
            method: "DELETE", body: nil)
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(VersionDeletedResponse.self, from: data)
    }

    // MARK: - Files

    func fetchFiles(label: String, versionKey: String) async throws -> [VersionFile] {
        let escaped = versionKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? versionKey
        var req = try buildRequest(
            "/files?backup_label=\(label.urlSafe)&version_key=\(escaped)",
            method: "GET", body: nil)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try await Self.decodeDetached([VersionFile].self, from: data)
    }

    /// Request for GET /files/{id}/download — executed by RestoreRunner on its own
    /// session (same pattern as BackupRunner's use of buildRequest).
    func downloadRequest(fileId: Int) throws -> URLRequest {
        var req = try buildRequest("/files/\(fileId)/download", method: "GET", body: nil)
        req.timeoutInterval = 3600
        return req
    }

    // MARK: - Cleanup

    func cleanup(label: String, keep: Int) async throws -> CleanupResult {
        let body = try JSONSerialization.data(withJSONObject: [
            "backup_label": label, "keep": keep
        ] as [String: Any])
        var req = try buildRequest("/backups/\(label.urlSafe)/cleanup", method: "POST", body: body)
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        var r = try JSONDecoder().decode(CleanupResult.self, from: data)
        r.label = label
        return r
    }

    struct CleanupAllOutcome {
        let results: [CleanupResult]
        let errors:  [(label: String, message: String)]
    }

    /// Runs cleanup for every backup label. Sequential on purpose — the server-side
    /// cleanup is a heavy SQLite + storage-deletion operation — but one failing label
    /// no longer aborts the rest: failures are collected per label.
    func cleanupAll(keep: Int) async -> CleanupAllOutcome {
        var results: [CleanupResult] = []
        var errors:  [(label: String, message: String)] = []
        for backup in backups {
            do {
                results.append(try await cleanup(label: backup.label, keep: keep))
            } catch {
                errors.append((backup.label, error.localizedDescription))
            }
        }
        return CleanupAllOutcome(results: results, errors: errors)
    }

    // MARK: - Absorb

    func absorb(session: URLSession, label: String,
                versionKey: String, sourceVersionKey: String) async throws -> AbsorbResponse {
        let body = try JSONEncoder().encode(AbsorbRequest(sourceVersionKey: sourceVersionKey))
        var req  = try buildRequest(
            "/backups/\(label.urlSafe)/versions/\(versionKey.urlSafe)/absorb",
            method: "POST", body: body)
        req.timeoutInterval = 300
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(AbsorbResponse.self, from: data)
    }

    // MARK: - Request Builder

    func buildRequest(_ path: String, method: String, body: Data?) throws -> URLRequest {
        guard let url = URL(string: serverURL + path) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = method
        if !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        if let body {
            req.httpBody = body
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        return req
    }

    // MARK: - Private helpers

    private func apiError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "NestVault", code: code,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) — \(message.prefix(200))"])
    }
}

// MARK: - Keychain

/// Minimal generic-password Keychain wrapper for the API key.
enum KeychainStore {
    private static let service = "com.vcm.nestvault"

    static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData  as String: true,
            kSecMatchLimit  as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores the value; an empty string deletes the item.
    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard !value.isEmpty else {
            SecItemDelete(base as CFDictionary)
            return
        }
        let data   = Data(value.utf8)
        let status = SecItemUpdate(base as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

// MARK: - Shared helpers

private extension String {
    var urlSafe: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
