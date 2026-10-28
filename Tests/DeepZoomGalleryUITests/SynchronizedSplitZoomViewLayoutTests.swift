#if canImport(UIKit) && os(iOS)
import XCTest
import SwiftUI
import UIKit
import MMapCanvas
import TruongScalerCore
import CoreExport
import TiledInferenceEngine
@testable import DeepZoomGalleryUI

/// Executed iOS regressions for the real production `UIScrollView` viewer.
///
/// The bug reported on the phone was a lifecycle bug: the production representable fitted only from
/// `updateUIView`, compared a zoom-transformed `frame` with the unscaled canvas, and centered with
/// insets that did not account for the current offset. These tests therefore mount the *actual*
/// `SynchronizedSplitZoomView` / `MMapTiledImageView` view hierarchy in a laid-out `UIWindow` through
/// a real `UIHostingController`. They do not test a geometry helper, a macOS conditional, or a
/// build-only branch.
@MainActor
final class SynchronizedSplitZoomViewLayoutTests: XCTestCase {
    private var workingDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplitZoomLayout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
        }
        workingDirectory = nil
        try await super.tearDown()
    }

    // MARK: - Production surfaces

    /// Observable model driving repeated SwiftUI updates, mirroring chrome/grain/split/progress
    /// publications that previously reset the viewer.
    @MainActor
    final class ViewerModel: ObservableObject {
        @Published var source: MMapBuffer
        @Published var output: MMapBuffer
        @Published var scaleFactor: Int
        @Published var grain: Float
        @Published var split: CGFloat
        @Published var tick: Int = 0

        init(source: MMapBuffer, output: MMapBuffer, scaleFactor: Int, grain: Float = 0.15, split: CGFloat = 0.5) {
            self.source = source
            self.output = output
            self.scaleFactor = scaleFactor
            self.grain = grain
            self.split = split
        }
    }

    struct ViewerHost: View {
        @ObservedObject var model: ViewerModel

        var body: some View {
            SynchronizedSplitZoomView(
                sourceBuffer: model.source,
                outputBuffer: model.output,
                scaleFactor: model.scaleFactor,
                grainAmount: model.grain,
                splitFraction: Binding(
                    get: { model.split },
                    set: { model.split = $0 }
                ),
                onSingleTap: {}
            )
            .ignoresSafeArea()
        }
    }

    @MainActor
    private final class Harness {
        let window: UIWindow
        let host: UIHostingController<ViewerHost>
        let model: ViewerModel

        init(model: ViewerModel, viewport: CGSize) {
            self.model = model
            self.host = UIHostingController(rootView: ViewerHost(model: model))
            self.window = UIWindow(frame: CGRect(origin: .zero, size: viewport))
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }

        func layout(size: CGSize) {
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = CGRect(origin: .zero, size: size)
            window.layoutIfNeeded()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            pump()
        }

        func pump(_ iterations: Int = 4) {
            for _ in 0..<iterations {
                window.layoutIfNeeded()
                host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }

        var scrollView: UIScrollView? {
            descendants(of: host.view).compactMap { $0 as? UIScrollView }.first
        }

        var containerView: UIView? {
            guard let scrollView else { return nil }
            return scrollView.subviews.first(where: { view in
                view.subviews.contains(where: { $0 is MMapTiledImageView })
            })
        }

        /// The production hierarchy adds the original (nearest-neighbor) view first and the
        /// processed (upscaled + live grain) view second.
        var processedView: MMapTiledImageView? {
            guard let containerView else { return nil }
            return containerView.subviews.compactMap { $0 as? MMapTiledImageView }.last
        }

        private func descendants(of root: UIView) -> [UIView] {
            var result: [UIView] = [root]
            for child in root.subviews {
                result.append(contentsOf: descendants(of: child))
            }
            return result
        }

        isolated deinit {
            window.isHidden = true
        }
    }

    // MARK: - Fixtures

    private func makeBuffer(name: String, width: Int, height: Int, seed: Float16) throws -> MMapBuffer {
        let buffer = try MMapBuffer(
            fileURL: workingDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).rgba16f"),
            width: width,
            height: height,
            createIfMissing: true
        )
        for y in 0..<height {
            let row = buffer.unsafeRowPointer(y: y).bindMemory(to: Float16.self, capacity: width * 4)
            for x in 0..<width {
                let base = x * 4
                row[base] = seed
                row[base + 1] = Float16(Float(x % 16) / 16.0)
                row[base + 2] = Float16(Float(y % 16) / 16.0)
                row[base + 3] = 1.0
            }
        }
        try buffer.flushToDisk(synchronous: true)
        return buffer
    }

    private func aspectFitScale(viewport: CGSize, canvas: CGSize) -> CGFloat {
        min(viewport.width / canvas.width, viewport.height / canvas.height)
    }

    /// Rect of the zoom target in scroll-view coordinates. Includes the zoom transform, the content
    /// offset and the centering insets, so it reflects what the human actually sees.
    private func visibleImageRect(
        scrollView: UIScrollView,
        container: UIView
    ) -> CGRect {
        scrollView.convert(container.bounds, from: container)
    }


    /// Tolerance-aware containment check in scroll-view content coordinates.
    private func contains(_ rect: CGRect, in bounds: CGRect, tolerance: CGFloat) -> Bool {
        rect.minX >= bounds.minX - tolerance
            && rect.minY >= bounds.minY - tolerance
            && rect.maxX <= bounds.maxX + tolerance
            && rect.maxY <= bounds.maxY + tolerance
    }

    func testPhotoSwipesAndDownwardDismissalAreGatedByActualZoom() throws {
        let source = try makeBuffer(name: "paging", width: 640, height: 480, seed: 0.4)
        let harness = Harness(model: ViewerModel(source: source, output: source, scaleFactor: 1), viewport: CGSize(width: 390, height: 844))
        defer { harness.window.isHidden = true }
        harness.pump()
        let scroll = try XCTUnwrap(harness.scrollView)
        let owner = try XCTUnwrap(scroll.delegate as? SplitZoomCoordinator)
        var steps: [Int] = [], dismissals = 0
        owner.onStep = { steps.append($0) }
        owner.onDismiss = { dismissals += 1 }
        let swipes = (scroll.gestureRecognizers ?? []).compactMap { $0 as? UISwipeGestureRecognizer }
        XCTAssertEqual(Set(swipes.map { $0.direction.rawValue }), [UISwipeGestureRecognizer.Direction.left.rawValue, UISwipeGestureRecognizer.Direction.right.rawValue])
        XCTAssertTrue(swipes.allSatisfy { owner.gestureRecognizerShouldBegin($0) })
        owner.navigatePhoto(1); owner.navigatePhoto(-1)
        XCTAssertEqual(steps, [1,-1])
        scroll.setZoomScale(scroll.minimumZoomScale * 2, animated: false)
        harness.pump()
        XCTAssertFalse(swipes.contains { owner.gestureRecognizerShouldBegin($0) })
        owner.navigatePhoto(1)
        owner.updateDismissal(state: .ended, translation: CGPoint(x: 0, y: 240), velocity: CGPoint(x: 0, y: 1200))
        XCTAssertEqual(steps, [1,-1], "Zoomed panning must never navigate to another photo")
        XCTAssertEqual(dismissals, 0)
        scroll.setZoomScale(scroll.minimumZoomScale, animated: false)
        harness.pump()
        owner.updateDismissal(state: .changed, translation: CGPoint(x: 0, y: 180), velocity: .zero)
        XCTAssertGreaterThan(scroll.transform.ty, 100)
        owner.updateDismissal(state: .ended, translation: CGPoint(x: 0, y: 180), velocity: .zero)
        XCTAssertEqual(dismissals, 1)
    }

    // MARK: - 1. First display is aspect-fit and centered

    func testFirstDisplayShowsWholeLandscapePhotoCenteredInPortraitViewport() throws {
        let source = try makeBuffer(name: "src", width: 2048, height: 1536, seed: 0.5)
        let model = ViewerModel(source: source, output: source, scaleFactor: 1)
        let harness = Harness(model: model, viewport: CGSize(width: 390, height: 844))
        defer { harness.window.isHidden = true }
        harness.pump()

        let scroll = try XCTUnwrap(harness.scrollView)
        let container = try XCTUnwrap(harness.containerView)
        let fit = aspectFitScale(viewport: scroll.bounds.size, canvas: container.bounds.size)

        XCTAssertEqual(scroll.zoomScale, fit, accuracy: fit * 0.01,
                       "First display must be aspect-fit, not 1:1/maximum zoom")
        XCTAssertEqual(scroll.minimumZoomScale, fit, accuracy: fit * 0.01,
                       "Minimum zoom must be the valid aspect-fit scale")

        let visible = visibleImageRect(scrollView: scroll, container: container)
        XCTAssertEqual(visible.midX, scroll.bounds.midX, accuracy: 1.0, "Fitted photo must be horizontally centered")
        XCTAssertEqual(visible.midY, scroll.bounds.midY, accuracy: 1.0, "Fitted photo must be vertically centered")
        XCTAssertEqual(visible.width, scroll.bounds.width, accuracy: 1.5)
        XCTAssertEqual(visible.height, scroll.bounds.width * container.bounds.height / container.bounds.width, accuracy: 1.5)
        XCTAssertTrue(contains(visible, in: scroll.bounds, tolerance: 1.0),
                      "Aspect-fit image must fit inside the viewport; got \(visible) in \(scroll.bounds)")
    }

    func testFirstDisplayShowsWholePortraitPhotoCenteredInLandscapeViewport() throws {
        let source = try makeBuffer(name: "portrait-src", width: 1536, height: 2048, seed: 0.5)
        let model = ViewerModel(source: source, output: source, scaleFactor: 1)
        let harness = Harness(model: model, viewport: CGSize(width: 844, height: 390))
        defer { harness.window.isHidden = true }
        harness.pump()

        let scroll = try XCTUnwrap(harness.scrollView)
        let container = try XCTUnwrap(harness.containerView)
        let fit = aspectFitScale(viewport: scroll.bounds.size, canvas: container.bounds.size)

        XCTAssertEqual(scroll.zoomScale, fit, accuracy: fit * 0.01)
        let visible = visibleImageRect(scrollView: scroll, container: container)
        XCTAssertEqual(visible.midX, scroll.bounds.midX, accuracy: 1.0)
        XCTAssertEqual(visible.midY, scroll.bounds.midY, accuracy: 1.0)
        XCTAssertEqual(visible.height, scroll.bounds.height, accuracy: 1.5)
        XCTAssertTrue(contains(visible, in: scroll.bounds, tolerance: 1.0))
    }

    // MARK: - 2. Repeated updates while zoomed must not reset/compound

    func testRepeatedChromeGrainAndSplitUpdatesPreserveZoomAndRegion() throws {
        let source = try makeBuffer(name: "zoom-src", width: 2048, height: 1536, seed: 0.4)
        let model = ViewerModel(source: source, output: source, scaleFactor: 1)
        let harness = Harness(model: model, viewport: CGSize(width: 390, height: 844))
        defer { harness.window.isHidden = true }
        harness.pump()

        let scroll = try XCTUnwrap(harness.scrollView)
        let fit = scroll.minimumZoomScale
        XCTAssertGreaterThan(fit, 0.01)
        scroll.setZoomScale(fit * 3.0, animated: false)
        harness.pump()
        scroll.contentOffset = CGPoint(x: scroll.contentSize.width * 0.35, y: scroll.contentSize.height * 0.4)
        harness.pump()

        let zoomBefore = scroll.zoomScale
        let offsetBefore = scroll.contentOffset

        for index in 0..<12 {
            // Grain, split and an unrelated chrome/progress publication all re-render the
            // representable. None of these is a true image/viewport change.
            model.grain = index.isMultiple(of: 2) ? 0.2 : 0.8
            model.split = index.isMultiple(of: 2) ? 0.35 : 0.65
            model.tick += 1
            harness.pump(2)
        }

        XCTAssertEqual(scroll.zoomScale, zoomBefore, accuracy: zoomBefore * 0.002,
                       "Chrome/grain/split updates must not reset or compound the user's zoom")
        XCTAssertEqual(scroll.contentOffset.x, offsetBefore.x, accuracy: 2.0,
                       "Chrome/grain/split updates must not jump the visible image region")
        XCTAssertEqual(scroll.contentOffset.y, offsetBefore.y, accuracy: 2.0)
    }

    // MARK: - 3. Zoom-out returns to a centered full image (not a tiny corner)

    func testZoomOutFromZoomedStateReturnsToCenteredAspectFit() throws {
        let source = try makeBuffer(name: "out-src", width: 2048, height: 1536, seed: 0.3)
        let model = ViewerModel(source: source, output: source, scaleFactor: 1)
        let harness = Harness(model: model, viewport: CGSize(width: 390, height: 844))
        defer { harness.window.isHidden = true }
        harness.pump()

        let scroll = try XCTUnwrap(harness.scrollView)
        let container = try XCTUnwrap(harness.containerView)
        let fit = scroll.minimumZoomScale

        // Zoom in, pan far into the image, then simulate a pinch back to minimum zoom.
        scroll.setZoomScale(fit * 4.0, animated: false)
        harness.pump()
        scroll.contentOffset = CGPoint(x: scroll.contentSize.width - scroll.bounds.width,
                                       y: scroll.contentSize.height - scroll.bounds.height)
        harness.pump()
        scroll.setZoomScale(fit, animated: false)
        harness.pump()

        XCTAssertEqual(scroll.zoomScale, fit, accuracy: fit * 0.01)
        let visible = visibleImageRect(scrollView: scroll, container: container)
        XCTAssertEqual(visible.midX, scroll.bounds.midX, accuracy: 1.5, "Zoom-out must re-center horizontally")
        XCTAssertEqual(visible.midY, scroll.bounds.midY, accuracy: 1.5, "Zoom-out must re-center vertically")
        XCTAssertEqual(visible.width, scroll.bounds.width, accuracy: 1.5,
                       "Zoom-out must show the full aspect-fit width, not a tiny corner")
        XCTAssertGreaterThan(visible.width * visible.height, scroll.bounds.width * scroll.bounds.height * 0.2,
                             "The fitted photo must occupy a meaningful part of the viewport")
    }

    // MARK: - 4. True image changes

    func testSameSizedDifferentPhotoRefitsAndRecenters() throws {
        let sourceA = try makeBuffer(name: "photo-a", width: 2048, height: 1536, seed: 0.2)
        let sourceB = try makeBuffer(name: "photo-b", width: 2048, height: 1536, seed: 0.7)
        let model = ViewerModel(source: sourceA, output: sourceA, scaleFactor: 1)
        let harness = Harness(model: model, viewport: CGSize(width: 390, height: 844))
        defer { harness.window.isHidden = true }
        harness.pump()

        let scroll = try XCTUnwrap(harness.scrollView)
        scroll.setZoomScale(scroll.minimumZoomScale * 3.0, animated: false)
        harness.pump()
        XCTAssertGreaterThan(scroll.zoomScale, scroll.minimumZoomScale * 2.0)

        model.source = sourceB
        model.output = sourceB
        harness.pump(6)

        let container = try XCTUnwrap(harness.containerView)
        let fit = aspectFitScale(viewport: scroll.bounds.size, canvas: container.bounds.size)
        XCTAssertEqual(scroll.zoomScale, fit, accuracy: fit * 0.02,
                       "A same-sized different photo must fit anew, not inherit the old zoom")
        let visible = visibleImageRect(scrollView: scroll, container: container)
        XCTAssertEqual(visible.midX, scroll.bounds.midX, accuracy: 1.5)
        XCTAssertEqual(visible.midY, scroll.bounds.midY, accuracy: 1.5)
    }

    func testOutputCanvasAppearingAfterCompletionFitsTheNewResult() throws {
        let source = try makeBuffer(name: "result-src", width: 400, height: 300, seed: 0.3)
        let output = try makeBuffer(name: "result-out", width: 1600, height: 1200, seed: 0.6)
        let model = ViewerModel(source: source, output: source, scaleFactor: 1)
        let harness = Harness(model: model, viewport: CGSize(width: 390, height: 844))
        defer { harness.window.isHidden = true }
        harness.pump()

        let scroll = try XCTUnwrap(harness.scrollView)
        scroll.setZoomScale(scroll.minimumZoomScale * 2.5, animated: false)
        harness.pump()

        model.output = output
        model.scaleFactor = 4
        harness.pump(6)

        let container = try XCTUnwrap(harness.containerView)
        XCTAssertEqual(container.bounds.size, CGSize(width: 1600, height: 1200))
        let fit = aspectFitScale(viewport: scroll.bounds.size, canvas: container.bounds.size)
        XCTAssertEqual(scroll.zoomScale, fit, accuracy: fit * 0.02,
                       "The new 4x output canvas must be fitted, not shown at the old canvas zoom")
        let visible = visibleImageRect(scrollView: scroll, container: container)
        XCTAssertEqual(visible.midX, scroll.bounds.midX, accuracy: 1.5)
        XCTAssertEqual(visible.midY, scroll.bounds.midY, accuracy: 1.5)
        XCTAssertTrue(contains(visible, in: scroll.bounds, tolerance: 1.0))
    }

    // MARK: - 5. Rotation / viewport changes

    func testRotationPreservesRelativeZoomAndImageAnchorWithoutDrift() throws {
        let source = try makeBuffer(name: "rot-src", width: 2048, height: 1536, seed: 0.5)
        let model = ViewerModel(source: source, output: source, scaleFactor: 1)
        let harness = Harness(model: model, viewport: CGSize(width: 390, height: 844))
        defer { harness.window.isHidden = true }
        harness.pump()

        let scroll = try XCTUnwrap(harness.scrollView)
        let oldFit = scroll.minimumZoomScale
        scroll.setZoomScale(oldFit * 3.0, animated: false)
        harness.pump()
        scroll.contentOffset = CGPoint(x: scroll.contentSize.width * 0.30, y: scroll.contentSize.height * 0.35)
        harness.pump()

        // Anchor point in normalized image coordinates at the viewport center.
        let container = try XCTUnwrap(harness.containerView)
        // `bounds.mid` already includes the scroll view's content offset; dividing by zoom gives the
        // canvas point under the visible center.
        let centerInContainer = CGPoint(
            x: scroll.bounds.midX / scroll.zoomScale,
            y: scroll.bounds.midY / scroll.zoomScale
        )
        let anchor = CGPoint(x: centerInContainer.x / container.bounds.width,
                             y: centerInContainer.y / container.bounds.height)
        let zoomRatioBefore = scroll.zoomScale / oldFit

        harness.layout(size: CGSize(width: 844, height: 390))
        harness.pump(6)

        let newFit = scroll.minimumZoomScale
        XCTAssertEqual(scroll.zoomScale / newFit, zoomRatioBefore, accuracy: 0.08,
                       "Rotation must preserve the relative zoom (no reset/compound loop)")
        let containerAfter = try XCTUnwrap(harness.containerView)
        let centerAfter = CGPoint(
            x: scroll.bounds.midX / scroll.zoomScale,
            y: scroll.bounds.midY / scroll.zoomScale
        )
        XCTAssertEqual(centerAfter.x / containerAfter.bounds.width, anchor.x, accuracy: 0.03,
                       "Rotation must preserve the image-relative anchor")
        XCTAssertEqual(centerAfter.y / containerAfter.bounds.height, anchor.y, accuracy: 0.03)
        XCTAssertTrue(scroll.zoomScale >= newFit - 0.001)

        // Repeated layout passes must not drift.
        let zoomAfterFirst = scroll.zoomScale
        let offsetAfterFirst = scroll.contentOffset
        harness.pump(8)
        XCTAssertEqual(scroll.zoomScale, zoomAfterFirst, accuracy: zoomAfterFirst * 0.002)
        XCTAssertEqual(scroll.contentOffset.x, offsetAfterFirst.x, accuracy: 2.0)
        XCTAssertEqual(scroll.contentOffset.y, offsetAfterFirst.y, accuracy: 2.0)
    }

    // MARK: - 6. Split-mask registration

    func testSplitMaskRegistersWithTheScreenDividerAcrossZoomAndPan() throws {
        let source = try makeBuffer(name: "split-src", width: 2048, height: 1536, seed: 0.4)
        let model = ViewerModel(source: source, output: source, scaleFactor: 1, split: 0.3)
        let harness = Harness(model: model, viewport: CGSize(width: 390, height: 844))
        defer { harness.window.isHidden = true }
        harness.pump()

        let scroll = try XCTUnwrap(harness.scrollView)
        let container = try XCTUnwrap(harness.containerView)
        let processed = try XCTUnwrap(harness.processedView)
        scroll.setZoomScale(scroll.minimumZoomScale * 2.2, animated: false)
        harness.pump()
        scroll.contentOffset = CGPoint(x: scroll.contentSize.width * 0.25, y: scroll.contentSize.height * 0.2)
        harness.pump()

        // Force the delegate callbacks the same way UIScrollView does during a live gesture.
        scroll.delegate?.scrollViewDidZoom?(scroll)
        scroll.delegate?.scrollViewDidScroll?(scroll)
        harness.pump(2)

        let mask = try XCTUnwrap(processed.layer.mask as? CAShapeLayer)
        let path = try XCTUnwrap(mask.path)
        let expected = (scroll.contentOffset.x + scroll.bounds.width * 0.3) / scroll.zoomScale
        let maskStart = path.boundingBox.minX
        XCTAssertEqual(maskStart, expected, accuracy: 1.0,
                       "Split mask must use real coordinate conversion (offset+inset+zoom)")
        XCTAssertEqual(path.boundingBox.width, container.bounds.width - expected, accuracy: 1.0)
        XCTAssertEqual(path.boundingBox.height, container.bounds.height, accuracy: 0.5)
    }

    func testLandscapePhotoRotationPreservesScrollableHorizontalAnchorWhenVerticalAxisFits() throws {
        let source = try makeBuffer(name: "rot-h", width: 2048, height: 1536, seed: 0.35)
        let model = ViewerModel(source: source, output: source, scaleFactor: 1)
        let harness = Harness(model: model, viewport: CGSize(width: 844, height: 390))
        defer { harness.window.isHidden = true }
        harness.pump()

        let scroll = try XCTUnwrap(harness.scrollView)
        let container = try XCTUnwrap(harness.containerView)
        let oldFit = scroll.minimumZoomScale
        scroll.setZoomScale(oldFit * 2, animated: false)
        harness.pump()
        scroll.contentOffset = CGPoint(x: 140, y: 40)
        harness.pump()
        let anchorBefore = CGPoint(
            x: scroll.bounds.midX / (scroll.zoomScale * container.bounds.width),
            y: scroll.bounds.midY / (scroll.zoomScale * container.bounds.height)
        )

        harness.layout(size: CGSize(width: 390, height: 844))
        harness.pump(6)
        XCTAssertGreaterThan(container.bounds.width * scroll.zoomScale, scroll.bounds.width)
        XCTAssertLessThan(container.bounds.height * scroll.zoomScale, scroll.bounds.height)
        let anchorAfter = CGPoint(
            x: scroll.bounds.midX / (scroll.zoomScale * container.bounds.width),
            y: scroll.bounds.midY / (scroll.zoomScale * container.bounds.height)
        )
        XCTAssertEqual(anchorAfter.x, anchorBefore.x, accuracy: 0.025,
                       "A scrollable horizontal anchor must survive when the vertical axis fits")
        XCTAssertEqual(anchorAfter.y, 0.5, accuracy: 0.02, "The fitting axis stays centered")

        // Split/mask registration must survive the same rotation.
        let processed = try XCTUnwrap(harness.processedView)
        scroll.delegate?.scrollViewDidZoom?(scroll)
        scroll.delegate?.scrollViewDidScroll?(scroll)
        harness.pump(2)
        let mask = try XCTUnwrap(processed.layer.mask as? CAShapeLayer)
        let path = try XCTUnwrap(mask.path)
        let expectedMaskX = (scroll.contentOffset.x + scroll.bounds.width * model.split) / scroll.zoomScale
        XCTAssertEqual(path.boundingBox.minX, expectedMaskX, accuracy: 1.0)

        // Rotate back; repeated transitions must not compound or drift.
        harness.layout(size: CGSize(width: 844, height: 390))
        harness.pump(6)
        let zoomAfter = scroll.zoomScale
        harness.pump(8)
        XCTAssertEqual(scroll.zoomScale, zoomAfter, accuracy: zoomAfter * 0.002)
        XCTAssertEqual(scroll.bounds.midX / (scroll.zoomScale * container.bounds.width), anchorBefore.x, accuracy: 0.03)
    }

    // MARK: - 7. Degenerate and repeated lifecycle

    func testZeroBoundsThenValidBoundsFitsAndRepeatedUpdatesAreNeutral() throws {
        let source = try makeBuffer(name: "zero-src", width: 2048, height: 1536, seed: 0.5)
        let model = ViewerModel(source: source, output: source, scaleFactor: 1)
        let harness = Harness(model: model, viewport: .zero)
        defer { harness.window.isHidden = true }
        harness.pump(2)
        XCTAssertNoThrow(harness.scrollView)

        harness.layout(size: CGSize(width: 390, height: 844))
        harness.pump(6)
        let scroll = try XCTUnwrap(harness.scrollView)
        let container = try XCTUnwrap(harness.containerView)
        let fit = aspectFitScale(viewport: scroll.bounds.size, canvas: container.bounds.size)
        XCTAssertEqual(scroll.zoomScale, fit, accuracy: fit * 0.02,
                       "Zero->non-zero bounds must trigger the first fit")

        let zoom = scroll.zoomScale
        let offset = scroll.contentOffset
        for _ in 0..<10 {
            model.tick += 1
            harness.pump(1)
        }
        XCTAssertEqual(scroll.zoomScale, zoom, accuracy: zoom * 0.002)
        XCTAssertEqual(scroll.contentOffset.x, offset.x, accuracy: 1.0)
        XCTAssertEqual(scroll.contentOffset.y, offset.y, accuracy: 1.0)
    }

    // MARK: - 8. Double tap

    func testDoubleTapTogglesFitAndUsefulZoomCenteredAtTap() throws {
        let source = try makeBuffer(name: "dt-src", width: 2048, height: 1536, seed: 0.5)
        let model = ViewerModel(source: source, output: source, scaleFactor: 1)
        let harness = Harness(model: model, viewport: CGSize(width: 390, height: 844))
        defer { harness.window.isHidden = true }
        harness.pump()

        let scroll = try XCTUnwrap(harness.scrollView)
        let container = try XCTUnwrap(harness.containerView)
        let coordinator = try XCTUnwrap(scroll.delegate as? SplitZoomCoordinator)
        let fit = scroll.minimumZoomScale
        XCTAssertEqual(scroll.zoomScale, fit, accuracy: fit * 0.01)

        // Tap inside the fitted image and toward the right; the target image point must stay under
        // that viewport point after zooming, not jump to the image center.
        let tapScreenPoint = CGPoint(x: scroll.bounds.width * 0.6, y: scroll.bounds.height * 0.5)
        let tapCanvasPoint = CGPoint(
            x: (scroll.contentOffset.x + tapScreenPoint.x) / scroll.zoomScale,
            y: (scroll.contentOffset.y + tapScreenPoint.y) / scroll.zoomScale
        )
        XCTAssertLessThanOrEqual(tapCanvasPoint.x, container.bounds.width)
        XCTAssertLessThanOrEqual(tapCanvasPoint.y, container.bounds.height)
        coordinator.performDoubleTap(atViewportPoint: tapScreenPoint)
        harness.pump(6)

        XCTAssertEqual(scroll.zoomScale, min(scroll.maximumZoomScale, fit * 4.0), accuracy: fit * 0.1)
        // Screen position of the tapped image point: content point × zoom − contentOffset.
        let zoomAfter = scroll.zoomScale
        let renderedX = tapCanvasPoint.x * zoomAfter - scroll.contentOffset.x
        let renderedY = tapCanvasPoint.y * zoomAfter - scroll.contentOffset.y
        XCTAssertEqual(renderedX, tapScreenPoint.x, accuracy: 2.0,
                       "Double-tap zoom must keep the tapped image point under the tap")
        XCTAssertEqual(renderedY, tapScreenPoint.y, accuracy: 2.0)

        coordinator.performDoubleTap(atViewportPoint: tapScreenPoint)
        harness.pump(8)
        XCTAssertEqual(scroll.zoomScale, fit, accuracy: fit * 0.02,
                       "Second double tap returns to aspect fit")
        let visible = visibleImageRect(scrollView: scroll, container: container)
        XCTAssertEqual(visible.midX, scroll.bounds.midX, accuracy: 1.5)
        XCTAssertEqual(visible.midY, scroll.bounds.midY, accuracy: 1.5)
    }

    func testCaptureProgressDetailsBusyPausedFailedAndCompleted() throws {
        func presentation(
            phase: PipelinePhase,
            stage: JobStage,
            title: String,
            detail: String,
            completed: Int,
            total: Int,
            current: Int?,
            average: Double?,
            eta: Int?,
            didDenoise: Bool?
        ) -> JobProgressPresentation {
            JobProgressPresentation(
                jobID: UUID(uuidString: "00000000-0000-0000-0000-000000000123"),
                phase: phase,
                title: title,
                detail: detail,
                completedTiles: completed,
                totalTiles: total,
                currentTileNumber: current,
                elapsedSeconds: 42.5,
                tileLoopElapsedSeconds: 41.8,
                estimatedSecondsRemaining: eta,
                averageSecondsPerTile: average,
                sourceWidth: 6000,
                sourceHeight: 4000,
                outputWidth: 24000,
                outputHeight: 16000,
                modelName: "QuickSRNet_Large_x2_256",
                requestedCompute: "all (CPU+GPU+ANE requested)",
                tileSize: 256,
                tileOverlap: 24,
                gridColumns: 24,
                gridRows: 16,
                timings: PipelineTileTimings(
                    extractionSeconds: 0.004,
                    modelSeconds: 1.22,
                    stabilitySeconds: 0.0,
                    reconstructionSeconds: 0.004,
                    journalSeconds: 0.008,
                    blendSeconds: 0.053,
                    flushSeconds: 0.002,
                    checkpointSeconds: 0.001,
                    cleanupSeconds: 0.001
                ),
                didRunDenoise: didDenoise,
                isStopping: false
            )
        }

        func snapshot(_ progress: JobProgressPresentation, name: String) throws {
            let host = UIHostingController(rootView: ProcessingDetailsSheet(progress: progress))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            for _ in 0..<6 {
                window.layoutIfNeeded()
                host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { context in
                window.backgroundColor = .black
                host.view.backgroundColor = .black
                host.view.layer.render(in: context.cgContext)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            let evidenceDirectory = URL(fileURLWithPath: "/tmp/truongscaler-viewer-evidence", isDirectory: true)
            try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
            if let png = image.pngData() {
                try? png.write(to: evidenceDirectory.appendingPathComponent("\(name).png"))
            }
            window.isHidden = true
        }

        try snapshot(
            presentation(
                phase: .predictingSuperResolution,
                stage: .denoisingAndUpscalingTiles,
                title: "Upscaling tile 4 of 10",
                detail: "Running QuickSRNet_Large_x2_256.",
                completed: 3,
                total: 10,
                current: 3,
                average: 2.1,
                eta: 15,
                didDenoise: false
            ),
            name: "details-busy"
        )
        try snapshot(
            presentation(
                phase: .paused,
                stage: .pausedOnDisk,
                title: "Paused",
                detail: "Stopped at a durable tile boundary.",
                completed: 3,
                total: 10,
                current: nil,
                average: 2.1,
                eta: nil,
                didDenoise: false
            ),
            name: "details-paused"
        )
        var waiting = JobProgressPresentation(phase: .completed, completedTiles: 234, totalTiles: 234,
            estimatedSecondsRemaining: 0)
        waiting.batchPhotoNumber = 2; waiting.batchPhotoCount = 5
        waiting.isWaitingForForeground = true
        try snapshot(waiting, name: "details-batch-waiting")
        let barHost = UIHostingController(rootView: ProcessingProgressBarView(progress: waiting,
            onStop: {}, onShowDetails: {}).padding().background(Color.black))
        let barWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 160))
        barWindow.rootViewController = barHost
        barWindow.makeKeyAndVisible()
        barWindow.layoutIfNeeded(); barHost.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let barImage = UIGraphicsImageRenderer(bounds: barWindow.bounds).image {
            barHost.view.layer.render(in: $0.cgContext)
        }
        let directory = URL(fileURLWithPath: "/tmp/truongscaler-viewer-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(barImage.pngData()).write(to: directory.appendingPathComponent("bar-batch-waiting.png"))
        let barAttachment = XCTAttachment(image: barImage)
        barAttachment.name = "bar-batch-waiting"; barAttachment.lifetime = .keepAlways
        add(barAttachment)
        barWindow.isHidden = true

        try snapshot(
            presentation(
                phase: .failed,
                stage: .failed,
                title: "Failed",
                detail: "Processing failed.",
                completed: 3,
                total: 10,
                current: nil,
                average: 2.1,
                eta: nil,
                didDenoise: false
            ),
            name: "details-failed"
        )
        try snapshot(
            presentation(
                phase: .completed,
                stage: .completed,
                title: "Complete",
                detail: "Result is ready to inspect.",
                completed: 10,
                total: 10,
                current: nil,
                average: 2.0,
                eta: 0,
                didDenoise: false
            ),
            name: "details-completed"
        )
    }

    // MARK: - 9. Screenshots of the actual production viewer chrome

    func testCaptureViewerScreenshotsPortraitLandscapeOriginalAndResult() throws {
        // Tiny synthetic canvases keep the screenshot fixture public/synthetic; the production
        // viewer/chrome code path is unchanged.
        let source = try makeBuffer(name: "shot-src", width: 600, height: 400, seed: 0.45)
        let output = try makeBuffer(name: "shot-out", width: 1200, height: 800, seed: 0.65)
        let metadata = ImageMetadataPacket(
            sourceURL: workingDirectory.appendingPathComponent("synthetic-fixture.dng"),
            utTypeIdentifier: "com.adobe.dng",
            category: .cameraRAW,
            originalWidth: 600,
            originalHeight: 400,
            isoSpeedRatings: 800
        )

        func makeViewModel(upscaled: Bool) -> StudioViewModel {
            let viewModel = StudioViewModel()
            viewModel.sourceURL = metadata.sourceURL
            viewModel.metadata = metadata
            viewModel.sourceBuffer = source
            viewModel.outputBuffer = upscaled ? output : source
            viewModel.currentStage = upscaled ? .readyForInspection : .idle
            return viewModel
        }

        func descendants(of root: UIView) -> [UIView] {
            var result: [UIView] = [root]
            for child in root.subviews { result.append(contentsOf: descendants(of: child)) }
            return result
        }

        func snapshot(
            _ viewModel: StudioViewModel,
            size: CGSize,
            name: String,
            zoomFactor: CGFloat = 1.0,
            rotateTo: CGSize? = nil
        ) throws {
            let host = UIHostingController(rootView: StudioWorkspaceView(viewModel: viewModel))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            for _ in 0..<6 {
                window.layoutIfNeeded()
                host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            }
            if zoomFactor != 1.0, let scroll = descendants(of: host.view).compactMap({ $0 as? UIScrollView }).first {
                scroll.setZoomScale(scroll.minimumZoomScale * zoomFactor, animated: false)
                for _ in 0..<4 {
                    window.layoutIfNeeded()
                    host.view.layoutIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                }
            }
            if let rotateTo {
                window.frame = CGRect(origin: .zero, size: rotateTo)
                host.view.frame = CGRect(origin: .zero, size: rotateTo)
                window.layoutIfNeeded()
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                for _ in 0..<6 {
                    window.layoutIfNeeded()
                    host.view.layoutIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                }
            }
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { context in
                // A standalone XCTest agent has no attached UIWindowScene, so `drawHierarchy` can
                // return a blank canvas. Render the real view hierarchy's layers directly; the
                // viewer chrome and layout are the production view tree either way.
                window.backgroundColor = .black
                host.view.backgroundColor = .black
                host.view.layer.render(in: context.cgContext)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            // The simulator shares the host /tmp filesystem; this also saves the actual render for
            // the stage evidence bundle without changing production code.
            let evidenceDirectory = URL(fileURLWithPath: "/tmp/truongscaler-viewer-evidence", isDirectory: true)
            try? FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
            if let png = image.pngData() {
                try? png.write(to: evidenceDirectory.appendingPathComponent("\(name).png"))
            }
            window.isHidden = true
        }

        try snapshot(makeViewModel(upscaled: false), size: CGSize(width: 390, height: 844), name: "viewer-original-portrait")
        try snapshot(makeViewModel(upscaled: true), size: CGSize(width: 390, height: 844), name: "viewer-result-portrait")
        try snapshot(makeViewModel(upscaled: true), size: CGSize(width: 390, height: 844), name: "viewer-result-portrait-zoomed", zoomFactor: 3.0)
        try snapshot(makeViewModel(upscaled: true), size: CGSize(width: 844, height: 390), name: "viewer-result-landscape")
        try snapshot(
            makeViewModel(upscaled: true),
            size: CGSize(width: 390, height: 844),
            name: "viewer-result-rotated-landscape",
            rotateTo: CGSize(width: 844, height: 390)
        )
    }
    func testComparisonControlsStayInsideFittedPhotoAndFollowZoomAndRotation() throws {
        let source = try makeBuffer(name: "comparison-photo", width: 1200, height: 800, seed: 0.5)
        let model = ViewerModel(source: source, output: source, scaleFactor: 1)
        let harness = Harness(model: model, viewport: CGSize(width: 390, height: 844))
        defer { harness.window.isHidden = true }
        harness.pump()
        let scroll = try XCTUnwrap(harness.scrollView as? SplitZoomScrollView)
        let container = try XCTUnwrap(harness.containerView)
        let overlay = scroll.comparisonOverlay
        var photo = visibleImageRect(scrollView: scroll, container: container).intersection(scroll.bounds)
        XCTAssertFalse(overlay.isHidden)
        XCTAssertEqual(overlay.frame.minY, photo.minY, accuracy: 1)
        XCTAssertEqual(overlay.frame.height, photo.height, accuracy: 1)
        XCTAssertLessThan(overlay.frame.height, scroll.bounds.height * 0.5)
        XCTAssertEqual(overlay.divider.frame.height, photo.height, accuracy: 1)
        XCTAssertTrue(overlay.clipsToBounds)
        XCTAssertFalse(overlay.point(inside: CGPoint(x: 10, y: 10), with: nil))
        overlay.changeFraction(to: 0.3)
        harness.pump()
        XCTAssertEqual(model.split, 0.3, accuracy: 0.001)
        XCTAssertEqual(overlay.divider.frame.midX, photo.width * 0.3, accuracy: 1)

        scroll.setZoomScale(scroll.minimumZoomScale * 3, animated: false)
        scroll.contentOffset = CGPoint(x: 100, y: 20)
        harness.pump()
        photo = visibleImageRect(scrollView: scroll, container: container).intersection(scroll.bounds)
        XCTAssertEqual(overlay.frame.height, photo.height, accuracy: 1)
        XCTAssertEqual(overlay.frame.width, photo.width, accuracy: 1)
        harness.layout(size: CGSize(width: 844, height: 390))
        photo = visibleImageRect(scrollView: scroll, container: container).intersection(scroll.bounds)
        XCTAssertEqual(overlay.frame.minY, photo.minY, accuracy: 1)
        XCTAssertEqual(overlay.frame.height, photo.height, accuracy: 1)
    }

    func testComparisonMaskUsesPhotoWidthWhenPortraitPhotoIsLetterboxed() throws {
        let source = try makeBuffer(name: "comparison-portrait", width: 800, height: 1200, seed: 0.5)
        let model = ViewerModel(source: source, output: source, scaleFactor: 1, split: 0.2)
        let harness = Harness(model: model, viewport: CGSize(width: 844, height: 390))
        defer { harness.window.isHidden = true }
        harness.pump()
        let scroll = try XCTUnwrap(harness.scrollView as? SplitZoomScrollView)
        let processed = try XCTUnwrap(harness.processedView)
        let mask = try XCTUnwrap(processed.layer.mask as? CAShapeLayer)
        let rect = try XCTUnwrap(mask.path).boundingBoxOfPath
        XCTAssertEqual(rect.minX, CGFloat(source.width) * 0.2, accuracy: 1)
        XCTAssertEqual(scroll.comparisonOverlay.frame.width, 260, accuracy: 1)
        scroll.comparisonOverlay.accessibilityIncrement()
        harness.pump()
        XCTAssertEqual(model.split, 0.3, accuracy: 0.001)
        model.split = 1
        harness.pump()
        XCTAssertTrue(scroll.comparisonOverlay.isHidden)
    }

}
#endif
