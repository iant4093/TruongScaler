#if canImport(UIKit)
import Foundation
import XCTest
import UIKit
import SwiftUI
import TruongScalerCore
@testable import DeepZoomGalleryUI

/// Actual scene/modal lifecycle regressions. Delegate-state simulation below verifies ownership,
/// not a real cross-app OS copy or physical-phone handoff.
@MainActor
final class CompanionHandoffLifecycleNativeTests: XCTestCase {
    private let own: SuiteCompanionApp = .truongScaler
    private let other: SuiteCompanionApp = .truongNoiser

    func testFastHandoffWaitsForConfirmationDismissalInsteadOfDroppingItsDocument() async throws {
        try requireCompanion()
        let directory = try temporaryDirectory()
        let (owner, window) = try host()
        let anchor = attachAnchor(to: owner)
        let alert = UIAlertController(title: "Send photo?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        await withCheckedContinuation { continuation in owner.present(alert, animated: false) { continuation.resume() } }
        var document: PortableSuiteHandoff.Document? = try makeDocument(directory: directory)
        weak let weakDocument = document
        var session: CompanionHandoffSession? = CompanionHandoffSession(document: try XCTUnwrap(document))
        let id = try XCTUnwrap(session?.id), url = try XCTUnwrap(session?.fileURL)
        let initial = CompanionDocumentTransfer.activeTransferCount
        var finishes: [(UUID, Bool)] = []
        anchor.update(session: session) { finishes.append(($0, $1)) }
        document = nil; session = nil
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(owner.presentedViewController === alert)
        XCTAssertTrue(finishes.isEmpty, "The preceding confirmation must not cancel a fast prepared send")
        XCTAssertNotNil(weakDocument)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(CompanionDocumentTransfer.activeTransferCount, initial)
        await withCheckedContinuation { continuation in alert.dismiss(animated: true) { continuation.resume() } }
        try await waitFor { CompanionDocumentTransfer.activeTransferCount == initial + 1 }
        XCTAssertTrue(finishes.isEmpty)
        XCTAssertNotNil(weakDocument)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "TruongScaler-OpenIn-after-confirmation-dismissal"
        attachment.lifetime = .keepAlways; add(attachment)
        anchor.tearDown()
        try await waitFor { finishes.count == 1 && CompanionDocumentTransfer.activeTransferCount == initial }
        XCTAssertEqual(finishes.first?.0, id)
        XCTAssertEqual(finishes.first?.1, false)
        XCTAssertNil(weakDocument)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBlockedUnpresentedHandoffRetiresOnTimeoutAndTeardownExactlyOnce() async throws {
        let directory = try temporaryDirectory()
        let (owner, _) = try host()
        let alert = UIAlertController(title: "A different modal owns this surface", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        await withCheckedContinuation { continuation in owner.present(alert, animated: false) { continuation.resume() } }
        for cancelOnTeardown in [false, true] {
            let anchor = attachAnchor(to: owner)
            var document: PortableSuiteHandoff.Document? = try makeDocument(directory: directory)
            weak let weakDocument = document
            var session: CompanionHandoffSession? = CompanionHandoffSession(document: try XCTUnwrap(document))
            let id = try XCTUnwrap(session?.id), url = try XCTUnwrap(session?.fileURL)
            var finishes: [(UUID, Bool)] = []
            anchor.update(session: session) { finishes.append(($0, $1)) }
            document = nil; session = nil
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(finishes.isEmpty)
            XCTAssertNotNil(weakDocument)
            if cancelOnTeardown { anchor.tearDown(); anchor.tearDown() }
            try await waitFor(timeout: .seconds(4)) { finishes.count == 1 }
            XCTAssertEqual(finishes.first?.0, id)
            XCTAssertEqual(finishes.first?.1, false)
            XCTAssertNil(weakDocument)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertTrue(owner.presentedViewController === alert)
            anchor.tearDown()
            anchor.willMove(toParent: nil); anchor.view.removeFromSuperview(); anchor.removeFromParent()
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(finishes.count, 1)
        }
    }

    func testAcceptedSendRetainsDocumentAfterItsViewerCancelsUntilSendingEnds() async throws {
        try requireCompanion()
        let directory = try temporaryDirectory()
        let (owner, _) = try host()
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 260, y: 760, width: 48, height: 48)
        owner.view.addSubview(button)
        var document: PortableSuiteHandoff.Document? = try makeDocument(directory: directory)
        weak let weakDocument = document
        var session: CompanionHandoffSession? = CompanionHandoffSession(document: try XCTUnwrap(document))
        let url = try XCTUnwrap(session?.fileURL), id = try XCTUnwrap(session?.id)
        var finishes: [(UUID, Bool)] = []
        var transfer: CompanionDocumentTransfer? = CompanionDocumentTransfer(session: try XCTUnwrap(session)) {
            finishes.append(($0, $1))
        }
        weak let weakTransfer = transfer
        let initial = CompanionDocumentTransfer.activeTransferCount
        transfer?.present(from: button)
        try await waitFor { CompanionDocumentTransfer.activeTransferCount == initial + 1 }
        let delegateController = UIDocumentInteractionController(url: url)
        // Model UIKit's accepted-send interval without invoking another app or claiming OS-copy success.
        transfer?.documentInteractionController(delegateController, willBeginSendingToApplication: "test.accepted.send")
        document = nil; session = nil
        transfer?.cancelMenu()
        transfer = nil
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(weakTransfer)
        XCTAssertNotNil(weakDocument)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(finishes.isEmpty)
        weakTransfer?.documentInteractionController(delegateController, didEndSendingToApplication: "test.accepted.send")
        try await waitFor { finishes.count == 1 && CompanionDocumentTransfer.activeTransferCount == initial }
        XCTAssertEqual(finishes.first?.0, id)
        XCTAssertEqual(finishes.first?.1, false)
        XCTAssertNil(weakTransfer)
        XCTAssertNil(weakDocument)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testIncomingHandoffDismissesOutputSetupAndAcknowledgesOnlyAnActuallyVisiblePhotoViewer() async throws {
        let directory = try temporaryDirectory()
        let suite = "TruongScaler-IncomingModal-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let vm = StudioViewModel(workingDirectory: directory.appendingPathComponent("workspace"),
            requiresOutputFolder: true, defaults: defaults)
        vm.restoreOutputBookmarkIfAvailable()
        XCTAssertTrue(vm.isOutputSetupPresented)
        let (owner, window) = try host(root: UIHostingController(rootView: LibraryScreen(viewModel: vm)))
        try await waitFor { owner.presentedViewController != nil && vm.isOutputSetupPresented }
        let setup = try XCTUnwrap(owner.presentedViewController)
        let source = try makeImage(in: directory)
        let document = try PortableSuiteHandoff.createDocument(exportedImageURL: source,
            originalFileName: source.lastPathComponent, sourceApp: other, targetApp: own,
            isDenoised: false, isUpscaled: false, globalMaxLuminance: 1, upscaleFactor: nil,
            globalMaxLinearComponent: 1, directory: directory.appendingPathComponent("incoming"))
        vm.handleIncomingHandoffURL(document.fileURL)
        await vm.waitForHandoffConsumptionsToFinish()
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isOutputSetupPresented)
        if owner.presentedViewController === setup {
            XCTAssertNotNil(vm.incomingHandoffViewerRequest, "Dismissing setup is not proof that the photo viewer appeared")
        }
        try await waitFor {
            vm.incomingHandoffViewerRequest == nil && owner.presentedViewController != nil
                && owner.presentedViewController !== setup && self.loadedOriginal(in: window)
        }
        XCTAssertEqual(vm.sourceBuffer?.width, 8)
        XCTAssertEqual(vm.sourceBuffer?.height, 6)
        XCTAssertEqual(vm.metadata?.isAlreadyDenoisedByNoiser, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(vm.sourceURL).path))
        // An existing viewer may itself own an inspector or share modal. Receiving another photo
        // must not acknowledge visibility until that viewer's own modal surface has settled.
        let viewer = try XCTUnwrap(owner.presentedViewController)
        let inspector = UIAlertController(title: "Existing viewer inspector", message: nil, preferredStyle: .alert)
        inspector.addAction(UIAlertAction(title: "Done", style: .cancel))
        await withCheckedContinuation { continuation in viewer.present(inspector, animated: false) { continuation.resume() } }
        let secondSource = try makeImage(in: directory)
        let secondDocument = try PortableSuiteHandoff.createDocument(exportedImageURL: secondSource,
            originalFileName: secondSource.lastPathComponent, sourceApp: other, targetApp: own,
            isDenoised: false, isUpscaled: false, globalMaxLuminance: 1, upscaleFactor: nil,
            globalMaxLinearComponent: 1, directory: directory.appendingPathComponent("incoming-second"))
        vm.handleIncomingHandoffURL(secondDocument.fileURL)
        await vm.waitForHandoffConsumptionsToFinish()
        XCTAssertNotNil(vm.incomingHandoffViewerRequest)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(vm.incomingHandoffViewerRequest, "A viewer hidden by a modal has not displayed the new photo")
        await withCheckedContinuation { continuation in inspector.dismiss(animated: true) { continuation.resume() } }
        try await waitFor { vm.incomingHandoffViewerRequest == nil && self.loadedOriginal(in: window) }
        XCTAssertEqual(vm.sourceURL?.lastPathComponent, secondSource.lastPathComponent)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "TruongScaler-incoming-handoff-after-output-setup"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    private func loadedOriginal(in view: UIView) -> Bool {
        if let pager = view as? OriginalPagerView, pager.scroll.imageView.image != nil { return true }
        return view.subviews.contains { loadedOriginal(in: $0) }
    }

    private func attachAnchor(to owner: UIViewController) -> CompanionHandoffAnchor {
        let anchor = CompanionHandoffAnchor()
        owner.addChild(anchor); owner.view.addSubview(anchor.view)
        anchor.view.frame = CGRect(x: 260, y: 760, width: 48, height: 48)
        anchor.didMove(toParent: owner)
        addTeardownBlock { @MainActor in anchor.tearDown() }
        return anchor
    }

    private func requireCompanion() throws {
        guard ProcessInfo.processInfo.environment["TRUONGSUITE_COMPANION_AVAILABLE"] == "1" else {
            throw XCTSkip("Install the updated companion on the task-owned Simulator before this native Open In test")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TruongScaler-HandoffLifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func host(root owner: UIViewController = UIViewController()) throws -> (UIViewController, UIWindow) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = owner; window.makeKeyAndVisible(); window.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            if owner.presentedViewController != nil {
                await withCheckedContinuation { continuation in owner.dismiss(animated: false) { continuation.resume() } }
            }
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        }
        return (owner, window)
    }

    private func makeDocument(directory: URL) throws -> PortableSuiteHandoff.Document {
        let source = try makeImage(in: directory)
        return try PortableSuiteHandoff.createDocument(exportedImageURL: source,
            originalFileName: source.lastPathComponent, sourceApp: own, targetApp: other,
            isDenoised: false, isUpscaled: false, globalMaxLuminance: 1, upscaleFactor: nil,
            globalMaxLinearComponent: 1, directory: directory.appendingPathComponent("outgoing"))
    }

    private func makeImage(in directory: URL) throws -> URL {
        let source = directory.appendingPathComponent("photo-\(UUID()).png")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // Pixel dimensions must not depend on the Simulator's 3× display scale.
        let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6), format: format).image { context in
            UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }.pngData())
        try data.write(to: source)
        return source
    }

    private func waitFor(timeout: Duration = .seconds(6), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while .now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The actual native presentation did not reach the expected lifecycle state")
        throw CocoaError(.featureUnsupported)
    }
}
#endif
