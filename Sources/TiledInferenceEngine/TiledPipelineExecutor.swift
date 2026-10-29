import Foundation
import CoreML
import Darwin
import TruongScalerCore
import MMapCanvas
import CoreIngestion
import MetalColorEngine

/// Human/machine-readable stage inside one pipeline job. Deliberately independent of the legacy
/// `JobStage` case names: the app is super-resolution only even though the checkpoint domain still
/// spells the tile stage `denoisingAndUpscalingTiles` for compatibility with accepted artifacts.
public enum PipelinePhase: String, Sendable, Equatable {
    case decodingSource
    case preparingModels
    case extractingTile
    case predictingSuperResolution
    case verifyingSuperResolution
    case reconstructingTile
    case blendingTile
    case committingTile
    case tileCommitted
    case finalizing
    case paused
    case completed
    case failed
}

/// Measured parts of one tile. Seconds are wall-clock samples from `ContinuousClock`; they are
/// measurements, not simulator/phone speed claims, and are never used to change processing.
public struct PipelineTileTimings: Sendable, Equatable, Codable {
    public var extractionSeconds: Double?
    public var modelLoadSeconds: Double?
    public var modelSeconds: Double?
    public var stabilitySeconds: Double?
    public var reconstructionSeconds: Double?
    public var journalSeconds: Double?
    public var blendSeconds: Double?
    public var flushSeconds: Double?
    public var checkpointSeconds: Double?
    public var cleanupSeconds: Double?

    public init(
        extractionSeconds: Double? = nil,
        modelLoadSeconds: Double? = nil,
        modelSeconds: Double? = nil,
        stabilitySeconds: Double? = nil,
        reconstructionSeconds: Double? = nil,
        journalSeconds: Double? = nil,
        blendSeconds: Double? = nil,
        flushSeconds: Double? = nil,
        checkpointSeconds: Double? = nil,
        cleanupSeconds: Double? = nil
    ) {
        self.extractionSeconds = extractionSeconds
        self.modelLoadSeconds = modelLoadSeconds
        self.modelSeconds = modelSeconds
        self.stabilitySeconds = stabilitySeconds
        self.reconstructionSeconds = reconstructionSeconds
        self.journalSeconds = journalSeconds
        self.blendSeconds = blendSeconds
        self.flushSeconds = flushSeconds
        self.checkpointSeconds = checkpointSeconds
        self.cleanupSeconds = cleanupSeconds
    }
}

/// Progress event emitted after each strip decode, phase transition or tile completion.
public struct PipelineProgressUpdate: Sendable {
    public let jobID: UUID
    public let stage: JobStage
    public let completedTiles: Int
    public let totalTiles: Int
    public let overallFraction: Double
    public let estimatedSecondsRemaining: Int?
    public let currentTileDescriptor: TileDescriptor?
    public let phase: PipelinePhase
    /// Zero-based plan tile index currently being worked on, or `nil` outside the tile loop.
    public let currentTileIndex: Int?
    public let elapsedSeconds: Double?
    /// Monotonic elapsed time inside the tile loop only (excludes decode/canvas preparation).
    public let tileLoopElapsedSeconds: Double?
    public let averageSecondsPerTile: Double?
    public let sourceWidth: Int?
    public let sourceHeight: Int?
    public let outputWidth: Int?
    public let outputHeight: Int?
    public let modelName: String?
    public let tileSize: Int?
    public let tileOverlap: Int?
    public let gridColumns: Int?
    public let gridRows: Int?
    /// Requested CoreML compute configuration, not proof of where operators actually ran.
    public let requestedCompute: String?
    public let didRunDenoise: Bool?
    public let timings: PipelineTileTimings?

    public init(
        jobID: UUID,
        stage: JobStage,
        completedTiles: Int,
        totalTiles: Int,
        overallFraction: Double,
        estimatedSecondsRemaining: Int?,
        currentTileDescriptor: TileDescriptor? = nil,
        phase: PipelinePhase = .decodingSource,
        currentTileIndex: Int? = nil,
        elapsedSeconds: Double? = nil,
        tileLoopElapsedSeconds: Double? = nil,
        averageSecondsPerTile: Double? = nil,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        modelName: String? = nil,
        tileSize: Int? = nil,
        tileOverlap: Int? = nil,
        gridColumns: Int? = nil,
        gridRows: Int? = nil,
        requestedCompute: String? = nil,
        didRunDenoise: Bool? = nil,
        timings: PipelineTileTimings? = nil
    ) {
        self.jobID = jobID
        self.stage = stage
        self.completedTiles = completedTiles
        self.totalTiles = totalTiles
        self.overallFraction = overallFraction
        self.estimatedSecondsRemaining = estimatedSecondsRemaining
        self.currentTileDescriptor = currentTileDescriptor
        self.phase = phase
        self.currentTileIndex = currentTileIndex
        self.elapsedSeconds = elapsedSeconds
        self.tileLoopElapsedSeconds = tileLoopElapsedSeconds
        self.averageSecondsPerTile = averageSecondsPerTile
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.modelName = modelName
        self.tileSize = tileSize
        self.tileOverlap = tileOverlap
        self.gridColumns = gridColumns
        self.gridRows = gridRows
        self.requestedCompute = requestedCompute
        self.didRunDenoise = didRunDenoise
        self.timings = timings
    }
}

/// Artifacts produced upon completing all tiles in Stage 3 (`docs/DEVELOPMENT.md` Section 4.1).
public struct CompletedPipelineArtifacts: Sendable {
    public let checkpoint: JobCheckpointState
    public let metadata: ImageMetadataPacket
    public let sourceBuffer: MMapBuffer
    public let outputBuffer: MMapBuffer

    public init(
        checkpoint: JobCheckpointState,
        metadata: ImageMetadataPacket,
        sourceBuffer: MMapBuffer,
        outputBuffer: MMapBuffer
    ) {
        self.checkpoint = checkpoint
        self.metadata = metadata
        self.sourceBuffer = sourceBuffer
        self.outputBuffer = outputBuffer
    }
}

/// Test-only deterministic interruption points inside the durable per-tile transaction.
/// Throwing at one proves the persistent state at that point; it is NOT a real process-kill test.
public enum TransactionInterruptionPoint: Sendable, Equatable {
    /// Undo journal (manifest + bytes) is durable; the canvas has not been mutated yet.
    case afterJournalPublished
    /// The tile was blended into the shared canvas; the affected range has not been flushed yet.
    case afterCanvasMutation
    /// The affected canvas rows are `msync`ed; the checkpoint has not been committed yet.
    case afterCanvasFlushBeforeCheckpoint
    /// The advanced checkpoint is durable; the now-obsolete journal has not been deleted yet.
    case afterCheckpointBeforeJournalCleanup
}

/// Identity of one coordinator job run. `generation` is the coordinator's globally increasing
/// `jobGeneration`; pause side effects captured for an older run must never reach a newer run.
public struct ExecutionPauseOwner: Sendable, Hashable {
    public let jobID: UUID
    public let generation: UInt64

    public init(jobID: UUID, generation: UInt64) {
        self.jobID = jobID
        self.generation = generation
    }
}

/// Immutable, Sendable progress context for one execution. Keeping geometry/model facts here lets
/// phase callbacks from inside `processTile` publish progress without capturing mutable actor state.
final class RequestedComputePolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    private var rawUnits: MLComputeUnits?
    private var revision: UInt64 = 0

    init(_ value: String) {
        self.value = value
    }

    /// Resolve a shared mode request against this event's immutable model identity. A changed
    /// next-job picker or another model's restriction may never relabel an in-flight event.
    func description(for modelID: CoreMLModelIdentifier, registry: CoreMLModelRegistry) -> String {
        lock.lock()
        let request = rawUnits
        let fallback = value
        lock.unlock()
        guard let request else { return fallback }
        return CoreMLModelRegistry.describeComputeUnits(registry.effectiveComputeUnits(for: request, modelID: modelID))
    }

    var currentRevision: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return revision
    }

    /// Records a newer explicit execution-tier/background request. Returns its revision so an
    /// older suspended entry-policy read can detect that it no longer owns publication.
    @discardableResult
    func setFromRequest(_ newValue: String, rawUnits: MLComputeUnits) -> UInt64 {
        lock.lock()
        revision &+= 1
        value = newValue
        self.rawUnits = rawUnits
        let result = revision
        lock.unlock()
        return result
    }

    /// Publishes a value only when no newer request has occurred since `expectedRevision`.
    func publishIfRevisionUnchanged(_ newValue: String, rawUnits: MLComputeUnits, expectedRevision: UInt64) {
        lock.lock()
        if revision == expectedRevision {
            value = newValue
            self.rawUnits = rawUnits
        }
        lock.unlock()
    }
}

private struct JobProgressEmitter: Sendable {
    let jobID: UUID
    let handler: (@Sendable (PipelineProgressUpdate) -> Void)?
    let sourceWidth: Int
    let sourceHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let modelName: String
    let modelID: CoreMLModelIdentifier
    let modelRegistry: CoreMLModelRegistry
    let tileSize: Int
    let tileOverlap: Int
    let gridColumns: Int
    let gridRows: Int
    let policy: RequestedComputePolicy
    let didRunDenoise: Bool
    let startNanos: UInt64
    let tileLoopStartNanos: UInt64

    func elapsedSeconds() -> Double {
        Self.seconds(since: startNanos)
    }

    func tileLoopElapsedSeconds() -> Double {
        Self.seconds(since: tileLoopStartNanos)
    }

    private static func seconds(since startNanos: UInt64) -> Double {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startNanos
        let seconds = Double(elapsed) / 1_000_000_000.0
        return seconds.isFinite ? max(0, seconds) : 0
    }

    func emit(
        phase: PipelinePhase,
        stage: JobStage,
        completed: Int,
        total: Int,
        tile: TileDescriptor?,
        timings: PipelineTileTimings?,
        averageSecondsPerTile: Double?,
        estimatedSecondsRemaining: Int?
    ) {
        let fraction: Double
        if total > 0 {
            let clamped = Double(max(0, min(completed, total))) / Double(total)
            fraction = 0.10 + 0.90 * clamped
        } else {
            fraction = 0.0
        }
        handler?(
            PipelineProgressUpdate(
                jobID: jobID,
                stage: stage,
                completedTiles: completed,
                totalTiles: total,
                overallFraction: fraction,
                estimatedSecondsRemaining: estimatedSecondsRemaining,
                currentTileDescriptor: tile,
                phase: phase,
                currentTileIndex: tile?.tileIndex,
                elapsedSeconds: elapsedSeconds(),
                tileLoopElapsedSeconds: tileLoopElapsedSeconds(),
                averageSecondsPerTile: averageSecondsPerTile,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                modelName: modelName,
                tileSize: tileSize,
                tileOverlap: tileOverlap,
                gridColumns: gridColumns,
                gridRows: gridRows,
                requestedCompute: policy.description(for: modelID, registry: modelRegistry),
                didRunDenoise: didRunDenoise,
                timings: timings
            )
        )
    }
}

/// Coordinates Stage 1 -> Stage 2 -> Stage 3 resumable tiled execution.
/// Specification: `docs/DEVELOPMENT.md` Section 4.
public actor TiledPipelineExecutor {
    /// A pause waiter. `owner == nil` represents the unscoped Stop/test pause; a scoped waiter is
    /// resumed only with the answer for the run that requested it (and is answered `false` as soon as
    /// a newer run is registered).
    private struct StableBoundaryWaiter {
        let owner: ExecutionPauseOwner?
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let workingDirectory: URL
    private let modelRegistry: CoreMLModelRegistry
    private let checkpointStore: JobCheckpointStore
    private let colorProcessor: MetalColorProcessor
    private var isBackgroundMode: Bool = false
    private var pauseRequested: Bool = false
    /// The run that issued the currently queued pause. `nil` means an unscoped Stop/test request.
    private var pauseRequestedByOwner: ExecutionPauseOwner?
    /// The run most recently registered by the coordinator. Scoped pauses are only accepted for it.
    private var currentRunOwner: ExecutionPauseOwner?
    /// Deterministic test hook: pause right after the tile with this index completes.
    private var pauseAfterCompletedTileIndex: Int?
    /// Number of `executeOrResumeJob` calls currently running. Used by `requestGracefulPauseAndWait`
    /// so it never waits forever when the executor is idle and no tile loop exists to observe a pause.
    private var activeExecutionCount: Int = 0
    /// Owner of each currently running execution (`nil` for an execution whose owner is unknown).
    /// Boundary signaling is scoped to the execution that actually reached it, so a queued pause for a
    /// not-yet-started replacement run is never resolved by the outgoing run's boundary.
    private var activeExecutionOwnerCounts: [ExecutionPauseOwner?: Int] = [:]
    /// Continuations resumed when the active tile loop reaches a stable paused/completed/failed boundary.
    private var stableBoundaryWaiters: [StableBoundaryWaiter] = []
    /// Test-only transaction interruption injection.
    private var transactionInterruptionHook: (@Sendable (TransactionInterruptionPoint) throws -> Void)?
    /// Test-only one-shot cleanup interruption: simulates a failure while retiring the pre-migration
    /// canvas after the migration checkpoint is already committed.
    private var migrationCleanupInterruptionHook: (@Sendable () throws -> Void)?
    /// Durable per-tile undo transaction (`journal_<jobID>_<tileIndex>.{undo,json}`).
    private let undoJournal: TileUndoJournal
    /// Requested CoreML policy at the time each progress event is emitted. This is a request, never
    /// proof of operator placement.
    private let requestedComputePolicy = RequestedComputePolicy("unknown")
    private var pendingComputePolicy: Task<Void, Never>?

    /// Stage 1 strip decoding performs blocking ImageIO/CoreImage work; keep it off the cooperative pool.
    private static let stage1IOOwner = BlockingIOOwner(
        label: "com.truongscaler.tiled-inference.stage1",
        qos: .userInitiated
    )

    public init(
        workingDirectory: URL,
        modelRegistry: CoreMLModelRegistry,
        checkpointStore: JobCheckpointStore,
        colorProcessor: MetalColorProcessor = MetalColorProcessor()
    ) {
        self.workingDirectory = workingDirectory
        self.modelRegistry = modelRegistry
        self.checkpointStore = checkpointStore
        self.colorProcessor = colorProcessor
        self.undoJournal = TileUndoJournal(workingDirectory: workingDirectory)
    }

    // MARK: - Execution tier / pause control

    /// Called by `BackgroundExecutionCoordinator` when the app enters/exits the background.
    /// Entering background switches CoreML to `.cpuAndNeuralEngine`; returning to the foreground
    /// requests the foreground tier (resolved to CPU+NE in production) and clears stale pauses.
    public func setBackgroundExecutionMode(_ inBackground: Bool) async {
        let transition = beginBackgroundExecutionMode(inBackground)
        await transition.value
    }

    /// Publish the safe color/next-prediction policy immediately. The returned task drains the
    /// registry change separately: its actor may still be inside a long synchronous Core ML call.
    /// Background scheduling/assertion acquisition must not wait for that call to finish.
    public func beginBackgroundExecutionMode(_ inBackground: Bool) -> Task<Void, Never> {
        if !inBackground {
            clearPauseRequest()
        }
        isBackgroundMode = inBackground
        let tier = ModelExecutionTier.forBackgroundMode(inBackground)
        return enqueueComputePolicy(tier.computeUnits)
    }

    /// Explicit execution-tier switch. Kept additive on top of `setBackgroundExecutionMode` so callers
    /// (background coordinator, tests, future CLI) can select `.cpuOnly` without changing the scaffolded API.
    public func switchExecutionTier(_ tier: ModelExecutionTier) async {
        switch tier {
        case .gpuAndANE:
            isBackgroundMode = false
        case .cpuAndANE, .cpuOnly:
            isBackgroundMode = true
        }
        await enqueueComputePolicy(tier.computeUnits).value
    }

    private func enqueueComputePolicy(_ requestedUnits: MLComputeUnits) -> Task<Void, Never> {
        let units = modelRegistry.effectiveComputeUnits(for: requestedUnits)
        requestedComputePolicy.setFromRequest(Self.requestedComputeDescription(units), rawUnits: requestedUnits)
        let previous = pendingComputePolicy
        let registry = modelRegistry
        let transition = Task {
            await previous?.value
            await registry.setComputeUnits(requestedUnits)
        }
        pendingComputePolicy = transition
        return transition
    }

    /// Re-check after suspension: a newer foreground/background request may have arrived while
    /// the previous registry change was draining. Never start another prediction on that old policy.
    private func waitForRequestedComputePolicy() async {
        while true {
            let revision = requestedComputePolicy.currentRevision
            await pendingComputePolicy?.value
            if revision == requestedComputePolicy.currentRevision { return }
        }
    }

    /// Requests a clean pause at the completion of the current tile (flushing `msync` & saving checkpoint).
    ///
    /// While an execution is active the request binds to that execution's owner so only the run it
    /// targets observes the pause. When idle it binds to the current registered run (a legitimate
    /// Stop/reset issued between registration and executor entry). Only when neither exists is this the
    /// explicit unscoped Stop/test marker, which the next direct unregistered execution may consume;
    /// `registerJobRun` discards it for a distinct new run. Background expiration must still use
    /// `requestGracefulPauseAndWait(ifOwner:)` so a stale continuation cannot pause a replacement run.
    public func requestGracefulPause() {
        bindPauseRequest(to: unscopedPauseBindingOwner())
    }

    /// Registers the coordinator run that owns the executor from this point on.
    ///
    /// Generations are globally increasing, so an older registration (for example a delayed start
    /// continuation) can never overwrite a newer run. Re-registering the exact same owner is idempotent
    /// and preserves a legitimate pause for that run. A conflicting equal-generation registration for a
    /// different identity is a documented no-op, so two owners can never silently trade identities.
    ///
    /// Registering a *newer distinct* owner retires pause state belonging to the outgoing run and
    /// answers its waiter `false` (D2). A first/new registration also discards an idle unscoped marker
    /// that has no ownership over a run registered afterwards. A pause issued for the *current*
    /// registered run after registration is scoped to that owner and is therefore preserved.
    public func registerJobRun(_ owner: ExecutionPauseOwner) async {
        guard let current = currentRunOwner else {
            // Nothing is registered yet. Any queued unscoped pause was an idle/direct marker that
            // targets no registered run, so the first registration retires it atomically.
            retireQueuedPauseForNewRegistration()
            currentRunOwner = owner
            return
        }
        if owner.generation < current.generation {
            return
        }
        if owner == current {
            // Same-owner re-registration is idempotent and keeps the owner's legitimate pause.
            return
        }
        if owner.generation == current.generation {
            // Conflicting equal-generation identity: do not silently replace the current owner.
            return
        }
        // A newer distinct run owns pause semantics from here on; the outgoing run's queued pause is
        // stale and must never be answered by the replacement's boundary.
        retireQueuedPauseForNewRegistration()
        currentRunOwner = owner
    }

    /// Requests a pause scoped to `owner`, and returns only after the tile loop has flushed the canvas,
    /// committed the checkpoint, and reached a stable paused/completed/failed boundary.
    ///
    /// If `owner` is not the registered run the request is refused immediately with `false` and no side
    /// effect. If a newer run registers while this call is waiting, registration discards the queued
    /// pause and this call returns `false`, so the stale caller cannot influence the replacement run.
    /// Safe to call when idle: the pause is armed for the registered run and `true` is returned.
    public func requestGracefulPauseAndWait(ifOwner owner: ExecutionPauseOwner) async -> Bool {
        guard currentRunOwner == owner else { return false }
        bindPauseRequest(to: owner)
        guard activeExecutionCount > 0 else { return true }
        let paused = await withCheckedContinuation { continuation in
            stableBoundaryWaiters.append(StableBoundaryWaiter(owner: owner, continuation: continuation))
        }
        // A newer run may have discarded the pause while we were suspended.
        return paused && currentRunOwner == owner
    }

    /// Requests a pause and returns only after the targeted tile loop has flushed the canvas, committed
    /// the checkpoint, and reached a stable paused/completed/failed boundary.
    ///
    /// While a run is active the request binds to that run, so it waits for the run's *own* boundary.
    /// When idle it binds to the current registered run (a legitimate Stop/reset before executor entry)
    /// and returns immediately because there is no tile loop to observe yet. With neither an active
    /// execution nor a registered run this is deliberately a no-op: it must not leave an unscoped pause
    /// that would stop the next distinct run (`StudioViewModel.resetSession` calls it unconditionally).
    public func requestGracefulPauseAndWait() async {
        if activeExecutionCount == 0 {
            guard let owner = currentRunOwner else { return }
            bindPauseRequest(to: owner)
            return
        }
        guard let owner = unscopedPauseBindingOwner() else {
            // More than one active execution owner (or an anonymous execution): keep the explicit
            // unscoped Stop and let the first active run to reach a stable boundary answer it.
            bindPauseRequest(to: nil)
            _ = await withCheckedContinuation { continuation in
                stableBoundaryWaiters.append(StableBoundaryWaiter(owner: nil, continuation: continuation))
            }
            return
        }
        bindPauseRequest(to: owner)
        _ = await withCheckedContinuation { continuation in
            stableBoundaryWaiters.append(StableBoundaryWaiter(owner: owner, continuation: continuation))
        }
    }

    /// Requested policy accessor for diagnostics tests. Not operator-placement evidence.
    func currentRequestedComputeDescriptionForTesting(modelID: CoreMLModelIdentifier = .quickSRx2_256) -> String {
        requestedComputePolicy.description(for: modelID, registry: modelRegistry)
    }

    /// Clears a stale pause so a resumed `executeOrResumeJob` can continue.
    public func clearPauseRequest() {
        pauseRequested = false
        pauseRequestedByOwner = nil
        pauseAfterCompletedTileIndex = nil
    }

    /// Test-only one-shot cleanup interruption, consumed by the next successful legacy migration.
    /// The committed checkpoint/canonical canvas must survive this failure; the old canvas is retained
    /// for the next resume to retire after durability confirmation.
    func setMigrationCleanupInterruptionHookForTesting(
        _ hook: (@Sendable () throws -> Void)?
    ) {
        self.migrationCleanupInterruptionHook = hook
    }

    /// Internal deterministic hook used by `TiledInferenceEngineTests` to pause mid-run. Kept internal
    /// (not public API) so production callers can only use `requestGracefulPause()`.
    func requestPauseAfterTileForTesting(_ tileIndex: Int) {
        self.pauseAfterCompletedTileIndex = tileIndex
    }

    /// Test-only injection at the frozen `TransactionInterruptionPoint` boundaries.
    func setTransactionInterruptionHookForTesting(
        _ hook: (@Sendable (TransactionInterruptionPoint) throws -> Void)?
    ) {
        self.transactionInterruptionHook = hook
    }

    // MARK: - Job execution

    /// Starts a new job or resumes from an existing `JobCheckpointState`.
    public func executeOrResumeJob(
        config: UpscaleJobConfig,
        existingCheckpoint: JobCheckpointState? = nil,
        overrideTier: DeviceTier? = nil,
        progressHandler: (@Sendable (PipelineProgressUpdate) -> Void)? = nil
    ) async throws -> CompletedPipelineArtifacts {
        let jobID = existingCheckpoint?.jobID ?? config.id
        let effectiveConfig = existingCheckpoint?.config ?? config
        // A retired checkpoint may be inspected, but must never mix model families on resume.
        guard effectiveConfig.backbone.isSupported,
              effectiveConfig.denoiseMode == .off,
              existingCheckpoint?.didRunDenoise != true,
              modelRegistry.availabilityPolicy != .requireProductionModels || effectiveConfig.scaleFactor == .x2 else {
            throw ScalerError.modelInferenceFailed(modelName: effectiveConfig.backbone.rawValue, tileIndex: 0,
                reason: "This job uses an unavailable model, scale or processing stage. Start a new 2× enlargement from the original photo; saved artifacts were left unchanged.")
        }
        let effectiveScale = effectiveConfig.scaleFactor
        // Whole-job monotonic origin, before registration and before every suspension.
        let jobStartNanos = DispatchTime.now().uptimeNanoseconds

        // Register the active execution before the first `await` so a concurrent pause request can never
        // observe an idle executor between job start and the first suspension and return too early.
        // A registered run for a different job is refused here, before any active-count/filesystem
        // mutation, instead of being misattributed to that run's identity.
        let executionOwner = try resolveExecutionOwner(for: jobID)
        activeExecutionCount += 1
        activeExecutionOwnerCounts[executionOwner, default: 0] += 1
        defer {
            activeExecutionCount -= 1
            if let count = activeExecutionOwnerCounts[executionOwner] {
                if count <= 1 {
                    activeExecutionOwnerCounts.removeValue(forKey: executionOwner)
                } else {
                    activeExecutionOwnerCounts[executionOwner] = count - 1
                }
            }
            // A pause/expiration waiter must never outlive its own tile loop, even on completion, failure,
            // cancellation, or a Stage 1 decode error before the first tile. Waiters belonging to a newer
            // run that has not started yet stay queued for that run's own boundary.
            signalStableBoundary(for: executionOwner)
        }
        discardStalePauseAtExecutionStart(for: executionOwner)

        // Diagnostics may suspend on the model-registry actor. It must happen only after ownership and
        // cleanup are installed above. Capture the request revision first: a newer tier/background
        // request may land while this read is suspended and must win over the stale entry snapshot.
        let entryPolicyRevision = requestedComputePolicy.currentRevision
        let rawRequestedUnits = await modelRegistry.currentRequestedUnits()
        let legacyDescription = Self.requestedComputeDescription(modelRegistry.effectiveComputeUnits(for: rawRequestedUnits))
        requestedComputePolicy.publishIfRevisionUnchanged(legacyDescription, rawUnits: rawRequestedUnits,
                                                         expectedRevision: entryPolicyRevision)
        // Tier changes only select a shape; compute routing is family-specific. Use the frozen
        // checkpoint/config even before decoding has selected the new job's final memory tier.
        let executionModelID = try CoreMLModelIdentifier.superResolver(backbone: effectiveConfig.backbone,
            tier: existingCheckpoint?.tileConfig.tier ?? .tierB_ConstrainedMemory)
        let requestedCompute = requestedComputePolicy.description(for: executionModelID, registry: modelRegistry)
        Diagnostics.shared.record(
            category: .pipeline,
            level: .notice,
            code: "pipeline.job.start",
            message: "job started",
            fields: [
                "correlationID": jobID.uuidString,
                "sourceType": Self.sourceType(for: effectiveConfig.sourceImageURL),
                "backbone": effectiveConfig.backbone.rawValue,
                "scale": "\(effectiveScale.rawValue)x",
                "denoise": effectiveConfig.denoiseMode.rawValue,
                "computeRequested": requestedCompute,
                "resume": existingCheckpoint == nil ? "false" : "true"
            ]
        )

        let sourceMMapFileName = existingCheckpoint?.sourceMMapFileName ?? "source_\(jobID.uuidString).rgba16f.bin"
        let outputMMapFileName = existingCheckpoint?.outputMMapFileName ?? "output_\(jobID.uuidString).rgba16f.bin"
        let metadataPacketFileName = existingCheckpoint?.metadataPacketFileName ?? "metadata_\(jobID.uuidString).json"

        let checkpointFileURL = await checkpointStore.checkpointFileURL(for: jobID)
        let sourceURL = try containedWorkingURL(relativePath: sourceMMapFileName, jobID: jobID)
        let outputURL = try containedWorkingURL(relativePath: outputMMapFileName, jobID: jobID)
        let metadataURL = try containedWorkingURL(relativePath: metadataPacketFileName, jobID: jobID)

        let sourceBuffer: MMapBuffer
        var outputBuffer: MMapBuffer
        /// Source metadata, merged with `config.sessionState` (additive pipeline state from a handoff
        /// or forwarding session) before any denoise decision or checkpoint save (contract §R6).
        var metadata: ImageMetadataPacket
        let plan: TileGridPlan
        var checkpoint: JobCheckpointState
        /// Exact clipped destination rectangle per tile index, derived from the plan (never from the
        /// journal file), used to validate undo manifests and to publish them.
        var journalRects: [Int: TileJournalRect] = [:]

        if let existingCheckpoint {
            // MARK: Stage 1 resume: reopen the existing mmap canvases + metadata and rebuild the plan.
            try validateResumeCheckpoint(
                existingCheckpoint,
                checkpointURL: checkpointFileURL,
                sourceURL: sourceURL,
                outputURL: outputURL,
                metadataURL: metadataURL
            )
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw ScalerError.fileNotFound(sourceURL)
            }
            guard FileManager.default.fileExists(atPath: outputURL.path) else {
                throw ScalerError.fileNotFound(outputURL)
            }
            metadata = try loadMetadata(from: metadataURL, checkpointFileURL: checkpointFileURL)

            // Contract §R6: the handoff/session state persisted in the checkpoint config must be
            // merged back into the loaded metadata before the job replays. Re-decoding the source on
            // every launch would otherwise discard payload-only denoise/upscale/headroom state and an
            // inherited processing history could be lost on resume. A caller-supplied
            // session state (e.g. an older checkpoint that predates the field) is also honored.
            let resumeSessionState = config.sessionState ?? effectiveConfig.sessionState
            let mergedMetadata = metadata.merging(sessionState: resumeSessionState)
            let needsMetadataPublication = mergedMetadata != metadata
            metadata = mergedMetadata

            do {
                sourceBuffer = try MMapBuffer(
                    fileURL: sourceURL,
                    width: existingCheckpoint.sourceWidth,
                    height: existingCheckpoint.sourceHeight,
                    createIfMissing: false
                )
                outputBuffer = try MMapBuffer(
                    fileURL: outputURL,
                    width: existingCheckpoint.outputWidth,
                    height: existingCheckpoint.outputHeight,
                    createIfMissing: false
                )
            } catch {
                throw ScalerError.checkpointCorrupted(checkpointFileURL)
            }

            plan = TileGridPlanner.makePlan(
                sourceWidth: existingCheckpoint.sourceWidth,
                sourceHeight: existingCheckpoint.sourceHeight,
                scaleFactor: effectiveScale,
                tileConfig: existingCheckpoint.tileConfig
            )
            guard plan.outputWidth == existingCheckpoint.outputWidth,
                  plan.outputHeight == existingCheckpoint.outputHeight,
                  plan.totalTiles == existingCheckpoint.totalTiles else {
                throw ScalerError.checkpointCorrupted(checkpointFileURL)
            }
            journalRects = try makeJournalRects(for: plan, checkpointURL: checkpointFileURL)
            checkpoint = existingCheckpoint

            // Resolve the normalization contract before journal recovery mutates any canvas pixel: if
            // this checkpoint already owns the canonical migrated output and another rebuild is needed,
            // refuse before even rollback recovery so the authoritative canonical bytes stay untouched.
            let normalizationResolution = try normalizationResolutionIfNeeded(
                existingCheckpoint,
                sourceBuffer: sourceBuffer,
                metadata: metadata,
                checkpointURL: checkpointFileURL
            )
            if normalizationResolution?.requiresRebuild == true {
                // A stale in-memory checkpoint may name the old canvas while the durable one
                // already owns the canonical output. Refuse before rollback can rewrite that old
                // canvas or delete its journal; migration rechecks after its later suspension.
                try await validateLegacyNormalizationRebuildOwnership(
                    state: existingCheckpoint,
                    jobID: jobID,
                    checkpointURL: checkpointFileURL
                )
            }

            // MARK: Crash recovery: exact pixel rollback of the one uncommitted tile, if any.
            // Committed journals are discarded; corrupt/truncated/unexpected journals fail before any
            // output byte is touched. The checkpoint commit is the source of truth for the frontier.
            _ = try undoJournal.recover(
                jobID: jobID,
                lastCompletedTileIndex: checkpoint.lastCompletedTileIndex,
                totalTiles: plan.totalTiles,
                expectedRects: journalRects,
                into: outputBuffer
            )

            // Incoming handoff/history facts are needed in memory during preflight, but must not
            // relabel the persisted photo when its plan/normalization/journal is incompatible.
            // Publish only after those checks pass, before any subsequent checkpoint save.
            if needsMetadataPublication, normalizationResolution?.requiresRebuild != true {
                try writeMetadata(metadata, to: metadataURL)
            }

            // Contract §R1/C1: never silently resume with a luminance-derived (or otherwise too small)
            // normalization denominator, and never relabel committed pixels that were produced under a
            // different denominator contract. Rescan the mapped source with checked streaming arithmetic
            // first, then either update metadata and replay the remaining tiles (compatible frontier) or
            // rebuild the complete canvas atomically from the immutable source (incompatible frontier).
            if let resolution = normalizationResolution {
                if resolution.requiresRebuild {
                    let migration = try await rebuildLegacyNormalization(
                        state: existingCheckpoint,
                        resolvedComponent: resolution.updatedCheckpoint.globalMaxLinearComponent,
                        sourceBuffer: sourceBuffer,
                        plan: plan,
                        jobID: jobID,
                        checkpointURL: checkpointFileURL,
                        executionOwner: executionOwner,
                        metadataToPublish: needsMetadataPublication ? metadata : nil,
                        progressHandler: progressHandler
                    )
                    checkpoint = migration.checkpoint
                    outputBuffer = migration.outputBuffer
                } else {
                    checkpoint = resolution.updatedCheckpoint
                    try await checkpointStore.save(checkpoint)
                }
            } else if existingCheckpoint.outputMMapFileName == legacyMigrationCanonicalFileName(jobID: jobID) {
                // A crash after the migration checkpoint commit but before the legacy-output cleanup
                // leaves the deterministic pre-migration output behind. The committed norm-2 output is
                // authoritative, but the checkpoint rename itself may not be durable yet (an ambiguous
                // save can leave a visible checkpoint before its directory fsync). Confirm durability
                // first; on failure retain BOTH canvases and keep resuming from the canonical one.
                if (try? await checkpointStore.confirmDurability()) != nil {
                    removeLegacyOutputIfOrphaned(
                        state: existingCheckpoint,
                        jobID: jobID
                    )
                }
            }

            let completed = max(0, min(checkpoint.lastCompletedTileIndex + 1, plan.totalTiles))
            progressHandler?(
                PipelineProgressUpdate(
                    jobID: jobID,
                    stage: .denoisingAndUpscalingTiles,
                    completedTiles: completed,
                    totalTiles: plan.totalTiles,
                    overallFraction: overallFraction(completed: completed, total: plan.totalTiles),
                    estimatedSecondsRemaining: nil,
                    currentTileDescriptor: nil,
                    phase: .preparingModels,
                    elapsedSeconds: Self.elapsedSeconds(sinceNanos: jobStartNanos),
                    requestedCompute: requestedComputePolicy.description(for: executionModelID, registry: modelRegistry)
                )
            )
        } else {
            // MARK: Stage 1 fresh job: decode the source image into a disk-backed mmap canvas.
            try Task.checkCancellation()
            progressHandler?(
                PipelineProgressUpdate(
                    jobID: jobID,
                    stage: .ingestingAndDecodingStrips,
                    completedTiles: 0,
                    totalTiles: 0,
                    overallFraction: 0.0,
                    estimatedSecondsRemaining: nil,
                    currentTileDescriptor: nil,
                    elapsedSeconds: Self.elapsedSeconds(sinceNanos: jobStartNanos),
                    requestedCompute: requestedComputePolicy.description(for: executionModelID, registry: modelRegistry)
                )
            )

            let computePolicy = requestedComputePolicy
            let progressRegistry = modelRegistry
            let decodeProgressHandler: @Sendable (Double) -> Void = { fraction in
                let clamped = fraction.isFinite ? min(max(fraction, 0.0), 1.0) : 0.0
                progressHandler?(
                    PipelineProgressUpdate(
                        jobID: jobID,
                        stage: .ingestingAndDecodingStrips,
                        completedTiles: 0,
                        totalTiles: 0,
                        overallFraction: clamped * 0.10,
                        estimatedSecondsRemaining: nil,
                        currentTileDescriptor: nil,
                        elapsedSeconds: Self.elapsedSeconds(sinceNanos: jobStartNanos),
                        requestedCompute: computePolicy.description(for: executionModelID, registry: progressRegistry)
                    )
                )
            }

            let decodeStart = ContinuousClock.now
            let decoded = try await Self.stage1IOOwner.run {
                try UniversalStripDecoder.decodeToMMap(
                    imageURL: config.sourceImageURL,
                    destinationMMapURL: sourceURL,
                    stripHeight: UniversalStripDecoder.defaultStripHeight,
                    progressHandler: decodeProgressHandler
                )
            }
            let decodeSeconds = Self.seconds(from: decodeStart.duration(to: .now))
            try Task.checkCancellation()
            Diagnostics.shared.record(
                category: .pipeline,
                level: .notice,
                code: "pipeline.decode",
                message: "source decoded",
                fields: [
                    "correlationID": jobID.uuidString,
                    "sourceType": Self.sourceType(for: config.sourceImageURL),
                    "decodedWidth": "\(decoded.decodedWidth)",
                    "decodedHeight": "\(decoded.decodedHeight)",
                    "category": decoded.metadata.category.rawValue,
                    "seconds": String(format: "%.3f", decodeSeconds)
                ]
            )

            guard decoded.decodedWidth > 0, decoded.decodedHeight > 0 else {
                throw ScalerError.invalidImageDimensions(width: decoded.decodedWidth, height: decoded.decodedHeight)
            }
            let scaleValue = effectiveScale.rawValue
            guard decoded.decodedWidth <= Int.max / scaleValue,
                  decoded.decodedHeight <= Int.max / scaleValue else {
                throw ScalerError.invalidImageDimensions(width: decoded.decodedWidth, height: decoded.decodedHeight)
            }
            let outputWidth = decoded.decodedWidth * scaleValue
            let outputHeight = decoded.decodedHeight * scaleValue

            let tileConfig: TileConfiguration
            if let overrideTier {
                tileConfig = TileConfiguration(tier: overrideTier, backbone: effectiveConfig.backbone)
            } else {
                tileConfig = HardwareTelemetry.makeTileConfiguration(backbone: effectiveConfig.backbone)
            }
            plan = TileGridPlanner.makePlan(
                sourceWidth: decoded.decodedWidth,
                sourceHeight: decoded.decodedHeight,
                scaleFactor: effectiveScale,
                tileConfig: tileConfig
            )
            journalRects = try makeJournalRects(for: plan, checkpointURL: checkpointFileURL)

            // Reserve room for the largest per-tile undo journal on top of both mmap canvases.
            // Checked geometry first: an absurd decoded width/height must throw a ScalerError here,
            // before the disk check or any mmap allocation can trap on overflow.
            let maximumJournalBytes = journalRects.values.reduce(0) { partial, rect in
                max(partial, TileUndoJournal.undoByteCount(for: rect))
            } + TileUndoJournal.maximumManifestBytes
            let outputMMapBytes = try HardwareTelemetry.checkedRequiredMMapBytes(
                width: outputWidth,
                height: outputHeight
            )
            let (requiredBytes, requiredOverflow) = outputMMapBytes
                .addingReportingOverflow(Int64(maximumJournalBytes))
            guard !requiredOverflow else {
                throw ScalerError.invalidImageDimensions(width: outputWidth, height: outputHeight)
            }
            try HardwareTelemetry.verifyDiskSpace(
                directory: workingDirectory,
                requiredBytes: requiredBytes
            )

            let canvasStart = ContinuousClock.now
            sourceBuffer = decoded.sourceBuffer
            // Contract §R6: a fresh decode must carry the handoff/session state into the metadata
            // *before* the denoise decision, and the merged packet is what gets persisted.
            metadata = decoded.metadata.merging(sessionState: effectiveConfig.sessionState)
            outputBuffer = try MMapBuffer(
                fileURL: outputURL,
                width: outputWidth,
                height: outputHeight,
                createIfMissing: true
            )

            // A fresh job has no checkpoint frontier, so its output canvas was just recreated. Any
            // journal sidecars carrying this job's ID are stale; remove only this job's files.
            _ = try undoJournal.removeAllJournalFiles(jobID: jobID)

            try writeMetadata(metadata, to: metadataURL)

            // Preserve upstream history separately; this SR-only job never runs denoising.
            let didRunDenoise = false
            let globalMaxLuminance = Self.sanitizedPeak(decoded.globalMaxLuminance)
            // Contract §R1: the checkpoint denominator is the decoded RGB *component* peak, never
            // luminance. A saturated red of 4 has luminance ~0.916 but still needs headroom 4.
            let globalMaxLinearComponent = Self.sanitizedPeak(decoded.globalMaxLinearComponent)
            checkpoint = JobCheckpointState(
                jobID: jobID,
                config: effectiveConfig,
                tileConfig: tileConfig,
                sourceWidth: decoded.decodedWidth,
                sourceHeight: decoded.decodedHeight,
                paddedSourceWidth: decoded.decodedWidth,
                paddedSourceHeight: decoded.decodedHeight,
                outputWidth: outputWidth,
                outputHeight: outputHeight,
                globalMaxLuminance: globalMaxLuminance,
                globalMaxLinearComponent: globalMaxLinearComponent,
                alphaCurveConstant: 16.0,
                didRunDenoise: didRunDenoise,
                sourceMMapFileName: sourceMMapFileName,
                outputMMapFileName: outputMMapFileName,
                metadataPacketFileName: metadataPacketFileName,
                lastCompletedTileIndex: -1,
                totalTiles: plan.totalTiles,
                updatedAt: Date(),
                transactionJournalVersion: JobCheckpointState.currentTransactionJournalVersion,
                normalizationPeakVersion: JobCheckpointState.currentNormalizationPeakVersion
            )
            try await checkpointStore.save(checkpoint)
            Diagnostics.shared.record(
                category: .pipeline,
                level: .notice,
                code: "pipeline.canvas_prepare",
                message: "mmap canvas prepared",
                fields: [
                    "correlationID": jobID.uuidString,
                    "outputWidth": "\(outputWidth)",
                    "outputHeight": "\(outputHeight)",
                    "outputBytes": "\(outputBuffer.totalByteSize)",
                    "journalReserveBytes": "\(maximumJournalBytes)",
                    "seconds": String(format: "%.3f", Self.seconds(from: canvasStart.duration(to: .now)))
                ]
            )

            progressHandler?(
                PipelineProgressUpdate(
                    jobID: jobID,
                    stage: .ingestingAndDecodingStrips,
                    completedTiles: 0,
                    totalTiles: plan.totalTiles,
                    overallFraction: 0.10,
                    estimatedSecondsRemaining: nil,
                    currentTileDescriptor: nil,
                    phase: .preparingModels,
                    elapsedSeconds: Self.elapsedSeconds(sinceNanos: jobStartNanos),
                    sourceWidth: decoded.decodedWidth,
                    sourceHeight: decoded.decodedHeight,
                    outputWidth: outputWidth,
                    outputHeight: outputHeight,
                    requestedCompute: requestedComputePolicy.description(for: executionModelID, registry: modelRegistry),
                    didRunDenoise: didRunDenoise
                )
            )
        }

        let totalTiles = plan.totalTiles
        let modelID = try CoreMLModelIdentifier.superResolver(
            backbone: checkpoint.config.backbone,
            tier: checkpoint.tileConfig.tier
        )
        let modelName = modelID.rawValue

        let progress = JobProgressEmitter(
            jobID: jobID,
            handler: progressHandler,
            sourceWidth: checkpoint.sourceWidth,
            sourceHeight: checkpoint.sourceHeight,
            outputWidth: checkpoint.outputWidth,
            outputHeight: checkpoint.outputHeight,
            modelName: modelName,
            modelID: modelID,
            modelRegistry: modelRegistry,
            tileSize: checkpoint.tileConfig.inputTileSize,
            tileOverlap: checkpoint.tileConfig.inputOverlap,
            gridColumns: plan.cols,
            gridRows: plan.rows,
            policy: requestedComputePolicy,
            didRunDenoise: checkpoint.didRunDenoise,
            startNanos: jobStartNanos,
            tileLoopStartNanos: DispatchTime.now().uptimeNanoseconds
        )

        Diagnostics.shared.record(
            category: .pipeline,
            level: .notice,
            code: "pipeline.plan",
            message: "plan ready",
            fields: [
                "correlationID": jobID.uuidString,
                "sourceWidth": "\(checkpoint.sourceWidth)",
                "sourceHeight": "\(checkpoint.sourceHeight)",
                "outputWidth": "\(checkpoint.outputWidth)",
                "outputHeight": "\(checkpoint.outputHeight)",
                "scale": "\(effectiveScale.rawValue)x",
                "model": modelName,
                "tileSize": "\(checkpoint.tileConfig.inputTileSize)",
                "tileOverlap": "\(checkpoint.tileConfig.inputOverlap)",
                "gridColumns": "\(plan.cols)",
                "gridRows": "\(plan.rows)",
                "totalTiles": "\(plan.totalTiles)",
                "computeRequested": requestedComputePolicy.description(for: modelID, registry: modelRegistry),
                "didRunDenoise": checkpoint.didRunDenoise ? "true" : "false"
            ]
        )

        // MARK: Stage 3: sequential row-major tile loop, resumable from `lastCompletedTileIndex`.
        var completedSinceStart = 0
        var elapsedSeconds: Double = 0.0
        /// First executed tile includes CoreML graph warmup; keep it out of the steady-state ETA.
        var steadyElapsedSeconds: Double = 0.0
        var steadyTileCount = 0
        /// Last established steady-state estimate. Kept available during the next long tile.
        var lastAverageSecondsPerTile: Double?
        var lastEstimatedSecondsRemaining: Int?
        /// Set by every real terminal path (paused/completed) so the failure defer is a fallback only.
        var terminalPhasePublished = false

        defer {
            if !terminalPhasePublished {
                let frontier = max(0, min(checkpoint.lastCompletedTileIndex + 1, totalTiles))
                progress.emit(
                    phase: .failed,
                    stage: .failed,
                    completed: frontier,
                    total: totalTiles,
                    tile: nil,
                    timings: nil,
                    averageSecondsPerTile: lastAverageSecondsPerTile,
                    estimatedSecondsRemaining: nil
                )
            }
        }

        func pauseIfRequested() throws {
            // Only a pause owned by *this* execution applies. A pause belonging to the current
            // registered replacement run is left intact for that run; a pause owned by neither this
            // execution nor the current run is stale and discarded.
            discardStalePauseIfAny(for: executionOwner)
            let triggerReached: Bool
            if let trigger = pauseAfterCompletedTileIndex {
                triggerReached = checkpoint.lastCompletedTileIndex >= trigger
            } else {
                triggerReached = false
            }
            let pauseApplies = pauseRequested
                && (pauseRequestedByOwner == nil || pauseRequestedByOwner == executionOwner)
            guard pauseApplies || triggerReached else { return }

            try outputBuffer.flushToDisk(synchronous: true)
            if pauseApplies {
                pauseRequested = false
                pauseRequestedByOwner = nil
            }
            pauseAfterCompletedTileIndex = nil
            // This execution is now at a stable, flushed boundary: release its own scoped waiter and
            // any unscoped Stop/test waiter, but never a queued pause for a replacement run.
            signalStableBoundary(for: executionOwner)

            terminalPhasePublished = true
            let completed = max(0, min(checkpoint.lastCompletedTileIndex + 1, totalTiles))
            progress.emit(
                phase: .paused,
                stage: .pausedOnDisk,
                completed: completed,
                total: totalTiles,
                tile: nil,
                timings: nil,
                averageSecondsPerTile: lastAverageSecondsPerTile,
                estimatedSecondsRemaining: nil
            )
            throw ScalerError.jobPausedForBackgroundExpiration(completedTileIndex: checkpoint.lastCompletedTileIndex)
        }

        for tile in plan.tiles where tile.tileIndex > checkpoint.lastCompletedTileIndex {
            try Task.checkCancellation()
            try pauseIfRequested()

            let tileStart = ContinuousClock.now
            let forceCPU = isBackgroundMode
            let durableCompleted = max(0, min(checkpoint.lastCompletedTileIndex + 1, totalTiles))
            let busyAverage = lastAverageSecondsPerTile
            let busyETA = lastEstimatedSecondsRemaining

            progress.emit(
                phase: .extractingTile,
                stage: .denoisingAndUpscalingTiles,
                completed: durableCompleted,
                total: totalTiles,
                tile: tile,
                timings: nil,
                averageSecondsPerTile: busyAverage,
                estimatedSecondsRemaining: busyETA
            )

            let processed: TileProcessResult
            do {
                processed = try await processTile(
                    tile: tile,
                    sourceBuffer: sourceBuffer,
                    checkpoint: checkpoint,
                    config: effectiveConfig,
                    effectiveScale: effectiveScale,
                    forceCPU: forceCPU,
                    phaseHandler: { [durableCompleted, totalTiles, busyAverage, busyETA] phase in
                        progress.emit(
                            phase: phase,
                            stage: .denoisingAndUpscalingTiles,
                            completed: durableCompleted,
                            total: totalTiles,
                            tile: tile,
                            timings: nil,
                            averageSecondsPerTile: busyAverage,
                            estimatedSecondsRemaining: busyETA
                        )
                    }
                )
            } catch {
                Diagnostics.shared.recordError(
                    error,
                    category: .pipeline,
                    code: "pipeline.tile.process.failed",
                    context: [
                        "correlationID": jobID.uuidString,
                        "tile": "\(tile.tileIndex)",
                        "completed": "\(completedSinceStart)",
                        "total": "\(totalTiles)",
                        "model": modelName
                    ]
                )
                throw error
            }
            try Task.checkCancellation()
            var timings = processed.timings

            guard let tileRect = journalRects[tile.tileIndex] else {
                throw ScalerError.checkpointCorrupted(checkpointFileURL)
            }

            // 1. Publish the durable undo journal BEFORE any canvas mutation. It holds the exact
            //    pre-blend bytes of the clipped destination rectangle, so a crash at any later point
            //    restores this tile instead of blending it a second time on resume.
            progress.emit(
                phase: .committingTile,
                stage: .denoisingAndUpscalingTiles,
                completed: durableCompleted,
                total: totalTiles,
                tile: tile,
                timings: timings,
                averageSecondsPerTile: busyAverage,
                estimatedSecondsRemaining: busyETA
            )
            let journalStart = ContinuousClock.now
            try undoJournal.publish(
                jobID: jobID,
                tileIndex: tile.tileIndex,
                rect: tileRect,
                from: outputBuffer
            )
            timings.journalSeconds = Self.seconds(from: journalStart.duration(to: .now))
            try transactionInterruptionHook?(.afterJournalPublished)

            // 2. Blend the tile with the existing causal feather math (unchanged).
            progress.emit(
                phase: .blendingTile,
                stage: .denoisingAndUpscalingTiles,
                completed: durableCompleted,
                total: totalTiles,
                tile: tile,
                timings: timings,
                averageSecondsPerTile: busyAverage,
                estimatedSecondsRemaining: busyETA
            )
            let blendStart = ContinuousClock.now
            let tileRowBytes = tile.outputSize * 8
            processed.rgba.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                CausalTileBlender.writeAndFeatherTile(
                    tilePointer: baseAddress,
                    tileRowBytes: tileRowBytes,
                    tileWidth: tile.outputSize,
                    tileHeight: tile.outputSize,
                    destX: tile.outputOriginX,
                    destY: tile.outputOriginY,
                    leftOverlap: tile.actualLeftOverlapOut,
                    topOverlap: tile.actualTopOverlapOut,
                    into: outputBuffer
                )
            }
            timings.blendSeconds = Self.seconds(from: blendStart.duration(to: .now))
            try transactionInterruptionHook?(.afterCanvasMutation)

            // 3. Flush only the page-aligned range this tile can have modified.
            let flushStart = ContinuousClock.now
            try outputBuffer.flushRange(startY: tileRect.y, rowCount: tileRect.height)
            timings.flushSeconds = Self.seconds(from: flushStart.duration(to: .now))
            try transactionInterruptionHook?(.afterCanvasFlushBeforeCheckpoint)

            // 4. Durably commit the frontier. A checkpoint can never name a tile whose pixels are not
            //    yet durable, and the journal still exists if this commit is interrupted.
            checkpoint.lastCompletedTileIndex = tile.tileIndex
            checkpoint.updatedAt = Date()
            let checkpointStart = ContinuousClock.now
            try await checkpointStore.save(checkpoint)
            timings.checkpointSeconds = Self.seconds(from: checkpointStart.duration(to: .now))
            try transactionInterruptionHook?(.afterCheckpointBeforeJournalCleanup)

            // 5. The commit is durable; the undo journal is now obsolete. Delete it and fsync the
            //    containing directory so the cleanup itself survives a crash.
            let cleanupStart = ContinuousClock.now
            try undoJournal.discard(tileIndex: tile.tileIndex, jobID: jobID)
            timings.cleanupSeconds = Self.seconds(from: cleanupStart.duration(to: .now))

            // Keep resident dirty RAM flat: once a full tile row is complete, msync + release the
            // rows belonging to the *previous* completed row.
            if tile.col == plan.cols - 1 && tile.row > 0 {
                let previousRowTileIndex = (tile.row - 1) * plan.cols
                if previousRowTileIndex >= 0 && previousRowTileIndex < plan.tiles.count {
                    let previousRowStartY = plan.tiles[previousRowTileIndex].outputOriginY
                    let previousRowHeight = tile.outputOriginY - previousRowStartY
                    if previousRowHeight > 0 {
                        outputBuffer.releaseCleanPages(startY: previousRowStartY, rowCount: previousRowHeight)
                    }
                }
            }

            let tileDuration = tileStart.duration(to: ContinuousClock.now)
            let tileSeconds = Double(tileDuration.components.seconds)
                + Double(tileDuration.components.attoseconds) / 1_000_000_000_000_000_000.0
            elapsedSeconds += tileSeconds
            if completedSinceStart > 0 {
                steadyElapsedSeconds += tileSeconds
                steadyTileCount += 1
            }
            completedSinceStart += 1

            let completed = max(0, min(checkpoint.lastCompletedTileIndex + 1, totalTiles))
            let remaining = max(0, totalTiles - completed)
            // The first executed tile commonly includes graph load/warmup. Report an ETA only after
            // at least one steady-state sample, rather than extrapolating the warmup over the image.
            let measuredAverage: Double?
            let estimatedSecondsRemaining: Int?
            if steadyTileCount > 0, steadyElapsedSeconds.isFinite {
                let averageSecondsPerTile = steadyElapsedSeconds / Double(steadyTileCount)
                measuredAverage = averageSecondsPerTile
                estimatedSecondsRemaining = Int((averageSecondsPerTile * Double(remaining)).rounded())
            } else {
                measuredAverage = nil
                estimatedSecondsRemaining = nil
            }

            lastAverageSecondsPerTile = measuredAverage
            lastEstimatedSecondsRemaining = estimatedSecondsRemaining
            progress.emit(
                phase: .tileCommitted,
                stage: .denoisingAndUpscalingTiles,
                completed: completed,
                total: totalTiles,
                tile: tile,
                timings: timings,
                averageSecondsPerTile: measuredAverage,
                estimatedSecondsRemaining: estimatedSecondsRemaining
            )

            // One representative measured tile event (first, every 25th, and final) keeps the
            // bounded diagnostic ring useful without flooding it or the disk.
            if completedSinceStart == 1 || completed % 25 == 0 || completed == totalTiles {
                Diagnostics.shared.record(
                    category: .pipeline,
                    level: .info,
                    code: "pipeline.tile.committed",
                    message: "tile committed",
                    fields: [
                        "correlationID": jobID.uuidString,
                        "completed": "\(completed)",
                        "total": "\(totalTiles)",
                        "tile": "\(tile.tileIndex)",
                        "tileSeconds": String(format: "%.3f", Self.seconds(from: tileStart.duration(to: .now))),
                        "avgSecondsPerTile": measuredAverage.map { String(format: "%.3f", $0) } ?? "unknown",
                        "etaSeconds": estimatedSecondsRemaining.map(String.init) ?? "unknown",
                        "extractSeconds": timings.extractionSeconds.map { String(format: "%.3f", $0) } ?? "unknown",
                        "modelSeconds": timings.modelSeconds.map { String(format: "%.3f", $0) } ?? "unknown",
                        "stabilitySeconds": timings.stabilitySeconds.map { String(format: "%.3f", $0) } ?? "unknown",
                        "reconstructSeconds": timings.reconstructionSeconds.map { String(format: "%.3f", $0) } ?? "unknown",
                        "journalSeconds": timings.journalSeconds.map { String(format: "%.3f", $0) } ?? "unknown",
                        "blendSeconds": timings.blendSeconds.map { String(format: "%.3f", $0) } ?? "unknown",
                        "flushSeconds": timings.flushSeconds.map { String(format: "%.3f", $0) } ?? "unknown",
                        "checkpointSeconds": timings.checkpointSeconds.map { String(format: "%.3f", $0) } ?? "unknown",
                        "cleanupSeconds": timings.cleanupSeconds.map { String(format: "%.3f", $0) } ?? "unknown"
                    ]
                )
            }
            try pauseIfRequested()
        }

        // MARK: Stage 3 completion: flush the canvas, release CoreML memory, persist the final checkpoint.
        progress.emit(
            phase: .finalizing,
            stage: .denoisingAndUpscalingTiles,
            completed: max(0, min(checkpoint.lastCompletedTileIndex + 1, totalTiles)),
            total: totalTiles,
            tile: nil,
            timings: nil,
            averageSecondsPerTile: lastAverageSecondsPerTile,
            estimatedSecondsRemaining: lastEstimatedSecondsRemaining
        )
        try outputBuffer.flushToDisk(synchronous: true)
        await modelRegistry.unloadAllModels(correlationID: jobID)

        // Only retire the pause owned by this execution. A pause queued by the current replacement
        // run must survive this older execution's completion.
        if pauseRequestedByOwner == nil || pauseRequestedByOwner == executionOwner {
            pauseRequested = false
            pauseRequestedByOwner = nil
        }
        pauseAfterCompletedTileIndex = nil
        if totalTiles > 0 {
            checkpoint.lastCompletedTileIndex = totalTiles - 1
        }
        checkpoint.updatedAt = Date()
        try await checkpointStore.save(checkpoint)

        terminalPhasePublished = true
        let completedTotal = max(0, min(checkpoint.lastCompletedTileIndex + 1, totalTiles))
        progress.emit(
            phase: .completed,
            stage: .completed,
            completed: completedTotal,
            total: totalTiles,
            tile: nil,
            timings: nil,
            averageSecondsPerTile: steadyTileCount > 0 ? steadyElapsedSeconds / Double(steadyTileCount) : nil,
            estimatedSecondsRemaining: 0
        )
        Diagnostics.shared.record(
            category: .pipeline,
            level: .notice,
            code: "pipeline.job.completed",
            message: "job completed",
            fields: [
                "correlationID": jobID.uuidString,
                "completed": "\(completedTotal)",
                "total": "\(totalTiles)",
                "elapsedSeconds": String(format: "%.3f", progress.elapsedSeconds()),
                "avgSecondsPerTile": steadyTileCount > 0
                    ? String(format: "%.3f", steadyElapsedSeconds / Double(steadyTileCount))
                    : "unknown",
                "model": modelName
            ]
        )

        return CompletedPipelineArtifacts(
            checkpoint: checkpoint,
            metadata: metadata,
            sourceBuffer: sourceBuffer,
            outputBuffer: outputBuffer
        )
    }

    // MARK: - Per-tile pipeline

    private struct TileProcessResult {
        let rgba: [Float16]
        let timings: PipelineTileTimings
        let modelName: String
    }

    private func processTile(
        tile: TileDescriptor,
        sourceBuffer: MMapBuffer,
        checkpoint: JobCheckpointState,
        config: UpscaleJobConfig,
        effectiveScale: ScaleFactor,
        forceCPU: Bool,
        phaseHandler: (@Sendable (PipelinePhase) -> Void)? = nil
    ) async throws -> TileProcessResult {
        phaseHandler?(.extractingTile)
        let extractionStart = ContinuousClock.now
        // 1. Extract the padded T x T RGBA tile and apply the forward reversible log curve.
        var tensors = try autoreleasepool {
            try colorProcessor.extractLogNormalizedRGBTile(
                from: sourceBuffer,
                tile: tile,
                globalMaxLuminance: checkpoint.globalMaxLuminance,
                globalMaxLinearComponent: checkpoint.globalMaxLinearComponent,
                alphaConstant: checkpoint.alphaCurveConstant,
                forceCPU: forceCPU
            )
        }
        var timings = PipelineTileTimings()

        // Preserve the established log-luminance/chroma/alpha pipeline. Only the model-facing
        // luminance is transfer encoded to the checkpoint's [0,1] training domain.
        let decouplingRequiresCPU = forceCPU || isBackgroundMode
        try autoreleasepool {
            try colorProcessor.decoupleLuminanceAndChrominance(tensors: &tensors, forceCPU: decouplingRequiresCPU)
        }

        timings.extractionSeconds = Self.seconds(from: extractionStart.duration(to: .now))

        // Native 2× trained super-resolution on transfer-encoded luminance.
        let superResolverID = try CoreMLModelIdentifier.superResolver(
            backbone: checkpoint.config.backbone,
            tier: checkpoint.tileConfig.tier
        )
        phaseHandler?(.predictingSuperResolution)
        let predictionStart = ContinuousClock.now
        await waitForRequestedComputePolicy()
        let prediction = try await modelRegistry.predict(
            modelID: superResolverID,
            inputPlanarFP16: try colorProcessor.superResolutionInputTensor(from: tensors),
            inputHeight: tile.inputSize,
            inputWidth: tile.inputSize,
            outputHeight: tile.outputSize,
            outputWidth: tile.outputSize,
            tileIndex: tile.tileIndex,
            correlationID: checkpoint.jobID,
            stageHandler: { stage in
                phaseHandler?(stage == .loadingModel ? .preparingModels : .predictingSuperResolution)
            }
        )
        let predictionSeconds = Self.seconds(from: predictionStart.duration(to: .now))
        timings.modelSeconds = predictionSeconds

        let upscaledY = try colorProcessor.restoreSuperResolvedLuminance(
            prediction, tensors: tensors, outputSize: tile.outputSize,
            modelName: superResolverID.rawValue, tileIndex: tile.tileIndex,
            predictionRange: checkpoint.config.backbone.predictionSampleRange
        )

        // 5. Recombine YCbCr -> log RGB, inverse log curve, and write an RGBAh tile.
        // Super-resolution is another actor suspension point, so use the current policy again.
        phaseHandler?(.reconstructingTile)
        let reconstructionStart = ContinuousClock.now
        let reconstructionRequiresCPU = forceCPU || isBackgroundMode
        var tileRGBA = [Float16](repeating: 0, count: tile.outputSize * tile.outputSize * 4)
        try autoreleasepool {
            try upscaledY.withUnsafeBufferPointer { luminanceBuffer in
                try tileRGBA.withUnsafeMutableBufferPointer { destinationBuffer in
                    guard let luminanceBase = luminanceBuffer.baseAddress,
                          let destinationBase = destinationBuffer.baseAddress else {
                        throw ScalerError.modelInferenceFailed(
                            modelName: superResolverID.rawValue,
                            tileIndex: tile.tileIndex,
                            reason: "Super-resolution prediction returned an empty planar tensor."
                        )
                    }
                    try colorProcessor.reconstructUpscaledTile(
                        upscaledYPlanarFP16: UnsafeBufferPointer(start: luminanceBase, count: luminanceBuffer.count),
                        tensors: tensors,
                        scaleFactor: effectiveScale,
                        destinationRGBA16F: destinationBase,
                        forceCPU: reconstructionRequiresCPU
                    )
                }
            }
        }
        timings.reconstructionSeconds = Self.seconds(from: reconstructionStart.duration(to: .now))
        return TileProcessResult(rgba: tileRGBA, timings: timings, modelName: superResolverID.rawValue)
    }

    // MARK: - Helpers

    /// Clamps a decoder/scan-reported normalization peak to a finite value >= 1.0.
    private static func sanitizedPeak(_ value: Float) -> Float {
        value.isFinite ? max(1.0, value) : 1.0
    }

    private static func elapsedSeconds(sinceNanos startNanos: UInt64) -> Double {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startNanos
        let seconds = Double(elapsed) / 1_000_000_000.0
        return seconds.isFinite ? max(0, seconds) : 0
    }

    private static func seconds(from duration: Duration) -> Double {
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000.0
        return seconds.isFinite ? max(0, seconds) : 0
    }

    /// Human-readable requested compute policy. This is a request, not evidence of operator
    /// placement: `.all` does not prove ANE or GPU execution.
    private static func requestedComputeDescription(_ units: MLComputeUnits) -> String {
        switch units {
        case .all: return "all (CPU+GPU+ANE requested)"
        case .cpuAndGPU: return "cpuAndGPU requested"
        case .cpuAndNeuralEngine: return "cpuAndNeuralEngine requested"
        case .cpuOnly: return "cpuOnly"
        @unknown default: return "unknown"
        }
    }

    /// File extension only; never a path or filename.
    private static func sourceType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "unknown" : ext
    }

    /// `true` when a resumed checkpoint's normalization denominator is known (or suspect) to be
    /// luminance-derived rather than component-bounded, so it must be rescanned before replay.
    private func normalizationPeakNeedsRescan(
        _ state: JobCheckpointState,
        metadata: ImageMetadataPacket
    ) -> Bool {
        if state.normalizationPeakVersion < JobCheckpointState.currentNormalizationPeakVersion {
            return true
        }
        if state.globalMaxLinearComponent + 1e-6 < state.globalMaxLuminance {
            return true
        }
        // A version-2 SDR checkpoint legitimately stores 1.0. Only treat `<= 1` as potentially
        // inadequate when the source category can genuinely carry extended-range components.
        if state.globalMaxLinearComponent <= 1.0 {
            switch metadata.category {
            case .cameraRAW, .appleProRAW, .hdrHEIC:
                return true
            case .standardAlphaRaster, .standardOpaqueRaster:
                return metadata.isLinearDNG
                    || (metadata.linearHeadroomScale ?? 1.0) > 1.0 + 1e-4
            }
        }
        return false
    }

    /// Resolution of a resumed checkpoint's normalization contract (contract §C1).
    private struct NormalizationResolution {
        /// Durable state carrying the corrected denominator and the current normalization version.
        let updatedCheckpoint: JobCheckpointState
        /// `true` when the committed canvas was produced under a different denominator and therefore
        /// must be rebuilt from the immutable source instead of being relabeled and skipped.
        let requiresRebuild: Bool
    }

    /// Result of a successful legacy-normalization migration: the committed checkpoint and the
    /// reopened deterministic norm-2 canvas that the caller must return as the job's output.
    private struct NormalizationMigrationResult {
        let checkpoint: JobCheckpointState
        let outputBuffer: MMapBuffer
    }

    /// Returns the corrected checkpoint (and whether committed pixels must be rebuilt) or `nil` when
    /// the persisted denominator is already adequate and current.
    ///
    /// The committed canvas is authoritative only when the denominator that produced it was at least
    /// the newly resolved component denominator; otherwise its pixels may have been clipped by the old
    /// contract and cannot be relabeled as current-version output.
    private func normalizationResolutionIfNeeded(
        _ state: JobCheckpointState,
        sourceBuffer: MMapBuffer,
        metadata: ImageMetadataPacket,
        checkpointURL: URL
    ) throws -> NormalizationResolution? {
        guard normalizationPeakNeedsRescan(state, metadata: metadata) else { return nil }
        let rescanned = try rescanGlobalMaxLinearComponent(from: sourceBuffer, checkpointURL: checkpointURL)
        // Keep a previously stored, larger (adequate) value: the rescan can only prove insufficiency.
        let resolvedComponent = max(
            Self.sanitizedPeak(rescanned),
            Self.sanitizedPeak(state.globalMaxLinearComponent)
        )
        let componentChanged = abs(resolvedComponent - state.globalMaxLinearComponent) > 1e-6
        let versionOutdated = state.normalizationPeakVersion < JobCheckpointState.currentNormalizationPeakVersion

        // The denominator that actually produced the committed pixels: pre-R1 checkpoints normalized
        // by luminance, version-2 checkpoints normalized by the stored component.
        let oldDenominator: Float
        if versionOutdated {
            oldDenominator = max(1.0, state.globalMaxLuminance)
        } else {
            oldDenominator = state.globalMaxLinearComponent
        }
        let requiresRebuild = state.lastCompletedTileIndex >= 0
            && oldDenominator + 1e-6 < resolvedComponent
        guard componentChanged || versionOutdated || requiresRebuild else { return nil }

        let updated = checkpointState(
            updating: state,
            globalMaxLinearComponent: resolvedComponent,
            outputMMapFileName: nil,
            lastCompletedTileIndex: nil,
            normalizationPeakVersion: JobCheckpointState.currentNormalizationPeakVersion
        )
        return NormalizationResolution(updatedCheckpoint: updated, requiresRebuild: requiresRebuild)
    }

    /// Copies a checkpoint, overriding only the fields a normalization migration or upgrade may change.
    private func checkpointState(
        updating state: JobCheckpointState,
        globalMaxLinearComponent: Float,
        outputMMapFileName: String?,
        lastCompletedTileIndex: Int?,
        normalizationPeakVersion: Int
    ) -> JobCheckpointState {
        JobCheckpointState(
            jobID: state.jobID,
            config: state.config,
            tileConfig: state.tileConfig,
            sourceWidth: state.sourceWidth,
            sourceHeight: state.sourceHeight,
            paddedSourceWidth: state.paddedSourceWidth,
            paddedSourceHeight: state.paddedSourceHeight,
            outputWidth: state.outputWidth,
            outputHeight: state.outputHeight,
            globalMaxLuminance: state.globalMaxLuminance,
            globalMaxLinearComponent: globalMaxLinearComponent,
            alphaCurveConstant: state.alphaCurveConstant,
            didRunDenoise: state.didRunDenoise,
            sourceMMapFileName: state.sourceMMapFileName,
            outputMMapFileName: outputMMapFileName ?? state.outputMMapFileName,
            metadataPacketFileName: state.metadataPacketFileName,
            lastCompletedTileIndex: lastCompletedTileIndex ?? state.lastCompletedTileIndex,
            totalTiles: state.totalTiles,
            updatedAt: Date(),
            transactionJournalVersion: state.transactionJournalVersion,
            normalizationPeakVersion: normalizationPeakVersion
        )
    }

    /// Deterministic canonical output name for a migrated legacy job. The name is stable so a crash
    /// after the rename but before the checkpoint commit can be detected and cleaned on retry.
    private func legacyMigrationCanonicalFileName(jobID: UUID) -> String {
        "output_\(jobID.uuidString)_norm2.rgba16f.bin"
    }

    /// Checks canonical ownership without mutating canvases, metadata or recovery sidecars.
    /// Used before journal recovery and rechecked inside the migration before candidate creation.
    private func validateLegacyNormalizationRebuildOwnership(
        state: JobCheckpointState,
        jobID: UUID,
        checkpointURL: URL
    ) async throws {
        let canonicalFileName = legacyMigrationCanonicalFileName(jobID: jobID)
        // Safety refusal: the input checkpoint already owns the deterministic canonical norm-2 output.
        // Another normalization rebuild would overwrite/unlink authoritative pixels before any safe
        // switch exists, so refuse before touching the filesystem. The caller must restart the job from
        // its immutable source (removing its checkpoint/output) instead.
        guard state.outputMMapFileName != canonicalFileName else {
            throw ScalerError.normalizationMigrationRequiresRestart(
                checkpointURL,
                reason: "The checkpoint already names \(canonicalFileName) while its denominator/frontier still requires a full rebuild."
            )
        }
        // The same refusal applies if the *durable* checkpoint already names the canonical output (for
        // example a previous save published it but the caller passed a stale in-memory checkpoint). Never
        // treat a canvas referenced by the on-disk checkpoint as a disposable orphan. An unreadable
        // durable checkpoint is also treated conservatively: it may still reference the canonical canvas.
        var persistedState: JobCheckpointState?
        do {
            persistedState = try await checkpointStore.load(jobID: jobID)
        } catch let error as ScalerError {
            if case .fileNotFound = error {
                persistedState = nil
            } else {
                throw ScalerError.normalizationMigrationRequiresRestart(
                    checkpointURL,
                    reason: "The durable checkpoint could not be read (\(error.localizedDescription)); refusing to overwrite a potentially referenced canonical canvas."
                )
            }
        }
        if persistedState?.outputMMapFileName == canonicalFileName {
            throw ScalerError.normalizationMigrationRequiresRestart(
                checkpointURL,
                reason: "The durable checkpoint already references \(canonicalFileName); refusing to overwrite or unlink that authoritative canvas."
            )
        }
    }

    /// Rebuilds every tile from the immutable source under the corrected denominator into a fresh temp
    /// canvas, then atomically switches the job to the deterministic norm-2 output.
    ///
    /// The old checkpoint/output/journals stay authoritative until the checkpoint commit returns. After
    /// the candidate canvas is renamed, a later failure retains both the canonical candidate and the old
    /// output: a thrown `save` does not prove the old checkpoint is still published. Journals are
    /// intentionally not published during the rebuild: the temp canvas is disposable.
    private func rebuildLegacyNormalization(
        state: JobCheckpointState,
        resolvedComponent: Float,
        sourceBuffer: MMapBuffer,
        plan: TileGridPlan,
        jobID: UUID,
        checkpointURL: URL,
        executionOwner: ExecutionPauseOwner?,
        metadataToPublish: ImageMetadataPacket?,
        progressHandler: (@Sendable (PipelineProgressUpdate) -> Void)?
    ) async throws -> NormalizationMigrationResult {
        let canonicalFileName = legacyMigrationCanonicalFileName(jobID: jobID)
        let canonicalURL = try containedWorkingURL(relativePath: canonicalFileName, jobID: jobID)
        let tempURL = try containedWorkingURL(
            relativePath: "output_\(jobID.uuidString)_norm2.\(UUID().uuidString).tmp.rgba16f.bin",
            jobID: jobID
        )

        try await validateLegacyNormalizationRebuildOwnership(
            state: state,
            jobID: jobID,
            checkpointURL: checkpointURL
        )

        // The durable checkpoint is another compatibility check: a stale in-memory resume must
        // not publish new handoff/history facts before the canonical-ownership refusal above.
        if let metadataToPublish {
            let metadataURL = try containedWorkingURL(relativePath: state.metadataPacketFileName, jobID: jobID)
            try writeMetadata(metadataToPublish, to: metadataURL)
        }

        // A previous interrupted attempt may have left a temp canvas, or a canonical canvas whose
        // rename succeeded but whose checkpoint commit did not. Both are disposable because the
        // durable checkpoint still names the old output.
        removeOrphanedMigrationArtifacts(
            jobID: jobID,
            canonicalURL: canonicalURL,
            legacyOutputFileName: state.outputMMapFileName
        )

        // Reserve the complete rebuilt canvas before creating it, so a full disk is an actionable
        // `ScalerError` instead of a partial migration.
        let requiredBytes = try HardwareTelemetry.checkedRequiredMMapBytes(
            width: plan.outputWidth,
            height: plan.outputHeight
        )
        try HardwareTelemetry.verifyDiskSpace(directory: workingDirectory, requiredBytes: requiredBytes)

        let migratedCheckpoint = checkpointState(
            updating: state,
            globalMaxLinearComponent: resolvedComponent,
            outputMMapFileName: canonicalFileName,
            lastCompletedTileIndex: plan.totalTiles - 1,
            normalizationPeakVersion: JobCheckpointState.currentNormalizationPeakVersion
        )
        let effectiveConfig = state.config
        let effectiveScale = effectiveConfig.scaleFactor
        let totalTiles = plan.totalTiles

        progressHandler?(
            PipelineProgressUpdate(
                jobID: jobID,
                stage: .denoisingAndUpscalingTiles,
                completedTiles: 0,
                totalTiles: totalTiles,
                overallFraction: overallFraction(completed: 0, total: totalTiles),
                estimatedSecondsRemaining: nil,
                currentTileDescriptor: nil
            )
        )

        var tempOutput: MMapBuffer? = try MMapBuffer(
            fileURL: tempURL,
            width: plan.outputWidth,
            height: plan.outputHeight,
            createIfMissing: true
        )
        var didRename = false
        do {
            // A pause request that arrived during the recovery/rescan/disk-check setup must not be
            // ignored until the whole rebuild finishes: honor it before the first rebuilt tile.
            try throwIfMigrationPaused(
                state: state,
                rebuiltTiles: 0,
                totalTiles: totalTiles,
                jobID: jobID,
                executionOwner: executionOwner,
                progressHandler: progressHandler
            )
            guard let tempCanvas = tempOutput else {
                throw ScalerError.checkpointCorrupted(checkpointURL)
            }
            var rebuiltTiles = 0
            for tile in plan.tiles {
                try Task.checkCancellation()
                let processed = try await processTile(
                    tile: tile,
                    sourceBuffer: sourceBuffer,
                    checkpoint: migratedCheckpoint,
                    config: effectiveConfig,
                    effectiveScale: effectiveScale,
                    forceCPU: isBackgroundMode
                )
                try Task.checkCancellation()

                let tileRowBytes = tile.outputSize * 8
                processed.rgba.withUnsafeBytes { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    CausalTileBlender.writeAndFeatherTile(
                        tilePointer: baseAddress,
                        tileRowBytes: tileRowBytes,
                        tileWidth: tile.outputSize,
                        tileHeight: tile.outputSize,
                        destX: tile.outputOriginX,
                        destY: tile.outputOriginY,
                        leftOverlap: tile.actualLeftOverlapOut,
                        topOverlap: tile.actualTopOverlapOut,
                        into: tempCanvas
                    )
                }
                rebuiltTiles += 1

                try throwIfMigrationPaused(
                    state: state,
                    rebuiltTiles: rebuiltTiles,
                    totalTiles: totalTiles,
                    jobID: jobID,
                    executionOwner: executionOwner,
                    progressHandler: progressHandler
                )

                progressHandler?(
                    PipelineProgressUpdate(
                        jobID: jobID,
                        stage: .denoisingAndUpscalingTiles,
                        completedTiles: rebuiltTiles,
                        totalTiles: totalTiles,
                        overallFraction: overallFraction(completed: rebuiltTiles, total: totalTiles),
                        estimatedSecondsRemaining: nil,
                        currentTileDescriptor: tile
                    )
                )
            }

            try tempCanvas.flushToDisk(synchronous: true)
            // Release the mapping before the rename so the canonical file is not held open by this
            // process any longer than necessary.
            tempOutput = nil
            guard Darwin.rename(tempURL.path, canonicalURL.path) == 0 else {
                throw ScalerError.mmapSyncFailed(errno: errno)
            }
            didRename = true
            try fsyncWorkingDirectory()

            // The durable commit is the switch point: before it the old checkpoint/output/journals are
            // authoritative; after it the complete norm-2 canvas is. `save` can throw AFTER it renamed
            // the new checkpoint over the authoritative one (the final directory fsync is the last
            // step), so a thrown error does not prove the old checkpoint is still in force.
            try await checkpointStore.save(migratedCheckpoint)
        } catch {
            tempOutput = nil
            if !didRename {
                // Still before the candidate rename: only the disposable temp canvas exists.
                try? FileManager.default.removeItem(at: tempURL)
            }
            // After the candidate rename, publication is ambiguous: the old checkpoint may still be
            // authoritative, or the new checkpoint may already be visible. Both the old output and the
            // fully flushed canonical candidate are retained so whichever checkpoint survives has a
            // complete canvas. A later retry removes an unreferenced canonical only after proving the
            // durable checkpoint does not name it.
            throw error
        }

        // The migration is committed (save returned). Retire the pre-migration output and any journal
        // sidecars; cleanup is best effort so a failure here can never discard committed work.
        var cleanupSucceeded = true
        if let hook = migrationCleanupInterruptionHook {
            migrationCleanupInterruptionHook = nil
            do {
                try hook()
            } catch {
                // Simulated/test-only cleanup failure: retain both canvases and keep the committed
                // canonical artifact/checkpoint. The next resume retires the old canvas after confirming
                // checkpoint durability.
                cleanupSucceeded = false
            }
        }
        if cleanupSucceeded,
           state.outputMMapFileName != canonicalFileName,
           let oldOutputURL = try? containedWorkingURL(relativePath: state.outputMMapFileName, jobID: jobID) {
            do {
                try FileManager.default.removeItem(at: oldOutputURL)
            } catch {
                cleanupSucceeded = false
            }
        }
        // Journal sidecars describe the old frontier; the committed canonical checkpoint already covers
        // every tile, so retiring them is safe even when canvas cleanup failed.
        _ = try? undoJournal.removeAllJournalFiles(jobID: jobID)
        try? fsyncWorkingDirectory()

        let reopened = try MMapBuffer(
            fileURL: canonicalURL,
            width: plan.outputWidth,
            height: plan.outputHeight,
            createIfMissing: false
        )
        return NormalizationMigrationResult(checkpoint: migratedCheckpoint, outputBuffer: reopened)
    }

    /// Honors a pause request (or the deterministic pause-after-tile test trigger) between rebuilt
    /// tiles. The old durable state is left untouched, so the migration simply retries next launch.
    private func throwIfMigrationPaused(
        state: JobCheckpointState,
        rebuiltTiles: Int,
        totalTiles: Int,
        jobID: UUID,
        executionOwner: ExecutionPauseOwner?,
        progressHandler: (@Sendable (PipelineProgressUpdate) -> Void)?
    ) throws {
        discardStalePauseIfAny(for: executionOwner)
        let triggerReached: Bool
        if let trigger = pauseAfterCompletedTileIndex {
            triggerReached = rebuiltTiles > 0 && rebuiltTiles - 1 >= trigger
        } else {
            triggerReached = false
        }
        let pauseApplies = pauseRequested
            && (pauseRequestedByOwner == nil || pauseRequestedByOwner == executionOwner)
        guard pauseApplies || triggerReached else { return }

        if pauseApplies {
            pauseRequested = false
            pauseRequestedByOwner = nil
        }
        pauseAfterCompletedTileIndex = nil
        signalStableBoundary(for: executionOwner)
        let completed = max(0, min(state.lastCompletedTileIndex + 1, totalTiles))
        progressHandler?(
            PipelineProgressUpdate(
                jobID: jobID,
                stage: .pausedOnDisk,
                completedTiles: completed,
                totalTiles: totalTiles,
                overallFraction: overallFraction(completed: completed, total: totalTiles),
                estimatedSecondsRemaining: nil,
                currentTileDescriptor: nil,
                phase: .paused,
                sourceWidth: state.sourceWidth,
                sourceHeight: state.sourceHeight,
                outputWidth: state.outputWidth,
                outputHeight: state.outputHeight,
                requestedCompute: requestedComputePolicy.description(for: try CoreMLModelIdentifier.superResolver(
                    backbone: state.config.backbone, tier: state.tileConfig.tier), registry: modelRegistry),
                didRunDenoise: state.didRunDenoise
            )
        )
        throw ScalerError.jobPausedForBackgroundExpiration(completedTileIndex: state.lastCompletedTileIndex)
    }

    /// Removes disposable artifacts from an interrupted migration: the unique temp canvases and a
    /// canonical canvas that the durable checkpoint does not reference yet.
    private func removeOrphanedMigrationArtifacts(
        jobID: UUID,
        canonicalURL: URL,
        legacyOutputFileName: String
    ) {
        let prefix = "output_\(jobID.uuidString)_norm2."
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: workingDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            guard (try? PathSafety.assertContained(entry, in: workingDirectory)) != nil else { continue }
            let name = entry.lastPathComponent
            let isTempCanvas = name.hasPrefix(prefix) && name.hasSuffix(".tmp.rgba16f.bin")
            let isUncommittedCanonical = name.hasPrefix(prefix)
                && entry.standardizedFileURL == canonicalURL.standardizedFileURL
                && name != legacyOutputFileName
            guard isTempCanvas || isUncommittedCanonical else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Retires the deterministic pre-migration output after a crash that happened between the norm-2
    /// checkpoint commit and the legacy-output cleanup. Only the canonical norm-2 state may call this.
    private func removeLegacyOutputIfOrphaned(state: JobCheckpointState, jobID: UUID) {
        guard state.outputMMapFileName == legacyMigrationCanonicalFileName(jobID: jobID) else { return }
        let legacyFileName = "output_\(jobID.uuidString).rgba16f.bin"
        guard legacyFileName != state.outputMMapFileName,
              let legacyOutputURL = try? containedWorkingURL(relativePath: legacyFileName, jobID: jobID),
              legacyOutputURL.standardizedFileURL
                != (try? containedWorkingURL(relativePath: state.sourceMMapFileName, jobID: jobID))?
                    .standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: legacyOutputURL)
    }

    /// Makes a completed rename/unlink durable by `fsync`ing the working directory itself.
    private func fsyncWorkingDirectory() throws {
        let directoryFD = Darwin.open(workingDirectory.path, O_RDONLY)
        guard directoryFD >= 0 else {
            throw ScalerError.mmapSyncFailed(errno: errno)
        }
        defer { _ = Darwin.close(directoryFD) }
        guard Darwin.fsync(directoryFD) == 0 else {
            throw ScalerError.mmapSyncFailed(errno: errno)
        }
    }

    /// Streams the mapped RGBA16F source canvas (row by row, bounded memory) to derive the true
    /// maximum nonnegative R/G/B component. All geometry arithmetic is checked before iteration so a
    /// corrupt checkpoint can never trap here.
    private func rescanGlobalMaxLinearComponent(
        from sourceBuffer: MMapBuffer,
        checkpointURL: URL
    ) throws -> Float {
        _ = try checkedElementCount(
            width: sourceBuffer.width,
            height: sourceBuffer.height,
            components: 4,
            checkpointURL: checkpointURL
        )
        let (minimumRowBytes, minimumRowOverflow) = sourceBuffer.width.multipliedReportingOverflow(by: 8)
        guard !minimumRowOverflow, sourceBuffer.rowBytes >= minimumRowBytes else {
            throw ScalerError.checkpointCorrupted(checkpointURL)
        }

        var maximum: Float = 1.0
        for row in 0..<sourceBuffer.height {
            let rowPointer = sourceBuffer
                .unsafeRowPointer(y: row)
                .assumingMemoryBound(to: Float16.self)
            for column in 0..<sourceBuffer.width {
                let pixel = rowPointer + column * 4
                for channel in 0..<3 {
                    let value = Float(pixel[channel])
                    if value.isFinite && value > maximum {
                        // Match the decoder's saturation clamp so a pathological pixel cannot make
                        // the persisted denominator non-finite or absurdly large.
                        maximum = min(value, 65_500.0)
                    }
                }
            }
        }
        return maximum
    }

    private func checkedElementCount(
        width: Int,
        height: Int,
        components: Int,
        checkpointURL: URL
    ) throws -> Int {
        guard width > 0, height > 0, components > 0 else {
            throw ScalerError.checkpointCorrupted(checkpointURL)
        }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (elementCount, elementOverflow) = pixelCount.multipliedReportingOverflow(by: components)
        guard !pixelOverflow, !elementOverflow else {
            throw ScalerError.checkpointCorrupted(checkpointURL)
        }
        return elementCount
    }

    private func validateResumeCheckpoint(
        _ state: JobCheckpointState,
        checkpointURL: URL,
        sourceURL: URL,
        outputURL: URL,
        metadataURL: URL
    ) throws {
        let scale = state.config.scaleFactor.rawValue
        guard state.jobID == state.config.id,
              state.sourceWidth > 0, state.sourceHeight > 0,
              state.sourceWidth <= Int.max / scale, state.sourceHeight <= Int.max / scale,
              state.outputWidth == state.sourceWidth * scale,
              state.outputHeight == state.sourceHeight * scale,
              state.tileConfig == TileConfiguration(tier: state.tileConfig.tier, backbone: state.config.backbone),
              state.totalTiles > 0,
              state.lastCompletedTileIndex >= -1,
              state.lastCompletedTileIndex < state.totalTiles,
              state.globalMaxLuminance.isFinite, state.globalMaxLuminance >= 1,
              state.globalMaxLinearComponent.isFinite, state.globalMaxLinearComponent >= 1,
              state.transactionJournalVersion == JobCheckpointState.currentTransactionJournalVersion,
              state.alphaCurveConstant.isFinite, state.alphaCurveConstant > 0,
              Set([sourceURL.standardizedFileURL.path, outputURL.standardizedFileURL.path,
                   metadataURL.standardizedFileURL.path, checkpointURL.standardizedFileURL.path]).count == 4 else {
            throw ScalerError.checkpointCorrupted(checkpointURL)
        }

        // Reject a truncated/oversized sidecar before opening it: the strict `MMapBuffer` reopen would
        // throw anyway, but this reports `checkpointCorrupted` and never touches the original file.
        for (url, width, height) in [(sourceURL, state.sourceWidth, state.sourceHeight),
                                    (outputURL, state.outputWidth, state.outputHeight)] {
            guard width <= (Int.max - 63) / 8 else {
                throw ScalerError.checkpointCorrupted(checkpointURL)
            }
            let rowBytes = ((width * 8 + 63) / 64) * 64
            guard height <= Int.max / rowBytes else {
                throw ScalerError.checkpointCorrupted(checkpointURL)
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ScalerError.fileNotFound(url)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.int64Value == Int64(rowBytes * height) else {
                throw ScalerError.checkpointCorrupted(checkpointURL)
            }
        }
    }

    /// Owner an unscoped Stop/reset request must bind to. A single active execution wins: its own tile
    /// loop must observe the pause and answer the waiter. When idle, the current registered run is a
    /// legitimate pre-executor-entry Stop/reset target. `nil` means no single run can be identified.
    private func unscopedPauseBindingOwner() -> ExecutionPauseOwner? {
        if activeExecutionCount > 0 {
            let activeOwners: [ExecutionPauseOwner] = activeExecutionOwnerCounts.compactMap { entry in
                guard entry.value > 0, let owner = entry.key else { return nil }
                return owner
            }
            return activeOwners.count == 1 ? activeOwners[0] : nil
        }
        return currentRunOwner
    }

    /// Binds the single queued pause to `owner` (`nil` = explicit unscoped Stop/test request). A pause
    /// queued by a different scoped run is stale by definition: discard it and answer its waiter
    /// `false` so a superseded caller can never influence the replacement run.
    private func bindPauseRequest(to owner: ExecutionPauseOwner?) {
        if pauseRequested, pauseRequestedByOwner != owner {
            if let staleOwner = pauseRequestedByOwner {
                resumeWaiters(for: staleOwner, returning: false)
            }
        }
        pauseRequested = true
        pauseRequestedByOwner = owner
    }

    /// Retires a queued pause that belongs to no registered run (an unscoped idle/direct marker) or to
    /// the outgoing run when a newer distinct owner registers. Scoped waiters for the retired owner are
    /// answered `false`; the replacement run's own pause is never touched.
    private func retireQueuedPauseForNewRegistration() {
        guard pauseRequested else { return }
        if let queuedOwner = pauseRequestedByOwner {
            resumeWaiters(for: queuedOwner, returning: false)
        } else {
            resumeWaiters(for: nil, returning: false)
        }
        pauseRequested = false
        pauseRequestedByOwner = nil
    }

    /// Resolves the owner of an execution that is about to start. A coordinator registration made
    /// before `executeOrResumeJob` wins when it names the same job. A current registered run for a
    /// *different* job is a safe refusal: the execution must never be attributed to another job's
    /// lifecycle (which could consume its pause or answer its boundary waiters), and the refusal happens
    /// before any active-count or filesystem side effect. Direct (unregistered) execution installs a
    /// generation-0 owner only when there is no registration yet or a previous generation-0 owner is
    /// left over; it can never overwrite a coordinator's newer registration.
    private func resolveExecutionOwner(for jobID: UUID) throws -> ExecutionPauseOwner? {
        if let current = currentRunOwner {
            if current.jobID == jobID {
                return current
            }
            guard current.generation == 0 else {
                throw ScalerError.executionOwnerMismatch(
                    submittedJobID: jobID,
                    registeredJobID: current.jobID
                )
            }
        }
        let direct = ExecutionPauseOwner(jobID: jobID, generation: 0)
        currentRunOwner = direct
        return direct
    }

    /// Signals a stable boundary for the execution that reached it: its own scoped waiters plus any
    /// unscoped Stop/test waiter. A waiter for a newer run that has not started yet stays queued.
    private func signalStableBoundary(for executionOwner: ExecutionPauseOwner?) {
        resumeWaiters(for: executionOwner, returning: true)
        if executionOwner != nil {
            resumeWaiters(for: nil, returning: true)
        }
    }

    /// Answers only the waiters belonging to `owner` (`nil` = the unscoped Stop/test waiter).
    private func resumeWaiters(for owner: ExecutionPauseOwner?, returning result: Bool) {
        var remaining: [StableBoundaryWaiter] = []
        var answered: [StableBoundaryWaiter] = []
        for waiter in stableBoundaryWaiters {
            if waiter.owner == owner {
                answered.append(waiter)
            } else {
                remaining.append(waiter)
            }
        }
        stableBoundaryWaiters = remaining
        for waiter in answered {
            waiter.continuation.resume(returning: result)
        }
    }

    /// Discards a queued scoped pause that belongs to neither this execution nor the current registered
    /// run. A pause owned by the current replacement run is left untouched (and ignored by this
    /// execution); an unscoped Stop/test pause is always left for execution.
    private func discardStalePauseIfAny(for executionOwner: ExecutionPauseOwner?) {
        guard pauseRequested, let queuedOwner = pauseRequestedByOwner else { return }
        guard queuedOwner != executionOwner, queuedOwner != currentRunOwner else { return }
        pauseRequested = false
        pauseRequestedByOwner = nil
        resumeWaiters(for: queuedOwner, returning: false)
    }

    /// Execution startup must not inherit a pause queued by a run that is not this execution. An
    /// unscoped Stop/test pause (`pauseRequestedByOwner == nil`) is preserved, as is the current run's
    /// own legitimate pause (including one armed before its first tile).
    private func discardStalePauseAtExecutionStart(for executionOwner: ExecutionPauseOwner?) {
        discardStalePauseIfAny(for: executionOwner)
    }

    /// Derives each tile's exact clipped output rectangle from the plan. Journals are validated
    /// against these rectangles, never against the journal's self-declared geometry alone.
    private func makeJournalRects(
        for plan: TileGridPlan,
        checkpointURL: URL
    ) throws -> [Int: TileJournalRect] {
        var rects: [Int: TileJournalRect] = [:]
        rects.reserveCapacity(plan.tiles.count)
        for tile in plan.tiles {
            guard let rect = TileJournalRect.clipped(
                destX: tile.outputOriginX,
                destY: tile.outputOriginY,
                size: tile.outputSize,
                canvasWidth: plan.outputWidth,
                canvasHeight: plan.outputHeight
            ) else {
                throw ScalerError.checkpointCorrupted(checkpointURL)
            }
            rects[tile.tileIndex] = rect
        }
        return rects
    }

    private func overallFraction(completed: Int, total: Int) -> Double {        guard total > 0 else { return 1.0 }
        return 0.10 + 0.90 * (Double(max(0, min(completed, total))) / Double(total))
    }

    private func containedWorkingURL(relativePath: String, jobID: UUID) throws -> URL {
        do {
            return try PathSafety.childURL(in: workingDirectory, relativePath: relativePath)
        } catch {
            let checkpointURL = workingDirectory.appendingPathComponent("checkpoint_\(jobID.uuidString).json")
            throw ScalerError.checkpointCorrupted(checkpointURL)
        }
    }

    private func loadMetadata(from metadataURL: URL, checkpointFileURL: URL) throws -> ImageMetadataPacket {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw ScalerError.fileNotFound(metadataURL)
        }
        do {
            let data = try Data(contentsOf: metadataURL)
            return try JSONDecoder().decode(ImageMetadataPacket.self, from: data)
        } catch {
            throw ScalerError.checkpointCorrupted(checkpointFileURL)
        }
    }

    private func writeMetadata(_ metadata: ImageMetadataPacket, to metadataURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }
}
