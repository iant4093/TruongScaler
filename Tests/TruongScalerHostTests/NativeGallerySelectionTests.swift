#if canImport(UIKit) && canImport(XCTest) && !TC_TESTKIT_STANDALONE
import XCTest
import UIKit
import SwiftUI
@testable import DeepZoomGalleryUI

private final class GalleryTestPan: UIPanGestureRecognizer {
    var movement = CGPoint.zero
    var point = CGPoint.zero
    override func translation(in view: UIView?) -> CGPoint { movement }
    override func location(in view: UIView?) -> CGPoint { point }
}

private final class GalleryRotatingTestController: UIViewController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
}

private struct GalleryNativeTestAnchor: UIViewRepresentable {
    let anchor: GalleryTrashAnchorView
    func makeUIView(context: Context) -> GalleryTrashAnchorView { anchor }
    func updateUIView(_ uiView: GalleryTrashAnchorView, context: Context) {}
    static func dismantleUIView(_ uiView: GalleryTrashAnchorView, coordinator: ()) { uiView.close() }
}

final class NativeGallerySelectionTests: XCTestCase {
    @MainActor private func makeWindow(size: CGSize, root: UIViewController? = nil) async throws -> UIWindow {
        for _ in 0..<100 {
            if UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = root ?? UIViewController()
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Owned UIKit presentation did not reach its expected terminal state")
        throw CocoaError(.featureUnsupported)
    }

    @MainActor private func rotate(_ window: UIWindow, to orientation: UIInterfaceOrientation) async throws {
        let scene = try XCTUnwrap(window.windowScene)
        let mask: UIInterfaceOrientationMask = orientation == .portrait ? .portrait :
            orientation == .landscapeLeft ? .landscapeLeft : .landscapeRight
        var geometryError: Error?
        window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { geometryError = $0 }
        for _ in 0..<100 {
            if let geometryError { throw geometryError }
            let geometry = scene.effectiveGeometry
            if geometry.interfaceOrientation == orientation,
               (geometry.coordinateSpace.bounds.width > geometry.coordinateSpace.bounds.height) == orientation.isLandscape,
               window.rootViewController?.transitionCoordinator == nil,
               window.rootViewController?.presentedViewController?.transitionCoordinator == nil {
                window.frame = geometry.coordinateSpace.bounds
                window.layoutIfNeeded()
                XCTAssertEqual(scene.effectiveGeometry.interfaceOrientation, orientation)
                XCTAssertEqual(window.bounds.width > window.bounds.height, orientation.isLandscape)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The real UIWindowScene did not rotate to \(orientation.rawValue)")
        throw CocoaError(.featureUnsupported)
    }

    @MainActor private func waitForAnchoredPopover(_ alert: UIAlertController,
        anchor: GalleryTrashAnchorView, window: UIWindow) async throws -> (actual: CGRect, target: CGRect) {
        var actual = CGRect.zero, target = CGRect.zero, effectiveSource = CGRect.zero
        var containerBounds = CGRect.zero
        for _ in 0..<300 {
            target = anchor.convert(anchor.bounds, to: window)
            actual = alert.view.convert(alert.view.bounds, to: window)
            if let popover = alert.popoverPresentationController, let source = popover.sourceView {
                // A sourceRect sentinel is an input policy, not persistent
                // state: UIKit may replace CGRectNull with the actual bounds.
                let rectangle = popover.sourceRect.isNull ? source.bounds : popover.sourceRect
                effectiveSource = source.convert(rectangle, to: window)
                containerBounds = popover.containerView?.bounds ?? .zero
            }
            let nativeRotationFinished = window.rootViewController?.transitionCoordinator == nil
                && alert.transitionCoordinator == nil && !alert.isBeingPresented && !alert.isBeingDismissed
            let containerFits = abs(containerBounds.width - window.bounds.width) <= 1
                && abs(containerBounds.height - window.bounds.height) <= 1
            let attached = effectiveSource == target && actual.maxY <= target.minY + 22
                && actual.maxY > target.minY - 60
            let onScreen = actual.minX >= -1 && actual.minY >= -1
                && actual.maxX <= window.bounds.width + 1 && actual.maxY <= window.bounds.height + 1
            if nativeRotationFinished, containerFits, attached, onScreen,
               alert.viewIfLoaded?.window === window { return (actual, target) }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Native popover did not settle above its current source: popup=\(actual), target=\(target), effectiveSource=\(effectiveSource), container=\(containerBounds), window=\(window.bounds)")
        throw CocoaError(.featureUnsupported)
    }

    @MainActor func testSelectionGestureUsesHorizontalStartNativeScrollAndCancellableRange() async throws {
        let window = try await makeWindow(size: CGSize(width: 402, height: 874))
        defer { window.isHidden = true }
        let host = try XCTUnwrap(window.rootViewController?.view)
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 100, width: 402, height: 500))
        scroll.contentSize = CGSize(width: 402, height: 2200)
        host.addSubview(scroll)
        let bridge = GallerySelectionGestureView(frame: CGRect(x: 0, y: 0, width: 402, height: 2200))
        scroll.addSubview(bridge)
        let ids = (0..<48).map { _ in UUID().uuidString }
        let frames = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, CGRect(x: (index % 3) * 134, y: (index / 3) * 134, width: 131, height: 130))
        })
        var selected: Set<String> = [ids[0]]
        bridge.update(frames: frames, orderedIDs: ids, selectedIDs: selected, context: "root-A", isEnabled: true) { selected = $0 }
        XCTAssertTrue(bridge.scrollView === scroll)
        XCTAssertTrue(scroll.gestureRecognizers?.contains(bridge.selectionPan) == true)
        let pan = GalleryTestPan()
        pan.movement = CGPoint(x: 20, y: 3); pan.point = CGPoint(x: 50, y: 30)
        XCTAssertTrue(bridge.gestureRecognizerShouldBegin(pan), "Horizontal photo sweep wins")
        pan.movement = CGPoint(x: 3, y: 20)
        XCTAssertFalse(bridge.gestureRecognizerShouldBegin(pan), "Vertical movement keeps native scrolling")
        pan.movement = CGPoint(x: 20, y: 3); pan.point = CGPoint(x: 50, y: -60)
        XCTAssertFalse(bridge.gestureRecognizerShouldBegin(pan), "Header space does not start selection")
        bridge.begin(at: CGPoint(x: 160, y: 50))
        bridge.updateSelection(at: bridge.convert(CGPoint(x: 300, y: 300), to: window))
        XCTAssertEqual(selected, Set(ids[0...8]), "The same native movement callback selects across rows")
        bridge.updateSelection(at: bridge.convert(CGPoint(x: 300, y: 50), to: window))
        XCTAssertEqual(selected, Set(ids[0...2]), "Reversing contracts the range")
        bridge.finish(cancelled: true)
        XCTAssertEqual(selected, [ids[0]], "An interrupted touch restores its baseline")
        bridge.begin(at: CGPoint(x: 160, y: 50))
        for _ in 0..<30 { bridge.advanceAutoScroll(at: CGPoint(x: 300, y: 598), elapsed: 1.0 / 30) }
        XCTAssertGreaterThan(scroll.contentOffset.y, 350, "Holding at the visible edge scrolls the actual grid")
        XCTAssertGreaterThan(selected.count, 10, "Sweep follows newly visible rows")
        bridge.update(frames: frames, orderedIDs: ids, selectedIDs: [], context: "root-B", isEnabled: true) { selected = $0 }
        XCTAssertNil(bridge.sweep, "Changing roots cancels the gesture without restoring old selections")
        selected = []
        bridge.finish(cancelled: true)
        XCTAssertTrue(selected.isEmpty)
        let stopped = scroll.contentOffset.y
        bridge.advanceAutoScroll(at: CGPoint(x: 300, y: 598), elapsed: 1)
        XCTAssertEqual(scroll.contentOffset.y, stopped, "No autoscroll survives cancellation")
        bridge.detach()
        XCTAssertFalse(scroll.gestureRecognizers?.contains(bridge.selectionPan) == true)
    }

    @MainActor func testTrashConfirmationActuallyPresentsAboveItsSourceInPortraitAndLandscape() async throws {
        let window = try await makeWindow(size: CGSize(width: 402, height: 874), root: GalleryRotatingTestController())
        do {
        for orientation in [UIInterfaceOrientation.portrait, .landscapeLeft, .landscapeRight] {
            try await rotate(window, to: orientation)
            let size = window.bounds.size
            let host = try XCTUnwrap(window.rootViewController?.view)
            let anchor = GalleryTrashAnchorView(frame: CGRect(x: size.width - 70, y: size.height - 110, width: 44, height: 44))
            host.addSubview(anchor)
            var confirmed = false, dismissed = false
            anchor.update(requestID: UUID(), count: 3, onConfirm: { _ in confirmed = true }, onDismiss: { _ in dismissed = true })
            try await waitUntil { anchor.confirmation?.viewIfLoaded?.window != nil && anchor.confirmation?.isBeingPresented == false }
            let alert = try XCTUnwrap(anchor.confirmation)
            let popover = try XCTUnwrap(alert.popoverPresentationController)
            let stableSource = try XCTUnwrap(popover.sourceView)
            XCTAssertFalse(stableSource === anchor, "SwiftUI may replace the button while UIKit dismisses")
            XCTAssertTrue(stableSource.superview === window, "The native source is outside SwiftUI's owned hierarchy")
            XCTAssertEqual(stableSource.convert(stableSource.bounds, to: window), anchor.convert(anchor.bounds, to: window))
            let sourceRect = popover.sourceRect.isNull ? stableSource.bounds : popover.sourceRect
            XCTAssertEqual(stableSource.convert(sourceRect, to: window), anchor.convert(anchor.bounds, to: window), "UIKit's effective source remains the actual Trash target")
            XCTAssertEqual(alert.modalPresentationStyle, .popover)
            XCTAssertTrue(window.rootViewController?.presentedViewController === alert)
            let (actual, target) = try await waitForAnchoredPopover(alert, anchor: anchor, window: window)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let name = "trash-source-orientation-\(orientation.rawValue)"
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TruongScalerGalleryParity", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
            print("TC_GALLERY_GEOMETRY orientation=\(sceneOrientation(window)) bounds=\(window.bounds) popup=\(actual) source=\(target) image=\(directory.path)")
            XCTAssertLessThanOrEqual(actual.maxY, target.minY + 22, "Native confirmation must appear above Trash, not at the screen center")
            XCTAssertGreaterThan(actual.maxY, target.minY - 60, "The native popover stays attached to its source")
            XCTAssertLessThanOrEqual(actual.maxX, size.width + 1)
            XCTAssertGreaterThanOrEqual(actual.minX, -1)
            XCTAssertFalse(confirmed, "Presenting confirmation never mutates photos")
            anchor.frame.origin.x -= 8
            XCTAssertEqual(stableSource.convert(stableSource.bounds, to: window), anchor.convert(anchor.bounds, to: window), "A live source follows position-only control placement")
            anchor.update(requestID: nil, count: 0, onConfirm: { _ in confirmed = true }, onDismiss: { _ in dismissed = true })
            try await waitUntil { window.rootViewController?.presentedViewController == nil }
            XCTAssertNil(stableSource.superview, "The stable native source is removed after dismissal")
            XCTAssertNil(window.rootViewController?.presentedViewController, "Replacing root/request dismisses the old confirmation")
            XCTAssertFalse(confirmed)
            XCTAssertFalse(dismissed, "Invalidating a request does not route an old popover action")
            anchor.removeFromSuperview()
        }
        try await rotate(window, to: .portrait)
        window.isHidden = true
        } catch {
            try? await rotate(window, to: .portrait)
            window.isHidden = true
            throw error
        }
    }

    @MainActor private func sceneOrientation(_ window: UIWindow) -> Int {
        window.windowScene?.effectiveGeometry.interfaceOrientation.rawValue ?? -1
    }

    @MainActor func testPermanentDeletionConfirmationIsExplicitDestructiveAndOwned() async throws {
        let window = try await makeWindow(size: CGSize(width: 402, height: 874)); defer { window.isHidden = true }
        let anchor = GalleryTrashAnchorView(frame: CGRect(x: 332, y: 764, width: 44, height: 44))
        try XCTUnwrap(window.rootViewController?.view).addSubview(anchor)
        let owner = UUID(); var confirmed: [UUID] = []
        anchor.update(requestID: owner, count: 3, onConfirm: { confirmed.append($0) }, onDismiss: { _ in }, kind: .permanentlyDelete)
        try await waitUntil { anchor.confirmation?.viewIfLoaded?.window != nil && anchor.confirmation?.isBeingPresented == false }
        let alert = try XCTUnwrap(anchor.confirmation)
        XCTAssertEqual(alert.title, "Permanently delete 3 photos?")
        XCTAssertTrue(alert.message?.contains("cannot be undone") == true)
        XCTAssertTrue(alert.actions.contains { $0.title == "Delete 3 Photos" && $0.style == .destructive })
        XCTAssertTrue(confirmed.isEmpty, "Presenting confirmation must never delete")
        anchor.performAction(for: UUID(), alert: alert, confirms: true)
        XCTAssertTrue(confirmed.isEmpty, "A different selection cannot approve this deletion")
        anchor.performAction(for: owner, alert: alert, confirms: true)
        if alert.viewIfLoaded?.window != nil || alert.presentingViewController != nil {
            XCTAssertTrue(confirmed.isEmpty, "Deletion cannot replace the footer during native dismissal")
        }
        try await waitUntil { confirmed == [owner] }
        XCTAssertEqual(confirmed, [owner])
        XCTAssertNil(alert.viewIfLoaded?.window)
        XCTAssertNil(alert.presentingViewController)
        anchor.performAction(for: owner, alert: alert, confirms: true)
        XCTAssertEqual(confirmed, [owner], "A repeated native action cannot re-dispatch")
        anchor.close()
    }

    @MainActor func testObsoleteTrashActionCannotConfirmOrDismissReplacementRequest() async throws {
        let window = try await makeWindow(size: CGSize(width: 402, height: 874))
        defer { window.isHidden = true }
        let anchor = GalleryTrashAnchorView(frame: CGRect(x: 332, y: 764, width: 44, height: 44))
        try XCTUnwrap(window.rootViewController?.view).addSubview(anchor)
        var confirmed: [UUID] = [], dismissed: [UUID] = []
        let a = UUID(), b = UUID()
        anchor.update(requestID: a, count: 2, onConfirm: { confirmed.append($0) }, onDismiss: { dismissed.append($0) })
        try await waitUntil { anchor.confirmation?.viewIfLoaded?.window != nil && anchor.confirmation?.isBeingPresented == false }
        let oldAlert = try XCTUnwrap(anchor.confirmation)
        let oldPopover = try XCTUnwrap(oldAlert.popoverPresentationController)
        anchor.update(requestID: nil, count: 0, onConfirm: { confirmed.append($0) }, onDismiss: { dismissed.append($0) })
        anchor.update(requestID: b, count: 3, onConfirm: { confirmed.append($0) }, onDismiss: { dismissed.append($0) })
        try await waitUntil { anchor.confirmation != nil && anchor.confirmation !== oldAlert && anchor.confirmation?.isBeingPresented == false }
        let replacement = try XCTUnwrap(anchor.confirmation)
        XCTAssertFalse(replacement === oldAlert)
        anchor.performAction(for: a, alert: oldAlert, confirms: true)
        anchor.performAction(for: a, alert: oldAlert, confirms: false)
        anchor.popoverPresentationControllerDidDismissPopover(oldPopover)
        anchor.performAction(for: b, alert: oldAlert, confirms: true)
        XCTAssertTrue(confirmed.isEmpty)
        XCTAssertTrue(dismissed.isEmpty)
        XCTAssertTrue(anchor.confirmation === replacement)
        anchor.performAction(for: b, alert: replacement, confirms: true)
        try await waitUntil { confirmed == [b] }
        XCTAssertEqual(confirmed, [b], "Only this exact request/controller pair can confirm")
        anchor.performAction(for: b, alert: replacement, confirms: true)
        XCTAssertEqual(confirmed, [b], "An action cannot be consumed twice")
        anchor.close()
        let detached = GalleryTrashAnchorView(frame: .zero)
        detached.update(requestID: a, count: 1, onConfirm: { confirmed.append($0) }, onDismiss: { dismissed.append($0) })
        XCTAssertTrue(dismissed.isEmpty, "A representable update cannot synchronously mutate SwiftUI state")
        for _ in 0..<100 where dismissed.isEmpty { await Task.yield() }
        XCTAssertEqual(dismissed, [a], "A detached anchor cancels its exact request instead of silently retaining it")
        XCTAssertNil(detached.confirmation)
    }

    @MainActor func testConfirmedBatchKeepsItsSourceUntilDismissalThenAllowsFooterReplacement() async throws {
        let window = try await makeWindow(size: CGSize(width: 402, height: 874))
        defer { window.isHidden = true }
        let host = try XCTUnwrap(window.rootViewController?.view)
        let footer = UIView(frame: CGRect(x: 0, y: 744, width: 402, height: 64))
        host.addSubview(footer)
        let anchor = GalleryTrashAnchorView(frame: CGRect(x: 332, y: 10, width: 44, height: 44))
        footer.addSubview(anchor)
        let owner = UUID()
        var confirmed: [UUID] = [], callbackSawVisibleAlert = false
        var presentedAlert: UIAlertController?
        anchor.update(requestID: owner, count: 177, onConfirm: { id in
            callbackSawVisibleAlert = presentedAlert?.viewIfLoaded?.window != nil || presentedAlert?.presentingViewController != nil
            confirmed.append(id)
            // This is the real callsite's state transition: delete progress
            // replaces the footer that hosted the representable.
            footer.removeFromSuperview()
            let progress = UIView(frame: CGRect(x: 0, y: 734, width: 402, height: 74))
            progress.accessibilityIdentifier = "synthetic-photo-progress"
            host.addSubview(progress)
        }, onDismiss: { _ in XCTFail("A confirmed batch must not be cancelled") })
        try await waitUntil { anchor.confirmation?.viewIfLoaded?.window != nil && anchor.confirmation?.isBeingPresented == false }
        let alert = try XCTUnwrap(anchor.confirmation); presentedAlert = alert
        let popover = try XCTUnwrap(alert.popoverPresentationController)
        let source = try XCTUnwrap(popover.sourceView)
        let expected = source.convert(source.bounds, to: window)
        anchor.performAction(for: owner, alert: alert, confirms: true)
        anchor.performAction(for: owner, alert: alert, confirms: true)
        // A late layout callback must not move the retiring popover's source
        // to a collapsed footer or the screen origin.
        footer.frame.origin.y = 0; anchor.frame = .zero
        anchor.setNeedsLayout(); anchor.layoutIfNeeded()
        if source.superview != nil {
            XCTAssertEqual(source.convert(source.bounds, to: window), expected)
            XCTAssertTrue(confirmed.isEmpty)
        }
        try await waitUntil { confirmed == [owner] }
        XCTAssertFalse(callbackSawVisibleAlert, "Mutation starts after the real UIKit presentation has ended")
        XCTAssertNil(source.superview)
        XCTAssertNil(footer.superview)
        XCTAssertEqual(host.subviews.filter { $0.accessibilityIdentifier == "synthetic-photo-progress" }.count, 1)
        XCTAssertNil(window.rootViewController?.presentedViewController)
    }

    @MainActor func testLiveTrashPopoverRetainsOneStableSourceThroughActualRotation() async throws {
        let window = try await makeWindow(size: CGSize(width: 402, height: 874), root: GalleryRotatingTestController())
        do {
            try await rotate(window, to: .portrait)
            let host = try XCTUnwrap(window.rootViewController?.view)
            let anchor = GalleryTrashAnchorView(frame: CGRect(x: window.bounds.width - 70,
                y: window.bounds.height - 110, width: 44, height: 44))
            anchor.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin]
            host.addSubview(anchor)
            var confirmed: [UUID] = [], dismissed: [UUID] = []
            let owner = UUID()
            anchor.update(requestID: owner, count: 177,
                onConfirm: { confirmed.append($0) }, onDismiss: { dismissed.append($0) })
            try await waitUntil { anchor.confirmation?.viewIfLoaded?.window != nil && anchor.confirmation?.isBeingPresented == false }
            let alert = try XCTUnwrap(anchor.confirmation)
            let source = try XCTUnwrap(alert.popoverPresentationController?.sourceView)
            for orientation in [UIInterfaceOrientation.landscapeLeft, .landscapeRight, .portrait] {
                try await rotate(window, to: orientation)
                let (actual, target) = try await waitForAnchoredPopover(alert, anchor: anchor, window: window)
                XCTAssertEqual(source.convert(source.bounds, to: window), target)
                XCTAssertTrue(anchor.confirmation === alert, "Rotation preserves the same native request")
                XCTAssertTrue(alert.popoverPresentationController?.sourceView === source)
                XCTAssertTrue(source.superview === window)
                XCTAssertEqual(alert.popoverPresentationController?.permittedArrowDirections, .down)
                XCTAssertLessThanOrEqual(actual.maxY, target.minY + 22)
                XCTAssertGreaterThan(actual.maxY, target.minY - 60)
                XCTAssertLessThanOrEqual(actual.maxX, window.bounds.width + 1)
                XCTAssertGreaterThanOrEqual(actual.minX, -1)
                XCTAssertLessThanOrEqual(actual.maxY, window.bounds.height + 1)
                XCTAssertGreaterThanOrEqual(actual.minY, -1)
                XCTAssertTrue(confirmed.isEmpty); XCTAssertTrue(dismissed.isEmpty)
            }
            anchor.close()
            try await waitUntil { window.rootViewController?.presentedViewController == nil }
            XCTAssertNil(source.superview)
            window.isHidden = true
        } catch {
            try? await rotate(window, to: .portrait)
            window.isHidden = true
            throw error
        }
    }

    @MainActor func testDismissalPendingActionCannotSurviveDetachedOwnerOrReplacementRequest() async throws {
        let window = try await makeWindow(size: CGSize(width: 402, height: 874))
        defer { window.isHidden = true }
        let host = try XCTUnwrap(window.rootViewController?.view)
        let anchor = GalleryTrashAnchorView(frame: CGRect(x: 332, y: 764, width: 44, height: 44))
        host.addSubview(anchor)
        var confirmed: [UUID] = [], dismissed: [UUID] = []
        let a = UUID(), b = UUID(), c = UUID()
        func update(_ id: UUID?) {
            anchor.update(requestID: id, count: id == nil ? 0 : 177,
                onConfirm: { confirmed.append($0) }, onDismiss: { dismissed.append($0) })
        }
        update(a)
        try await waitUntil { anchor.confirmation?.viewIfLoaded?.window != nil && anchor.confirmation?.isBeingPresented == false }
        let old = try XCTUnwrap(anchor.confirmation)
        let oldSource = try XCTUnwrap(old.popoverPresentationController?.sourceView)
        anchor.performAction(for: a, alert: old, confirms: true)
        update(b)
        try await waitUntil { anchor.confirmation?.viewIfLoaded?.window != nil && anchor.confirmation !== old && anchor.confirmation?.isBeingPresented == false }
        XCTAssertTrue(confirmed.isEmpty, "A replaced request cannot gain mutation authority after dismissal")
        XCTAssertTrue(dismissed.isEmpty)
        XCTAssertNil(oldSource.superview)
        let replacement = try XCTUnwrap(anchor.confirmation)
        let replacementSource = try XCTUnwrap(replacement.popoverPresentationController?.sourceView)
        anchor.performAction(for: b, alert: replacement, confirms: true)
        anchor.removeFromSuperview()
        try await waitUntil { window.rootViewController?.presentedViewController == nil }
        XCTAssertTrue(confirmed.isEmpty, "Leaving the surface revokes a not-yet-dispatched native action")
        XCTAssertTrue(dismissed.isEmpty)
        XCTAssertNil(replacementSource.superview)
        host.addSubview(anchor)
        update(c)
        try await waitUntil { anchor.confirmation?.viewIfLoaded?.window != nil && anchor.confirmation?.isBeingPresented == false }
        let current = try XCTUnwrap(anchor.confirmation)
        anchor.performAction(for: a, alert: old, confirms: true)
        anchor.performAction(for: b, alert: replacement, confirms: false)
        anchor.performAction(for: c, alert: current, confirms: false)
        try await waitUntil { dismissed == [c] }
        XCTAssertTrue(confirmed.isEmpty)
        XCTAssertNil(current.viewIfLoaded?.window)
    }

    /// Signals the production UIAlertAction entry point and then performs an
    /// actual external UIKit dismissal. This verifies the automatic-dismissal
    /// branch's ownership, not accessibility activation or a physical tap.
    @MainActor func testNativeActionSignalWaitsForExternalUIKitDismissalAndReleasesTheNextSheet() async throws {
        let anchor = GalleryTrashAnchorView(frame: .zero)
        let presenter = UIHostingController(rootView: Color.black.overlay(alignment: .bottomTrailing) {
            GalleryNativeTestAnchor(anchor: anchor).frame(width: 44, height: 44)
                .padding(.trailing, 26).padding(.bottom, 66)
        })
        let window = try await makeWindow(size: CGSize(width: 402, height: 874), root: presenter)
        defer { window.isHidden = true }
        try await waitUntil { anchor.window === window && anchor.bounds.width == 44 && anchor.bounds.height == 44 }
        var confirmed: [UUID] = [], dismissed: [UUID] = []
        var callbackSawAnAlert = false
        for kind in [GalleryPhotoConfirmationKind.move, .recover, .permanentlyDelete] {
            let owner = UUID()
            func update(_ id: UUID?) {
                anchor.update(requestID: id, count: id == nil ? 0 : 177, onConfirm: {
                    callbackSawAnAlert = callbackSawAnAlert || presenter.presentedViewController is UIAlertController
                    confirmed.append($0)
                }, onDismiss: { dismissed.append($0) }, kind: kind)
            }
            update(owner)
            try await waitUntil { anchor.confirmation?.viewIfLoaded?.window != nil && anchor.confirmation?.isBeingPresented == false }
            let alert = try XCTUnwrap(anchor.confirmation)
            let source = try XCTUnwrap(alert.popoverPresentationController?.sourceView)
            XCTAssertTrue(source.superview === window)
            let previous = confirmed.count
            anchor.performNativeAction(for: owner, alert: alert, confirms: true)
            XCTAssertFalse(alert.isBeingDismissed, "The native action branch observes; UIKit owns its dismissal")
            XCTAssertTrue(alert.viewIfLoaded?.window === window)
            XCTAssertEqual(confirmed.count, previous)
            // Real SwiftUI invalidations may still carry the snapshot that
            // created this action while its native dismissal is unwinding.
            for _ in 0..<8 { update(owner); await Task.yield() }
            XCTAssertEqual(confirmed.count, previous, "The callback cannot precede native dismissal")
            alert.dismiss(animated: true)
            try await waitUntil { confirmed.count == previous + 1 }
            XCTAssertEqual(confirmed.last, owner)
            XCTAssertNil(alert.presentingViewController)
            XCTAssertNil(alert.viewIfLoaded?.window)
            XCTAssertNil(source.superview)
            for _ in 0..<8 { update(owner); await Task.yield() }
            update(nil); update(owner)
            XCTAssertNil(anchor.confirmation, "Consumed snapshots cannot blink open another alert")
            XCTAssertNil(presenter.presentedViewController, "No zombie alert may hold the next Folder sheet")
            XCTAssertEqual(confirmed.count, previous + 1)
            XCTAssertTrue(dismissed.isEmpty)
            let folder = UIViewController()
            folder.modalPresentationStyle = .pageSheet
            presenter.present(folder, animated: false)
            try await waitUntil { presenter.presentedViewController === folder && folder.viewIfLoaded?.window === window }
            folder.dismiss(animated: false)
            try await waitUntil { presenter.presentedViewController == nil }
            XCTAssertFalse(callbackSawAnAlert, "The owner receives its action after UIKit fully releases presentation")
            update(nil)
        }
        XCTAssertEqual(confirmed.count, 3)
        XCTAssertEqual(Set(confirmed).count, 3)
        anchor.close()
    }
}
#endif
