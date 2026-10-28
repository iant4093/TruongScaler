#if canImport(UIKit)
import XCTest
import UIKit
import SwiftUI
import Observation
@testable import DeepZoomGalleryUI
@MainActor @Observable private final class InteractivePagerFixture {
    let ids = [UUID().uuidString, UUID().uuidString, UUID().uuidString]
    let images: [CGImage]
    var index = 1
    var enabled = true
    var revision = 0
    var reduceMotion = false
    var progress: CGFloat = 0
    var steps: [Int] = []
    init() throws {
        images = try [[UInt8(230), 8, 8, 255], [8, 230, 8, 255], [8, 8, 230, 255]].map { pixel in
            try XCTUnwrap(displayImage(bytes: (0..<(40*30)).flatMap { _ in pixel }, width: 40, height: 30))
        }
    }
    func adjacent(_ delta: Int) -> ViewerAdjacentPage? {
        let target = index + delta
        return ids.indices.contains(target) ? ViewerAdjacentPage(captureID: ids[target], image: images[target]) : nil
    }
    func step(_ delta: Int) {
        guard enabled, ids.indices.contains(index + delta) else { return }
        index += delta; steps.append(index)
    }
}
private struct InteractivePagerFixtureView: View {
    let fixture: InteractivePagerFixture
    var body: some View {
        InteractiveOriginalPager(image: fixture.images[fixture.index], captureID: fixture.ids[fixture.index],
            position: fixture.index,
            previousCaptureID: fixture.index > 0 ? fixture.ids[fixture.index-1] : nil,
            nextCaptureID: fixture.index < 2 ? fixture.ids[fixture.index+1] : nil,
            previousPage: fixture.adjacent(-1), nextPage: fixture.adjacent(1),
            hasPrevious: fixture.index > 0, hasNext: fixture.index < 2,
            navigationEnabled: fixture.enabled,
            context: ViewerPagingContext(revision: String(fixture.revision), rootURL: nil),
            reduceMotion: fixture.reduceMotion, toggleChrome: {}, previous: { fixture.step(-1) },
            next: { fixture.step(1) }, selectPage: { displayedID, targetID in
                guard fixture.enabled, fixture.ids[fixture.index] == displayedID,
                      let target = fixture.ids.firstIndex(of: targetID), abs(target-fixture.index) == 1 else { return false }
                fixture.step(target-fixture.index)
                return true
            }, pagingProgress: { fixture.progress = $0 })
            .ignoresSafeArea()
    }
}

final class InteractivePagingNativeTests: XCTestCase {
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The hosted interactive photo pager did not reach the expected layout")
        throw CocoaError(.featureUnsupported)
    }
    @MainActor private func findPager(_ view: UIView) -> OriginalPagerView? {
        if let pager = view as? OriginalPagerView { return pager }
        return view.subviews.compactMap(findPager).first
    }
    @MainActor private func host(_ fixture: InteractivePagerFixture) async throws -> (UIWindow, OriginalPagerView) {
        try await wait { UIApplication.shared.connectedScenes.contains { $0 is UIWindowScene } }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: InteractivePagerFixtureView(fixture: fixture))
        window.makeKeyAndVisible()
        try await wait { self.findPager(window).map { $0.bounds.width > 0 && $0.scroll.minimumZoomScale > 0.0001 } == true }
        return (window, try XCTUnwrap(findPager(window)))
    }
    @MainActor private func begin(_ pager: OriginalPagerView, x: CGFloat) {
        pager.updatePan(state: .began, translation: .zero, velocity: CGPoint(x: x < 0 ? -300 : 300, y: 0))
        pager.updatePan(state: .changed, translation: CGPoint(x: x, y: 0), velocity: .zero)
    }
    @MainActor private func color(_ view: UIView, at point: CGPoint) throws -> [UInt8] {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
        let cg = try XCTUnwrap(image.cgImage)
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let x = min(width-1, max(0, Int(point.x * image.scale)))
        let y = min(height-1, max(0, Int(point.y * image.scale)))
        return Array(bytes[((y * width + x) * 4)..<((y * width + x) * 4 + 4)])
    }

    @MainActor func testHalfDragRendersBothActualPhotosAndReversesBeforeCommit() async throws {
        let f = try InteractivePagerFixture(), (window, pager) = try await host(f)
        defer { window.isHidden = true; window.rootViewController = nil }
        let width = pager.bounds.width
        begin(pager, x: -width/2)
        XCTAssertEqual(pager.track.transform.tx, -width/2, accuracy: 0.1)
        XCTAssertTrue(pager.isDragging); XCTAssertTrue(f.steps.isEmpty)
        XCTAssertTrue(pager.scroll.imageView.image?.cgImage === f.images[1])
        XCTAssertTrue(pager.nextCanvas.image?.cgImage === f.images[2])
        let current = try color(pager, at: CGPoint(x: width*0.20, y: pager.bounds.midY))
        let next = try color(pager, at: CGPoint(x: width*0.80, y: pager.bounds.midY))
        XCTAssertGreaterThan(Int(current[1]), Int(current[2])+100, "The exposed left half must contain actual green current pixels")
        XCTAssertGreaterThan(Int(next[2]), Int(next[1])+100, "The exposed right half must contain actual blue adjacent pixels")
        pager.updatePan(state: .changed, translation: CGPoint(x: width*0.40, y: 0), velocity: .zero)
        XCTAssertEqual(pager.track.transform.tx, width*0.40, accuracy: 0.1)
        let previous = try color(pager, at: CGPoint(x: width*0.15, y: pager.bounds.midY))
        XCTAssertGreaterThan(Int(previous[0]), Int(previous[1])+100, "Reversing the same drag exposes the previous red photo")
        pager.updatePan(state: .cancelled, translation: .zero, velocity: .zero)
        try await wait { pager.track.layer.animationKeys()?.isEmpty != false }
        XCTAssertEqual(f.index, 1); XCTAssertTrue(f.steps.isEmpty)
        XCTAssertEqual(pager.track.transform, .identity)
    }

    @MainActor func testCommittedPanKeepsCanvasAndMatchingIdentityThenAllowsPreviousAndEndpoints() async throws {
        let f = try InteractivePagerFixture(), (window, pager) = try await host(f)
        defer { window.isHidden = true; window.rootViewController = nil }
        let scroll = pager.scroll, width = pager.bounds.width
        begin(pager, x: -width*0.55)
        pager.updatePan(state: .ended, translation: CGPoint(x: -width*0.55, y: 0), velocity: .zero)
        try await wait { f.index == 2 && pager.configuration.captureID == f.ids[2] }
        XCTAssertTrue(pager.scroll === scroll)
        XCTAssertTrue(scroll.imageView.image?.cgImage === f.images[2]); XCTAssertTrue(scroll.isAtFitSize)
        XCTAssertEqual(pager.track.transform, .identity)
        begin(pager, x: -width*0.7)
        XCTAssertEqual(pager.dragOffset, -width*0.7*0.18, accuracy: 0.1, "The final page has bounded edge resistance")
        pager.updatePan(state: .ended, translation: CGPoint(x: -width*0.7, y: 0), velocity: .zero)
        XCTAssertEqual(f.steps, [2])
        begin(pager, x: width*0.5)
        pager.updatePan(state: .ended, translation: CGPoint(x: width*0.5, y: 0), velocity: .zero)
        try await wait { f.index == 1 && pager.configuration.captureID == f.ids[1] }
        XCTAssertEqual(f.steps, [2,1]); XCTAssertTrue(pager.scroll === scroll)
    }

    @MainActor func testShortPanZoomMutationAndChangedRootRejectNavigation() async throws {
        let f = try InteractivePagerFixture(), (window, pager) = try await host(f)
        defer { window.isHidden = true; window.rootViewController = nil }
        begin(pager, x: -35)
        pager.updatePan(state: .ended, translation: CGPoint(x: -35, y: 0), velocity: .zero)
        XCTAssertTrue(f.steps.isEmpty); XCTAssertEqual(pager.track.transform, .identity)
        pager.scroll.setZoomScale(pager.scroll.minimumZoomScale*2, animated: false)
        XCTAssertFalse(pager.mayBegin(velocity: CGPoint(x: -500, y: 0)))
        begin(pager, x: -250); XCTAssertFalse(pager.isDragging)
        pager.scroll.setZoomScale(pager.scroll.minimumZoomScale, animated: false)
        XCTAssertFalse(pager.mayBegin(velocity: CGPoint(x: 10, y: 500)), "Vertical drag remains owned by dismissal")
        begin(pager, x: -250); f.enabled = false
        try await wait { !pager.configuration.navigationEnabled }
        pager.updatePan(state: .ended, translation: CGPoint(x: -250, y: 0), velocity: .zero)
        XCTAssertTrue(f.steps.isEmpty); XCTAssertEqual(pager.track.transform, .identity)
        f.enabled = true
        try await wait { pager.configuration.navigationEnabled }
        begin(pager, x: -250); f.revision += 1
        try await wait { pager.configuration.context.revision == "1" }
        pager.updatePan(state: .ended, translation: CGPoint(x: -250, y: 0), velocity: .zero)
        XCTAssertTrue(f.steps.isEmpty); XCTAssertEqual(pager.track.transform, .identity)
        try await wait { f.progress == 0 }
        begin(pager, x: -180)
        XCTAssertGreaterThan(f.progress, 0)
        pager.bounds.size = CGSize(width: 874, height: 402)
        pager.setNeedsLayout(); pager.layoutIfNeeded()
        try await wait { f.progress == 0 }
        XCTAssertFalse(pager.isDragging); XCTAssertEqual(pager.track.transform, .identity)
        XCTAssertTrue(f.steps.isEmpty, "Changing viewport geometry cancels the old-axis gesture")
    }

    @MainActor func testDisappearanceCancelsUnfinishedPanAndReduceMotionCommitsWithoutAutoplaySlide() async throws {
        let f = try InteractivePagerFixture(); f.reduceMotion = true
        let (window, pager) = try await host(f)
        defer { window.isHidden = true; window.rootViewController = nil }
        begin(pager, x: -210); pager.invalidate()
        pager.updatePan(state: .ended, translation: CGPoint(x: -210, y: 0), velocity: .zero)
        XCTAssertTrue(f.steps.isEmpty)
        begin(pager, x: -210)
        pager.updatePan(state: .ended, translation: CGPoint(x: -210, y: 0), velocity: .zero)
        try await wait { f.index == 2 && pager.configuration.captureID == f.ids[2] }
        XCTAssertTrue(pager.track.layer.animationKeys()?.isEmpty != false)
        XCTAssertTrue(pager.scroll.layer.animationKeys()?.isEmpty != false)
        XCTAssertEqual(pager.track.transform, .identity)
        XCTAssertTrue(pager.scroll.imageView.image?.cgImage === f.images[2])
    }
}
#endif

#if canImport(UIKit)
private func displayImage(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}
#endif
