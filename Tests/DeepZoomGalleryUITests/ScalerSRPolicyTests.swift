import XCTest
import Foundation
import TruongScalerCore
import MMapCanvas
import CoreIngestion
import TiledInferenceEngine
import BackgroundJobManager
@testable import DeepZoomGalleryUI

private final class CancelFirstPhotoDecoder: StudioImageDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var first = true
    private let next = FakeDecoder()

    func decodeImage(at url: URL, destinationMMapURL: URL) async throws -> DecodedSourceResult {
        let cancel = lock.withLock { let result = first; first = false; return result }
        if cancel { throw CancellationError() }
        return try await next.decodeImage(at: url, destinationMMapURL: destinationMMapURL)
    }
}

/// App-level SR-only contract tests. Denoising belongs to TruongNoiser; Scaler must construct every
/// production job with `denoiseMode == .off`, never invoke the retired denoise stage, and never relabel legacy artifacts.
@MainActor
final class ScalerSRPolicyTests: XCTestCase {
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

    // MARK: - New jobs are SR-only

    func testStopKeepsOriginalPreviewAndAllowsOpeningAnotherPhoto() async throws {
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        let model = makeViewModel(pipeline: pipeline)
        await model.ingestFile(at: try makeFile("stop-original.dng"))
        let preview = try XCTUnwrap(model.sourceBuffer)
        model.startProcessing()
        let started = await waitUntil { pipeline.executionCount == 1 }
        XCTAssertTrue(started)
        model.cancelProcessing()
        let stopped = await waitUntil { !model.isProcessing && !model.isStopping }
        XCTAssertTrue(stopped)
        XCTAssertTrue(model.sourceBuffer === preview, "Stop must retain the readable original preview")
        XCTAssertNotNil(model.metadata)

        let other = try makeFile("after-stop.dng")
        await model.ingestFile(at: other)
        XCTAssertEqual(model.sourceURL, other)
        XCTAssertEqual(model.currentStage, .idle)
        XCTAssertNotNil(model.sourceBuffer)
        XCTAssertNotNil(model.metadata)
    }

    func testCancelledCurrentIngestIsRecoverableAndCanBeRetried() async throws {
        let model = makeViewModel(decoder: CancelFirstPhotoDecoder(),
                                  pipeline: FakePipelineExecutor(directory: tempDirectory))
        let photo = try makeFile("retry-after-cancel.dng")
        await model.ingestFile(at: photo)
        XCTAssertEqual(model.currentStage, .idle, "A cancelled decode must not stay in an opening state forever")
        XCTAssertNotNil(model.errorMessage)
        await model.ingestFile(at: photo)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.currentStage, .idle)
        XCTAssertNotNil(model.sourceBuffer)
        XCTAssertNotNil(model.metadata)
    }

    func testElapsedClockAdvancesDuringAnUnchangedLongPrediction() {
        let update = PipelineProgressUpdate(jobID: UUID(), stage: .denoisingAndUpscalingTiles,
            completedTiles: 0, totalTiles: 234, overallFraction: 0.1,
            estimatedSecondsRemaining: nil, phase: .predictingSuperResolution, elapsedSeconds: 1.4)
        let presentation = JobProgressPresentation.make(update: update, elapsedSeconds: 65, isStopping: false)
        XCTAssertEqual(presentation.elapsedSeconds, 65)
        XCTAssertEqual(presentation.completedTiles, 0, "An advancing clock must not invent tile progress")
        XCTAssertNil(presentation.estimatedSecondsRemaining)
    }

    func testRawDNGHighISOJobIsConstructedWithDenoiseOffAndNoDenoiserDecision() async throws {
        let decoder = FakeDecoder()
        decoder.setDefaultConfiguration(
            FakeDecodeConfiguration(
                utTypeIdentifier: "com.adobe.dng",
                category: .cameraRAW,
                isoSpeedRatings: 3200
            )
        )
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(decoder: decoder, pipeline: pipeline)
        let url = try makeFile("high-iso-camera.dng")

        await viewModel.ingestFile(at: url)
        XCTAssertEqual(viewModel.metadata?.isoSpeedRatings, 3200)
        XCTAssertEqual(viewModel.selectedScaleFactor, .x2)
        XCTAssertEqual(viewModel.backbone, .quickSRNet)
        viewModel.startProcessing()
        let finished = await waitUntil { pipeline.executionCount == 1 && !viewModel.isProcessing }
        XCTAssertTrue(finished)

        let execution = try XCTUnwrap(pipeline.recordedExecutions.first)
        XCTAssertEqual(execution.config.denoiseMode, .off, "Every Scaler job must be SR-only even for high-ISO DNG metadata")
        XCTAssertFalse(execution.shouldRunDenoiserConfigured, "The production config must not invoke the retired denoise stage")
        XCTAssertEqual(execution.config.scaleFactor, .x2)
        XCTAssertEqual(execution.config.backbone, .quickSRNet)
        XCTAssertEqual(viewModel.completedArtifacts?.checkpoint.didRunDenoise, false)
        XCTAssertFalse(viewModel.metadata?.isAlreadyDenoisedBySuite ?? true, "An SR-only job must not claim it denoised the photo")
        XCTAssertEqual(viewModel.latestProgress?.completedTiles, 1)
        XCTAssertEqual(viewModel.latestProgress?.totalTiles, 1)
        XCTAssertEqual(viewModel.jobProgress.totalTiles, 1)
        XCTAssertEqual(viewModel.jobProgress.title, "Complete")
        XCTAssertEqual(viewModel.latestProgress?.phase, .completed)
    }

    func testBatchUsesTheSameSRPolicy() async throws {
        let decoder = FakeDecoder()
        decoder.setDefaultConfiguration(
            FakeDecodeConfiguration(
                utTypeIdentifier: "public.jpeg",
                category: .standardOpaqueRaster,
                isoSpeedRatings: 6400
            )
        )
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(decoder: decoder, pipeline: pipeline)
        let url = try makeFile("batch-high-iso.jpg")
        let item = LibraryPhotoItem(
            id: url.path,
            fileURL: url,
            filename: url.lastPathComponent,
            capturedAt: Date(),
            byteCount: 2,
            badgeLabel: nil
        )
        viewModel.daySections = [
            LibraryDaySection(id: "batch", displayTitle: "Batch", items: [item])
        ]

        await viewModel.batchProcessSelected(ids: [item.id])

        XCTAssertFalse(pipeline.recordedExecutions.isEmpty)
        for execution in pipeline.recordedExecutions {
            XCTAssertEqual(execution.config.denoiseMode, .off, "Batch jobs must also be SR-only")
            XCTAssertFalse(execution.shouldRunDenoiserConfigured)
            XCTAssertEqual(execution.config.scaleFactor, .x2)
            XCTAssertEqual(execution.config.backbone, .quickSRNet)
        }
    }

    func testIncomingHandoffJobIsSRAndPreservesSourceDenoiseMetadata() async throws {
        // The existing lifecycle test covers the untagged/already-denoised handoff contract; this
        // focused test proves the app config can never turn the retired denoise stage back on for that path.
        let config = ScalerSRPolicy.makeJobConfig(
            sourceImageURL: URL(fileURLWithPath: "/tmp/synthetic.jpg"),
            naturalGrainAmount: 0.2,
            exportFormat: .autoMatchSource,
            sessionState: PipelineSessionState(isDenoised: true, linearHeadroomScale: 2.5)
        )
        XCTAssertEqual(config.denoiseMode, .off)
        XCTAssertEqual(config.scaleFactor, .x2)
        XCTAssertEqual(config.backbone, .quickSRNet)
        XCTAssertEqual(config.sessionState?.isDenoised, true, "The already-denoised source history is preserved, not re-run")
    }

    func testSelectedModelsFlowIntoNewJobsWithoutChangingScaleOrDenoise() async throws {
        for selected in BackboneModelKind.allCases {
            let pipeline = FakePipelineExecutor(directory: tempDirectory)
            pipeline.gateExecution = false
            let model = makeViewModel(pipeline: pipeline)
            model.selectedModel = selected
            await model.ingestFile(at: try makeFile("choice-\(selected.rawValue).dng"))
            model.startProcessing()
            let done = await waitUntil { pipeline.executionCount == 1 && !model.isProcessing }
            XCTAssertTrue(done)
            let config = try XCTUnwrap(pipeline.recordedExecutions.first?.config)
            XCTAssertEqual(config.backbone, selected)
            XCTAssertEqual(config.scaleFactor, .x2)
            XCTAssertEqual(config.denoiseMode, .off)
            XCTAssertEqual(model.tileConfig.inputOverlap, selected == .hatSmall ? 32 :
                (model.tileConfig.tier == .tierA_HighMemory ? 24 : 16))
            XCTAssertNoThrow(try ScalerSRPolicy.validateJobConfig(config))
            let artifact = try XCTUnwrap(model.completedArtifacts)
            XCTAssertFalse(ScalerSRPolicy.resumeDisposition(for: artifact.checkpoint).isRefused)
            XCTAssertEqual(artifact.checkpoint.tileConfig,
                TileConfiguration(tier: artifact.checkpoint.tileConfig.tier, backbone: selected))
            let recordedOverlap = model.latestProgress?.tileOverlap
            model.selectedModel = selected == .quickSRNet ? .edsrBaseline : .quickSRNet
            XCTAssertEqual(model.backbone, selected, "A later picker change must not relabel the displayed artifact")
            XCTAssertEqual(artifact.checkpoint.config.backbone, selected)
            XCTAssertEqual(model.latestProgress?.tileOverlap, recordedOverlap,
                           "Changing next-job geometry must not relabel the completed artifact's progress")
        }
    }

    // MARK: - Legacy resume refusal is non-destructive

    func testOlderFourTimesJobsAreRefusedWithoutRelabelingOrChangingTheirPixels() throws {
        for (backbone, scale) in [(BackboneModelKind.quickSRNet, ScaleFactor.x4), (.unavailable, .x2), (.unavailable, .x4)] {
            let artifacts = try StudioTestArtifacts.make(
                directory: tempDirectory,
                sourceURL: try makeFile("old-\(backbone.rawValue)-\(scale.rawValue).jpg"),
                configuredScale: scale,
                backbone: backbone,
                denoiseMode: .off,
                didRunDenoise: false
            )
            let before = try Data(contentsOf: artifacts.outputBuffer.fileURL)
            XCTAssertTrue(ScalerSRPolicy.resumeDisposition(for: artifacts.checkpoint).isRefused)
            XCTAssertThrowsError(try ScalerSRPolicy.validateResume(artifacts.checkpoint)) { error in
                guard case ScalerSRPolicy.ConfigurationError.incompatibleSavedJob = error else {
                    return XCTFail("Expected a non-destructive 2× restart refusal, got \(error)")
                }
            }
            let model = makeViewModel(pipeline: FakePipelineExecutor(directory: tempDirectory))
            model.completedArtifacts = artifacts
            XCTAssertEqual(model.scaleFactor, .x4, "Existing 4× pixels must retain their actual inspection/export scale")
            XCTAssertEqual(model.backbone, backbone)
            XCTAssertEqual(try Data(contentsOf: artifacts.outputBuffer.fileURL), before)
        }
    }

    func testProductionAdapterRefusesNonTwoTimesConfigurationsBeforeOpeningSource() async throws {
        let registry = CoreMLModelRegistry(initialComputeUnits: .cpuOnly)
        let executor = TiledPipelineExecutor(workingDirectory: tempDirectory, modelRegistry: registry,
            checkpointStore: JobCheckpointStore(directory: tempDirectory))
        let adapter = TiledExecutorPipelineAdapter(executor: executor)
        for (backbone, scale, denoise) in [
            (BackboneModelKind.quickSRNet, ScaleFactor.x4, DenoiseMode.off),
            (.unavailable, .x2, .off), (.unavailable, .x4, .off), (.quickSRNet, .x2, .auto)
        ] {
            let config = UpscaleJobConfig(sourceImageURL: tempDirectory.appendingPathComponent("not-opened.jpg"),
                scaleFactor: scale, backbone: backbone, denoiseMode: denoise,
                naturalGrainAmount: 0.15, exportFormat: .autoMatchSource)
            do {
                _ = try await adapter.executeOrResumeJob(config: config, progressHandler: nil)
                XCTFail("Unsupported app configuration reached the engine")
            } catch ScalerSRPolicy.ConfigurationError.requiresNativeTwoTimesJob {
                // Policy refusal must precede any missing-source or model error from the engine.
            } catch {
                XCTFail("Expected product-policy refusal before source access, got \(error)")
            }
        }
    }

    func testLegacyDenoiseCheckpointIsRefusedWithoutTouchingArtifacts() throws {
        let sourceURL = try makeFile("legacy-source.jpg")
        let artifacts = try StudioTestArtifacts.make(
            directory: tempDirectory,
            sourceURL: sourceURL,
            didRunDenoise: true,
            inputComponentPeak: 1.0,
            inputLuminance: 1.5
        )
        let outputURL = artifacts.outputBuffer.fileURL
        let before = try Data(contentsOf: outputURL)

        XCTAssertTrue(ScalerSRPolicy.resumeDisposition(for: artifacts.checkpoint).isRefused)
        XCTAssertThrowsError(try ScalerSRPolicy.validateResume(artifacts.checkpoint)) { error in
            guard case ScalerError.srOnlyResumeOfLegacyDenoiseJob(let completed, let total) = error else {
                return XCTFail("Expected SR-only legacy resume refusal, got \(error)")
            }
            XCTAssertEqual(completed, artifacts.checkpoint.lastCompletedTileIndex + 1)
            XCTAssertEqual(total, artifacts.checkpoint.totalTiles)
            XCTAssertTrue(error.localizedDescription.contains("TruongNoiser"))
        }

        XCTAssertEqual(try Data(contentsOf: outputURL), before, "Refusal must leave the legacy output byte-identical")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testCheckpointConfiguredForDenoiseIsRefusedEvenBeforeAnyTileCommitted() throws {
        let sourceURL = try makeFile("legacy-unstarted.jpg")
        let legacyConfig = UpscaleJobConfig(
            sourceImageURL: sourceURL,
            scaleFactor: .x4,
            backbone: .quickSRNet,
            denoiseMode: .auto,
            naturalGrainAmount: 0.15,
            exportFormat: .autoMatchSource
        )
        let checkpoint = JobCheckpointState(
            jobID: legacyConfig.id,
            config: legacyConfig,
            tileConfig: TileConfiguration(tier: .tierB_ConstrainedMemory),
            sourceWidth: 8,
            sourceHeight: 6,
            paddedSourceWidth: 8,
            paddedSourceHeight: 6,
            outputWidth: 32,
            outputHeight: 24,
            globalMaxLuminance: 1.0,
            globalMaxLinearComponent: 1.0,
            alphaCurveConstant: 16.0,
            didRunDenoise: false,
            sourceMMapFileName: "source.bin",
            outputMMapFileName: "output.bin",
            metadataPacketFileName: "metadata.json",
            lastCompletedTileIndex: -1,
            totalTiles: 1,
            updatedAt: Date(),
            transactionJournalVersion: JobCheckpointState.currentTransactionJournalVersion,
            normalizationPeakVersion: JobCheckpointState.currentNormalizationPeakVersion
        )
        XCTAssertTrue(ScalerSRPolicy.resumeDisposition(for: checkpoint).isRefused,
                      "A stored auto/forceOn config would turn the retired denoise stage back on for remaining tiles")
        XCTAssertThrowsError(try ScalerSRPolicy.validateResume(checkpoint))
    }

    func testSROnlyCheckpointIsCompatibleAndProductionAdapterEnforcesRefusal() throws {
        let sourceURL = try makeFile("sr-only.jpg")
        let artifacts = try StudioTestArtifacts.make(
            directory: tempDirectory,
            sourceURL: sourceURL,
            configuredScale: .x2,
            denoiseMode: .off,
            didRunDenoise: false,
            inputComponentPeak: 1.0,
            inputLuminance: 1.0
        )
        XCTAssertEqual(ScalerSRPolicy.resumeDisposition(for: artifacts.checkpoint), .compatible)
        XCTAssertNoThrow(try ScalerSRPolicy.validateResume(artifacts.checkpoint))

        let registry = CoreMLModelRegistry(initialComputeUnits: .all)
        let store = JobCheckpointStore(directory: tempDirectory)
        let executor = TiledPipelineExecutor(
            workingDirectory: tempDirectory,
            modelRegistry: registry,
            checkpointStore: store
        )
        let adapter = TiledExecutorPipelineAdapter(executor: executor)
        XCTAssertNoThrow(try adapter.validateResumeCompatibility(artifacts.checkpoint))

        let legacy = try StudioTestArtifacts.make(
            directory: tempDirectory,
            sourceURL: try makeFile("legacy-adapter.jpg"),
            didRunDenoise: true,
            inputComponentPeak: 1.0,
            inputLuminance: 1.0
        )
        XCTAssertThrowsError(try adapter.validateResumeCompatibility(legacy.checkpoint),
                             "The production app adapter must enforce the SR-only resume policy")
    }

    // MARK: - Terminal presentation / ownership

    func testSuccessfulJobPublishesCompletedTerminalDetailsWithUUIDCorrelation() async throws {
        let decoder = FakeDecoder()
        decoder.setDefaultConfiguration(
            FakeDecodeConfiguration(
                utTypeIdentifier: "com.adobe.dng",
                category: .cameraRAW,
                isoSpeedRatings: 1600
            )
        )
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(decoder: decoder, pipeline: pipeline)
        let url = try makeFile("terminal-success.dng")
        await viewModel.ingestFile(at: url)
        viewModel.startProcessing()
        let finished = await waitUntil { pipeline.executionCount == 1 && !viewModel.isProcessing }
        XCTAssertTrue(finished)
        let configID = try XCTUnwrap(pipeline.recordedExecutions.first?.config.id)
        XCTAssertEqual(viewModel.latestProgress?.phase, .completed)
        XCTAssertEqual(viewModel.latestProgress?.jobID, configID)
        XCTAssertEqual(viewModel.jobProgress.title, "Complete")
        XCTAssertEqual(viewModel.currentStage, .readyForInspection)
        let event = Diagnostics.shared.recentEvents(limit: 500)
            .last { $0.code == "app.job.completed" && $0.fields["correlationID"] == configID.uuidString }
        XCTAssertNotNil(event, "Terminal diagnostics must correlate with the actual job UUID")
    }

    func testPausedTerminalPublishesPausedDetailsNotReadingSource() async throws {
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        pipeline.configureFailure(ScalerError.jobPausedForBackgroundExpiration(completedTileIndex: 0))
        let viewModel = makeViewModel(pipeline: pipeline)
        let url = try makeFile("terminal-paused.jpg")
        await viewModel.ingestFile(at: url)
        viewModel.startProcessing()
        let finished = await waitUntil { pipeline.executionCount == 1 && !viewModel.isProcessing }
        XCTAssertTrue(finished)
        XCTAssertEqual(viewModel.currentStage, .pausedOnDisk)
        XCTAssertEqual(viewModel.latestProgress?.phase, .paused)
        XCTAssertEqual(viewModel.latestProgress?.stage, .pausedOnDisk)
        XCTAssertEqual(viewModel.jobProgress.title, "Paused")
    }

    func testFailedTerminalPublishesFailedDetailsAndStructuredError() async throws {
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        pipeline.configureFailure(
            ScalerError.modelInferenceFailed(modelName: "QuickSRNet_Large_x2_256", tileIndex: 3, reason: "synthetic failure")
        )
        let viewModel = makeViewModel(pipeline: pipeline)
        let url = try makeFile("terminal-failed.jpg")
        await viewModel.ingestFile(at: url)
        viewModel.startProcessing()
        let finished = await waitUntil { pipeline.executionCount == 1 && !viewModel.isProcessing }
        XCTAssertTrue(finished)
        XCTAssertEqual(viewModel.currentStage, .failed)
        XCTAssertEqual(viewModel.latestProgress?.phase, .failed)
        XCTAssertEqual(viewModel.jobProgress.title, "Failed")
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testLateProgressAfterTerminalCannotOverwriteCompletedPresentation() async throws {
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(pipeline: pipeline)
        let url = try makeFile("terminal-late-progress.jpg")
        await viewModel.ingestFile(at: url)
        viewModel.startProcessing()
        let finished = await waitUntil { pipeline.executionCount == 1 && !viewModel.isProcessing }
        XCTAssertTrue(finished)
        let configID = try XCTUnwrap(pipeline.recordedExecutions.first?.config.id)
        XCTAssertEqual(viewModel.latestProgress?.phase, .completed)

        pipeline.sendLateProgress(
            PipelineProgressUpdate(
                jobID: configID,
                stage: .denoisingAndUpscalingTiles,
                completedTiles: 0,
                totalTiles: 4,
                overallFraction: 0.1,
                estimatedSecondsRemaining: nil,
                phase: .extractingTile,
                currentTileIndex: 0
            )
        )
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(viewModel.latestProgress?.phase, .completed,
                       "A late callback from the same generation must not replace terminal details")
        XCTAssertEqual(viewModel.latestProgress?.completedTiles, 1)
    }

    // MARK: - Progress presentation truthfulness

    func testPreparationHasNoFakeOneOfOneAndBusyTileKeepsCommittedCount() {
        let preparation = JobProgressPresentation.make(update: nil, elapsedSeconds: 2, isStopping: false)
        XCTAssertFalse(preparation.hasTilePlan)
        XCTAssertEqual(preparation.completedTiles, 0)
        XCTAssertEqual(preparation.totalTiles, 0)
        XCTAssertEqual(preparation.title, "Preparing…")

        let busy = PipelineProgressUpdate(
            jobID: UUID(),
            stage: .denoisingAndUpscalingTiles,
            completedTiles: 3,
            totalTiles: 10,
            overallFraction: 0.37,
            estimatedSecondsRemaining: 14,
            currentTileDescriptor: nil,
            phase: .predictingSuperResolution,
            currentTileIndex: 5,
            elapsedSeconds: 12,
            averageSecondsPerTile: 2.0,
            sourceWidth: 6000,
            sourceHeight: 4000,
            outputWidth: 24000,
            outputHeight: 16000,
            modelName: "QuickSRNet_Large_x2_256",
            tileSize: 256,
            tileOverlap: 24,
            gridColumns: 24,
            gridRows: 16,
            requestedCompute: "all requested",
            didRunDenoise: false,
            timings: PipelineTileTimings(extractionSeconds: 0.4, modelSeconds: 1.4)
        )
        let presentation = JobProgressPresentation.make(update: busy, elapsedSeconds: 12, isStopping: false)
        XCTAssertTrue(presentation.hasTilePlan)
        XCTAssertEqual(presentation.completedTiles, 3, "An uncommitted tile must not be counted as completed")
        XCTAssertEqual(presentation.currentTileDisplayNumber, 6)
        XCTAssertTrue(presentation.title.contains("tile 6 of 10"))
        XCTAssertEqual(presentation.estimatedSecondsRemaining, 14)
        XCTAssertEqual(presentation.outputWidth, 24000)
        XCTAssertEqual(presentation.didRunDenoise, false)

        let noSamples = PipelineProgressUpdate(
            jobID: UUID(),
            stage: .denoisingAndUpscalingTiles,
            completedTiles: 0,
            totalTiles: 10,
            overallFraction: 0.1,
            estimatedSecondsRemaining: nil,
            phase: .extractingTile,
            currentTileIndex: 0
        )
        let early = JobProgressPresentation.make(update: noSamples, elapsedSeconds: 3, isStopping: false)
        XCTAssertNil(early.averageSecondsPerTile)
        XCTAssertNil(early.estimatedSecondsRemaining,
                       "No honest ETA exists before measured tile samples")
    }
}
