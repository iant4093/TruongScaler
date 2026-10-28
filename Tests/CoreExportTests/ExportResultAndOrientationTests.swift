import XCTest
import Foundation
import CoreGraphics
import ImageIO
import CoreIngestion
@testable import CoreExport
@testable import TiledInferenceEngine
@testable import MMapCanvas
@testable import TruongScalerCore

/// Review-cycle regressions for R7 (upright artifact factor metadata) and the R6 detailed export
/// result (final grain-blended component peak / DNG headroom scale).
final class ExportResultAndOrientationTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ExportResultAndOrientationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    // MARK: - R7: direct review probe

    /// Exact review probe: a 2x3 source with EXIF orientation 6 decodes upright to 3x2, so a 2x
    /// result is 6x4 and must be tagged `UpscaledFactor=2x`, never `4x`.
    func testReviewProbeUprightOrientationSixExportsTwoX() throws {
        let packet = ImageMetadataPacket(
            sourceURL: URL(fileURLWithPath: "/tmp/review-portrait.jpg"),
            utTypeIdentifier: "public.jpeg",
            category: .standardOpaqueRaster,
            originalWidth: 2,
            originalHeight: 3,
            originalOrientation: 6
        )
        let properties = MetadataReinjector.buildDestinationProperties(
            from: packet,
            upscaledWidth: 6,
            upscaledHeight: 4,
            exportFormat: .tiff16BitLZW
        )
        let comment = try userComment(in: properties)
        XCTAssertTrue(comment.contains("UpscaledFactor=2x"), "Actual 2x portrait result was tagged: \(comment)")
        XCTAssertFalse(comment.contains("UpscaledFactor=4x"))
    }

    /// Actual exported raster metadata readback for every transposing orientation (5...8) at both
    /// 2x and 4x. The decoded (upright) source buffer is 12x16 for a 16x12 EXIF original, so a 2x
    /// artifact is 24x32 and a 4x artifact is 48x64; the tag must describe that artifact ratio.
    func testRasterExportTagsActualArtifactFactorForOrientationsFiveThroughEight() throws {
        let formats: [ExportFormat] = [.tiff16BitLZW, .png16Bit, .jpeg95]
        for orientation in 5...8 {
            for scale in [2, 4] {
                for format in formats {
                    let artifacts = try makeArtifacts(orientation: orientation, scale: scale)
                    let destination = tempDirectory.appendingPathComponent(
                        "orientation-\(orientation)-\(scale)x-\(format.rawValue)."
                            + fileExtension(for: format)
                    )
                    let result = try FormatAwareExporter.exportImageDetailed(
                        artifacts: artifacts,
                        destinationURL: destination,
                        overrideFormat: format,
                        overrideGrainAmount: 0
                    )
                    XCTAssertEqual(result.actualScaleFactor, scale)
                    XCTAssertEqual(
                        result.url, destination,
                        "Detailed export did not publish to the destination"
                    )
                    let comment = try exportedUserComment(at: destination)
                    XCTAssertTrue(
                        comment.contains("UpscaledFactor=\(scale)x"),
                        "Orientation \(orientation) \(scale)x \(format.rawValue) tagged: \(comment)"
                    )
                    XCTAssertFalse(
                        comment.contains("UpscaledFactor=\(scale == 2 ? 4 : 2)x"),
                        "Orientation \(orientation) \(scale)x \(format.rawValue) got the wrong factor: \(comment)"
                    )
                }
            }
        }
    }

    /// HEIC capability is host-dependent, so this runs only where a HEIC encoder exists; the factor
    /// rule is identical to the other containers.
    func testHEICExportTagsActualArtifactFactorWhenHostEncoderExists() throws {
        try XCTSkipUnless(Self.hasHEICEncoder(), "HEIC encoder unavailable on this host")
        for orientation in 5...8 {
            for scale in [2, 4] {
                let artifacts = try makeArtifacts(orientation: orientation, scale: scale)
                let destination = tempDirectory.appendingPathComponent(
                    "orientation-\(orientation)-\(scale)x.heic"
                )
                let result = try FormatAwareExporter.exportImageDetailed(
                    artifacts: artifacts,
                    destinationURL: destination,
                    overrideFormat: .heic10BitHDR,
                    overrideGrainAmount: 0
                )
                XCTAssertEqual(result.actualScaleFactor, scale)
                let comment = try exportedUserComment(at: destination)
                XCTAssertTrue(
                    comment.contains("UpscaledFactor=\(scale)x"),
                    "HEIC orientation \(orientation) \(scale)x tagged: \(comment)"
                )
                XCTAssertFalse(comment.contains("UpscaledFactor=\(scale == 2 ? 4 : 2)x"))
            }
        }
    }

    /// The exported filename/scale in the app must use the same artifact ratio that the exporter
    /// reports; verify the public helper agrees with the detailed result (D consumes this value).
    func testPublicActualScaleFactorHelperMatchesDetailedResult() throws {
        for (orientation, scale) in [(5, 2), (6, 2), (7, 4), (8, 4)] {
            let artifacts = try makeArtifacts(orientation: orientation, scale: scale)
            let destination = tempDirectory.appendingPathComponent(
                "helper-\(orientation)-\(scale)x.tiff"
            )
            let result = try FormatAwareExporter.exportImageDetailed(
                artifacts: artifacts,
                destinationURL: destination,
                overrideFormat: .tiff16BitLZW,
                overrideGrainAmount: 0
            )
            XCTAssertEqual(
                FormatAwareExporter.actualScaleFactor(artifacts: artifacts),
                result.actualScaleFactor
            )
            XCTAssertEqual(result.actualScaleFactor, scale)
        }
    }

    /// Legacy always produces a 4x canvas even when the persisted selector says 2x; the artifact
    /// ratio must win for both metadata and filenames.
    func testLegacyCanvasKeepsFourXWhenSelectorSaysTwoX() throws {
        let artifacts = try makeArtifacts(orientation: 1, scale: 4, configuredScale: 2)
        XCTAssertEqual(FormatAwareExporter.actualScaleFactor(artifacts: artifacts), 4)
        let destination = tempDirectory.appendingPathComponent("legacy-4x.tiff")
        let result = try FormatAwareExporter.exportImageDetailed(
            artifacts: artifacts,
            destinationURL: destination,
            overrideFormat: .tiff16BitLZW,
            overrideGrainAmount: 0
        )
        XCTAssertEqual(result.actualScaleFactor, 4)
        let comment = try exportedUserComment(at: destination)
        XCTAssertTrue(comment.contains("UpscaledFactor=4x"), "Legacy artifact tagged: \(comment)")
        XCTAssertFalse(comment.contains("UpscaledFactor=2x"))
    }

    // MARK: - R6: detailed result / final headroom

    /// The detailed result reports the maximum nonnegative component of the FINAL grain-blended
    /// pixels, not luminance and not the checkpoint input peak.
    func testDetailedExportReportsGrainBlendedComponentPeakOfFour() throws {
        let artifacts = try makeArtifacts(orientation: 1, scale: 4)
        // Saturated red HDR patch: component peak 4, luminance is about 0.92.
        for y in 0..<artifacts.sourceBuffer.height {
            for x in 0..<artifacts.sourceBuffer.width {
                let pixel = artifacts.sourceBuffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = 4; pixel[1] = 0; pixel[2] = 0; pixel[3] = 1
            }
        }
        for y in 0..<artifacts.outputBuffer.height {
            for x in 0..<artifacts.outputBuffer.width {
                let pixel = artifacts.outputBuffer.unsafePixelPointer(x: x, y: y)
                // Mixed content: the saturated red survives grain blending; a dim patch checks the
                // measurement is a max over all components rather than a single sampled pixel.
                if x < artifacts.outputBuffer.width / 2 {
                    pixel[0] = 4; pixel[1] = 0; pixel[2] = 0; pixel[3] = 1
                } else {
                    pixel[0] = 0.25; pixel[1] = 0.5; pixel[2] = 0.75; pixel[3] = 1
                }
            }
        }

        let destination = tempDirectory.appendingPathComponent("grain-peak.tiff")
        let result = try FormatAwareExporter.exportImageDetailed(
            artifacts: artifacts,
            destinationURL: destination,
            overrideFormat: .tiff16BitLZW,
            overrideGrainAmount: 0.35
        )
        XCTAssertEqual(result.format, .tiff16BitLZW)
        XCTAssertEqual(result.finalLinearPeak, 4.0, accuracy: 0.02)
        XCTAssertEqual(result.dngHeadroomScale, 4.0, accuracy: 0.02)
        XCTAssertTrue(result.isHDR)
        XCTAssertEqual(result.actualScaleFactor, 4)

        // The peak is measured over the grain-blended pixels that actually reach the container.
        let decoded = try UniversalStripDecoder.decodeToMMap(
            imageURL: destination,
            destinationMMapURL: tempDirectory.appendingPathComponent("grain-peak.bin")
        )
        let red = decoded.sourceBuffer.unsafePixelPointer(x: 10, y: 10)
        XCTAssertEqual(Float(red[0]), 4.0, accuracy: 0.02)
        var decodedMax: Float = 0
        for y in 0..<decoded.decodedHeight {
            for x in 0..<decoded.decodedWidth {
                let pixel = decoded.sourceBuffer.unsafePixelPointer(x: x, y: y)
                for channel in 0..<3 {
                    let value = Float(pixel[channel])
                    if value.isFinite { decodedMax = max(decodedMax, value) }
                }
            }
        }
        XCTAssertEqual(
            decodedMax,
            result.finalLinearPeak,
            accuracy: 0.02,
            "The reported final peak must match the rendered container peak"
        )
    }

    /// The SDR headroom scale is clamped to 1 and never reports an input-derived value above it.
    func testDetailedSDRExportReportsUnitHeadroom() throws {
        let artifacts = try makeArtifacts(orientation: 1, scale: 2)
        let destination = tempDirectory.appendingPathComponent("sdr-result.png")
        let result = try FormatAwareExporter.exportImageDetailed(
            artifacts: artifacts,
            destinationURL: destination,
            overrideFormat: .png16Bit,
            overrideGrainAmount: 0
        )
        XCTAssertLessThanOrEqual(result.finalLinearPeak, FormatAwareExporter.hdrComponentThreshold)
        XCTAssertEqual(result.dngHeadroomScale, 1.0)
        XCTAssertFalse(result.isHDR)
    }

    /// The detailed API must preserve the reviewed PNG HDR refusal: no clipping, no destination.
    func testDetailedPNGHDRRefusalKeepsBehavior() throws {
        let artifacts = try makeArtifacts(orientation: 1, scale: 2)
        for y in 0..<artifacts.outputBuffer.height {
            for x in 0..<artifacts.outputBuffer.width {
                let pixel = artifacts.outputBuffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = 4; pixel[1] = 2; pixel[2] = 0.5; pixel[3] = 1
            }
        }
        let destination = tempDirectory.appendingPathComponent("refused.png")
        XCTAssertThrowsError(
            try FormatAwareExporter.exportImageDetailed(
                artifacts: artifacts,
                destinationURL: destination,
                overrideFormat: .png16Bit,
                overrideGrainAmount: 0
            )
        ) { error in
            guard case ScalerError.unsupportedFormatExport(let format, let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(format.contains("PNG"))
            XCTAssertTrue(reason.contains("TIFF"))
            XCTAssertTrue(reason.contains("DNG"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Fixtures

    /// Builds a pipeline artifact whose EXIF original is 16x12 and whose decoded upright source
    /// buffer is swapped to 12x16 for transposing orientations 5...8.
    private func makeArtifacts(
        orientation: Int,
        scale: Int,
        configuredScale: Int? = nil
    ) throws -> CompletedPipelineArtifacts {
        let originalWidth = 16
        let originalHeight = 12
        let swaps = (5...8).contains(orientation)
        let sourceWidth = swaps ? originalHeight : originalWidth
        let sourceHeight = swaps ? originalWidth : originalHeight
        let outputWidth = sourceWidth * scale
        let outputHeight = sourceHeight * scale

        let metadata = ImageMetadataPacket(
            sourceURL: tempDirectory.appendingPathComponent("IMG_0001.heic"),
            utTypeIdentifier: "public.heic",
            category: .standardOpaqueRaster,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            originalOrientation: orientation,
            bitsPerComponent: 12,
            isoSpeedRatings: 800,
            rawPropertiesPlistData: try rawProperties(orientation: orientation),
            isAlreadyDenoisedBySuite: false
        )

        let sourceBuffer = try MMapBuffer(
            fileURL: tempDirectory.appendingPathComponent("source-\(UUID().uuidString).bin"),
            width: sourceWidth,
            height: sourceHeight,
            deleteOnDeinit: true
        )
        for y in 0..<sourceHeight {
            for x in 0..<sourceWidth {
                let pixel = sourceBuffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = Float16(0.05 + 0.7 * Float(x) / Float(max(1, sourceWidth - 1)))
                pixel[1] = Float16(0.05 + 0.7 * Float(y) / Float(max(1, sourceHeight - 1)))
                pixel[2] = Float16(0.25)
                pixel[3] = 1
            }
        }

        let outputBuffer = try MMapBuffer(
            fileURL: tempDirectory.appendingPathComponent("output-\(UUID().uuidString).bin"),
            width: outputWidth,
            height: outputHeight,
            deleteOnDeinit: true
        )
        for y in 0..<outputHeight {
            for x in 0..<outputWidth {
                let pixel = outputBuffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = Float16(0.05 + 0.7 * Float(x) / Float(max(1, outputWidth - 1)))
                pixel[1] = Float16(0.05 + 0.7 * Float(y) / Float(max(1, outputHeight - 1)))
                pixel[2] = Float16(0.25)
                pixel[3] = 1
            }
        }

        let config = UpscaleJobConfig(
            id: UUID(),
            sourceImageURL: metadata.sourceURL,
            scaleFactor: configuredScale == 2 ? .x2 : (configuredScale == 4 ? .x4 : (scale == 2 ? .x2 : .x4)),
            backbone: scale == 4 && configuredScale == 2 ? .unavailable : .quickSRNet,
            denoiseMode: .auto,
            naturalGrainAmount: 0.0,
            exportFormat: .autoMatchSource
        )
        let checkpoint = JobCheckpointState(
            jobID: UUID(),
            config: config,
            tileConfig: TileConfiguration(tier: .tierA_HighMemory),
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            paddedSourceWidth: sourceWidth,
            paddedSourceHeight: sourceHeight,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            globalMaxLuminance: 1.5,
            globalMaxLinearComponent: 4.0,
            alphaCurveConstant: 16.0,
            didRunDenoise: true,
            sourceMMapFileName: "source_rgba16f.bin",
            outputMMapFileName: "output_rgba16f.bin",
            metadataPacketFileName: "metadata.plist",
            lastCompletedTileIndex: 0,
            totalTiles: 1,
            normalizationPeakVersion: JobCheckpointState.currentNormalizationPeakVersion
        )
        return CompletedPipelineArtifacts(
            checkpoint: checkpoint,
            metadata: metadata,
            sourceBuffer: sourceBuffer,
            outputBuffer: outputBuffer
        )
    }

    private func rawProperties(orientation: Int) throws -> Data {
        let properties: [String: Any] = [
            kCGImagePropertyPixelWidth as String: 16,
            kCGImagePropertyPixelHeight as String: 12,
            kCGImagePropertyOrientation as String: orientation,
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifUserComment as String: "Review orientation fixture",
                kCGImagePropertyExifDateTimeOriginal as String: "2025:03:04 05:06:07",
            ] as [String: Any],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Apple",
                kCGImagePropertyTIFFModel as String: "iPhone 17 Pro",
                kCGImagePropertyTIFFOrientation as String: orientation,
            ] as [String: Any],
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: properties,
            format: .binary,
            options: 0
        )
    }

    // MARK: - Readback helpers

    private func userComment(in properties: [CFString: Any]) throws -> String {
        let exif = properties[kCGImagePropertyExifDictionary] as? [String: Any]
        return normalizedComment(exif?[kCGImagePropertyExifUserComment as String])
    }

    private func exportedUserComment(at url: URL) throws -> String {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        )
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        return normalizedComment(exif?[kCGImagePropertyExifUserComment as String])
    }

    private func normalizedComment(_ value: Any?) -> String {
        switch value {
        case let string as String:
            return string
        case let data as Data:
            return String(data: data, encoding: .utf8) ?? ""
        default:
            return ""
        }
    }

    private func fileExtension(for format: ExportFormat) -> String {
        switch format {
        case .linearDNG16Bit, .autoMatchSource: return "dng"
        case .tiff16BitLZW: return "tiff"
        case .png16Bit: return "png"
        case .heic10BitHDR: return "heic"
        case .jpeg95: return "jpg"
        }
    }

    private static func hasHEICEncoder() -> Bool {
        let supported = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return supported.contains("public.heic") || supported.contains("public.heif")
    }
}
