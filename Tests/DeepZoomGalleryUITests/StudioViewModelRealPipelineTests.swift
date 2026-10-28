import XCTest
import Foundation
import CoreML
import TruongScalerCore
import CoreIngestion
import TiledInferenceEngine
import BackgroundJobManager
@testable import DeepZoomGalleryUI

/// Production-chain Reset/Stop → select → Start coverage (E1).
///
/// These tests intentionally drive the **real** `StudioViewModel` execution path:
/// * `TiledExecutorPipelineAdapter` over a real, stateful `TiledPipelineExecutor`;
/// * one explicit deterministic-fallback model registry
///   (`initialComputeUnits: .cpuOnly, availabilityPolicy: .allowDeterministicFallback`);
/// * `BlockingStudioImageDecoder` reading a real ImageIO-encoded PNG from the test temporary
///   directory into a real mmap source.
///
/// No stateless `FakePipelineExecutor` participates in pause ownership here, and the tests never
/// invoke a foreground scene-phase transition or a manual `clearPauseRequest`. A stale unscoped
/// Reset/Stop pause therefore has to be retired by the executor's job-run registration itself for
/// these runs to reach their completed artifact.
final class StudioViewModelRealPipelineTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StudioViewModelRealPipelineTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    // MARK: - Harness

    /// One real executor shared by the view model's coordinator registration and the execution
    /// adapter (exactly like the production initializer), so pause ownership is the real stateful
    /// executor's, not a seam.
    @MainActor
    private func makeRealPipelineViewModel(
        scopeProvider: RecordingScopeProvider = RecordingScopeProvider()
    ) -> StudioViewModel {
        let registry = CoreMLModelRegistry(
            initialComputeUnits: .cpuOnly,
            availabilityPolicy: .allowDeterministicFallback
        )
        let checkpointStore = JobCheckpointStore(directory: tempDirectory)
        let executor = TiledPipelineExecutor(
            workingDirectory: tempDirectory,
            modelRegistry: registry,
            checkpointStore: checkpointStore
        )
        return StudioViewModel(
            workingDirectory: tempDirectory,
            pipelineExecutor: executor,
            pipeline: TiledExecutorPipelineAdapter(executor: executor),
            decoder: BlockingStudioImageDecoder(),
            exporter: FakeExporter(),
            scanner: FakeScanner(),
            thumbnailReader: ImageIOThumbnailReader(),
            handoffManager: FakeHandoffManager(),
            externalOpener: RecordingOpener(),
            scopeProvider: scopeProvider,
            backgroundTaskRouter: BackgroundTaskDeliveryRouter()
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 120.0,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Waits for a real run to reach any terminal state (success artifact, failure or paused-on-disk)
    /// and for its execution owner to be released, so a regression fails fast instead of burning the
    /// full timeout and a completed-state probe never races the owner's post-publish teardown.
    @MainActor
    private func waitForRealRunToSettle(
        _ viewModel: StudioViewModel,
        timeout: TimeInterval = 120.0
    ) async -> Bool {
        await waitUntil(timeout: timeout) {
            guard !viewModel.isProcessing,
                  !viewModel.isStopping,
                  viewModel.ownedExecutionCount == 0 else { return false }
            return viewModel.completedArtifacts != nil
                || viewModel.currentStage == .failed
                || viewModel.currentStage == .pausedOnDisk
        }
    }

    /// Asserts the real run completed and returned a real artifact for `source`.
    @MainActor
    @discardableResult
    private func assertRealRunCompleted(
        _ viewModel: StudioViewModel,
        expectedSource: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CompletedPipelineArtifacts {
        XCTAssertFalse(viewModel.isProcessing, "The execution owner must have returned", file: file, line: line)
        XCTAssertFalse(viewModel.isStopping, "No Stop/reset drain may remain", file: file, line: line)
        XCTAssertEqual(
            viewModel.currentStage,
            .readyForInspection,
            "Expected the real run to complete; pausedOnDisk would mean a stale pause stopped it "
                + "before tile 0 (stage=\(viewModel.currentStage.rawValue), "
                + "error=\(viewModel.errorMessage ?? "none"))",
            file: file,
            line: line
        )
        XCTAssertNotEqual(
            viewModel.currentStage,
            .pausedOnDisk,
            "A distinct new run must not inherit an old unscoped Reset/Stop pause",
            file: file,
            line: line
        )
        XCTAssertNil(viewModel.errorMessage, file: file, line: line)
        let artifacts = try XCTUnwrap(
            viewModel.completedArtifacts,
            "A successful real pipeline run must publish its completed artifact",
            file: file,
            line: line
        )
        XCTAssertEqual(
            artifacts.metadata.sourceURL.standardizedFileURL,
            expectedSource.standardizedFileURL,
            file: file,
            line: line
        )
        XCTAssertEqual(
            viewModel.outputBuffer?.width,
            artifacts.outputBuffer.width,
            "The published output buffer must be the completed artifact's",
            file: file,
            line: line
        )
        return artifacts
    }

    private func assertGrantsClosedExactlyOnce(
        _ scope: RecordingScopeProvider,
        for url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            scope.activeGrantCount(for: url),
            0,
            "Every grant for the replaced selection must be closed",
            file: file,
            line: line
        )
        XCTAssertEqual(
            scope.grants(for: url).filter { $0.releaseCallCount != 1 }.count,
            0,
            "Every grant for the replaced selection must be released exactly once",
            file: file,
            line: line
        )
        XCTAssertEqual(
            scope.uniqueGrantIdentifiers,
            scope.acquiredCount,
            "Each operation must own an independent grant",
            file: file,
            line: line
        )
    }

    // MARK: - E1: idle Reset → select → Start through the real pipeline

    @MainActor
    func testIdleResetThenNewSelectionRealPipelineRunReachesCompletedArtifact() async throws {
        let scope = RecordingScopeProvider()
        let viewModel = makeRealPipelineViewModel(scopeProvider: scope)
        let oldImage = try RealPipelineImageFixture.makePNG(
            in: tempDirectory,
            name: "real-idle-reset-old.png"
        )
        let newImage = try RealPipelineImageFixture.makePNG(
            in: tempDirectory,
            name: "real-idle-reset-new.png"
        )

        // Ingest a real image while idle: the old selection owns one live scope grant.
        await viewModel.ingestFile(at: oldImage)
        XCTAssertEqual(viewModel.sourceURL?.standardizedFileURL, oldImage.standardizedFileURL)
        XCTAssertNil(viewModel.completedArtifacts)
        XCTAssertEqual(scope.activeGrantCount(for: oldImage), 1)

        // The production Reset sequence that regressed: no execution is active, no foreground scene
        // transition occurs, and nothing ever calls `clearPauseRequest`.
        viewModel.resetSession()
        await viewModel.waitForResetToFinish()
        XCTAssertNil(viewModel.sourceURL)
        XCTAssertNil(viewModel.metadata)
        XCTAssertNil(viewModel.completedArtifacts)
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertFalse(viewModel.isStopping)
        assertGrantsClosedExactlyOnce(scope, for: oldImage)

        // Select a second real image; its selection grant must stay live through the new run.
        await viewModel.ingestFile(at: newImage)
        XCTAssertEqual(viewModel.sourceURL?.standardizedFileURL, newImage.standardizedFileURL)
        XCTAssertEqual(scope.activeGrantCount(for: newImage), 1)

        viewModel.startProcessing()
        let settled = await waitForRealRunToSettle(viewModel)
        XCTAssertTrue(settled, "The real pipeline run must settle")
        try assertRealRunCompleted(viewModel, expectedSource: newImage)

        // The reset must not own the new selection: its grant is still live after completion.
        XCTAssertGreaterThan(
            scope.activeGrantCount(for: newImage),
            0,
            "The new selection grant must remain live; Reset owns only the captured old selection"
        )
        assertGrantsClosedExactlyOnce(scope, for: oldImage)
        XCTAssertEqual(viewModel.ownedExecutionCount, 0)
        XCTAssertFalse(viewModel.isStopping)
    }

    @MainActor
    func testIdleResetBeforeAnyJobThenRealPipelineRunCompletes() async throws {
        let scope = RecordingScopeProvider()
        let viewModel = makeRealPipelineViewModel(scopeProvider: scope)
        let image = try RealPipelineImageFixture.makePNG(
            in: tempDirectory,
            name: "real-idle-reset-no-job.png"
        )

        // Reset with no selection and no job anywhere in the lifecycle.
        viewModel.resetSession()
        await viewModel.waitForResetToFinish()
        XCTAssertNil(viewModel.sourceURL)
        XCTAssertNil(viewModel.metadata)
        XCTAssertEqual(viewModel.currentStage, .idle)
        XCTAssertFalse(viewModel.isStopping)
        XCTAssertEqual(scope.acquiredCount, 0)

        await viewModel.ingestFile(at: image)
        XCTAssertEqual(scope.activeGrantCount(for: image), 1)
        viewModel.startProcessing()
        let settled = await waitForRealRunToSettle(viewModel)
        XCTAssertTrue(settled, "The real pipeline run must settle")
        try assertRealRunCompleted(viewModel, expectedSource: image)
        XCTAssertGreaterThan(scope.activeGrantCount(for: image), 0)
    }

    // MARK: - E1: Reset after completion → new run

    @MainActor
    func testResetAfterCompletedRealRunThenNewRunCompletes() async throws {
        let scope = RecordingScopeProvider()
        let viewModel = makeRealPipelineViewModel(scopeProvider: scope)
        let firstImage = try RealPipelineImageFixture.makePNG(
            in: tempDirectory,
            name: "real-after-completion-first.png"
        )
        let secondImage = try RealPipelineImageFixture.makePNG(
            in: tempDirectory,
            name: "real-after-completion-second.png"
        )

        await viewModel.ingestFile(at: firstImage)
        viewModel.startProcessing()
        let firstSettled = await waitForRealRunToSettle(viewModel)
        XCTAssertTrue(firstSettled)
        try assertRealRunCompleted(viewModel, expectedSource: firstImage)
        XCTAssertGreaterThan(scope.activeGrantCount(for: firstImage), 0)

        // Reset after the executor has already reached its completed boundary (the executor still
        // has a current registered run from the completed job).
        viewModel.resetSession()
        await viewModel.waitForResetToFinish()
        XCTAssertNil(viewModel.sourceURL)
        XCTAssertNil(viewModel.completedArtifacts)
        XCTAssertEqual(viewModel.currentStage, .idle)
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertFalse(viewModel.isStopping)
        assertGrantsClosedExactlyOnce(scope, for: firstImage)

        await viewModel.ingestFile(at: secondImage)
        viewModel.startProcessing()
        let settled = await waitForRealRunToSettle(viewModel)
        XCTAssertTrue(settled, "The replacement real pipeline run must settle")
        try assertRealRunCompleted(viewModel, expectedSource: secondImage)
        XCTAssertGreaterThan(
            scope.activeGrantCount(for: secondImage),
            0,
            "The replacement selection grant must remain live"
        )
        assertGrantsClosedExactlyOnce(scope, for: firstImage)
        XCTAssertEqual(viewModel.ownedExecutionCount, 0)
    }

    // MARK: - E1: Stop/reset before executor entry, then a new selection

    @MainActor
    func testResetImmediatelyAfterStartBeforeExecutorEntryThenNewSelectionCompletes() async throws {
        let scope = RecordingScopeProvider()
        let viewModel = makeRealPipelineViewModel(scopeProvider: scope)
        let staleImage = try RealPipelineImageFixture.makePNG(
            in: tempDirectory,
            name: "real-reset-before-entry.png"
        )
        let nextImage = try RealPipelineImageFixture.makePNG(
            in: tempDirectory,
            name: "real-reset-before-entry-next.png"
        )

        await viewModel.ingestFile(at: staleImage)
        viewModel.startProcessing()
        // No suspension between Start and Reset: the Reset's pause request races the coordinator
        // registration and the executor entry, which is exactly the "before executor entry" case.
        viewModel.resetSession()
        await viewModel.waitForResetToFinish()

        XCTAssertNil(viewModel.sourceURL)
        XCTAssertNil(viewModel.metadata)
        XCTAssertNil(viewModel.completedArtifacts)
        XCTAssertEqual(viewModel.currentStage, .idle)
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertFalse(viewModel.isStopping)
        XCTAssertEqual(viewModel.ownedExecutionCount, 0)
        assertGrantsClosedExactlyOnce(scope, for: staleImage)

        await viewModel.ingestFile(at: nextImage)
        viewModel.startProcessing()
        let settled = await waitForRealRunToSettle(viewModel)
        XCTAssertTrue(settled, "The replacement real pipeline run must settle")
        try assertRealRunCompleted(viewModel, expectedSource: nextImage)
        XCTAssertGreaterThan(scope.activeGrantCount(for: nextImage), 0)
    }

    @MainActor
    func testStopBeforeExecutorEntryDrainsThenNewSelectionRealRunCompletes() async throws {
        let scope = RecordingScopeProvider()
        let viewModel = makeRealPipelineViewModel(scopeProvider: scope)
        let staleImage = try RealPipelineImageFixture.makePNG(
            in: tempDirectory,
            name: "real-stop-before-entry.png"
        )
        let nextImage = try RealPipelineImageFixture.makePNG(
            in: tempDirectory,
            name: "real-stop-before-entry-next.png"
        )

        await viewModel.ingestFile(at: staleImage)
        viewModel.startProcessing()
        // Stop immediately, before the executor has entered the tile loop for this run.
        viewModel.cancelProcessing()
        XCTAssertTrue(viewModel.isProcessing)
        XCTAssertTrue(viewModel.isStopping)

        await viewModel.waitForStopToFinish()
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertFalse(viewModel.isStopping)
        XCTAssertEqual(viewModel.ownedExecutionCount, 0)

        // A new selection after the Stop drained must run to completion; the old Stop's unscoped
        // pause may not survive into this distinct run.
        await viewModel.ingestFile(at: nextImage)
        viewModel.startProcessing()
        let settled = await waitForRealRunToSettle(viewModel)
        XCTAssertTrue(settled, "The real pipeline run after Stop/drain must settle")
        try assertRealRunCompleted(viewModel, expectedSource: nextImage)
        XCTAssertGreaterThan(scope.activeGrantCount(for: nextImage), 0)
        XCTAssertFalse(viewModel.isStopping)
    }
}
