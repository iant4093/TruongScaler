import XCTest
import Foundation
import CoreIngestion
import CryptoKit
@testable import DeepZoomGalleryUI

private struct GatedImageFileDecoder: StudioImageDecoding {
    let gate: TestGate
    private let decoder = BlockingStudioImageDecoder()
    func decodeImage(at url: URL, destinationMMapURL: URL) async throws -> DecodedSourceResult {
        await gate.hold()
        return try await decoder.decodeImage(at: url, destinationMMapURL: destinationMMapURL)
    }
}

private struct GatedAfterImageFileDecoder: StudioImageDecoding {
    let gate: TestGate
    private let decoder = BlockingStudioImageDecoder()
    func decodeImage(at url: URL, destinationMMapURL: URL) async throws -> DecodedSourceResult {
        let decoded = try await decoder.decodeImage(at: url, destinationMMapURL: destinationMMapURL)
        await gate.hold()
        return decoded
    }
}

final class DecodedPhotoCacheTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DecodeCache-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testRealDecodedMMapIsReusedAndSurvivesItsUnlinkedTemporaryPath() async throws {
        let input = try RealPipelineImageFixture.makePNG(in: root, name: "photo.png")
        let cache = CachingStudioImageDecoder(capacityBytes: 1024 * 1024)
        let first = try await cache.decodeImage(at: input, destinationMMapURL: root.appendingPathComponent("first.bin"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.sourceBuffer.fileURL.path))
        let second = try await cache.decodeImage(at: input, destinationMMapURL: root.appendingPathComponent("second.bin"))
        XCTAssertTrue(first.sourceBuffer === second.sourceBuffer)
        XCTAssertEqual(second.sourceBuffer.width, 48)
        XCTAssertGreaterThan(Float(second.sourceBuffer.unsafeRowPointer(y: 0).assumingMemoryBound(to: Float16.self)[3]), 0.99)
        await cache.purge()
        let third = try await cache.decodeImage(at: input, destinationMMapURL: root.appendingPathComponent("third.bin"))
        XCTAssertFalse(second.sourceBuffer === third.sourceBuffer)
    }

    func testSameSizeAndTimestampEditCannotReuseStalePixels() async throws {
        let input = root.appendingPathComponent("photo.png")
        try Data([1]).write(to: input)
        let date = try input.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let base = FakeDecoder(), cache = CachingStudioImageDecoder(base: base, capacityBytes: 4096)
        _ = try await cache.decodeImage(at: input, destinationMMapURL: root.appendingPathComponent("first.bin"))
        _ = try await cache.decodeImage(at: input, destinationMMapURL: root.appendingPathComponent("same.bin"))
        XCTAssertEqual(base.recordedDecodeURLs.count, 1)
        try Data([2]).write(to: input)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: input.path)
        _ = try await cache.decodeImage(at: input, destinationMMapURL: root.appendingPathComponent("changed.bin"))
        XCTAssertEqual(base.recordedDecodeURLs.count, 2)
    }

    func testFileReplacementDuringDecodeCannotPoisonTheOriginalContentKey() async throws {
        let file = try RealPipelineImageFixture.makePNG(in: root, name: "edited.png", width: 48, height: 32)
        let original = try Data(contentsOf: file), gate = TestGate()
        let cache = CachingStudioImageDecoder(base: GatedImageFileDecoder(gate: gate), capacityBytes: 1024 * 1024)
        let pendingURL = root.appendingPathComponent("pending.bin"), restoredURL = root.appendingPathComponent("restored.bin")
        let request = Task { try await cache.decodeImage(at: file, destinationMMapURL: pendingURL) }
        await gate.entered.wait()
        defer { gate.open() }
        // An ordinary editor/provider replacement while the decode queue is occupied.
        try RealPipelineImageFixture.makePNG(in: root, name: file.lastPathComponent, width: 64, height: 32)
        gate.open()
        do { _ = try await request.value; XCTFail("A source replaced during opening must be refused") }
        catch { XCTAssertTrue(error is CachedImageDecodeError) }
        try original.write(to: file, options: .atomic)
        let restored = try await cache.decodeImage(at: file, destinationMMapURL: restoredURL)
        XCTAssertEqual(restored.sourceBuffer.width, 48, "A restored original must not reuse pixels decoded after its bytes changed")
        XCTAssertEqual(restored.sourceBuffer.height, 32)
    }

    func testVerifiedSourceRemovalAfterDecodeRefusesAndDoesNotPoisonRetry() async throws {
        let file = try RealPipelineImageFixture.makePNG(in: root, name: "disappearing.png")
        let original = try Data(contentsOf: file), gate = TestGate()
        let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let cache = CachingStudioImageDecoder(base: GatedAfterImageFileDecoder(gate: gate), capacityBytes: 1024 * 1024)
        let firstURL = root.appendingPathComponent("removed.bin"), restoredURL = root.appendingPathComponent("retry.bin")
        let request = Task { try await cache.decodeImage(at: file, destinationMMapURL: firstURL, validatedContentSHA256: digest) }
        await gate.entered.wait()
        defer { gate.open() }
        try FileManager.default.removeItem(at: file)
        gate.open()
        do { _ = try await request.value; XCTFail("A vanished verified source cannot produce a saved-result frame") }
        catch { XCTAssertTrue(error is CachedImageDecodeError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        let bytes = await cache.retainedBytes
        XCTAssertEqual(bytes, 0)
        try original.write(to: file, options: .atomic)
        let restored = try await cache.decodeImage(at: file, destinationMMapURL: restoredURL, validatedContentSHA256: digest)
        XCTAssertEqual(restored.sourceBuffer.width, 48)
    }

    func testMemoryWarningPurgePreventsAnInflightDecodeFromRepopulatingCache() async throws {
        let file = root.appendingPathComponent("gated.png"), destination = root.appendingPathComponent("pending.bin")
        try Data([1]).write(to: file)
        let base = FakeDecoder(), gate = TestGate()
        base.setGate(gate, forFileName: "gated.png")
        let cache = CachingStudioImageDecoder(base: base, capacityBytes: 4096)
        let request = Task { try await cache.decodeImage(at: file, destinationMMapURL: destination) }
        await gate.entered.wait()
        await cache.purge()
        gate.open()
        _ = try await request.value
        let bytes = await cache.retainedBytes
        XCTAssertEqual(bytes, 0)
    }

    func testLRUEvictionAndOversizedFramesStayWithinBudget() async throws {
        let base = FakeDecoder(), cache = CachingStudioImageDecoder(base: base, capacityBytes: 8 * 6 * 8)
        for name in ["a.png", "b.png", "a.png"] {
            let file = root.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) { try Data(name.utf8).write(to: file) }
            _ = try await cache.decodeImage(at: file, destinationMMapURL: root.appendingPathComponent(UUID().uuidString))
            let bytes = await cache.retainedBytes
            XCTAssertLessThanOrEqual(bytes, 8 * 6 * 8)
        }
        XCTAssertEqual(base.recordedDecodeURLs.count, 3)
        let tiny = CachingStudioImageDecoder(base: base, capacityBytes: 1)
        let file = root.appendingPathComponent("a.png")
        _ = try await tiny.decodeImage(at: file, destinationMMapURL: root.appendingPathComponent("large.bin"))
        let bytes = await tiny.retainedBytes
        XCTAssertEqual(bytes, 0)
    }

    func testPrivatePreviewHasNoOrphanablePathAndSurvivesCachePurgeForItsReader() async throws {
        let file = try RealPipelineImageFixture.makePNG(in: root, name: "lifetime.png")
        let destination = root.appendingPathComponent("private-preview.bin")
        let cache = CachingStudioImageDecoder(capacityBytes: 1024 * 1024)
        var frame: DecodedSourceResult? = try await cache.decodeImage(at: file, destinationMMapURL: destination)
        await cache.purge()
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "Only a private preview path is unlinked; its live mmap remains readable")
        XCTAssertEqual(frame?.sourceBuffer.width, 48)
        XCTAssertGreaterThan(Float(try XCTUnwrap(frame).sourceBuffer.unsafePixelPointer(x: 1, y: 1)[3]), 0.99)
        frame = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "Private decoded previews must not accumulate after cache eviction")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testCancellingOneSharedDecodeReaderDoesNotCancelTheOther() async throws {
        let file = root.appendingPathComponent("shared.png"), base = FakeDecoder(), gate = TestGate()
        let inputBytes = Data([1, 2, 3])
        try inputBytes.write(to: file)
        base.setGate(gate, forFileName: file.lastPathComponent)
        let cache = CachingStudioImageDecoder(base: base, capacityBytes: 4096)
        let digest = SHA256.hash(data: inputBytes).map { String(format: "%02x", $0) }.joined()
        let one = root.appendingPathComponent("one.bin"), two = root.appendingPathComponent("two.bin")
        let first = Task { try await cache.decodeImage(at: file, destinationMMapURL: one, validatedContentSHA256: digest) }
        await gate.entered.wait()
        let other = Task { try await cache.decodeImage(at: file, destinationMMapURL: two, validatedContentSHA256: digest) }
        try await Task.sleep(for: .milliseconds(30))
        first.cancel()
        gate.open()
        do { _ = try await first.value; XCTFail("The cancelled reader should leave after draining") } catch is CancellationError {}
        let decoded = try await other.value
        XCTAssertEqual(decoded.sourceBuffer.width, 8)
        XCTAssertEqual(base.recordedDecodeURLs.count, 1)
    }
}
