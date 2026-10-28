import Foundation
import Darwin
import CryptoKit
import TruongScalerCore

/// Exact destination rectangle of one upscaled tile, clipped to the output canvas.
/// Specification: `docs/DEVELOPMENT.md` Section 1.3.
public struct TileJournalRect: Codable, Sendable, Equatable {
    public static let bytesPerPixel = 8 // 4 x Float16 (R, G, B, A)

    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// `width * 8 * height`, or `0` when that product cannot be represented in `Int`.
    ///
    /// This property deliberately never traps: a manifest or tile plan can be decoded from
    /// untrusted/on-disk state. Callers that need to distinguish a genuinely empty rectangle from
    /// an unrepresentable one must use `checkedByteCount(width:height:)`.
    public var byteCount: Int {
        Self.checkedByteCount(width: width, height: height) ?? 0
    }

    /// Checked `width * bytesPerPixel * height`. Returns `nil` for non-positive or overflowing
    /// geometry so untrusted dimensions are rejected instead of trapping the process.
    public static func checkedByteCount(width: Int, height: Int) -> Int? {
        guard width > 0, height > 0 else { return nil }
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: bytesPerPixel)
        guard !rowOverflow else { return nil }
        let (total, totalOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !totalOverflow, total > 0 else { return nil }
        return total
    }

    /// Clips `[destX ..< destX + size] x [destY ..< destY + size]` to the canvas.
    /// Returns `nil` when the intersection is empty or the arithmetic would overflow.
    public static func clipped(
        destX: Int,
        destY: Int,
        size: Int,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> TileJournalRect? {
        guard canvasWidth > 0, canvasHeight > 0, size > 0 else { return nil }
        let (destXEnd, destXOverflow) = destX.addingReportingOverflow(size)
        let (destYEnd, destYOverflow) = destY.addingReportingOverflow(size)
        guard !destXOverflow, !destYOverflow else { return nil }
        let minX = max(0, destX)
        let minY = max(0, destY)
        let maxX = min(canvasWidth, destXEnd)
        let maxY = min(canvasHeight, destYEnd)
        guard maxX > minX, maxY > minY else { return nil }
        return TileJournalRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Durable per-tile undo manifest. `sha256` is the lowercase CryptoKit SHA-256 hex digest of the
/// `.undo` bytes. One manifest + one `.undo` file form a single tile transaction journal.
/// Specification: `docs/DEVELOPMENT.md` Section 1.3.
public struct TileJournalManifest: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let jobID: UUID
    public let tileIndex: Int
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let byteCount: Int
    public let sha256: String
    public let createdAt: Date

    public init(
        version: Int = TileJournalManifest.currentVersion,
        jobID: UUID,
        tileIndex: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        byteCount: Int,
        sha256: String,
        createdAt: Date = Date()
    ) {
        self.version = version
        self.jobID = jobID
        self.tileIndex = tileIndex
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.sha256 = sha256
        self.createdAt = createdAt
    }

    public var rect: TileJournalRect {
        TileJournalRect(x: x, y: y, width: width, height: height)
    }
}

/// A journal manifest together with its resolved, containment-checked file URLs.
public struct TileJournalRecord: Sendable, Equatable {
    public let manifest: TileJournalManifest
    public let manifestURL: URL
    public let undoURL: URL

    public init(manifest: TileJournalManifest, manifestURL: URL, undoURL: URL) {
        self.manifest = manifest
        self.manifestURL = manifestURL
        self.undoURL = undoURL
    }
}

/// Deterministic recovery/cleanup boundaries for persistent-state interruption tests.
///
/// A handler may throw at any point to model process death at that boundary. The journal files are
/// left in exactly the state a real interruption would leave them in, so a subsequent `recover`
/// proves idempotence. This is persistent-state simulation — not a SIGKILL claim.
public enum TileJournalRecoveryFaultPoint: String, Sendable, CaseIterable, Equatable {
    /// Undo bytes were streamed into the canvas, `flushRange` has not been called yet.
    case afterRollbackWriteBeforeFlush
    /// Undo bytes were written and the affected rows were synchronously flushed.
    case afterRollbackFlush
    /// The pending manifest was atomically renamed to the restored marker; undo bytes remain.
    case afterManifestRetirementBeforeUndoRemoval
    /// The undo bytes were removed; the restored marker still proves rollback completed.
    case afterUndoRemovalBeforeMarkerRemoval
    /// The restored marker was removed; the directory `fsync` has not happened yet.
    case afterMarkerRemovalBeforeDirectorySync
    /// Every cleanup step (including the final directory sync) completed.
    case afterCleanupCompleted
}

/// Receives recovery/cleanup boundary callbacks. Throw to simulate an interruption at that point.
public typealias TileJournalFaultHandler = (TileJournalRecoveryFaultPoint) throws -> Void

/// Durable per-tile undo transaction used by `TiledPipelineExecutor` so arbitrary process
/// termination is recovered by exact pixel rollback instead of a second (double) blend.
///
/// Layout under `workingDirectory` (all `PathSafety`-validated):
/// - `journal_<jobID>_<tileIndex>.undo` — raw clipped-rectangle rows, `width * 8` bytes per row
/// - `journal_<jobID>_<tileIndex>.json` — `TileJournalManifest` (pending commit record)
/// - `journal_<jobID>_<tileIndex>.json.restored` — durable **restored marker** proving rollback
///   completed for that tile
///
/// No full-image copy is ever held in RAM: publishing streams rows from the mmap canvas into the
/// undo file while hashing, and restoring streams them back after validating the digest.
/// Specification: `docs/DEVELOPMENT.md` Section 1.3.
public struct TileUndoJournal: Sendable {
    /// Generous upper bound for the manifest JSON so disk-space checks can reserve journal space.
    public static let maximumManifestBytes = 4 * 1024

    public let workingDirectory: URL

    /// Non-throwing: the journal only needs the containing directory to exist when it publishes,
    /// restores, or cleans up (the owning checkpoint store creates the working directory).
    public init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    // MARK: - Paths

    public func undoFileURL(jobID: UUID, tileIndex: Int) throws -> URL {
        try PathSafety.childURL(
            in: workingDirectory,
            relativePath: "journal_\(jobID.uuidString)_\(tileIndex).undo"
        )
    }

    public func manifestFileURL(jobID: UUID, tileIndex: Int) throws -> URL {
        try PathSafety.childURL(
            in: workingDirectory,
            relativePath: "journal_\(jobID.uuidString)_\(tileIndex).json"
        )
    }

    /// Durable restored marker. Its existence (after the atomic rename) is the proof that the
    /// rollback write + flush completed, so the pending manifest can never be mistaken for an
    /// unfinished journal again.
    public func restoredMarkerFileURL(jobID: UUID, tileIndex: Int) throws -> URL {
        try PathSafety.childURL(
            in: workingDirectory,
            relativePath: "journal_\(jobID.uuidString)_\(tileIndex).json.restored"
        )
    }

    public static func undoByteCount(for rect: TileJournalRect) -> Int {
        rect.byteCount
    }

    // MARK: - Publish

    /// Durably publishes the undo journal for `rect`: stream-copies exactly those canvas rows into a
    /// temporary sibling file (hashing while copying), `fsync`s it, writes and `fsync`s the manifest,
    /// atomically renames both into place, then `fsync`s the containing directory.
    ///
    /// This MUST complete before any canvas mutation for the tile. The manifest rename is the commit
    /// record: an `.undo` file without a manifest was never published and is removed by `scan`.
    @discardableResult
    public func publish(
        jobID: UUID,
        tileIndex: Int,
        rect: TileJournalRect,
        from canvas: MMapBuffer
    ) throws -> TileJournalManifest {
        let undoURL = try undoFileURL(jobID: jobID, tileIndex: tileIndex)
        let manifestURL = try manifestFileURL(jobID: jobID, tileIndex: tileIndex)
        let markerURL = try restoredMarkerFileURL(jobID: jobID, tileIndex: tileIndex)
        let corrupted = ScalerError.checkpointCorrupted(manifestURL)

        guard tileIndex >= 0,
              let byteCount = TileJournalRect.checkedByteCount(width: rect.width, height: rect.height),
              rect.x >= 0, rect.y >= 0,
              rect.width <= canvas.width, rect.height <= canvas.height,
              rect.x <= canvas.width - rect.width,
              rect.y <= canvas.height - rect.height else {
            throw corrupted
        }
        let rowBytes = rect.width * TileJournalRect.bytesPerPixel

        // A leftover restored marker for this tile only proves an earlier rollback finished; the new
        // transaction supersedes it. Remove it before the new manifest becomes the commit record.
        try removeFileIfExists(markerURL)

        let uniqueSuffix = UUID().uuidString
        let tempUndoURL = workingDirectory.appendingPathComponent(
            "journal_\(jobID.uuidString)_\(tileIndex).undo.tmp-\(uniqueSuffix)"
        )
        let tempManifestURL = workingDirectory.appendingPathComponent(
            "journal_\(jobID.uuidString)_\(tileIndex).json.tmp-\(uniqueSuffix)"
        )
        _ = try PathSafety.assertContained(tempUndoURL, in: workingDirectory)
        _ = try PathSafety.assertContained(tempManifestURL, in: workingDirectory)

        var undoRenamed = false
        do {
            // 1. Stream exactly the clipped rectangle rows into the undo temp while hashing.
            let undoFD = Darwin.open(tempUndoURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            guard undoFD >= 0 else {
                throw ScalerError.mmapAllocationFailed(errno: errno, requestedBytes: byteCount)
            }
            var hasher = SHA256()
            do {
                for row in 0..<rect.height {
                    let sourceRow = canvas
                        .unsafeRowPointer(y: rect.y + row)
                        .advanced(by: rect.x * TileJournalRect.bytesPerPixel)
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(start: sourceRow, count: rowBytes))
                    try Self.writeAll(undoFD, from: sourceRow, byteCount: rowBytes)
                }
                guard Darwin.fsync(undoFD) == 0 else {
                    throw ScalerError.mmapSyncFailed(errno: errno)
                }
            } catch {
                _ = Darwin.close(undoFD)
                throw error
            }
            guard Darwin.close(undoFD) == 0 else {
                throw ScalerError.mmapSyncFailed(errno: errno)
            }

            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let manifest = TileJournalManifest(
                jobID: jobID,
                tileIndex: tileIndex,
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: rect.height,
                byteCount: byteCount,
                sha256: digest,
                createdAt: Date()
            )

            // 2. Write + fsync the manifest temp.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let manifestData = try encoder.encode(manifest)
            let manifestFD = Darwin.open(tempManifestURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            guard manifestFD >= 0 else {
                throw ScalerError.mmapAllocationFailed(errno: errno, requestedBytes: manifestData.count)
            }
            do {
                try manifestData.withUnsafeBytes { rawBuffer in
                    try Self.writeAll(manifestFD, from: rawBuffer.baseAddress, byteCount: rawBuffer.count)
                }
                guard Darwin.fsync(manifestFD) == 0 else {
                    throw ScalerError.mmapSyncFailed(errno: errno)
                }
            } catch {
                _ = Darwin.close(manifestFD)
                throw error
            }
            guard Darwin.close(manifestFD) == 0 else {
                throw ScalerError.mmapSyncFailed(errno: errno)
            }

            // 3. Atomically publish: undo bytes first, then the manifest commit record.
            guard Darwin.rename(tempUndoURL.path, undoURL.path) == 0 else {
                throw ScalerError.mmapSyncFailed(errno: errno)
            }
            undoRenamed = true
            guard Darwin.rename(tempManifestURL.path, manifestURL.path) == 0 else {
                throw ScalerError.mmapSyncFailed(errno: errno)
            }
            undoRenamed = false // Both names are published; the journal is now consistent.

            // 4. Make the renames durable.
            try fsyncDirectory()
            return manifest
        } catch {
            try? FileManager.default.removeItem(at: tempUndoURL)
            try? FileManager.default.removeItem(at: tempManifestURL)
            if undoRenamed {
                try? FileManager.default.removeItem(at: undoURL)
            }
            throw error
        }
    }

    // MARK: - Scan / recovery

    /// Enumerates only this job's contained pending journal manifests, sorted by tile index.
    /// Removes leftover temporary artifacts, unpublished `.undo` files (no manifest => no mutation),
    /// and restored markers whose rollback already completed.
    ///
    /// A restored marker is never treated as a pending journal and never causes a canvas write.
    public func scan(jobID: UUID) throws -> [TileJournalRecord] {
        let inventory = try makeInventory(jobID: jobID)
        var changed = false

        // A marker is durable proof that rollback completed; both it and any leftover undo bytes for
        // that tile are safe to remove idempotently.
        for marker in inventory.markers {
            try removeFileIfExists(marker.undoURL)
            try removeFileIfExists(marker.markerURL)
            changed = true
        }
        // An undo file without a manifest and without a restored marker was never a published
        // transaction (publish renames the manifest last), so it cannot back a canvas mutation.
        for undoURL in inventory.orphanUndoURLs {
            try removeFileIfExists(undoURL)
            changed = true
        }
        for temporaryURL in inventory.temporaryURLs {
            try removeFileIfExists(temporaryURL)
            changed = true
        }
        if changed {
            try fsyncDirectory()
        }
        return inventory.pending
    }

    /// Restores the exact pre-blend rectangle of the single possible in-flight tile (if any),
    /// discards journals for already-committed tiles, and cleans restored markers.
    ///
    /// - Validates the exact frontier: after `lastCompletedTileIndex` the only permissible
    ///   uncommitted tile is `lastCompletedTileIndex + 1` (and `< totalTiles`). Committed tiles
    ///   `<= lastCompletedTileIndex` may be discarded. Multiple pending journals, a restored marker
    ///   for any other future tile, or any out-of-plan record throws `checkpointCorrupted` **before**
    ///   mutating the canvas or deleting anything.
    /// - Validates job/filename/tile/rect/byteCount/SHA-256 for every pending record before any
    ///   mutation. A pending manifest whose `.undo` is missing and has no restored marker is accepted
    ///   only when the live canvas rectangle hashes to the manifest's original-bytes SHA-256 (proof
    ///   that rollback already completed or the tile was never mutated); otherwise it is
    ///   `checkpointCorrupted`, never silent success.
    /// - Cleanup order: restore bytes → `flushRange` → atomic rename of the pending manifest to the
    ///   restored marker + directory `fsync` → remove undo bytes + `fsync` → remove marker + `fsync`.
    ///   An interruption at any step is resumable and idempotent.
    ///
    /// - Returns: the restored/recovered tile index, or `nil` when only committed journals were
    ///   discarded (or there was nothing to do).
    @discardableResult
    public func recover(
        jobID: UUID,
        lastCompletedTileIndex: Int,
        totalTiles: Int,
        expectedRects: [Int: TileJournalRect],
        into canvas: MMapBuffer,
        faultHandler: TileJournalFaultHandler? = nil
    ) throws -> Int? {
        // Phase 1 — inventory + structural validation. No mutation happens here.
        let inventory = try makeInventory(jobID: jobID)
        let (nextCandidate, nextOverflow) = lastCompletedTileIndex.addingReportingOverflow(1)
        guard !nextOverflow else {
            let fallback = (try? manifestFileURL(jobID: jobID, tileIndex: 0)) ?? workingDirectory
            throw ScalerError.checkpointCorrupted(fallback)
        }
        let nextTileIndex = nextCandidate

        var committedPending: [TileJournalRecord] = []
        var frontierPending: TileJournalRecord?
        var committedMarkers: [RestoredMarkerRecord] = []
        var frontierMarker: RestoredMarkerRecord?

        for record in inventory.pending {
            let tileIndex = record.manifest.tileIndex
            guard tileIndex >= 0, tileIndex < totalTiles,
                  let expectedRect = expectedRects[tileIndex],
                  record.manifest.rect == expectedRect else {
                throw ScalerError.checkpointCorrupted(record.manifestURL)
            }
            if tileIndex <= lastCompletedTileIndex {
                committedPending.append(record)
            } else {
                // The only possible in-flight tile after the frontier is the exact next tile.
                guard tileIndex == nextTileIndex else {
                    throw ScalerError.checkpointCorrupted(record.manifestURL)
                }
                guard frontierPending == nil else {
                    throw ScalerError.checkpointCorrupted(record.manifestURL)
                }
                frontierPending = record
            }
        }
        for marker in inventory.markers {
            let tileIndex = marker.manifest.tileIndex
            guard tileIndex >= 0, tileIndex < totalTiles,
                  let expectedRect = expectedRects[tileIndex],
                  marker.manifest.rect == expectedRect else {
                throw ScalerError.checkpointCorrupted(marker.markerURL)
            }
            if tileIndex <= lastCompletedTileIndex {
                committedMarkers.append(marker)
            } else {
                guard tileIndex == nextTileIndex else {
                    throw ScalerError.checkpointCorrupted(marker.markerURL)
                }
                guard frontierMarker == nil else {
                    throw ScalerError.checkpointCorrupted(marker.markerURL)
                }
                frontierMarker = marker
            }
        }

        // Phase 2 — validate every pending record's rollback bytes (or the live-canvas proof) before
        // the first mutation/deletion.
        var frontierNeedsRestore = false
        if let record = frontierPending {
            switch try validatePendingJournal(record, into: canvas) {
            case .restorable:
                frontierNeedsRestore = true
            case .alreadyRestoredOnCanvas:
                frontierNeedsRestore = false
            }
        }
        for record in committedPending {
            _ = try validatePendingJournal(record, into: canvas)
        }

        // Phase 3 — mutation. Committed journals are obsolete: retire the manifest/marker (the commit
        // record) and fsync before removing its backing undo bytes, so a crash in the middle leaves
        // only an orphan `.undo` that `scan` can remove safely.
        var changed = false
        for record in committedPending {
            try removeFileIfExists(record.manifestURL)
            changed = true
        }
        for marker in committedMarkers {
            try removeFileIfExists(marker.markerURL)
            changed = true
        }
        if changed {
            try fsyncDirectory()
        }

        changed = false
        for record in committedPending {
            try removeFileIfExists(record.undoURL)
            changed = true
        }
        for marker in committedMarkers {
            try removeFileIfExists(marker.undoURL)
            changed = true
        }
        for undoURL in inventory.orphanUndoURLs {
            try removeFileIfExists(undoURL)
            changed = true
        }
        for temporaryURL in inventory.temporaryURLs {
            try removeFileIfExists(temporaryURL)
            changed = true
        }
        if changed {
            try fsyncDirectory()
        }

        // Phase 4 — the single in-flight tile, if any.
        if let marker = frontierMarker {
            // The restored marker proves rollback completed. Clean up idempotently; never touch the
            // canvas because its restored pixels are already authoritative.
            try removeFileIfExists(marker.undoURL)
            try fsyncDirectory()
            try removeFileIfExists(marker.markerURL)
            try fsyncDirectory()
            return marker.manifest.tileIndex
        }
        if let record = frontierPending {
            if frontierNeedsRestore {
                try restore(
                    record,
                    into: canvas,
                    expectedJobID: jobID,
                    expectedTileIndex: record.manifest.tileIndex,
                    expectedRect: expectedRects[record.manifest.tileIndex],
                    faultHandler: faultHandler
                )
            } else {
                // The live canvas already holds the journaled original bytes; there is nothing to
                // write. Retire the manifest so the job can continue.
                try removeFileIfExists(record.manifestURL)
                try removeFileIfExists(record.undoURL)
                try fsyncDirectory()
            }
            return record.manifest.tileIndex
        }
        return nil
    }

    // MARK: - Restore

    /// Validates `record` against identity/rectangle/size/hash, streams the undo bytes back into the
    /// exact clipped rectangle, flushes that range, then runs the crash-safe retirement protocol:
    ///
    /// 1. atomically rename the pending manifest to the `.json.restored` marker and `fsync` the
    ///    directory (proof rollback completed);
    /// 2. remove the `.undo` bytes and `fsync`;
    /// 3. remove the restored marker and `fsync`.
    ///
    /// An interruption after step 1 is cleaned up by `scan`/`recover` without touching the canvas.
    public func restore(
        _ record: TileJournalRecord,
        into canvas: MMapBuffer,
        expectedJobID: UUID? = nil,
        expectedTileIndex: Int? = nil,
        expectedRect: TileJournalRect? = nil,
        faultHandler: TileJournalFaultHandler? = nil
    ) throws {
        let manifestURL = record.manifestURL
        let manifest = record.manifest
        let expectedManifestName = "journal_\(manifest.jobID.uuidString)_\(manifest.tileIndex).json"
        let expectedUndoName = "journal_\(manifest.jobID.uuidString)_\(manifest.tileIndex).undo"

        // Identity + structural validation happens before opening the undo file.
        guard Self.validateStructure(manifest),
              record.manifestURL.lastPathComponent == expectedManifestName,
              record.undoURL.lastPathComponent == expectedUndoName,
              (try? PathSafety.assertContained(record.manifestURL, in: workingDirectory)) != nil,
              (try? PathSafety.assertContained(record.undoURL, in: workingDirectory)) != nil,
              expectedJobID == nil || manifest.jobID == expectedJobID,
              expectedTileIndex == nil || manifest.tileIndex == expectedTileIndex,
              expectedRect == nil || manifest.rect == expectedRect else {
            throw ScalerError.checkpointCorrupted(manifestURL)
        }
        guard let byteCount = TileJournalRect.checkedByteCount(width: manifest.width, height: manifest.height),
              manifest.byteCount == byteCount else {
            throw ScalerError.checkpointCorrupted(manifestURL)
        }
        let rowBytes = manifest.width * TileJournalRect.bytesPerPixel
        guard manifest.x >= 0, manifest.y >= 0,
              manifest.width <= canvas.width, manifest.height <= canvas.height,
              manifest.x <= canvas.width - manifest.width,
              manifest.y <= canvas.height - manifest.height else {
            throw ScalerError.checkpointCorrupted(manifestURL)
        }

        let undoFD = Darwin.open(record.undoURL.path, O_RDONLY)
        guard undoFD >= 0 else {
            throw ScalerError.checkpointCorrupted(manifestURL)
        }
        var closed = false
        defer { if !closed { _ = Darwin.close(undoFD) } }

        var fileStat = Darwin.stat()
        guard Darwin.fstat(undoFD, &fileStat) == 0 else {
            throw ScalerError.checkpointCorrupted(manifestURL)
        }
        guard fileStat.st_size == off_t(byteCount) else {
            throw ScalerError.checkpointCorrupted(manifestURL)
        }

        // Pass 1 — hash the undo bytes without touching the output canvas.
        guard try Self.hash(undoFD: undoFD, byteCount: byteCount, corruptURL: manifestURL)
            == manifest.sha256.lowercased() else {
            throw ScalerError.checkpointCorrupted(manifestURL)
        }

        // Pass 2 — stream the validated bytes into the exact canvas rectangle.
        guard Darwin.lseek(undoFD, 0, SEEK_SET) == 0 else {
            throw ScalerError.checkpointCorrupted(manifestURL)
        }
        for row in 0..<manifest.height {
            let destinationRow = canvas
                .unsafeRowPointer(y: manifest.y + row)
                .advanced(by: manifest.x * TileJournalRect.bytesPerPixel)
            let readCount = try Self.readAll(
                undoFD,
                into: destinationRow,
                byteCount: rowBytes,
                corruptURL: manifestURL
            )
            guard readCount == rowBytes else {
                throw ScalerError.checkpointCorrupted(manifestURL)
            }
        }
        guard Darwin.close(undoFD) == 0 else {
            throw ScalerError.mmapSyncFailed(errno: errno)
        }
        closed = true

        try faultHandler?(.afterRollbackWriteBeforeFlush)

        // The rollback is only a rollback once the restored rows are durable.
        try canvas.flushRange(startY: manifest.y, rowCount: manifest.height)
        try faultHandler?(.afterRollbackFlush)

        // Retire the pending manifest into the durable restored marker. Only this rename proves the
        // rollback completed; the undo bytes must never be deleted while the pending manifest is the
        // only record.
        let markerURL = try restoredMarkerFileURL(jobID: manifest.jobID, tileIndex: manifest.tileIndex)
        guard (try? PathSafety.assertContained(markerURL, in: workingDirectory)) != nil else {
            throw ScalerError.checkpointCorrupted(manifestURL)
        }
        guard Darwin.rename(manifestURL.path, markerURL.path) == 0 else {
            if errno == ENOENT {
                throw ScalerError.checkpointCorrupted(manifestURL)
            }
            throw ScalerError.mmapSyncFailed(errno: errno)
        }
        try fsyncDirectory()
        try faultHandler?(.afterManifestRetirementBeforeUndoRemoval)

        // The marker is durable: the undo bytes are now provably obsolete.
        try removeFileIfExists(record.undoURL)
        try fsyncDirectory()
        try faultHandler?(.afterUndoRemovalBeforeMarkerRemoval)

        try removeFileIfExists(markerURL)
        try faultHandler?(.afterMarkerRemovalBeforeDirectorySync)
        try fsyncDirectory()
        try faultHandler?(.afterCleanupCompleted)
    }

    // MARK: - Discard

    /// Deletes journals whose tile is already durably committed; keeps uncommitted ones for `recover`.
    public func discard(committedTiles lastCompletedTileIndex: Int, jobID: UUID) throws {
        let inventory = try makeInventory(jobID: jobID)
        let committedPending = inventory.pending.filter { $0.manifest.tileIndex <= lastCompletedTileIndex }
        let committedMarkers = inventory.markers.filter { $0.manifest.tileIndex <= lastCompletedTileIndex }

        // Retire the commit record first so an interruption can never leave a pending manifest whose
        // undo bytes are already gone.
        var changed = false
        for record in committedPending {
            try removeFileIfExists(record.manifestURL)
            changed = true
        }
        for marker in committedMarkers {
            try removeFileIfExists(marker.markerURL)
            changed = true
        }
        if changed {
            try fsyncDirectory()
        }

        changed = false
        for record in committedPending {
            try removeFileIfExists(record.undoURL)
            changed = true
        }
        for marker in committedMarkers {
            try removeFileIfExists(marker.undoURL)
            changed = true
        }
        if changed {
            try fsyncDirectory()
        }
    }

    /// Deletes both sidecars (and any restored marker) for one tile after its checkpoint commit is
    /// durable, then fsyncs the containing directory so the cleanup is not lost on power failure.
    public func discard(tileIndex: Int, jobID: UUID) throws {
        let manifestURL = try manifestFileURL(jobID: jobID, tileIndex: tileIndex)
        let markerURL = try restoredMarkerFileURL(jobID: jobID, tileIndex: tileIndex)
        let undoURL = try undoFileURL(jobID: jobID, tileIndex: tileIndex)

        try removeFileIfExists(manifestURL)
        try removeFileIfExists(markerURL)
        try fsyncDirectory()
        try removeFileIfExists(undoURL)
        try fsyncDirectory()
    }

    /// Removes every journal artifact belonging to `jobID` only. Used for a fresh job (no checkpoint)
    /// whose output canvas has been recreated: no prior journal can be valid state.
    @discardableResult
    public func removeAllJournalFiles(jobID: UUID) throws -> Int {
        let prefix = "journal_\(jobID.uuidString)_"
        let entries = try FileManager.default.contentsOfDirectory(
            at: workingDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var removedCount = 0
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            let contained = try PathSafety.assertContained(entry, in: workingDirectory)
            guard FileManager.default.fileExists(atPath: contained.path) else { continue }
            try removeFileIfExists(contained)
            removedCount += 1
        }
        if removedCount > 0 {
            try fsyncDirectory()
        }
        return removedCount
    }

    // MARK: - Inventory

    private struct RestoredMarkerRecord: Sendable, Equatable {
        let manifest: TileJournalManifest
        let markerURL: URL
        let undoURL: URL
    }

    private struct JournalInventory {
        var pending: [TileJournalRecord] = []
        var markers: [RestoredMarkerRecord] = []
        var orphanUndoURLs: [URL] = []
        var temporaryURLs: [URL] = []
    }

    /// Non-mutating, fully validating inventory of one job's journal artifacts.
    private func makeInventory(jobID: UUID) throws -> JournalInventory {
        let prefix = "journal_\(jobID.uuidString)_"
        // An unreadable directory does not prove that no transaction is pending. Propagate the
        // enumeration error before recovery can treat a mutated canvas as a clean frontier.
        let entries = try FileManager.default.contentsOfDirectory(
            at: workingDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var inventory = JournalInventory()
        var undoURLsByTileIndex: [Int: URL] = [:]

        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix) else { continue }
            let contained = try PathSafety.assertContained(entry, in: workingDirectory)

            // Leftover temp artifacts from a publish interrupted before its atomic rename.
            if name.contains(".tmp-") {
                inventory.temporaryURLs.append(contained)
                continue
            }

            let suffix = String(name.dropFirst(prefix.count))
            if suffix.hasSuffix(".json.restored") {
                let tileIndexString = String(suffix.dropLast(".json.restored".count))
                guard let tileIndex = Int(tileIndexString), tileIndex >= 0 else {
                    throw ScalerError.checkpointCorrupted(contained)
                }
                let manifest = try decodeManifest(at: contained, corruptURL: contained)
                let expectedName = "journal_\(jobID.uuidString)_\(tileIndex).json.restored"
                guard Self.validateStructure(manifest),
                      manifest.jobID == jobID,
                      manifest.tileIndex == tileIndex,
                      contained.lastPathComponent == expectedName else {
                    throw ScalerError.checkpointCorrupted(contained)
                }
                inventory.markers.append(
                    RestoredMarkerRecord(
                        manifest: manifest,
                        markerURL: contained,
                        undoURL: try undoFileURL(jobID: jobID, tileIndex: tileIndex)
                    )
                )
            } else if suffix.hasSuffix(".json") {
                let tileIndexString = String(suffix.dropLast(".json".count))
                guard let tileIndex = Int(tileIndexString), tileIndex >= 0 else {
                    throw ScalerError.checkpointCorrupted(contained)
                }
                let manifest = try decodeManifest(at: contained, corruptURL: contained)
                let expectedName = "journal_\(jobID.uuidString)_\(tileIndex).json"
                guard Self.validateStructure(manifest),
                      manifest.jobID == jobID,
                      manifest.tileIndex == tileIndex,
                      contained.lastPathComponent == expectedName else {
                    throw ScalerError.checkpointCorrupted(contained)
                }
                inventory.pending.append(
                    TileJournalRecord(
                        manifest: manifest,
                        manifestURL: contained,
                        undoURL: try undoFileURL(jobID: jobID, tileIndex: tileIndex)
                    )
                )
            } else if suffix.hasSuffix(".undo") {
                let tileIndexString = String(suffix.dropLast(".undo".count))
                if let tileIndex = Int(tileIndexString), tileIndex >= 0 {
                    undoURLsByTileIndex[tileIndex] = contained
                }
            }
            // Unknown suffixes sharing the prefix are not journal files; leave them alone.
        }

        inventory.pending.sort { $0.manifest.tileIndex < $1.manifest.tileIndex }
        inventory.markers.sort { $0.manifest.tileIndex < $1.manifest.tileIndex }

        // A pending manifest and a restored marker for the same tile cannot coexist under the atomic
        // rename protocol; that combination is ambiguous state and must fail closed.
        let pendingIndices = Set(inventory.pending.map { $0.manifest.tileIndex })
        let markerIndices = Set(inventory.markers.map { $0.manifest.tileIndex })
        if let conflict = inventory.markers.first(where: { pendingIndices.contains($0.manifest.tileIndex) }) {
            throw ScalerError.checkpointCorrupted(conflict.markerURL)
        }
        for (tileIndex, undoURL) in undoURLsByTileIndex
        where !pendingIndices.contains(tileIndex) && !markerIndices.contains(tileIndex) {
            inventory.orphanUndoURLs.append(undoURL)
        }
        return inventory
    }

    // MARK: - Pending-journal validation

    private enum PendingJournalState {
        /// The `.undo` bytes are present, correctly sized and hash-valid; a rollback write is needed.
        case restorable
        /// The `.undo` bytes are missing (old-style interrupted cleanup) but the live canvas rectangle
        /// hashes to the manifest's original-bytes digest, proving no rollback write is needed.
        case alreadyRestoredOnCanvas
    }

    private func validatePendingJournal(
        _ record: TileJournalRecord,
        into canvas: MMapBuffer
    ) throws -> PendingJournalState {
        let manifest = record.manifest
        guard let byteCount = TileJournalRect.checkedByteCount(width: manifest.width, height: manifest.height),
              manifest.byteCount == byteCount,
              manifest.x >= 0, manifest.y >= 0,
              manifest.width <= canvas.width, manifest.height <= canvas.height,
              manifest.x <= canvas.width - manifest.width,
              manifest.y <= canvas.height - manifest.height else {
            throw ScalerError.checkpointCorrupted(record.manifestURL)
        }

        let undoFD = Darwin.open(record.undoURL.path, O_RDONLY)
        if undoFD < 0 {
            guard errno == ENOENT else {
                throw ScalerError.checkpointCorrupted(record.manifestURL)
            }
            // Interruption during the OLD cleanup ordering (delete undo, then manifest) leaves a
            // pending manifest with no undo bytes. Accept it only when the live canvas rectangle is
            // byte-identical to the journaled original bytes; otherwise it is corrupt state.
            guard try canvasRectMatches(manifest, byteCount: byteCount, into: canvas) else {
                throw ScalerError.checkpointCorrupted(record.manifestURL)
            }
            return .alreadyRestoredOnCanvas
        }
        var closed = false
        defer { if !closed { _ = Darwin.close(undoFD) } }

        var fileStat = Darwin.stat()
        guard Darwin.fstat(undoFD, &fileStat) == 0, fileStat.st_size == off_t(byteCount) else {
            throw ScalerError.checkpointCorrupted(record.manifestURL)
        }
        guard try Self.hash(undoFD: undoFD, byteCount: byteCount, corruptURL: record.manifestURL)
            == manifest.sha256.lowercased() else {
            throw ScalerError.checkpointCorrupted(record.manifestURL)
        }
        _ = Darwin.close(undoFD)
        closed = true
        return .restorable
    }

    private func canvasRectMatches(
        _ manifest: TileJournalManifest,
        byteCount: Int,
        into canvas: MMapBuffer
    ) throws -> Bool {
        guard manifest.x >= 0, manifest.y >= 0,
              manifest.width <= canvas.width, manifest.height <= canvas.height,
              manifest.x <= canvas.width - manifest.width,
              manifest.y <= canvas.height - manifest.height,
              manifest.byteCount == byteCount,
              byteCount > 0 else {
            return false
        }
        let rowBytes = manifest.width * TileJournalRect.bytesPerPixel
        var hasher = SHA256()
        for row in 0..<manifest.height {
            let start = canvas
                .unsafeRowPointer(y: manifest.y + row)
                .advanced(by: manifest.x * TileJournalRect.bytesPerPixel)
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: start, count: rowBytes))
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == manifest.sha256.lowercased()
    }

    // MARK: - Validation / IO helpers

    private func decodeManifest(at url: URL, corruptURL: URL) throws -> TileJournalManifest {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(TileJournalManifest.self, from: data)
        } catch {
            throw ScalerError.checkpointCorrupted(corruptURL)
        }
    }

    private static func validateStructure(_ manifest: TileJournalManifest) -> Bool {
        guard manifest.version == TileJournalManifest.currentVersion,
              manifest.tileIndex >= 0,
              manifest.width > 0, manifest.height > 0,
              manifest.x >= 0, manifest.y >= 0,
              let expectedByteCount = TileJournalRect.checkedByteCount(
                  width: manifest.width,
                  height: manifest.height
              ),
              manifest.byteCount == expectedByteCount,
              manifest.sha256.count == 64,
              manifest.sha256.allSatisfy({ $0.isHexDigit }) else {
            return false
        }
        return true
    }

    private func removeFileIfExists(_ url: URL) throws {
        if Darwin.unlink(url.path) != 0 {
            let code = errno
            guard code == ENOENT else {
                throw ScalerError.mmapSyncFailed(errno: code)
            }
        }
    }

    private func fsyncDirectory() throws {
        let directoryFD = Darwin.open(workingDirectory.path, O_RDONLY)
        guard directoryFD >= 0 else {
            throw ScalerError.mmapSyncFailed(errno: errno)
        }
        defer { _ = Darwin.close(directoryFD) }
        guard Darwin.fsync(directoryFD) == 0 else {
            throw ScalerError.mmapSyncFailed(errno: errno)
        }
    }

    private static func hash(undoFD: Int32, byteCount: Int, corruptURL: URL) throws -> String {
        var hasher = SHA256()
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        var remaining = byteCount
        while remaining > 0 {
            let chunk = min(remaining, scratch.count)
            let readCount = try readAll(
                undoFD,
                into: &scratch,
                byteCount: chunk,
                corruptURL: corruptURL
            )
            guard readCount == chunk else {
                throw ScalerError.checkpointCorrupted(corruptURL)
            }
            scratch.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: base, count: chunk))
            }
            remaining -= chunk
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func writeAll(_ fd: Int32, from pointer: UnsafeRawPointer?, byteCount: Int) throws {
        guard byteCount > 0 else { return }
        guard let pointer else {
            throw ScalerError.mmapSyncFailed(errno: EIO)
        }
        var written = 0
        while written < byteCount {
            let result = Darwin.write(fd, pointer.advanced(by: written), byteCount - written)
            if result < 0 {
                if errno == EINTR { continue }
                throw ScalerError.mmapSyncFailed(errno: errno)
            }
            guard result > 0 else {
                throw ScalerError.mmapSyncFailed(errno: EIO)
            }
            written += result
        }
    }

    private static func readAll(
        _ fd: Int32,
        into buffer: UnsafeMutableRawPointer,
        byteCount: Int,
        corruptURL: URL
    ) throws -> Int {
        var total = 0
        while total < byteCount {
            let result = Darwin.read(fd, buffer.advanced(by: total), byteCount - total)
            if result < 0 {
                if errno == EINTR { continue }
                throw ScalerError.checkpointCorrupted(corruptURL)
            }
            guard result > 0 else { break }
            total += result
        }
        return total
    }

    private static func readAll(
        _ fd: Int32,
        into scratch: inout [UInt8],
        byteCount: Int,
        corruptURL: URL
    ) throws -> Int {
        try scratch.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return 0 }
            return try Self.readAll(
                fd,
                into: base,
                byteCount: min(byteCount, rawBuffer.count),
                corruptURL: corruptURL
            )
        }
    }
}
