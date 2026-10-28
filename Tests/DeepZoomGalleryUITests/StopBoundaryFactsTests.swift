import XCTest
import Foundation
import TruongScalerCore
import MMapCanvas
import TiledInferenceEngine
import BackgroundJobManager
@testable import DeepZoomGalleryUI

/// App-level SR-only contract tests. Denoising belongs to TruongNoiser; Scaler must construct every
/// production job with `denoiseMode == .off`, never invoke the retired denoise stage, and never relabel legacy artifacts.
@MainActor
final class StopBoundaryFactsTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScalerSRPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        tempDirectory = nil
        try await super.tearDown()
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try Data([0x01, 0x02]).write(to: url)
        return url
    }

    private func makeViewModel(
        decoder: any StudioImageDecoding = FakeDecoder(),
        pipeline: any StudioPipelineExecuting
    ) -> StudioViewModel {
        let registry = CoreMLModelRegistry(initialComputeUnits: .all)
        let store = JobCheckpointStore(directory: tempDirectory)
        let executor = TiledPipelineExecutor(
            workingDirectory: tempDirectory,
            modelRegistry: registry,
            checkpointStore: store
        )
        return StudioViewModel(
            workingDirectory: tempDirectory,
            pipelineExecutor: executor,
            pipeline: pipeline,
            decoder: decoder,
            exporter: FakeExporter(),
            scanner: FakeScanner(),
            thumbnailReader: ImageIOThumbnailReader(),
            handoffManager: FakeHandoffManager(),
            externalOpener: RecordingOpener(),
            scopeProvider: RecordingScopeProvider(),
            backgroundTaskRouter: BackgroundTaskDeliveryRouter()
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }


    func testStopTerminalRetainsTheTileCommittedWhileItWasDraining() async throws {
        let pipeline = ReviewBoundaryPipeline()
        let model = makeViewModel(pipeline: pipeline)
        await model.ingestFile(at: try makeFile("synthetic-stop.jpg"))
        model.startProcessing()
        await pipeline.started.wait()
        pipeline.publish(completed: 1, phase: .predictingSuperResolution)
        let began = await waitUntil { model.latestProgress?.completedTiles == 1 }
        XCTAssertTrue(began)
        model.cancelProcessing()
        await pipeline.pauseGate.entered.wait()
        pipeline.publish(completed: 2, phase: .tileCommitted)
        pipeline.publish(completed: 2, phase: .paused)
        let committedWhileDraining = await waitUntil { model.latestProgress?.completedTiles == 2 && model.latestProgress?.phase == .paused }
        XCTAssertTrue(committedWhileDraining)
        XCTAssertTrue(model.isStopping)
        XCTAssertEqual(model.jobProgress.completedTiles, 2)
        pipeline.pauseGate.open()
        let stopped = await waitUntil { !model.isProcessing }
        XCTAssertTrue(stopped)
        print("REVIEW_STOP_FRONTIER latest=\(String(describing:model.latestProgress?.completedTiles)) public=\(model.completedTiles) total=\(model.totalTiles)")
        XCTAssertEqual(model.latestProgress?.phase, .paused)
        XCTAssertEqual(model.latestProgress?.completedTiles, 2, "The authoritative paused state must retain the final durable tile committed during Stop drain")
        XCTAssertEqual(model.completedTiles, 2, "Public count must agree with the durable frontier, not the count at the instant Stop was tapped")
    }

    func testQueuedFinalDurableProgressAfterStopStillRaisesPausedFrontier() async throws {
        let pipeline = ReviewBoundaryPipeline()
        let model = makeViewModel(pipeline: pipeline)
        await model.ingestFile(at: try makeFile("synthetic-stop-queued.jpg"))
        model.startProcessing()
        await pipeline.started.wait()
        pipeline.publish(completed: 1, phase: .predictingSuperResolution)
        _ = await waitUntil { model.latestProgress?.completedTiles == 1 }
        model.cancelProcessing()
        await pipeline.pauseGate.entered.wait()
        pipeline.publish(completed: 2, phase: .paused)
        _ = await waitUntil { model.latestProgress?.completedTiles == 2 }
        pipeline.pauseGate.open()
        _ = await waitUntil { !model.isProcessing }
        XCTAssertEqual(model.latestProgress?.phase, .paused)

        // The final durable commit was queued behind the terminal delivery. It is a genuine owned
        // fact, not a stale phase callback, so the paused terminal must advance without changing phase.
        pipeline.publish(completed: 3, phase: .tileCommitted)
        let merged = await waitUntil {
            model.latestProgress?.completedTiles == 3 && model.latestProgress?.phase == .paused
        }
        XCTAssertTrue(merged)
        XCTAssertEqual(model.completedTiles, 3)
        XCTAssertEqual(model.jobProgress.completedTiles, 3)
        XCTAssertEqual(model.jobProgress.phase, .paused)
    }
}

private final class ReviewBoundaryPipeline: StudioPipelineExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (PipelineProgressUpdate) -> Void)?
    private var jobID = UUID()
    let started = TestSignal()
    let executeGate = CancellableGate()
    let pauseGate = TestGate()
    func executeOrResumeJob(config: UpscaleJobConfig, progressHandler: (@Sendable (PipelineProgressUpdate) -> Void)?) async throws -> CompletedPipelineArtifacts {
        lock.withLock { jobID = config.id; handler = progressHandler }
        started.signal()
        await executeGate.wait()
        throw CancellationError()
    }
    func requestGracefulPauseAndWait() async { await pauseGate.hold() }
    func clearPauseRequest() async {}
    func publish(completed: Int, phase: PipelinePhase) {
        let captured = lock.withLock { (jobID, handler) }
        captured.1?(PipelineProgressUpdate(jobID: captured.0, stage: phase == .paused ? .pausedOnDisk : .denoisingAndUpscalingTiles, completedTiles: completed, totalTiles: 4, overallFraction: 0.1 + 0.9 * Double(completed)/4, estimatedSecondsRemaining: nil, phase: phase, currentTileIndex: phase == .paused ? nil : (phase == .tileCommitted ? max(0, completed - 1) : completed), elapsedSeconds: 10, sourceWidth: 8, sourceHeight: 6, outputWidth: 32, outputHeight: 24, modelName: "QuickSRNet_Large_x2_192", didRunDenoise: false))
    }
}
