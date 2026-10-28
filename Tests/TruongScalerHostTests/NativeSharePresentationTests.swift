import XCTest
import UIKit
import SwiftUI
import CoreGraphics
import ImageIO
import Observation
import CryptoKit
import TruongScalerCore
@testable import DeepZoomGalleryUI

/// UIKit modal presentation needs a running UIApplication scene, unlike standalone package tests.
/// All files/folder grants are disposable and the physical phone is never selected.
@MainActor
final class NativeSharePresentationTests: XCTestCase {
    /// Opt-in documentation capture of the production screens, with real required-model output.
    /// The two CC0 photographs and their attribution already live in the quality fixture set.
    /// Normal test runs never write documentation or populate the person's photo libraries.
    func testCaptureREADMEProductionScreenshots() async throws {
        guard let capturePath = ProcessInfo.processInfo.environment["TRUONGSCALER_README_SCREENSHOT_DIR"],
              !capturePath.isEmpty else {
            throw XCTSkip("Set TRUONGSCALER_README_SCREENSHOT_DIR to capture the README screens")
        }
        let captures = URL(fileURLWithPath: capturePath, isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("README-Capture-\(UUID())", isDirectory: true)
        let directory = scratch.appendingPathComponent("TruongScaler Demo", isDirectory: true)
        let input = directory.appendingPathComponent("Sample photos", isDirectory: true)
        let output = directory.appendingPathComponent("Enlarged photos", isDirectory: true)
        for folder in [input, output] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let suite = "README-Capture-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: scratch)
        }
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TiledInferenceEngineTests/Fixtures/quality", isDirectory: true)
        let samples = [
            (fixture: "photo_flower_lr_512x384.png", name: "Blue sow-thistle.png"),
            (fixture: "photo_landscape_lr_512x384.png", name: "Urbino at sunset.png"),
        ]
        var photos: [URL] = []
        for sample in samples {
            let destination = input.appendingPathComponent(sample.name)
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(sample.fixture), to: destination)
            photos.append(destination)
        }
        // The public production initializer always requires the four shipped trained variants.
        // Do not replace this with the deterministic test fallback: these are README photographs.
        let vm = StudioViewModel(workingDirectory: directory.appendingPathComponent("work"), defaults: defaults)
        await vm.setOutputFolder(url: output)
        await vm.setLibraryFolder(url: input)
        XCTAssertEqual(vm.daySections.flatMap(\.items).count, 2)
        XCTAssertNil(vm.errorMessage)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = .dark
        let library = UIHostingController(rootView: LibraryScreen(viewModel: vm).preferredColorScheme(.dark))
        window.rootViewController = library
        window.makeKeyAndVisible()
        defer {
            library.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
            vm.viewerDidDismiss()
        }
        func settle() async throws {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(800))
            window.layoutIfNeeded()
        }
        var capturedNames: [String] = []
        func capture(_ name: String) throws {
            XCTAssertEqual(window.bounds.size, CGSize(width: 402, height: 874))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            format.opaque = true
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let pixels = try XCTUnwrap(image.cgImage)
            XCTAssertEqual(pixels.width, 1206)
            XCTAssertEqual(pixels.height, 2622)
            try XCTUnwrap(image.pngData()).write(to: captures.appendingPathComponent(name + ".png"), options: .atomic)
            let attachment = XCTAttachment(image: image)
            attachment.name = "README-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
            capturedNames.append(name + ".png")
        }
        try await settle()
        try capture("input-library")

        vm.exportFormat = .tiff16BitLZW
        vm.selectedModel = .quickSRNet
        for photo in photos {
            await vm.ingestFile(at: photo)
            vm.startProcessing()
            let deadline = ContinuousClock.now + .seconds(120)
            while vm.isProcessing, .now < deadline { try await Task.sleep(for: .milliseconds(30)) }
            XCTAssertFalse(vm.isProcessing, "The required-model screenshot job exceeded its deadline")
            if vm.isProcessing {
                vm.cancelProcessing()
                await vm.waitForStopToFinish()
                throw CocoaError(.featureUnsupported)
            }
            XCTAssertEqual(vm.currentStage, .readyForInspection, vm.errorMessage ?? "")
            XCTAssertTrue(vm.isProcessedPhoto)
            XCTAssertEqual(vm.completedArtifacts?.checkpoint.config.backbone, .quickSRNet)
            XCTAssertEqual(vm.completedArtifacts?.checkpoint.outputWidth, 1024)
            XCTAssertEqual(vm.completedArtifacts?.checkpoint.outputHeight, 768)
            guard vm.currentStage == .readyForInspection else { throw CocoaError(.featureUnsupported) }
        }
        await vm.reloadOutputFolder()
        XCTAssertEqual(vm.outputDaySections.flatMap(\.items).count, 2)
        // Reopen the saved flower result to exercise the portable before/after record, rather than
        // holding an unpersisted in-memory canvas only for a screenshot.
        let records = try await ProcessedLibraryStore().records(under: output)
        let flowerRecord = try XCTUnwrap(records.first { $0.original.filename == samples[0].name })
        let flowerURL = output.appendingPathComponent(flowerRecord.outputRelativePath)
        let flowerResult = try XCTUnwrap(vm.outputDaySections.flatMap(\.items).first { $0.fileURL == flowerURL })
        vm.selectedCollection = .output
        await vm.openLibraryPhoto(flowerResult)
        XCTAssertEqual(vm.currentStage, .readyForInspection, vm.errorMessage ?? "")
        XCTAssertNil(vm.comparisonUnavailableReason)
        let viewer = UIHostingController(rootView: StudioWorkspaceView(viewModel: vm).preferredColorScheme(.dark))
        viewer.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in library.present(viewer, animated: false) { continuation.resume() } }
        try await settle()
        try capture("processed-viewer")
        await withCheckedContinuation { continuation in library.dismiss(animated: false) { continuation.resume() } }
        vm.viewerDidDismiss()
        try await settle()
        try capture("output-library")

        vm.selectedCollection = .input
        await vm.ingestFile(at: photos[0])
        XCTAssertEqual(vm.metadata?.originalWidth, 512)
        let options = UIHostingController(rootView: UpscaleOptionsFormSheet(viewModel: vm, onPickFileOrFolder: {})
            .preferredColorScheme(.dark))
        options.modalPresentationStyle = .pageSheet
        if let sheet = options.sheetPresentationController { sheet.detents = [.large()] }
        await withCheckedContinuation { continuation in library.present(options, animated: false) { continuation.resume() } }
        try await settle()
        // Use the real form's native scroll view to expose the existing model and export controls.
        func formScrollView(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height + 100 { return scroll }
            return view.subviews.compactMap { formScrollView($0) }.first
        }
        let form = try XCTUnwrap(formScrollView(options.view))
        let bottom = max(-form.adjustedContentInset.top, form.contentSize.height - form.bounds.height + form.adjustedContentInset.bottom)
        form.setContentOffset(CGPoint(x: 0, y: min(660, bottom)), animated: false)
        try await settle()
        try capture("model-settings")
        await withCheckedContinuation { continuation in library.dismiss(animated: false) { continuation.resume() } }

        let attribution = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("fixture-provenance.json"))) as? [String: Any]
        let sourceHashes = try Dictionary(uniqueKeysWithValues: samples.map { sample in
            let data = try Data(contentsOf: fixtures.appendingPathComponent(sample.fixture))
            return (sample.fixture, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        })
        let manifest: [String: Any] = [
            "capture": "Actual production SwiftUI/UIKit screens in an iOS simulator, 402×874 points at 3×; private temporary libraries",
            "processing": "Real StudioViewModel production initializer (.requireProductionModels), QuickSRNet-Large native 2×, denoise off; two 512×384 inputs saved as 1024×768 TIFF results and reopened through portable records",
            "qualityScope": "Screenshots illustrate the interface; they do not establish physical-phone performance or image-quality superiority",
            "screenshots": capturedNames,
            "fixtureSHA256": sourceHashes,
            "photographSources": attribution?["sources"] ?? [],
            "fixtureProvenance": "Tests/TiledInferenceEngineTests/Fixtures/quality/fixture-provenance.json",
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: captures.appendingPathComponent("provenance.json"), options: .atomic)
    }

    func testUnpresentedShareRetiresOnTeardownExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UnpresentedShare-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = PhotoShareSession(id: UUID(), surface: .viewer, fileURLs: [], directory: directory)
        let anchor = PhotoShareAnchor()
        anchor.loadViewIfNeeded()
        var retired: [UUID] = []
        anchor.update(session: session, onDismiss: { retired.append($0) })
        await Task.yield()
        anchor.tearDown(); anchor.tearDown()
        for _ in 0..<100 where retired.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(retired, [session.id])
    }

    func testObsoleteNativeShareSignalsCannotDismissTheNextSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShareIdentity-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.png")
        try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData()).write(to: url)
        let first = PhotoShareSession(id: UUID(), surface: .viewer, fileURLs: [url], directory: directory)
        let second = PhotoShareSession(id: UUID(), surface: .viewer, fileURLs: [url], directory: directory)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let parent = UIViewController(), anchor = PhotoShareAnchor()
        window.rootViewController = parent; window.makeKeyAndVisible()
        parent.addChild(anchor); parent.view.addSubview(anchor.view)
        anchor.view.frame = parent.view.bounds; anchor.didMove(toParent: parent)
        defer { anchor.tearDown(); window.isHidden = true; window.rootViewController = nil }
        func waitFor(_ predicate: () -> Bool) async throws {
            for _ in 0..<300 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("The native share transition did not complete")
            throw CocoaError(.featureUnsupported)
        }
        var retired: [UUID] = []
        anchor.update(session: first, onDismiss: { retired.append($0) })
        try await waitFor { parent.presentedViewController is UIActivityViewController && parent.presentedViewController?.isBeingPresented == false }
        let oldController = try XCTUnwrap(parent.presentedViewController as? UIActivityViewController)
        let oldPresentation = try XCTUnwrap(oldController.presentationController)
        let oldCompletion = oldController.completionWithItemsHandler
        await withCheckedContinuation { continuation in parent.dismiss(animated: false) { continuation.resume() } }
        anchor.presentationControllerDidDismiss(oldPresentation)
        try await waitFor { retired == [first.id] }
        anchor.update(session: second, onDismiss: { retired.append($0) })
        try await waitFor { parent.presentedViewController is UIActivityViewController && parent.presentedViewController?.isBeingPresented == false }
        let current = try XCTUnwrap(parent.presentedViewController as? UIActivityViewController)
        oldCompletion?(nil, false, nil, nil)
        anchor.presentationControllerDidDismiss(oldPresentation)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(parent.presentedViewController === current)
        XCTAssertFalse(current.isBeingDismissed)
        XCTAssertEqual(retired, [first.id])
        let currentPresentation = try XCTUnwrap(current.presentationController)
        await withCheckedContinuation { continuation in parent.dismiss(animated: false) { continuation.resume() } }
        anchor.presentationControllerDidDismiss(currentPresentation)
        try await waitFor { retired == [first.id, second.id] }
    }

    func testBlockedShareRequestRetiresInsteadOfWedging() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BlockedShare-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.png")
        try Data([0]).write(to: url)
        let session = PhotoShareSession(id: UUID(), surface: .viewer, fileURLs: [url], directory: directory)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let parent = UIViewController(), anchor = PhotoShareAnchor()
        window.rootViewController = parent; window.makeKeyAndVisible()
        parent.addChild(anchor); parent.view.addSubview(anchor.view)
        anchor.view.frame = parent.view.bounds; anchor.didMove(toParent: parent)
        defer { anchor.tearDown(); window.isHidden = true; window.rootViewController = nil }
        let inspector = UIViewController(); inspector.modalPresentationStyle = .pageSheet
        await withCheckedContinuation { continuation in parent.present(inspector, animated: false) { continuation.resume() } }
        var retired = false
        anchor.update(session: session, onDismiss: { _ in retired = true })
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(parent.presentedViewController === inspector, "Sharing must not replace the user's newer native sheet")
        XCTAssertTrue(retired, "An unpresentable share must release its request so the next Export tap is usable")
        await withCheckedContinuation { continuation in parent.dismiss(animated: false) { continuation.resume() } }
    }

    func testCancelledDeletedPreviewCannotClearTheNextRenderedPhoto() async throws {
        let fixture = DeletedPreviewFixture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: DeletedPreviewFixtureView(fixture: fixture))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; fixture.releasePendingReads() }
        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<300 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("The actual deleted-photo preview did not finish the requested transition")
            throw CocoaError(.featureUnsupported)
        }
        func renderedPhoto(in view: UIView) -> CGImage? {
            if let scroll = view as? OriginalScrollView { return scroll.imageView.image?.cgImage }
            return view.subviews.compactMap { renderedPhoto(in: $0) }.first
        }
        let first = fixture.entry.id
        try await waitFor { fixture.pending[first] != nil }
        fixture.entry = DeletedPreviewFixture.makeEntry()
        let second = fixture.entry.id
        try await waitFor { fixture.pending[second] != nil }
        let image = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 30, height: 40)).image { context in
            UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0, y: 0, width: 30, height: 40))
        }.cgImage)
        fixture.complete(second, with: image)
        try await waitFor { renderedPhoto(in: window) === image }
        // The production view model returns nil when an obsolete disk read drains after task
        // cancellation. That old completion used to erase the already rendered second photo.
        fixture.complete(first, with: nil)
        try await waitFor { fixture.completed.contains(first) }
        XCTAssertTrue(fixture.cancelledCompletions.contains(first), "SwiftUI must actually cancel the previous entry's task")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(renderedPhoto(in: window) === image)
    }

    func testEmptyRecentlyDeletedAndRoomierControlsInNativeSheet() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GalleryPolish-\(UUID())")
        let suite = "GalleryPolish-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let vm = StudioViewModel(workingDirectory: directory, defaults: defaults)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let parent = UIViewController(); window.rootViewController = parent; window.makeKeyAndVisible()
        defer { parent.dismiss(animated: false); window.isHidden = true }
        func attach(_ name: String) {
            let capture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: capture); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        let controls = UIHostingController(rootView: VStack {
            Spacer()
            ProcessingProgressBarView(progress: JobProgressPresentation(phase: .tileCommitted, completedTiles: 117, totalTiles: 234), onStop: {}, onShowDetails: {})
            LibraryCollectionBar(selection: .constant(.input)).padding(.bottom, 16)
        }.background(.black).preferredColorScheme(.dark))
        parent.addChild(controls); parent.view.addSubview(controls.view); controls.view.frame = parent.view.bounds
        controls.didMove(toParent: parent)
        try await Task.sleep(for: .milliseconds(200)); attach("roomier-gallery-controls")
        let trash = UIHostingController(rootView: RecentlyDeletedView(viewModel: vm))
        await withCheckedContinuation { continuation in parent.present(trash, animated: false) { continuation.resume() } }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(vm.recentlyDeleted.isEmpty)
        XCTAssertNotNil(trash.view.window)
        attach("recently-deleted-empty-cam-style")
    }

    func testRequiredModelResultSharesFromFullscreenViewerAndDeletesRecoverably() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeShareTest-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input"), output = directory.appendingPathComponent("output")
        for folder in [input, output] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let photo = input.appendingPathComponent("fixture.png")
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32)).image { ctx in
            UIColor.systemGreen.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
            UIColor.white.setFill(); ctx.fill(CGRect(x: 12, y: 6, width: 16, height: 20))
        }
        try XCTUnwrap(rendered.pngData()).write(to: photo)
        let suite = "TruongScalerHostTest-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vm = StudioViewModel(workingDirectory: directory.appendingPathComponent("work"), defaults: defaults)
        await vm.setOutputFolder(url: output); await vm.setLibraryFolder(url: input); await vm.ingestFile(at: photo)
        vm.exportFormat = .tiff16BitLZW; vm.startProcessing()
        let processingDeadline = ContinuousClock.now + .seconds(120)
        while vm.isProcessing, .now < processingDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(vm.currentStage, .readyForInspection, vm.errorMessage ?? "")
        XCTAssertTrue(vm.isProcessedPhoto)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let parent = UIViewController(); window.rootViewController = parent; window.makeKeyAndVisible()
        parent.view.frame = window.bounds
        let viewer = UIHostingController(rootView: StudioWorkspaceView(viewModel: vm))
        viewer.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in parent.present(viewer, animated: false) { continuation.resume() } }
        defer { parent.dismiss(animated: false); window.isHidden = true; vm.viewerDidDismiss() }
        XCTAssertNotNil(viewer.view.window)
        let start = ContinuousClock.now
        await vm.exportFinalImage()
        func containsActivity(_ c: UIViewController) -> Bool {
            if c is UIActivityViewController { return c.viewIfLoaded?.window != nil && !c.isBeingPresented }
            return c.children.contains(where: containsActivity) || c.presentedViewController.map(containsActivity) == true
        }
        while !containsActivity(viewer), start.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(containsActivity(viewer), "A real native share controller must be presented by the fullscreen viewer")
        XCTAssertTrue(parent.presentedViewController === viewer)
        XCTAssertNil(vm.shareBinding(for: .library))
        let snapshot = try XCTUnwrap(vm.shareSession?.fileURLs.first)
        XCTAssertEqual(try Data(contentsOf: snapshot), try Data(contentsOf: vm.exportedShareURLs[0]))
        let activity = UIActivityViewController(activityItems: [], applicationActivities: nil)
        let item = PhotoShareItem(url: snapshot)
        XCTAssertEqual(item.activityViewControllerLinkMetadata(activity)?.title, vm.inspectionFilename)
        XCTAssertNotNil(item.activityViewControllerLinkMetadata(activity)?.iconProvider)
        XCTAssertNil(item.activityViewControllerLinkMetadata(activity)?.imageProvider)
        XCTAssertTrue(SaveOriginalToPhotosActivity().canPerform(withActivityItems: [item]))
        print("HOSTED_SHARE_SECONDS \(start.duration(to: .now))")
        let shareCapture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let shareAttachment = XCTAttachment(image: shareCapture); shareAttachment.name = "native-share"; shareAttachment.lifetime = .keepAlways; add(shareAttachment)
        await withCheckedContinuation { continuation in viewer.dismiss(animated: false) { continuation.resume() } }
        for _ in 0..<100 where vm.shareSession != nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(vm.shareSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        vm.selectedCollection = .output
        let request = try XCTUnwrap(vm.displayedTrashRequest())
        await vm.trashOutputs(request)
        XCTAssertTrue(vm.outputDaySections.isEmpty)
        await vm.reloadRecentlyDeleted()
        XCTAssertEqual(vm.recentlyDeleted.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
        await vm.waitForResetToFinish()
        let trashView = UIHostingController(rootView: RecentlyDeletedView(viewModel: vm).preferredColorScheme(.dark))
        await withCheckedContinuation { continuation in viewer.present(trashView, animated: false) { continuation.resume() } }
        try await Task.sleep(for: .milliseconds(250))
        let trashCapture = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let trashAttachment = XCTAttachment(image: trashCapture); trashAttachment.name = "recently-deleted-native"; trashAttachment.lifetime = .keepAlways; add(trashAttachment)
    }
}

@MainActor @Observable private final class DeletedPreviewFixture {
    var entry = DeletedPreviewFixture.makeEntry()
    var pending: [UUID: CheckedContinuation<CGImage?, Never>] = [:]
    var completed: Set<UUID> = []
    var cancelledCompletions: Set<UUID> = []
    static func makeEntry() -> OutputTrashEntry {
        OutputTrashEntry(id: UUID(), schemaVersion: 1, authoredBy: "com.iantruong.truongscaler", deletedAt: Date(),
            filename: "fixture.dng", record: nil, state: .trashed,
            files: [.init(originalPath: "output/fixture.dng", storedName: "0.dng", sha256: String(repeating: "0", count: 64), bytes: 4)])
    }
    func read(_ entry: OutputTrashEntry) async -> CGImage? {
        let image = await withCheckedContinuation { pending[entry.id] = $0 }
        if Task.isCancelled { cancelledCompletions.insert(entry.id) }
        completed.insert(entry.id)
        return image
    }
    func complete(_ id: UUID, with image: CGImage?) { pending.removeValue(forKey: id)?.resume(returning: image) }
    func releasePendingReads() {
        let reads = pending.values
        pending.removeAll()
        for read in reads { read.resume(returning: nil) }
    }
}

private struct DeletedPreviewFixtureView: View {
    let fixture: DeletedPreviewFixture
    var body: some View {
        DeletedPhotoPreview(entry: fixture.entry, loadThumbnail: { await fixture.read($0) },
            previous: {}, next: {}, close: {})
    }
}
