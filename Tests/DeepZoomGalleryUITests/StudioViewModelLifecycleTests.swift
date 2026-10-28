import XCTest
import SwiftUI
import Foundation
import TruongScalerCore
import CoreIngestion
import CoreExport
import TiledInferenceEngine
import BackgroundJobManager
@testable import DeepZoomGalleryUI

/// Writes a disposable partial intermediate before failing, unlike the normal fake's pre-write
/// error. This makes cleanup observable without opening another application or filling the disk.
private actor PartialHandoffFailureExporter: StudioImageExporting {
    private(set) var writtenURL: URL?
    func exportDetailed(artifacts: CompletedPipelineArtifacts, destinationURL: URL,
        overrideFormat: ExportFormat?, overrideGrainAmount: Float?) async throws -> ExportResult {
        writtenURL = destinationURL
        try Data([0x02, 0x03]).write(to: destinationURL)
        throw CocoaError(.fileWriteOutOfSpace)
    }
}

private actor GatedCompatibilitySharePreparer: StudioPhotoSharePreparing {
    let gate: TestGate
    let root: URL
    init(gate: TestGate, root: URL) { self.gate = gate; self.root = root }
    func prepare(_ urls: [URL], surface: PhotoShareSurface, expectedHashes: [URL: String]) async throws -> PhotoShareSession {
        await gate.hold()
        let id = UUID(), directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = directory.appendingPathComponent("shared.dng")
        try FileManager.default.copyItem(at: urls[0], to: snapshot)
        return PhotoShareSession(id: id, surface: surface, fileURLs: [snapshot], directory: directory)
    }
}

/// Models a refused OS submission without touching the system scheduler. A gate can keep one
/// background callback suspended while the foreground/new photo acquires notice ownership.
private final class RefusingSceneScheduler: BackgroundTaskScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var submitGate: TestGate?
    func setSubmitGate(_ gate: TestGate?) { lock.withLock { submitGate = gate } }
    func registerContinuedProcessing(identifier: String,
        launchHandler: @escaping @Sendable (AnyObject) -> Void) throws {}
    func submitContinuedProcessing(_ descriptor: ContinuedProcessingRequestDescriptor) async throws {
        if let gate = lock.withLock({ submitGate }) { await gate.hold() }
        throw ScalerError.backgroundTaskSchedulingFailed(reason: "Test continuation refused")
    }
    func cancelContinuedProcessing(identifier: String) {}
}

/// Deterministic view-model lifecycle/ownership tests (R5) and production-chain handoff tests (R6).
///
/// All seams are injected protocols; production defaults keep the real decoder/exporter/scanner/
/// executor and the app's `.requireProductionModels` model policy. No debug UI or control is added.
final class StudioViewModelLifecycleTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StudioViewModelLifecycleTests-\(UUID().uuidString)",
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

    @MainActor
    private func makeViewModel(
        decoder: any StudioImageDecoding = FakeDecoder(),
        exporter: any StudioImageExporting = FakeExporter(),
        scanner: any StudioLibraryScanning = FakeScanner(),
        thumbnailReader: any StudioThumbnailReading = ImageIOThumbnailReader(),
        pipeline: any StudioPipelineExecuting,
        handoffManager: any StudioHandoffManaging = FakeHandoffManager(),
        externalOpener: any ExternalApplicationOpening = RecordingOpener(),
        scopeProvider: any SecurityScopeGrantProviding = RecordingScopeProvider(),
        sharePreparer: any StudioPhotoSharePreparing = PhotoSharePreparer(),
        backgroundScheduler: (any BackgroundTaskScheduling)? = nil
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
            exporter: exporter,
            scanner: scanner,
            thumbnailReader: thumbnailReader,
            handoffManager: handoffManager,
            externalOpener: externalOpener,
            scopeProvider: scopeProvider,
            backgroundTaskRouter: BackgroundTaskDeliveryRouter(),
            sharePreparer: sharePreparer,
            backgroundScheduler: backgroundScheduler
        )
    }

    /// A 2×2 opaque test raster used to prove a stale thumbnail read is discarded.
    private func makeThumbnailImage() -> CGImage? {
        let width = 2
        let height = 2
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try Data([0x01, 0x02]).write(to: url)
        return url
    }

    private func incomingPayload(
        for url: URL,
        isDenoised: Bool = true
    ) -> SharedSuiteHandoffPayload {
        SharedSuiteHandoffPayload(
            sourceApp: .truongNoiser,
            targetApp: .truongScaler,
            imageFileURLPath: url.path,
            originalFileName: url.lastPathComponent,
            isDenoised: isDenoised,
            isUpscaled: false,
            globalMaxLuminance: 1.0,
            upscaleFactor: nil,
            globalMaxLinearComponent: 1.0
        )
    }

    private func handoffDeepLink(for payload: SharedSuiteHandoffPayload) -> URL {
        URL(string: "truongscaler://handoff?id=\(payload.handoffID.uuidString)")!
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 3.0,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @MainActor
    private func waitForProcessingToFinish(_ viewModel: StudioViewModel) async -> Bool {
        await waitUntil { !viewModel.isProcessing && !viewModel.isStopping }
    }

    // MARK: - R5: blocked decode followed by select/reset

    @MainActor
    func testIdleSceneCannotRepublishAnEarlierJobsSchedulingFailure() async throws {
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        let scheduler = RefusingSceneScheduler()
        let vm = makeViewModel(pipeline: pipeline, backgroundScheduler: scheduler)
        await vm.ingestFile(at: try makeFile("scheduling-A.jpg"))
        vm.startProcessing()
        let entered = await waitUntil { pipeline.executionCount == 1 }
        XCTAssertTrue(entered)
        await vm.handleScenePhaseChange(.inactive)
        XCTAssertTrue(vm.errorMessage?.hasPrefix("Background processing unavailable:") == true)
        await vm.handleScenePhaseChange(.active)

        let replacement = try makeFile("scheduling-B.jpg")
        await vm.ingestFile(at: replacement)
        vm.errorMessage = "Current photo notice"
        let diagnostic = await vm.backgroundCoordinator.schedulingError()
        XCTAssertNotNil(diagnostic, "The old failure remains available for diagnostics")
        await vm.handleScenePhaseChange(.background)
        XCTAssertEqual(vm.errorMessage, "Current photo notice")
        XCTAssertEqual(vm.sourceURL, replacement)
        XCTAssertFalse(vm.isProcessing)
        XCTAssertEqual(vm.ownedExecutionCount, 0)
    }

    @MainActor
    func testSceneNoticeKeepsItsBackgroundCycleButCannotOverwriteForeground() async throws {
        for returnToForeground in [false, true] {
            let pipeline = FakePipelineExecutor(directory: tempDirectory)
            let scheduler = RefusingSceneScheduler()
            let vm = makeViewModel(pipeline: pipeline, backgroundScheduler: scheduler)
            await vm.ingestFile(at: try makeFile("scene-\(returnToForeground).jpg"))
            vm.startProcessing()
            let entered = await waitUntil { pipeline.executionCount == 1 }
            XCTAssertTrue(entered)
            if returnToForeground {
                // Leave a diagnostic for the same job, then suspend a retry. Foregrounding makes
                // that retry stale, but the coordinator intentionally keeps its previous diagnostic.
                await vm.handleScenePhaseChange(.inactive)
                XCTAssertTrue(vm.errorMessage?.hasPrefix("Background processing unavailable:") == true)
                await vm.handleScenePhaseChange(.active)
            }
            let gate = TestGate()
            scheduler.setSubmitGate(gate)
            defer { gate.open(); vm.cancelProcessing() }
            let leaving = Task { await vm.handleScenePhaseChange(.inactive) }
            await gate.entered.wait()
            if returnToForeground {
                await vm.handleScenePhaseChange(.active)
                vm.errorMessage = "New foreground notice"
            } else {
                // The inactive preparation still owns this same background cycle. The second
                // scene callback must not discard its eventual genuine scheduling refusal.
                await vm.handleScenePhaseChange(.background)
            }
            gate.open()
            await leaving.value
            if returnToForeground { XCTAssertEqual(vm.errorMessage, "New foreground notice") }
            else { XCTAssertTrue(vm.errorMessage?.hasPrefix("Background processing unavailable:") == true) }
            vm.cancelProcessing()
            await vm.waitForStopToFinish()
            XCTAssertFalse(vm.isProcessing)
            XCTAssertFalse(vm.isStopping)
            XCTAssertEqual(vm.ownedExecutionCount, 0)
        }
    }

    @MainActor
    func testBlockedDecodeThenSelectingAnotherPhotoDoesNotPublishStaleStateOrReleaseEarly() async throws {
        let scope = RecordingScopeProvider()
        let decoder = FakeDecoder()
        let gate = TestGate()
        let urlA = try makeFile("A.jpg")
        let urlB = try makeFile("B.jpg")
        decoder.setGate(gate, forFileName: "A.jpg")

        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(
            decoder: decoder,
            pipeline: pipeline,
            scopeProvider: scope
        )

        let ingestA = Task { await viewModel.ingestFile(at: urlA) }
        await gate.entered.wait()
        XCTAssertEqual(viewModel.sourceURL?.lastPathComponent, "A.jpg")

        // A newer selection completes while A's decode is still blocked.
        await viewModel.ingestFile(at: urlB)
        XCTAssertEqual(viewModel.sourceURL?.lastPathComponent, "B.jpg")
        XCTAssertEqual(viewModel.metadata?.sourceURL.lastPathComponent, "B.jpg")
        XCTAssertGreaterThan(
            scope.activeGrantCount(for: urlA),
            0,
            "A blocked decode's grants must not be released by the newer selection"
        )

        gate.open()
        await ingestA.value
        await viewModel.waitForIngestTasksToFinish()

        // The late A result must not replace B's published state, and A's grants must drain only now.
        XCTAssertEqual(viewModel.sourceURL?.lastPathComponent, "B.jpg")
        XCTAssertEqual(viewModel.metadata?.sourceURL.lastPathComponent, "B.jpg")
        XCTAssertEqual(scope.activeGrantCount(for: urlA), 0)
        XCTAssertGreaterThan(scope.activeGrantCount(for: urlB), 0)
        XCTAssertEqual(scope.uniqueGrantIdentifiers, scope.acquiredCount, "Every operation must own an independent grant")
    }

    @MainActor
    func testBlockedDecodeThenResetDoesNotPublishStaleStateAndReleasesOnlyAfterDrain() async throws {
        let scope = RecordingScopeProvider()
        let decoder = FakeDecoder()
        let gate = TestGate()
        let urlA = try makeFile("reset-A.jpg")
        decoder.setGate(gate, forFileName: "reset-A.jpg")

        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(decoder: decoder, pipeline: pipeline, scopeProvider: scope)

        let ingestA = Task { await viewModel.ingestFile(at: urlA) }
        await gate.entered.wait()

        viewModel.resetSession()
        await viewModel.waitForResetToFinish()
        XCTAssertNil(viewModel.sourceURL, "Reset clears the session only after its teardown drain")
        XCTAssertNil(viewModel.metadata)
        XCTAssertGreaterThan(
            scope.activeGrantCount(for: urlA),
            0,
            "The blocked decode still owns its grants; reset must not release them early"
        )

        gate.open()
        await ingestA.value
        await viewModel.waitForIngestTasksToFinish()

        XCTAssertNil(viewModel.sourceURL)
        XCTAssertNil(viewModel.metadata)
        XCTAssertEqual(scope.activeGrantCount(for: urlA), 0)
    }

    // MARK: - R5: export blocked followed by library change

    @MainActor
    func testBlockedExportThenChangingLibraryDoesNotPublishStaleURLOrReleaseFolderEarly() async throws {
        let scope = RecordingScopeProvider()
        let exporter = FakeExporter()
        let scanner = FakeScanner()
        let folderA = tempDirectory.appendingPathComponent("folderA", isDirectory: true)
        let folderB = tempDirectory.appendingPathComponent("folderB", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        let sourceURL = try makeFile("export-source.jpg")

        scanner.setDefaultItems([StudioTestArtifacts.libraryItem(named: "A.jpg")])
        scanner.setItems([StudioTestArtifacts.libraryItem(named: "B.jpg")], forFolderName: "folderB")

        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(
            decoder: FakeDecoder(),
            exporter: exporter,
            scanner: scanner,
            pipeline: pipeline,
            scopeProvider: scope
        )

        await viewModel.ingestFile(at: sourceURL)
        await viewModel.setLibraryFolder(url: folderA)
        viewModel.startProcessing()
        let finished = await waitForProcessingToFinish(viewModel)
        XCTAssertTrue(finished)
        XCTAssertNotNil(viewModel.completedArtifacts)
        XCTAssertEqual(viewModel.currentStage, .readyForInspection)

        exporter.configure(finalPeak: 2.0, actualScaleFactor: 4)
        let exportGate = TestGate()
        exporter.gate = exportGate
        let exportTask = Task { await viewModel.exportFinalImage(presentShareSheet: true) }
        await exportGate.entered.wait()

        // The completed export is still reading folder A while the user selects folder B.
        await viewModel.setLibraryFolder(url: folderB)
        XCTAssertGreaterThan(
            scope.activeGrantCount(for: folderA),
            0,
            "Folder A's grant must be retained while its export is still reading it"
        )

        exportGate.open()
        await exportTask.value
        await viewModel.waitForExportTasksToFinish()

        XCTAssertTrue(viewModel.exportedShareURLs.isEmpty, "A stale export must not publish into the new library session")
        XCTAssertEqual(scope.activeGrantCount(for: folderA), 0)
        XCTAssertGreaterThan(scope.activeGrantCount(for: folderB), 0)
        XCTAssertEqual(viewModel.libraryOperationCount, 0)
    }

    @MainActor
    func testCompatibilityExportCannotRelabelNewPhotoAfterBlockedSharePreparation() async throws {
        let exporter = FakeExporter(), gate = TestGate()
        exporter.configure(finalPeak: 4.0, actualScaleFactor: 4)
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(exporter: exporter, pipeline: pipeline,
            sharePreparer: GatedCompatibilitySharePreparer(gate: gate, root: tempDirectory.appendingPathComponent("snapshots")))
        let original = try makeFile("legacy-export-original.jpg"), newer = try makeFile("legacy-export-newer.jpg")
        await viewModel.ingestFile(at: original)
        viewModel.startProcessing()
        let finished = await waitForProcessingToFinish(viewModel)
        XCTAssertTrue(finished)
        XCTAssertNotNil(viewModel.completedArtifacts)
        let export = Task { await viewModel.exportFinalImage(presentShareSheet: true) }
        await gate.entered.wait()
        defer { gate.open() }

        await viewModel.ingestFile(at: newer)
        XCTAssertEqual(viewModel.metadata?.isAlreadyUpscaledBySuite, false)
        XCTAssertNil(viewModel.metadata?.upscaledByAppFactor)
        XCTAssertNil(viewModel.metadata?.linearHeadroomScale)
        gate.open(); await export.value
        await viewModel.waitForExportTasksToFinish()

        XCTAssertEqual(viewModel.sourceURL, newer)
        XCTAssertEqual(viewModel.metadata?.sourceURL, newer)
        XCTAssertEqual(viewModel.metadata?.isAlreadyUpscaledBySuite, false, "Old export metadata cannot relabel the new photo")
        XCTAssertNil(viewModel.metadata?.upscaledByAppFactor)
        XCTAssertNil(viewModel.metadata?.linearHeadroomScale)
        XCTAssertTrue(viewModel.exportedShareURLs.isEmpty)
        XCTAssertNil(viewModel.shareSession)
    }

    // MARK: - R5: blocked library scan followed by selection change

    @MainActor
    func testBatchDecodeCannotProcessANewerDirectImportOrAdvanceOverIt() async throws {
        let decoder = FakeDecoder(), gate = TestGate()
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let scopes = RecordingScopeProvider()
        let viewModel = makeViewModel(decoder: decoder, pipeline: pipeline, scopeProvider: scopes)
        let items = [StudioTestArtifacts.libraryItem(named: "batch-decode-A.jpg"),
                     StudioTestArtifacts.libraryItem(named: "batch-decode-A2.jpg")]
        let newer = try makeFile("batch-decode-new-import.jpg")
        decoder.setGate(gate, forFileName: items[0].filename)
        viewModel.daySections = [LibraryDaySection(id: "batch", displayTitle: "Batch", items: items)]
        let batch = Task { await viewModel.batchProcessSelected(ids: Set(items.map(\.id))) }
        await gate.entered.wait()
        defer { gate.open() }
        await viewModel.ingestFile(at: newer)
        viewModel.errorMessage = "Notice for the newly imported photo"
        gate.open()
        await batch.value
        await viewModel.waitForIngestTasksToFinish()

        XCTAssertEqual(pipeline.executionCount, 0, "The batch must not process an independently imported photo")
        XCTAssertEqual(viewModel.sourceURL, newer)
        XCTAssertEqual(viewModel.metadata?.sourceURL, newer)
        XCTAssertEqual(viewModel.currentStage, .idle)
        XCTAssertEqual(viewModel.errorMessage, "Notice for the newly imported photo")
        XCTAssertFalse(decoder.recordedDecodeURLs.contains(items[1].fileURL), "The old queue cannot replace the new selection")
        XCTAssertFalse(viewModel.isBatchProcessing)
        XCTAssertNil(viewModel.batchPhotoNumber)
        XCTAssertEqual(scopes.activeGrantCount(for: items[0].fileURL), 0)

        viewModel.startProcessing()
        let completed = await waitUntil { viewModel.completedArtifacts != nil && !viewModel.isProcessing }
        XCTAssertTrue(completed, "The newer photo must remain usable after the batch drains")
        XCTAssertEqual(pipeline.recordedExecutions.last?.config.sourceImageURL, newer)
    }

    @MainActor
    func testBatchExecutionCannotAdvanceOverANewerIncomingHandoff() async throws {
        let pause = TestGate()
        defer { pause.open() }
        let pipeline = FakePipelineExecutor(directory: tempDirectory, pauseGate: pause)
        let decoder = FakeDecoder(), manager = FakeHandoffManager(), scopes = RecordingScopeProvider()
        let viewModel = makeViewModel(decoder: decoder, pipeline: pipeline, handoffManager: manager, scopeProvider: scopes)
        let items = [StudioTestArtifacts.libraryItem(named: "batch-execution-A.jpg"),
                     StudioTestArtifacts.libraryItem(named: "batch-execution-A2.jpg")]
        let newer = try makeFile("batch-execution-handoff.jpg")
        let payload = incomingPayload(for: newer)
        manager.configureConsumedPayload(payload)
        viewModel.daySections = [LibraryDaySection(id: "batch", displayTitle: "Batch", items: items)]
        let batch = Task { await viewModel.batchProcessSelected(ids: Set(items.map(\.id))) }
        let entered = await waitUntil { pipeline.executionCount == 1 }
        XCTAssertTrue(entered)
        viewModel.handleIncomingHandoffURL(handoffDeepLink(for: payload))
        await pause.entered.wait()
        pause.open()
        await viewModel.waitForHandoffConsumptionsToFinish()
        await batch.value
        await viewModel.waitForIngestTasksToFinish()

        XCTAssertEqual(pipeline.executionCount, 1, "The superseded batch cannot start its next queued job")
        XCTAssertEqual(pipeline.maxConcurrentExecutions, 1)
        XCTAssertFalse(decoder.recordedDecodeURLs.contains(items[1].fileURL))
        XCTAssertEqual(viewModel.sourceURL, newer)
        XCTAssertEqual(viewModel.metadata?.sourceURL, newer)
        XCTAssertTrue(viewModel.metadata?.isAlreadyDenoisedBySuite == true)
        XCTAssertEqual(viewModel.currentStage, .idle)
        XCTAssertNil(viewModel.completedArtifacts)
        XCTAssertFalse(viewModel.isBatchProcessing)
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertFalse(viewModel.isStopping)
        XCTAssertEqual(scopes.activeGrantCount(for: items[0].fileURL), 0)
    }

    @MainActor
    func testBlockedScanThenSelectingAnotherFolderKeepsOldGrantUntilScanDrains() async throws {
        let scope = RecordingScopeProvider()
        let scanner = FakeScanner()
        let folderA = tempDirectory.appendingPathComponent("scanA", isDirectory: true)
        let folderB = tempDirectory.appendingPathComponent("scanB", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)

        let scanGate = TestGate()
        scanner.setGate(scanGate, forFolderName: "scanA")
        scanner.setItems([StudioTestArtifacts.libraryItem(named: "A.jpg")], forFolderName: "scanA")
        scanner.setItems([StudioTestArtifacts.libraryItem(named: "B.jpg")], forFolderName: "scanB")

        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(
            decoder: FakeDecoder(),
            exporter: FakeExporter(),
            scanner: scanner,
            pipeline: pipeline,
            scopeProvider: scope
        )

        let selectionA = Task { await viewModel.setLibraryFolder(url: folderA) }
        await scanGate.entered.wait()

        await viewModel.setLibraryFolder(url: folderB)
        XCTAssertEqual(viewModel.libraryFolderURL, folderB)
        XCTAssertEqual(viewModel.orderedLibraryItems.map(\.filename), ["B.jpg"])
        XCTAssertGreaterThan(
            scope.activeGrantCount(for: folderA),
            0,
            "The old folder grant must survive its still-running scan"
        )

        scanGate.open()
        await selectionA.value
        XCTAssertEqual(scope.activeGrantCount(for: folderA), 0)
        XCTAssertGreaterThan(scope.activeGrantCount(for: folderB), 0)
        XCTAssertEqual(viewModel.orderedLibraryItems.map(\.filename), ["B.jpg"])
        XCTAssertEqual(viewModel.libraryOperationCount, 0)
    }

    // MARK: - R5: Start -> immediate Stop -> Start

    @MainActor
    func testStartImmediateStopRefusesOverlapAndOnlyStartsAgainAfterBoundary() async throws {
        let pauseGate = TestGate()
        let pipeline = FakePipelineExecutor(directory: tempDirectory, pauseGate: pauseGate)
        let decoder = FakeDecoder()
        let sourceURL = try makeFile("stop-source.jpg")
        let viewModel = makeViewModel(decoder: decoder, pipeline: pipeline)

        await viewModel.ingestFile(at: sourceURL)
        viewModel.startProcessing()
        let started = await waitUntil { pipeline.executionCount == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(pipeline.maxConcurrentExecutions, 1)

        viewModel.cancelProcessing()
        XCTAssertTrue(viewModel.isStopping, "Stop exposes a distinct stopping state")
        XCTAssertTrue(viewModel.isProcessing, "The execution owner is retained until the boundary drains")

        // A new run is refused while the old owner is stopping/draining.
        viewModel.startProcessing()
        XCTAssertEqual(pipeline.executionCount, 1, "Two executeOrResumeJob calls must never overlap")

        let waiting = await waitUntil { pipeline.pauseWaitCount >= 1 }
        XCTAssertTrue(waiting)
        pauseGate.open()
        await viewModel.waitForStopToFinish()

        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertFalse(viewModel.isStopping)
        XCTAssertEqual(pipeline.cancelledExecutionCount, 1)
        if let pauseIndex = pipeline.log.index(of: "pauseWait"),
           let cancelIndex = pipeline.log.index(of: "executionCancelled") {
            XCTAssertLessThan(pauseIndex, cancelIndex, "The pause boundary must be reached before cancelling the task")
        } else {
            XCTFail("Expected pauseWait and executionCancelled events")
        }

        // Only after the stable boundary may a new run start, and still serialized.
        pipeline.gateExecution = false
        viewModel.startProcessing()
        let completed = await waitUntil { viewModel.completedArtifacts != nil && !viewModel.isProcessing }
        XCTAssertTrue(completed)
        XCTAssertEqual(pipeline.executionCount, 2)
        XCTAssertEqual(pipeline.maxConcurrentExecutions, 1)
        XCTAssertFalse(viewModel.isStopping)
    }

    @MainActor
    func testStopThenSelectionChangeDoesNotCancelTheNextRun() async throws {
        let pauseGate = TestGate()
        let pipeline = FakePipelineExecutor(directory: tempDirectory, pauseGate: pauseGate)
        let decoder = FakeDecoder()
        let urlA = try makeFile("cleanup-A.jpg")
        let urlB = try makeFile("cleanup-B.jpg")
        let viewModel = makeViewModel(decoder: decoder, pipeline: pipeline)

        await viewModel.ingestFile(at: urlA)
        viewModel.startProcessing()
        _ = await waitUntil { pipeline.executionCount == 1 }

        viewModel.cancelProcessing()
        let selection = Task { await viewModel.ingestFile(at: urlB) }
        try await Task.sleep(for: .milliseconds(20))
        pauseGate.open()
        await selection.value
        XCTAssertEqual(viewModel.sourceURL?.lastPathComponent, "cleanup-B.jpg")
        XCTAssertFalse(viewModel.isStopping)

        // The old cleanup must not cancel the newer job.
        pipeline.gateExecution = false
        viewModel.startProcessing()
        let completed = await waitUntil { viewModel.completedArtifacts != nil && !viewModel.isProcessing }
        XCTAssertTrue(completed)
        XCTAssertEqual(pipeline.executionCount, 2)
        // `isProcessing` clears just before the coordinator's terminal activity publication; wait for
        // the observable terminal state instead of assuming the async hop already ran (instrumented
        // schedules can reorder this without indicating a cancellation race).
        let publishedCompleted = await waitUntil {
            viewModel.liveActivityController.lastKnownState?.phase == .completed
        }
        XCTAssertTrue(publishedCompleted, "The old cleanup must not cancel the newer coordinator job")
        XCTAssertEqual(viewModel.liveActivityController.lastKnownState?.phase, .completed)
    }

    @MainActor
    private func batchWaitingAfterFirstPhoto(handoffManager: any StudioHandoffManaging = FakeHandoffManager()) async throws -> (
        StudioViewModel, FakePipelineExecutor, FakeDecoder, [LibraryPhotoItem], Task<Void, Never>
    ) {
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        let decoder = FakeDecoder()
        let vm = makeViewModel(decoder: decoder, pipeline: pipeline, handoffManager: handoffManager)
        let items = [StudioTestArtifacts.libraryItem(named: "foreground-batch-A.jpg"),
                     StudioTestArtifacts.libraryItem(named: "foreground-batch-B.jpg")]
        vm.daySections = [LibraryDaySection(id: "batch", displayTitle: "Batch", items: items)]
        let batch = Task { await vm.batchProcessSelected(ids: Set(items.map(\.id))) }
        let firstStarted = await waitUntil { pipeline.executionCount == 1 }
        XCTAssertTrue(firstStarted)
        await vm.handleScenePhaseChange(.background)
        pipeline.openExecutionGate()
        let waiting = await waitUntil { vm.isBatchWaitingForForeground }
        XCTAssertTrue(waiting)
        XCTAssertEqual(vm.batchPhotoNumber, 2)
        XCTAssertEqual(pipeline.executionCount, 1)
        XCTAssertFalse(decoder.recordedDecodeURLs.contains(items[1].fileURL))
        XCTAssertNotNil(vm.completedArtifacts, "Waiting must keep the last completed photo available")
        return (vm, pipeline, decoder, items, batch)
    }

    @MainActor
    func testBackgroundBatchRetainsQueueAndStartsNextPhotoOnlyAfterForeground() async throws {
        let (vm, pipeline, decoder, items, batch) = try await batchWaitingAfterFirstPhoto()
        defer { batch.cancel(); vm.cancelProcessing() }
        XCTAssertTrue(vm.isBatchProcessing)
        XCTAssertFalse(vm.isProcessing)
        XCTAssertEqual(vm.jobProgress.compactTitle, "Open app to continue")
        XCTAssertEqual(vm.jobProgress.compactSubtitle, "Photo 2 of 2 is queued")
        XCTAssertEqual(vm.jobProgress.compactPercentText, "")
        XCTAssertEqual(vm.jobProgress.remainingText, "Waiting for app")
        XCTAssertEqual(vm.jobProgress.elapsedSeconds, 0, "The previous photo's elapsed time is not the queued photo's timing")
        XCTAssertNil(vm.jobProgress.modelName)
        XCTAssertNil(vm.jobProgress.sourceWidth)
        XCTAssertNil(vm.jobProgress.outputWidth)
        await vm.handleScenePhaseChange(.active)
        await batch.value
        XCTAssertEqual(pipeline.executionCount, 2)
        XCTAssertTrue(decoder.recordedDecodeURLs.contains(items[1].fileURL))
        XCTAssertEqual(pipeline.maxConcurrentExecutions, 1)
        XCTAssertFalse(vm.isBatchProcessing)
        XCTAssertFalse(vm.isBatchWaitingForForeground)
        XCTAssertEqual(vm.currentStage, .readyForInspection)
    }

    @MainActor
    func testStopWhileBatchWaitsKeepsLastCompletedArtifactAndDoesNotOpenNextPhoto() async throws {
        let (vm, pipeline, decoder, items, batch) = try await batchWaitingAfterFirstPhoto()
        let completedID = vm.completedArtifacts?.checkpoint.config.id
        vm.cancelProcessing()
        await batch.value
        XCTAssertFalse(vm.isBatchProcessing)
        XCTAssertFalse(vm.isBatchWaitingForForeground)
        XCTAssertFalse(vm.isStopping)
        XCTAssertEqual(vm.completedArtifacts?.checkpoint.config.id, completedID)
        XCTAssertEqual(vm.currentStage, .readyForInspection)
        await vm.handleScenePhaseChange(.active)
        XCTAssertEqual(pipeline.executionCount, 1)
        XCTAssertFalse(decoder.recordedDecodeURLs.contains(items[1].fileURL))
    }

    @MainActor
    func testTaskCancellationRetiresBatchForegroundWaitWithoutAnotherSceneEvent() async throws {
        let (vm, pipeline, decoder, items, batch) = try await batchWaitingAfterFirstPhoto()
        batch.cancel()
        await batch.value
        XCTAssertFalse(vm.isBatchProcessing)
        XCTAssertFalse(vm.isBatchWaitingForForeground)
        XCTAssertNotNil(vm.completedArtifacts)
        await vm.handleScenePhaseChange(.active)
        XCTAssertEqual(pipeline.executionCount, 1)
        XCTAssertFalse(decoder.recordedDecodeURLs.contains(items[1].fileURL))
    }

    @MainActor
    func testResetWakesBatchForegroundWaitAndClearsOnlyCurrentPresentation() async throws {
        let (vm, pipeline, decoder, items, batch) = try await batchWaitingAfterFirstPhoto()
        vm.resetSession()
        await vm.waitForResetToFinish()
        await batch.value
        XCTAssertFalse(vm.isBatchProcessing)
        XCTAssertFalse(vm.isBatchWaitingForForeground)
        XCTAssertNil(vm.sourceURL)
        XCTAssertEqual(vm.currentStage, .idle)
        await vm.handleScenePhaseChange(.active)
        XCTAssertEqual(pipeline.executionCount, 1)
        XCTAssertFalse(decoder.recordedDecodeURLs.contains(items[1].fileURL))
    }

    @MainActor
    func testNewImportOrHandoffRetiresWaitingBatchWithoutReplacingNewPhoto() async throws {
        for handoff in [false, true] {
            let manager = FakeHandoffManager()
            let (vm, pipeline, decoder, items, batch) = try await batchWaitingAfterFirstPhoto(handoffManager: manager)
            let newer = try makeFile("foreground-new-\(handoff).jpg")
            if handoff {
                let payload = incomingPayload(for: newer)
                manager.configureConsumedPayload(payload)
                vm.handleIncomingHandoffURL(handoffDeepLink(for: payload))
                await vm.waitForHandoffConsumptionsToFinish()
            } else {
                await vm.ingestFile(at: newer)
            }
            await batch.value
            XCTAssertFalse(vm.isBatchProcessing)
            XCTAssertFalse(vm.isBatchWaitingForForeground)
            XCTAssertEqual(vm.sourceURL, newer)
            await vm.handleScenePhaseChange(.active)
            XCTAssertEqual(pipeline.executionCount, 1)
            XCTAssertFalse(decoder.recordedDecodeURLs.contains(items[1].fileURL))
            XCTAssertEqual(vm.sourceURL, newer)
        }
    }

    @MainActor
    func testBackgroundDuringNextBatchDecodeDefersItsInferenceUntilForeground() async throws {
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let decoder = FakeDecoder(), gate = TestGate()
        let vm = makeViewModel(decoder: decoder, pipeline: pipeline)
        let items = [StudioTestArtifacts.libraryItem(named: "decode-batch-A.jpg"),
                     StudioTestArtifacts.libraryItem(named: "decode-batch-B.jpg")]
        decoder.setGate(gate, forFileName: items[1].filename)
        vm.daySections = [LibraryDaySection(id: "batch", displayTitle: "Batch", items: items)]
        let batch = Task { await vm.batchProcessSelected(ids: Set(items.map(\.id))) }
        defer { gate.open(); batch.cancel(); vm.cancelProcessing() }
        await gate.entered.wait()
        XCTAssertEqual(pipeline.executionCount, 1)
        await vm.handleScenePhaseChange(.inactive)
        gate.open()
        let waiting = await waitUntil { vm.isBatchWaitingForForeground }
        XCTAssertTrue(waiting)
        XCTAssertEqual(pipeline.executionCount, 1)
        await vm.handleScenePhaseChange(.active)
        await batch.value
        XCTAssertEqual(pipeline.executionCount, 2)
        XCTAssertFalse(vm.isBatchWaitingForForeground)
    }

    @MainActor
    func testBatchStopsOnFailureAndCancellation() async throws {
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let decoder = FakeDecoder()
        let viewModel = makeViewModel(decoder: decoder, pipeline: pipeline)
        let items = [
            StudioTestArtifacts.libraryItem(named: "batch-1.jpg"),
            StudioTestArtifacts.libraryItem(named: "batch-2.jpg"),
            StudioTestArtifacts.libraryItem(named: "batch-3.jpg"),
        ]
        viewModel.daySections = [LibraryDaySection(id: "day", displayTitle: "Today", items: items)]

        pipeline.configureFailure(ScalerError.unsupportedImageFormat("batch failure"))
        await viewModel.batchProcessSelected(ids: Set(items.map(\.id)))
        XCTAssertEqual(pipeline.executionCount, 1, "A failed item must terminate the batch")
        XCTAssertEqual(viewModel.currentStage, .failed)

        // Cancellation inside a batch also terminates it instead of continuing with a stale scope.
        let cancellationPipeline = FakePipelineExecutor(directory: tempDirectory, pauseGate: TestGate())
        let secondViewModel = makeViewModel(decoder: FakeDecoder(), pipeline: cancellationPipeline)
        secondViewModel.daySections = [LibraryDaySection(id: "day", displayTitle: "Today", items: items)]
        let batch = Task { await secondViewModel.batchProcessSelected(ids: Set(items.map(\.id))) }
        _ = await waitUntil { cancellationPipeline.executionCount == 1 }
        secondViewModel.cancelProcessing()
        if let pauseGate = cancellationPipeline.pauseGate { pauseGate.open() }
        await secondViewModel.waitForStopToFinish()
        await batch.value
        XCTAssertEqual(cancellationPipeline.executionCount, 1, "A stopped item must terminate the batch")
    }

    @MainActor
    func testResetDuringStopDrainsAndDoesNotOverlapANewRun() async throws {
        let pauseGate = TestGate()
        let pipeline = FakePipelineExecutor(directory: tempDirectory, pauseGate: pauseGate)
        let urlA = try makeFile("reset-stop-A.jpg")
        let urlB = try makeFile("reset-stop-B.jpg")
        let viewModel = makeViewModel(decoder: FakeDecoder(), pipeline: pipeline)

        await viewModel.ingestFile(at: urlA)
        viewModel.startProcessing()
        _ = await waitUntil { pipeline.executionCount == 1 }

        viewModel.cancelProcessing()
        viewModel.resetSession()
        XCTAssertTrue(viewModel.isStopping)
        // A new run is refused while the old owner is still stopping/draining.
        viewModel.startProcessing()
        XCTAssertEqual(pipeline.executionCount, 1)

        pauseGate.open()
        await viewModel.waitForResetToFinish()
        XCTAssertFalse(viewModel.isProcessing)
        XCTAssertFalse(viewModel.isStopping)
        XCTAssertNil(viewModel.sourceURL)
        XCTAssertNil(viewModel.metadata)
        XCTAssertNil(viewModel.completedArtifacts)
        XCTAssertEqual(pipeline.cancelledExecutionCount, 1)

        // Once the reset drained, a fresh session can start a genuinely new run.
        pipeline.gateExecution = false
        await viewModel.ingestFile(at: urlB)
        viewModel.startProcessing()
        let completed = await waitUntil { viewModel.completedArtifacts != nil && !viewModel.isProcessing }
        XCTAssertTrue(completed)
        XCTAssertEqual(pipeline.executionCount, 2)
        XCTAssertEqual(pipeline.maxConcurrentExecutions, 1)
        XCTAssertEqual(viewModel.liveActivityController.lastKnownState?.phase, .completed)
    }

    // MARK: - R6: incoming payload state reaches execution (no double denoise)

    @MainActor
    func testIncomingHandoffSessionStateReachesExecutionAndPreventsDoubleDenoise() async throws {
        let handoff = FakeHandoffManager()
        let decoder = FakeDecoder()
        let sourceURL = try makeFile("incoming-untagged.jpg")
        let payload = SharedSuiteHandoffPayload(
            sourceApp: .truongNoiser,
            targetApp: .truongScaler,
            imageFileURLPath: sourceURL.path,
            originalFileName: sourceURL.lastPathComponent,
            isDenoised: true,
            isUpscaled: false,
            globalMaxLuminance: 1.2,
            upscaleFactor: nil,
            globalMaxLinearComponent: 2.5
        )
        handoff.configureConsumedPayload(payload)

        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(
            decoder: decoder,
            pipeline: pipeline,
            handoffManager: handoff
        )

        viewModel.handleIncomingHandoffURL(URL(string: "truongscaler://handoff?id=\(payload.handoffID.uuidString)")!)
        let applied = await waitUntil { viewModel.metadata?.isAlreadyDenoisedBySuite == true }
        XCTAssertTrue(applied)
        XCTAssertEqual(viewModel.metadata?.linearHeadroomScale ?? 0, 2.5, accuracy: 0.0001)

        viewModel.startProcessing()
        let executed = await waitUntil { pipeline.executionCount == 1 && !viewModel.isProcessing }
        XCTAssertTrue(executed)

        let execution = try XCTUnwrap(pipeline.recordedExecutions.first)
        XCTAssertEqual(execution.config.sessionState?.isDenoised, true)
        XCTAssertEqual(execution.config.sessionState?.linearHeadroomScale ?? 0, 2.5, accuracy: 0.0001)
        XCTAssertEqual(execution.mergedIsDenoised, true)
        XCTAssertFalse(
            execution.shouldRunDenoiserAuto,
            "An untagged JPEG handed off as already denoised must not run the retired denoise stage in auto mode"
        )
        XCTAssertEqual(
            viewModel.completedArtifacts?.checkpoint.didRunDenoise,
            false
        )
    }

    @MainActor
    func testIncomingHandoffFalseAndPreDenoiseOffStayExplicit() async throws {
        let handoff = FakeHandoffManager()
        let sourceURL = try makeFile("incoming-flagged.jpg")
        let payload = SharedSuiteHandoffPayload(
            sourceApp: .truongNoiser,
            targetApp: .truongScaler,
            imageFileURLPath: sourceURL.path,
            originalFileName: sourceURL.lastPathComponent,
            isDenoised: false,
            isUpscaled: false,
            globalMaxLuminance: 1.0,
            upscaleFactor: nil,
            globalMaxLinearComponent: 1.0
        )
        handoff.configureConsumedPayload(payload)

        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(
            decoder: FakeDecoder(),
            pipeline: pipeline,
            handoffManager: handoff
        )
        viewModel.handleIncomingHandoffURL(URL(string: "truongscaler://handoff?id=\(payload.handoffID.uuidString)")!)
        _ = await waitUntil { viewModel.metadata != nil }
        XCTAssertEqual(viewModel.metadata?.isAlreadyDenoisedBySuite, false)

        viewModel.startProcessing()
        _ = await waitUntil { pipeline.executionCount == 1 && !viewModel.isProcessing }
        let execution = try XCTUnwrap(pipeline.recordedExecutions.first)
        XCTAssertEqual(execution.config.denoiseMode, .off)
        XCTAssertEqual(execution.config.sessionState?.isDenoised, false)
    }

    @MainActor
    func testMissingAppGroupHandoffIsActionableAndDoesNotLaunch() async throws {
        let exporter = FakeExporter()
        exporter.configure(finalPeak: 2.0, actualScaleFactor: 4)
        let handoff = FakeHandoffManager()
        handoff.packageError = ScalerError.appGroupUnavailable(
            identifier: AppGroupHandoffManager.appGroupIdentifier
        )
        let opener = RecordingOpener()
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(
            exporter: exporter,
            pipeline: pipeline,
            handoffManager: handoff,
            externalOpener: opener
        )
        let sourceURL = try makeFile("missing-group.jpg")
        viewModel.sourceURL = sourceURL
        viewModel.metadata = ImageMetadataPacket(
            sourceURL: sourceURL,
            utTypeIdentifier: "public.jpeg",
            category: .standardOpaqueRaster,
            originalWidth: 8,
            originalHeight: 6
        )

        await viewModel.sendToTruongNoiser()

        XCTAssertTrue(opener.openedURLs.isEmpty)
        let message = try XCTUnwrap(viewModel.errorMessage)
        XCTAssertTrue(message.contains(AppGroupHandoffManager.appGroupIdentifier), "The missing App Group must be actionable")
        XCTAssertTrue(message.contains("App Group"), message)
    }

    // MARK: - R6: outgoing handoff derives from the frozen artifact/session

    @MainActor
    func testOutgoingHandoffUsesCheckpointDenoiseAndFinalExportHeadroom() async throws {
        let exporter = FakeExporter()
        exporter.configure(finalPeak: 4.0, actualScaleFactor: 4)
        let handoff = FakeHandoffManager()
        let opener = RecordingOpener()
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(
            exporter: exporter,
            pipeline: pipeline,
            handoffManager: handoff,
            externalOpener: opener
        )

        let sourceURL = try makeFile("headroom-source.jpg")
        let artifacts = try StudioTestArtifacts.make(
            directory: tempDirectory,
            sourceURL: sourceURL,
            configuredScale: .x2,
            backbone: .unavailable,
            redPeak: 4.0,
            grain: 0.25,
            didRunDenoise: true,
            inputComponentPeak: 1.0,
            inputLuminance: 1.5
        )
        viewModel.sourceURL = sourceURL
        viewModel.metadata = artifacts.metadata
        viewModel.completedArtifacts = artifacts

        await viewModel.sendToTruongNoiser()

        let call = try XCTUnwrap(handoff.packageCalls.first)
        XCTAssertTrue(call.isDenoised, "checkpoint.didRunDenoise must be forwarded")
        XCTAssertTrue(call.isUpscaled)
        XCTAssertEqual(call.upscaleFactor, 4, "Legacy output is really 4x even when 2x was selected")
        XCTAssertEqual(call.globalMaxLinearComponent, 4.0, accuracy: 0.0001, "Headroom is the final export peak, not the input checkpoint")
        XCTAssertEqual(call.globalMaxLuminance, 1.5, accuracy: 0.0001)
        XCTAssertEqual(opener.openedURLs.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: call.exportedImageURL.path), "A staged send must retire its private export intermediate")
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data([0x01, 0x02]))
    }

    @MainActor
    func testOutgoingHandoffCleansPartialExportFailure() async throws {
        let exporter = PartialHandoffFailureExporter()
        let handoff = FakeHandoffManager(), opener = RecordingOpener()
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(exporter: exporter, pipeline: pipeline, handoffManager: handoff, externalOpener: opener)
        let sourceURL = try makeFile("partial-handoff-source.jpg")
        let artifacts = try StudioTestArtifacts.make(directory: tempDirectory, sourceURL: sourceURL)
        viewModel.sourceURL = sourceURL; viewModel.metadata = artifacts.metadata; viewModel.completedArtifacts = artifacts

        await viewModel.sendToTruongNoiser()

        let writtenURL = await exporter.writtenURL
        let intermediate = try XCTUnwrap(writtenURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: intermediate.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data([0x01, 0x02]))
        XCTAssertTrue(handoff.packageCalls.isEmpty)
        XCTAssertTrue(opener.openedURLs.isEmpty)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    @MainActor
    func testOutgoingHandoffCleansIntermediateWhenStagingFails() async throws {
        let exporter = FakeExporter(), handoff = FakeHandoffManager(), opener = RecordingOpener()
        handoff.packageError = ScalerError.appGroupUnavailable(identifier: AppGroupHandoffManager.appGroupIdentifier)
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(exporter: exporter, pipeline: pipeline, handoffManager: handoff, externalOpener: opener)
        let sourceURL = try makeFile("failed-handoff-staging.jpg")
        let artifacts = try StudioTestArtifacts.make(directory: tempDirectory, sourceURL: sourceURL)
        viewModel.sourceURL = sourceURL; viewModel.metadata = artifacts.metadata; viewModel.completedArtifacts = artifacts

        await viewModel.sendToTruongNoiser()

        let intermediate = try XCTUnwrap(exporter.recordedCalls.first?.destinationURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: intermediate.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data([0x01, 0x02]))
        XCTAssertTrue(opener.openedURLs.isEmpty)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    @MainActor
    func testForwardingAlreadyUpscaledFileWithoutProcessingPreservesTrue() async throws {
        let exporter = FakeExporter()
        let handoff = FakeHandoffManager()
        let opener = RecordingOpener()
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(
            exporter: exporter,
            pipeline: pipeline,
            handoffManager: handoff,
            externalOpener: opener
        )
        let sourceURL = try makeFile("forwarded-upscaled.dng")
        viewModel.sourceURL = sourceURL
        viewModel.metadata = ImageMetadataPacket(
            sourceURL: sourceURL,
            utTypeIdentifier: "com.adobe.dng",
            category: .cameraRAW,
            originalWidth: 8,
            originalHeight: 6,
            isAlreadyDenoisedBySuite: true,
            isAlreadyUpscaledBySuite: true,
            upscaledByAppFactor: 4,
            linearHeadroomScale: 2.5
        )
        viewModel.completedArtifacts = nil

        await viewModel.sendToTruongNoiser()

        XCTAssertTrue(exporter.recordedCalls.isEmpty, "Forwarding must not run a new export/processing pass")
        let call = try XCTUnwrap(handoff.packageCalls.first)
        XCTAssertTrue(call.isDenoised)
        XCTAssertTrue(call.isUpscaled, "Forwarding an already-upscaled file must preserve isUpscaled")
        XCTAssertEqual(call.upscaleFactor, 4)
        XCTAssertEqual(call.globalMaxLinearComponent, 2.5, accuracy: 0.0001)
        XCTAssertEqual(opener.openedURLs.count, 1)
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data([0x01, 0x02]), "Direct forwarding never owns the source for deletion")
    }

    @MainActor
    func testStaleHandoffIsNeverLaunchedAfterSessionChange() async throws {
        let exporter = FakeExporter()
        exporter.configure(finalPeak: 2.0, actualScaleFactor: 4)
        let handoff = FakeHandoffManager()
        let packageGate = TestGate()
        handoff.packageGate = packageGate
        let opener = RecordingOpener()
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(
            decoder: FakeDecoder(),
            exporter: exporter,
            pipeline: pipeline,
            handoffManager: handoff,
            externalOpener: opener
        )

        let sourceURL = try makeFile("stale-source.jpg")
        let artifacts = try StudioTestArtifacts.make(directory: tempDirectory, sourceURL: sourceURL)
        viewModel.sourceURL = sourceURL
        viewModel.metadata = artifacts.metadata
        viewModel.completedArtifacts = artifacts

        let send = Task { await viewModel.sendToTruongNoiser() }
        await packageGate.entered.wait()
        let intermediate = try XCTUnwrap(exporter.recordedCalls.first?.destinationURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: intermediate.path))

        // The session changes while the handoff package is still being staged.
        let newURL = try makeFile("stale-new.jpg")
        await viewModel.ingestFile(at: newURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: intermediate.path), "Staging retains its input until the await drains")
        packageGate.open()
        await send.value

        XCTAssertTrue(opener.openedURLs.isEmpty, "A previous session's export must never launch for a newer session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: intermediate.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data([0x01, 0x02]))
        XCTAssertEqual(try Data(contentsOf: newURL), Data([0x01, 0x02]))
    }

    // MARK: - R6: real export -> manifest -> reingest agreement

    @MainActor
    func testRealExportManifestAndReingestedFileAgreeOnFlagsFactorAndHeadroom() async throws {
        let handoffBase = tempDirectory.appendingPathComponent("handoffs", isDirectory: true)
        try FileManager.default.createDirectory(at: handoffBase, withIntermediateDirectories: true)
        let handoffManager = AppGroupHandoffManagerSeam(overrideBaseDirectory: handoffBase)
        let opener = RecordingOpener()
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(
            exporter: BlockingStudioImageExporter(),
            pipeline: pipeline,
            handoffManager: handoffManager,
            externalOpener: opener
        )

        let sourceURL = try makeFile("real-chain-source.jpg")
        let artifacts = try StudioTestArtifacts.make(
            directory: tempDirectory,
            sourceURL: sourceURL,
            configuredScale: .x2,
            backbone: .unavailable,
            redPeak: 4.0,
            grain: 0.25,
            didRunDenoise: true,
            inputComponentPeak: 1.0,
            inputLuminance: 1.5
        )
        viewModel.sourceURL = sourceURL
        viewModel.metadata = artifacts.metadata
        viewModel.completedArtifacts = artifacts

        await viewModel.sendToTruongNoiser()
        let deepLink = try XCTUnwrap(opener.openedURLs.first)

        // The outgoing manifest targets TruongNoiser, so decode it directly (the inbound consumer
        // intentionally rejects a manifest whose target is not TruongScaler).
        let manifestURLs = try FileManager.default.contentsOfDirectory(
            at: handoffBase,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        let manifestURL = try XCTUnwrap(manifestURLs.first)
        let payload = try JSONDecoder().decode(
            SharedSuiteHandoffPayload.self,
            from: try Data(contentsOf: manifestURL)
        )
        XCTAssertTrue(deepLink.absoluteString.contains(payload.handoffID.uuidString))
        XCTAssertTrue(payload.isDenoised)
        XCTAssertTrue(payload.isUpscaled)
        XCTAssertEqual(payload.upscaleFactor, 4)
        XCTAssertGreaterThan(payload.globalMaxLinearComponent, 1.5, "Final grain-blended HDR peak must be forwarded")
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.imageFileURLPath), "The App Group's actual copied handoff survives intermediate cleanup")
        let privateIntermediates = try FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("handoff_") && $0.pathExtension == "dng" }
        XCTAssertTrue(privateIntermediates.isEmpty)

        // Reingest the actual exported file with the production CoreIngestion reader and compare the
        // embedded suite state with the manifest.
        let reingestDestination = tempDirectory.appendingPathComponent("reingested-\(UUID().uuidString).bin")
        let decoded = try UniversalStripDecoder.decodeToMMap(
            imageURL: URL(fileURLWithPath: payload.imageFileURLPath),
            destinationMMapURL: reingestDestination
        )
        XCTAssertEqual(decoded.metadata.isAlreadyDenoisedBySuite, payload.isDenoised)
        XCTAssertEqual(decoded.metadata.isAlreadyUpscaledBySuite, payload.isUpscaled)
        XCTAssertEqual(decoded.metadata.upscaledByAppFactor, payload.upscaleFactor)
        XCTAssertEqual(
            Double(decoded.metadata.linearHeadroomScale ?? 0),
            Double(payload.globalMaxLinearComponent),
            accuracy: 0.05,
            "The embedded DNG headroom and the manifest must agree"
        )
    }

    // MARK: - C3a: incoming-handoff ingress ownership

    @MainActor
    func testGatedIncomingHandoffThenResetCannotResurrectTheSession() async throws {
        let handoff = FakeHandoffManager()
        let gate = TestGate()
        let decoder = FakeDecoder()
        let lateURL = try makeFile("late-handoff.jpg")
        let payload = incomingPayload(for: lateURL)
        let link = handoffDeepLink(for: payload)
        handoff.setConsumeGate(gate, forDeepLink: link)
        handoff.configureConsumedPayload(payload, forDeepLink: link)

        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(
            decoder: decoder,
            pipeline: pipeline,
            handoffManager: handoff
        )

        viewModel.handleIncomingHandoffURL(link)
        await gate.entered.wait()
        XCTAssertNil(viewModel.sourceURL)

        viewModel.resetSession()
        await viewModel.waitForResetToFinish()
        XCTAssertNil(viewModel.sourceURL)

        // The late payload arrives after the reset fully drained.
        gate.open()
        await viewModel.waitForIngestTasksToFinish()

        XCTAssertNil(viewModel.sourceURL, "A late consumed payload must not resurrect a reset session")
        XCTAssertNil(viewModel.metadata)
        XCTAssertTrue(
            decoder.recordedDecodeURLs.isEmpty,
            "A superseded handoff payload must never reach decode/ingest"
        )
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testGatedIncomingHandoffThenSelectingAnotherPhotoKeepsTheUserSelection() async throws {
        let handoff = FakeHandoffManager()
        let gate = TestGate()
        let decoder = FakeDecoder()
        let lateURL = try makeFile("late-handoff-select.jpg")
        let userURL = try makeFile("user-choice.jpg")
        let payload = incomingPayload(for: lateURL)
        let link = handoffDeepLink(for: payload)
        handoff.setConsumeGate(gate, forDeepLink: link)
        handoff.configureConsumedPayload(payload, forDeepLink: link)

        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(
            decoder: decoder,
            pipeline: pipeline,
            handoffManager: handoff
        )

        viewModel.handleIncomingHandoffURL(link)
        await gate.entered.wait()

        // The user picks another photo while the handoff is still being consumed.
        await viewModel.ingestFile(at: userURL)
        XCTAssertEqual(viewModel.sourceURL, userURL)

        gate.open()
        await viewModel.waitForIngestTasksToFinish()

        XCTAssertEqual(viewModel.sourceURL, userURL, "The late handoff must not replace the newer selection")
        XCTAssertEqual(viewModel.metadata?.sourceURL, userURL)
        XCTAssertEqual(decoder.recordedDecodeURLs, [userURL], "Only the user's selection may be decoded")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testOutOfOrderIncomingHandoffsNewestWins() async throws {
        let handoff = FakeHandoffManager()
        let gateOld = TestGate()
        let gateNew = TestGate()
        let decoder = FakeDecoder()
        let oldURL = try makeFile("handoff-old.jpg")
        let newURL = try makeFile("handoff-new.jpg")
        let oldPayload = incomingPayload(for: oldURL)
        let newPayload = incomingPayload(for: newURL)
        let oldLink = handoffDeepLink(for: oldPayload)
        let newLink = handoffDeepLink(for: newPayload)
        handoff.setConsumeGate(gateOld, forDeepLink: oldLink)
        handoff.setConsumeGate(gateNew, forDeepLink: newLink)
        handoff.configureConsumedPayload(oldPayload, forDeepLink: oldLink)
        handoff.configureConsumedPayload(newPayload, forDeepLink: newLink)

        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(
            decoder: decoder,
            pipeline: pipeline,
            handoffManager: handoff
        )

        viewModel.handleIncomingHandoffURL(oldLink)
        await gateOld.entered.wait()
        viewModel.handleIncomingHandoffURL(newLink)
        await gateNew.entered.wait()

        // The newer handoff completes first; the older one is still blocked.
        gateNew.open()
        let newApplied = await waitUntil {
            viewModel.sourceURL == newURL && viewModel.metadata?.sourceURL == newURL
        }
        XCTAssertTrue(newApplied)

        gateOld.open()
        await viewModel.waitForIngestTasksToFinish()

        XCTAssertEqual(viewModel.sourceURL, newURL, "Newest handoff wins")
        XCTAssertEqual(viewModel.metadata?.sourceURL, newURL)
        XCTAssertEqual(
            decoder.recordedDecodeURLs,
            [newURL],
            "An out-of-order older payload must be discarded instead of ingesting"
        )
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testLateIncomingHandoffErrorCannotOverwriteNewerState() async throws {
        let handoff = FakeHandoffManager()
        let gateOld = TestGate()
        let oldLink = URL(string: "truongscaler://handoff?id=\(UUID().uuidString)")!
        let newLink = URL(string: "truongscaler://handoff?id=\(UUID().uuidString)")!
        handoff.setConsumeGate(gateOld, forDeepLink: oldLink)
        handoff.setConsumeError(
            ScalerError.unsupportedImageFormat("old handoff failure"),
            forDeepLink: oldLink
        )
        handoff.setConsumeError(
            ScalerError.unsupportedImageFormat("new handoff failure"),
            forDeepLink: newLink
        )

        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(pipeline: pipeline, handoffManager: handoff)

        viewModel.handleIncomingHandoffURL(oldLink)
        await gateOld.entered.wait()
        viewModel.handleIncomingHandoffURL(newLink)
        let newerPublished = await waitUntil {
            viewModel.errorMessage?.contains("new handoff failure") == true
        }
        XCTAssertTrue(newerPublished)

        gateOld.open()
        await viewModel.waitForIngestTasksToFinish()

        let message = try XCTUnwrap(viewModel.errorMessage)
        XCTAssertTrue(message.contains("new handoff failure"), message)
        XCTAssertFalse(message.contains("old handoff failure"), "A superseded consume error must not publish")
    }

    // MARK: - C3b: unconditional reset cleanup and drain identity

    @MainActor
    func testResetSupersededByIngestReleasesTheCapturedOldSelection() async throws {
        let scope = RecordingScopeProvider()
        let gate = TestGate()
        let pipeline = FakePipelineExecutor(directory: tempDirectory, pauseGate: gate)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(pipeline: pipeline, scopeProvider: scope)
        let oldURL = try makeFile("before-reset.jpg")
        let newURL = try makeFile("after-reset.jpg")

        await viewModel.ingestFile(at: oldURL)
        XCTAssertEqual(scope.activeGrantCount(for: oldURL), 1)

        viewModel.resetSession()
        await gate.entered.wait()

        // Ingest B supersedes the still-blocked reset.
        let newer = Task { await viewModel.ingestFile(at: newURL) }
        let selected = await waitUntil { viewModel.sourceURL == newURL }
        XCTAssertTrue(selected)

        gate.open()
        await newer.value
        await viewModel.waitForResetToFinish()

        XCTAssertEqual(viewModel.sourceURL, newURL)
        XCTAssertEqual(
            scope.activeGrantCount(for: oldURL),
            0,
            "A reset superseded by ingest B must still release A's selection grant"
        )
        XCTAssertTrue(
            scope.grants(for: oldURL).allSatisfy { $0.releaseCallCount == 1 },
            "A's captured selection must be released exactly once"
        )
        XCTAssertGreaterThan(
            scope.activeGrantCount(for: newURL),
            0,
            "The reset must never release the newer selection"
        )
        XCTAssertFalse(viewModel.isStopping)

        viewModel.resetSession()
        await viewModel.waitForResetToFinish()
        XCTAssertEqual(scope.activeGrantCount(for: newURL), 0)
    }

    @MainActor
    func testResetWithActiveReadersDrainsAndReleasesSourceGrantExactlyOnce() async throws {
        let scope = RecordingScopeProvider()
        let pauseGate = TestGate()
        let pipeline = FakePipelineExecutor(directory: tempDirectory, pauseGate: pauseGate)
        let viewModel = makeViewModel(pipeline: pipeline, scopeProvider: scope)
        let url = try makeFile("reset-reader.jpg")

        await viewModel.ingestFile(at: url)
        viewModel.startProcessing()
        let started = await waitUntil { pipeline.executionCount == 1 }
        XCTAssertTrue(started)

        viewModel.resetSession()
        await pauseGate.entered.wait()

        // The execution still owns a source reader; the reset may not release its grant early.
        XCTAssertGreaterThanOrEqual(scope.activeGrantCount(for: url), 2)
        XCTAssertTrue(viewModel.isStopping)

        pauseGate.open()
        await viewModel.waitForResetToFinish()

        XCTAssertNil(viewModel.sourceURL)
        XCTAssertEqual(scope.activeGrantCount(for: url), 0)
        XCTAssertTrue(
            scope.grants(for: url).allSatisfy { $0.releaseCallCount == 1 },
            "The old source selection and its reader must each release exactly once"
        )
        XCTAssertEqual(pipeline.cancelledExecutionCount, 1)
        XCTAssertEqual(scope.uniqueGrantIdentifiers, scope.acquiredCount)
    }

    @MainActor
    func testLateSupersededResetDrainCannotCancelOrStopTheNewerJob() async throws {
        let pauseGate = TestGate()
        let pipeline = FakePipelineExecutor(directory: tempDirectory, pauseGate: pauseGate)
        let viewModel = makeViewModel(pipeline: pipeline)
        let oldURL = try makeFile("drain-old.jpg")
        let newURL = try makeFile("drain-new.jpg")

        await viewModel.ingestFile(at: oldURL)
        viewModel.startProcessing()
        _ = await waitUntil { pipeline.executionCount == 1 }

        viewModel.cancelProcessing()
        viewModel.resetSession()
        await pauseGate.entered.wait()

        let newerSelection = Task { await viewModel.ingestFile(at: newURL) }
        _ = await waitUntil { viewModel.sourceURL == newURL }
        XCTAssertEqual(viewModel.sourceURL, newURL)

        pauseGate.open()
        await newerSelection.value
        await viewModel.waitForResetToFinish()
        XCTAssertEqual(viewModel.sourceURL, newURL)
        XCTAssertFalse(viewModel.isStopping)

        // The superseded reset's late drain must not have cancelled or interrupted the new run.
        pipeline.gateExecution = false
        viewModel.startProcessing()
        let completed = await waitUntil { viewModel.completedArtifacts != nil && !viewModel.isProcessing }
        XCTAssertTrue(completed)
        XCTAssertEqual(pipeline.executionCount, 2)
        XCTAssertEqual(viewModel.liveActivityController.lastKnownState?.phase, .completed)
        XCTAssertFalse(viewModel.isStopping)
    }

    // MARK: - C3c: actual thumbnail read ownership

    @MainActor
    func testBlockedThumbnailReadSurvivesFolderSwitchAndDiscardsStaleImage() async throws {
        let scope = RecordingScopeProvider()
        let scanner = FakeScanner()
        let folderA = tempDirectory.appendingPathComponent("thumbA", isDirectory: true)
        let folderB = tempDirectory.appendingPathComponent("thumbB", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        let itemA = LibraryPhotoItem(
            id: "thumb-A",
            fileURL: folderA.appendingPathComponent("thumb-A.jpg"),
            filename: "thumb-A.jpg",
            capturedAt: Date(timeIntervalSince1970: 0),
            byteCount: 1
        )
        let itemB = LibraryPhotoItem(
            id: "thumb-B",
            fileURL: folderB.appendingPathComponent("thumb-B.jpg"),
            filename: "thumb-B.jpg",
            capturedAt: Date(timeIntervalSince1970: 0),
            byteCount: 1
        )
        scanner.setItems([itemA], forFolderName: "thumbA")
        scanner.setItems([itemB], forFolderName: "thumbB")

        let gate = TestGate()
        let reader = GatedThumbnailReader(gate: gate, image: makeThumbnailImage())
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(
            scanner: scanner,
            thumbnailReader: reader,
            pipeline: pipeline,
            scopeProvider: scope
        )

        await viewModel.setLibraryFolder(url: folderA)
        XCTAssertEqual(viewModel.orderedLibraryItems.map(\.id), [itemA.id])

        let read = Task { await viewModel.loadLibraryThumbnail(for: itemA) }
        await gate.entered.wait()
        XCTAssertEqual(reader.requests, [itemA.fileURL])
        XCTAssertEqual(viewModel.libraryOperationCount, 1)
        XCTAssertEqual(
            scope.activeGrantCount(for: folderA),
            2,
            "The selection root grant plus the independent thumbnail read grant must both be held"
        )

        // The user switches folders while the production read is still in ImageIO.
        await viewModel.setLibraryFolder(url: folderB)
        XCTAssertEqual(viewModel.libraryFolderURL, folderB)
        XCTAssertEqual(viewModel.orderedLibraryItems.map(\.id), [itemB.id])
        XCTAssertGreaterThanOrEqual(
            scope.activeGrantCount(for: folderA),
            1,
            "The released folder's root grant must survive its still-running thumbnail read"
        )
        XCTAssertEqual(viewModel.libraryOperationCount, 1)

        gate.open()
        let staleImage = await read.value

        XCTAssertNil(staleImage, "A thumbnail from a released folder must not be published")
        XCTAssertEqual(viewModel.libraryOperationCount, 0)
        XCTAssertEqual(scope.activeGrantCount(for: folderA), 0)
        XCTAssertTrue(
            scope.grants(for: folderA).allSatisfy { $0.releaseCallCount == 1 },
            "Every released-folder grant must close exactly once after the read drains"
        )
        XCTAssertGreaterThan(scope.activeGrantCount(for: folderB), 0)
        XCTAssertEqual(scope.uniqueGrantIdentifiers, scope.acquiredCount)
    }

    @MainActor
    func testCancelledThumbnailReadReleasesSelectedFolderGrantExactlyOnce() async throws {
        let scope = RecordingScopeProvider()
        let scanner = FakeScanner()
        let folderA = tempDirectory.appendingPathComponent("thumbCancel", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        let itemA = LibraryPhotoItem(
            id: "cancel-A",
            fileURL: folderA.appendingPathComponent("cancel-A.jpg"),
            filename: "cancel-A.jpg",
            capturedAt: Date(timeIntervalSince1970: 0),
            byteCount: 1
        )
        scanner.setItems([itemA], forFolderName: "thumbCancel")

        let gate = CancellableGate()
        let reader = CancellableGatedThumbnailReader(gate: gate, image: makeThumbnailImage())
        let pipeline = FakePipelineExecutor(directory: tempDirectory)
        pipeline.gateExecution = false
        let viewModel = makeViewModel(
            scanner: scanner,
            thumbnailReader: reader,
            pipeline: pipeline,
            scopeProvider: scope
        )

        await viewModel.setLibraryFolder(url: folderA)
        let read = Task { await viewModel.loadLibraryThumbnail(for: itemA) }
        let started = await waitUntil {
            reader.requests == [itemA.fileURL] && viewModel.libraryOperationCount == 1
        }
        XCTAssertTrue(started)

        // Release the selected folder while its thumbnail read is blocked; its grant stays open.
        viewModel.releaseLibraryFolder()
        XCTAssertNil(viewModel.libraryFolderURL)
        XCTAssertTrue(viewModel.daySections.isEmpty)
        XCTAssertEqual(
            scope.activeGrantCount(for: folderA),
            2,
            "Release must not close the root grant while its thumbnail read is still running"
        )

        read.cancel()
        let staleImage = await read.value

        XCTAssertNil(staleImage, "A cancelled thumbnail read must not publish an image")
        XCTAssertEqual(viewModel.libraryOperationCount, 0)
        XCTAssertEqual(scope.activeGrantCount(for: folderA), 0)
        for grant in scope.grants(for: folderA) {
            XCTAssertEqual(grant.releaseCallCount, 1, "Each folder grant must be released exactly once")
        }
    }
}
