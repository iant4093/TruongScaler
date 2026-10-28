import Foundation
import SwiftUI
import Observation
import ImageIO
import UniformTypeIdentifiers
import os
import TruongScalerCore
import MMapCanvas
import CoreIngestion
import MetalColorEngine
import TiledInferenceEngine
import CoreExport
import BackgroundJobManager
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

// MARK: - Security-scope grants

/// One independent, exactly-once security-scope grant.
///
/// Every off-main operation (decode, execution, export, library scan, handoff staging) acquires its
/// own grant from a `SecurityScopeGrantProviding`; leases are never copied with a shared consumed
/// bit. `init` performs the matching `startAccessingSecurityScopedResource()` and `release()` the
/// matching stop, at most once.
protocol SecurityScopeGrant: AnyObject, Sendable {
    var url: URL { get }
    func release()
}

final class SecurityScopeLease: SecurityScopeGrant, @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false
    let url: URL
    private let openedLease: Bool

    init(url: URL) {
        self.url = url
        self.openedLease = url.startAccessingSecurityScopedResource()
    }

    func release() {
        lock.lock()
        if consumed {
            lock.unlock()
            return
        }
        consumed = true
        let shouldRelease = openedLease
        lock.unlock()
        if shouldRelease {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

/// Opens independent grants for each operation. Production uses the system security-scope API; tests
/// inject a recording provider so grant balance/no-early-release can be asserted deterministically.
protocol SecurityScopeGrantProviding: Sendable {
    func openGrant(for url: URL) -> any SecurityScopeGrant
}

struct SystemSecurityScopeGrantProvider: SecurityScopeGrantProviding {
    func openGrant(for url: URL) -> any SecurityScopeGrant {
        SecurityScopeLease(url: url)
    }
}

// MARK: - Injected orchestration seams

/// Full-resolution decode seam (blocking ImageIO work in production).
protocol StudioImageDecoding: Sendable {
    func decodeImage(at url: URL, destinationMMapURL: URL) async throws -> DecodedSourceResult
    func decodeImage(at url: URL, destinationMMapURL: URL, validatedContentSHA256: String?) async throws -> DecodedSourceResult
}

extension StudioImageDecoding {
    func decodeImage(at url: URL, destinationMMapURL: URL, validatedContentSHA256: String?) async throws -> DecodedSourceResult {
        try await decodeImage(at: url, destinationMMapURL: destinationMMapURL)
    }
}

struct BlockingStudioImageDecoder: StudioImageDecoding {
    private let owner = BlockingIOOwner(label: "com.truongscaler.studio-view-model.decode")

    func decodeImage(at url: URL, destinationMMapURL: URL) async throws -> DecodedSourceResult {
        try await owner.run {
            let decoded = try UniversalStripDecoder.decodeToMMap(
                imageURL: url,
                destinationMMapURL: destinationMMapURL,
                deleteDestinationOnDeinit: true
            )
            // These are private display decodes, never checkpoint canvases. The open mapping
            // retains its bytes without a directory entry, and process death cannot orphan it.
            try? FileManager.default.removeItem(at: destinationMMapURL)
            return decoded
        }
    }
}

/// Export seam. Production uses the detailed exporter so the outgoing handoff can carry the measured
/// final grain-blended component peak (`ExportResult.dngHeadroomScale`) and the actual artifact ratio.
protocol StudioImageExporting: Sendable {
    func exportDetailed(
        artifacts: CompletedPipelineArtifacts,
        destinationURL: URL,
        overrideFormat: ExportFormat?,
        overrideGrainAmount: Float?
    ) async throws -> ExportResult
}

/// Share snapshot seam for deterministic failure/supersession checks. Production still makes
/// private, byte-for-byte snapshots under its independently owned file grants.
protocol StudioPhotoSharePreparing: Sendable {
    func prepare(_ urls: [URL], surface: PhotoShareSurface, expectedHashes: [URL: String]) async throws -> PhotoShareSession
}
extension PhotoSharePreparer: StudioPhotoSharePreparing {}

struct BlockingStudioImageExporter: StudioImageExporting {
    private let owner = BlockingIOOwner(label: "com.truongscaler.studio-view-model.export")

    func exportDetailed(
        artifacts: CompletedPipelineArtifacts,
        destinationURL: URL,
        overrideFormat: ExportFormat?,
        overrideGrainAmount: Float?
    ) async throws -> ExportResult {
        try await owner.run {
            try FormatAwareExporter.exportImageDetailed(
                artifacts: artifacts,
                destinationURL: destinationURL,
                overrideFormat: overrideFormat,
                overrideGrainAmount: overrideGrainAmount
            )
        }
    }
}

/// Library enumeration seam (blocking directory/resource-value reads in production).
protocol StudioLibraryScanning: Sendable {
    func scanLibraryItems(at scanRoot: URL) async -> [LibraryPhotoItem]
}

struct BlockingLibraryScanner: StudioLibraryScanning {
    private let owner = BlockingIOOwner(label: "com.truongscaler.studio-view-model.library-scan")

    func scanLibraryItems(at scanRoot: URL) async -> [LibraryPhotoItem] {
        await owner.runInfallible {
            StudioViewModel.scanLibraryItemsSynchronously(at: scanRoot)
        }
    }
}

/// Thumbnail-read seam. Production performs the real ImageIO downsample off MainActor; tests inject
/// a gated reader so scope ownership across a folder release/switch can be proven deterministically.
protocol StudioThumbnailReading: Sendable {
    func readThumbnail(at url: URL, maxPixelSize: Int) async -> CGImage?
}

struct ImageIOThumbnailReader: StudioThumbnailReading {
    private let owner: BlockingIOOwner
    init(owner: BlockingIOOwner = BlockingIOOwner(label: "com.truongscaler.studio-view-model.thumbnail")) {
        self.owner = owner
    }

    func readThumbnail(at url: URL, maxPixelSize: Int) async -> CGImage? {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await owner.runInfallible {
                // Offscreen cells keep their lease until this queued work drains, but do not
                // decode obsolete RAW previews ahead of the newly visible cells.
                guard !cancelled.withLock({ $0 }) else { return nil }
                return autoreleasepool { () -> CGImage? in
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                    ]
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }
}

/// Pipeline-execution seam. Production is the real tiled executor; tests gate start/execute/pause so
/// overlapping runs and stale cleanup can be proven deterministically.
protocol StudioPipelineExecuting: Sendable {
    func executeOrResumeJob(
        config: UpscaleJobConfig,
        progressHandler: (@Sendable (PipelineProgressUpdate) -> Void)?
    ) async throws -> CompletedPipelineArtifacts
    func requestGracefulPauseAndWait() async
    func clearPauseRequest() async
    /// Scaler is SR-only. Any future/legacy resume entry point must call this first; it refuses a
    /// checkpoint that already used (or was configured to use) the retired denoise stage without
    /// mutating the checkpoint or output. The current app starts a new job ID for every run.
    func validateResumeCompatibility(_ checkpoint: JobCheckpointState) throws
}

extension StudioPipelineExecuting {
    func validateResumeCompatibility(_ checkpoint: JobCheckpointState) throws {}
}

struct TiledExecutorPipelineAdapter: StudioPipelineExecuting {
    let executor: TiledPipelineExecutor

    func executeOrResumeJob(
        config: UpscaleJobConfig,
        progressHandler: (@Sendable (PipelineProgressUpdate) -> Void)?
    ) async throws -> CompletedPipelineArtifacts {
        try ScalerSRPolicy.validateJobConfig(config)
        return try await executor.executeOrResumeJob(config: config, progressHandler: progressHandler)
    }

    func requestGracefulPauseAndWait() async {
        await executor.requestGracefulPauseAndWait()
    }

    func clearPauseRequest() async {
        await executor.clearPauseRequest()
    }

    func validateResumeCompatibility(_ checkpoint: JobCheckpointState) throws {
        try ScalerSRPolicy.validateResume(checkpoint)
    }
}

/// App Group handoff seam. Production passes `overrideBaseDirectory: nil` so a missing App Group is
/// the actionable `ScalerError.appGroupUnavailable`; tests may supply a temporary group directory to
/// validate the real manifest/byte-copy path.
protocol StudioHandoffManaging: Sendable {
    func consumeIncomingHandoff(from deepLinkURL: URL) async throws -> SharedSuiteHandoffPayload
    func createHandoffPackage(
        exportedImageURL: URL,
        originalFileName: String,
        isDenoised: Bool,
        isUpscaled: Bool,
        globalMaxLuminance: Float,
        upscaleFactor: Int?,
        globalMaxLinearComponent: Float
    ) async throws -> (payload: SharedSuiteHandoffPayload, deepLinkURL: URL)
}

struct AppGroupHandoffManagerSeam: StudioHandoffManaging {
    let overrideBaseDirectory: URL?
    private let owner = BlockingIOOwner(label: "com.truongscaler.studio-view-model.handoff")

    init(overrideBaseDirectory: URL? = nil) {
        self.overrideBaseDirectory = overrideBaseDirectory
    }

    func consumeIncomingHandoff(from deepLinkURL: URL) async throws -> SharedSuiteHandoffPayload {
        try await owner.run {
            try AppGroupHandoffManager.consumeIncomingHandoff(
                from: deepLinkURL,
                overrideBaseDirectory: overrideBaseDirectory
            )
        }
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
        try await owner.run {
            try AppGroupHandoffManager.createHandoffPackage(
                exportedImageURL: exportedImageURL,
                originalFileName: originalFileName,
                sourceApp: .truongScaler,
                targetApp: .truongNoiser,
                isDenoised: isDenoised,
                isUpscaled: isUpscaled,
                globalMaxLuminance: globalMaxLuminance,
                upscaleFactor: upscaleFactor,
                globalMaxLinearComponent: globalMaxLinearComponent,
                overrideBaseDirectory: overrideBaseDirectory
            )
        }
    }
}

/// Outgoing deep-link launch seam (UIApplication on iOS; test double captures launches).
protocol ExternalApplicationOpening: Sendable {
    func open(_ url: URL) async
}

struct SystemExternalApplicationOpener: ExternalApplicationOpening {
    func open(_ url: URL) async {
        #if canImport(UIKit) && os(iOS)
        await MainActor.run {
            UIApplication.shared.open(url)
        }
        #else
        _ = url
        #endif
    }
}

// MARK: - View model

/// Owns every asynchronous studio operation until it actually finishes or drains.
///
/// Lifetime contract (`docs/DEVELOPMENT.md` §3):
/// * ingest/execution/export/library-scan/reset each have an explicit owner and generation; a newer
///   operation invalidates publications and cleanup of older ones instead of racing them;
/// * every off-main operation holds its own security-scope grant; a replaced session/folder grant is
///   released only after all operations reading it have drained (reader count);
/// * Stop enters a distinct stopping state and keeps the execution owner until
///   `requestGracefulPauseAndWait()` + task cancellation have drained; new runs are refused until then;
/// * export/handoff snapshot artifact/session/destination/flags before awaiting and revalidate before
///   publishing or launching, so a previous export URL can never be mixed with a newer session.
///
/// The approved native UI is unchanged: only seams/lifecycle ownership were added.
@Observable
@MainActor
public final class StudioViewModel {
    public static let bookmarkDefaultsKey = "com.truongscaler.library.rootBookmark"

    // Shared Library Folder State (Matches TruongCam LibraryScreen)
    public var libraryFolderURL: URL?
    public var libraryLocationLabel: String = "No folder selected"
    public var libraryStatusLine: String = "Select your TruongCam library or a local folder"
    public var daySections: [LibraryDaySection] = []
    /// Non-nil while a previously saved folder bookmark could not be restored. The bookmark is
    /// retained; the UI offers reconnect and change-folder actions instead of silently clearing it.
    public private(set) var savedLibraryRecoveryMessage: String?
    /// True while an off-main bookmark/folder validation is in flight. Publishing remains on
    /// MainActor; the actual blocking read is owned by `LibraryFolderIO`/`BlockingIOOwner`.
    public private(set) var isValidatingLibraryFolder = false
    /// True while a saved bookmark exists in preferences (even if it currently cannot be opened).
    public var hasSavedLibraryBookmark: Bool {
        defaults.data(forKey: Self.bookmarkDefaultsKey) != nil
    }

    public static let outputBookmarkDefaultsKey = "com.truongscaler.library.outputBookmark"
    public var selectedCollection: LibraryCollection = .input
    public private(set) var outputFolderURL: URL?
    public private(set) var outputLocationLabel = "No output folder selected"
    public private(set) var outputStatusLine = "Choose where processed photos will be saved"
    public private(set) var outputDaySections: [LibraryDaySection] = []
    public private(set) var isValidatingOutputFolder = false
    public private(set) var savedOutputRecoveryMessage: String?
    public var isOutputSetupPresented = false
    public private(set) var displayedOutputRecord: ProcessedPhotoRecord?
    private var displayedLegacyOutput = false
    private var legacyOutputPaths: Set<URL> = []
    public private(set) var comparisonUnavailableReason: String?
    public private(set) var isSavingResult = false
    public private(set) var isManagingOutput = false
    public private(set) var recentlyDeleted: [OutputTrashEntry] = []
    public var visibleDaySections: [LibraryDaySection] { selectedCollection == .input ? daySections : outputDaySections }
    public var visibleFolderURL: URL? { selectedCollection == .input ? libraryFolderURL : outputFolderURL }
    public var hasSavedOutputBookmark: Bool { defaults.data(forKey: Self.outputBookmarkDefaultsKey) != nil }
    public var isShowingSavedOutput: Bool { displayedOutputRecord != nil || displayedLegacyOutput }
    public var isProcessedPhoto: Bool { isShowingSavedOutput || completedArtifacts != nil }
    public var viewerGrainAmount: Float { isShowingSavedOutput ? 0 : grainRetention }
    public var inspectionFilename: String {
        if let record = displayedOutputRecord ?? publishedCurrentResult { return (record.outputRelativePath as NSString).lastPathComponent }
        return sourceURL?.lastPathComponent ?? "Photo"
    }
    public var inspectionByteCount: Int64? { (displayedOutputRecord ?? publishedCurrentResult)?.outputByteCount }
    public var inspectionMetadata: ImageMetadataPacket? {
        completedArtifacts.map { FormatAwareExporter.processedMetadata(artifacts: $0) } ?? metadata
    }
    public var inspectionModelLabel: String? {
        if displayedLegacyOutput { return "Not recorded in this earlier export" }
        if let displayedOutputRecord { return displayedOutputRecord.modelLabel }
        if let model = completedArtifacts?.checkpoint.config.backbone {
            return model.isSupported ? model.displayName : model.rawValue
        }
        return nil
    }
    public var inspectionDimensionsText: String {
        if let record = displayedOutputRecord { return "\(record.outputWidth) × \(record.outputHeight)" }
        if let checkpoint = completedArtifacts?.checkpoint { return "\(checkpoint.outputWidth) × \(checkpoint.outputHeight)" }
        return metadata.map { "\($0.originalWidth) × \($0.originalHeight)" } ?? ""
    }

    // Current Active Photo & Pipeline Configuration
    public var currentStage: JobStage = .idle
    public private(set) var displayedInputURL: URL?
    public private(set) var viewerInputURL: URL?
    public var sourceURL: URL?
    public var metadata: ImageMetadataPacket?
    public var sourceBuffer: MMapBuffer?
    public var outputBuffer: MMapBuffer?
    public var completedArtifacts: CompletedPipelineArtifacts?

    /// New jobs are fixed at native 2×. Existing completed results retain their actual scale/model
    /// for inspection, export and handoff; the new product policy never relabels old 4× pixels.
    public var selectedScaleFactor: ScaleFactor { ScalerSRPolicy.scaleFactor }
    /// Choice for the next job; a displayed/resumed artifact always owns its recorded model.
    public var selectedModel: BackboneModelKind = ScalerSRPolicy.backbone
    public var scaleFactor: ScaleFactor {
        displayedOutputRecord.flatMap { ScaleFactor(rawValue: $0.scaleFactor) } ?? derivedScaleFactor ?? selectedScaleFactor
    }
    public var backbone: BackboneModelKind {
        displayedOutputRecord.map { BackboneModelKind(rawValue: $0.modelRawValue) } ?? completedArtifacts?.checkpoint.config.backbone ?? selectedModel
    }
    public var exportFormat: ExportFormat = .autoMatchSource
    /// Selector for the *next* job. The approved UI reads `grainRetention`, which resolves to the
    /// completed artifact's recorded grain amount while that result is displayed.
    public var selectedGrainRetention: Float = 0.15
    public var grainRetention: Float {
        get { derivedGrainAmount }
        set { selectedGrainRetention = newValue }
    }

    // Hardware & Tile Telemetry
    public var tileConfig: TileConfiguration
    public var completedTiles: Int = 0
    public var totalTiles: Int = 0
    /// Latest real pipeline update (phase, grid, timings) for the progress/details UI.
    public private(set) var latestProgress: PipelineProgressUpdate?
    /// Ticking elapsed clock while a job is owned. Advanced by a MainActor timer, not inferred from
    /// log lines or guessed from file size.
    public private(set) var processingElapsedSeconds: Double = 0
    /// Truthful user-facing progress. A busy uncommitted tile keeps the committed count and shows the
    /// current tile/phase; total 0 is "preparing", never a fake 1/1.
    private var batchStopRequested = false
    public private(set) var isBatchProcessing = false
    /// Remaining photos retain their queue while no foreground owner can start a new continuation.
    public private(set) var isBatchWaitingForForeground = false
    private var isBatchForegroundReady = true
    private var latestScenePhase: ScenePhase = .active
    private var batchForegroundWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    public private(set) var batchPhotoNumber: Int?
    public private(set) var batchPhotoCount: Int?
    public var jobProgress: JobProgressPresentation {
        var progress = JobProgressPresentation.make(update: latestProgress,
            elapsedSeconds: processingElapsedSeconds, isStopping: isStopping)
        if isSavingResult {
            progress.phase = .finalizing
            progress.title = "Saving photo…"
            progress.isSavingOutput = true
        }
        // The prior artifact stays inspectable, but its timings/model/dimensions do not describe
        // the queued photo. Publish a fresh waiting presentation without relabelling those facts.
        if isBatchWaitingForForeground {
            progress = JobProgressPresentation(isStopping: isStopping)
            progress.isWaitingForForeground = true
        }
        progress.batchPhotoNumber = batchPhotoNumber
        progress.batchPhotoCount = batchPhotoCount
        return progress
    }
    /// True while this view model owns an execution or is draining one (including stopping).
    public private(set) var isProcessing: Bool = false
    /// Distinct stopping state: Stop/reset requested, `requestGracefulPauseAndWait()`/cancellation has
    /// not reached the stable boundary yet. New runs are refused while this is true.
    public private(set) var isStopping: Bool = false
    public var exportedShareURLs: [URL] = []
    public private(set) var shareSession: PhotoShareSession?
    public private(set) var isPreparingShare = false
    private let sharePreparer: any StudioPhotoSharePreparing
    private var shareRequestGeneration: UInt64 = 0
    private var dismissedShareSessions: [PhotoShareSession] = []

    public func viewerDidDismiss() {
        shareRequestGeneration &+= 1
        shareDidDisappear(surface: .viewer)
    }
    public func shareBinding(for surface: PhotoShareSurface) -> PhotoShareSession? {
        shareSession?.surface == surface ? shareSession : nil
    }
    public func dismissShare(surface: PhotoShareSurface) {
        guard let session = shareSession, session.surface == surface else { return }
        dismissedShareSessions.append(session)
        shareSession = nil
        exportedShareURLs = []
    }
    public func shareDidDisappear(surface: PhotoShareSurface) {
        dismissShare(surface: surface)
        dismissedShareSessions.filter { $0.surface == surface }.forEach { $0.retireSnapshots() }
        dismissedShareSessions.removeAll { $0.surface == surface }
    }
    /// A delayed native callback owns only the session that was actually presented or refused.
    /// It cannot dismiss a newer share on the same surface or retire that share's snapshots.
    public func shareDidDisappear(surface: PhotoShareSurface, sessionID: UUID) {
        if let session = shareSession, session.surface == surface, session.id == sessionID {
            dismissShare(surface: surface)
        }
        dismissedShareSessions.filter { $0.surface == surface && $0.id == sessionID }
            .forEach { $0.retireSnapshots() }
        dismissedShareSessions.removeAll { $0.surface == surface && $0.id == sessionID }
    }
    private func prepareShare(_ urls: [URL], surface: PhotoShareSurface) async {
        guard !urls.isEmpty, !isPreparingShare, shareSession == nil, dismissedShareSessions.isEmpty,
              !isManagingOutput else { return }
        isPreparingShare = true
        let generation = sessionGeneration, output = outputGeneration, library = libraryGeneration, request = shareRequestGeneration
        var seenScopes = Set<ObjectIdentifier>()
        let scopes = [outputSession, librarySession, resultSelection, sourceSession].compactMap { $0 }
            .filter { seenScopes.insert(ObjectIdentifier($0)).inserted }
        scopes.forEach { $0.activeOperations += 1 }
        let grants = (urls + scopes.map(\.url)).map { scopeProvider.openGrant(for: $0) }
        defer {
            grants.forEach { $0.release() }
            scopes.forEach { $0.activeOperations -= 1; $0.releaseIfDrained() }
            isPreparingShare = false
        }
        let span = Diagnostics.shared.startSpan(category: .export, code: "share.prepare", fields: ["count": "\(urls.count)"])
        defer { span.end() }
        do {
            var hashes: [URL: String] = [:]
            if let selection = outputSession {
                for url in urls {
                    if let record = outputRecord(at: url, under: selection.url) { hashes[url] = record.outputSHA256 }
                }
            }
            if let record = publishedCurrentResult, let selection = resultSelection {
                hashes[selection.url.appendingPathComponent(record.outputRelativePath)] = record.outputSHA256
            }
            let prepared = try await sharePreparer.prepare(urls, surface: surface, expectedHashes: hashes)
            guard generation == sessionGeneration, output == outputGeneration, library == libraryGeneration, request == shareRequestGeneration else { return }
            exportedShareURLs = urls
            shareSession = prepared
        } catch {
            guard generation == sessionGeneration, output == outputGeneration, library == libraryGeneration,
                  request == shareRequestGeneration else { return }
            errorMessage = "The photo could not be prepared for sharing: " + error.localizedDescription
        }
    }
    public var errorMessage: String?
    /// Number of library operations currently reading the selected folder (scan/thumbnail/export).
    /// The previous folder's grant is released only when this reaches zero for that selection.
    public private(set) var libraryOperationCount: Int = 0

    // One Live Activity controller and one coordinator per executor-owned view model; the app
    // entry point registers background tasks against the same router.
    public let liveActivityController: LiveActivityController
    public let backgroundCoordinator: BackgroundExecutionCoordinator
    public let backgroundTaskRouter: BackgroundTaskDeliveryRouter

    /// One selected security scope and its independent reader count. The scope's grant is released
    /// only after `releaseRequested` and all readers have drained.
    private final class ScopeSession {
        let generation: UInt64
        let url: URL
        let lease: any SecurityScopeGrant
        /// Off-main validation result used by the library scan, so no MainActor `fileExists`
        /// (or other filesystem metadata read) is needed after the selection changes.
        let scanRoot: URL
        var activeOperations = 0
        var releaseRequested = false
        private var released = false

        init(generation: UInt64, url: URL, lease: any SecurityScopeGrant, scanRoot: URL? = nil) {
            self.generation = generation
            self.url = url
            self.lease = lease
            self.scanRoot = scanRoot ?? url
        }

        func markReleaseRequested() {
            releaseRequested = true
            releaseIfDrained()
        }

        func releaseIfDrained() {
            guard releaseRequested, activeOperations == 0, !released else { return }
            // Release is exactly-once per selection, independent of any generation-gated publication.
            released = true
            lease.release()
        }
    }

    /// One owned execution run. Exists from `startProcessing()` until the executor task has returned
    /// (success/failure/cancellation), independent of UI state.
    private final class ExecutionOwner {
        let generation: UInt64
        let session: ScopeSession?
        var task: Task<Void, Never>?
        var stopRequested = false
        var outputSelection: ScopeSession?
        var archivedOriginal: ArchivedOriginal?

        init(generation: UInt64, session: ScopeSession?) {
            self.generation = generation
            self.session = session
        }
    }

    private let resultStore: ProcessedLibraryStore
    private let requiresOutputFolder: Bool
    private var outputSession: ScopeSession?
    private var outputGeneration: UInt64 = 0
    private var outputRestoreStarted = false
    /// Portable libraries may merge two result paths with the same job UUID. File actions belong
    /// to the selected path; the record's opaque job identity is retained without deduplication.
    private var outputRecordsByURL: [URL: ProcessedPhotoRecord] = [:]
    private var outputRecordRoot: URL?
    private var selectedOutputItem: LibraryPhotoItem?
    private var publishedCurrentResult: ProcessedPhotoRecord?
    private var resultSelection: ScopeSession?
    private let workingDirectory: URL
    private let decoder: any StudioImageDecoding
    private let exporter: any StudioImageExporting
    private let scanner: any StudioLibraryScanning
    private let thumbnailReader: any StudioThumbnailReading
    private let pipeline: any StudioPipelineExecuting
    private let handoffManager: any StudioHandoffManaging
    private let externalOpener: any ExternalApplicationOpening
    private let scopeProvider: any SecurityScopeGrantProviding
    private let folderIO: any LibraryFolderIO

    /// Latest selected-folder scope. Replaced synchronously on selection change; the previous scope
    /// drains independently.
    private var librarySession: ScopeSession?
    /// Current ingested photo scope. Replaced by a newer ingest; the previous photo drains.
    private var sourceSession: ScopeSession?

    private var extractionTask: Task<Void, Never>?

    /// Identity guards so a late async result from an older operation cannot publish newer state.
    private var sessionGeneration: UInt64 = 0
    private var jobGeneration: UInt64 = 0
    /// Inactive/background callbacks share one cycle. Returning active supersedes any older
    /// suspended notice without discarding an inactive preparation when background follows it.
    private var foregroundSceneGeneration: UInt64 = 0
    private var libraryGeneration: UInt64 = 0
    private var completedArtifactsGeneration: UInt64?

    private var executionOwner: ExecutionOwner?
    private var progressTimerTask: Task<Void, Never>?
    private var jobStartedAt: Date?
    private var lastProgressDiagnosticAt: Date?
    private var lastCoordinatorProgressAt: Date?
    private var lastCoordinatorCompletedTiles: Int = -1
    private var activeJobID: UUID?
    private var terminalProgressGeneration: UInt64?
    private var stoppingTask: Task<Void, Never>?
    private var stoppingTaskID: UUID?
    private var drainTask: Task<Void, Never>?
    private var drainTaskID: UUID?
    private var resetTask: Task<Void, Never>?
    private var resetTaskGeneration: UInt64?

    /// Every in-flight ingest/export/library operation is retained until it really finishes.
    private var ingestTasks: [UUID: Task<Void, Never>] = [:]
    private var exportTasks: [UUID: Task<Void, Never>] = [:]
    private var scanTasks: [UUID: Task<Void, Never>] = [:]

    /// Accepted incoming-handoff consumption operations, retained until their consume/ingest chain
    /// drains. A newer handoff, a photo selection or reset supersedes them by ingress generation.
    private var handoffConsumeTasks: [UUID: Task<Void, Never>] = [:]
    /// Monotonic incoming-handoff ingress identity, reserved synchronously when a handoff is accepted.
    private var handoffIngressGeneration: UInt64 = 0

    /// Coordinator job generation that this view model started and still owns. Cleanup cancels only
    /// when it still matches, so old cleanup can never cancel a newer job.
    private var activeCoordinatorGeneration: UInt64?
    /// Set when the user presses Stop for the given execution generation.
    private var stopRequestedForJobGeneration: UInt64?

    private let displayPreviewReader = ImageIOThumbnailReader()
    private var inputContentRevision: UInt64 = 0
    private let defaults: UserDefaults
    private var didAttemptBookmarkRestore = false
    /// Monotonic identity of the current folder request. It is minted exactly once at the start of
    /// every restore/reconnect/picker/explicit selection/release and propagated through all internal
    /// helpers; helpers never mint a new identity for an older continuation.
    private var libraryRequestGeneration: UInt64 = 0

    // MARK: - Init

    /// Production initializer. Never substitutes the deterministic resampler for a missing model:
    /// the registry always uses `.requireProductionModels`.
    public convenience init(
        workingDirectory: URL? = nil,
        backgroundTaskRouter: BackgroundTaskDeliveryRouter = .shared,
        requiresOutputFolder: Bool = true,
        defaults: UserDefaults = .standard
    ) {
        let dir = workingDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("TruongScalerWorkspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let registry = CoreMLModelRegistry(availabilityPolicy: .requireProductionModels)
        let store = JobCheckpointStore(directory: dir)
        let executor = TiledPipelineExecutor(
            workingDirectory: dir,
            modelRegistry: registry,
            checkpointStore: store
        )
        self.init(
            workingDirectory: dir,
            pipelineExecutor: executor,
            pipeline: TiledExecutorPipelineAdapter(executor: executor),
            decoder: CachingStudioImageDecoder(),
            exporter: BlockingStudioImageExporter(),
            scanner: BlockingLibraryScanner(),
            thumbnailReader: ImageIOThumbnailReader(),
            handoffManager: AppGroupHandoffManagerSeam(overrideBaseDirectory: nil),
            externalOpener: SystemExternalApplicationOpener(),
            scopeProvider: SystemSecurityScopeGrantProvider(),
            backgroundTaskRouter: backgroundTaskRouter,
            defaults: defaults,
            requiresOutputFolder: requiresOutputFolder
        )
    }

    /// Testable designated initializer: production defaults are supplied by the public convenience
    /// init; tests inject deterministic seams without changing the app's model-availability policy.
    init(
        workingDirectory: URL,
        pipelineExecutor: TiledPipelineExecutor,
        pipeline: any StudioPipelineExecuting,
        decoder: any StudioImageDecoding,
        exporter: any StudioImageExporting,
        scanner: any StudioLibraryScanning,
        thumbnailReader: any StudioThumbnailReading = ImageIOThumbnailReader(),
        handoffManager: any StudioHandoffManaging,
        externalOpener: any ExternalApplicationOpening,
        scopeProvider: any SecurityScopeGrantProviding,
        backgroundTaskRouter: BackgroundTaskDeliveryRouter,
        defaults: UserDefaults = .standard,
        folderIO: any LibraryFolderIO = BlockingLibraryFolderIO(),
        requiresOutputFolder: Bool = false,
        sharePreparer: any StudioPhotoSharePreparing = PhotoSharePreparer(),
        resultStore: ProcessedLibraryStore = ProcessedLibraryStore(),
        backgroundScheduler: (any BackgroundTaskScheduling)? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.requiresOutputFolder = requiresOutputFolder
        self.defaults = defaults
        self.folderIO = folderIO
        self.tileConfig = HardwareTelemetry.makeTileConfiguration()
        self.backgroundTaskRouter = backgroundTaskRouter
        self.decoder = decoder
        self.exporter = exporter
        self.scanner = scanner
        self.thumbnailReader = thumbnailReader
        self.sharePreparer = sharePreparer
        self.resultStore = resultStore
        self.pipeline = pipeline
        self.handoffManager = handoffManager
        self.externalOpener = externalOpener
        self.scopeProvider = scopeProvider

        let activityMode: LiveActivityController.PresentationMode = {
            #if os(iOS)
            if #available(iOS 26, *) { return .systemContinuation }
            #endif
            return .customActivity
        }()
        let controller = LiveActivityController(presentationMode: activityMode)
        self.liveActivityController = controller
        let coordinator = BackgroundExecutionCoordinator(
            executor: pipelineExecutor,
            liveActivityController: controller,
            scheduler: backgroundScheduler,
            deliveryRouter: backgroundTaskRouter
        )
        self.backgroundCoordinator = coordinator
        coordinator.installDeliveryHandler(on: backgroundTaskRouter)
    }

    // MARK: - Background task registration

    /// Continued-processing launch handlers are registered on demand by
    /// `BackgroundExecutionCoordinator` for each concrete job identifier immediately before its
    /// first submission. Registering the literal wildcard here is rejected by the system even when
    /// `BGTaskSchedulerPermittedIdentifiers` advertises it (reproduced on iOS 27); the wildcard is
    /// only the Info.plist family declaration. Registration failures stay nonfatal and are surfaced
    /// through `errorMessage` when the scene leaves the foreground; foreground processing remains
    /// fully usable.

    // MARK: - Derived artifact state

    /// Actual scale of the completed artifact, derived from its output/source ratio.
    public var derivedScaleFactor: ScaleFactor? {
        guard let artifacts = completedArtifacts else { return nil }
        return ScaleFactor(rawValue: FormatAwareExporter.actualScaleFactor(artifacts: artifacts))
    }

    /// Grain amount recorded by the completed artifact; later slider changes cannot relabel output.
    public var derivedGrainAmount: Float {
        completedArtifacts?.checkpoint.config.naturalGrainAmount ?? selectedGrainRetention
    }

    /// Single source of truth for the actual artifact ratio (shared with the exporter and R7), so
    /// export filenames, handoff factor and embedded raster metadata can never disagree.
    private func artifactActualScaleFactor(_ artifacts: CompletedPipelineArtifacts) -> Int {
        FormatAwareExporter.actualScaleFactor(artifacts: artifacts)
    }

    public func releaseIdleImageCache() async {
        if let cache = decoder as? CachingStudioImageDecoder { await cache.purge() }
    }

    // MARK: - Library Folder Management (TruongCam Compatible)

    // MARK: - Output library selection and saved results

    public func restoreOutputBookmarkIfAvailable() {
        guard !outputRestoreStarted else { return }
        outputRestoreStarted = true
        outputGeneration &+= 1
        let request = outputGeneration
        guard let data = defaults.data(forKey: Self.outputBookmarkDefaultsKey) else {
            isOutputSetupPresented = requiresOutputFolder
            return
        }
        isValidatingOutputFolder = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let resolved = await self.folderIO.resolveBookmark(data)
            guard self.outputGeneration == request else { return }
            self.isValidatingOutputFolder = false
            switch resolved {
            case .success(let folder): await self.setOutputFolder(url: folder.url)
            case .failure:
                self.savedOutputRecoveryMessage = "The saved output folder is unavailable. Reconnect it to view saved results; your saved selection has not been removed."
                self.outputStatusLine = "Reconnect output folder"
                self.isOutputSetupPresented = self.requiresOutputFolder
            }
        }
    }

    public func reconnectOutputFolder() async {
        guard !Task.isCancelled else { return }
        guard let data = defaults.data(forKey: Self.outputBookmarkDefaultsKey) else {
            isOutputSetupPresented = true; return
        }
        let request = outputGeneration
        let resolved = await folderIO.resolveBookmark(data)
        guard !Task.isCancelled, request == outputGeneration else { return }
        if case .success(let folder) = resolved { await setOutputFolder(url: folder.url) }
        else { savedOutputRecoveryMessage = "The saved output folder could not be reconnected. Choose it again in Files." }
    }

    private static func inputIsInsideOutput(_ input: URL?, _ output: URL?) -> Bool {
        guard let input, let output else { return false }
        let i = input.standardizedFileURL.resolvingSymlinksInPath().path
        let o = output.standardizedFileURL.resolvingSymlinksInPath().path
        return i == o || i.hasPrefix(o + "/")
    }
    public func setOutputFolder(url: URL) async {
        guard !Task.isCancelled else { return }
        guard !isProcessing, !isBatchProcessing, exportTasks.isEmpty, !isManagingOutput, !isPreparingShare else {
            errorMessage = "Wait for the current photo to finish saving before changing the output folder."
            return
        }
        let validationGrant = scopeProvider.openGrant(for: url)
        defer { validationGrant.release() }
        guard !Self.inputIsInsideOutput(libraryFolderURL, url) else {
            errorMessage = "Choose a different output folder so originals and results stay separate."
            return
        }
        outputGeneration &+= 1
        let request = outputGeneration
        isValidatingOutputFolder = true
        // Provider/bookmark work may complete after its picker task was cancelled. Only the
        // current request may clear checking state, and cancelled requests never commit a root.
        defer { if request == outputGeneration { isValidatingOutputFolder = false } }
        do {
            try await resultStore.validateWritableFolder(url)
            guard !Task.isCancelled, request == outputGeneration else { return }
            guard let bookmark = await folderIO.createBookmark(for: url) else {
                throw ProcessedLibraryError.unreadableFolder
            }
            guard !Task.isCancelled, request == outputGeneration else { return }
            guard !isProcessing, !isBatchProcessing, !isManagingOutput, !Self.inputIsInsideOutput(libraryFolderURL, url) else {
                isValidatingOutputFolder = false
                errorMessage = "Choose a separate output folder after the current photo finishes."
                return
            }
            let session = ScopeSession(generation: request, url: url, lease: scopeProvider.openGrant(for: url))
            let previous = outputSession
            outputSession = session
            previous?.markReleaseRequested()
            if previous?.url.standardizedFileURL != url.standardizedFileURL {
                // This root owns a different gallery. Provider reads may take time or fail;
                // never leave the previous root's photos/actions under the new folder label.
                outputDaySections = []
                outputRecordsByURL = [:]
                outputRecordRoot = nil
                legacyOutputPaths = []
            }
            recentlyDeleted = []
            outputFolderURL = url
            outputLocationLabel = url.lastPathComponent
            outputStatusLine = "Output folder ready"
            savedOutputRecoveryMessage = nil
            errorMessage = nil
            defaults.set(bookmark, forKey: Self.outputBookmarkDefaultsKey)
            isOutputSetupPresented = false
            isValidatingOutputFolder = false
            await reloadOutputFolder()
            await reloadLibraryFolder()
        } catch {
            guard !Task.isCancelled, request == outputGeneration else { return }
            isValidatingOutputFolder = false
            savedOutputRecoveryMessage = error.localizedDescription
            if outputSession == nil { outputStatusLine = "Choose or reconnect an output folder" }
            errorMessage = error.localizedDescription
        }
    }

    public func reloadVisibleLibrary() async {
        if selectedCollection == .output { await reloadOutputFolder() }
        else { await reloadLibraryFolder() }
    }

    public func reloadOutputFolder() async {
        guard let selection = outputSession else { return }
        selection.activeOperations += 1
        let grant = scopeProvider.openGrant(for: selection.url)
        defer {
            grant.release(); selection.activeOperations -= 1; selection.releaseIfDrained()
        }
        do {
            let records = try await resultStore.records(under: selection.url)
            let legacy = try await resultStore.legacyPhotos(under: selection.url, excluding: records)
            guard outputSession === selection, !selection.releaseRequested else { return }
            outputRecordsByURL = Dictionary(records.map {
                (selection.url.appendingPathComponent($0.outputRelativePath).standardizedFileURL, $0)
            }, uniquingKeysWith: { first, _ in first })
            outputRecordRoot = selection.url
            legacyOutputPaths = Set(legacy.map { $0.fileURL.standardizedFileURL })
            let items = records.map { record in
                let file = selection.url.appendingPathComponent(record.outputRelativePath)
                return LibraryPhotoItem(id: file.path, fileURL: file, filename: file.lastPathComponent,
                    capturedAt: record.processedAt, byteCount: record.outputByteCount,
                    badgeLabel: "\(record.scaleFactor)× · \(record.modelLabel)", collection: .output)
            }
            outputDaySections = Self.groupLibraryItems((items + legacy).sorted {
                $0.capturedAt == $1.capturedAt ? $0.id < $1.id : $0.capturedAt > $1.capturedAt
            })
            let count = items.count + legacy.count
            outputStatusLine = count == 1 ? "1 processed photo" : "\(count) processed photos"
        } catch {
            guard outputSession === selection else { return }
            savedOutputRecoveryMessage = "The output folder could not be read. Reconnect it; its files and saved bookmark are unchanged."
        }
    }

    public func openLibraryPhoto(_ item: LibraryPhotoItem) async {
        guard !isManagingOutput else { return }
        await openOutputOrInputPhoto(item)
    }
    /// Returns the reserved selection generation even if superseded while decoding, so a caller's
    /// follow-up notice can be published only for the selection this operation actually opened.
    @discardableResult
    private func openOutputOrInputPhoto(_ item: LibraryPhotoItem) async -> UInt64? {
        guard item.collection == .output else { await ingestFile(at: item.fileURL); return nil }
        if let selection = outputSession, legacyOutputPaths.contains(item.fileURL.standardizedFileURL) {
            supersedeIncomingHandoffConsumptions()
            let generation = reserveIngestGeneration()
            selectedOutputItem = item
            prepareViewerForIngest(at: item.fileURL, inputPreviewURL: nil)
            selection.activeOperations += 1
            let grant = scopeProvider.openGrant(for: selection.url)
            defer { grant.release(); selection.activeOperations -= 1; selection.releaseIfDrained() }
            await enqueueIngest(at: item.fileURL, sessionGeneration: generation, handoff: nil,
                comparisonWarning: "This earlier export has no saved original or model record. Its before/after comparison is unavailable.",
                savedResultSelection: selection, legacyOutput: true)
            return generation
        }
        guard let selection = outputSession, let record = outputRecord(at: item.fileURL, under: selection.url)
        else { errorMessage = "Reconnect the output folder to open this result."; return nil }
        supersedeIncomingHandoffConsumptions()
        let generation = reserveIngestGeneration()
        selectedOutputItem = item
        // Record verification hashes both files before decoding. Publish the loading selection
        // before that first await, so a previous input/result cannot hide Output's loading UI.
        prepareViewerForIngest(at: item.fileURL, inputPreviewURL: nil)
        selection.activeOperations += 1
        let grant = scopeProvider.openGrant(for: selection.url)
        defer { grant.release(); selection.activeOperations -= 1; selection.releaseIfDrained() }
        do {
            let opened = try await resultStore.open(record, under: selection.url)
            guard isCurrentOutputOpening(generation: generation, selection: selection) else { return generation }
            await enqueueIngest(at: opened.outputURL, sessionGeneration: generation, handoff: nil,
                savedResult: record, comparisonOriginalURL: opened.originalURL,
                comparisonWarning: opened.comparisonUnavailableReason, savedResultSelection: selection)
        } catch {
            guard isCurrentOutputOpening(generation: generation, selection: selection) else { return generation }
            errorMessage = error.localizedDescription
            currentStage = .failed
        }
        return generation
    }

    /// Root validation may finish while record verification is still reading the previous folder.
    /// Retire that loading state, but never overwrite a newer photo's presentation or notice.
    private func isCurrentOutputOpening(generation: UInt64, selection: ScopeSession) -> Bool {
        guard generation == sessionGeneration else { return false }
        guard outputSession === selection else {
            errorMessage = "The output folder changed while this photo was opening. Open it again from its output folder."
            currentStage = .failed
            return false
        }
        return true
    }

    private func outputRecord(at url: URL, under root: URL) -> ProcessedPhotoRecord? {
        guard outputRecordRoot == root else { return nil }
        return outputRecordsByURL[url.standardizedFileURL]
    }

    /// An Output retry must repeat record/hash validation, never reinterpret the export as Input.
    public func retryOpeningCurrentPhoto() async {
        if let selectedOutputItem { await openLibraryPhoto(selectedOutputItem) }
        else if let sourceURL { await ingestFile(at: sourceURL) }
    }

    private func replaceResultContext(_ record: ProcessedPhotoRecord?, selection: ScopeSession?) {
        let previous = resultSelection
        selection?.activeOperations += 1
        resultSelection = selection
        publishedCurrentResult = record
        previous?.activeOperations -= 1
        previous?.releaseIfDrained()
    }

    private func publishResult(_ artifacts: CompletedPipelineArtifacts, owner: ExecutionOwner) async throws -> ProcessedPhotoRecord? {
        guard let selection = owner.outputSelection, let original = owner.archivedOriginal else { return nil }
        return try await exportResultRecord(artifacts, original: original, selection: selection) {
            self.isCurrentExecution(owner) && !Task.isCancelled
        }
    }

    private func exportResultRecord(_ artifacts: CompletedPipelineArtifacts, original: ArchivedOriginal,
        selection: ScopeSession, isCurrent: () -> Bool) async throws -> ProcessedPhotoRecord {
        let format = artifacts.metadata.resolvedExportFormat(from: artifacts.checkpoint.config.exportFormat)
        let ext: String
        switch format {
        case .linearDNG16Bit, .autoMatchSource: ext = "dng"
        case .tiff16BitLZW: ext = "tiff"
        case .heic10BitHDR: ext = "heic"
        case .png16Bit: ext = "png"
        case .jpeg95: ext = "jpg"
        }
        let stage = workingDirectory.appendingPathComponent("publish-\(UUID().uuidString).\(ext)")
        let preview = workingDirectory.appendingPathComponent("preview-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: stage); try? FileManager.default.removeItem(at: preview) }
        guard isCurrent() else { throw CancellationError() }
        let exported = try await exporter.exportDetailed(artifacts: artifacts, destinationURL: stage,
            overrideFormat: format, overrideGrainAmount: artifacts.checkpoint.config.naturalGrainAmount)
        guard isCurrent() else { throw CancellationError() }
        try await ProcessedPhotoPreview().write(artifacts: artifacts, to: preview)
        guard isCurrent() else { throw CancellationError() }
        let checkpoint = artifacts.checkpoint
        let draft = ProcessedPhotoDraft(id: checkpoint.jobID, modelRawValue: checkpoint.config.backbone.rawValue,
            sourceWidth: checkpoint.sourceWidth, sourceHeight: checkpoint.sourceHeight,
            outputWidth: checkpoint.outputWidth, outputHeight: checkpoint.outputHeight,
            scaleFactor: checkpoint.config.scaleFactor.rawValue, grainAmount: checkpoint.config.naturalGrainAmount,
            processedAt: Date(), formatRawValue: exported.format.rawValue)
        return try await resultStore.publish(exportedURL: exported.url, original: original, draft: draft, under: selection.url, previewURL: preview)
    }

    /// Restores the saved library selection exactly once at launch.
    ///
    /// A failed, stale or temporarily unavailable grant never traps and never deletes the human's
    /// saved selection or preferences. It publishes an actionable reconnect state with a usable
    /// (empty but interactive) library UI; `reconnectSavedLibraryFolder()` retries the same saved
    /// bookmark and `releaseLibraryFolder()` is the only path that clears it (explicit user action).
    public func restoreLibraryBookmarkIfAvailable() {
        guard !didAttemptBookmarkRestore else { return }
        didAttemptBookmarkRestore = true

        // Capture launch-restore ownership when scheduling. The queued task may not adopt a newer
        // user action's identity, and App.init does not wait for any provider/bookmark I/O.
        let request = beginLibraryRequest()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let data = self.defaults.data(forKey: Self.bookmarkDefaultsKey) else { return }
            guard !Task.isCancelled,
                  self.isCurrentLibraryRequest(request),
                  self.librarySession == nil else { return }

            self.beginLibraryChecking(request, status: "Checking saved library folder…")

            let result = await self.folderIO.resolveBookmark(data)
            guard !Task.isCancelled else {
                self.finishLibraryChecking(request)
                return
            }
            guard self.isCurrentLibraryRequest(request), self.librarySession == nil else { return }

            switch result {
            case .success(let resolved):
                // Same immutable request identity: this is not a new user action.
                await self.applyLibraryFolder(
                    url: resolved.url,
                    saveBookmark: resolved.isStale,
                    request: request
                )
            case .failure(let error):
                self.finishLibraryChecking(request)
                guard self.isCurrentLibraryRequest(request) else { return }
                self.markSavedLibraryUnavailable(url: nil, reason: error.message)
            }
        }
    }

    /// Retries the saved bookmark after the recovery banner/UI asked the user to reconnect.
    public func reconnectSavedLibraryFolder() async {
        let request = beginLibraryRequest()

        guard let data = defaults.data(forKey: Self.bookmarkDefaultsKey) else {
            finishLibraryChecking(request)
            guard isCurrentLibraryRequest(request) else { return }
            savedLibraryRecoveryMessage = nil
            libraryStatusLine = "No saved folder to reconnect. Choose a folder."
            return
        }

        beginLibraryChecking(request, status: "Checking saved library folder…")
        let result = await folderIO.resolveBookmark(data)

        guard !Task.isCancelled else {
            finishLibraryChecking(request)
            return
        }
        guard isCurrentLibraryRequest(request) else { return }

        switch result {
        case .success(let resolved):
            await applyLibraryFolder(url: resolved.url, saveBookmark: true, request: request)
        case .failure(let error):
            finishLibraryChecking(request)
            guard isCurrentLibraryRequest(request) else { return }
            if librarySession == nil {
                markSavedLibraryUnavailable(url: nil, reason: error.message)
            } else {
                errorMessage = "The saved folder could not be reconnected. Your current folder is still selected."
                    + " (\(error.message))"
                Diagnostics.shared.record(
                    category: .app,
                    level: .warning,
                    code: "library.reconnect.failed",
                    message: "saved folder reconnect failed; current folder retained",
                    fields: ["operation": "reconnect"]
                )
            }
        }
    }

    private func beginLibraryRequest() -> UInt64 {
        libraryRequestGeneration &+= 1
        return libraryRequestGeneration
    }

    private func isCurrentLibraryRequest(_ request: UInt64) -> Bool {
        request == libraryRequestGeneration
    }

    private func beginLibraryChecking(_ request: UInt64, status: String) {
        guard isCurrentLibraryRequest(request) else { return }
        isValidatingLibraryFolder = true
        libraryStatusLine = status
    }

    /// Clears the checking state only when this request still owns the UI. A stale/cancelled
    /// request must leave a newer request's checking/recovery/selection state untouched.
    private func finishLibraryChecking(_ request: UInt64) {
        guard isCurrentLibraryRequest(request) else { return }
        isValidatingLibraryFolder = false
        if libraryFolderURL != nil {
            libraryStatusLine = "Library ready"
        } else if savedLibraryRecoveryMessage != nil {
            libraryStatusLine = "Saved folder unavailable — reconnect or choose a different folder"
        } else {
            libraryStatusLine = "Select your TruongCam library or a local folder"
        }
    }

    private func markSavedLibraryUnavailable(url: URL?, reason: String) {
        isValidatingLibraryFolder = false
        libraryFolderURL = nil
        libraryLocationLabel = url.map { "\($0.deletingLastPathComponent().lastPathComponent) · \($0.lastPathComponent)" }
            ?? "Saved library folder"
        libraryStatusLine = "Saved folder unavailable — reconnect or choose a different folder"
        savedLibraryRecoveryMessage = "The saved library folder could not be opened. Your saved selection has not "
            + "been deleted. Reconnect it, choose a different folder, or stop using it. (\(reason))"
        daySections = []
        Diagnostics.shared.record(
            category: .app,
            level: .warning,
            code: "library.saved_folder.unavailable",
            message: "saved folder unavailable",
            fields: ["operation": "folder_validation"]
        )
    }

    /// Handles a Files-picker result without touching the URL before its security scope is open.
    ///
    /// Returns `true` when the picked URL was a single file handed to the normal ingestion path
    /// (so the caller can present the viewer), and `false` for a folder/refused/superseded result.
    public func handlePickedURL(_ url: URL) async -> Bool {
        let request = beginLibraryRequest()
        beginLibraryChecking(request, status: "Checking folder…")

        // Classification owns its own grant; the earlier FileManager.fileExists in the view was
        // removed because it could run before the picker URL's security scope was active.
        let classificationGrant = scopeProvider.openGrant(for: url)
        let category = await folderIO.classifyImportedURL(at: url)
        classificationGrant.release()

        guard !Task.isCancelled else {
            finishLibraryChecking(request)
            return false
        }
        guard isCurrentLibraryRequest(request) else { return false }

        switch category {
        case .directory(let scanRoot):
            await applyValidatedLibraryFolder(
                url: url,
                saveBookmark: true,
                scanRoot: scanRoot,
                request: request
            )
            return false
        case .file:
            finishLibraryChecking(request)
            await ingestFile(at: url)
            // A newer folder request owns the UI; do not present the older file's viewer over it.
            return isCurrentLibraryRequest(request)
        case .unavailable(let reason):
            finishLibraryChecking(request)
            guard isCurrentLibraryRequest(request) else { return false }
            errorMessage = "That item is unavailable or access was not granted. Choose it again in Files."
            Diagnostics.shared.record(
                category: .app,
                level: .warning,
                code: "library.pick.unavailable",
                message: "picked item unavailable or access not granted",
                fields: ["operation": "folder_validation"]
            )
            if librarySession == nil {
                markSavedLibraryUnavailable(url: url, reason: reason)
            }
            return false
        }
    }

    /// Explicit user selection. Reconnect/restore/picker use the same internal helper with their
    /// already-captured request identity rather than minting a new one.
    public func setLibraryFolder(url: URL, saveBookmark: Bool = true) async {
        guard !Task.isCancelled else { return }
        let request = beginLibraryRequest()
        await applyLibraryFolder(url: url, saveBookmark: saveBookmark, request: request)
    }

    private func applyLibraryFolder(
        url: URL,
        saveBookmark: Bool,
        request: UInt64
    ) async {
        guard isCurrentLibraryRequest(request) else { return }
        guard !Task.isCancelled else {
            finishLibraryChecking(request)
            return
        }
        let boundaryGrant = outputFolderURL.map { _ in scopeProvider.openGrant(for: url) }
        defer { boundaryGrant?.release() }
        guard !isManagingOutput, !isBatchProcessing, !isPreparingShare, !Self.inputIsInsideOutput(url, outputFolderURL) else {
            finishLibraryChecking(request)
            errorMessage = "Choose an input folder outside the output folder. Input photos are managed separately."
            return
        }
        beginLibraryChecking(request, status: "Checking folder…")

        // Validation owns an independent grant opened BEFORE the first filesystem metadata/listing
        // access and released exactly once when the off-main validation drains. The result includes
        // the scan root, so no MainActor FileManager probe is needed after this await.
        let validation = await validateFolderWithOwnedGrant(url)

        guard !Task.isCancelled else {
            finishLibraryChecking(request)
            return
        }
        guard isCurrentLibraryRequest(request) else { return }

        switch validation {
        case .unavailable(let reason):
            finishLibraryChecking(request)
            guard isCurrentLibraryRequest(request) else { return }
            errorMessage = "That folder is unavailable or access was not granted. Choose it again in Files."
            Diagnostics.shared.record(
                category: .app,
                level: .warning,
                code: "library.folder.unavailable",
                message: "folder unavailable or access not granted",
                fields: ["operation": "folder_validation"]
            )
            if librarySession == nil {
                markSavedLibraryUnavailable(url: url, reason: reason)
            }
            return
        case .available(let scanRoot):
            await applyValidatedLibraryFolder(
                url: url,
                saveBookmark: saveBookmark,
                scanRoot: scanRoot,
                request: request
            )
        }
    }

    /// Publishes an already-validated selection, saves its bookmark off-main, and starts the scan.
    /// The same request identity gates every await and publication; no helper mints a new one.
    private func applyValidatedLibraryFolder(
        url: URL,
        saveBookmark: Bool,
        scanRoot: URL,
        request: UInt64
    ) async {
        if Task.isCancelled {
            finishLibraryChecking(request)
            return
        }
        guard isCurrentLibraryRequest(request) else { return }
        let boundaryGrant = outputFolderURL.map { _ in scopeProvider.openGrant(for: url) }
        defer { boundaryGrant?.release() }
        guard !isManagingOutput, !isBatchProcessing, !isPreparingShare, !Self.inputIsInsideOutput(url, outputFolderURL) else {
            errorMessage = "Choose a different input folder so originals and results stay separate."
            finishLibraryChecking(request)
            return
        }

        libraryGeneration &+= 1
        let generation = libraryGeneration

        // Each selection owns one independent session grant; only scope activation happens on
        // MainActor. The previous selection's grant is released only after its readers drain.
        let newSession = ScopeSession(
            generation: generation,
            url: url,
            lease: scopeProvider.openGrant(for: url),
            scanRoot: scanRoot
        )
        guard isCurrentLibraryRequest(request) else {
            newSession.markReleaseRequested()
            return
        }
        let previous = librarySession
        librarySession = newSession
        previous?.markReleaseRequested()
        if previous?.url.standardizedFileURL != url.standardizedFileURL {
            // Bookmark creation and scanning suspend below. Old-root thumbnails must not stay
            // selectable while the current root already names a different input folder.
            daySections = []
        }

        isValidatingLibraryFolder = false
        savedLibraryRecoveryMessage = nil
        libraryFolderURL = url
        libraryLocationLabel = "\(url.deletingLastPathComponent().lastPathComponent) · \(url.lastPathComponent)"
        libraryStatusLine = "Library ready"

        // Bookmark creation is off-main and opens/balances its own scope. A stale operation may not
        // overwrite a newer request's bookmark or session.
        if saveBookmark, let data = await folderIO.createBookmark(for: url) {
            guard !Task.isCancelled,
                  isCurrentLibraryRequest(request),
                  librarySession === newSession else { return }
            defaults.set(data, forKey: Self.bookmarkDefaultsKey)
        }

        guard !Task.isCancelled,
              isCurrentLibraryRequest(request),
              librarySession === newSession else { return }
        await reloadLibraryFolder(request: request)
    }

    /// Opens the validation-owned grant, performs the off-main bounded validation, and releases the
    /// grant exactly once even if the awaiting task is cancelled or a newer request supersedes it.
    private func validateFolderWithOwnedGrant(_ url: URL) async -> LibraryFolderValidation {
        let grant = scopeProvider.openGrant(for: url)
        defer { grant.release() }
        return await folderIO.validateFolder(at: url)
    }

    /// Explicit user action ("Stop using this folder" after destructive confirmation). This is the
    /// only path that removes the saved bookmark; a failed restore/relaunch never calls it.
    public func releaseLibraryFolder() {
        _ = beginLibraryRequest()
        libraryGeneration &+= 1
        let previous = librarySession
        librarySession = nil
        previous?.markReleaseRequested()

        isValidatingLibraryFolder = false
        defaults.removeObject(forKey: Self.bookmarkDefaultsKey)
        savedLibraryRecoveryMessage = nil
        libraryFolderURL = nil
        libraryLocationLabel = "No folder selected"
        libraryStatusLine = "Select your TruongCam library or a local folder"
        daySections = []
    }
    public func reloadLibraryFolder() async {
        // A manual refresh is tied to the request current when it begins; it never mints a new
        // folder-selection request identity.
        let request = libraryRequestGeneration
        await reloadLibraryFolder(request: request)
    }

    private func reloadLibraryFolder(request: UInt64) async {
        guard isCurrentLibraryRequest(request), let selection = librarySession else { return }
        libraryGeneration &+= 1
        let generation = libraryGeneration

        let scanRoot = selection.scanRoot
        let operationID = UUID()

        // Each scan is an independently owned library operation with its own scope grant.
        libraryOperationCount += 1
        selection.activeOperations += 1
        let operationGrant = scopeProvider.openGrant(for: selection.url)
        let scan = Task { @MainActor [weak self] in
            guard let self else { return }
            let discovered = await self.scanner.scanLibraryItems(at: scanRoot)
            operationGrant.release()
            selection.activeOperations -= 1
            selection.releaseIfDrained()
            self.libraryOperationCount = max(0, self.libraryOperationCount - 1)
            self.scanTasks.removeValue(forKey: operationID)

            // Revalidate before ANY publication: a stale request/scan may not replace a newer
            // selection or a newer request's state.
            guard self.isCurrentLibraryRequest(request),
                  generation == self.libraryGeneration,
                  self.librarySession === selection else { return }
            self.publishLibraryItems(discovered)
        }
        scanTasks[operationID] = scan
        await scan.value
    }

    private func publishLibraryItems(_ discovered: [LibraryPhotoItem]) {
        let outputPrefix = outputFolderURL.map { $0.standardizedFileURL.path + "/" }
        let inputPrefix = libraryFolderURL.map { $0.standardizedFileURL.path + "/" }
        let filtered = discovered.filter { item in
            guard let outputPrefix, let inputPrefix, outputPrefix.hasPrefix(inputPrefix) else { return true }
            return !item.fileURL.standardizedFileURL.path.hasPrefix(outputPrefix)
        }
        let grouped = Self.groupLibraryItems(filtered)
        if daySections != grouped { inputContentRevision &+= 1 }
        self.daySections = grouped
    }

    static func groupLibraryItems(_ discovered: [LibraryPhotoItem]) -> [LibraryDaySection] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        var grouped: [Date: [LibraryPhotoItem]] = [:]
        for item in discovered {
            let dayStart = calendar.startOfDay(for: item.capturedAt)
            grouped[dayStart, default: []].append(item)
        }
        let identifiers = ISO8601DateFormatter()
        return grouped.keys.sorted(by: >).map { dayStart in
            let title: String
            if calendar.isDateInToday(dayStart) {
                title = "Today"
            } else if calendar.isDateInYesterday(dayStart) {
                title = "Yesterday"
            } else {
                title = formatter.string(from: dayStart)
            }
            return LibraryDaySection(id: identifiers.string(from: dayStart), displayTitle: title, items: grouped[dayStart] ?? [])
        }
    }

    /// Loads one library thumbnail as an owned library operation.
    ///
    /// The current selected folder's `ScopeSession` is captured synchronously, an independent root
    /// grant + reader count are held through the ImageIO read, and the grant is released exactly once
    /// after the read drains. The image is returned only while that same selection is still current
    /// (the session owns the library generation, so a replaced/released folder fails this check), so
    /// a stale read can never publish into a reused cell.
    func loadLibraryThumbnail(
        for item: LibraryPhotoItem,
        maxPixelSize: Int = 256
    ) async -> CGImage? {
        guard let selection = item.collection == .input ? librarySession : outputSession else { return nil }

        libraryOperationCount += 1
        selection.activeOperations += 1
        let operationGrant = scopeProvider.openGrant(for: selection.url)

        var image: CGImage?
        if item.collection == .output, let record = outputRecord(at: item.fileURL, under: selection.url),
           let preview = try? await resultStore.thumbnailURL(record, under: selection.url) {
            image = await thumbnailReader.readThumbnail(at: preview, maxPixelSize: maxPixelSize)
        }
        if image == nil { image = await thumbnailReader.readThumbnail(at: item.fileURL, maxPixelSize: maxPixelSize) }

        // Release the independently owned grant before any publication decision.
        operationGrant.release()
        selection.activeOperations -= 1
        selection.releaseIfDrained()
        libraryOperationCount = max(0, libraryOperationCount - 1)

        // `releaseRequested` is set synchronously when the folder is replaced or released, while the
        // session/generation identity distinguishes a re-selected folder from the same selection.
        guard !Task.isCancelled,
              !selection.releaseRequested,
              (item.collection == .input ? librarySession : outputSession) === selection else { return nil }
        return image
    }

    nonisolated static func scanLibraryItemsSynchronously(at scanRoot: URL) -> [LibraryPhotoItem] {
        let supportedExtensions: Set<String> = [
            "dng", "cr2", "cr3", "arw", "nef", "raf", "orf", "rw2", "tif", "tiff", "heic", "heif", "png", "jpg", "jpeg"
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: scanRoot,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let isCamLibrary = FileManager.default.fileExists(atPath: scanRoot.appendingPathComponent("metadata/library.json").path)
        var discovered: [LibraryPhotoItem] = []
        for case let fileURL as URL in enumerator {
            if isCamLibrary, ["metadata", "sequences"].contains(fileURL.lastPathComponent),
               (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                enumerator.skipDescendants()
                continue
            }
            let ext = fileURL.pathExtension.lowercased()
            let type = UTType(filenameExtension: ext)
            guard supportedExtensions.contains(ext) || type?.conforms(to: .rawImage) == true || type?.conforms(to: .image) == true else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let date = values?.creationDate ?? values?.contentModificationDate ?? Date()
            let size = Int64(values?.fileSize ?? 0)
            let name = fileURL.lastPathComponent
            let badge: String? = name.contains("_4x") ? "4× DNG" : (name.contains("_2x") ? "2× DNG" : nil)

            discovered.append(
                LibraryPhotoItem(
                    id: fileURL.path,
                    fileURL: fileURL,
                    filename: name,
                    capturedAt: date,
                    byteCount: size,
                    badgeLabel: badge
                )
            )
        }
        discovered.sort { $0.capturedAt == $1.capturedAt ? $0.id < $1.id : $0.capturedAt > $1.capturedAt }
        return discovered
    }

    // MARK: - Single Photo Ingestion & Viewer Navigation

    public var orderedLibraryItems: [LibraryPhotoItem] {
        visibleDaySections.flatMap(\.items)
    }

    public var currentPhotoIndex: Int? {
        guard let sourceURL else { return nil }
        return orderedLibraryItems.firstIndex { $0.fileURL.standardizedFileURL == sourceURL.standardizedFileURL }
    }

    public func canStepPhoto(_ delta: Int) -> Bool {
        guard !isProcessing, !isStopping, !isBatchProcessing, let idx = currentPhotoIndex else { return false }
        return orderedLibraryItems.indices.contains(idx + delta)
    }

    var inputPreviewMatchesSelection: Bool { viewerInputURL == nil || displayedInputURL == viewerInputURL }
    func inputPreviewDidDisplay(_ url: URL?) {
        if let url, url == viewerInputURL { displayedInputURL = url }
    }
    public func stepPhoto(_ delta: Int) {
        guard canStepPhoto(delta), let idx = currentPhotoIndex else { return }
        let target = orderedLibraryItems[idx + delta]
        Task { @MainActor [weak self] in
            await self?.openLibraryPhoto(target)
        }
    }

    /// Ingests a photo off MainActor. Owns its decode until it finishes; a newer selection/reset
    /// invalidates this operation before it can publish anything. A user selection also supersedes an
    /// in-flight incoming-handoff consumption, which is why the ingress identity is bumped here.
    public func ingestFile(at url: URL) async {
        supersedeIncomingHandoffConsumptions()
        let generation = reserveIngestGeneration()
        await enqueueIngest(at: url, sessionGeneration: generation, handoff: nil)
    }

    /// Reserves the session/ingest identity synchronously, before any await, so the operation that
    /// owns this generation can be superseded deterministically by a newer selection/reset/handoff.
    @discardableResult
    private func reserveIngestGeneration() -> UInt64 {
        sessionGeneration &+= 1
        jobGeneration &+= 1
        stopRequestedForJobGeneration = nil
        wakeBatchForegroundWaiters()
        return sessionGeneration
    }

    /// Runs one owned ingest operation. `handoff` is passed explicitly (not through shared mutable
    /// state) so a payload accepted for this reserved generation cannot leak into a newer ingest.
    private func enqueueIngest(
        at url: URL,
        sessionGeneration generation: UInt64,
        handoff: SharedSuiteHandoffPayload?,
        savedResult: ProcessedPhotoRecord? = nil,
        comparisonOriginalURL: URL? = nil,
        comparisonWarning: String? = nil,
        savedResultSelection: ScopeSession? = nil,
        legacyOutput: Bool = false
    ) async {
        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performIngest(
                at: url,
                sessionGeneration: generation,
                handoff: handoff,
                savedResult: savedResult,
                comparisonOriginalURL: comparisonOriginalURL,
                comparisonWarning: comparisonWarning,
                savedResultSelection: savedResultSelection,
                legacyOutput: legacyOutput
            )
            self.ingestTasks.removeValue(forKey: operationID)
        }
        ingestTasks[operationID] = task
        await task.value
    }

    /// Only publishes presentation state. Scope leases and owned execution/mmap teardown still
    /// drain in performIngest; a renderer retaining an old buffer keeps its own read lifetime.
    private func prepareViewerForIngest(at url: URL, inputPreviewURL: URL?) {
        viewerInputURL = inputPreviewURL
        if inputPreviewURL != nil { selectedOutputItem = nil }
        sourceURL = url
        isSavingResult = false
        metadata = nil
        sourceBuffer = nil
        outputBuffer = nil
        completedArtifacts = nil
        displayedOutputRecord = nil
        displayedLegacyOutput = false
        replaceResultContext(nil, selection: nil)
        comparisonUnavailableReason = nil
        completedArtifactsGeneration = nil
        errorMessage = nil
        currentStage = .ingestingAndDecodingStrips
        completedTiles = 0
        totalTiles = 0
        latestProgress = nil
        activeJobID = nil
        terminalProgressGeneration = nil
    }

    private func performIngest(
        at url: URL,
        sessionGeneration generation: UInt64,
        handoff: SharedSuiteHandoffPayload?,
        savedResult: ProcessedPhotoRecord? = nil,
        comparisonOriginalURL: URL? = nil,
        comparisonWarning: String? = nil,
        savedResultSelection: ScopeSession? = nil,
        legacyOutput: Bool = false
    ) async {
        // The reservation may have been superseded before this MainActor task actually ran. A stale
        // ingest must not publish selection state or open a scope lease at all.
        guard generation == sessionGeneration else { return }

        extractionTask?.cancel()
        extractionTask = nil

        // Publish the new selection synchronously (no await yet): the previous photo's grant is
        // released only when its own readers drain.
        let selection = ScopeSession(
            generation: generation,
            url: url,
            lease: scopeProvider.openGrant(for: url)
        )
        let previous = sourceSession
        sourceSession = selection
        previous?.markReleaseRequested()

        prepareViewerForIngest(at: url, inputPreviewURL: savedResult == nil && !legacyOutput ? url : nil)

        // Wait for any owned execution to reach its stable boundary before replacing mapped paths.
        await drainExecutionForSessionChange()

        // Revalidate BEFORE mutating any current UI/ownership flags: a stale operation must mutate
        // nothing. Only the current ingest may clear the stopping/processing state it superseded.
        guard generation == sessionGeneration else {
            selection.markReleaseRequested()
            return
        }

        // The replaced execution's teardown intentionally deferred the idle/stopping flags to the
        // operation that superseded it; this ingest now owns the UI state.
        isProcessing = false
        isStopping = false

        selection.activeOperations += 1
        let operationGrant = scopeProvider.openGrant(for: url)
        let destination = workingDirectory.appendingPathComponent(
            "preview_\(UUID().uuidString).rgba16f.bin"
        )
        let ingestID = UUID().uuidString
        Diagnostics.shared.record(
            category: .pipeline,
            level: .notice,
            code: "app.ingest.start",
            message: "ingest started",
            fields: [
                "ingestID": ingestID,
                "sourceType": url.pathExtension.lowercased(),
                "handoff": handoff == nil ? "false" : "true"
            ]
        )
        let decodeSpan = Diagnostics.shared.startSpan(
            category: .pipeline,
            code: "pipeline.decode",
            fields: [
                "ingestID": ingestID,
                "sourceType": url.pathExtension.lowercased()
            ]
        )

        do {
            // Full-resolution decode is blocking ImageIO/CoreImage work: never on MainActor.
            let decoded = try await decoder.decodeImage(at: url, destinationMMapURL: destination,
                validatedContentSHA256: savedResult?.outputSHA256)
            var before: DecodedSourceResult?
            var unavailable = comparisonWarning
            if let savedResult {
                guard decoded.sourceBuffer.width == savedResult.outputWidth,
                      decoded.sourceBuffer.height == savedResult.outputHeight else { throw ProcessedLibraryError.invalidRecord }
                if let comparisonOriginalURL {
                    let beforeDestination = workingDirectory.appendingPathComponent("before-\(UUID().uuidString).rgba16f.bin")
                    do {
                        let candidate = try await decoder.decodeImage(at: comparisonOriginalURL, destinationMMapURL: beforeDestination,
                            validatedContentSHA256: savedResult.original.sha256)
                        guard candidate.sourceBuffer.width == savedResult.sourceWidth,
                              candidate.sourceBuffer.height == savedResult.sourceHeight else { throw ProcessedLibraryError.invalidRecord }
                        before = candidate
                    } catch { unavailable = "The saved original could not be opened. The processed photo is still available." }
                }
            }
            operationGrant.release()
            selection.activeOperations -= 1
            selection.releaseIfDrained()

            // Revalidate after every await before replacing metadata/buffers/lease state.
            guard generation == sessionGeneration else {
                try? FileManager.default.removeItem(at: destination)
                return
            }

            var decodedMetadata = decoded.metadata
            if let handoff {
                decodedMetadata = Self.applyHandoff(handoff, to: decodedMetadata)
                self.libraryStatusLine = "Handoff applied · \(url.lastPathComponent)"
            }

            guard generation == sessionGeneration else {
                try? FileManager.default.removeItem(at: destination)
                return
            }

            decodeSpan.end(additionalFields: [
                "decodedWidth": "\(decoded.sourceBuffer.width)",
                "decodedHeight": "\(decoded.sourceBuffer.height)",
                "category": decodedMetadata.category.rawValue
            ])
            self.metadata = decodedMetadata
            self.sourceBuffer = before?.sourceBuffer ?? decoded.sourceBuffer
            self.outputBuffer = before == nil ? nil : decoded.sourceBuffer
            self.displayedOutputRecord = savedResult
            self.displayedLegacyOutput = legacyOutput
            self.replaceResultContext(savedResult, selection: savedResultSelection)
            self.comparisonUnavailableReason = unavailable
            self.currentStage = savedResult == nil && !legacyOutput ? .idle : .readyForInspection
        } catch {
            operationGrant.release()
            selection.activeOperations -= 1
            selection.releaseIfDrained()
            decodeSpan.end(level: error is CancellationError ? .debug : .warning, additionalFields: [
                "ingestID": ingestID
            ])
            guard generation == sessionGeneration else { return }
            if error is CancellationError {
                // This is still the current ingest (the generation guard above excludes a newer
                // selection). Do not leave it permanently "opening" with no buffers or navigation.
                if sourceSession === selection {
                    sourceSession = nil
                    selection.markReleaseRequested()
                }
                self.currentStage = .idle
                self.errorMessage = "Opening the photo was cancelled. You can open it again from the library."
                try? FileManager.default.removeItem(at: destination)
                return
            }
            Diagnostics.shared.recordError(
                error,
                category: .pipeline,
                code: "app.ingest.failed",
                context: ["ingestID": ingestID, "sourceType": url.pathExtension.lowercased()]
            )
            if sourceSession === selection {
                sourceSession = nil
                selection.markReleaseRequested()
            }
            self.errorMessage = error.localizedDescription
            self.currentStage = .failed
        }
    }

    /// Applies a validated companion-app handoff payload to the freshly ingested metadata.
    private nonisolated static func applyHandoff(
        _ payload: SharedSuiteHandoffPayload,
        to packet: ImageMetadataPacket
    ) -> ImageMetadataPacket {
        packet.applyingSuiteHandoff(
            isDenoised: payload.isDenoised,
            isUpscaled: payload.isUpscaled,
            upscaleFactor: payload.upscaleFactor,
            linearHeadroomScale: payload.globalMaxLinearComponent,
            denoisedByNoiser: payload.sourceApp == .truongNoiser ? payload.isDenoised : nil
        )
    }

    // MARK: - Upscale Execution & Batch Processing

    /// Starts one serialized execution run. Refused while an execution is owned, stopping, draining
    /// or resetting, so two `executeOrResumeJob` calls can never overlap.
    public func startProcessing() { startProcessing(ownedByBatch: false) }
    private func startProcessing(ownedByBatch: Bool) {
        guard !isBatchProcessing || ownedByBatch else { return }
        guard !isValidatingOutputFolder else {
            errorMessage = "Wait for the output folder check to finish."
            return
        }
        if requiresOutputFolder, outputSession == nil {
            errorMessage = "Choose an output folder before upscaling."
            isOutputSetupPresented = true
            return
        }
        guard !isShowingSavedOutput else { return }
        guard let sourceURL,
              metadata != nil,
              !isProcessing,
              !isStopping,
              executionOwner == nil,
              stoppingTask == nil,
              drainTask == nil,
              resetTask == nil,
              let session = sourceSession,
              session.generation == sessionGeneration else { return }

        isProcessing = true
        isStopping = false
        completedTiles = 0
        totalTiles = 0
        latestProgress = nil
        processingElapsedSeconds = 0
        jobStartedAt = Date()
        lastProgressDiagnosticAt = nil
        lastCoordinatorProgressAt = nil
        lastCoordinatorCompletedTiles = -1
        startProgressTimer()
        errorMessage = nil
        currentStage = .ingestingAndDecodingStrips
        // A new job supersedes the previous artifact: the selector may now relabel the new run,
        // while the old completed result can no longer be displayed or exported.
        completedArtifacts = nil
        displayedOutputRecord = nil
        replaceResultContext(nil, selection: nil)
        completedArtifactsGeneration = nil
        outputBuffer = nil

        jobGeneration &+= 1
        let generation = jobGeneration
        stopRequestedForJobGeneration = nil

        // R6: carry the validated session state (from ingestion/handoff) into execution so the
        // executor does not discard payload-only denoise/upscale/factor/headroom after re-decode.
        // Scaler is super-resolution only: all new app jobs are constructed with `.off`.
        let config = ScalerSRPolicy.makeJobConfig(
            sourceImageURL: sourceURL,
            model: selectedModel,
            naturalGrainAmount: selectedGrainRetention,
            exportFormat: exportFormat,
            sessionState: metadata?.pipelineSessionState
        )
        activeJobID = config.id
        terminalProgressGeneration = nil
        let effectiveScale = config.scaleFactor
        let baseWidth = sourceBuffer?.width ?? metadata?.originalWidth ?? 0
        let baseHeight = sourceBuffer?.height ?? metadata?.originalHeight ?? 0
        Diagnostics.shared.record(
            category: .pipeline,
            level: .notice,
            code: "app.job.enqueued",
            message: "SR-only job enqueued",
            fields: [
                "correlationID": config.id.uuidString,
                "sourceType": sourceURL.pathExtension.lowercased(),
                "sourceWidth": "\(baseWidth)",
                "sourceHeight": "\(baseHeight)",
                "backbone": config.backbone.rawValue,
                "scale": "\(effectiveScale.rawValue)x",
                "denoise": "off",
                "exportFormat": config.exportFormat.rawValue,
                "tileTier": tileConfig.tier.rawValue,
                "tileSize": "\(tileConfig.inputTileSize)",
                "tileOverlap": "\(tileConfig.inputOverlap)",
                "historyDenoised": (metadata?.isAlreadyDenoisedBySuite ?? false) ? "true" : "false"
            ]
        )
        let descriptor = BackgroundJobDescriptor(
            jobID: config.id,
            sourceFileName: sourceURL.lastPathComponent,
            scaleFactor: effectiveScale,
            targetWidth: baseWidth * effectiveScale.rawValue,
            targetHeight: baseHeight * effectiveScale.rawValue,
            totalTiles: 0,
            includesOutputPublication: outputSession != nil
        )

        let owner = ExecutionOwner(generation: generation, session: session)
        owner.outputSelection = outputSession
        executionOwner = owner
        activeCoordinatorGeneration = generation

        let coordinator = backgroundCoordinator
        let pipeline = self.pipeline
        // Keep the selected input root alive as well as the independent photo grant. Retaining
        // it is harmless for a separately imported file and avoids path-alias/provider assumptions.
        let inputSelection = librarySession
        inputSelection?.activeOperations += 1
        let task = Task { @MainActor [weak self] in
            defer { inputSelection?.activeOperations -= 1; inputSelection?.releaseIfDrained() }
            guard let self else { return }
            // A scene hop can win after the batch's foreground check but before this task runs.
            // Adoption is guarded on the coordinator actor too; an already adopted current photo
            // keeps its existing continuation, but a new photo must wait for foreground ownership.
            while true {
                if ownedByBatch {
                    guard await self.waitForBatchForeground(sessionGeneration: session.generation) else {
                        self.finishExecution(owner)
                        return
                    }
                }
                let foregroundAttempt = self.foregroundSceneGeneration
                let started = await coordinator.startJob(descriptor, requiresForegroundStart: ownedByBatch)
                if started == .deferred {
                    // Do not lose a newer active callback that already completed during the hop.
                    if self.foregroundSceneGeneration == foregroundAttempt || self.latestScenePhase != .active {
                        self.isBatchForegroundReady = false
                    }
                    continue
                }
                guard started == .started else {
                    self.finishExecution(owner)
                    return
                }
                break
            }

            // Revalidate after the coordinator await: Stop/reset/ingest may have superseded this run
            // before it reached the executor.
            guard self.isCurrentExecution(owner), !Task.isCancelled else {
                await self.cancelCoordinatorIfOwned(generation: generation, message: "Upscale superseded")
                self.finishExecution(owner)
                return
            }

            // Stale pauses are cleared atomically by the coordinator's job-run registration
            // (`registerJobRun`) before this execution starts. Do not unconditionally clear here: a
            // legitimate pause that arrived between `startJob` and this point (for the same job) must
            // still pause the run, and a newer job's pause must never be cleared by an older start.
            guard self.isCurrentExecution(owner), !Task.isCancelled else {
                await self.cancelCoordinatorIfOwned(generation: generation, message: "Upscale superseded")
                self.finishExecution(owner)
                return
            }

            // Each execution acquires its own independent source grant.
            session.activeOperations += 1
            let operationGrant = self.scopeProvider.openGrant(for: session.url)

            let destinationSession = owner.outputSelection
            destinationSession?.activeOperations += 1
            let destinationGrant = destinationSession.map { self.scopeProvider.openGrant(for: $0.url) }
            defer {
                destinationGrant?.release()
                destinationSession?.activeOperations -= 1
                destinationSession?.releaseIfDrained()
            }
            do {
                var executionConfig = config
                if let destinationSession {
                    let original = try await self.resultStore.archiveOriginal(at: sourceURL,
                        named: sourceURL.lastPathComponent, under: destinationSession.url)
                    let archivedURL = try await self.resultStore.originalURL(original, under: destinationSession.url)
                    guard self.isCurrentExecution(owner), !owner.stopRequested, !Task.isCancelled else { throw CancellationError() }
                    owner.archivedOriginal = original
                    executionConfig = UpscaleJobConfig(id: config.id, sourceImageURL: archivedURL,
                        scaleFactor: config.scaleFactor, backbone: config.backbone, denoiseMode: config.denoiseMode,
                        naturalGrainAmount: config.naturalGrainAmount, exportFormat: config.exportFormat,
                        sessionState: config.sessionState)
                }
                let artifacts = try await pipeline.executeOrResumeJob(config: executionConfig) { [weak self] update in
                    Task { @MainActor [weak self] in
                        self?.applyProgress(update, generation: generation)
                    }
                }
                operationGrant.release()
                session.activeOperations -= 1
                session.releaseIfDrained()
                await self.handleJobSuccess(artifacts, generation: generation)
            } catch {
                operationGrant.release()
                session.activeOperations -= 1
                session.releaseIfDrained()
                await self.handleJobFailure(error, generation: generation)
            }
            self.finishExecution(owner)
        }
        owner.task = task
    }

    private func isCurrentExecution(_ owner: ExecutionOwner) -> Bool {
        executionOwner === owner && owner.generation == jobGeneration
    }

    private func applyProgress(_ update: PipelineProgressUpdate, generation: UInt64) {
        guard generation == jobGeneration else { return }
        // A late progress callback after a completed/failed terminal must never overwrite it. A paused
        // terminal is different: a genuinely newer durable frontier can still arrive from a queued
        // delivery after Stop published; merge only counts that advanced, keeping the paused phase.
        if terminalProgressGeneration == generation {
            guard let current = latestProgress,
                  current.phase == .paused,
                  update.completedTiles > max(current.completedTiles, completedTiles) else { return }
            completedTiles = update.completedTiles
            totalTiles = max(update.totalTiles, current.totalTiles)
            publishTerminalProgress(phase: .paused, stage: .pausedOnDisk, generation: generation)
            return
        }
        guard isProcessing else { return }
        // Counts/total are durable checkpoint facts, not stage decorations. Accept them while Stop
        // drains so the authoritative terminal frame cannot regress to the pre-Stop frontier. Only the
        // stage word is kept at the stopping state; an uncommitted heartbeat repeats the same count.
        completedTiles = update.completedTiles
        totalTiles = update.totalTiles
        if !isStopping {
            currentStage = update.stage
        }
        latestProgress = update
        if let elapsed = update.elapsedSeconds, elapsed > processingElapsedSeconds {
            processingElapsedSeconds = elapsed
        }
        recordProgressDiagnosticIfNeeded(update)
        // ActivityKit/NSProgress updates are comparatively expensive and were observed spamming the
        // console. Forward a real update when a tile is durably committed, at most once per second for
        // intra-tile phase changes, and always forward terminal state. UI progress above is not
        // throttled; Stop/error/completion use their own immediate coordinator paths.
        let now = Date()
        let terminal = update.phase == .completed || update.phase == .failed
        let committedChanged = update.completedTiles != lastCoordinatorCompletedTiles
        let due = lastCoordinatorProgressAt.map { now.timeIntervalSince($0) >= 1.0 } ?? true
        guard terminal || committedChanged || due else { return }
        lastCoordinatorProgressAt = now
        lastCoordinatorCompletedTiles = update.completedTiles
        Task { @MainActor [weak self] in
            guard let self, generation == self.jobGeneration else { return }
            await self.backgroundCoordinator.updateProgress(update)
        }
    }

    private func recordProgressDiagnosticIfNeeded(_ update: PipelineProgressUpdate) {
        let now = Date()
        let terminalPhase = update.phase == .completed || update.phase == .failed
        let due = lastProgressDiagnosticAt.map { now.timeIntervalSince($0) >= 5.0 } ?? true
        guard due || terminalPhase else { return }
        lastProgressDiagnosticAt = now
        var fields: [String: String] = [
            "correlationID": update.jobID.uuidString,
            "phase": update.phase.rawValue,
            "completed": "\(update.completedTiles)",
            "total": "\(update.totalTiles)",
            "elapsedSeconds": update.elapsedSeconds.map { String(format: "%.3f", $0) } ?? "unknown"
        ]
        if let current = update.currentTileIndex { fields["currentTileIndex"] = "\(current)" }
        if let average = update.averageSecondsPerTile { fields["avgSecondsPerTile"] = String(format: "%.3f", average) }
        if let eta = update.estimatedSecondsRemaining { fields["etaSeconds"] = "\(eta)" }
        if let model = update.modelName { fields["model"] = model }
        if let compute = update.requestedCompute { fields["computeRequested"] = compute }
        Diagnostics.shared.record(
            category: .pipeline,
            level: update.phase == .failed ? .error : .info,
            code: "pipeline.progress",
            message: "progress",
            fields: fields
        )
    }

    /// Publishes the authoritative terminal progress state for the owned generation and prevents
    /// late intra-tile callbacks from replacing it. Diagnostic/UI details therefore agree with the
    /// actual paused/failed/completed state after the processing bar closes.
    private func publishTerminalProgress(
        phase: PipelinePhase,
        stage: JobStage,
        generation: UInt64,
        artifacts: CompletedPipelineArtifacts? = nil
    ) {
        guard generation == jobGeneration else { return }
        terminalProgressGeneration = generation
        let base = latestProgress
        let jobID = artifacts?.checkpoint.config.id ?? activeJobID ?? base?.jobID ?? UUID()
        let completed = artifacts?.checkpoint.totalTiles
            ?? max(max(0, completedTiles), base?.completedTiles ?? 0)
        let total = artifacts?.checkpoint.totalTiles
            ?? max(max(0, totalTiles), base?.totalTiles ?? 0)
        let fraction: Double
        if phase == .completed { fraction = 1.0 }
        else if total > 0 { fraction = 0.10 + 0.90 * Double(min(completed, total)) / Double(total) }
        else { fraction = 0 }
        let modelName: String? = {
            if let artifacts {
                guard artifacts.checkpoint.config.backbone.isSupported else { return "Previous model" }
                return CoreMLModelIdentifier.superResolver(
                    backbone: artifacts.checkpoint.config.backbone,
                    tier: artifacts.checkpoint.tileConfig.tier
                ).rawValue
            }
            return base?.modelName
        }()
        latestProgress = PipelineProgressUpdate(
            jobID: jobID,
            stage: stage,
            completedTiles: completed,
            totalTiles: total,
            overallFraction: fraction,
            estimatedSecondsRemaining: phase == .completed ? 0 : nil,
            currentTileDescriptor: nil,
            phase: phase,
            currentTileIndex: nil,
            elapsedSeconds: processingElapsedSeconds,
            tileLoopElapsedSeconds: base?.tileLoopElapsedSeconds,
            averageSecondsPerTile: base?.averageSecondsPerTile,
            sourceWidth: artifacts?.checkpoint.sourceWidth ?? base?.sourceWidth,
            sourceHeight: artifacts?.checkpoint.sourceHeight ?? base?.sourceHeight,
            outputWidth: artifacts?.checkpoint.outputWidth ?? base?.outputWidth,
            outputHeight: artifacts?.checkpoint.outputHeight ?? base?.outputHeight,
            modelName: modelName,
            tileSize: artifacts?.checkpoint.tileConfig.inputTileSize ?? base?.tileSize,
            tileOverlap: artifacts?.checkpoint.tileConfig.inputOverlap ?? base?.tileOverlap,
            gridColumns: base?.gridColumns,
            gridRows: base?.gridRows,
            requestedCompute: base?.requestedCompute,
            didRunDenoise: artifacts?.checkpoint.didRunDenoise ?? base?.didRunDenoise,
            timings: nil
        )
        recordProgressDiagnosticIfNeeded(latestProgress!)
    }

    private func startProgressTimer() {
        progressTimerTask?.cancel()
        let started = Date()
        progressTimerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard self.isProcessing else { return }
                self.processingElapsedSeconds = max(self.processingElapsedSeconds, Date().timeIntervalSince(started))
            }
        }
    }

    private func stopProgressTimer() {
        progressTimerTask?.cancel()
        progressTimerTask = nil
        if let jobStartedAt {
            processingElapsedSeconds = max(processingElapsedSeconds, Date().timeIntervalSince(jobStartedAt))
        }
    }

    private func handleJobSuccess(_ artifacts: CompletedPipelineArtifacts, generation: UInt64) async {
        guard generation == jobGeneration, executionOwner?.generation == generation else {
            await cancelCoordinatorIfOwned(generation: generation, message: "Upscale superseded")
            return
        }
        var saveError: String?
        if let owner = executionOwner, owner.outputSelection != nil {
            currentStage = .exportingContainer
            isSavingResult = true
            defer { isSavingResult = false }
            replaceResultContext(nil, selection: owner.outputSelection)
            do {
                let saved = try await publishResult(artifacts, owner: owner)
                guard generation == jobGeneration, executionOwner === owner else { return }
                replaceResultContext(saved, selection: owner.outputSelection)
            }
            catch { saveError = "The photo was processed, but could not be saved: " + error.localizedDescription }
            guard generation == jobGeneration, executionOwner === owner else { return }
        }
        if stopRequestedForJobGeneration != generation { stopRequestedForJobGeneration = nil }
        self.errorMessage = saveError
        self.completedArtifacts = artifacts
        self.completedArtifactsGeneration = generation
        self.sourceBuffer = artifacts.sourceBuffer
        self.outputBuffer = artifacts.outputBuffer
        self.metadata = artifacts.metadata
        self.completedTiles = artifacts.checkpoint.totalTiles
        self.totalTiles = artifacts.checkpoint.totalTiles
        self.currentStage = .readyForInspection
        self.isProcessing = false
        self.isStopping = false
        self.activeCoordinatorGeneration = nil
        stopProgressTimer()
        publishTerminalProgress(phase: .completed, stage: .completed, generation: generation, artifacts: artifacts)
        Diagnostics.shared.record(
            category: .pipeline,
            level: .notice,
            code: "app.job.completed",
            message: "SR-only job completed",
            fields: [
                "correlationID": artifacts.checkpoint.config.id.uuidString,
                "sourceWidth": "\(artifacts.checkpoint.sourceWidth)",
                "sourceHeight": "\(artifacts.checkpoint.sourceHeight)",
                "outputWidth": "\(artifacts.checkpoint.outputWidth)",
                "outputHeight": "\(artifacts.checkpoint.outputHeight)",
                "actualScale": "\(FormatAwareExporter.actualScaleFactor(artifacts: artifacts))x",
                "elapsedSeconds": String(format: "%.3f", processingElapsedSeconds),
                "didRunDenoise": artifacts.checkpoint.didRunDenoise ? "true" : "false",
                "model": CoreMLModelIdentifier.superResolver(
                    backbone: artifacts.checkpoint.config.backbone,
                    tier: artifacts.checkpoint.tileConfig.tier
                ).rawValue
            ]
        )
        await backgroundCoordinator.completeJob(success: saveError == nil, message: saveError == nil ? "Upscale complete" : "Result could not be saved")
        await reloadOutputFolder()
    }

    private func handleJobFailure(_ error: Error, generation: UInt64) async {
        guard generation == jobGeneration else {
            // A newer operation owns the view model now; its drain cancels the coordinator job.
            return
        }
        if stopRequestedForJobGeneration == generation || Self.isPauseError(error) {
            // Stop/reset owns the final state; keep the stopping state until the drain completes.
            if stoppingTask == nil, !isStopping {
                stopProgressTimer()
                self.isProcessing = false
                if currentStage != .pausedOnDisk {
                    currentStage = .pausedOnDisk
                }
                publishTerminalProgress(phase: .paused, stage: .pausedOnDisk, generation: generation)
            }
            return
        }

        self.errorMessage = error.localizedDescription
        self.currentStage = .failed
        self.isProcessing = false
        self.isStopping = false
        self.activeCoordinatorGeneration = nil
        stopProgressTimer()
        publishTerminalProgress(phase: .failed, stage: .failed, generation: generation)
        Diagnostics.shared.recordError(
            error,
            category: .pipeline,
            code: "app.job.failed",
            context: [
                "correlationID": activeJobID?.uuidString ?? generation.description,
                "elapsedSeconds": String(format: "%.3f", processingElapsedSeconds)
            ]
        )
        await backgroundCoordinator.completeJob(success: false, message: error.localizedDescription)
    }

    /// The executor task has fully returned (success, failure or cancellation). Only the owner that
    /// actually finished may clear the owner slot.
    private func finishExecution(_ owner: ExecutionOwner) {
        guard executionOwner === owner else { return }
        executionOwner = nil
        if stoppingTask == nil, !isStopping {
            isProcessing = false
            stopProgressTimer()
        }
    }

    private nonisolated static func isPauseError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let scalerError = error as? ScalerError,
           case .jobPausedForBackgroundExpiration = scalerError {
            return true
        }
        return false
    }

    /// Cancels the coordinator job only when this view model still owns that exact generation.
    private func cancelCoordinatorIfOwned(generation: UInt64, message: String) async {
        guard activeCoordinatorGeneration == generation else { return }
        activeCoordinatorGeneration = nil
        await backgroundCoordinator.cancelJob(message: message)
    }

    /// User Stop: distinct stopping state; waits for the graceful pause boundary, then cancels the
    /// owned task and only then clears `isProcessing`.
    public func cancelProcessing() {
        if isBatchProcessing {
            batchStopRequested = true
            wakeBatchForegroundWaiters()
        }
        guard isProcessing, !isStopping, let owner = executionOwner, stoppingTask == nil else { return }
        isStopping = true
        currentStage = .pausedOnDisk
        stopRequestedForJobGeneration = owner.generation
        owner.stopRequested = true

        let pipeline = self.pipeline
        let stoppingID = UUID()
        stoppingTaskID = stoppingID
        let stoppage = Task { @MainActor [weak self] in
            guard let self else { return }
            // Wait for the executor's stable paused boundary BEFORE cancelling the owned task.
            await pipeline.requestGracefulPauseAndWait()
            owner.task?.cancel()
            await owner.task?.value
            if self.executionOwner === owner { self.executionOwner = nil }
            if self.stoppingTaskID == stoppingID {
                self.stoppingTask = nil
                self.stoppingTaskID = nil
            }
            // A reset/new run that superseded this stop owns the final state.
            guard owner.generation == self.jobGeneration else { return }
            self.stopRequestedForJobGeneration = nil
            // A Stop that raced a successful completion must not overwrite the completed result.
            if self.completedArtifactsGeneration == owner.generation {
                self.isProcessing = false
                self.isStopping = false
                return
            }
            self.isProcessing = false
            self.isStopping = false
            self.currentStage = .pausedOnDisk
            self.stopProgressTimer()
            self.publishTerminalProgress(phase: .paused, stage: .pausedOnDisk, generation: owner.generation)
            Diagnostics.shared.record(
                category: .pipeline,
                level: .notice,
                code: "app.job.stopped",
                message: "stopped at durable boundary",
                fields: [
                    "correlationID": self.activeJobID?.uuidString ?? owner.generation.description,
                    "completed": "\(self.completedTiles)",
                    "total": "\(self.totalTiles)",
                    "elapsedSeconds": String(format: "%.3f", self.processingElapsedSeconds)
                ]
            )
            await self.cancelCoordinatorIfOwned(generation: owner.generation, message: "Upscale cancelled")
        }
        stoppingTask = stoppage
    }

    /// Drains any owned execution to its stable boundary before a session-replacing operation.
    /// Serialized: concurrent callers await the same drain task.
    private func drainExecutionForSessionChange(waitForReset: Bool = true) async {
        if waitForReset, let resetTask {
            await resetTask.value
        }
        if let existingDrain = drainTask {
            await existingDrain.value
            return
        }
        let owner = executionOwner
        let stoppage = stoppingTask
        guard owner != nil || stoppage != nil else { return }

        // Invalidate the old run's publications immediately; it may still be inside an await.
        jobGeneration &+= 1
        let drainedGeneration = owner?.generation ?? activeCoordinatorGeneration
        let drainID = UUID()
        drainTaskID = drainID
        let drain = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pipeline.requestGracefulPauseAndWait()
            if let stoppage { await stoppage.value }
            if let owner {
                owner.task?.cancel()
                await owner.task?.value
                if self.executionOwner === owner { self.executionOwner = nil }
            }
            if self.drainTaskID == drainID {
                self.drainTask = nil
                self.drainTaskID = nil
            }
            if self.stoppingTask != nil {
                self.stoppingTask = nil
                self.stoppingTaskID = nil
            }
            if drainedGeneration == self.jobGeneration || self.executionOwner == nil {
                self.isStopping = false
            }
            if let drainedGeneration {
                await self.cancelCoordinatorIfOwned(generation: drainedGeneration, message: "Upscale superseded")
            }
        }
        drainTask = drain
        await drain.value
    }

    /// No polling or background request replay: only a real foreground callback releases a queued
    /// photo. Stop/cancellation and a newer session wake the same continuation to retire the queue.
    private func waitForBatchForeground(sessionGeneration generation: UInt64) async -> Bool {
        while isBatchProcessing, !batchStopRequested, !Task.isCancelled,
              sessionGeneration == generation {
            if isBatchForegroundReady { return true }
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard isBatchProcessing, !batchStopRequested, !Task.isCancelled,
                          sessionGeneration == generation, !isBatchForegroundReady else {
                        continuation.resume()
                        return
                    }
                    batchForegroundWaiters[waiterID] = continuation
                    isBatchWaitingForForeground = true
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.wakeBatchForegroundWaiter(waiterID) }
            }
        }
        return false
    }

    private func wakeBatchForegroundWaiter(_ id: UUID) {
        let continuation = batchForegroundWaiters.removeValue(forKey: id)
        isBatchWaitingForForeground = !batchForegroundWaiters.isEmpty
        continuation?.resume()
    }

    private func wakeBatchForegroundWaiters() {
        let continuations = Array(batchForegroundWaiters.values)
        batchForegroundWaiters.removeAll()
        isBatchWaitingForForeground = false
        for continuation in continuations { continuation.resume() }
    }

    public func batchProcessSelected(ids: Set<String>) async {
        guard !isBatchProcessing, !isProcessing, !isStopping, selectedCollection == .input else { return }
        let items = orderedLibraryItems.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        isBatchProcessing = true; batchStopRequested = false; batchPhotoCount = items.count
        defer {
            isBatchProcessing = false; batchPhotoNumber = nil; batchPhotoCount = nil
            wakeBatchForegroundWaiters()
        }
        var expectedSession = sessionGeneration
        for (index, item) in items.enumerated() {
            batchPhotoNumber = index + 1
            guard await waitForBatchForeground(sessionGeneration: expectedSession) else { break }
            latestProgress = nil; completedTiles = 0; totalTiles = 0
            // A direct import or incoming handoff may supersede this item while its decode,
            // execution or save drains. Never process the replacement under this batch slot or
            // open the next queued photo over that newer user selection.
            supersedeIncomingHandoffConsumptions()
            let itemGeneration = reserveIngestGeneration()
            expectedSession = itemGeneration
            await enqueueIngest(at: item.fileURL, sessionGeneration: itemGeneration, handoff: nil)
            guard sessionGeneration == itemGeneration else { break }
            if currentStage == .failed || Task.isCancelled || batchStopRequested { break }

            // A previous Stop must reach its stable boundary before the next item starts.
            if isProcessing || isStopping {
                await waitForExecutionToSettle()
            }
            guard sessionGeneration == itemGeneration else { break }
            if Task.isCancelled || currentStage == .failed || batchStopRequested { break }

            guard await waitForBatchForeground(sessionGeneration: itemGeneration) else { break }
            startProcessing(ownedByBatch: true)
            guard let owner = executionOwner else { break }
            let ownedTask = owner.task, ownedGeneration = owner.generation
            await withTaskCancellationHandler {
                await ownedTask?.value
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.executionOwner?.generation == ownedGeneration else { return }
                    self.cancelProcessing()
                }
            }

            guard sessionGeneration == itemGeneration else { break }
            if batchStopRequested { break }
            if currentStage == .readyForInspection {
                await exportFinalImage(presentShareSheet: false)
                guard sessionGeneration == itemGeneration else { break }
                // Processing can succeed while publication and its retry both fail. Retain the
                // current completed artifact/error for retry instead of clearing them for photo 2.
                if requiresOutputFolder && publishedCurrentResult == nil { break }
            } else if currentStage == .failed || currentStage == .pausedOnDisk {
                // Batch stops on failure/cancellation instead of continuing with stale scope.
                break
            }
        }
        await reloadLibraryFolder()
    }

    public func exportSelected(ids: Set<String>) async {
        let urls = orderedLibraryItems.filter { ids.contains($0.id) }.map(\.fileURL)
        guard !urls.isEmpty else { return }
        await prepareShare(urls, surface: .library)
    }

    // MARK: - Export & Companion App Handoff

    private func retrySavingResult(presentShareSheet: Bool) async {
        guard let artifacts = completedArtifacts, let artifactGeneration = completedArtifactsGeneration else { return }
        guard let destination = outputSession else { isOutputSetupPresented = true; return }
        guard exportTasks.isEmpty else { return }
        let sourceSelection = resultSelection
        let generation = sessionGeneration
        let taskID = UUID()
        let task = Task { @MainActor in
            guard sessionGeneration == generation, completedArtifactsGeneration == artifactGeneration else {
                exportTasks.removeValue(forKey: taskID); return
            }
            sourceSelection?.activeOperations += 1
            destination.activeOperations += 1
            let sourceGrant = sourceSelection.map { scopeProvider.openGrant(for: $0.url) }
            let destinationGrant = scopeProvider.openGrant(for: destination.url)
            isSavingResult = true
            defer {
                sourceGrant?.release(); destinationGrant.release()
                sourceSelection?.activeOperations -= 1; sourceSelection?.releaseIfDrained()
                destination.activeOperations -= 1; destination.releaseIfDrained()
                if sessionGeneration == generation { isSavingResult = false }
                exportTasks.removeValue(forKey: taskID)
            }
            do {
                let original = try await resultStore.archiveOriginal(at: artifacts.checkpoint.config.sourceImageURL,
                    named: sourceURL?.lastPathComponent ?? "Original", under: destination.url)
                let record = try await exportResultRecord(artifacts, original: original, selection: destination) {
                    self.sessionGeneration == generation && self.completedArtifactsGeneration == artifactGeneration && !Task.isCancelled
                }
                guard sessionGeneration == generation, completedArtifactsGeneration == artifactGeneration else { return }
                replaceResultContext(record, selection: destination)
                errorMessage = nil
                if presentShareSheet { await prepareShare([destination.url.appendingPathComponent(record.outputRelativePath)], surface: .viewer) }
                await reloadOutputFolder()
            } catch {
                guard sessionGeneration == generation else { return }
                errorMessage = "The result could not be saved: " + error.localizedDescription
            }
        }
        exportTasks[taskID] = task
        await task.value
    }

    public func exportFinalImage(presentShareSheet: Bool = true) async {
        if displayedLegacyOutput, let sourceURL {
            if presentShareSheet { await prepareShare([sourceURL], surface: .viewer) }
            return
        }
        if let record = publishedCurrentResult, let selection = resultSelection {
            let url = selection.url.appendingPathComponent(record.outputRelativePath)
            if presentShareSheet { await prepareShare([url], surface: .viewer) }
            return
        }
        if requiresOutputFolder {
            await retrySavingResult(presentShareSheet: presentShareSheet)
            return
        }
        guard let artifacts = completedArtifacts, let artifactGeneration = completedArtifactsGeneration else { return }
        let sessionSnapshot = sessionGeneration
        let librarySnapshot = libraryGeneration
        let librarySelection = librarySession
        let session = sourceSession
        let requestedFormat = exportFormat

        let resolvedFormat = artifacts.metadata.resolvedExportFormat(from: requestedFormat)
        let ext: String
        switch resolvedFormat {
        case .linearDNG16Bit, .autoMatchSource: ext = "dng"
        case .tiff16BitLZW: ext = "tiff"
        case .heic10BitHDR: ext = "heic"
        case .png16Bit: ext = "png"
        case .jpeg95: ext = "jpg"
        }
        // Filename and grain derive from the completed artifact, not the live selector.
        let artifactScale = self.artifactActualScaleFactor(artifacts)
        let baseName = artifacts.metadata.sourceURL.deletingPathExtension().lastPathComponent
        let outName = "\(baseName)_\(artifactScale)x.\(ext)"
        let outDir = libraryFolderURL ?? workingDirectory
        let destURL = outDir.appendingPathComponent(outName)
        let grain = artifacts.checkpoint.config.naturalGrainAmount

        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performExport(
                artifacts: artifacts,
                artifactGeneration: artifactGeneration,
                sessionSnapshot: sessionSnapshot,
                librarySnapshot: librarySnapshot,
                librarySelection: librarySelection,
                session: session,
                destinationURL: destURL,
                format: resolvedFormat,
                grain: grain,
                presentShareSheet: presentShareSheet
            )
            self.exportTasks.removeValue(forKey: operationID)
        }
        exportTasks[operationID] = task
        await task.value
    }

    private func performExport(
        artifacts: CompletedPipelineArtifacts,
        artifactGeneration: UInt64,
        sessionSnapshot: UInt64,
        librarySnapshot: UInt64,
        librarySelection: ScopeSession?,
        session: ScopeSession?,
        destinationURL: URL,
        format: ExportFormat,
        grain: Float,
        presentShareSheet: Bool
    ) async {
        // Each export holds independent source + destination grants for its whole duration.
        let sourceSession = session
        sourceSession?.activeOperations += 1
        let sourceGrant = scopeProvider.openGrant(for: artifacts.metadata.sourceURL)
        var destinationGrant: (any SecurityScopeGrant)?
        if let librarySelection {
            librarySelection.activeOperations += 1
            libraryOperationCount += 1
            destinationGrant = scopeProvider.openGrant(for: librarySelection.url)
        }

        func drainGrants() {
            destinationGrant?.release()
            if let librarySelection {
                librarySelection.activeOperations -= 1
                librarySelection.releaseIfDrained()
                libraryOperationCount = max(0, libraryOperationCount - 1)
            }
            sourceGrant.release()
            sourceSession?.activeOperations -= 1
            sourceSession?.releaseIfDrained()
        }

        let exportID = UUID().uuidString
        let exportSpan = Diagnostics.shared.startSpan(
            category: .export,
            code: "export.write",
            fields: [
                "exportID": exportID,
                "format": format.rawValue,
                "artifactScale": "\(artifactActualScaleFactor(artifacts))x",
                "outputWidth": "\(artifacts.checkpoint.outputWidth)",
                "outputHeight": "\(artifacts.checkpoint.outputHeight)"
            ]
        )
        do {
            let result = try await exporter.exportDetailed(
                artifacts: artifacts,
                destinationURL: destinationURL,
                overrideFormat: format,
                overrideGrainAmount: grain
            )
            exportSpan.end(additionalFields: [
                "actualScale": "\(result.actualScaleFactor)x",
                "headroomScale": String(format: "%.4f", result.dngHeadroomScale)
            ])
            drainGrants()

            // Recheck identity BEFORE publishing anything: a newer ingest/select/reset must not see
            // a stale export URL or a stale final state.
            guard sessionSnapshot == sessionGeneration,
                  artifactGeneration == completedArtifactsGeneration,
                  librarySnapshot == libraryGeneration,
                  librarySession === librarySelection else { return }

            if presentShareSheet {
                await self.prepareShare([result.url], surface: .viewer)
            }
            // Share preparation can outlive this photo/library selection. Its own publication
            // fences do not authorize the export's later metadata mutation for a newer photo.
            guard sessionSnapshot == sessionGeneration,
                  artifactGeneration == completedArtifactsGeneration,
                  librarySnapshot == libraryGeneration,
                  librarySession === librarySelection else { return }
            // Record the authoritative final headroom/factor for later forwarding handoffs.
            self.metadata = self.metadata?.withPipelineState(
                isUpscaled: true,
                upscaledByAppFactor: result.actualScaleFactor,
                linearHeadroomScale: result.dngHeadroomScale
            )
            await reloadLibraryFolder()
        } catch {
            exportSpan.end(level: error is CancellationError ? .debug : .warning)
            drainGrants()
            guard sessionSnapshot == sessionGeneration,
                  artifactGeneration == completedArtifactsGeneration,
                  librarySnapshot == libraryGeneration else { return }
            if error is CancellationError { return }
            Diagnostics.shared.recordError(error, category: .export, code: "export.failed", context: [
                "exportID": exportID,
                "format": format.rawValue
            ])
            self.errorMessage = error.localizedDescription
        }
    }

    /// Outgoing handoff to TruongNoiser. Never launches or edits TruongNoiser itself.
    ///
    /// The payload is derived from the frozen artifact/session:
    /// * `isDenoised = checkpoint.didRunDenoise || metadata.isAlreadyDenoisedBySuite`;
    /// * `isUpscaled` from the artifact, preserving an already-upscaled forwarded file;
    /// * headroom from the final grain-blended export (`ExportResult.dngHeadroomScale`), never from
    ///   the input/luminance checkpoint.
    ///
    /// Every input is snapshotted before the awaits and revalidated afterwards, so a stale export can
    /// never launch against a newer session.
    public func sendToTruongNoiser() async {
        guard let sourceURL else { return }
        let sessionSnapshot = sessionGeneration
        let artifactGeneration = completedArtifactsGeneration
        let artifacts = completedArtifacts
        let metadataSnapshot = metadata
        let sourceSessionSnapshot = sourceSession
        let fallbackFactor = derivedScaleFactor?.rawValue
        let tempDNG = workingDirectory.appendingPathComponent("handoff_\(UUID().uuidString).dng")
        // The App Group handoff owns its byte copy after staging drains. This unique private
        // intermediate belongs only to this send, including partial-export/staging failures.
        // Never remove exportURL here: forwarding can use the human's existing source directly.
        defer { try? FileManager.default.removeItem(at: tempDNG) }

        // Determine the session state to forward. With an artifact we must wait for the detailed
        // export to learn the actual final headroom; forwarding uses the frozen session state.
        let isDenoised = (artifacts?.checkpoint.didRunDenoise ?? false)
            || (metadataSnapshot?.isAlreadyDenoisedBySuite ?? false)
        let forwardedIsUpscaled = artifacts != nil
            || (metadataSnapshot?.isAlreadyUpscaledBySuite ?? false)
        let forwardedFactor: Int? = artifacts != nil
            ? nil
            : (metadataSnapshot?.upscaledByAppFactor ?? (forwardedIsUpscaled ? fallbackFactor : nil))
        let forwardedHeadroom = max(1, metadataSnapshot?.linearHeadroomScale ?? 1)

        // Each staging operation holds its own source grant for the whole await chain.
        sourceSessionSnapshot?.activeOperations += 1
        let sourceGrant = scopeProvider.openGrant(for: sourceURL)
        func drainSourceGrant() {
            sourceGrant.release()
            sourceSessionSnapshot?.activeOperations -= 1
            sourceSessionSnapshot?.releaseIfDrained()
        }

        do {
            let exportResult: ExportResult?
            if let artifacts {
                let grain = artifacts.checkpoint.config.naturalGrainAmount
                exportResult = try await exporter.exportDetailed(
                    artifacts: artifacts,
                    destinationURL: tempDNG,
                    overrideFormat: .linearDNG16Bit,
                    overrideGrainAmount: grain
                )
            } else {
                exportResult = nil
            }

            let exportURL = exportResult?.url ?? sourceURL
            let calculatedFactor = exportResult?.actualScaleFactor ?? forwardedFactor
            let isUpscaled = exportResult != nil ? true : forwardedIsUpscaled
            let headroom = exportResult?.dngHeadroomScale ?? forwardedHeadroom
            let luminance: Float = {
                if let artifacts { return max(1, artifacts.checkpoint.globalMaxLuminance) }
                return forwardedHeadroom
            }()
            let originalFileName = sourceURL.lastPathComponent

            // Revalidate BEFORE creating the handoff package: never stage a stale artifact/session mix.
            guard sessionSnapshot == sessionGeneration,
                  artifactGeneration == completedArtifactsGeneration,
                  sourceURL == self.sourceURL else {
                drainSourceGrant()
                return
            }

            let handoff = try await handoffManager.createHandoffPackage(
                exportedImageURL: exportURL,
                originalFileName: originalFileName,
                isDenoised: isDenoised,
                isUpscaled: isUpscaled,
                globalMaxLuminance: luminance,
                upscaleFactor: calculatedFactor,
                globalMaxLinearComponent: headroom
            )

            // Revalidate again before publishing/launching: a newer session must never receive the
            // previous session's export URL or flags.
            guard sessionSnapshot == sessionGeneration,
                  artifactGeneration == completedArtifactsGeneration else {
                drainSourceGrant()
                return
            }

            self.metadata = self.metadata?.withPipelineState(
                isDenoised: isDenoised,
                isUpscaled: isUpscaled,
                upscaledByAppFactor: calculatedFactor,
                linearHeadroomScale: headroom
            )
            drainSourceGrant()
            await externalOpener.open(handoff.deepLinkURL)
        } catch {
            drainSourceGrant()
            guard sessionSnapshot == sessionGeneration,
                  artifactGeneration == completedArtifactsGeneration else { return }
            if error is CancellationError { return }
            Diagnostics.shared.recordError(
                error,
                category: .export,
                code: "handoff.outgoing.failed",
                context: ["operation": "outgoing_handoff"]
            )
            self.errorMessage = error.localizedDescription
        }
    }

    /// Accepts an incoming handoff as an owned ingress operation.
    ///
    /// A monotonic ingress identity is reserved synchronously when the request is accepted; the
    /// previous consume task is cancelled and retained until it drains. Reset, a photo selection or a
    /// newer handoff supersedes the reservation. Every post-await decision re-checks that identity,
    /// so a late payload/error can neither resurrect an old session nor overwrite newer error state.
    public func handleIncomingHandoffURL(_ url: URL) {
        supersedeIncomingHandoffConsumptions()
        if isBatchProcessing {
            batchStopRequested = true
            wakeBatchForegroundWaiters()
        }
        let ingressGeneration = handoffIngressGeneration

        let operationID = UUID()
        let manager = handoffManager
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performIncomingHandoffConsumption(
                from: url,
                manager: manager,
                ingressGeneration: ingressGeneration
            )
            self.handoffConsumeTasks.removeValue(forKey: operationID)
        }
        handoffConsumeTasks[operationID] = task
    }

    /// Cancels and invalidates every previously accepted incoming handoff. The retained tasks remain
    /// owned until they actually return; their late results fail the identity check.
    private func supersedeIncomingHandoffConsumptions() {
        handoffIngressGeneration &+= 1
        for task in handoffConsumeTasks.values {
            task.cancel()
        }
    }

    private func performIncomingHandoffConsumption(
        from deepLinkURL: URL,
        manager: any StudioHandoffManaging,
        ingressGeneration: UInt64
    ) async {
        do {
            let payload = try await manager.consumeIncomingHandoff(from: deepLinkURL)

            // Revalidate after the consume await before setting any handoff state.
            guard ingressGeneration == handoffIngressGeneration, !Task.isCancelled else { return }

            // Reserve the ingest identity synchronously so this payload cannot go through a public
            // ingest that would bump the generation and supersede a newer handoff.
            let generation = reserveIngestGeneration()
            let fileURL = URL(fileURLWithPath: payload.imageFileURLPath)
            await enqueueIngest(at: fileURL, sessionGeneration: generation, handoff: payload)
        } catch {
            guard ingressGeneration == handoffIngressGeneration else { return }
            if error is CancellationError { return }
            Diagnostics.shared.recordError(
                error,
                category: .app,
                code: "handoff.incoming.failed",
                context: ["operation": "incoming_handoff"]
            )
            self.errorMessage = error.localizedDescription
        }
    }

    public func resetSession() {
        guard resetTask == nil else { return }
        supersedeIncomingHandoffConsumptions()
        sessionGeneration &+= 1
        let resetGeneration = sessionGeneration
        wakeBatchForegroundWaiters()
        jobGeneration &+= 1
        stopRequestedForJobGeneration = nil
        isStopping = true

        let previous = sourceSession
        sourceSession = nil
        let pipeline = self.pipeline

        let task = Task { @MainActor [weak self] in
            // Captured old-selection cleanup is unconditional and exactly-once on every exit: a newer
            // ingest superseding this reset must not leak A's grant, and the newer selection is never
            // touched because only the captured `previous` session is released here.
            defer { previous?.markReleaseRequested() }
            guard let self else { return }
            // Keep the owner/activeTask until pause + cancellation actually drain.
            await pipeline.requestGracefulPauseAndWait()
            await self.drainExecutionForSessionChange(waitForReset: false)
            if self.resetTask != nil, self.resetTaskGeneration == resetGeneration {
                self.resetTask = nil
                self.resetTaskGeneration = nil
            }
            // A newer ingest/reset owns the state now; do not publish stale teardown.
            guard resetGeneration == self.sessionGeneration else { return }
            self.displayedInputURL = nil
            self.viewerInputURL = nil
            self.selectedOutputItem = nil
            self.sourceURL = nil
            self.displayedOutputRecord = nil
            self.displayedLegacyOutput = false
            self.comparisonUnavailableReason = nil
            self.replaceResultContext(nil, selection: nil)
            self.metadata = nil
            self.sourceBuffer = nil
            self.outputBuffer = nil
            self.completedArtifacts = nil
            self.completedArtifactsGeneration = nil
            self.completedTiles = 0
            self.totalTiles = 0
            self.latestProgress = nil
            self.activeJobID = nil
            self.terminalProgressGeneration = nil
            self.processingElapsedSeconds = 0
            self.currentStage = .idle
            self.isProcessing = false
            self.isStopping = false
            self.stopProgressTimer()
        }
        resetTask = task
        resetTaskGeneration = resetGeneration
    }

    private func releaseSourceLease() {
        sourceSession?.markReleaseRequested()
        sourceSession = nil
    }

    // MARK: - Scene phase routing

    /// Routes `scenePhase` through the coordinator (compute-tier switch, continued-processing
    /// submission, legacy assertion balance, Live Activity), not just the executor flag.
    public func handleScenePhaseChange(_ phase: ScenePhase) async {
        latestScenePhase = phase
        isBatchForegroundReady = false
        if phase == .active { foregroundSceneGeneration &+= 1 }
        let sceneGeneration = foregroundSceneGeneration
        let selectionGeneration = sessionGeneration
        let owner = executionOwner
        let jobID = activeJobID
        Diagnostics.shared.record(category: .background, level: .notice,
            code: "app.scene", message: "scene changed",
            fields: ["phase": String(describing: phase), "correlationID": activeJobID?.uuidString ?? "none"])
        let title = "TruongScaler · \(scaleFactor.rawValue)×"
        let subtitle = "\(backbone.displayName) · \(selectedScaleFactor.rawValue)×"
        switch phase {
        case .active:
            await backgroundCoordinator.handleDidBecomeActive()
            if latestScenePhase == .active, foregroundSceneGeneration == sceneGeneration {
                isBatchForegroundReady = true
                wakeBatchForegroundWaiters()
            }
        case .inactive:
            await backgroundCoordinator.handleWillResignActive(jobTitle: title, jobSubtitle: subtitle)
        case .background:
            await backgroundCoordinator.handleDidEnterBackground(jobTitle: title, jobSubtitle: subtitle)
        @unknown default:
            await backgroundCoordinator.handleDidEnterBackground(jobTitle: title, jobSubtitle: subtitle)
        }

        // A diagnostic can outlive its job and the scene hop itself can suspend. Only the still
        // running selection may receive its notice; idle photos and a newer foreground state own
        // their own errors. Inactive/background are one cycle, so either may report its refusal.
        guard phase != .active, let owner, let jobID,
              isCurrentSchedulingNotice(owner: owner, jobID: jobID,
                selectionGeneration: selectionGeneration, sceneGeneration: sceneGeneration),
              let schedulingError = await backgroundCoordinator.schedulingError(for: jobID),
              isCurrentSchedulingNotice(owner: owner, jobID: jobID,
                selectionGeneration: selectionGeneration, sceneGeneration: sceneGeneration) else { return }
        errorMessage = "Background processing unavailable: \(schedulingError)"
    }

    private func isCurrentSchedulingNotice(owner: ExecutionOwner, jobID: UUID,
        selectionGeneration: UInt64, sceneGeneration: UInt64) -> Bool {
        !Task.isCancelled && isProcessing && !owner.stopRequested
            && isCurrentExecution(owner) && activeCoordinatorGeneration == owner.generation
            && activeJobID == jobID && sessionGeneration == selectionGeneration
            && foregroundSceneGeneration == sceneGeneration
    }

    // MARK: - Internal ownership helpers (test observability)

    /// True while an ingest operation is still owned/draining.
    var hasActiveIngestOperations: Bool { !ingestTasks.isEmpty }
    /// True while an accepted incoming-handoff consume/ingest chain is still owned/draining.
    var hasActiveHandoffConsumptions: Bool { !handoffConsumeTasks.isEmpty }
    /// Current incoming-handoff ingress identity for race assertions.
    var currentHandoffIngressGeneration: UInt64 { handoffIngressGeneration }
    /// Number of owned library operations currently reading the selected folder.
    var activeLibraryOperationCount: Int { libraryOperationCount }
    /// True while an export operation is still owned/draining.
    var hasActiveExportOperations: Bool { !exportTasks.isEmpty }
    /// Number of owned execution runs (0 or 1 because execution is serialized).
    var ownedExecutionCount: Int { executionOwner == nil ? 0 : 1 }
    /// True while a reset teardown is still draining.
    var isResetting: Bool { resetTask != nil }
    /// Current source/folder scope generations for race assertions.
    var currentSessionGeneration: UInt64 { sessionGeneration }
    var currentJobGeneration: UInt64 { jobGeneration }
    var currentLibraryGeneration: UInt64 { libraryGeneration }
    /// Current completed-artifact identity generation.
    var currentArtifactGeneration: UInt64? { completedArtifactsGeneration }

    /// Waits for the latest Stop drain to finish (test helper).
    func waitForStopToFinish() async {
        await stoppingTask?.value
    }

    /// Waits for the latest reset teardown to finish (test helper).
    func waitForResetToFinish() async {
        await resetTask?.value
    }

    /// Waits for every currently-owned ingress operation (including handoff consumption that may
    /// spawn a reserved ingest) to finish (test helper).
    func waitForIngestTasksToFinish() async {
        while true {
            let handoffTasks = Array(handoffConsumeTasks.values)
            let ingestTasks = Array(ingestTasks.values)
            if handoffTasks.isEmpty, ingestTasks.isEmpty { return }
            for task in handoffTasks { await task.value }
            for task in ingestTasks { await task.value }
        }
    }

    /// Waits for every accepted incoming handoff to drain (test helper).
    func waitForHandoffConsumptionsToFinish() async {
        while true {
            let tasks = Array(handoffConsumeTasks.values)
            if tasks.isEmpty { return }
            for task in tasks { await task.value }
        }
    }

    /// Waits for all currently-owned export tasks to finish (test helper).
    func waitForExportTasksToFinish() async {
        for task in exportTasks.values { await task.value }
    }

    private func waitForExecutionToSettle() async {
        if let stoppingTask { await stoppingTask.value }
        if let executionOwner { await executionOwner.task?.value }
    }
}

extension StudioViewModel {
    public var canManageOutput: Bool {
        outputSession != nil && !isBatchProcessing && !isProcessing && !isStopping && resetTask == nil && !isSavingResult && exportTasks.isEmpty && !isManagingOutput
            && !isPreparingShare && shareSession == nil && dismissedShareSessions.isEmpty
            && currentStage != .ingestingAndDecodingStrips
    }
    public var canTrashDisplayedOutput: Bool {
        canManageOutput && resultSelection === outputSession && ((displayedOutputRecord ?? publishedCurrentResult) != nil || displayedLegacyOutput)
    }
    public func trashRequest(ids: Set<String>) -> OutputManagementRequest? {
        guard canManageOutput, selectedCollection == .output, let selection = outputSession else { return nil }
        let items = outputDaySections.flatMap(\.items).filter { ids.contains($0.id) }
        let records = items.compactMap { outputRecord(at: $0.fileURL, under: selection.url) }
        let legacy = items.filter { legacyOutputPaths.contains($0.fileURL.standardizedFileURL) }.map(\.fileURL)
        guard !records.isEmpty || !legacy.isEmpty else { return nil }
        return OutputManagementRequest(generation: outputGeneration, root: selection.url, records: records, legacyURLs: legacy)
    }
    public func displayedTrashRequest() -> OutputManagementRequest? {
        guard canTrashDisplayedOutput, let selection = outputSession else { return nil }
        if let record = displayedOutputRecord ?? publishedCurrentResult {
            return OutputManagementRequest(generation: outputGeneration, root: selection.url, records: [record], legacyURLs: [])
        }
        guard displayedLegacyOutput, let sourceURL, legacyOutputPaths.contains(sourceURL.standardizedFileURL) else { return nil }
        return OutputManagementRequest(generation: outputGeneration, root: selection.url, records: [], legacyURLs: [sourceURL])
    }
    public func trashOutputs(_ request: OutputManagementRequest) async {
        guard canManageOutput, let selection = outputSession, request.generation == outputGeneration,
              request.root == selection.url else { errorMessage = "The output folder changed. Select the photos again."; return }
        isManagingOutput = true
        selection.activeOperations += 1
        let grant = scopeProvider.openGrant(for: selection.url)
        defer { grant.release(); selection.activeOperations -= 1; selection.releaseIfDrained(); isManagingOutput = false }
        let displayedRecordURL = (displayedOutputRecord ?? publishedCurrentResult).map {
            selection.url.appendingPathComponent($0.outputRelativePath).standardizedFileURL
        }
        let displayedURL = sourceURL
        let operationSession = sessionGeneration
        let next = outputDaySections.flatMap(\.items).first { item in
            !request.legacyURLs.contains(item.fileURL) && !request.records.contains { selection.url.appendingPathComponent($0.outputRelativePath) == item.fileURL }
        }
        var failure: String?
        do {
            for record in request.records { try await resultStore.trash(record: record, under: selection.url) }
            for url in request.legacyURLs { try await resultStore.trashLegacy(at: url, under: selection.url) }
        } catch { failure = "Some photos could not be moved to Recently Deleted: " + error.localizedDescription }
        if sessionGeneration == operationSession, outputSession === selection, outputGeneration == request.generation {
            errorMessage = failure
        }
        await reloadOutputFolder()
        guard sessionGeneration == operationSession, outputSession === selection, outputGeneration == request.generation else {
            await reloadRecentlyDeleted()
            return
        }
        // Partial batches leave completed moves in trash; reconcile the currently displayed result.
        let removed = resultSelection === selection && (displayedRecordURL.map { outputRecordsByURL[$0] == nil } ?? (displayedLegacyOutput && displayedURL.map { !legacyOutputPaths.contains($0) } == true))
        var noticeGeneration: UInt64? = operationSession
        if removed {
            if let next { noticeGeneration = await openOutputOrInputPhoto(next) ?? operationSession }
            else { resetSession(); noticeGeneration = sessionGeneration }
        }
        await reloadRecentlyDeleted()
        // Opening the survivor clears ordinary photo errors. Preserve this operation's partial
        // failure only if its own follow-up selection still owns the viewer after all awaits.
        if let failure, noticeGeneration == sessionGeneration, outputSession === selection, outputGeneration == request.generation {
            if let current = errorMessage, current != failure { errorMessage = failure + "\n" + current }
            else { errorMessage = failure }
        }
    }
    public func reloadRecentlyDeleted() async {
        guard let selection = outputSession else { recentlyDeleted = []; return }
        selection.activeOperations += 1
        let grant = scopeProvider.openGrant(for: selection.url)
        defer { grant.release(); selection.activeOperations -= 1; selection.releaseIfDrained() }
        do {
            let entries = try await resultStore.trashed(under: selection.url)
            guard outputSession === selection else { return }
            recentlyDeleted = entries
        } catch { if outputSession === selection { errorMessage = error.localizedDescription } }
    }
    public func trashManagementRequest(ids: Set<UUID>, permanent: Bool) -> TrashManagementRequest? {
        guard canManageOutput, let selection = outputSession else { return nil }
        let entries = recentlyDeleted.filter { ids.contains($0.id) }
        guard !entries.isEmpty, permanent || entries.allSatisfy(\.canRestore) else { return nil }
        return TrashManagementRequest(generation: outputGeneration, root: selection.url, entries: entries, permanent: permanent)
    }
    public func manageTrash(_ request: TrashManagementRequest) async {
        guard canManageOutput, let selection = outputSession, outputGeneration == request.generation,
              selection.url == request.root else { errorMessage = "The output folder changed. Select the photos again."; return }
        isManagingOutput = true
        selection.activeOperations += 1
        let grant = scopeProvider.openGrant(for: selection.url)
        defer { grant.release(); selection.activeOperations -= 1; selection.releaseIfDrained(); isManagingOutput = false }
        let operationSession = sessionGeneration
        var failure: String?
        do {
            for entry in request.entries {
                if request.permanent { try await resultStore.permanentlyDelete(entry, under: selection.url) }
                else { try await resultStore.restore(entry, under: selection.url) }
            }
        } catch { failure = "The operation could not finish. Remaining photos were kept: " + error.localizedDescription }
        // A direct import or incoming handoff can supersede the viewer while filesystem work
        // drains. Its notice belongs to that newer photo, even though this root's list still reloads.
        if sessionGeneration == operationSession, outputSession === selection, outputGeneration == request.generation {
            errorMessage = failure
        }
        await reloadRecentlyDeleted()
        await reloadOutputFolder()
    }
}

extension StudioViewModel {
    func loadTrashThumbnail(_ entry: OutputTrashEntry, maxPixelSize: Int) async -> CGImage? {
        guard let selection = outputSession, recentlyDeleted.contains(entry) else { return nil }
        selection.activeOperations += 1
        let grant = scopeProvider.openGrant(for: selection.url)
        defer { grant.release(); selection.activeOperations -= 1; selection.releaseIfDrained() }
        guard let url = try? await resultStore.trashPreviewURL(entry, under: selection.url),
              let image = await thumbnailReader.readThumbnail(at: url, maxPixelSize: maxPixelSize),
              outputSession === selection, !Task.isCancelled, recentlyDeleted.contains(entry) else { return nil }
        return image
    }
}

extension StudioViewModel {
    var outputBrowsingContext: String { "\(outputGeneration)|" + (outputFolderURL?.absoluteString ?? "none") }
    var gallerySelectionContext: String { selectedCollection == .input ? inputBrowsingContext : outputBrowsingContext }
    var inputBrowsingContext: String { "\(libraryGeneration)|\(inputContentRevision)|" + (libraryFolderURL?.absoluteString ?? "single-file") }
    func loadInputDisplayPreview(at url: URL) async -> CGImage? {
        let root = librarySession
        let generation = libraryGeneration
        root?.activeOperations += 1
        let grants = [url, root?.url].compactMap { $0 }.map { scopeProvider.openGrant(for: $0) }
        defer { grants.forEach { $0.release() }; root?.activeOperations -= 1; root?.releaseIfDrained() }
        let image = await displayPreviewReader.readThumbnail(at: url, maxPixelSize: 2048)
        guard !Task.isCancelled, generation == libraryGeneration, librarySession === root else { return nil }
        return image
    }
}
