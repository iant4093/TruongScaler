import Foundation
import CryptoKit
import CoreIngestion
import TruongScalerCore

enum CachedImageDecodeError: LocalizedError, Sendable {
    case sourceChangedWhileOpening
    var errorDescription: String? {
        "This photo changed while it was opening. Open it again to load its current contents."
    }
}

/// A bounded cache of immutable decoded mmap frames. The caller still owns the source grant through
/// hashing/decode. Validated output-record hashes avoid redundant initial hashing on reopen; a
/// cache miss verifies the source again after decoding. Arbitrary inputs are content-hashed, so
/// same-size/timestamp edits never reuse stale pixels. Cached frames
/// are local mmap references, not retained security-scoped URLs or a second full-image heap copy.
actor CachingStudioImageDecoder: StudioImageDecoding {
    private struct Key: Hashable { let path: String; let digest: String }
    private struct Entry { let decoded: DecodedSourceResult; let bytes: Int; var lastUse: UInt64 }
    private struct Pending {
        let id: UUID
        let generation: UInt64
        let task: Task<DecodedSourceResult, Error>
    }
    private let base: any StudioImageDecoding
    private let capacityBytes: Int
    private let io = BlockingIOOwner(label: "com.truongscaler.decode-cache-validation")
    private var entries: [Key: Entry] = [:]
    private var pending: [Key: Pending] = [:]
    private var clock: UInt64 = 0
    private var generation: UInt64 = 0
    private(set) var retainedBytes = 0

    init(base: any StudioImageDecoding = BlockingStudioImageDecoder(), capacityBytes: Int? = nil) {
        self.base = base
        self.capacityBytes = max(0, capacityBytes ?? Int(min(512 * 1024 * 1024, HardwareTelemetry.currentAvailableMemoryBytes() / 8)))
    }

    func decodeImage(at url: URL, destinationMMapURL: URL) async throws -> DecodedSourceResult {
        try await decodeImage(at: url, destinationMMapURL: destinationMMapURL, validatedContentSHA256: nil)
    }

    func decodeImage(at url: URL, destinationMMapURL: URL, validatedContentSHA256: String?) async throws -> DecodedSourceResult {
        let requestGeneration = generation
        let digest: String
        if let validatedContentSHA256 { digest = validatedContentSHA256 }
        else {
            digest = try await Self.contentDigest(at: url, io: io)
        }
        try Task.checkCancellation()
        let key = Key(path: url.standardizedFileURL.path, digest: digest)
        clock &+= 1
        if var hit = entries[key] {
            hit.lastUse = clock
            entries[key] = hit
            return hit.decoded
        }
        let operation: Pending
        if let existing = pending[key], existing.generation == requestGeneration { operation = existing }
        else {
            let base = self.base
            let io = self.io
            operation = Pending(id: UUID(), generation: requestGeneration, task: Task {
                let decoded = try await base.decodeImage(at: url, destinationMMapURL: destinationMMapURL)
                // An editor or Files provider can replace the live source while its decode is
                // queued. Never cache those new pixels under the earlier content digest, or
                // accept a saved-result decode whose verified bytes changed during opening.
                let currentDigest: String
                do { currentDigest = try await Self.contentDigest(at: url, io: io) }
                catch { throw CachedImageDecodeError.sourceChangedWhileOpening }
                guard currentDigest == digest else { throw CachedImageDecodeError.sourceChangedWhileOpening }
                return decoded
            })
            pending[key] = operation
        }
        let decoded: DecodedSourceResult
        do { decoded = try await operation.task.value }
        catch {
            if pending[key]?.id == operation.id { pending[key] = nil }
            throw error
        }
        if pending[key]?.id == operation.id { pending[key] = nil }
        // A cancelled reader still drains the shared decode under its own file grant, then exits.
        // It never cancels a task another current reader needs or repopulates after a memory purge.
        try Task.checkCancellation()
        let bytes = decoded.sourceBuffer.totalByteSize
        if generation == requestGeneration, bytes <= capacityBytes, !Task.isCancelled {
            if let replaced = entries.removeValue(forKey: key) { retainedBytes -= replaced.bytes }
            while retainedBytes + bytes > capacityBytes || entries.count >= 3 {
                guard let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key,
                      let removed = entries.removeValue(forKey: oldest) else { break }
                retainedBytes -= removed.bytes
            }
            clock &+= 1
            entries[key] = Entry(decoded: decoded, bytes: bytes, lastUse: clock)
            retainedBytes += bytes
        }
        return decoded
    }

    func purge() { generation &+= 1; entries.removeAll(); pending.removeAll(); retainedBytes = 0 }

    private nonisolated static func contentDigest(at url: URL, io: BlockingIOOwner) async throws -> String {
        try await io.run {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var sha = SHA256()
            while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty { sha.update(data: bytes) }
            return sha.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
}
