import Foundation
import CryptoKit

/// Streaming SHA-256 shared by backup (dedup/classify) and restore (integrity verify).
func computeSHA256Streaming(url: URL) async throws -> (sha256: String, size: Int) {
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
