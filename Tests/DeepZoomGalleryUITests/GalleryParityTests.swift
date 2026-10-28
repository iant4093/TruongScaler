import XCTest
import TruongScalerCore
@testable import DeepZoomGalleryUI

final class GalleryParityTests: XCTestCase {
    func testRangeSweepAddsContractsDeselectsAndRejectsUnknownIdentity() throws {
        let ids = (0..<12).map(String.init)
        let sweep = try XCTUnwrap(GalleryRangeSelection(orderedIDs: ids, anchorID: "3", baseline: ["0"]))
        XCTAssertEqual(sweep.selection(through: "8"), Set(["0"] + Array(ids[3...8])))
        XCTAssertEqual(sweep.selection(through: "4"), ["0", "3", "4"])
        XCTAssertNil(sweep.selection(through: "other root"))
        let deselect = try XCTUnwrap(GalleryRangeSelection(orderedIDs: ids, anchorID: "3", baseline: Set(ids)))
        XCTAssertEqual(deselect.selection(through: "8"), Set(ids).subtracting(ids[3...8]))
    }
    func testBatchCompactTitleKeepsPhotoCountThroughTileAndSavePhases() {
        var progress = JobProgressPresentation(completedTiles: 1, totalTiles: 234)
        progress.batchPhotoNumber = 2; progress.batchPhotoCount = 5
        XCTAssertEqual(progress.compactTitle, "Processing 2/5")
        progress.completedTiles = 234; progress.isSavingOutput = true
        XCTAssertEqual(progress.compactTitle, "Processing 2/5")
        progress.isStopping = true
        XCTAssertEqual(progress.compactTitle, "Stopping…")
    }
}

#if canImport(UIKit)
import UIKit

extension GalleryParityTests {
    @MainActor private func image(_ color: UIColor) throws -> CGImage {
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { ctx in color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30)) }
        return try XCTUnwrap(rendered.cgImage)
    }
    @MainActor func testInputPreviewCoalescesForegroundReadsAndPublishesIdentityWithPixels() async throws {
        let model = InputPhotoBrowser(), gate = TestGate()
        let urls = (0..<4).map { URL(fileURLWithPath: "/fixture/\($0).dng") }
        let items = urls.map { LibraryPhotoItem(id: $0.path, fileURL: $0, filename: $0.lastPathComponent, capturedAt: Date(), byteCount: 1) }
        let first = try image(.red), last = try image(.blue)
        var reads: [URL] = []
        let loader: @MainActor (URL) async -> CGImage? = { url in
            reads.append(url)
            if url == urls[0] { await gate.hold(); return first }
            return last
        }
        model.request(urls[0], items: items, context: "root-a", load: loader)
        await gate.entered.wait()
        model.request(urls[1], items: items, context: "root-a", load: loader)
        model.request(urls[3], items: items, context: "root-a", load: loader)
        gate.open()
        for _ in 0..<100 where model.displayedURL != urls[3] { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.displayedURL, urls[3])
        XCTAssertTrue(model.image === last)
        XCTAssertFalse(reads.contains(urls[1]), "A superseded foreground target must not enqueue another RAW preview read")
        XCTAssertLessThanOrEqual(model.cache.count, 3)
        model.cancel()
    }
    @MainActor func testInputPreviewRootChangeAndDisappearanceFenceOldCompletion() async throws {
        let model = InputPhotoBrowser(), gate = TestGate()
        let a = URL(fileURLWithPath: "/root-a/a.dng"), b = URL(fileURLWithPath: "/root-b/b.dng")
        let red = try image(.red), blue = try image(.blue)
        model.request(a, items: [], context: "a") { _ in await gate.hold(); return red }
        await gate.entered.wait()
        model.request(b, items: [], context: "b") { _ in blue }
        for _ in 0..<100 where model.displayedURL != b { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.displayedURL, b)
        model.cancel(); gate.open()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.displayedURL, b); XCTAssertTrue(model.image === blue)
        XCTAssertNil(model.cache[a])
    }
}
#endif
