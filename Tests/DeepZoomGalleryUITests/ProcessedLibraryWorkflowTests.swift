import XCTest
import Foundation
import CoreML
import CoreExport
#if canImport(UIKit)
import UIKit
import SwiftUI
import ActivityKit
#endif
import TruongScalerCore
import TiledInferenceEngine
import BackgroundJobManager
@testable import DeepZoomGalleryUI

/// Real ImageIO → mmap → tiled pipeline → real export → portable record → decode/reopen.
/// The lifecycle fixture explicitly uses the test-only resampler; trained predictions have their
/// own required-model suite and are never substituted in the app.
final class ProcessedLibraryWorkflowTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryWorkflow-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func folder(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @MainActor private func make(_ name: String, defaults: UserDefaults, exporter: any StudioImageExporting = BlockingStudioImageExporter(), decoder: any StudioImageDecoding = BlockingStudioImageDecoder(), sharePreparer: any StudioPhotoSharePreparing = PhotoSharePreparer(), resultStore: ProcessedLibraryStore = ProcessedLibraryStore(), folderIO: any LibraryFolderIO = BlockingLibraryFolderIO()) throws -> StudioViewModel {
        let work = try folder(name)
        let registry = CoreMLModelRegistry(initialComputeUnits: .cpuOnly, availabilityPolicy: .allowDeterministicFallback)
        let executor = TiledPipelineExecutor(workingDirectory: work, modelRegistry: registry, checkpointStore: JobCheckpointStore(directory: work))
        return StudioViewModel(workingDirectory: work, pipelineExecutor: executor,
            pipeline: TiledExecutorPipelineAdapter(executor: executor), decoder: decoder,
            exporter: exporter, scanner: BlockingLibraryScanner(), handoffManager: FakeHandoffManager(),
            externalOpener: RecordingOpener(), scopeProvider: RecordingScopeProvider(),
            backgroundTaskRouter: BackgroundTaskDeliveryRouter(), defaults: defaults, folderIO: folderIO, requiresOutputFolder: true,
            sharePreparer: sharePreparer, resultStore: resultStore)
    }
    @MainActor private func settle(_ vm: StudioViewModel) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while (vm.isProcessing || vm.ownedExecutionCount > 0) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(vm.isProcessing)
        XCTAssertEqual(vm.ownedExecutionCount, 0)
        XCTAssertEqual(vm.currentStage, .readyForInspection, vm.errorMessage ?? "")
    }
    #if canImport(UIKit)
    @MainActor private func capture<V: View>(_ view: V, name: String) async throws {
        let size = CGSize(width: 402, height: 874)
        let host = UIHostingController(rootView: view.preferredColorScheme(.dark).tint(.green)
            .frame(width: size.width, height: size.height))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        for _ in 0..<8 { window.layoutIfNeeded(); host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
        let image = UIGraphicsImageRenderer(size: size).image { context in host.view.layer.render(in: context.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        XCTAssertGreaterThan(stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 120 }.count, 200,
            "The actual hosted UI must be visible in its screenshot")
        let path = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TRUONGSCALER_QUALITY_EVIDENCE_DIR"] ?? "/tmp/truongscaler-library-evidence")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try image.pngData()?.write(to: path.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        window.isHidden = true
    }
    @MainActor func testModernAppUsesSystemActivityOnlyAndKeepsLifecycleIdentity() async throws {
        let suite = "LibraryActivity-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = try make("activity", defaults: defaults)
        XCTAssertEqual(vm.liveActivityController.presentationMode, .systemContinuation)
        let controller = vm.liveActivityController
        let existing = Set(Activity<UpscaleActivityAttributes>.activities.map(\.id))
        let accepted = await controller.startActivity(jobID: UUID(), sourceFileName: "photo.dng", scaleFactor: .x2,
            targetWidth: 96, targetHeight: 64, totalTiles: 12, ifNewerThanRequestIdentity: 100)
        XCTAssertTrue(accepted)
        await controller.updateProgress(stageTitle: "Upscaling", completedTiles: 3, totalTiles: 12,
            progressFraction: 0.25, estimatedSecondsRemaining: 10, forceImmediate: true)
        XCTAssertEqual(controller.lastKnownState?.completedTiles, 3)
        XCTAssertEqual(Set(Activity<UpscaleActivityAttributes>.activities.map(\.id)), existing,
            "No custom ActivityKit card may be created beside the system continued-processing card")
        let stale = await controller.markFailed(completedTiles: 0, totalTiles: 12, message: "old", ifActivityIdentity: 99)
        XCTAssertFalse(stale)
        await controller.markCompleted(completedTiles: 12, totalTiles: 12, finalMessage: "Saved")
        XCTAssertNil(controller.activityLifecycleIdentity)
    }
    #endif

    @MainActor func testFolderChangeDuringOutputVerificationRetiresLoadingWithoutOverwritingNewPhoto() async throws {
        for corruptOutput in [false, true] {
            for replacePhoto in [false, true] {
                let key = "\(corruptOutput)-\(replacePhoto)"
                let suite = "OutputVerificationRoot-\(UUID())", defaults = UserDefaults(suiteName: suite)!
                defer { defaults.removePersistentDomain(forName: suite) }
                let first = try folder("verify-first-" + key), second = try folder("verify-second-" + key)
                let source = try RealPipelineImageFixture.makePNG(in: directory, name: "verify-source-" + key + ".png")
                let exported = try RealPipelineImageFixture.makePNG(in: directory, name: "verify-export-" + key + ".png", width: 96, height: 64)
                let store = ProcessedLibraryStore()
                let original = try await store.archiveOriginal(at: source, named: source.lastPathComponent, under: first)
                let draft = ProcessedPhotoDraft(id: UUID(), modelRawValue: BackboneModelKind.quickSRNet.rawValue,
                    sourceWidth: 48, sourceHeight: 32, outputWidth: 96, outputHeight: 64,
                    scaleFactor: 2, grainAmount: 0, processedAt: Date(), formatRawValue: ExportFormat.png16Bit.rawValue)
                let record = try await store.publish(exportedURL: exported, original: original, draft: draft, under: first)
                let outputURL = first.appendingPathComponent(record.outputRelativePath)
                if corruptOutput { try Data([0x01, 0x02]).write(to: outputURL) }
                let expectedBytes = try Data(contentsOf: outputURL)
                let io = BoundaryLibraryFolderIO(boundary: ScopeBoundary(), resolvedURL: first)
                let vm = try make("verify-work-" + key, defaults: defaults, resultStore: store, folderIO: io)
                vm.selectedCollection = .output
                await vm.setOutputFolder(url: first)
                let item = try XCTUnwrap(vm.outputDaySections.first?.items.first)

                // Validation B completes its file check first, but holds its bookmark while A
                // starts verifying. A real serial store-queue gate then keeps verification pending.
                let bookmarkGate = CancellableGate()
                io.gateBookmark(for: second, gate: bookmarkGate)
                let switching = Task { await vm.setOutputFolder(url: second) }
                defer { bookmarkGate.open() }
                for _ in 0..<500 where io.createBookmarkCallCount < 2 { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertEqual(io.createBookmarkCallCount, 2)
                let entered = TestSignal(), release = DispatchSemaphore(value: 0)
                let blocker = Task { try await store.io.run { entered.signal(); release.wait() } }
                defer { release.signal() }
                await entered.wait()
                let opening = Task { await vm.openLibraryPhoto(item) }
                for _ in 0..<500 where vm.currentStage != .ingestingAndDecodingStrips { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertEqual(vm.currentStage, .ingestingAndDecodingStrips)
                bookmarkGate.open()
                for _ in 0..<500 where vm.outputFolderURL != second { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertEqual(vm.outputFolderURL, second)
                if replacePhoto {
                    await vm.ingestFile(at: source)
                    vm.errorMessage = "Notice for the new photo"
                }
                release.signal(); try await blocker.value
                await opening.value; await switching.value
                XCTAssertEqual(vm.outputFolderURL, second)
                XCTAssertEqual(try Data(contentsOf: outputURL), expectedBytes)
                if replacePhoto {
                    XCTAssertEqual(vm.sourceURL, source)
                    XCTAssertEqual(vm.currentStage, .idle)
                    XCTAssertNotNil(vm.sourceBuffer)
                    XCTAssertEqual(vm.errorMessage, "Notice for the new photo")
                } else {
                    XCTAssertEqual(vm.currentStage, .failed, "A retired root must not leave an endless Opening photo state")
                    XCTAssertTrue(vm.errorMessage?.contains("output folder changed") == true)
                    XCTAssertNil(vm.metadata)
                    XCTAssertNil(vm.outputBuffer)
                    #if canImport(UIKit)
                    if !corruptOutput { try await capture(StudioWorkspaceView(viewModel: vm), name: "output-root-changed-recovery") }
                    #endif
                }
            }
        }
    }

    @MainActor func testSetupIsRequiredBeforeAnyJobAndSeparateRootsAreEnforced() async throws {
        let suite = "LibraryWorkflow-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = try make("work", defaults: defaults)
        let input = try folder("input")
        let photo = try RealPipelineImageFixture.makePNG(in: input, name: "photo.png")
        await vm.setLibraryFolder(url: input)
        await vm.ingestFile(at: photo)
        vm.startProcessing()
        XCTAssertFalse(vm.isProcessing)
        XCTAssertTrue(vm.isOutputSetupPresented)
        XCTAssertEqual(vm.ownedExecutionCount, 0)
        await vm.setOutputFolder(url: input)
        XCTAssertNil(vm.outputFolderURL)
        XCTAssertFalse(vm.hasSavedOutputBookmark)
    }
    @MainActor func testAutomaticSaveReopensComparisonAfterRelaunchAndSharesWithoutReexport() async throws {
        let suite = "LibraryWorkflow-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = try make("work", defaults: defaults), input = try folder("input"), output = try folder("output")
        let photo = try RealPipelineImageFixture.makePNG(in: input, name: "camera.png")
        let originalBytes = try Data(contentsOf: photo)
        await vm.setOutputFolder(url: output)
        await vm.setLibraryFolder(url: input)
        await vm.ingestFile(at: photo)
        vm.selectedModel = .edsrBaseline
        vm.selectedGrainRetention = 0.25
        vm.exportFormat = .tiff16BitLZW
        vm.startProcessing()
        try await settle(vm)
        XCTAssertNil(vm.errorMessage)
        let savedRecords = try await ProcessedLibraryStore().records(under: output)
        let record = try XCTUnwrap(savedRecords.first)
        XCTAssertEqual(record.modelRawValue, BackboneModelKind.edsrBaseline.rawValue)
        XCTAssertEqual(record.original.filename, "camera.png")
        XCTAssertEqual(record.outputWidth, 96)
        XCTAssertEqual(record.outputHeight, 64)
        XCTAssertEqual(try Data(contentsOf: photo), originalBytes, "Input remains untouched")
        XCTAssertEqual(vm.inspectionByteCount, record.outputByteCount)
        XCTAssertEqual(vm.inspectionFilename, (record.outputRelativePath as NSString).lastPathComponent)
        let savedURL = output.appendingPathComponent(record.outputRelativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent(record.thumbnailRelativePath).path))
        let savedBytes = try Data(contentsOf: savedURL)
        let bookmark = defaults.data(forKey: StudioViewModel.outputBookmarkDefaultsKey)
        await vm.setOutputFolder(url: directory.appendingPathComponent("missing folder"))
        XCTAssertEqual(vm.outputFolderURL, output)
        XCTAssertEqual(defaults.data(forKey: StudioViewModel.outputBookmarkDefaultsKey), bookmark)
        // A changed next-job destination must not redirect sharing of the displayed result.
        await vm.setOutputFolder(url: try folder("next output"))
        await vm.exportFinalImage()
        XCTAssertEqual(vm.exportedShareURLs, [savedURL])
        XCTAssertEqual(try Data(contentsOf: savedURL), savedBytes)
        // Restore the real bookmark in a new model, as on a cold launch.
        await vm.setOutputFolder(url: output)
        let relaunched = try make("relaunch", defaults: defaults)
        relaunched.restoreOutputBookmarkIfAvailable()
        let deadline = ContinuousClock.now + .seconds(5)
        while relaunched.outputDaySections.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let item = try XCTUnwrap(relaunched.outputDaySections.first?.items.first)
        relaunched.selectedModel = .quickSRNet
        await relaunched.openLibraryPhoto(item)
        XCTAssertTrue(relaunched.isShowingSavedOutput)
        XCTAssertNil(relaunched.comparisonUnavailableReason)
        XCTAssertEqual(relaunched.sourceBuffer?.width, 48)
        XCTAssertEqual(relaunched.outputBuffer?.width, 96)
        XCTAssertEqual(relaunched.viewerGrainAmount, 0, "Reopened file already contains the recorded grain")
        XCTAssertEqual(relaunched.inspectionModelLabel, "EDSR (Better)")
        XCTAssertEqual(relaunched.inspectionDimensionsText, "96 × 64")
        await relaunched.exportFinalImage()
        XCTAssertEqual(relaunched.exportedShareURLs.map { $0.resolvingSymlinksInPath() }, [savedURL.resolvingSymlinksInPath()])
        XCTAssertEqual(try Data(contentsOf: savedURL), savedBytes)
        #if canImport(UIKit)
        relaunched.selectedCollection = .output
        let thumbnail = await relaunched.loadLibraryThumbnail(for: item)
        XCTAssertNotNil(thumbnail, "Saved previews must be readable without a full output decode")
        XCTAssertLessThanOrEqual(thumbnail?.width ?? 999, 256)
        try await capture(LibraryScreen(viewModel: relaunched), name: "output-library")
        try await capture(StudioWorkspaceView(viewModel: relaunched), name: "reopened-comparison")
        try await capture(MetadataInspectorSheet(metadata: try XCTUnwrap(relaunched.metadata),
            sourceFilename: relaunched.inspectionFilename, outputDimensionsText: relaunched.inspectionDimensionsText,
            pipelineSummaryText: "", upscaleModelText: relaunched.inspectionModelLabel,
            fileByteCountOverride: relaunched.inspectionByteCount), name: "output-information")
        try await capture(OutputFolderSetupView(viewModel: relaunched), name: "output-folder-setup")
        #endif
        relaunched.startProcessing()
        XCTAssertFalse(relaunched.isProcessing, "An output must not accidentally be enlarged a second time")
    }
    @MainActor func testFailedOutputRetryRevalidatesTheRecordAndNeverBecomesInput() async throws {
        let suite = "OutputRetry-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = try make("retry-work", defaults: defaults), input = try folder("retry-input"), output = try folder("retry-output")
        let photo = try RealPipelineImageFixture.makePNG(in: input, name: "source.png")
        await vm.setOutputFolder(url: output); await vm.ingestFile(at: photo)
        vm.exportFormat = .tiff16BitLZW; vm.startProcessing(); try await settle(vm)
        let item = try XCTUnwrap(vm.outputDaySections.first?.items.first)
        let bytes = try Data(contentsOf: item.fileURL)
        try Data([0, 1, 2]).write(to: item.fileURL)
        await vm.openLibraryPhoto(item)
        XCTAssertEqual(vm.currentStage, .failed); XCTAssertNil(vm.viewerInputURL)
        await vm.retryOpeningCurrentPhoto()
        XCTAssertEqual(vm.currentStage, .failed); XCTAssertNil(vm.viewerInputURL)
        XCTAssertNil(vm.metadata); XCTAssertNil(vm.completedArtifacts)
        XCTAssertEqual(try Data(contentsOf: item.fileURL), Data([0, 1, 2]))
        try bytes.write(to: item.fileURL)
        await vm.retryOpeningCurrentPhoto()
        XCTAssertEqual(vm.currentStage, .readyForInspection, vm.errorMessage ?? "")
        XCTAssertTrue(vm.isShowingSavedOutput); XCTAssertNotNil(vm.outputBuffer)
        XCTAssertEqual(try Data(contentsOf: photo), try Data(contentsOf: output.appendingPathComponent(
            try XCTUnwrap(vm.displayedOutputRecord).original.relativePath)))
    }

    @MainActor func testSaveFailureRetainsResultAndRetryPublishesExactlyOnePhoto() async throws {
        let suite = "LibraryWorkflow-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let exporter = RetryExporter()
        let vm = try make("work", defaults: defaults, exporter: exporter), output = try folder("output")
        let photo = try RealPipelineImageFixture.makePNG(in: directory, name: "camera.png")
        await vm.setOutputFolder(url: output)
        await vm.ingestFile(at: photo)
        vm.exportFormat = .tiff16BitLZW
        vm.startProcessing()
        try await settle(vm)
        XCTAssertNotNil(vm.outputBuffer)
        XCTAssertTrue(vm.errorMessage?.contains("could not be saved") == true)
        XCTAssertTrue(vm.outputDaySections.isEmpty)
        await exporter.allowSuccess()
        await vm.exportFinalImage()
        XCTAssertNil(vm.errorMessage)
        let first = vm.exportedShareURLs
        XCTAssertEqual(first.count, 1)
        await vm.exportFinalImage()
        XCTAssertEqual(vm.exportedShareURLs, first)
        let records = try await ProcessedLibraryStore().records(under: output)
        XCTAssertEqual(records.count, 1)
    }
    @MainActor func testEarlierAppExportWithoutRecordRemainsViewableWithoutInventedModelOrBefore() async throws {
        let suite = "LibraryWorkflow-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = try make("work", defaults: defaults), output = try folder("output")
        let photo = try RealPipelineImageFixture.makePNG(in: directory, name: "camera.png")
        await vm.setOutputFolder(url: output)
        await vm.ingestFile(at: photo)
        vm.exportFormat = .tiff16BitLZW
        vm.startProcessing(); try await settle(vm)
        let records = try await ProcessedLibraryStore().records(under: output)
        let record = try XCTUnwrap(records.first)
        try FileManager.default.removeItem(at: output.appendingPathComponent(record.metadataRelativePath))
        await vm.reloadOutputFolder()
        let item = try XCTUnwrap(vm.outputDaySections.first?.items.first)
        XCTAssertEqual(item.badgeLabel, "Earlier result")
        await vm.openLibraryPhoto(item)
        XCTAssertTrue(vm.isShowingSavedOutput)
        XCTAssertNil(vm.displayedOutputRecord)
        XCTAssertNil(vm.outputBuffer)
        XCTAssertNotNil(vm.comparisonUnavailableReason)
        XCTAssertTrue(vm.inspectionModelLabel?.contains("Not recorded") == true)
        XCTAssertEqual(vm.inspectionDimensionsText, "96 × 64")
        await vm.exportFinalImage()
        XCTAssertEqual(vm.exportedShareURLs, [item.fileURL])
        vm.startProcessing()
        XCTAssertFalse(vm.isProcessing)
    }

    @MainActor func testSavedLinearDNGHasBrowsablePreviewAndPersistentComparison() async throws {
        let suite = "LibraryDNG-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = try make("work", defaults: defaults), output = try folder("output")
        let photo = try RealPipelineImageFixture.makePNG(in: directory, name: "camera.png")
        await vm.setOutputFolder(url: output)
        await vm.ingestFile(at: photo)
        vm.exportFormat = .linearDNG16Bit
        vm.startProcessing(); try await settle(vm)
        XCTAssertNil(vm.errorMessage)
        let item = try XCTUnwrap(vm.outputDaySections.first?.items.first)
        XCTAssertEqual(item.fileURL.pathExtension, "dng")
        let thumbnail = await vm.loadLibraryThumbnail(for: item)
        XCTAssertNotNil(thumbnail)
        await vm.openLibraryPhoto(item)
        XCTAssertEqual(vm.sourceBuffer?.width, 48)
        XCTAssertEqual(vm.outputBuffer?.width, 96)
        XCTAssertNil(vm.comparisonUnavailableReason)
    }

    @MainActor func testMissingSavedOriginalShowsOutputWithTruthfulComparisonState() async throws {
        let suite = "LibraryWorkflow-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = try make("work", defaults: defaults), output = try folder("output")
        let photo = try RealPipelineImageFixture.makePNG(in: directory, name: "camera.png")
        await vm.setOutputFolder(url: output)
        await vm.ingestFile(at: photo)
        vm.exportFormat = .tiff16BitLZW
        vm.startProcessing(); try await settle(vm)
        let records = try await ProcessedLibraryStore().records(under: output)
        let record = try XCTUnwrap(records.first)
        try FileManager.default.removeItem(at: output.appendingPathComponent(record.original.relativePath))
        let item = try XCTUnwrap(vm.outputDaySections.first?.items.first)
        await vm.openLibraryPhoto(item)
        XCTAssertTrue(vm.isShowingSavedOutput)
        XCTAssertNotNil(vm.comparisonUnavailableReason)
        XCTAssertEqual(vm.sourceBuffer?.width, 96)
        XCTAssertNil(vm.outputBuffer, "Do not fabricate a before/after from one image")
        XCTAssertEqual(vm.inspectionModelLabel, "QuickSRNet (Fast)")
    }
}
private actor RetryExporter: StudioImageExporting {
    private var succeeds = false
    func allowSuccess() { succeeds = true }
    func exportDetailed(artifacts: CompletedPipelineArtifacts, destinationURL: URL, overrideFormat: ExportFormat?, overrideGrainAmount: Float?) async throws -> ExportResult {
        guard succeeds else { throw CocoaError(.fileWriteNoPermission) }
        return try await BlockingStudioImageExporter().exportDetailed(artifacts: artifacts, destinationURL: destinationURL,
            overrideFormat: overrideFormat, overrideGrainAmount: overrideGrainAmount)
    }
}

private actor GatedFailingSharePreparer: StudioPhotoSharePreparing {
    let gate: TestGate
    init(gate: TestGate) { self.gate = gate }
    func prepare(_ urls: [URL], surface: PhotoShareSurface, expectedHashes: [URL: String]) async throws -> PhotoShareSession {
        await gate.hold()
        throw CocoaError(.fileReadNoPermission)
    }
}

extension ProcessedLibraryWorkflowTests {
    @MainActor func testBatchSaveFailureStopsBeforeNextPhotoAndRetainsRetryArtifacts() async throws {
        let suite = "BatchSaveFailure-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = try folder("batch-save-input"), output = try folder("batch-save-output"), exporter = RetryExporter()
        for name in ["first.png", "second.png"] { try RealPipelineImageFixture.makePNG(in: input, name: name) }
        let vm = try make("batch-save-work", defaults: defaults, exporter: exporter)
        await vm.setOutputFolder(url: output); await vm.setLibraryFolder(url: input)
        vm.exportFormat = .tiff16BitLZW
        let items = vm.orderedLibraryItems, first = try XCTUnwrap(items.first)
        await vm.batchProcessSelected(ids: Set(items.map(\.id)))
        XCTAssertFalse(vm.isBatchProcessing)
        XCTAssertEqual(vm.sourceURL, first.fileURL, "An unsaved result must not be replaced by the second input")
        XCTAssertEqual(vm.currentStage, .readyForInspection)
        XCTAssertTrue(vm.errorMessage?.contains("could not be saved") == true)
        let artifacts = try XCTUnwrap(vm.completedArtifacts)
        XCTAssertNotNil(vm.outputBuffer)
        XCTAssertTrue(vm.outputDaySections.isEmpty)
        XCTAssertEqual(vm.ownedExecutionCount, 0)
        await exporter.allowSuccess()
        await vm.exportFinalImage(presentShareSheet: false)
        let records = try await ProcessedLibraryStore().records(under: output)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, artifacts.checkpoint.jobID)
        XCTAssertEqual(records.first?.original.filename, first.filename)
        XCTAssertNil(vm.errorMessage)
    }

    @MainActor private func partialTrashFixture(_ name: String, defaults: UserDefaults, decoder: FakeDecoder) async throws -> (vm: StudioViewModel, items: [LibraryPhotoItem]) {
        let sourceFolder = try folder(name + "-sources"), output = try folder(name + "-output")
        let input = try RealPipelineImageFixture.makePNG(in: sourceFolder, name: "source.png")
        let exported = try RealPipelineImageFixture.makePNG(in: sourceFolder, name: "export.png", width: 96, height: 64)
        let store = ProcessedLibraryStore()
        let original = try await store.archiveOriginal(at: input, named: input.lastPathComponent, under: output)
        for index in 0..<3 {
            let draft = ProcessedPhotoDraft(id: UUID(), modelRawValue: BackboneModelKind.quickSRNet.rawValue,
                sourceWidth: 48, sourceHeight: 32, outputWidth: 96, outputHeight: 64, scaleFactor: 2,
                grainAmount: 0, processedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index)),
                formatRawValue: ExportFormat.png16Bit.rawValue)
            _ = try await store.publish(exportedURL: exported, original: original, draft: draft, under: output)
        }
        decoder.setDefaultConfiguration(FakeDecodeConfiguration(width: 48, height: 32))
        let vm = try make(name + "-work", defaults: defaults, decoder: decoder)
        await vm.setOutputFolder(url: output); vm.selectedCollection = .output
        let items = vm.orderedLibraryItems
        XCTAssertEqual(items.count, 3)
        for item in items { decoder.setConfiguration(FakeDecodeConfiguration(width: 96, height: 64), forFileName: item.filename) }
        await vm.openLibraryPhoto(try XCTUnwrap(items.first))
        XCTAssertEqual(vm.currentStage, .readyForInspection)
        // Only this disposable fixture output changes. Its exact saved digest must reject deletion.
        try Data([1, 2, 3]).write(to: items[1].fileURL)
        return (vm, items)
    }

    @MainActor func testPartialTrashFailureRemainsVisibleAfterOpeningSurvivor() async throws {
        let suite = "PartialTrashNotice-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try await partialTrashFixture("partial-notice", defaults: defaults, decoder: FakeDecoder())
        let vm = fixture.vm, items = fixture.items
        let request = try XCTUnwrap(vm.trashRequest(ids: Set(items.prefix(2).map(\.id))))
        await vm.trashOutputs(request)
        XCTAssertEqual(vm.sourceURL, items[2].fileURL)
        XCTAssertEqual(vm.currentStage, .readyForInspection)
        XCTAssertTrue(vm.errorMessage?.contains("could not be moved") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: items[0].fileURL.path))
        XCTAssertEqual(try Data(contentsOf: items[1].fileURL), Data([1, 2, 3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: items[2].fileURL.path))
        XCTAssertEqual(vm.recentlyDeleted.count, 1)
    }

    @MainActor func testPartialTrashNoticeCannotOverwriteANewerPhotoSession() async throws {
        let suite = "PartialTrashSuperseded-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let decoder = FakeDecoder(), gate = TestGate()
        let fixture = try await partialTrashFixture("partial-superseded", defaults: defaults, decoder: decoder)
        let vm = fixture.vm, items = fixture.items
        decoder.setGate(gate, forFileName: items[2].filename)
        let request = try XCTUnwrap(vm.trashRequest(ids: Set(items.prefix(2).map(\.id))))
        let deletion = Task { await vm.trashOutputs(request) }
        await gate.entered.wait()
        defer { gate.open() }
        let newInput = try RealPipelineImageFixture.makePNG(in: directory, name: "new-selection.png")
        await vm.ingestFile(at: newInput)
        vm.errorMessage = "New photo notice"
        gate.open(); await deletion.value
        XCTAssertEqual(vm.sourceURL, newInput)
        XCTAssertEqual(vm.currentStage, .idle)
        XCTAssertEqual(vm.errorMessage, "New photo notice")
    }

    @MainActor func testStaleShareFailureDoesNotReplaceCurrentPhotoNotice() async throws {
        let suite = "StaleShareFailure-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = try folder("share-failure-input"), gate = TestGate()
        for name in ["a.png", "b.png"] { try RealPipelineImageFixture.makePNG(in: input, name: name) }
        let vm = try make("share-failure-work", defaults: defaults, sharePreparer: GatedFailingSharePreparer(gate: gate))
        await vm.setLibraryFolder(url: input)
        let items = vm.orderedLibraryItems
        XCTAssertEqual(items.count, 2)
        await vm.ingestFile(at: items[0].fileURL)
        let sharing = Task { await vm.exportSelected(ids: [items[0].id]) }
        await gate.entered.wait()
        defer { gate.open() }
        await vm.ingestFile(at: items[1].fileURL)
        vm.errorMessage = "Current photo notice"
        gate.open(); await sharing.value
        XCTAssertEqual(vm.sourceURL, items[1].fileURL)
        XCTAssertEqual(vm.errorMessage, "Current photo notice")
        XCTAssertFalse(vm.isPreparingShare); XCTAssertNil(vm.shareSession)
    }

    @MainActor func testRejectedOutputSelectionCannotReplaceFailedInputRetryIdentity() async throws {
        let suite = "RejectedOutputRetry-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = try RealPipelineImageFixture.makePNG(in: directory, name: "failed-input.png")
        let decoder = FakeDecoder(), gate = TestGate()
        decoder.setConfiguration(FakeDecodeConfiguration(width: 0, height: 0), forFileName: input.lastPathComponent)
        decoder.setGate(gate, forFileName: input.lastPathComponent)
        let vm = try make("rejected-retry-work", defaults: defaults, decoder: decoder)
        let opening = Task { await vm.ingestFile(at: input) }
        await gate.entered.wait()
        defer { gate.open() }
        let staleURL = directory.appendingPathComponent("old-output.png")
        let stale = LibraryPhotoItem(id: staleURL.path, fileURL: staleURL, filename: staleURL.lastPathComponent,
            capturedAt: Date(), byteCount: 1, collection: .output)
        await vm.openLibraryPhoto(stale)
        gate.open(); await opening.value
        XCTAssertEqual(vm.currentStage, .failed); XCTAssertEqual(vm.sourceURL, input)
        decoder.setConfiguration(FakeDecodeConfiguration(width: 48, height: 32), forFileName: input.lastPathComponent)
        await vm.retryOpeningCurrentPhoto()
        XCTAssertEqual(vm.sourceURL, input)
        XCTAssertEqual(vm.currentStage, .idle, vm.errorMessage ?? "")
        XCTAssertNil(vm.errorMessage)
    }
}

extension ProcessedLibraryWorkflowTests {
    @MainActor func testOutputDeletionIsRecoverableAndFrozenConfirmationsCannotCrossRoots() async throws {
        let suite = "OutputManagement-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = try make("work", defaults: defaults), input = try folder("input"), output = try folder("output")
        let photo = try RealPipelineImageFixture.makePNG(in: input, name: "camera.png")
        let inputBytes = try Data(contentsOf: photo)
        await vm.setOutputFolder(url: output)
        await vm.setLibraryFolder(url: input)
        await vm.ingestFile(at: photo)
        XCTAssertFalse(vm.canTrashDisplayedOutput)
        XCTAssertFalse(vm.isProcessedPhoto)
        vm.exportFormat = .tiff16BitLZW
        vm.startProcessing()
        try await settle(vm)
        XCTAssertTrue(vm.isProcessedPhoto)
        XCTAssertTrue(vm.canTrashDisplayedOutput)
        XCTAssertEqual(vm.inspectionMetadata?.processingHistory?.steps.last?.model, BackboneModelKind.quickSRNet.rawValue)
        let request = try XCTUnwrap(vm.displayedTrashRequest())
        let saved = try XCTUnwrap(vm.outputDaySections.first?.items.first)
        await vm.setOutputFolder(url: try folder("other output"))
        await vm.trashOutputs(request)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.fileURL.path), "Stale confirmation cannot delete from the old folder")
        await vm.setOutputFolder(url: output)
        vm.selectedCollection = .input
        XCTAssertNil(vm.trashRequest(ids: Set(vm.daySections.flatMap(\.items).map(\.id))), "Input has no delete API")
        vm.selectedCollection = .output
        await vm.openLibraryPhoto(saved)
        let current = try XCTUnwrap(vm.displayedTrashRequest())
        await vm.trashOutputs(current)
        XCTAssertTrue(vm.outputDaySections.isEmpty)
        await vm.reloadRecentlyDeleted()
        XCTAssertEqual(vm.recentlyDeleted.count, 1)
        // Empty-viewer reset is asynchronous and must drain before a new mutation.
        await vm.waitForResetToFinish()
        let restore = try XCTUnwrap(vm.trashManagementRequest(ids: Set(vm.recentlyDeleted.map(\.id)), permanent: false))
        await vm.manageTrash(restore)
        XCTAssertEqual(vm.outputDaySections.flatMap(\.items).count, 1, vm.errorMessage ?? "")
        XCTAssertEqual(try Data(contentsOf: photo), inputBytes)
    }

    @MainActor func testTrashManagementCompletionCannotReplaceANewerPhotoNotice() async throws {
        for shouldFail in [false, true] {
            let name = shouldFail ? "restore-failure" : "restore-success"
            let suite = "TrashSuperseded-\(UUID())", defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let input = try folder(name + "-input"), output = try folder(name + "-output")
            let originalURL = try RealPipelineImageFixture.makePNG(in: input, name: "original.png")
            let exportedURL = try RealPipelineImageFixture.makePNG(in: input, name: "export.png", width: 96, height: 64)
            let store = ProcessedLibraryStore()
            let archived = try await store.archiveOriginal(at: originalURL, named: originalURL.lastPathComponent, under: output)
            let draft = ProcessedPhotoDraft(id: UUID(), modelRawValue: BackboneModelKind.quickSRNet.rawValue,
                sourceWidth: 48, sourceHeight: 32, outputWidth: 96, outputHeight: 64, scaleFactor: 2,
                grainAmount: 0, processedAt: Date(), formatRawValue: ExportFormat.png16Bit.rawValue)
            let record = try await store.publish(exportedURL: exportedURL, original: archived, draft: draft, under: output)
            try await store.trash(record: record, under: output)
            let vm = try make(name + "-work", defaults: defaults, decoder: FakeDecoder(), resultStore: store)
            await vm.setOutputFolder(url: output)
            await vm.reloadRecentlyDeleted()
            let entry = try XCTUnwrap(vm.recentlyDeleted.first)
            let request = try XCTUnwrap(vm.trashManagementRequest(ids: [entry.id], permanent: false))
            if shouldFail {
                // Corrupt only this disposable fixture; restore must reject its recorded digest.
                let file = try XCTUnwrap(entry.files.first)
                try Data([0x42]).write(to: output.appendingPathComponent(entry.directory).appendingPathComponent(file.storedName))
            }

            // Suspend the real store queue before the mutation enters it. No timed sleeps or
            // production fake are needed to place a newer ingest between request and completion.
            let entered = TestSignal(), gate = DispatchSemaphore(value: 0)
            let blockedIO = Task { try await store.io.run { entered.signal(); gate.wait() } }
            defer { gate.signal() }
            await entered.wait()
            let management = Task { await vm.manageTrash(request) }
            let deadline = ContinuousClock.now + .seconds(5)
            while !vm.isManagingOutput, .now < deadline { await Task.yield() }
            XCTAssertTrue(vm.isManagingOutput)

            let newer = try RealPipelineImageFixture.makePNG(in: input, name: "newer.png")
            await vm.ingestFile(at: newer)
            vm.errorMessage = "New photo notice"
            gate.signal()
            try await blockedIO.value
            await management.value

            XCTAssertEqual(vm.sourceURL, newer)
            XCTAssertEqual(vm.currentStage, .idle)
            XCTAssertEqual(vm.errorMessage, "New photo notice", name)
            XCTAssertFalse(vm.isManagingOutput)
            XCTAssertEqual(vm.recentlyDeleted.count, shouldFail ? 1 : 0)
            XCTAssertEqual(vm.outputDaySections.flatMap(\.items).count, shouldFail ? 0 : 1)
        }
    }

    @MainActor func testShareSurfaceOwnsSnapshotUntilActualDismissalAndDoesNotReexport() async throws {
        let suite = "ShareSurface-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = try make("work", defaults: defaults), output = try folder("output")
        let photo = try RealPipelineImageFixture.makePNG(in: directory, name: "camera.png")
        await vm.setOutputFolder(url: output)
        await vm.ingestFile(at: photo)
        vm.exportFormat = .tiff16BitLZW; vm.startProcessing(); try await settle(vm)
        await vm.exportFinalImage()
        let snapshot = try XCTUnwrap(vm.shareBinding(for: .viewer)?.fileURLs.first)
        XCTAssertNil(vm.shareBinding(for: .library))
        XCTAssertEqual(try Data(contentsOf: snapshot), try Data(contentsOf: vm.exportedShareURLs[0]))
        vm.dismissShare(surface: .library)
        XCTAssertNotNil(vm.shareSession, "Another surface cannot dismiss this viewer's export")
        vm.dismissShare(surface: .viewer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path), "Native dismissal can still be reading the snapshot")
        vm.shareDidDisappear(surface: .viewer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vm.outputDaySections[0].items[0].fileURL.path))
    }

    @MainActor func testNativeShareCompletionRetiresOnlyItsMatchingSession() async throws {
        let suite = "ShareCompletionIdentity-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = try make("share-identity-work", defaults: defaults), output = try folder("share-identity-output")
        let photo = try RealPipelineImageFixture.makePNG(in: directory, name: "share-identity-source.png")
        await vm.setOutputFolder(url: output)
        await vm.ingestFile(at: photo)
        vm.exportFormat = .tiff16BitLZW; vm.startProcessing(); try await settle(vm)
        await vm.exportFinalImage()
        let first = try XCTUnwrap(vm.shareSession), firstURL = try XCTUnwrap(first.fileURLs.first)
        vm.dismissShare(surface: .viewer)
        vm.shareDidDisappear(surface: .viewer, sessionID: UUID())
        vm.shareDidDisappear(surface: .library, sessionID: first.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path), "An unrelated callback cannot retire a still-dismissing snapshot")
        XCTAssertFalse(vm.canManageOutput)
        vm.shareDidDisappear(surface: .viewer, sessionID: first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(vm.canManageOutput)

        await vm.exportFinalImage()
        let second = try XCTUnwrap(vm.shareSession), secondURL = try XCTUnwrap(second.fileURLs.first)
        XCTAssertNotEqual(first.id, second.id)
        vm.shareDidDisappear(surface: .viewer, sessionID: first.id)
        XCTAssertEqual(vm.shareSession?.id, second.id, "A late callback from A cannot dismiss replacement share B")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        vm.shareDidDisappear(surface: .viewer, sessionID: second.id)
        XCTAssertNil(vm.shareSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: vm.outputDaySections[0].items[0].fileURL.path))
    }

    @MainActor func testMergedOutputPathsWithTheSameJobIDKeepTheirOwnOpenShareAndTrashIdentity() async throws {
        let suite = "MergedOutputIdentity-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = try make("merged-output-work", defaults: defaults), merged = try folder("merged-output")
        let store = ProcessedLibraryStore(), id = UUID()
        var records: [ProcessedPhotoRecord] = []
        for (index, dimensions) in [(8, 6), (12, 9)].enumerated() {
            let root = try folder("portable-root-\(index)")
            let source = try RealPipelineImageFixture.makePNG(in: directory, name: "portable-source-\(index).png",
                width: dimensions.0, height: dimensions.1)
            let result = try RealPipelineImageFixture.makePNG(in: directory, name: "portable-output-\(index).png",
                width: dimensions.0 * 2, height: dimensions.1 * 2)
            let original = try await store.archiveOriginal(at: source, named: source.lastPathComponent, under: root)
            // Two independent portable roots may save a resumed job on different dates. These
            // synthetic raster records intentionally share the opaque job UUID, not file identity.
            let draft = ProcessedPhotoDraft(id: id,
                modelRawValue: (index == 0 ? BackboneModelKind.quickSRNet : .edsrBaseline).rawValue,
                sourceWidth: dimensions.0, sourceHeight: dimensions.1,
                outputWidth: dimensions.0 * 2, outputHeight: dimensions.1 * 2,
                scaleFactor: 2, grainAmount: 0,
                processedAt: Date(timeIntervalSince1970: Double(2 - index) * 86400), formatRawValue: ExportFormat.png16Bit.rawValue)
            let record = try await store.publish(exportedURL: result, original: original, draft: draft, under: root)
            for relative in [record.outputRelativePath, record.metadataRelativePath, record.original.relativePath] {
                let target = merged.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: root.appendingPathComponent(relative), to: target)
            }
            records.append(record)
        }
        let first = records[0], second = records[1]
        XCTAssertEqual(first.id, second.id)
        let firstURL = merged.appendingPathComponent(first.outputRelativePath), secondURL = merged.appendingPathComponent(second.outputRelativePath)
        let firstBytes = try Data(contentsOf: firstURL), secondBytes = try Data(contentsOf: secondURL)
        let firstMetadata = try Data(contentsOf: merged.appendingPathComponent(first.metadataRelativePath))
        let secondMetadata = try Data(contentsOf: merged.appendingPathComponent(second.metadataRelativePath))
        await vm.setOutputFolder(url: merged); vm.selectedCollection = .output
        let items = vm.outputDaySections.flatMap(\.items)
        XCTAssertEqual(items.count, 2); XCTAssertEqual(Set(items.map(\.id)).count, 2)
        let firstItem = try XCTUnwrap(items.first { $0.fileURL == firstURL })
        let secondItem = try XCTUnwrap(items.first { $0.fileURL == secondURL })
        await vm.openLibraryPhoto(secondItem)
        XCTAssertEqual(vm.displayedOutputRecord, second)
        XCTAssertEqual(vm.sourceURL, secondURL)
        XCTAssertEqual(vm.inspectionModelLabel, "EDSR (Better)")
        XCTAssertEqual(vm.inspectionDimensionsText, "24 × 18")
        await vm.exportFinalImage()
        XCTAssertEqual(vm.exportedShareURLs, [secondURL])
        let share = try XCTUnwrap(vm.shareSession)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(share.fileURLs.first)), secondBytes)
        vm.shareDidDisappear(surface: .viewer, sessionID: share.id)

        let firstRequest = try XCTUnwrap(vm.trashRequest(ids: [firstItem.id]))
        XCTAssertEqual(firstRequest.records, [first])
        await vm.trashOutputs(firstRequest)
        XCTAssertEqual(vm.displayedOutputRecord, second, "Deleting its UUID-sharing sibling must not move the viewer")
        XCTAssertEqual(vm.sourceURL, secondURL)
        XCTAssertEqual(try Data(contentsOf: secondURL), secondBytes)
        XCTAssertEqual(try Data(contentsOf: merged.appendingPathComponent(second.metadataRelativePath)), secondMetadata)
        let trash = try XCTUnwrap(vm.recentlyDeleted.first)
        let restore = try XCTUnwrap(vm.trashManagementRequest(ids: [trash.id], permanent: false))
        await vm.manageTrash(restore)
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertEqual(try Data(contentsOf: merged.appendingPathComponent(first.metadataRelativePath)), firstMetadata)

        let secondRequest = try XCTUnwrap(vm.trashRequest(ids: [secondItem.id]))
        XCTAssertEqual(secondRequest.records, [second])
        await vm.trashOutputs(secondRequest)
        XCTAssertEqual(vm.displayedOutputRecord, first, "The removed path must be reconciled even when a sibling keeps its UUID")
        XCTAssertEqual(vm.sourceURL, firstURL)
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertEqual(try Data(contentsOf: merged.appendingPathComponent(first.metadataRelativePath)), firstMetadata)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertEqual(vm.recentlyDeleted.map { $0.record?.outputRelativePath }, [second.outputRelativePath])
    }
    @MainActor func testInputCannotBeNestedInsideOutputAndBookmarksAreNotCleared() async throws {
        let suite = "OutputBoundary-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = try make("work", defaults: defaults), input = try folder("input"), output = try folder("output")
        let nested = output.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        await vm.setLibraryFolder(url: input)
        let bookmark = defaults.data(forKey: StudioViewModel.bookmarkDefaultsKey)
        await vm.setOutputFolder(url: output)
        await vm.setLibraryFolder(url: nested)
        XCTAssertEqual(vm.libraryFolderURL, input)
        XCTAssertEqual(defaults.data(forKey: StudioViewModel.bookmarkDefaultsKey), bookmark)
        await vm.setOutputFolder(url: directory)
        XCTAssertEqual(vm.outputFolderURL, output, "An output root containing the Input folder is refused")
    }
}


extension ProcessedLibraryWorkflowTests {
    @MainActor func testBatchReportsEveryPhotoAndStopDoesNotStartTheRemainingQueue() async throws {
        let suite = "GalleryParityBatch-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = try make("batch-work", defaults: defaults), input = try folder("batch-input"), output = try folder("batch-output")
        for i in 0..<3 { _ = try RealPipelineImageFixture.makePNG(in: input, name: "photo-\(i).png") }
        await vm.setOutputFolder(url: output); await vm.setLibraryFolder(url: input)
        vm.exportFormat = .tiff16BitLZW
        let ids = Set(vm.daySections.flatMap(\.items).map(\.id))
        let task = Task { await vm.batchProcessSelected(ids: ids) }
        var observed = Set<Int>()
        for _ in 0..<2000 {
            if let photo = vm.batchPhotoNumber {
                observed.insert(photo)
                XCTAssertEqual(vm.batchPhotoCount, 3)
                if !vm.isStopping { XCTAssertEqual(vm.jobProgress.compactTitle, "Processing \(photo)/3") }
                if photo == 2 { vm.cancelProcessing() }
            }
            if !observed.isEmpty && !vm.isBatchProcessing { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        await task.value
        XCTAssertTrue(observed.contains(1)); XCTAssertTrue(observed.contains(2)); XCTAssertFalse(observed.contains(3))
        XCTAssertFalse(vm.isBatchProcessing); XCTAssertNil(vm.batchPhotoCount)
        let records = try await ProcessedLibraryStore().records(under: output)
        XCTAssertGreaterThanOrEqual(records.count, 1)
        XCTAssertLessThan(records.count, 3, "Stop must preserve completed outputs while leaving the remaining queue alone")
    }
}

#if canImport(UIKit)
extension ProcessedLibraryWorkflowTests {
    @MainActor func testOutputOpeningClearsPreviousInputAndShowsLoadingUntilDecodeCompletes() async throws {
        let suite = "OutputOpening-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = try folder("loading-input"), output = try folder("loading-output")
        let photo = try RealPipelineImageFixture.makePNG(in: input, name: "source.png")
        let producer = try make("producer", defaults: defaults)
        await producer.setOutputFolder(url: output); await producer.ingestFile(at: photo)
        producer.exportFormat = .tiff16BitLZW; producer.startProcessing(); try await settle(producer)
        let decoder = FakeDecoder(), gate = TestGate()
        decoder.setDefaultConfiguration(FakeDecodeConfiguration(width: 48, height: 32))
        let vm = try make("output-loading", defaults: defaults, decoder: decoder)
        await vm.setOutputFolder(url: output); await vm.ingestFile(at: photo)
        XCTAssertEqual(vm.viewerInputURL, photo); XCTAssertNotNil(vm.metadata)
        let item = try XCTUnwrap(vm.outputDaySections.first?.items.first)
        decoder.setConfiguration(FakeDecodeConfiguration(width: 96, height: 64), forFileName: item.filename)
        decoder.setGate(gate, forFileName: item.filename)
        let opening = Task { await vm.openLibraryPhoto(item) }
        await gate.entered.wait()
        defer { gate.open() }
        XCTAssertNil(vm.viewerInputURL, "An old input preview must not mask Output loading")
        XCTAssertEqual(vm.sourceURL, item.fileURL)
        XCTAssertEqual(vm.currentStage, .ingestingAndDecodingStrips)
        XCTAssertNil(vm.sourceBuffer); XCTAssertNil(vm.outputBuffer); XCTAssertNil(vm.metadata)
        try await capture(StudioWorkspaceView(viewModel: vm), name: "output-opening-photo")
        gate.open(); await opening.value
        XCTAssertEqual(vm.currentStage, .readyForInspection, vm.errorMessage ?? "")
        XCTAssertNotNil(vm.sourceBuffer); XCTAssertNotNil(vm.outputBuffer)
        XCTAssertNil(vm.viewerInputURL)
    }

    @MainActor func testInputPreviewAndNavigationAppearBeforeFullRAWDecodeFinishes() async throws {
        let suite = "InputPreviewBeforeDecode-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let input = try folder("preview-input"), decoder = FakeDecoder(), gate = TestGate()
        let photo = try RealPipelineImageFixture.makePNG(in: input, name: "opening.png")
        decoder.setGate(gate, forFileName: "opening.png")
        let vm = try make("preview-work", defaults: defaults, decoder: decoder)
        await vm.setLibraryFolder(url: input)
        let opening = Task { await vm.ingestFile(at: photo) }
        await gate.entered.wait()
        defer { gate.open() }
        let host = UIHostingController(rootView: StudioWorkspaceView(viewModel: vm))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.frame = window.bounds
        defer { window.isHidden = true }
        for _ in 0..<100 where vm.displayedInputURL != photo {
            window.layoutIfNeeded(); host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(vm.viewerInputURL, photo); XCTAssertEqual(vm.displayedInputURL, photo)
        XCTAssertNil(vm.metadata, "The full-resolution decoder is deliberately still held")
        XCTAssertNil(vm.sourceBuffer, "The visible input preview must not wait for a full mmap decode")
        XCTAssertTrue(vm.inputPreviewMatchesSelection)
        try await capture(StudioWorkspaceView(viewModel: vm), name: "input-before-full-decode")
        gate.open(); await opening.value
        XCTAssertNotNil(vm.metadata); XCTAssertNotNil(vm.sourceBuffer)
    }
}
#endif
