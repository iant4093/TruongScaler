#if canImport(UIKit) && os(iOS)
import XCTest
import SwiftUI
import UIKit
import MMapCanvas
import TruongScalerCore
import CoreExport
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
final class ViewerEdgeCaseTests: XCTestCase {
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


    func testPortraitPhotoRotationPreservesScrollableVerticalAnchorWhenHorizontalAxisFits() throws {
        let source = try makeBuffer(name: "review-portrait", width: 1536, height: 2048, seed: 0.4)
        let model = ViewerModel(source: source, output: source, scaleFactor: 1)
        let harness = Harness(model: model, viewport: CGSize(width: 390, height: 844))
        defer { harness.window.isHidden = true }
        harness.pump()
        let scroll = try XCTUnwrap(harness.scrollView)
        let container = try XCTUnwrap(harness.containerView)
        scroll.setZoomScale(scroll.minimumZoomScale * 2, animated: false)
        harness.pump()
        scroll.contentOffset = CGPoint(x: 120, y: 150)
        harness.pump()
        let before = scroll.bounds.midY / (scroll.zoomScale * container.bounds.height)
        let relativeZoom = scroll.zoomScale / scroll.minimumZoomScale
        harness.layout(size: CGSize(width: 844, height: 390))
        harness.pump(6)
        let after = scroll.bounds.midY / (scroll.zoomScale * container.bounds.height)
        print("REVIEW_ROTATION_VERTICAL before=\(before) after=\(after) zoom=\(scroll.zoomScale) fit=\(scroll.minimumZoomScale)")
        XCTAssertEqual(scroll.zoomScale / scroll.minimumZoomScale, relativeZoom, accuracy: 0.02)
        XCTAssertLessThan(container.bounds.width * scroll.zoomScale, scroll.bounds.width)
        XCTAssertGreaterThan(container.bounds.height * scroll.zoomScale, scroll.bounds.height)
        XCTAssertEqual(after, before, accuracy: 0.025, "Scrollable vertical image anchor must survive rotation even when the other axis fits")
    }

    func testAtFitRotationStaysAtFitWhenNewMinimumIncreases() throws {
        let source = try makeBuffer(name: "review-fit", width: 2048, height: 1536, seed: 0.4)
        let model = ViewerModel(source: source, output: source, scaleFactor: 1)
        let harness = Harness(model: model, viewport: CGSize(width: 390, height: 844))
        defer { harness.window.isHidden = true }
        harness.pump()
        let scroll = try XCTUnwrap(harness.scrollView)
        let container = try XCTUnwrap(harness.containerView)
        XCTAssertEqual(scroll.zoomScale / scroll.minimumZoomScale, 1, accuracy: 0.01)
        harness.layout(size: CGSize(width: 844, height: 390))
        harness.pump(6)
        print("REVIEW_ROTATION_FIT zoom=\(scroll.zoomScale) fit=\(scroll.minimumZoomScale)")
        XCTAssertEqual(scroll.zoomScale, scroll.minimumZoomScale, accuracy: 0.001, "An aspect-fitted image must remain at fit on rotation")
        XCTAssertTrue(contains(visibleImageRect(scrollView: scroll, container: container), in: scroll.bounds, tolerance: 1))
    }
}
#endif
