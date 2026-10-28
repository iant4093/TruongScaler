import Foundation
import Darwin
import MMapCanvas
import TruongScalerCore

/// Deterministic, one-shot durability boundaries used by `@testable` persistence tests. These are
/// test-only seams: nothing here is consulted unless a test explicitly injects a fault.
enum CheckpointDurabilityFaultPoint: Sendable, Equatable {
    /// The checkpoint temp file is written/fsynced/closed but has not replaced the destination yet.
    /// A thrown error proves the previous checkpoint is still authoritative.
    case beforePublication
    /// The new checkpoint JSON is already renamed over the destination, but the containing directory
    /// has not been fsynced yet. A thrown error is the ambiguous-publication case: the visible
    /// checkpoint may name files that a caller cannot prove durable.
    case afterPublicationBeforeDirectorySync
    /// `confirmDurability()` fails before fsyncing the working directory.
    case beforeDurabilityConfirmation
}

/// Atomically + durably persists `JobCheckpointState` to `workingDirectory / "checkpoint_<jobID>.json"`.
/// Specification: `docs/DEVELOPMENT.md` Section 2.
public actor JobCheckpointStore {
    public let workingDirectory: URL
    /// Test-only one-shot durability fault. Internal so production code can never inject it.
    private var pendingDurabilityFault: (point: CheckpointDurabilityFaultPoint, error: ScalerError)?

    public init(workingDirectory: URL) throws {
        self.workingDirectory = workingDirectory
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    /// Non-throwing convenience initializer used by `@MainActor` `StudioViewModel`.
    public init(directory: URL) {
        self.workingDirectory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func checkpointFileURL(for jobID: UUID) -> URL {
        workingDirectory.appendingPathComponent("checkpoint_\(jobID.uuidString).json")
    }

    /// Writes a temporary JSON file in the same directory, `fsync`s it, atomically renames it over the
    /// destination, then `fsync`s the containing directory. A successful return therefore means the
    /// checkpoint is durable on disk, not merely present in the page cache.
    public func save(_ state: JobCheckpointState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try durableWrite(
            data,
            to: checkpointFileURL(for: state.jobID),
            workingDirectory: workingDirectory
        )
    }

    /// Confirms that a previously returned checkpoint is durable by `fsync`ing the containing
    /// directory. Callers that observed a newly published checkpoint (for example after recovering an
    /// ambiguous migration save) must confirm durability here before retiring an older canvas that the
    /// checkpoint may still fall back to.
    public func confirmDurability() throws {
        try throwInjectedFault(at: .beforeDurabilityConfirmation)
        try Self.fsyncDirectory(workingDirectory)
    }

    /// Installs a one-shot deterministic fault at `point`. The next matching boundary throws once and
    /// clears the injection; unrelated fsync calls and subsequent saves are unaffected.
    func injectDurabilityFaultForTesting(
        _ point: CheckpointDurabilityFaultPoint,
        error: ScalerError = .mmapSyncFailed(errno: EIO)
    ) {
        pendingDurabilityFault = (point, error)
    }

    func clearDurabilityFaultForTesting() {
        pendingDurabilityFault = nil
    }

    private func throwInjectedFault(at point: CheckpointDurabilityFaultPoint) throws {
        guard let pending = pendingDurabilityFault, pending.point == point else { return }
        pendingDurabilityFault = nil
        throw pending.error
    }

    public func load(jobID: UUID) throws -> JobCheckpointState {
        let url = checkpointFileURL(for: jobID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ScalerError.fileNotFound(url)
        }
        do {
            let data = try Data(contentsOf: url)
            let state = try JSONDecoder().decode(JobCheckpointState.self, from: data)
            guard state.jobID == jobID, state.config.id == jobID else {
                throw ScalerError.checkpointCorrupted(url)
            }
            return state
        } catch {
            throw ScalerError.checkpointCorrupted(url)
        }
    }

    /// Enumerates every `checkpoint_*.json` in `workingDirectory`, tolerantly skips corrupted or
    /// out-of-container files, keeps only jobs whose final tile has not completed yet
    /// (`lastCompletedTileIndex + 1 < totalTiles`), and returns them sorted by `updatedAt` descending
    /// (ties broken by job ID) so resumption UIs present the most recent paused job first.
    public func listIncompleteCheckpoints() -> [JobCheckpointState] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: workingDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var incomplete: [JobCheckpointState] = []
        for entry in entries {
            guard entry.lastPathComponent.hasPrefix("checkpoint_"),
                  entry.pathExtension.lowercased() == "json" else {
                continue
            }
            let contained: URL
            do {
                contained = try PathSafety.assertContained(entry, in: workingDirectory)
            } catch {
                continue
            }
            guard let data = try? Data(contentsOf: contained),
                  let state = try? JSONDecoder().decode(JobCheckpointState.self, from: data) else {
                continue
            }
            guard entry.lastPathComponent == "checkpoint_\(state.jobID.uuidString).json",
                  state.config.id == state.jobID,
                  state.totalTiles > 0,
                  state.lastCompletedTileIndex >= -1,
                  state.lastCompletedTileIndex < state.totalTiles - 1 else { continue }
            incomplete.append(state)
        }

        incomplete.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.jobID.uuidString < rhs.jobID.uuidString
        }
        return incomplete
    }

    /// Removes only the checkpoint JSON for `jobID` without touching the stage mmap files.
    /// Returns `true` when a checkpoint file was removed.
    @discardableResult
    public func remove(jobID: UUID) -> Bool {
        do {
            try FileManager.default.removeItem(at: checkpointFileURL(for: jobID))
            return true
        } catch {
            return false
        }
    }

    /// Removes only `jobID`'s durable tile-journal sidecars (never another job's files).
    /// Returns the number of files removed.
    @discardableResult
    public func removeJournalSidecars(for jobID: UUID) -> Int {
        let journal = TileUndoJournal(workingDirectory: workingDirectory)
        return (try? journal.removeAllJournalFiles(jobID: jobID)) ?? 0
    }

    /// Removes the checkpoint plus all stage-1/2 sidecar files referenced by `state`.
    /// Every derived path is containment-checked through `PathSafety` before deletion, so a corrupted
    /// checkpoint containing `../` segments can never delete files outside `workingDirectory`.
    public func deleteJobFiles(state: JobCheckpointState) {
        let relativePaths = [
            state.sourceMMapFileName,
            state.outputMMapFileName,
            state.metadataPacketFileName
        ]
        for relativePath in relativePaths {
            guard let fileURL = try? PathSafety.childURL(in: workingDirectory, relativePath: relativePath) else {
                continue
            }
            try? FileManager.default.removeItem(at: fileURL)
        }
        _ = removeJournalSidecars(for: state.jobID)
        try? FileManager.default.removeItem(at: checkpointFileURL(for: state.jobID))
    }

    // MARK: - Durable file replacement

    private func durableWrite(
        _ data: Data,
        to destination: URL,
        workingDirectory: URL
    ) throws {
        let tempURL = destination.deletingLastPathComponent().appendingPathComponent(
            "\(destination.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let fd = Darwin.open(tempURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            throw ScalerError.mmapSyncFailed(errno: errno)
        }
        var closed = false
        defer { if !closed { _ = Darwin.close(fd) } }

        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(fd, base.advanced(by: written), rawBuffer.count - written)
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
        guard Darwin.fsync(fd) == 0 else {
            throw ScalerError.mmapSyncFailed(errno: errno)
        }
        guard Darwin.close(fd) == 0 else {
            closed = true
            throw ScalerError.mmapSyncFailed(errno: errno)
        }
        closed = true

        // Test-only: fail while the previous checkpoint is still the only published state.
        try throwInjectedFault(at: .beforePublication)

        guard Darwin.rename(tempURL.path, destination.path) == 0 else {
            throw ScalerError.mmapSyncFailed(errno: errno)
        }
        // Test-only: the new checkpoint is visible but its directory entry is not yet confirmed durable.
        try throwInjectedFault(at: .afterPublicationBeforeDirectorySync)
        try Self.fsyncDirectory(workingDirectory)
    }

    private nonisolated static func fsyncDirectory(_ directory: URL) throws {
        let directoryFD = Darwin.open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else {
            throw ScalerError.mmapSyncFailed(errno: errno)
        }
        defer { _ = Darwin.close(directoryFD) }
        guard Darwin.fsync(directoryFD) == 0 else {
            throw ScalerError.mmapSyncFailed(errno: errno)
        }
    }
}
