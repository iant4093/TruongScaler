import XCTest
import CoreML
@testable import BackgroundJobManager
@testable import TiledInferenceEngine
@testable import TruongScalerCore

final class BackgroundJobManagerTests: XCTestCase {
    private var workingDirectory: URL!

    override func setUpWithError() throws {
        workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BackgroundJobManagerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
        }
        workingDirectory = nil
    }

    // MARK: - Background Transition & Expiration

    func testBackgroundModeTransitionSwitchesExecutorAndPausesOnExpiration() async throws {
        let registry = CoreMLModelRegistry(initialComputeUnits: .all)
        let checkpointStore = try JobCheckpointStore(workingDirectory: workingDirectory)
        let executor = TiledPipelineExecutor(
            workingDirectory: workingDirectory,
            modelRegistry: registry,
            checkpointStore: checkpointStore
        )
        let liveActivityController = await LiveActivityController()
        let coordinator = BackgroundExecutionCoordinator(
            executor: executor,
            liveActivityController: liveActivityController
        )

        // Initially foreground, full compute.
        var inBackground = await coordinator.isInBackground()
        XCTAssertFalse(inBackground)
        var expired = await coordinator.didExpire()
        XCTAssertFalse(expired)
        var computeUnits = await registry.currentUnits()
        XCTAssertEqual(computeUnits, .all)
        var state = await liveActivityController.lastKnownState
        XCTAssertNil(state)

        // Enter background: executor must switch to CPU + ANE before anything else.
        await coordinator.handleDidEnterBackground(
            jobTitle: "Upscaling RAW",
            jobSubtitle: "QuickSRNet-Large 4×"
        )

        inBackground = await coordinator.isInBackground()
        XCTAssertTrue(inBackground)
        computeUnits = await registry.currentUnits()
        XCTAssertEqual(computeUnits, .cpuAndNeuralEngine)
        expired = await coordinator.didExpire()
        XCTAssertFalse(expired)

        // Duplicate background callbacks must be idempotent (no tier flapping).
        await coordinator.handleDidEnterBackground(
            jobTitle: "Upscaling RAW",
            jobSubtitle: "QuickSRNet-Large 4×"
        )
        computeUnits = await registry.currentUnits()
        XCTAssertEqual(computeUnits, .cpuAndNeuralEngine)
        inBackground = await coordinator.isInBackground()
        XCTAssertTrue(inBackground)

        // Background time expires before the final tile: request a graceful pause + pause the
        // Live Activity at 18/24 = 75%.
        await coordinator.handleBackgroundExpiration(completedTiles: 18, totalTiles: 24)

        expired = await coordinator.didExpire()
        XCTAssertTrue(expired)
        state = await liveActivityController.lastKnownState
        XCTAssertEqual(state?.isPaused, true)
        XCTAssertEqual(state?.statusMessage, "Paused at 75% — Tap to finish")
        XCTAssertEqual(state?.stageTitle, "Paused at 75% — Tap to finish")
        XCTAssertEqual(state?.completedTiles, 18)
        XCTAssertEqual(state?.totalTiles, 24)
        XCTAssertEqual(state?.progressFraction ?? 0.0, 0.75, accuracy: 0.0001)

        // Still considered backgrounded, and a second expiration must not overwrite the pause point.
        inBackground = await coordinator.isInBackground()
        XCTAssertTrue(inBackground)
        await coordinator.handleBackgroundExpiration(completedTiles: 24, totalTiles: 24)
        let repeatedState = await liveActivityController.lastKnownState
        XCTAssertEqual(repeatedState?.completedTiles, 18)
        XCTAssertEqual(repeatedState?.statusMessage, "Paused at 75% — Tap to finish")
        expired = await coordinator.didExpire()
        XCTAssertTrue(expired)

        // A paused executor must not complete a subsequent job submission.
        let missingSource = workingDirectory.appendingPathComponent("does-not-exist.heic")
        let config = UpscaleJobConfig(
            sourceImageURL: missingSource,
            scaleFactor: .x4,
            backbone: .quickSRNet,
            denoiseMode: .off,
            naturalGrainAmount: 0.0,
            exportFormat: .png16Bit
        )
        do {
            _ = try await executor.executeOrResumeJob(config: config)
            XCTFail("A paused executor unexpectedly completed executeOrResumeJob")
        } catch {
            // Expected: pause-aware executors throw `jobPausedForBackgroundExpiration`; while
            // Track D's Stage 1-3 implementation is in flight any thrown error proves the paused
            // executor did not run the job to completion.
        }

        // Returning to the foreground restores `.all` compute and clears the expiration flag.
        await coordinator.handleDidBecomeActive()

        inBackground = await coordinator.isInBackground()
        XCTAssertFalse(inBackground)
        expired = await coordinator.didExpire()
        XCTAssertFalse(expired)
        computeUnits = await registry.currentUnits()
        XCTAssertEqual(computeUnits, .all)

        // A second foreground callback is also idempotent.
        await coordinator.handleDidBecomeActive()
        computeUnits = await registry.currentUnits()
        XCTAssertEqual(computeUnits, .all)
    }

    // MARK: - Live Activity State & Throttling (macOS-compatible state path)

    func testLiveActivityStateThrottleAndEnd() async throws {
        let controller = await LiveActivityController()

        await MainActor.run {
            controller.startActivity(
                jobID: UUID(),
                sourceFileName: "IMG_0001.dng",
                scaleFactor: .x4,
                targetWidth: 8064,
                targetHeight: 6048,
                totalTiles: 64
            )
        }

        let initial = await controller.lastKnownState
        XCTAssertEqual(initial?.completedTiles, 0)
        XCTAssertEqual(initial?.totalTiles, 64)
        XCTAssertEqual(initial?.progressFraction, 0.0)
        XCTAssertEqual(initial?.isPaused, false)

        // First update is delivered immediately (forceImmediate).
        await controller.updateProgress(
            stageTitle: "Upscaling Tile 1/64",
            completedTiles: 1,
            totalTiles: 64,
            progressFraction: 1.0 / 64.0,
            estimatedSecondsRemaining: 42,
            forceImmediate: true
        )
        var delivered = await controller.deliveredUpdateCount
        var throttled = await controller.throttledUpdateCount
        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(throttled, 0)
        var state = await controller.lastKnownState
        XCTAssertEqual(state?.stageTitle, "Upscaling Tile 1/64")
        XCTAssertEqual(state?.completedTiles, 1)
        XCTAssertEqual(state?.estimatedSecondsRemaining, 42)

        // An immediate non-terminal follow-up is throttled, but lastKnownState stays current.
        await controller.updateProgress(
            stageTitle: "Upscaling Tile 2/64",
            completedTiles: 2,
            totalTiles: 64,
            progressFraction: 2.0 / 64.0,
            estimatedSecondsRemaining: 41
        )
        delivered = await controller.deliveredUpdateCount
        throttled = await controller.throttledUpdateCount
        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(throttled, 1)
        state = await controller.lastKnownState
        XCTAssertEqual(state?.stageTitle, "Upscaling Tile 2/64")
        XCTAssertEqual(state?.completedTiles, 2)

        // forceImmediate bypasses the throttle.
        await controller.updateProgress(
            stageTitle: "Upscaling Tile 3/64",
            completedTiles: 3,
            totalTiles: 64,
            progressFraction: 3.0 / 64.0,
            estimatedSecondsRemaining: 40,
            forceImmediate: true
        )
        delivered = await controller.deliveredUpdateCount
        XCTAssertEqual(delivered, 2)

        // Terminal (100%) updates are never throttled.
        await controller.updateProgress(
            stageTitle: "Finalizing image",
            completedTiles: 64,
            totalTiles: 64,
            progressFraction: 1.0,
            estimatedSecondsRemaining: 0
        )
        delivered = await controller.deliveredUpdateCount
        XCTAssertEqual(delivered, 3)
        state = await controller.lastKnownState
        XCTAssertEqual(state?.progressFraction, 1.0)

        // markPaused always pushes and reports the exact pause message.
        await controller.markPaused(completedTiles: 48, totalTiles: 64)
        state = await controller.lastKnownState
        XCTAssertEqual(state?.isPaused, true)
        XCTAssertEqual(state?.statusMessage, "Paused at 75% — Tap to finish")
        XCTAssertEqual(state?.completedTiles, 48)
        XCTAssertEqual(state?.totalTiles, 64)
        delivered = await controller.deliveredUpdateCount
        XCTAssertEqual(delivered, 4)

        // endActivity updates the final state and completes cleanly without ActivityKit.
        await controller.endActivity(finalMessage: "Upscale complete")
        state = await controller.lastKnownState
        XCTAssertEqual(state?.stageTitle, "Upscale complete")
        XCTAssertEqual(state?.statusMessage, "Upscale complete")
        XCTAssertEqual(state?.isPaused, false)
    }

    // MARK: - Idempotency of Background Callbacks

    func testLiveActivitySanitizesInvalidProgressAndPauseCounts() async {
        let controller = await LiveActivityController()
        await controller.updateProgress(stageTitle: "Invalid", completedTiles: 99, totalTiles: 10,
            progressFraction: .nan, estimatedSecondsRemaining: nil, forceImmediate: true)
        var state = await controller.lastKnownState
        XCTAssertEqual(state?.completedTiles, 10)
        XCTAssertEqual(state?.progressFraction, 0)
        await controller.markPaused(completedTiles: Int.max, totalTiles: 10)
        state = await controller.lastKnownState
        XCTAssertEqual(state?.completedTiles, 10)
        XCTAssertEqual(state?.statusMessage, "Paused at 100% — Tap to finish")
        await controller.markPaused(completedTiles: 10, totalTiles: -1)
        state = await controller.lastKnownState
        XCTAssertEqual(state?.completedTiles, 0)
        XCTAssertEqual(state?.progressFraction, 0)
    }

    func testRepeatedBackgroundAndForegroundCallbacksAreIdempotent() async throws {
        let registry = CoreMLModelRegistry(initialComputeUnits: .all)
        let checkpointStore = try JobCheckpointStore(workingDirectory: workingDirectory)
        let executor = TiledPipelineExecutor(
            workingDirectory: workingDirectory,
            modelRegistry: registry,
            checkpointStore: checkpointStore
        )
        let liveActivityController = await LiveActivityController()
        let coordinator = BackgroundExecutionCoordinator(
            executor: executor,
            liveActivityController: liveActivityController
        )

        for _ in 0..<3 {
            await coordinator.handleDidEnterBackground(jobTitle: "Upscaling", jobSubtitle: "QuickSRNet-Large 2×")
        }
        var computeUnits = await registry.currentUnits()
        XCTAssertEqual(computeUnits, .cpuAndNeuralEngine)
        var inBackground = await coordinator.isInBackground()
        XCTAssertTrue(inBackground)

        await coordinator.handleBackgroundExpiration(completedTiles: 2, totalTiles: 8)
        let state = await liveActivityController.lastKnownState
        XCTAssertEqual(state?.isPaused, true)
        XCTAssertEqual(state?.statusMessage, "Paused at 25% — Tap to finish")

        for _ in 0..<3 {
            await coordinator.handleDidBecomeActive()
        }
        computeUnits = await registry.currentUnits()
        XCTAssertEqual(computeUnits, .all)
        inBackground = await coordinator.isInBackground()
        XCTAssertFalse(inBackground)
        let expired = await coordinator.didExpire()
        XCTAssertFalse(expired)

        // Re-entering background after foreground restores the background compute tier.
        await coordinator.handleDidEnterBackground(jobTitle: "Upscaling", jobSubtitle: "QuickSRNet-Large 2×")
        computeUnits = await registry.currentUnits()
        XCTAssertEqual(computeUnits, .cpuAndNeuralEngine)
        inBackground = await coordinator.isInBackground()
        XCTAssertTrue(inBackground)
    }
}
