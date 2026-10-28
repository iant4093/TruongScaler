import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import TruongScalerCore
import MMapCanvas
import CoreIngestion
import TiledInferenceEngine
import BackgroundJobManager
@testable import DeepZoomGalleryUI

/// Relaunch/bookmark recovery regressions.
///
/// The phone user saved a library folder, hit the tiled-renderer trap and could not reopen a
/// usable library. These tests drive the real bookmark/grant/scan path with task-owned fixture
/// folders and injected preferences, proving:
/// * launch restores the saved selection exactly once;
/// * a missing/stale grant never traps, loops or deletes the bookmark;
/// * the empty library stays interactive with explicit reconnect/change actions;
/// * an explicit release is the only path that clears the saved bookmark.
@MainActor
final class LibraryRelaunchRecoveryTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryRelaunchRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        suiteName = "com.truongscaler.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        try await super.tearDown()
    }

    // MARK: - Factories

    private func makeFixtureFolder(name: String, imageCount: Int = 0, withOriginals: Bool = false) throws -> URL {
        var folder = tempDirectory.appendingPathComponent(name, isDirectory: true)
        if withOriginals {
            folder = folder.appendingPathComponent("originals", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if imageCount > 0 {
            for index in 0..<imageCount {
                let url = folder.appendingPathComponent("fixture-\(index).png")
                XCTAssertTrue(writePNG(to: url, width: 8 + index, height: 6 + index))
            }
        }
        return folder
    }

    private func writePNG(to url: URL, width: Int, height: Int) -> Bool {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private func saveBookmark(for folder: URL) throws {
        let data = try BookmarkRootGrant.createBookmarkData(for: folder)
        defaults.set(data, forKey: StudioViewModel.bookmarkDefaultsKey)
    }

    private func makeViewModel(
        scanner: any StudioLibraryScanning = FakeScanner(),
        scopeProvider: any SecurityScopeGrantProviding = RecordingScopeProvider(),
        folderIO: any LibraryFolderIO = BlockingLibraryFolderIO()
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

    // MARK: - Tests

    func testLaunchRestoresReachableSavedFolderExactlyOnce() async throws {
        let folder = try makeFixtureFolder(name: "reachable-library", imageCount: 2)
        try saveBookmark(for: folder)
        let scanner = FakeScanner()
        scanner.setDefaultItems([
            LibraryPhotoItem(id: "a", fileURL: folder.appendingPathComponent("a.dng"), filename: "a.dng", capturedAt: Date(), byteCount: 1),
            LibraryPhotoItem(id: "b", fileURL: folder.appendingPathComponent("b.dng"), filename: "b.dng", capturedAt: Date(), byteCount: 1),
        ])
        let viewModel = makeViewModel(scanner: scanner)

        viewModel.restoreLibraryBookmarkIfAvailable()
        // A second launch observer (for example another scene) must not restore or rescan again.
        viewModel.restoreLibraryBookmarkIfAvailable()

        let restored = await waitUntil { viewModel.libraryFolderURL != nil }
        XCTAssertTrue(restored)
        XCTAssertEqual(viewModel.libraryFolderURL?.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertNil(viewModel.savedLibraryRecoveryMessage)
        XCTAssertEqual(viewModel.orderedLibraryItems.count, 2)

        // Give any accidental second restore a chance to run before asserting the scan count.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(scanner.scanCount, 1)
        XCTAssertNotNil(defaults.data(forKey: StudioViewModel.bookmarkDefaultsKey))
    }

    func testUnavailableSavedFolderKeepsBookmarkAndOffersRecovery() async throws {
        let folder = try makeFixtureFolder(name: "will-disappear")
        try saveBookmark(for: folder)
        try FileManager.default.removeItem(at: folder)

        let viewModel = makeViewModel()
        viewModel.restoreLibraryBookmarkIfAvailable()
        // Bookmark resolution/validation now runs off-main; publication still happens on MainActor.
        let published = await waitUntil { viewModel.savedLibraryRecoveryMessage != nil }
        XCTAssertTrue(published)
        XCTAssertNil(viewModel.libraryFolderURL)
        XCTAssertNotNil(viewModel.savedLibraryRecoveryMessage)
        XCTAssertTrue(viewModel.hasSavedLibraryBookmark)
        XCTAssertTrue(defaults.data(forKey: StudioViewModel.bookmarkDefaultsKey) != nil)
        XCTAssertTrue(viewModel.daySections.isEmpty)

        // The saved bookmark is retained on disk even after repeated restore calls.
        viewModel.restoreLibraryBookmarkIfAvailable()
        XCTAssertTrue(viewModel.hasSavedLibraryBookmark)
    }

    func testReconnectAfterUnavailableFolderRestoresUsableLibrary() async throws {
        let folder = try makeFixtureFolder(name: "reconnect-me", imageCount: 1)
        try saveBookmark(for: folder)
        let originalData = try XCTUnwrap(defaults.data(forKey: StudioViewModel.bookmarkDefaultsKey))

        // Simulate a temporarily unavailable grant, then reconnect the same saved bookmark.
        try FileManager.default.removeItem(at: folder)
        let viewModel = makeViewModel()
        viewModel.restoreLibraryBookmarkIfAvailable()
        let failed = await waitUntil { viewModel.savedLibraryRecoveryMessage != nil }
        XCTAssertTrue(failed)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if (try? BookmarkRootGrant.resolveBookmarkData(originalData)) == nil {
            // Some filesystems invalidate a bookmark for a removed directory; keep the exact saved
            // bytes semantically equivalent by re-creating the bookmark for the same path.
            try saveBookmark(for: folder)
        }
        await viewModel.reconnectSavedLibraryFolder()
        let restored = await waitUntil { viewModel.libraryFolderURL != nil }
        XCTAssertTrue(restored)
        XCTAssertEqual(viewModel.libraryFolderURL?.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertNil(viewModel.savedLibraryRecoveryMessage)
        XCTAssertNotNil(defaults.data(forKey: StudioViewModel.bookmarkDefaultsKey))
    }

    func testExplicitReleaseIsTheOnlyPathThatClearsTheSavedBookmark() async throws {
        let folder = try makeFixtureFolder(name: "explicit-release")
        try saveBookmark(for: folder)
        let viewModel = makeViewModel()
        viewModel.restoreLibraryBookmarkIfAvailable()
        _ = await waitUntil { viewModel.libraryFolderURL != nil }
        XCTAssertTrue(viewModel.hasSavedLibraryBookmark)

        viewModel.releaseLibraryFolder()
        XCTAssertFalse(viewModel.hasSavedLibraryBookmark)
        XCTAssertNil(defaults.data(forKey: StudioViewModel.bookmarkDefaultsKey))
        XCTAssertNil(viewModel.savedLibraryRecoveryMessage)
        XCTAssertNil(viewModel.libraryFolderURL)
        XCTAssertTrue(viewModel.daySections.isEmpty)
    }

    func testNoSavedBookmarkLeavesUsableEmptyLibrary() {
        let viewModel = makeViewModel()
        viewModel.restoreLibraryBookmarkIfAvailable()
        XCTAssertNil(viewModel.libraryFolderURL)
        XCTAssertNil(viewModel.savedLibraryRecoveryMessage)
        XCTAssertFalse(viewModel.hasSavedLibraryBookmark)
        XCTAssertTrue(viewModel.daySections.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testUserSelectionBeforeDelayedRestoreWins() async throws {
        let savedFolder = try makeFixtureFolder(name: "saved-old", imageCount: 1)
        let chosenFolder = try makeFixtureFolder(name: "chosen-new", imageCount: 2)
        try saveBookmark(for: savedFolder)
        let scanner = FakeScanner()
        scanner.setDefaultItems([
            LibraryPhotoItem(id: "new", fileURL: chosenFolder.appendingPathComponent("new.png"), filename: "new.png", capturedAt: Date(), byteCount: 1),
        ])
        let viewModel = makeViewModel(scanner: scanner)

        viewModel.restoreLibraryBookmarkIfAvailable()
        await viewModel.setLibraryFolder(url: chosenFolder)

        XCTAssertEqual(viewModel.libraryFolderURL?.standardizedFileURL, chosenFolder.standardizedFileURL)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(viewModel.libraryFolderURL?.standardizedFileURL, chosenFolder.standardizedFileURL)
        XCTAssertEqual(scanner.scanCount, 1)
    }

    func testRealFixtureFolderEnumerationAfterRestore() async throws {
        let folder = try makeFixtureFolder(name: "real-fixture", imageCount: 3, withOriginals: true)
        try saveBookmark(for: folder)
        let viewModel = makeViewModel(scanner: BlockingLibraryScanner())

        viewModel.restoreLibraryBookmarkIfAvailable()
        let loaded = await waitUntil(timeout: 10) {
            viewModel.orderedLibraryItems.count == 3
        }
        XCTAssertTrue(loaded)
        XCTAssertEqual(viewModel.orderedLibraryItems.count, 3)
        XCTAssertFalse(viewModel.daySections.isEmpty)
        XCTAssertNil(viewModel.savedLibraryRecoveryMessage)
    }
}
