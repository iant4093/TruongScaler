import XCTest
import Foundation
import CoreExport
import TruongScalerCore
@testable import DeepZoomGalleryUI

final class PhotoIOBenchmarkTests: XCTestCase {
    func testFullResolutionDNGSaveAndReopenBenchmark() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TRUONGSCALER_RUN_IO_BENCHMARK"] == "1", "Explicit 48 MP I/O benchmark")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoIOBenchmark-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try RealPipelineImageFixture.makePNG(in: root, name: "source.png", width: 3024, height: 4032)
        let artifact = try StudioTestArtifacts.make(directory: root, sourceURL: input, configuredScale: .x2,
            sourceWidth: 3024, sourceHeight: 4032, grain: 0.15, denoiseMode: .off, didRunDenoise: false)
        let exportStart = ContinuousClock.now
        let exported = try await BlockingStudioImageExporter().exportDetailed(artifacts: artifact,
            destinationURL: root.appendingPathComponent("output.dng"), overrideFormat: .linearDNG16Bit, overrideGrainAmount: 0.15)
        let exportSeconds = Self.seconds(exportStart.duration(to: .now))
        let decoder = BlockingStudioImageDecoder()
        let decodeStart = ContinuousClock.now
        let decoded = try await decoder.decodeImage(at: exported.url, destinationMMapURL: root.appendingPathComponent("decoded.bin"))
        let decodeSeconds = Self.seconds(decodeStart.duration(to: .now))
        XCTAssertEqual(decoded.sourceBuffer.width, 6048)
        XCTAssertEqual(decoded.sourceBuffer.height, 8064)
        XCTAssertEqual(decoded.metadata.upscaledByAppFactor, 2)
        print("PHOTO_IO_BENCHMARK exportSeconds=\(exportSeconds) decodeSeconds=\(decodeSeconds) width=6048 height=8064 grain=0.15")
    }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
