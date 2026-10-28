import XCTest
import Foundation
import CoreIngestion
import TruongScalerCore
import CryptoKit
@testable import DeepZoomGalleryUI

final class LibraryPerformanceTests: XCTestCase {
    func testCancelledOffscreenThumbnailSkipsItsQueuedDecode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ThumbnailQueue-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try RealPipelineImageFixture.makePNG(in: root, name: "photo.png")
        let owner = BlockingIOOwner(label: "test.thumbnail-queue"), entered = TestSignal(), release = DispatchSemaphore(value: 0)
        let blocked = Task { await owner.runInfallible { entered.signal(); release.wait() } }
        await entered.wait()
        let reader = ImageIOThumbnailReader(owner: owner)
        let request = Task { await reader.readThumbnail(at: image, maxPixelSize: 256) }
        request.cancel(); release.signal(); await blocked.value
        let cancelledImage = await request.value
        XCTAssertNil(cancelledImage)
        let currentImage = await reader.readThumbnail(at: image, maxPixelSize: 256)
        XCTAssertNotNil(currentImage, "The queue must still serve current cells")
    }

    @MainActor func testLargeGalleryGroupingKeepsStableSectionsAndInputOrder() throws {
        let date = Date(timeIntervalSince1970: 1_740_000_000)
        let photos = (0..<5_000).map { index in
            let url = URL(fileURLWithPath: "/gallery/\(index).dng")
            return LibraryPhotoItem(id: url.path, fileURL: url, filename: url.lastPathComponent,
                capturedAt: date.addingTimeInterval(Double(index % 5) * -86_400), byteCount: 1)
        }
        let start = ContinuousClock.now
        let sections = StudioViewModel.groupLibraryItems(photos)
        print("REVIEW_GROUP_5000_SECONDS \(start.duration(to: .now))")
        XCTAssertEqual(sections.count, 5)
        XCTAssertEqual(sections.flatMap(\.items).count, photos.count)
        for section in sections {
            XCTAssertEqual(section.items.map(\.id), photos.filter {
                Calendar.current.isDate($0.capturedAt, inSameDayAs: section.items[0].capturedAt)
            }.map(\.id))
        }
        XCTAssertEqual(StudioViewModel.groupLibraryItems([]), [])
    }

    func testConcurrentIdenticalDecodesShareOneUnderlyingRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DecodeCoalescing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.png"), base = FakeDecoder(), gate = TestGate()
        let inputBytes = Data([4, 5, 6])
        try inputBytes.write(to: file)
        let digest = SHA256.hash(data: inputBytes).map { String(format: "%02x", $0) }.joined()
        base.setGate(gate, forFileName: file.lastPathComponent)
        let cache = CachingStudioImageDecoder(base: base, capacityBytes: 4096)
        let requests = (0..<8).map { index in Task {
            try await cache.decodeImage(at: file, destinationMMapURL: root.appendingPathComponent("\(index).bin"),
                validatedContentSHA256: digest)
        } }
        await gate.entered.wait()
        defer { gate.open() }
        try await Task.sleep(for: .milliseconds(40))
        let actualReads = base.recordedDecodeURLs.count
        gate.open()
        var frames: [DecodedSourceResult] = []
        for request in requests { frames.append(try await request.value) }
        XCTAssertEqual(actualReads, 1, "Concurrent requests for identical bytes should not queue duplicate full decodes")
        XCTAssertTrue(frames.allSatisfy { $0.sourceBuffer === frames[0].sourceBuffer })
    }
}
