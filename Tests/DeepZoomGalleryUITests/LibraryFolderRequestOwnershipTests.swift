import XCTest
import Foundation
import TruongScalerCore
import MMapCanvas
import CoreIngestion
import TiledInferenceEngine
import BackgroundJobManager
@testable import DeepZoomGalleryUI

/// Permanent request-ownership/cancellation regressions for the asynchronous folder paths.
///
/// Each test drives the real `StudioViewModel` restore/reconnect/picker/selection orchestration
/// through the injected `LibraryFolderIO` seam and asserts the winning folder, exact saved bookmark,
/// checking/recovery state and exactly-once scope grants. These are controlled timing tests, not
/// physical File Provider/sandbox evidence.
final class LibraryFolderRequestOwnershipTests: XCTestCase {
    private static let bookmarkKey = "com.truongscaler.library.rootBookmark"
    private var tempDirectory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFolderRequestOwnershipTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        suiteName = "com.truongscaler.tests.request.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(Data([1, 2, 3]), forKey: Self.bookmarkKey)
    }

    override func tearDownWithError() throws {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        defaults = nil
        suiteName = nil
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        tempDirectory = nil
        try super.tearDownWithError()
    }

    @MainActor
    private func makeFolder(_ name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func makeViewModel(
        scopeProvider: BoundaryScopeProvider,
        folderIO: BoundaryLibraryFolderIO,
        scanner: any StudioLibraryScanning = FakeScanner(),
        resultStore: ProcessedLibraryStore = ProcessedLibraryStore()
    ) -> StudioViewModel {
        let executor = TiledPipelineExecutor(
            workingDirectory: tempDirectory,
            modelRegistry: CoreMLModelRegistry(initialComputeUnits: .all),
            checkpointStore: JobCheckpointStore(directory: tempDirectory)
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
            folderIO: folderIO,
            resultStore: resultStore
        )
    }

    @MainActor
    func testInputRootChangeRemovesOldPhotosBeforeBookmarkAndScanDrain() async throws {
        let first = try makeFolder("input-before-switch"), second = try makeFolder("input-after-switch")
        let boundary = ScopeBoundary(), scanner = FakeScanner()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: first)
        func photo(_ root: URL) -> LibraryPhotoItem {
            let url = root.appendingPathComponent("photo.png")
            return LibraryPhotoItem(id: url.path, fileURL: url, filename: url.lastPathComponent,
                capturedAt: Date(timeIntervalSince1970: 0), byteCount: 12)
        }
        let firstPhoto = photo(first), secondPhoto = photo(second)
        scanner.setItems([firstPhoto], forFolderName: first.lastPathComponent)
        scanner.setItems([secondPhoto], forFolderName: second.lastPathComponent)
        let vm = makeViewModel(scopeProvider: provider, folderIO: io, scanner: scanner)
        await vm.setLibraryFolder(url: first)
        XCTAssertEqual(vm.daySections.flatMap(\.items), [firstPhoto])

        let bookmarkGate = CancellableGate()
        io.gateBookmark(for: second, gate: bookmarkGate)
        let switching = Task { await vm.setLibraryFolder(url: second) }
        defer { bookmarkGate.open() }
        let savingBookmark = await waitUntil { io.createBookmarkCallCount == 2 }
        XCTAssertTrue(savingBookmark)
        XCTAssertEqual(vm.libraryFolderURL, second)
        XCTAssertTrue(vm.daySections.isEmpty, "The new folder label must never expose old-root photos while its bookmark is pending")
        XCTAssertTrue(vm.orderedLibraryItems.isEmpty)
        bookmarkGate.open(); await switching.value
        XCTAssertEqual(vm.daySections.flatMap(\.items), [secondPhoto])

        // Refreshing the same root should retain its valid contents while the provider drains.
        let scanGate = TestGate()
        scanner.setGate(scanGate, forFolderName: second.lastPathComponent)
        let refresh = Task { await vm.reloadLibraryFolder() }
        await scanGate.entered.wait()
        XCTAssertEqual(vm.daySections.flatMap(\.items), [secondPhoto])
        scanGate.open(); await refresh.value
        vm.releaseLibraryFolder()
        XCTAssertEqual(boundary.activeCount, 0)
    }

    @MainActor
    func testOutputRootChangeCannotExposePreviousResultsDuringReadOrAfterReadFailure() async throws {
        for shouldFail in [false, true] {
            let label = shouldFail ? "failed" : "successful"
            let first = try makeFolder("output-before-" + label), second = try makeFolder("output-after-" + label)
            let input = tempDirectory.appendingPathComponent("source-\(label).png")
            let export = tempDirectory.appendingPathComponent("export-\(label).png")
            try Data([1, 2, 3]).write(to: input); try Data([4, 5, 6]).write(to: export)
            let store = ProcessedLibraryStore()
            func publish(in root: URL) async throws -> ProcessedPhotoRecord {
                let original = try await store.archiveOriginal(at: input, named: "source.png", under: root)
                let draft = ProcessedPhotoDraft(id: UUID(), modelRawValue: BackboneModelKind.quickSRNet.rawValue,
                    sourceWidth: 1, sourceHeight: 1, outputWidth: 2, outputHeight: 2,
                    scaleFactor: 2, grainAmount: 0, processedAt: Date(), formatRawValue: ExportFormat.png16Bit.rawValue)
                return try await store.publish(exportedURL: export, original: original, draft: draft, under: root)
            }
            let firstRecord = try await publish(in: first), secondRecord = try await publish(in: second)
            let boundary = ScopeBoundary(), provider = BoundaryScopeProvider(boundary: boundary)
            let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: first)
            let vm = makeViewModel(scopeProvider: provider, folderIO: io, resultStore: store)
            vm.selectedCollection = .output
            await vm.setOutputFolder(url: first)
            let oldItem = try XCTUnwrap(vm.outputDaySections.first?.items.first)
            XCTAssertEqual(oldItem.fileURL, first.appendingPathComponent(firstRecord.outputRelativePath))

            let bookmarkGate = CancellableGate()
            io.gateBookmark(for: second, gate: bookmarkGate)
            let switching = Task { await vm.setOutputFolder(url: second) }
            let savingBookmark = await waitUntil { io.createBookmarkCallCount == 2 }
            XCTAssertTrue(savingBookmark)
            // The real store queue holds the new root's read after it commits. All generated
            // files are private fixtures; a poisoned sidecar simulates a refused provider read.
            if shouldFail {
                let outside = try makeFolder("outside-" + label)
                try FileManager.default.createSymbolicLink(at: second.appendingPathComponent(".trash"), withDestinationURL: outside)
            }
            let entered = TestSignal(), gate = DispatchSemaphore(value: 0)
            let blocked = Task { try await store.io.run { entered.signal(); gate.wait() } }
            defer { gate.signal(); bookmarkGate.open() }
            await entered.wait()
            bookmarkGate.open()
            let committed = await waitUntil { vm.outputFolderURL == second }
            XCTAssertTrue(committed)
            XCTAssertTrue(vm.outputDaySections.isEmpty, "A new output root must not display the previous root's result while reading")
            XCTAssertNil(vm.trashRequest(ids: [oldItem.id]), "Old-root actions must retire with their gallery")
            gate.signal(); try await blocked.value; await switching.value

            XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent(firstRecord.outputRelativePath)), Data([4, 5, 6]))
            XCTAssertEqual(try Data(contentsOf: second.appendingPathComponent(secondRecord.outputRelativePath)), Data([4, 5, 6]))
            if shouldFail {
                XCTAssertTrue(vm.outputDaySections.isEmpty)
                XCTAssertNotNil(vm.savedOutputRecoveryMessage)
            } else {
                let currentItems = vm.outputDaySections.flatMap(\.items)
                XCTAssertEqual(currentItems.map(\.fileURL), [second.appendingPathComponent(secondRecord.outputRelativePath)])
                let refreshEntered = TestSignal(), refreshGate = DispatchSemaphore(value: 0)
                let blockRefresh = Task { try await store.io.run { refreshEntered.signal(); refreshGate.wait() } }
                defer { refreshGate.signal() }
                await refreshEntered.wait()
                let previousGrantCount = provider.grants.count
                let refresh = Task { await vm.reloadOutputFolder() }
                let refreshing = await waitUntil { provider.grants.count > previousGrantCount }
                XCTAssertTrue(refreshing)
                XCTAssertEqual(vm.outputDaySections.flatMap(\.items), currentItems)
                refreshGate.signal(); try await blockRefresh.value; await refresh.value
            }
        }
    }

    private func bookmark(_ viewModel: StudioViewModel) -> Data? {
        defaults.data(forKey: Self.bookmarkKey)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5.0, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - Reproduced review failures

    @MainActor
    func testOlderReconnectCannotDefeatNewerPickerWhileClassificationPending() async throws {
        let old = try makeFolder("old-reconnect")
        let picked = try makeFolder("new-picked")
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: old)
        let resolve = CancellableGate()
        let classify = CancellableGate()
        io.resolutionGate = resolve
        io.classificationGate = classify
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)

        let reconnect = Task { await vm.reconnectSavedLibraryFolder() }
        await io.resolutionEntered.wait()
        let picker = Task { await vm.handlePickedURL(picked) }
        await io.classificationEntered.wait()

        resolve.open()
        await reconnect.value
        XCTAssertNil(vm.libraryFolderURL, "Older reconnect published while newer picker owns selection")
        XCTAssertTrue(vm.isValidatingLibraryFolder, "Older request cleared the newer picker status")
        XCTAssertEqual(bookmark(vm), Data([1, 2, 3]), "Older reconnect wrote its bookmark while picker was pending")

        classify.open()
        _ = await picker.value
        XCTAssertEqual(vm.libraryFolderURL, picked)
        XCTAssertEqual(bookmark(vm), Data(picked.path.utf8))
        XCTAssertFalse(vm.isValidatingLibraryFolder)

        vm.releaseLibraryFolder()
        XCTAssertEqual(boundary.activeCount, 0)
    }

    @MainActor
    func testOlderSelectionCannotDefeatNewerReconnectWhileResolutionPending() async throws {
        let selected = try makeFolder("old-selection")
        let saved = try makeFolder("saved-reconnect")
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: saved)
        let validation = CancellableGate()
        let resolve = CancellableGate()
        io.gateValidation(for: selected, gate: validation)
        let validationEntered = io.signalWhenValidationEntered(for: selected)
        io.resolutionGate = resolve
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)

        let selection = Task { await vm.setLibraryFolder(url: selected) }
        await validationEntered.wait()
        let reconnect = Task { await vm.reconnectSavedLibraryFolder() }
        await io.resolutionEntered.wait()

        validation.open()
        await selection.value
        XCTAssertNil(vm.libraryFolderURL, "Older selection published after a newer reconnect began")
        XCTAssertEqual(bookmark(vm), Data([1, 2, 3]), "Older request replaced the bookmark while reconnect was pending")
        XCTAssertTrue(vm.isValidatingLibraryFolder)

        resolve.open()
        await reconnect.value
        XCTAssertEqual(vm.libraryFolderURL, saved)
        XCTAssertEqual(bookmark(vm), Data(saved.path.utf8))
        XCTAssertFalse(vm.isValidatingLibraryFolder)

        vm.releaseLibraryFolder()
        XCTAssertEqual(boundary.activeCount, 0)
    }

    @MainActor
    func testOlderReconnectFailureCannotClearPendingPickerState() async throws {
        let picked = try makeFolder("picked-after-failure")
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: tempDirectory)
        io.resolutionFailure = true
        io.resolutionGate = CancellableGate()
        io.classificationGate = CancellableGate()
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)

        let reconnect = Task { await vm.reconnectSavedLibraryFolder() }
        await io.resolutionEntered.wait()
        let picker = Task { await vm.handlePickedURL(picked) }
        await io.classificationEntered.wait()

        io.resolutionGate?.open()
        await reconnect.value
        XCTAssertNil(vm.savedLibraryRecoveryMessage, "Stale failure replaced newer in-flight picker status")
        XCTAssertTrue(vm.isValidatingLibraryFolder, "Stale failure cleared newer picker checking state")
        XCTAssertEqual(bookmark(vm), Data([1, 2, 3]))

        io.classificationGate?.open()
        _ = await picker.value
        XCTAssertEqual(vm.libraryFolderURL, picked)
        XCTAssertEqual(bookmark(vm), Data(picked.path.utf8))
        vm.releaseLibraryFolder()
    }

    // MARK: - F4 cancellation ownership

    @MainActor
    func testAlreadyCancelledSelectionCannotSupersedePendingValidation() async throws {
        let pending = try makeFolder("pending-before-cancelled-request")
        let cancelled = try makeFolder("already-cancelled-request")
        let boundary = ScopeBoundary(), provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: pending)
        let validation = CancellableGate()
        io.gateValidation(for: pending, gate: validation)
        let entered = io.signalWhenValidationEntered(for: pending)
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)

        let selection = Task { await vm.setLibraryFolder(url: pending) }
        defer { validation.open() }
        await entered.wait()
        XCTAssertTrue(vm.isValidatingLibraryFolder)

        // This gate deliberately ignores cancellation until released, so cancellation is already
        // established before the second request reaches the view model.
        let entry = TestGate()
        let rejected = Task {
            await entry.hold()
            await vm.setLibraryFolder(url: cancelled)
        }
        await entry.entered.wait()
        rejected.cancel()
        entry.open()
        await rejected.value
        XCTAssertTrue(vm.isValidatingLibraryFolder, "The live validation still owns checking state")
        XCTAssertEqual(io.validationRecords.map(\.url), [pending])

        validation.open()
        await selection.value
        XCTAssertEqual(vm.libraryFolderURL, pending, "An already cancelled request must not retire the live selection")
        XCTAssertEqual(bookmark(vm), Data(pending.path.utf8))
        XCTAssertFalse(vm.isValidatingLibraryFolder)
        XCTAssertEqual(vm.libraryStatusLine, "Library ready")
        vm.releaseLibraryFolder()
        XCTAssertEqual(boundary.activeCount, 0)
        XCTAssertTrue(provider.grants.allSatisfy { $0.releaseCallCount == 1 })
    }

    @MainActor
    func testRefusedSelectionRetiresOlderCheckingStateWithoutReplacingFolder() async throws {
        let selected = try makeFolder("selected-before-refusal")
        let pending = try makeFolder("pending-before-refusal")
        let output = try makeFolder("output-before-input-refusal")
        let refused = output.appendingPathComponent("nested-input", isDirectory: true)
        try FileManager.default.createDirectory(at: refused, withIntermediateDirectories: true)
        let boundary = ScopeBoundary(), provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: selected)
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)
        await vm.setLibraryFolder(url: selected)
        await vm.setOutputFolder(url: output)
        let savedBookmark = bookmark(vm)

        let validation = CancellableGate()
        io.gateValidation(for: pending, gate: validation)
        let entered = io.signalWhenValidationEntered(for: pending)
        let selection = Task { await vm.setLibraryFolder(url: pending) }
        defer { validation.open() }
        await entered.wait()
        XCTAssertTrue(vm.isValidatingLibraryFolder)

        await vm.setLibraryFolder(url: refused)
        XCTAssertFalse(vm.isValidatingLibraryFolder, "A current request refused before validation must clear the retired request's spinner")
        XCTAssertEqual(vm.libraryStatusLine, "Library ready")
        XCTAssertEqual(vm.libraryFolderURL, selected)
        XCTAssertEqual(bookmark(vm), savedBookmark)
        XCTAssertNotNil(vm.errorMessage)

        validation.open()
        await selection.value
        XCTAssertEqual(vm.libraryFolderURL, selected, "The older validation must remain superseded after it drains")
        XCTAssertEqual(bookmark(vm), savedBookmark)
        XCTAssertFalse(vm.isValidatingLibraryFolder)
        XCTAssertEqual(vm.libraryStatusLine, "Library ready")
        XCTAssertFalse(io.validationRecords.contains { $0.url == refused })
        vm.releaseLibraryFolder()
        XCTAssertEqual(boundary.activeCount, 1, "Only the selected output session remains")
        XCTAssertTrue(provider.grants.filter { $0.url != output }.allSatisfy { $0.releaseCallCount == 1 })
    }

    @MainActor
    func testCancelledReconnectClearsItsValidationStatusAfterResolutionDrains() async throws {
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: tempDirectory)
        io.resolutionGate = CancellableGate()
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)

        let reconnect = Task { await vm.reconnectSavedLibraryFolder() }
        await io.resolutionEntered.wait()
        reconnect.cancel()
        io.resolutionGate?.open()
        await reconnect.value

        XCTAssertFalse(vm.isValidatingLibraryFolder, "Cancelled reconnect left checking status stuck")
        XCTAssertNil(vm.libraryFolderURL)
        XCTAssertEqual(bookmark(vm), Data([1, 2, 3]))
        XCTAssertEqual(boundary.activeCount, 0)
        XCTAssertNotEqual(vm.libraryStatusLine, "Checking saved library folder…")
    }

    @MainActor
    func testCancelledPickerClearsItsValidationStatusAndBalancesGrant() async throws {
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: tempDirectory)
        io.classificationGate = CancellableGate()
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)

        let picker = Task { await vm.handlePickedURL(tempDirectory) }
        await io.classificationEntered.wait()
        picker.cancel()
        io.classificationGate?.open()
        _ = await picker.value

        XCTAssertFalse(vm.isValidatingLibraryFolder, "Cancelled picker left checking status stuck")
        XCTAssertNil(vm.libraryFolderURL)
        XCTAssertEqual(boundary.activeCount, 0)
        XCTAssertEqual(provider.grants.first?.releaseCallCount, 1)
    }

    @MainActor
    func testCancelledSelectionThenNewerReconnectKeepsNewerCheckingState() async throws {
        let selected = try makeFolder("cancelled-selection")
        let saved = try makeFolder("newer-reconnect")
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: saved)
        let validation = CancellableGate()
        io.gateValidation(for: selected, gate: validation)
        let entered = io.signalWhenValidationEntered(for: selected)
        io.resolutionGate = CancellableGate()
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)

        let selection = Task { await vm.setLibraryFolder(url: selected) }
        await entered.wait()
        let reconnect = Task { await vm.reconnectSavedLibraryFolder() }
        await io.resolutionEntered.wait()
        selection.cancel()
        validation.open()
        await selection.value
        XCTAssertTrue(vm.isValidatingLibraryFolder, "Cancelled old selection cleared newer reconnect checking state")
        XCTAssertNil(vm.libraryFolderURL)

        io.resolutionGate?.open()
        await reconnect.value
        XCTAssertEqual(vm.libraryFolderURL, saved)
        XCTAssertFalse(vm.isValidatingLibraryFolder)
        XCTAssertEqual(bookmark(vm), Data(saved.path.utf8))
    }

    @MainActor
    func testCancelledPickerThenNewerSelectionKeepsNewerCheckingState() async throws {
        let picked = try makeFolder("cancelled-picker-file")
        let chosen = try makeFolder("newer-selection-after-cancel")
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: chosen)
        let classify = CancellableGate()
        io.classificationGate = classify
        let validation = CancellableGate()
        io.gateValidation(for: chosen, gate: validation)
        let validationEntered = io.signalWhenValidationEntered(for: chosen)
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)

        let picker = Task { await vm.handlePickedURL(picked) }
        await io.classificationEntered.wait()
        let selection = Task { await vm.setLibraryFolder(url: chosen) }
        await validationEntered.wait()

        picker.cancel()
        classify.open()
        _ = await picker.value
        XCTAssertTrue(vm.isValidatingLibraryFolder, "Cancelled picker cleared newer selection checking state")
        XCTAssertNil(vm.libraryFolderURL)

        validation.open()
        await selection.value
        XCTAssertEqual(vm.libraryFolderURL, chosen)
        XCTAssertFalse(vm.isValidatingLibraryFolder)
        XCTAssertEqual(bookmark(vm), Data(chosen.path.utf8))
    }

    @MainActor
    func testCancelledSelectionDuringBookmarkCreationKeepsLastValidStateAndBalancesGrants() async throws {
        let folder = try makeFolder("cancel-bookmark")
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: folder)
        let bookmarkGate = CancellableGate()
        io.gateBookmark(for: folder, gate: bookmarkGate)
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)

        let selection = Task { await vm.setLibraryFolder(url: folder) }
        await io.bookmarkEntered.wait()
        XCTAssertEqual(vm.libraryFolderURL, folder)
        XCTAssertFalse(vm.isValidatingLibraryFolder)

        selection.cancel()
        bookmarkGate.open()
        await selection.value

        XCTAssertEqual(vm.libraryFolderURL, folder, "Last valid selection must be preserved")
        XCTAssertFalse(vm.isValidatingLibraryFolder)
        XCTAssertEqual(bookmark(vm), Data([1, 2, 3]), "Cancelled bookmark save must not overwrite saved bytes")
        XCTAssertEqual(boundary.activeCount, 1, "Only the selected session grant remains; no scan started")
        XCTAssertEqual(provider.grants[0].releaseCallCount, 1)
        XCTAssertEqual(provider.grants[1].releaseCallCount, 0)

        vm.releaseLibraryFolder()
        XCTAssertEqual(boundary.activeCount, 0)
    }

    // MARK: - Reversed completion / repeated requests

    @MainActor
    func testReversedCompletionOrderNewerPickerWinsThenOlderReconnectDrains() async throws {
        let old = try makeFolder("draining-reconnect")
        let picked = try makeFolder("first-picker")
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: old)
        let resolve = CancellableGate()
        let classify = CancellableGate()
        io.resolutionGate = resolve
        io.classificationGate = classify
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)

        let reconnect = Task { await vm.reconnectSavedLibraryFolder() }
        await io.resolutionEntered.wait()
        let picker = Task { await vm.handlePickedURL(picked) }
        await io.classificationEntered.wait()

        // Newer picker completes first; older reconnect then drains.
        classify.open()
        _ = await picker.value
        XCTAssertEqual(vm.libraryFolderURL, picked)
        XCTAssertEqual(bookmark(vm), Data(picked.path.utf8))

        resolve.open()
        await reconnect.value
        XCTAssertEqual(vm.libraryFolderURL, picked, "Older reconnect overwrote a newer completed picker")
        XCTAssertEqual(bookmark(vm), Data(picked.path.utf8))
        XCTAssertFalse(vm.isValidatingLibraryFolder)
    }

    @MainActor
    func testRepeatedReconnectLatestSuccessWinsRegardlessOfCompletionOrder() async throws {
        let first = try makeFolder("reconnect-one")
        let second = try makeFolder("reconnect-two")
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: first)
        let firstGate = CancellableGate()
        io.resolutionGate = firstGate
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)

        let one = Task { await vm.reconnectSavedLibraryFolder() }
        await io.resolutionEntered.wait()

        io.resolvedURL = second
        let secondGate = CancellableGate()
        io.resolutionGate = secondGate
        let two = Task { await vm.reconnectSavedLibraryFolder() }
        let secondEntered = await waitUntil { io.resolutionCallCount >= 2 }
        XCTAssertTrue(secondEntered)

        secondGate.open()
        await two.value
        XCTAssertEqual(vm.libraryFolderURL, second)
        XCTAssertEqual(bookmark(vm), Data(second.path.utf8))

        firstGate.open()
        await one.value
        XCTAssertEqual(vm.libraryFolderURL, second, "Older repeated reconnect overwrote the newest request")
        XCTAssertEqual(bookmark(vm), Data(second.path.utf8))
        XCTAssertFalse(vm.isValidatingLibraryFolder)
    }

    @MainActor
    func testOldReconnectFailureAfterNewerSuccessDoesNotPublishRecovery() async throws {
        let newer = try makeFolder("newer-success")
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: newer)
        let oldGate = CancellableGate()
        io.resolutionGate = oldGate
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)

        let old = Task { await vm.reconnectSavedLibraryFolder() }
        await io.resolutionEntered.wait()

        let newerGate = CancellableGate()
        io.resolutionGate = newerGate
        let newerTask = Task { await vm.reconnectSavedLibraryFolder() }
        let newerEntered = await waitUntil { io.resolutionCallCount >= 2 }
        XCTAssertTrue(newerEntered)
        newerGate.open()
        await newerTask.value
        XCTAssertNil(vm.savedLibraryRecoveryMessage)

        // Make the older resolution fail after the newer success has drained.
        io.resolutionFailure = true
        oldGate.open()
        await old.value
        XCTAssertNil(vm.savedLibraryRecoveryMessage, "Older reconnect failure published stale recovery")
        XCTAssertFalse(vm.isValidatingLibraryFolder)
    }

    // MARK: - Bookmark-write and restore scheduling

    @MainActor
    func testCancelledOutputBookmarkCreationKeepsCurrentRootAndBookmark() async throws {
        let original = try makeFolder("output-current")
        let cancelled = try makeFolder("output-cancelled")
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: original)
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)
        await vm.setOutputFolder(url: original)
        let originalBookmark = defaults.data(forKey: StudioViewModel.outputBookmarkDefaultsKey)
        let gate = CancellableGate()
        io.gateBookmark(for: cancelled, gate: gate)

        let selection = Task { await vm.setOutputFolder(url: cancelled) }
        let entered = await waitUntil { io.createBookmarkCallCount == 2 }
        XCTAssertTrue(entered)
        XCTAssertTrue(vm.isValidatingOutputFolder)
        selection.cancel()
        await selection.value

        XCTAssertEqual(vm.outputFolderURL, original)
        XCTAssertEqual(defaults.data(forKey: StudioViewModel.outputBookmarkDefaultsKey), originalBookmark)
        XCTAssertFalse(vm.isValidatingOutputFolder)
        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(provider.grants.filter { $0.url == cancelled }.allSatisfy { $0.releaseCallCount == 1 })
    }

    @MainActor
    func testCancelledOlderOutputSelectionCannotClearNewerValidation() async throws {
        let original = try makeFolder("output-original")
        let older = try makeFolder("output-older")
        let newer = try makeFolder("output-newer")
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: original)
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)
        await vm.setOutputFolder(url: original)
        let olderGate = CancellableGate(), newerGate = CancellableGate()
        io.gateBookmark(for: older, gate: olderGate)
        io.gateBookmark(for: newer, gate: newerGate)

        let first = Task { await vm.setOutputFolder(url: older) }
        let firstEntered = await waitUntil { io.createBookmarkCallCount == 2 }
        XCTAssertTrue(firstEntered)
        let second = Task { await vm.setOutputFolder(url: newer) }
        let secondEntered = await waitUntil { io.createBookmarkCallCount == 3 }
        XCTAssertTrue(secondEntered)
        first.cancel()
        await first.value
        XCTAssertTrue(vm.isValidatingOutputFolder, "Cancelled old cleanup cannot clear the newer folder check")
        XCTAssertEqual(vm.outputFolderURL, original)

        newerGate.open()
        await second.value
        XCTAssertEqual(vm.outputFolderURL, newer)
        XCTAssertEqual(defaults.data(forKey: StudioViewModel.outputBookmarkDefaultsKey), Data(newer.path.utf8))
        XCTAssertFalse(vm.isValidatingOutputFolder)
    }

    @MainActor
    func testCancelledOutputReconnectDoesNotPublishProviderFailure() async throws {
        let original = try makeFolder("output-reconnect-current")
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: original)
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)
        await vm.setOutputFolder(url: original)
        let originalBookmark = defaults.data(forKey: StudioViewModel.outputBookmarkDefaultsKey)
        io.resolutionFailure = true
        io.resolutionGate = CancellableGate()
        let reconnect = Task { await vm.reconnectOutputFolder() }
        await io.resolutionEntered.wait()
        reconnect.cancel()
        await reconnect.value

        XCTAssertNil(vm.savedOutputRecoveryMessage)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.outputFolderURL, original)
        XCTAssertEqual(defaults.data(forKey: StudioViewModel.outputBookmarkDefaultsKey), originalBookmark)
    }

    @MainActor
    func testOldBookmarkCreationAfterNewerRequestDoesNotOverwriteSavedBookmark() async throws {
        let older = try makeFolder("older-bookmark")
        let newer = try makeFolder("newer-bookmark")
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: older)
        let bookmarkGate = CancellableGate()
        io.gateBookmark(for: older, gate: bookmarkGate)
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)

        let olderSelection = Task { await vm.setLibraryFolder(url: older) }
        await io.bookmarkEntered.wait()
        XCTAssertEqual(vm.libraryFolderURL, older) // committed before bookmark save awaits

        let newerSelection = Task { await vm.setLibraryFolder(url: newer) }
        await newerSelection.value
        XCTAssertEqual(vm.libraryFolderURL, newer)
        XCTAssertEqual(bookmark(vm), Data(newer.path.utf8))

        bookmarkGate.open()
        await olderSelection.value
        XCTAssertEqual(vm.libraryFolderURL, newer, "Older bookmark save restored its selection")
        XCTAssertEqual(bookmark(vm), Data(newer.path.utf8), "Older bookmark save overwrote the newer saved selection")
        XCTAssertFalse(vm.isValidatingLibraryFolder)
    }

    @MainActor
    func testScheduledRestoreCannotAdoptNewerUserAction() async throws {
        let saved = try makeFolder("scheduled-saved")
        let chosen = try makeFolder("user-chosen")
        let boundary = ScopeBoundary()
        let provider = BoundaryScopeProvider(boundary: boundary)
        let io = BoundaryLibraryFolderIO(boundary: boundary, resolvedURL: saved)
        let resolve = CancellableGate()
        io.resolutionGate = resolve
        let vm = makeViewModel(scopeProvider: provider, folderIO: io)

        vm.restoreLibraryBookmarkIfAvailable()
        await io.resolutionEntered.wait()

        await vm.setLibraryFolder(url: chosen)
        XCTAssertEqual(vm.libraryFolderURL, chosen)
        XCTAssertEqual(bookmark(vm), Data(chosen.path.utf8))

        resolve.open()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(vm.libraryFolderURL, chosen, "Scheduled restore adopted a newer action's ownership")
        XCTAssertEqual(bookmark(vm), Data(chosen.path.utf8))
        XCTAssertFalse(vm.isValidatingLibraryFolder)
    }
}
