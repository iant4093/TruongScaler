import XCTest
import Foundation
import Darwin
import TruongScalerCore
import MMapCanvas
import CoreIngestion
import TiledInferenceEngine
import BackgroundJobManager
@testable import DeepZoomGalleryUI

/// Controlled security-scope boundary shared by the fake grant provider and fake folder I/O.
/// The I/O fake refuses validation unless this boundary has an open grant, which deterministically
/// models a provider whose filesystem becomes readable only after `startAccessing...`.
final class ScopeBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var opens = 0
    private var closes = 0
    private var peak = 0

    func opened() {
        lock.lock()
        active += 1
        opens += 1
        peak = max(peak, active)
        lock.unlock()
    }

    func closed() {
        lock.lock()
        active = max(0, active - 1)
        closes += 1
        lock.unlock()
    }

    var activeCount: Int { lock.lock(); defer { lock.unlock() }; return active }
    var openCount: Int { lock.lock(); defer { lock.unlock() }; return opens }
    var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }
    var peakActiveCount: Int { lock.lock(); defer { lock.unlock() }; return peak }
}

/// Small thread-safe flag for MainActor-liveness assertions.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Scope provider whose grants toggle the shared boundary and record exactly-once releases.
final class BoundaryScopeProvider: SecurityScopeGrantProviding, @unchecked Sendable {
    final class Grant: SecurityScopeGrant, @unchecked Sendable {
        let url: URL
        private let boundary: ScopeBoundary
        private let lock = NSLock()
        private var released = false
        private var releaseCalls = 0

        init(url: URL, boundary: ScopeBoundary) {
            self.url = url
            self.boundary = boundary
            boundary.opened()
        }

        func release() {
            lock.lock()
            let shouldRelease = !released
            released = true
            releaseCalls += 1
            lock.unlock()
            guard shouldRelease else { return }
            boundary.closed()
        }

        var releaseCallCount: Int { lock.lock(); defer { lock.unlock() }; return releaseCalls }
        var isReleased: Bool { lock.lock(); defer { lock.unlock() }; return released }
    }

    let boundary: ScopeBoundary
    private let lock = NSLock()
    private var storage: [Grant] = []

    init(boundary: ScopeBoundary) {
        self.boundary = boundary
    }

    func openGrant(for url: URL) -> any SecurityScopeGrant {
        let grant = Grant(url: url, boundary: boundary)
        lock.lock()
        storage.append(grant)
        lock.unlock()
        return grant
    }

    var grants: [Grant] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Fake folder I/O that models a sandboxed external provider:
/// * `validateFolder` records whether the scope boundary was active and whether it ran on MainActor;
/// * it refuses validation unless the boundary is active (so validation before grant acquisition
///   deterministically fails);
/// * optional gates suspend resolution/validation to prove MainActor liveness and stale-race rules.
final class BoundaryLibraryFolderIO: LibraryFolderIO, @unchecked Sendable {
    struct ProbeRecord: Sendable {
        let url: URL
        let scopeActive: Bool
        let onMainActor: Bool
    }

    let boundary: ScopeBoundary
    var resolvedURL: URL
    var resolutionError: LibraryFolderIOError?
    var bookmarkData: Data?
    var resolutionGate: CancellableGate?
    var classificationGate: CancellableGate?
    var bookmarkGate: CancellableGate?
    var resolutionFailure = false
    let resolutionEntered = TestSignal()
    let classificationEntered = TestSignal()
    let bookmarkEntered = TestSignal()
    var denyValidation = false
    var denyValidationFor: Set<String> = []
    var classificationResult: ImportedURLCategory?

    private let lock = NSLock()
    private var validationGates: [String: CancellableGate] = [:]
    private var enteredSignals: [String: TestSignal] = [:]
    private var bookmarkGates: [String: CancellableGate] = [:]
    private var probes: [ProbeRecord] = []
    private var classificationProbes: [ProbeRecord] = []
    private var bookmarkCreationCalls = 0
    private var resolutionEntries = 0

    init(boundary: ScopeBoundary, resolvedURL: URL) {
        self.boundary = boundary
        self.resolvedURL = resolvedURL
    }

    static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    func gateValidation(for url: URL, gate: CancellableGate) {
        lock.lock()
        validationGates[Self.key(url)] = gate
        lock.unlock()
    }

    func gateBookmark(for url: URL, gate: CancellableGate) {
        lock.lock()
        bookmarkGates[Self.key(url)] = gate
        lock.unlock()
    }

    func signalWhenValidationEntered(for url: URL) -> TestSignal {
        lock.lock()
        if let existing = enteredSignals[Self.key(url)] {
            lock.unlock()
            return existing
        }
        let signal = TestSignal()
        enteredSignals[Self.key(url)] = signal
        lock.unlock()
        return signal
    }

    var validationRecords: [ProbeRecord] { lock.lock(); defer { lock.unlock() }; return probes }
    var classificationRecords: [ProbeRecord] { lock.lock(); defer { lock.unlock() }; return classificationProbes }
    var createBookmarkCallCount: Int { lock.lock(); defer { lock.unlock() }; return bookmarkCreationCalls }
    var resolutionCallCount: Int { lock.lock(); defer { lock.unlock() }; return resolutionEntries }

    func resolveBookmark(_ data: Data) async -> Result<ResolvedLibraryFolder, LibraryFolderIOError> {
        _ = data
        let gate = lock.withLock {
            resolutionEntries += 1
            return resolutionGate
        }
        resolutionEntered.signal()
        if let gate { await gate.wait() }
        if resolutionFailure {
            return .failure(LibraryFolderIOError(message: "controlled old failure"))
        }
        if let resolutionError {
            return .failure(resolutionError)
        }
        return .success(ResolvedLibraryFolder(url: resolvedURL, isStale: false))
    }

    func createBookmark(for url: URL) async -> Data? {
        _ = url
        let key = Self.key(url)
        let (data, gate) = lock.withLock {
            bookmarkCreationCalls += 1
            return (bookmarkData, bookmarkGates[key] ?? bookmarkGate)
        }
        bookmarkEntered.signal()
        if let gate { await gate.wait() }
        return data ?? Data(url.path.utf8)
    }

    func classifyImportedURL(at url: URL) async -> ImportedURLCategory {
        let record = ProbeRecord(
            url: url,
            scopeActive: boundary.activeCount > 0,
            onMainActor: pthread_main_np() != 0
        )
        let (override, gate) = lock.withLock { () -> (ImportedURLCategory?, CancellableGate?) in
            classificationProbes.append(record)
            return (classificationResult, classificationGate)
        }
        classificationEntered.signal()
        if let gate { await gate.wait() }
        guard record.scopeActive else {
            return .unavailable(reason: "Sandbox denied before the classification grant was opened.")
        }
        if let override { return override }
        return .directory(scanRoot: url)
    }

    func validateFolder(at url: URL) async -> LibraryFolderValidation {
        let key = Self.key(url)
        let (gate, signal, deny) = lock.withLock {
            (validationGates[key], enteredSignals[key], denyValidation || denyValidationFor.contains(key))
        }

        let record = ProbeRecord(
            url: url,
            scopeActive: boundary.activeCount > 0,
            onMainActor: pthread_main_np() != 0
        )
        lock.withLock { probes.append(record) }
        signal?.signal()

        if let gate { await gate.wait() }

        guard !deny, record.scopeActive else {
            return .unavailable(reason: "Sandbox denied before the validation grant was opened.")
        }
        return .available(scanRoot: url)
    }
}

final class LibraryFolderAccessBoundaryTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFolderAccessBoundaryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        suiteName = "com.truongscaler.tests.scope.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        defaults = nil
        suiteName = nil
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeFolder(_ name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func makeViewModel(
        scopeProvider: BoundaryScopeProvider,
        folderIO: BoundaryLibraryFolderIO,
        scanner: any StudioLibraryScanning = FakeScanner()
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
            pipeline: FakePipelineExecutor(directory: tempDirectory),
            decoder: FakeDecoder(),
            exporter: FakeExporter(),
            scanner: scanner,
            thumbnailReader: ImageIOThumbnailReader(),
            handoffManager: FakeHandoffManager(),
            externalOpener: RecordingOpener(),
            scopeProvider: scopeProvider,
            backgroundTaskRouter: BackgroundTaskDeliveryRouter(),
            defaults: defaults,
            folderIO: folderIO
        )
    }

    @MainActor
    private func saveBookmarkData(_ data: Data = Data([1, 2, 3])) {
        defaults.set(data, forKey: StudioViewModel.bookmarkDefaultsKey)
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 5.0,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - F1: grant-before-access boundary

    @MainActor
    func testRestoreOpensValidationGrantBeforeFirstProbeAndBalancesIt() async throws {
        let folder = try makeFolder("saved-external")
        saveBookmarkData()
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: folder)
        let viewModel = makeViewModel(scopeProvider: provider, folderIO: io)

        viewModel.restoreLibraryBookmarkIfAvailable()
        let loaded = await waitUntil { viewModel.libraryFolderURL != nil }
        XCTAssertTrue(loaded)

        let probes = io.validationRecords
        XCTAssertEqual(probes.count, 1)
        XCTAssertEqual(probes.first?.scopeActive, true, "The first validation probe must run with the scope grant open")
        XCTAssertEqual(probes.first?.onMainActor, false, "Validation belongs off MainActor")
        XCTAssertGreaterThanOrEqual(boundary.peakActiveCount, 1)

        // Validation grant, selected-session grant, and scan-operation grant. The validation and
        // scan operation grants are balanced; only the selected session remains active.
        XCTAssertEqual(provider.grants.count, 3)
        XCTAssertEqual(provider.grants[0].releaseCallCount, 1, "Validation grant is released exactly once")
        XCTAssertTrue(provider.grants[0].isReleased)
        XCTAssertEqual(provider.grants[1].releaseCallCount, 0, "Selected session grant stays active")
        XCTAssertEqual(provider.grants[2].releaseCallCount, 1, "Scan operation grant is balanced")
        XCTAssertEqual(boundary.activeCount, 1)
        XCTAssertNotNil(defaults.data(forKey: StudioViewModel.bookmarkDefaultsKey))

        viewModel.releaseLibraryFolder()
        XCTAssertEqual(provider.grants[1].releaseCallCount, 1)
        XCTAssertEqual(boundary.activeCount, 0)
        XCTAssertNil(defaults.data(forKey: StudioViewModel.bookmarkDefaultsKey))
    }

    @MainActor
    func testPickedFolderClassifiesUnderGrantBeforeApplying() async throws {
        let folder = try makeFolder("picked-folder")
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: folder)
        let viewModel = makeViewModel(scopeProvider: provider, folderIO: io)

        let openedAsFile = await viewModel.handlePickedURL(folder)
        XCTAssertFalse(openedAsFile)
        XCTAssertEqual(viewModel.libraryFolderURL?.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertNil(viewModel.savedLibraryRecoveryMessage)

        XCTAssertEqual(io.classificationRecords.count, 1)
        XCTAssertEqual(io.classificationRecords.first?.scopeActive, true)
        XCTAssertEqual(io.classificationRecords.first?.onMainActor, false)
        // Classification grant + selected-session grant + scan-operation grant.
        XCTAssertEqual(provider.grants.count, 3)
        XCTAssertEqual(provider.grants[0].releaseCallCount, 1)
        XCTAssertEqual(provider.grants[1].releaseCallCount, 0)
        XCTAssertEqual(provider.grants[2].releaseCallCount, 1)
        XCTAssertEqual(boundary.activeCount, 1)
    }

    func testInternalFolderValidationNeedsNoActiveExternalScope() async throws {
        let folder = try makeFolder("internal-folder")
        let validator = BlockingLibraryFolderIO()

        // A task-owned/app-container folder is readable even when startAccessing... is false.
        let result = await validator.validateFolder(at: folder)
        XCTAssertEqual(result, .available(scanRoot: folder))

        let missing = tempDirectory.appendingPathComponent("does-not-exist", isDirectory: true)
        let missingResult = await validator.validateFolder(at: missing)
        if case .available = missingResult {
            XCTFail("A missing folder must not validate as available")
        }
    }

    // MARK: - F2: off-main liveness

    @MainActor
    func testRestoreValidationIsOffMainAndMainActorRemainsResponsive() async throws {
        let folder = try makeFolder("slow-provider")
        saveBookmarkData()
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: folder)
        let gate = CancellableGate()
        io.gateValidation(for: folder, gate: gate)
        let enteredSignal = io.signalWhenValidationEntered(for: folder)
        let viewModel = makeViewModel(scopeProvider: provider, folderIO: io)

        viewModel.restoreLibraryBookmarkIfAvailable()
        await enteredSignal.wait()
        XCTAssertEqual(viewModel.isValidatingLibraryFolder, true)
        XCTAssertEqual(io.validationRecords.first?.onMainActor, false)

        // The MainActor is free while the off-main validation is suspended.
        let marker = AtomicFlag()
        Task { @MainActor in marker.set() }
        let responsive = await waitUntil { marker.isSet }
        XCTAssertTrue(responsive, "MainActor/UI must remain responsive while folder validation is outstanding")
        XCTAssertNil(viewModel.libraryFolderURL, "Restoration must not publish before validation drains")

        gate.open()
        let loaded = await waitUntil { viewModel.libraryFolderURL != nil }
        XCTAssertTrue(loaded)
        XCTAssertEqual(viewModel.isValidatingLibraryFolder, false)
        XCTAssertEqual(provider.grants.first?.releaseCallCount, 1)
    }

    // MARK: - Stale restore / newer user action

    @MainActor
    func testNewerUserSelectionWinsWhileRestoreValidationPending() async throws {
        let savedFolder = try makeFolder("saved-a")
        let chosenFolder = try makeFolder("chosen-b")
        saveBookmarkData()
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: savedFolder)
        let gate = CancellableGate()
        io.gateValidation(for: savedFolder, gate: gate)
        let entered = io.signalWhenValidationEntered(for: savedFolder)
        let viewModel = makeViewModel(scopeProvider: provider, folderIO: io)

        viewModel.restoreLibraryBookmarkIfAvailable()
        await entered.wait()

        await viewModel.setLibraryFolder(url: chosenFolder)
        XCTAssertEqual(viewModel.libraryFolderURL?.standardizedFileURL, chosenFolder.standardizedFileURL)

        gate.open()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(viewModel.libraryFolderURL?.standardizedFileURL, chosenFolder.standardizedFileURL)
        XCTAssertNil(viewModel.savedLibraryRecoveryMessage)
        XCTAssertFalse(viewModel.isValidatingLibraryFolder)
        XCTAssertEqual(provider.grants[0].releaseCallCount, 1)
    }

    @MainActor
    func testStaleRestoreFailureDoesNotOverwriteNewerSelection() async throws {
        let savedFolder = try makeFolder("stale-saved")
        let chosenFolder = try makeFolder("new-chosen")
        saveBookmarkData()
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: savedFolder)
        io.denyValidationFor.insert(BoundaryLibraryFolderIO.key(savedFolder))
        let gate = CancellableGate()
        io.gateValidation(for: savedFolder, gate: gate)
        let entered = io.signalWhenValidationEntered(for: savedFolder)
        let viewModel = makeViewModel(scopeProvider: provider, folderIO: io)

        viewModel.restoreLibraryBookmarkIfAvailable()
        await entered.wait()
        await viewModel.setLibraryFolder(url: chosenFolder)
        XCTAssertEqual(viewModel.libraryFolderURL?.standardizedFileURL, chosenFolder.standardizedFileURL)

        gate.open()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(viewModel.libraryFolderURL?.standardizedFileURL, chosenFolder.standardizedFileURL)
        XCTAssertNil(viewModel.savedLibraryRecoveryMessage)
        XCTAssertEqual(viewModel.libraryStatusLine, "Library ready")
    }

    @MainActor
    func testPendingRestoreCannotPublishAfterReconnectStarts() async throws {
        let savedFolder = try makeFolder("restore-a")
        let reconnectFolder = try makeFolder("reconnect-b")
        saveBookmarkData()
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: savedFolder)
        let gate = CancellableGate()
        io.gateValidation(for: savedFolder, gate: gate)
        let entered = io.signalWhenValidationEntered(for: savedFolder)
        let viewModel = makeViewModel(scopeProvider: provider, folderIO: io)

        viewModel.restoreLibraryBookmarkIfAvailable()
        await entered.wait()

        // The explicit reconnect resolves a different folder and publishes it while the stale
        // restore validation is still suspended. The stale restore must not publish over it.
        io.resolvedURL = reconnectFolder
        let reconnect = Task { await viewModel.reconnectSavedLibraryFolder() }
        let reconnected = await waitUntil { viewModel.libraryFolderURL != nil }
        XCTAssertTrue(reconnected)
        XCTAssertEqual(viewModel.libraryFolderURL?.standardizedFileURL, reconnectFolder.standardizedFileURL)

        gate.open()
        await reconnect.value
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(viewModel.libraryFolderURL?.standardizedFileURL, reconnectFolder.standardizedFileURL)
        XCTAssertNil(viewModel.savedLibraryRecoveryMessage)
    }

    @MainActor
    func testExplicitReleaseWhileRestorePendingDoesNotResurrect() async throws {
        let folder = try makeFolder("release-pending")
        saveBookmarkData()
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: folder)
        let gate = CancellableGate()
        io.gateValidation(for: folder, gate: gate)
        let entered = io.signalWhenValidationEntered(for: folder)
        let viewModel = makeViewModel(scopeProvider: provider, folderIO: io)

        viewModel.restoreLibraryBookmarkIfAvailable()
        await entered.wait()
        viewModel.releaseLibraryFolder()
        XCTAssertNil(defaults.data(forKey: StudioViewModel.bookmarkDefaultsKey))

        gate.open()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(viewModel.libraryFolderURL)
        XCTAssertNil(viewModel.savedLibraryRecoveryMessage)
        XCTAssertFalse(viewModel.isValidatingLibraryFolder)
        XCTAssertEqual(provider.grants[0].releaseCallCount, 1)
        XCTAssertEqual(boundary.activeCount, 0)
    }

    @MainActor
    func testReconnectResolutionPendingNewerSelectionWins() async throws {
        let savedFolder = try makeFolder("old-reconnect")
        let chosenFolder = try makeFolder("new-selection")
        saveBookmarkData()
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: savedFolder)
        let gate = CancellableGate()
        io.resolutionGate = gate
        let viewModel = makeViewModel(scopeProvider: provider, folderIO: io)

        let reconnect = Task { await viewModel.reconnectSavedLibraryFolder() }
        // Resolution is gated; let the reconnect reach the off-main await before selecting another.
        let entered = await waitUntil { io.resolutionCallCount == 1 }
        XCTAssertTrue(entered)
        await viewModel.setLibraryFolder(url: chosenFolder)
        gate.open()
        await reconnect.value

        XCTAssertEqual(viewModel.libraryFolderURL?.standardizedFileURL, chosenFolder.standardizedFileURL)
        XCTAssertNil(viewModel.savedLibraryRecoveryMessage)
    }

    @MainActor
    func testCancelledSelectionValidationBalancesGrantAndDoesNotPublish() async throws {
        let folder = try makeFolder("cancelled")
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: folder)
        let gate = CancellableGate()
        io.gateValidation(for: folder, gate: gate)
        let entered = io.signalWhenValidationEntered(for: folder)
        let viewModel = makeViewModel(scopeProvider: provider, folderIO: io)

        let selection = Task { await viewModel.setLibraryFolder(url: folder) }
        await entered.wait()
        selection.cancel()
        await selection.value

        XCTAssertNil(viewModel.libraryFolderURL)
        XCTAssertFalse(viewModel.isValidatingLibraryFolder)
        XCTAssertEqual(provider.grants.count, 1, "No session/bookmark/scan work for a cancelled validation")
        XCTAssertEqual(provider.grants[0].releaseCallCount, 1)
        XCTAssertEqual(boundary.activeCount, 0)
        XCTAssertEqual(io.createBookmarkCallCount, 0)
        XCTAssertNil(defaults.data(forKey: StudioViewModel.bookmarkDefaultsKey))
    }

    @MainActor
    func testDeniedValidationPreservesBookmarkAndBalancesGrant() async throws {
        let folder = try makeFolder("denied")
        saveBookmarkData()
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: folder)
        io.denyValidation = true
        let viewModel = makeViewModel(scopeProvider: provider, folderIO: io)

        viewModel.restoreLibraryBookmarkIfAvailable()
        let failed = await waitUntil { viewModel.savedLibraryRecoveryMessage != nil }
        XCTAssertTrue(failed)
        XCTAssertNil(viewModel.libraryFolderURL)
        XCTAssertFalse(viewModel.isValidatingLibraryFolder)
        XCTAssertNotNil(defaults.data(forKey: StudioViewModel.bookmarkDefaultsKey), "A true failure must retain the saved selection")
        XCTAssertEqual(provider.grants.count, 1)
        XCTAssertEqual(provider.grants[0].releaseCallCount, 1)
        XCTAssertEqual(boundary.activeCount, 0)
    }
}
