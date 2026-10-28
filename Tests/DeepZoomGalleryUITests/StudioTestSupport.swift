import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import TruongScalerCore
import MMapCanvas
import CoreIngestion
import CoreExport
import TiledInferenceEngine
import BackgroundJobManager
@testable import DeepZoomGalleryUI

// MARK: - One-shot async signals

/// A minimal one-shot async signal (deliberately not an `actor`, so gated seams can signal from
/// synchronous callers too).
final class TestSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        lock.lock()
        signaled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            enqueue(continuation)
        }
    }

    private func enqueue(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if signaled {
            lock.unlock()
            continuation.resume()
        } else {
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

/// A gate that signals when entered and suspends until `open()` is called.
final class TestGate: @unchecked Sendable {
    let entered = TestSignal()
    private let releaseSignal = TestSignal()

    func hold() async {
        entered.signal()
        await releaseSignal.wait()
    }

    func open() {
        releaseSignal.signal()
    }
}

/// A gate that also resumes when the calling task is cancelled (models executor cancellation).
final class CancellableGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                self.enqueue(continuation)
            }
        }, onCancel: {
            self.resumeAll()
        })
    }

    private func enqueue(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if isOpen {
            lock.unlock()
            continuation.resume()
        } else {
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        resumeAll()
    }

    private func resumeAll() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}

/// Thread-safe ordered event log shared by fake seams.
final class TestEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func index(of event: String) -> Int? {
        events.firstIndex(of: event)
    }

    var count: Int { events.count }
}

// MARK: - Recording security-scope provider

final class RecordingScopeProvider: SecurityScopeGrantProviding, @unchecked Sendable {
    final class Grant: SecurityScopeGrant, @unchecked Sendable {
        let id = UUID()
        let url: URL
        private let lock = NSLock()
        private var released = false
        private var releaseCalls = 0

        init(url: URL) { self.url = url }

        func release() {
            lock.lock()
            releaseCalls += 1
            released = true
            lock.unlock()
        }

        var isReleased: Bool {
            lock.lock(); defer { lock.unlock() }
            return released
        }

        var releaseCallCount: Int {
            lock.lock(); defer { lock.unlock() }
            return releaseCalls
        }
    }

    private let lock = NSLock()
    private var grants: [Grant] = []

    func openGrant(for url: URL) -> any SecurityScopeGrant {
        let grant = Grant(url: url)
        lock.lock()
        grants.append(grant)
        lock.unlock()
        return grant
    }

    var allGrants: [Grant] {
        lock.lock(); defer { lock.unlock() }
        return grants
    }

    var acquiredCount: Int { allGrants.count }
    var activeGrants: [Grant] { allGrants.filter { !$0.isReleased } }
    var activeGrantCount: Int { activeGrants.count }
    var unbalancedCount: Int { activeGrants.count }

    func activeGrantCount(for url: URL) -> Int {
        activeGrants.filter { $0.url.standardizedFileURL == url.standardizedFileURL }.count
    }

    func grants(for url: URL) -> [Grant] {
        allGrants.filter { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    /// Total release invocations across every grant opened for this URL. Exactly-once teardown
    /// asserts that each grant's own `releaseCallCount` is 1.
    func releaseCallCount(for url: URL) -> Int {
        grants(for: url).reduce(0) { $0 + $1.releaseCallCount }
    }

    var uniqueGrantIdentifiers: Int {
        Set(allGrants.map(\.id)).count
    }
}

// MARK: - Fake decoder

struct FakeDecodeConfiguration: Sendable {
    var width: Int = 8
    var height: Int = 6
    var utTypeIdentifier: String = "public.jpeg"
    var category: SourceImageCategory = .standardOpaqueRaster
    var isoSpeedRatings: Int? = 800
    var isAlreadyDenoisedBySuite: Bool = false
    var isAlreadyUpscaledBySuite: Bool = false
    var upscaledByAppFactor: Int? = nil
    var linearHeadroomScale: Float? = nil
}

final class FakeDecoder: StudioImageDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [String: TestGate] = [:]
    private var configurations: [String: FakeDecodeConfiguration] = [:]
    private var defaultConfiguration = FakeDecodeConfiguration()
    private var decodedURLs: [URL] = []

    /// URLs actually passed to the decoder, in order. Used to prove superseded handoffs never
    /// resurrect a session (no decode happens at all).
    var recordedDecodeURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return decodedURLs
    }

    func setGate(_ gate: TestGate, forFileName name: String) {
        lock.lock(); gates[name] = gate; lock.unlock()
    }

    func setConfiguration(_ configuration: FakeDecodeConfiguration, forFileName name: String) {
        lock.lock(); configurations[name] = configuration; lock.unlock()
    }

    func setDefaultConfiguration(_ configuration: FakeDecodeConfiguration) {
        lock.lock(); defaultConfiguration = configuration; lock.unlock()
    }

    private func gate(for name: String) -> TestGate? {
        lock.lock(); defer { lock.unlock() }
        return gates[name]
    }

    private func configuration(for name: String) -> FakeDecodeConfiguration {
        lock.lock(); defer { lock.unlock() }
        return configurations[name] ?? defaultConfiguration
    }

    func decodeImage(at url: URL, destinationMMapURL: URL) async throws -> DecodedSourceResult {
        lock.withLock { decodedURLs.append(url) }
        if let gate = gate(for: url.lastPathComponent) {
            await gate.hold()
        }
        let configuration = configuration(for: url.lastPathComponent)
        let buffer = try MMapBuffer(
            fileURL: destinationMMapURL,
            width: configuration.width,
            height: configuration.height,
            deleteOnDeinit: false
        )
        for y in 0..<configuration.height {
            for x in 0..<configuration.width {
                let pixel = buffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = 0.5
                pixel[1] = 0.25
                pixel[2] = 0.1
                pixel[3] = 1
            }
        }
        let metadata = ImageMetadataPacket(
            sourceURL: url,
            utTypeIdentifier: configuration.utTypeIdentifier,
            category: configuration.category,
            originalWidth: configuration.width,
            originalHeight: configuration.height,
            isoSpeedRatings: configuration.isoSpeedRatings,
            isAlreadyDenoisedBySuite: configuration.isAlreadyDenoisedBySuite,
            isAlreadyUpscaledBySuite: configuration.isAlreadyUpscaledBySuite,
            upscaledByAppFactor: configuration.upscaledByAppFactor,
            linearHeadroomScale: configuration.linearHeadroomScale
        )
        return DecodedSourceResult(
            metadata: metadata,
            sourceBuffer: buffer,
            globalMaxLuminance: 0.5,
            globalMaxLinearComponent: 0.5,
            decodedWidth: configuration.width,
            decodedHeight: configuration.height
        )
    }
}

// MARK: - Fake exporter

final class FakeExporter: StudioImageExporting, @unchecked Sendable {
    struct Call: Sendable {
        let destinationURL: URL
        let format: ExportFormat?
        let grainAmount: Float?
        let configuredScale: ScaleFactor
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var peak: Float = 1.0
    private var factor: Int?
    var gate: TestGate?
    var error: Error?
    let log: TestEventLog?

    init(log: TestEventLog? = nil) {
        self.log = log
    }

    func configure(finalPeak: Float, actualScaleFactor: Int? = nil) {
        lock.lock()
        peak = finalPeak
        factor = actualScaleFactor
        lock.unlock()
    }

    var recordedCalls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    private var currentPeak: Float {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    private var currentFactor: Int? {
        lock.lock(); defer { lock.unlock() }
        return factor
    }

    private func recordCall(_ call: Call) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    func exportDetailed(
        artifacts: CompletedPipelineArtifacts,
        destinationURL: URL,
        overrideFormat: ExportFormat?,
        overrideGrainAmount: Float?
    ) async throws -> ExportResult {
        recordCall(
            Call(
                destinationURL: destinationURL,
                format: overrideFormat,
                grainAmount: overrideGrainAmount,
                configuredScale: artifacts.checkpoint.config.scaleFactor
            )
        )

        if let gate { await gate.hold() }
        if let error { throw error }

        let measuredPeak = currentPeak
        let resolvedFactor = currentFactor
            ?? max(1, Int((Double(artifacts.outputBuffer.width) / Double(max(1, artifacts.sourceBuffer.width))).rounded()))
        try Data([0x00]).write(to: destinationURL, options: .atomic)
        log?.record("exported")
        return ExportResult(
            url: destinationURL,
            format: overrideFormat ?? artifacts.checkpoint.config.exportFormat,
            finalLinearPeak: measuredPeak,
            actualScaleFactor: resolvedFactor,
            dngHeadroomScale: max(1, measuredPeak),
            isHDR: measuredPeak > 1.0 + 1e-4
        )
    }
}

// MARK: - Fake library scanner

final class FakeScanner: StudioLibraryScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [String: TestGate] = [:]
    private var itemsByFolder: [String: [LibraryPhotoItem]] = [:]
    private var defaultItems: [LibraryPhotoItem] = []
    private(set) var scanCount = 0

    func setGate(_ gate: TestGate, forFolderName name: String) {
        lock.lock(); gates[name] = gate; lock.unlock()
    }

    func setItems(_ items: [LibraryPhotoItem], forFolderName name: String) {
        lock.lock(); itemsByFolder[name] = items; lock.unlock()
    }

    func setDefaultItems(_ items: [LibraryPhotoItem]) {
        lock.lock(); defaultItems = items; lock.unlock()
    }

    private func scanConfiguration(for scanRoot: URL) -> (gate: TestGate?, items: [LibraryPhotoItem]) {
        let folderName = scanRoot.lastPathComponent
        let parentName = scanRoot.deletingLastPathComponent().lastPathComponent
        lock.lock()
        scanCount += 1
        let gate = gates[folderName] ?? gates[parentName]
        let items = itemsByFolder[folderName] ?? itemsByFolder[parentName] ?? defaultItems
        lock.unlock()
        return (gate, items)
    }

    func scanLibraryItems(at scanRoot: URL) async -> [LibraryPhotoItem] {
        let configuration = scanConfiguration(for: scanRoot)
        if let gate = configuration.gate { await gate.hold() }
        return configuration.items
    }
}

// MARK: - Gated thumbnail readers

/// Deterministic thumbnail reader: records each requested URL, then suspends on a gate until the
/// test opens it. Models the real ImageIO read draining after a folder changes.
final class GatedThumbnailReader: StudioThumbnailReading, @unchecked Sendable {
    let gate: TestGate
    let image: CGImage?
    private let lock = NSLock()
    private var requestedURLs: [URL] = []

    init(gate: TestGate, image: CGImage? = nil) {
        self.gate = gate
        self.image = image
    }

    var requests: [URL] {
        lock.lock(); defer { lock.unlock() }
        return requestedURLs
    }

    func readThumbnail(at url: URL, maxPixelSize: Int) async -> CGImage? {
        lock.withLock { requestedURLs.append(url) }
        await gate.hold()
        return image
    }
}

/// Thumbnail reader whose blocked read drains as soon as the requesting task is cancelled, modelling
/// an ImageIO read that observes cancellation at its next boundary.
final class CancellableGatedThumbnailReader: StudioThumbnailReading, @unchecked Sendable {
    let gate: CancellableGate
    let image: CGImage?
    private let lock = NSLock()
    private var requestedURLs: [URL] = []

    init(gate: CancellableGate, image: CGImage? = nil) {
        self.gate = gate
        self.image = image
    }

    var requests: [URL] {
        lock.lock(); defer { lock.unlock() }
        return requestedURLs
    }

    func readThumbnail(at url: URL, maxPixelSize: Int) async -> CGImage? {
        lock.withLock { requestedURLs.append(url) }
        await gate.wait()
        return image
    }
}

// MARK: - Fake pipeline executor

final class FakePipelineExecutor: StudioPipelineExecuting, @unchecked Sendable {
    struct RecordedExecution: Sendable {
        let config: UpscaleJobConfig
        let mergedIsDenoised: Bool
        let shouldRunDenoiserAuto: Bool
        let shouldRunDenoiserConfigured: Bool
        let mergedUpscaleFactor: Int?
    }

    private let lock = NSLock()
    private var recorded: [RecordedExecution] = []
    private var lastProgressHandler: (@Sendable (PipelineProgressUpdate) -> Void)?
    private var executions = 0
    private var concurrent = 0
    private var maxConcurrent = 0
    private var pauseWaits = 0
    private var clearPauses = 0
    private var cancellations = 0
    private var failure: Error?
    private let directory: URL
    let log: TestEventLog
    let executeGate: CancellableGate
    let pauseGate: TestGate?
    var gateExecution = true

    init(directory: URL, log: TestEventLog = TestEventLog(), pauseGate: TestGate? = nil) {
        self.directory = directory
        self.log = log
        self.executeGate = CancellableGate()
        self.pauseGate = pauseGate
    }

    func openExecutionGate() { executeGate.open() }

    func configureFailure(_ error: Error?) {
        lock.lock(); failure = error; lock.unlock()
    }

    var executionCount: Int { lock.lock(); defer { lock.unlock() }; return executions }
    var maxConcurrentExecutions: Int { lock.lock(); defer { lock.unlock() }; return maxConcurrent }
    var pauseWaitCount: Int { lock.lock(); defer { lock.unlock() }; return pauseWaits }
    var clearPauseCount: Int { lock.lock(); defer { lock.unlock() }; return clearPauses }
    var cancelledExecutionCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    var recordedExecutions: [RecordedExecution] { lock.lock(); defer { lock.unlock() }; return recorded }

    private func beginExecution() {
        lock.lock()
        executions += 1
        concurrent += 1
        maxConcurrent = max(maxConcurrent, concurrent)
        lock.unlock()
    }

    private func endExecution() {
        lock.lock()
        concurrent -= 1
        lock.unlock()
    }

    private func recordCancellation() {
        lock.lock()
        cancellations += 1
        lock.unlock()
    }

    private func record(_ execution: RecordedExecution) -> Error? {
        lock.lock()
        recorded.append(execution)
        let configuredFailure = failure
        lock.unlock()
        return configuredFailure
    }

    private func incrementPauseWait() {
        lock.lock()
        pauseWaits += 1
        lock.unlock()
    }

    private func incrementClearPause() {
        lock.lock()
        clearPauses += 1
        lock.unlock()
    }

    func executeOrResumeJob(
        config: UpscaleJobConfig,
        progressHandler: (@Sendable (PipelineProgressUpdate) -> Void)?
    ) async throws -> CompletedPipelineArtifacts {
        beginExecution()
        lock.withLock { lastProgressHandler = progressHandler }
        log.record("execute")
        defer { endExecution() }

        if gateExecution { await executeGate.wait() }
        if Task.isCancelled {
            recordCancellation()
            log.record("executionCancelled")
            throw CancellationError()
        }

        let decodedStub = ImageMetadataPacket(
            sourceURL: config.sourceImageURL,
            utTypeIdentifier: "public.jpeg",
            category: .standardOpaqueRaster,
            originalWidth: 8,
            originalHeight: 6,
            isoSpeedRatings: 800
        )
        let merged = decodedStub.merging(sessionState: config.sessionState)
        let execution = RecordedExecution(
            config: config,
            mergedIsDenoised: merged.isAlreadyDenoisedBySuite,
            shouldRunDenoiserAuto: merged.shouldRunDenoiser(mode: .auto),
            shouldRunDenoiserConfigured: merged.shouldRunDenoiser(mode: config.denoiseMode),
            mergedUpscaleFactor: merged.upscaledByAppFactor
        )
        let configuredFailure = record(execution)
        progressHandler?(
            PipelineProgressUpdate(
                jobID: config.id,
                stage: .denoisingAndUpscalingTiles,
                completedTiles: 1,
                totalTiles: 4,
                overallFraction: 0.5,
                estimatedSecondsRemaining: 1,
                phase: .committingTile,
                currentTileIndex: 1
            )
        )
        if let configuredFailure { throw configuredFailure }
        return try makeArtifacts(config: config, mergedMetadata: merged)
    }

    /// Test-only: deliver a progress callback after the execution has already returned, proving the
    /// view model's terminal-generation guard ignores late work.
    func sendLateProgress(_ update: PipelineProgressUpdate) {
        lock.lock(); let handler = lastProgressHandler; lock.unlock()
        handler?(update)
    }

    func requestGracefulPauseAndWait() async {
        incrementPauseWait()
        log.record("pauseWait")
        if let pauseGate { await pauseGate.hold() }
    }

    func clearPauseRequest() async {
        incrementClearPause()
        log.record("clearPause")
    }

    private func makeArtifacts(
        config: UpscaleJobConfig,
        mergedMetadata: ImageMetadataPacket
    ) throws -> CompletedPipelineArtifacts {
        let scale: Int = config.backbone == .unavailable ? 4 : config.scaleFactor.rawValue
        let sourceWidth = 8, sourceHeight = 6
        let outputWidth = sourceWidth * scale
        let outputHeight = sourceHeight * scale
        let sourceBuffer = try MMapBuffer(
            fileURL: directory.appendingPathComponent("src_\(UUID().uuidString).bin"),
            width: sourceWidth,
            height: sourceHeight,
            deleteOnDeinit: true
        )
        let outputBuffer = try MMapBuffer(
            fileURL: directory.appendingPathComponent("out_\(UUID().uuidString).bin"),
            width: outputWidth,
            height: outputHeight,
            deleteOnDeinit: true
        )
        for y in 0..<outputHeight {
            for x in 0..<outputWidth {
                let pixel = outputBuffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = 0.5
                pixel[1] = 0.25
                pixel[2] = 0.1
                pixel[3] = 1
            }
        }
        let didRunDenoise = mergedMetadata.shouldRunDenoiser(mode: config.denoiseMode)
        let checkpoint = JobCheckpointState(
            jobID: config.id,
            config: config,
            tileConfig: TileConfiguration(tier: .tierA_HighMemory),
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            paddedSourceWidth: sourceWidth,
            paddedSourceHeight: sourceHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            globalMaxLuminance: 1.0,
            globalMaxLinearComponent: 1.0,
            alphaCurveConstant: 16.0,
            didRunDenoise: didRunDenoise,
            sourceMMapFileName: "source.bin",
            outputMMapFileName: "output.bin",
            metadataPacketFileName: "metadata.json",
            lastCompletedTileIndex: 0,
            totalTiles: 1,
            normalizationPeakVersion: JobCheckpointState.currentNormalizationPeakVersion
        )
        return CompletedPipelineArtifacts(
            checkpoint: checkpoint,
            metadata: mergedMetadata,
            sourceBuffer: sourceBuffer,
            outputBuffer: outputBuffer
        )
    }
}

// MARK: - Fake handoff manager

final class FakeHandoffManager: StudioHandoffManaging, @unchecked Sendable {
    struct PackageCall: Sendable {
        let exportedImageURL: URL
        let originalFileName: String
        let isDenoised: Bool
        let isUpscaled: Bool
        let globalMaxLuminance: Float
        let upscaleFactor: Int?
        let globalMaxLinearComponent: Float
    }

    private let lock = NSLock()
    private var calls: [PackageCall] = []
    private var consumedPayload: SharedSuiteHandoffPayload?
    private var consumeGates: [String: TestGate] = [:]
    private var consumePayloads: [String: SharedSuiteHandoffPayload] = [:]
    private var consumeErrors: [String: Error] = [:]
    var consumeError: Error?
    var packageError: Error?
    var packageGate: TestGate?

    func configureConsumedPayload(_ payload: SharedSuiteHandoffPayload?) {
        lock.lock(); consumedPayload = payload; lock.unlock()
    }

    /// Gates the consume await for one exact deep link, modelling a slow App Group handoff read.
    func setConsumeGate(_ gate: TestGate, forDeepLink url: URL) {
        lock.lock(); consumeGates[url.absoluteString] = gate; lock.unlock()
    }

    func configureConsumedPayload(_ payload: SharedSuiteHandoffPayload, forDeepLink url: URL) {
        lock.lock(); consumePayloads[url.absoluteString] = payload; lock.unlock()
    }

    func setConsumeError(_ error: Error, forDeepLink url: URL) {
        lock.lock(); consumeErrors[url.absoluteString] = error; lock.unlock()
    }

    var packageCalls: [PackageCall] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func consumeIncomingHandoff(from deepLinkURL: URL) async throws -> SharedSuiteHandoffPayload {
        let key = deepLinkURL.absoluteString
        let (gate, payload, error) = lock.withLock {
            (
                consumeGates[key],
                consumePayloads[key] ?? consumedPayload,
                consumeErrors[key] ?? consumeError
            )
        }

        if let gate { await gate.hold() }
        if let error { throw error }
        guard let payload else {
            throw ScalerError.fileNotFound(deepLinkURL)
        }
        return payload
    }

    private func appendCall(_ call: PackageCall) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    func createHandoffPackage(
        exportedImageURL: URL,
        originalFileName: String,
        isDenoised: Bool,
        isUpscaled: Bool,
        globalMaxLuminance: Float,
        upscaleFactor: Int?,
        globalMaxLinearComponent: Float
    ) async throws -> (payload: SharedSuiteHandoffPayload, deepLinkURL: URL) {
        if let packageError { throw packageError }
        if let packageGate { await packageGate.hold() }
        let call = PackageCall(
            exportedImageURL: exportedImageURL,
            originalFileName: originalFileName,
            isDenoised: isDenoised,
            isUpscaled: isUpscaled,
            globalMaxLuminance: globalMaxLuminance,
            upscaleFactor: upscaleFactor,
            globalMaxLinearComponent: globalMaxLinearComponent
        )
        appendCall(call)
        let payload = SharedSuiteHandoffPayload(
            sourceApp: .truongScaler,
            targetApp: .truongNoiser,
            imageFileURLPath: exportedImageURL.path,
            originalFileName: originalFileName,
            isDenoised: isDenoised,
            isUpscaled: isUpscaled,
            globalMaxLuminance: globalMaxLuminance,
            upscaleFactor: upscaleFactor,
            globalMaxLinearComponent: globalMaxLinearComponent
        )
        return (payload, URL(string: "truongnoiser://handoff?id=\(payload.handoffID.uuidString)")!)
    }
}

// MARK: - Recording external opener

final class RecordingOpener: ExternalApplicationOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    var openedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return urls
    }

    private func record(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func open(_ url: URL) async {
        record(url)
    }
}

// MARK: - Real decodable image fixtures

/// Writes a genuinely decodable image into the test temporary directory so an end-to-end
/// `StudioViewModel` run exercises the production ImageIO decode path instead of a synthetic mmap.
enum RealPipelineImageFixture {
    enum FixtureError: Error {
        case synthesisFailed
        case finalizeFailed
    }

    /// A small 8-bit RGBA PNG with a deterministic gradient. ImageIO (`CGImageDestination`) writes the
    /// bytes; `BlockingStudioImageDecoder` / `UniversalStripDecoder` read them back into a real mmap.
    @discardableResult
    static func makePNG(
        in directory: URL,
        name: String,
        width: Int = 48,
        height: Int = 32
    ) throws -> URL {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw FixtureError.synthesisFailed
        }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = UInt8((x * 255) / max(1, width - 1))
                pixels[offset + 1] = UInt8((y * 255) / max(1, height - 1))
                pixels[offset + 2] = UInt8(((x + y) * 255) / max(1, width + height - 2))
                pixels[offset + 3] = 255
            }
        }
        let url = directory.appendingPathComponent(name)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else {
            throw FixtureError.synthesisFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.finalizeFailed
        }
        return url
    }
}

// MARK: - Artifact fixtures

enum StudioTestArtifacts {
    static func make(
        directory: URL,
        sourceURL: URL,
        configuredScale: ScaleFactor = .x4,
        backbone: BackboneModelKind = .quickSRNet,
        sourceWidth: Int = 8,
        sourceHeight: Int = 6,
        redPeak: Float = 0.5,
        grain: Float = 0.15,
        denoiseMode: DenoiseMode = .auto,
        didRunDenoise: Bool = true,
        inputComponentPeak: Float = 1.0,
        inputLuminance: Float = 1.0,
        metadataIsDenoised: Bool = false,
        metadataIsUpscaled: Bool = false,
        metadataUpscaleFactor: Int? = nil,
        metadataHeadroom: Float? = nil
    ) throws -> CompletedPipelineArtifacts {
        let scale: Int = backbone == .unavailable ? 4 : configuredScale.rawValue
        let outputWidth = sourceWidth * scale
        let outputHeight = sourceHeight * scale
        let sourceBuffer = try MMapBuffer(
            fileURL: directory.appendingPathComponent("fixture_src_\(UUID().uuidString).bin"),
            width: sourceWidth,
            height: sourceHeight,
            deleteOnDeinit: true
        )
        let outputBuffer = try MMapBuffer(
            fileURL: directory.appendingPathComponent("fixture_out_\(UUID().uuidString).bin"),
            width: outputWidth,
            height: outputHeight,
            deleteOnDeinit: true
        )
        for y in 0..<outputHeight {
            for x in 0..<outputWidth {
                let pixel = outputBuffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = Float16(redPeak)
                pixel[1] = Float16(0.0)
                pixel[2] = Float16(0.0)
                pixel[3] = 1
            }
        }
        let metadata = ImageMetadataPacket(
            sourceURL: sourceURL,
            utTypeIdentifier: "public.jpeg",
            category: .standardOpaqueRaster,
            originalWidth: sourceWidth,
            originalHeight: sourceHeight,
            isoSpeedRatings: 800,
            isAlreadyDenoisedBySuite: metadataIsDenoised,
            isAlreadyUpscaledBySuite: metadataIsUpscaled,
            upscaledByAppFactor: metadataUpscaleFactor,
            linearHeadroomScale: metadataHeadroom
        )
        let config = UpscaleJobConfig(
            sourceImageURL: sourceURL,
            scaleFactor: configuredScale,
            backbone: backbone,
            denoiseMode: denoiseMode,
            naturalGrainAmount: grain,
            exportFormat: .linearDNG16Bit
        )
        let checkpoint = JobCheckpointState(
            jobID: config.id,
            config: config,
            tileConfig: TileConfiguration(tier: .tierA_HighMemory),
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            paddedSourceWidth: sourceWidth,
            paddedSourceHeight: sourceHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            globalMaxLuminance: inputLuminance,
            globalMaxLinearComponent: inputComponentPeak,
            alphaCurveConstant: 16.0,
            didRunDenoise: didRunDenoise,
            sourceMMapFileName: "source.bin",
            outputMMapFileName: "output.bin",
            metadataPacketFileName: "metadata.json",
            lastCompletedTileIndex: 0,
            totalTiles: 1,
            normalizationPeakVersion: JobCheckpointState.currentNormalizationPeakVersion
        )
        return CompletedPipelineArtifacts(
            checkpoint: checkpoint,
            metadata: metadata,
            sourceBuffer: sourceBuffer,
            outputBuffer: outputBuffer
        )
    }

    static func libraryItem(named name: String) -> LibraryPhotoItem {
        LibraryPhotoItem(
            id: name,
            fileURL: URL(fileURLWithPath: "/library/\(name)"),
            filename: name,
            capturedAt: Date(timeIntervalSince1970: 0),
            byteCount: 1,
            badgeLabel: nil
        )
    }
}
