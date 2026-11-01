import Foundation
import XCTest
import ImageIO
import UniformTypeIdentifiers
import TruongScalerCore
import CoreIngestion
import CoreExport
import TiledInferenceEngine
import BackgroundJobManager
@testable import DeepZoomGalleryUI

private final class CountingHandoffExporter: StudioImageExporting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let actual = BlockingStudioImageExporter()
    var callCount: Int { lock.withLock { count } }
    func exportDetailed(artifacts: CompletedPipelineArtifacts, destinationURL: URL,
                        overrideFormat: ExportFormat?, overrideGrainAmount: Float?) async throws -> ExportResult {
        lock.withLock { count += 1 }
        return try await actual.exportDetailed(artifacts: artifacts, destinationURL: destinationURL,
            overrideFormat: overrideFormat, overrideGrainAmount: overrideGrainAmount)
    }
}

private struct RefusingHandoffOpener: ExternalApplicationOpening {
    func open(_ url: URL) async { }
    func openWithResult(_ url: URL) async -> Bool { false }
}

private final class GatedPortableHandoffManager: StudioHandoffManaging, @unchecked Sendable {
    let gate = TestGate()
    private let lock = NSLock()
    private var imported: SharedSuiteHandoffPayload?
    private let actual: AppGroupHandoffManagerSeam
    var importedPayload: SharedSuiteHandoffPayload? { lock.withLock { imported } }
    init(directory: URL) { actual = AppGroupHandoffManagerSeam(overrideBaseDirectory: directory) }
    func consumeIncomingHandoff(from url: URL) async throws -> SharedSuiteHandoffPayload {
        let payload = try await actual.consumeIncomingHandoff(from: url)
        lock.withLock { imported = payload }
        await gate.hold()
        return payload
    }
    func retireUnconsumedHandoff(_ payload: SharedSuiteHandoffPayload) async {
        await actual.retireUnconsumedHandoff(payload)
    }
    func createHandoffPackage(exportedImageURL: URL, originalFileName: String, isDenoised: Bool,
        isUpscaled: Bool, globalMaxLuminance: Float, upscaleFactor: Int?, globalMaxLinearComponent: Float
    ) async throws -> (payload: SharedSuiteHandoffPayload, deepLinkURL: URL) {
        try await actual.createHandoffPackage(exportedImageURL: exportedImageURL, originalFileName: originalFileName,
            isDenoised: isDenoised, isUpscaled: isUpscaled, globalMaxLuminance: globalMaxLuminance,
            upscaleFactor: upscaleFactor, globalMaxLinearComponent: globalMaxLinearComponent)
    }
}

private final class GatedOutgoingCompanionManager: StudioHandoffManaging, @unchecked Sendable {
    let gate = TestGate()
    private let lock = NSLock()
    private var documentURL: URL?
    private let actual: AppGroupHandoffManagerSeam
    var preparedDocumentURL: URL? { lock.withLock { documentURL } }
    init(directory: URL) { actual = AppGroupHandoffManagerSeam(overrideBaseDirectory: directory) }
    func consumeIncomingHandoff(from url: URL) async throws -> SharedSuiteHandoffPayload {
        try await actual.consumeIncomingHandoff(from: url)
    }
    func createHandoffPackage(exportedImageURL: URL, originalFileName: String, isDenoised: Bool,
        isUpscaled: Bool, globalMaxLuminance: Float, upscaleFactor: Int?, globalMaxLinearComponent: Float
    ) async throws -> (payload: SharedSuiteHandoffPayload, deepLinkURL: URL) {
        try await actual.createHandoffPackage(exportedImageURL: exportedImageURL, originalFileName: originalFileName,
            isDenoised: isDenoised, isUpscaled: isUpscaled, globalMaxLuminance: globalMaxLuminance,
            upscaleFactor: upscaleFactor, globalMaxLinearComponent: globalMaxLinearComponent)
    }
    func prepareOutgoingHandoff(exportedImageURL: URL, originalFileName: String, isDenoised: Bool,
        isUpscaled: Bool, globalMaxLuminance: Float, upscaleFactor: Int?, globalMaxLinearComponent: Float,
        isDenoisedByNoiser: Bool?, processingHistory: ImageProcessingHistory?, expectedImageSHA256: String?
    ) async throws -> PreparedSuiteHandoff {
        let prepared = try await actual.prepareOutgoingHandoff(exportedImageURL: exportedImageURL,
            originalFileName: originalFileName, isDenoised: isDenoised, isUpscaled: isUpscaled,
            globalMaxLuminance: globalMaxLuminance, upscaleFactor: upscaleFactor,
            globalMaxLinearComponent: globalMaxLinearComponent, isDenoisedByNoiser: isDenoisedByNoiser,
            processingHistory: processingHistory, expectedImageSHA256: expectedImageSHA256)
        if case .document(let document) = prepared { lock.withLock { documentURL = document.fileURL } }
        await gate.hold()
        return prepared
    }
}

@MainActor
final class CompanionHandoffViewModelTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScalerCompanionVM-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        suite = "ScalerCompanionVM-\(UUID())"; defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    private func model(handoff: any StudioHandoffManaging, pipeline: (any StudioPipelineExecuting)? = nil,
                       decoder: any StudioImageDecoding = FakeDecoder(),
                       exporter: any StudioImageExporting = FakeExporter(),
                       opener: any ExternalApplicationOpening = RecordingOpener(),
                       scopes: RecordingScopeProvider = RecordingScopeProvider(),
                       outputRequired: Bool = false, store: ProcessedLibraryStore = ProcessedLibraryStore()) -> StudioViewModel {
        let executor = TiledPipelineExecutor(workingDirectory: directory,
            modelRegistry: CoreMLModelRegistry(initialComputeUnits: .cpuOnly, availabilityPolicy: .allowDeterministicFallback),
            checkpointStore: JobCheckpointStore(directory: directory))
        return StudioViewModel(workingDirectory: directory, pipelineExecutor: executor,
            pipeline: pipeline ?? FakePipelineExecutor(directory: directory), decoder: decoder, exporter: exporter,
            scanner: FakeScanner(), handoffManager: handoff, externalOpener: opener,
            scopeProvider: scopes, backgroundTaskRouter: BackgroundTaskDeliveryRouter(), defaults: defaults,
            requiresOutputFolder: outputRequired, resultStore: store)
    }

    func testRealPortableImportDecodesCopiedPixelsHistoryAndRequestsViewerUnderHeldGrant() async throws {
        let input = try RealPipelineImageFixture.makePNG(in: directory, name: "camera.png", width: 8, height: 6)
        let bytes = try Data(contentsOf: input)
        let history = ImageProcessingHistory(steps: [.init(id: UUID(), app: "com.iantruong.truongscaler", operation: "upscale",
            model: "QuickSRNet", scale: 2, inputWidth: 4, inputHeight: 3, outputWidth: 8, outputHeight: 6)])
        var document: PortableSuiteHandoff.Document? = try PortableSuiteHandoff.createDocument(exportedImageURL: input,
            originalFileName: "camera.png", sourceApp: .truongNoiser, targetApp: .truongScaler,
            isDenoised: true, isUpscaled: true, globalMaxLuminance: 1, upscaleFactor: 2,
            globalMaxLinearComponent: 1, directory: directory.appendingPathComponent("send"),
            isDenoisedByNoiser: false, processingHistory: history)
        let url = try XCTUnwrap(document?.fileURL)
        let scopes = RecordingScopeProvider()
        let vm = model(handoff: AppGroupHandoffManagerSeam(overrideBaseDirectory: directory.appendingPathComponent("receive")),
            decoder: BlockingStudioImageDecoder(), scopes: scopes)
        vm.handleIncomingHandoffURL(url)
        await vm.waitForHandoffConsumptionsToFinish()
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.sourceBuffer?.width, 8)
        XCTAssertEqual(vm.sourceBuffer?.height, 6)
        XCTAssertEqual(vm.metadata?.processingHistory, history)
        XCTAssertEqual(vm.metadata?.isAlreadyDenoisedByNoiser, false)
        XCTAssertEqual(vm.metadata?.isAlreadyDenoisedBySuite, true)
        XCTAssertEqual(vm.metadata?.upscaledByAppFactor, 2)
        let imported = try XCTUnwrap(vm.sourceURL)
        XCTAssertNotEqual(imported, input)
        XCTAssertEqual(imported.lastPathComponent, "camera.png")
        XCTAssertEqual(try Data(contentsOf: imported), bytes)
        XCTAssertEqual(scopes.releaseCallCount(for: url), 1)
        let request = try XCTUnwrap(vm.incomingHandoffViewerRequest)
        vm.acknowledgeIncomingHandoffViewerRequest(UUID())
        XCTAssertEqual(vm.incomingHandoffViewerRequest, request, "A stale presentation must not consume the current request")
        vm.acknowledgeIncomingHandoffViewerRequest(request)
        XCTAssertNil(vm.incomingHandoffViewerRequest)
        document = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: imported), bytes, "The received photo owns its bytes independently of sender lifetime")
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }

    func testUnsupportedReceivedImageDoesNotLeaveAViewerOrOrphanedImport() async throws {
        let input = directory.appendingPathComponent("unsupported.png")
        let bytes = Data([1, 2, 3, 4]); try bytes.write(to: input)
        let document = try PortableSuiteHandoff.createDocument(exportedImageURL: input,
            originalFileName: input.lastPathComponent, sourceApp: .truongNoiser, targetApp: .truongScaler,
            isDenoised: false, isUpscaled: false, globalMaxLuminance: 1, upscaleFactor: nil,
            globalMaxLinearComponent: 1, directory: directory.appendingPathComponent("send"))
        let receive = directory.appendingPathComponent("receive")
        let vm = model(handoff: AppGroupHandoffManagerSeam(overrideBaseDirectory: receive), decoder: BlockingStudioImageDecoder())
        vm.handleIncomingHandoffURL(document.fileURL)
        await vm.waitForHandoffConsumptionsToFinish()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNil(vm.sourceBuffer)
        XCTAssertNil(vm.incomingHandoffViewerRequest)
        let imports = receive.appendingPathComponent("ImportedDocuments")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? []).isEmpty)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }

    func testSupersededPortableImportRetiresOnlyItsUnconsumedCopyAndCannotOpenViewer() async throws {
        let input = try RealPipelineImageFixture.makePNG(in: directory, name: "incoming.png", width: 8, height: 6)
        let document = try PortableSuiteHandoff.createDocument(exportedImageURL: input,
            originalFileName: input.lastPathComponent, sourceApp: .truongNoiser, targetApp: .truongScaler,
            isDenoised: false, isUpscaled: false, globalMaxLuminance: 1, upscaleFactor: nil,
            globalMaxLinearComponent: 1, directory: directory.appendingPathComponent("send"))
        let manager = GatedPortableHandoffManager(directory: directory.appendingPathComponent("receive"))
        let scopes = RecordingScopeProvider(), vm = model(handoff: manager, scopes: scopes)
        vm.handleIncomingHandoffURL(document.fileURL)
        await manager.gate.entered.wait()
        let imported = try XCTUnwrap(manager.importedPayload)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.imageFileURLPath))
        XCTAssertEqual(scopes.activeGrantCount(for: document.fileURL), 1)
        let selected = try RealPipelineImageFixture.makePNG(in: directory, name: "new-selection.png", width: 8, height: 6)
        await vm.ingestFile(at: selected)
        manager.gate.open()
        await vm.waitForHandoffConsumptionsToFinish()
        XCTAssertEqual(vm.sourceURL, selected)
        XCTAssertNil(vm.incomingHandoffViewerRequest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.imageFileURLPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertEqual(scopes.releaseCallCount(for: document.fileURL), 1)
    }

    func testViewerDismissalSupersedesAnIncomingCopyBeforeItCanReopenTheViewer() async throws {
        let selected = try RealPipelineImageFixture.makePNG(in: directory, name: "visible.png", width: 8, height: 6)
        let incoming = try RealPipelineImageFixture.makePNG(in: directory, name: "incoming-late.png", width: 8, height: 6)
        let document = try PortableSuiteHandoff.createDocument(exportedImageURL: incoming,
            originalFileName: incoming.lastPathComponent, sourceApp: .truongNoiser, targetApp: .truongScaler,
            isDenoised: false, isUpscaled: false, globalMaxLuminance: 1, upscaleFactor: nil,
            globalMaxLinearComponent: 1, directory: directory.appendingPathComponent("late-incoming"))
        let manager = GatedPortableHandoffManager(directory: directory.appendingPathComponent("late-receive"))
        let vm = model(handoff: manager)
        await vm.ingestFile(at: selected)
        vm.handleIncomingHandoffURL(document.fileURL)
        await manager.gate.entered.wait()
        let imported = try XCTUnwrap(manager.importedPayload)
        vm.viewerDidDismiss()
        manager.gate.open()
        await vm.waitForHandoffConsumptionsToFinish()
        XCTAssertEqual(vm.sourceURL, selected)
        XCTAssertNil(vm.incomingHandoffViewerRequest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.imageFileURLPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.path))
    }

    func testUntouchedForwardingUsesDocumentAndDoesNotInventNoiserAttribution() async throws {
        let input = try RealPipelineImageFixture.makePNG(in: directory, name: "unknown-denoiser.png", width: 8, height: 6)
        let decoder = FakeDecoder()
        decoder.setDefaultConfiguration(.init(isAlreadyDenoisedBySuite: true))
        let opener = RecordingOpener()
        let vm = model(handoff: AppGroupHandoffManagerSeam(overrideBaseDirectory: directory.appendingPathComponent("send")),
            decoder: decoder, opener: opener)
        await vm.ingestFile(at: input)
        await vm.sendToTruongNoiser()
        let session = try XCTUnwrap(vm.companionHandoffSession)
        XCTAssertTrue(opener.openedURLs.isEmpty, "A private file path must not be disguised as a cross-sandbox deep link")
        XCTAssertTrue(session.document.payload.isDenoised)
        XCTAssertEqual(session.document.payload.isDenoisedByNoiser, false)
        XCTAssertNil(session.document.payload.processingHistory)
        vm.companionHandoffDidFinish(sessionID: UUID(), unavailable: true)
        XCTAssertEqual(vm.companionHandoffSession?.id, session.id)
        vm.companionHandoffDidFinish(sessionID: session.id, unavailable: true)
        XCTAssertNil(vm.companionHandoffSession)
        XCTAssertTrue(vm.errorMessage?.contains("Install or update TruongNoiser") == true)
    }

    func testRejectedLegacyLaunchIsReportedInsteadOfSilentlySucceeding() async throws {
        let input = try RealPipelineImageFixture.makePNG(in: directory, name: "input.png", width: 8, height: 6)
        let vm = model(handoff: FakeHandoffManager(), opener: RefusingHandoffOpener())
        await vm.ingestFile(at: input)
        await vm.sendToTruongNoiser()
        XCTAssertTrue(vm.errorMessage?.contains("TruongNoiser could not be opened") == true)
    }

    func testViewerDismissalSelectionAndResetRetireAnOutgoingCopyThatFinishesLate() async throws {
        let input = try RealPipelineImageFixture.makePNG(in: directory, name: "outgoing-a.png", width: 8, height: 6)
        let selected = try RealPipelineImageFixture.makePNG(in: directory, name: "selected-b.png", width: 8, height: 6)
        let originalBytes = try Data(contentsOf: input)
        for action in ["dismiss", "selection", "reset"] {
            let manager = GatedOutgoingCompanionManager(directory: directory.appendingPathComponent("send-" + action))
            let vm = model(handoff: manager)
            await vm.ingestFile(at: input)
            let send = Task { await vm.sendToTruongNoiser() }
            let deadline = ContinuousClock.now + .seconds(5)
            while manager.preparedDocumentURL == nil, .now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let document = manager.preparedDocumentURL else {
                manager.gate.open(); await send.value
                XCTFail(vm.errorMessage ?? "The outgoing document did not reach its test gate")
                return
            }
            XCTAssertTrue(vm.isPreparingCompanionHandoff)
            XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))
            switch action {
            case "dismiss": vm.viewerDidDismiss()
            case "selection": await vm.ingestFile(at: selected)
            default: vm.resetSession(); await vm.waitForResetToFinish()
            }
            manager.gate.open(); await send.value
            XCTAssertFalse(vm.isPreparingCompanionHandoff)
            XCTAssertNil(vm.companionHandoffSession, "Photo A may not be presented after its viewer was superseded")
            XCTAssertFalse(FileManager.default.fileExists(atPath: document.path), "Only the unused private transport copy is retired")
            XCTAssertEqual(try Data(contentsOf: input), originalBytes)
            if action == "selection" { XCTAssertEqual(vm.sourceURL, selected) }
        }
    }

    func testAlreadyPreparedUnpresentedDocumentRetiresOnDismissalSelectionAndReset() async throws {
        let input = try RealPipelineImageFixture.makePNG(in: directory, name: "prepared-a.png", width: 8, height: 6)
        let selected = try RealPipelineImageFixture.makePNG(in: directory, name: "prepared-b.png", width: 8, height: 6)
        for action in ["dismiss", "selection", "reset"] {
            let vm = model(handoff: AppGroupHandoffManagerSeam(overrideBaseDirectory: directory.appendingPathComponent("prepared-" + action)))
            await vm.ingestFile(at: input)
            await vm.sendToTruongNoiser()
            let document = try XCTUnwrap(vm.companionHandoffSession?.fileURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))
            switch action {
            case "dismiss": vm.viewerDidDismiss()
            case "selection": await vm.ingestFile(at: selected)
            default: vm.resetSession(); await vm.waitForResetToFinish()
            }
            XCTAssertNil(vm.companionHandoffSession)
            XCTAssertFalse(FileManager.default.fileExists(atPath: document.path))
        }
    }

    func testPublishedResultIsHandedOffWithoutAnotherExportAndChangedSavedBytesAreRefused() async throws {
        let input = try RealPipelineImageFixture.makePNG(in: directory, name: "input.png", width: 8, height: 6)
        let output = directory.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let exporter = CountingHandoffExporter(), store = ProcessedLibraryStore()
        let pipeline = FakePipelineExecutor(directory: directory)
        pipeline.gateExecution = false
        let vm = model(handoff: AppGroupHandoffManagerSeam(overrideBaseDirectory: directory.appendingPathComponent("send")),
            pipeline: pipeline, exporter: exporter, outputRequired: true, store: store)
        await vm.setOutputFolder(url: output)
        await vm.ingestFile(at: input)
        vm.exportFormat = .tiff16BitLZW
        vm.startProcessing()
        let deadline = ContinuousClock.now + .seconds(10)
        while (vm.isProcessing || vm.isSavingResult), .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let failure = vm.errorMessage ?? "none"
        let state = "stage=\(vm.currentStage.rawValue), processing=\(vm.isProcessing), saving=\(vm.isSavingResult), error=\(failure)"
        guard !vm.isProcessing, !vm.isSavingResult else {
            vm.cancelProcessing(); await vm.waitForStopToFinish()
            XCTFail("The immediate test pipeline did not finish publication before the deadline: " + state)
            return
        }
        XCTAssertEqual(vm.currentStage, .readyForInspection, state)
        XCTAssertEqual(pipeline.executionCount, 1, state)
        XCTAssertNil(vm.errorMessage)
        let records = try await store.records(under: output)
        let record = try XCTUnwrap(records.first)
        let saved = output.appendingPathComponent(record.outputRelativePath)
        let savedBytes = try Data(contentsOf: saved), beforeExports = exporter.callCount
        XCTAssertGreaterThan(beforeExports, 0)
        await vm.sendToTruongNoiser()
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(exporter.callCount, beforeExports)
        let session = try XCTUnwrap(vm.companionHandoffSession)
        let received = try PortableSuiteHandoff.importDocument(at: session.fileURL, expectedTarget: .truongNoiser,
            directory: directory.appendingPathComponent("received"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: received.imageFileURLPath)), savedBytes)
        XCTAssertEqual(try Data(contentsOf: saved), savedBytes)
        XCTAssertEqual(URL(fileURLWithPath: received.imageFileURLPath).pathExtension, "tiff")
        vm.companionHandoffDidFinish(sessionID: session.id, unavailable: false)
        var changed = savedBytes
        changed[changed.count - 1] ^= 1
        try changed.write(to: saved)
        await vm.sendToTruongNoiser()
        XCTAssertNil(vm.companionHandoffSession)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(exporter.callCount, beforeExports)
        XCTAssertEqual(try Data(contentsOf: saved), changed, "A failed send must not reset or replace the user's changed file")
    }

    func testSavedSDRHandoffUsesEncodedContainerInsteadOfWorkingOrStaleHeadroom() async throws {
        let manager = AppGroupHandoffManagerSeam(overrideBaseDirectory: directory.appendingPathComponent("saved-sdr-send"))
        let history = recordedHandoffHistory()
        for type in [UTType.jpeg, UTType.png] {
            for staleHeadroom in [false, true] {
                // Deliberately use a TIFF filename: the actual ImageIO container must decide.
                let saved = try makeSavedSDRContainer(type: type, staleHeadroom: staleHeadroom)
                let bytes = try Data(contentsOf: saved)
                let encoded = try MetadataExtractor.extractMetadata(from: saved)
                XCTAssertEqual(encoded.utTypeIdentifier, type.identifier)
                if staleHeadroom { XCTAssertEqual(encoded.linearHeadroomScale, 4) }
                else { XCTAssertNil(encoded.linearHeadroomScale) }
                let prepared = try await manager.prepareOutgoingHandoff(exportedImageURL: saved,
                    originalFileName: "camera.dng", isDenoised: true, isUpscaled: true,
                    globalMaxLuminance: 2, upscaleFactor: 2, globalMaxLinearComponent: 4,
                    isDenoisedByNoiser: true, processingHistory: history,
                    expectedImageSHA256: ProcessedLibraryStore.hash(saved))
                guard case .document(let document) = prepared else { return XCTFail("Expected an owned companion document") }
                XCTAssertEqual(document.payload.globalMaxLinearComponent, 1)
                XCTAssertEqual(document.payload.globalMaxLuminance, 1)
                XCTAssertTrue(document.payload.isDenoised)
                XCTAssertTrue(document.payload.isUpscaled)
                XCTAssertEqual(document.payload.upscaleFactor, 2)
                XCTAssertEqual(document.payload.isDenoisedByNoiser, true)
                XCTAssertEqual(document.payload.processingHistory, history)
                let received = try PortableSuiteHandoff.importDocument(at: document.fileURL, expectedTarget: .truongNoiser,
                    directory: directory.appendingPathComponent("saved-sdr-receive"))
                XCTAssertEqual(received.globalMaxLinearComponent, 1)
                XCTAssertEqual(received.processingHistory, history)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: received.imageFileURLPath)), bytes)
                XCTAssertEqual(try Data(contentsOf: saved), bytes)
            }
        }
    }

    func testSavedHDRDNGHandoffRetainsItsEmbeddedHeadroomAndProcessingEvidence() async throws {
        let source = try RealPipelineImageFixture.makePNG(in: directory, name: "hdr-source.png", width: 8, height: 6)
        let artifacts = try StudioTestArtifacts.make(directory: directory, sourceURL: source,
            configuredScale: .x2, redPeak: 4, grain: 0, inputComponentPeak: 4, metadataHeadroom: 4)
        let saved = directory.appendingPathComponent("saved-hdr.dng")
        let exported = try FormatAwareExporter.exportImageDetailed(artifacts: artifacts, destinationURL: saved,
            overrideFormat: .linearDNG16Bit, overrideGrainAmount: 0)
        XCTAssertEqual(exported.dngHeadroomScale, 4, accuracy: 0.001)
        let encoded = try MetadataExtractor.extractMetadata(from: saved)
        XCTAssertTrue(encoded.isLinearDNG)
        XCTAssertEqual(try XCTUnwrap(encoded.linearHeadroomScale), 4, accuracy: 0.001)
        let bytes = try Data(contentsOf: saved), history = recordedHandoffHistory()
        let manager = AppGroupHandoffManagerSeam(overrideBaseDirectory: directory.appendingPathComponent("saved-hdr-send"))
        let prepared = try await manager.prepareOutgoingHandoff(exportedImageURL: saved,
            originalFileName: "camera.dng", isDenoised: true, isUpscaled: true,
            globalMaxLuminance: 2, upscaleFactor: 2, globalMaxLinearComponent: 8,
            isDenoisedByNoiser: true, processingHistory: history,
            expectedImageSHA256: ProcessedLibraryStore.hash(saved))
        guard case .document(let document) = prepared else { return XCTFail("Expected an owned companion document") }
        XCTAssertEqual(document.payload.globalMaxLinearComponent, 4, accuracy: 0.001)
        XCTAssertEqual(document.payload.globalMaxLuminance, 2)
        XCTAssertTrue(document.payload.isDenoised)
        XCTAssertTrue(document.payload.isUpscaled)
        XCTAssertEqual(document.payload.upscaleFactor, 2)
        XCTAssertEqual(document.payload.isDenoisedByNoiser, true)
        XCTAssertEqual(document.payload.processingHistory, history)
        let received = try PortableSuiteHandoff.importDocument(at: document.fileURL, expectedTarget: .truongNoiser,
            directory: directory.appendingPathComponent("saved-hdr-receive"))
        XCTAssertEqual(received.globalMaxLinearComponent, 4, accuracy: 0.001)
        XCTAssertEqual(received.processingHistory, history)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: received.imageFileURLPath)), bytes)
        XCTAssertEqual(try Data(contentsOf: saved), bytes)
    }

    private func recordedHandoffHistory() -> ImageProcessingHistory {
        ImageProcessingHistory(steps: [
            .init(id: UUID(), app: "com.iantruong.truongscaler", operation: "upscale",
                model: "opaque-legacy-upscaler", scale: 2, inputWidth: 4, inputHeight: 3, outputWidth: 8, outputHeight: 6),
            .init(id: UUID(), app: "com.iantruong.truongnoiser", operation: "denoise",
                model: "opaque-legacy-denoiser", scale: nil, inputWidth: 8, inputHeight: 6, outputWidth: 8, outputHeight: 6)
        ])
    }

    private func makeSavedSDRContainer(type: UTType, staleHeadroom: Bool) throws -> URL {
        let input = try RealPipelineImageFixture.makePNG(in: directory, name: "pixels-\(UUID()).png", width: 8, height: 6)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(input as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let saved = directory.appendingPathComponent("saved-\(UUID()).tiff")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(saved as CFURL, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if staleHeadroom {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment as String: "HeadroomScale=4"]
            if type == .png {
                properties[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGSoftware as String: "HeadroomScale=4"]
            }
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return saved
    }
}
