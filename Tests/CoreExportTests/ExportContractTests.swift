import XCTest
import Foundation
import CoreGraphics
import ImageIO
import CoreIngestion
@testable import CoreExport
@testable import TiledInferenceEngine
@testable import MMapCanvas
@testable import TruongScalerCore

/// Contract-level tests for the reviewed per-format export behavior:
/// shared HDR peak pre-pass, TIFF lossless extended range/alpha/metadata, explicit PNG SDR refusal,
/// HEIC verified-or-refused HDR (no stale gain map, no silent SDR fallback), JPEG flattening,
/// atomic publication/alias safety for every format, and the additive capability labels.
final class ExportContractTests: XCTestCase {
    private static let sourceWidth = 16
    private static let sourceHeight = 12
    private static let outputWidth = sourceWidth * 4
    private static let outputHeight = sourceHeight * 4

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ExportContractTests-\(UUID().uuidString)",
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

    // MARK: - TIFF: extended linear HDR + alpha + metadata

    func testDNGWithoutCaptureTimeUsesStableJobTimeWithoutInventingEXIFCaptureDates() throws {
        let base = try makeArtifacts(category: .standardOpaqueRaster)
        let c = base.checkpoint
        let checkpoint = JobCheckpointState(jobID: c.jobID, config: c.config, tileConfig: c.tileConfig,
            sourceWidth: c.sourceWidth, sourceHeight: c.sourceHeight,
            paddedSourceWidth: c.paddedSourceWidth, paddedSourceHeight: c.paddedSourceHeight,
            outputWidth: c.outputWidth, outputHeight: c.outputHeight,
            globalMaxLuminance: c.globalMaxLuminance, globalMaxLinearComponent: c.globalMaxLinearComponent,
            didRunDenoise: c.didRunDenoise, sourceMMapFileName: c.sourceMMapFileName,
            outputMMapFileName: c.outputMMapFileName, metadataPacketFileName: c.metadataPacketFileName,
            lastCompletedTileIndex: c.lastCompletedTileIndex, totalTiles: c.totalTiles,
            updatedAt: Date(timeIntervalSince1970: 0))
        let metadata = ImageMetadataPacket(sourceURL: base.metadata.sourceURL,
            utTypeIdentifier: base.metadata.utTypeIdentifier, category: base.metadata.category,
            originalWidth: base.metadata.originalWidth, originalHeight: base.metadata.originalHeight)
        let artifacts = CompletedPipelineArtifacts(checkpoint: checkpoint, metadata: metadata,
            sourceBuffer: base.sourceBuffer, outputBuffer: base.outputBuffer)
        let destination = tempDirectory.appendingPathComponent("no-capture-date.dng")
        _ = try FormatAwareExporter.exportImage(artifacts: artifacts, destinationURL: destination,
            overrideFormat: .linearDNG16Bit, overrideGrainAmount: 0)
        let embedded = try XCTUnwrap(LinearDNGTIFFReader.probe(imageURL: destination)?.embeddedMetadata)
        XCTAssertEqual(embedded.dateTime, "1970:01:01 00:00:00", "Save retries must use stable completed-job time, not wall-clock time")
        XCTAssertNil(embedded.dateTimeOriginal)
        XCTAssertNil(embedded.dateTimeDigitized)

        let captured = tempDirectory.appendingPathComponent("recorded-capture-date.dng")
        _ = try FormatAwareExporter.exportImage(artifacts: base, destinationURL: captured,
            overrideFormat: .linearDNG16Bit, overrideGrainAmount: 0)
        XCTAssertEqual(LinearDNGTIFFReader.probe(imageURL: captured)?.embeddedMetadata?.dateTimeOriginal,
            "2025:03:04 05:06:07", "Recorded source capture time must retain priority")
    }

    func testTIFFHDRColoredPatchesAlphaAndMetadataSurviveDecode() throws {
        let artifacts = try makeArtifacts(category: .standardOpaqueRaster, hasAlpha: true)
        // Left half: opaque saturated HDR colour. Right half: valid premultiplied semi-transparent
        // SDR patch (each component <= alpha), so both extended range and alpha are exercised.
        for y in 0..<Self.outputHeight {
            for x in 0..<Self.outputWidth {
                let pixel = artifacts.outputBuffer.unsafePixelPointer(x: x, y: y)
                if x < Self.outputWidth / 2 {
                    pixel[0] = 4.0; pixel[1] = 2.0; pixel[2] = 0.5; pixel[3] = 1.0
                } else {
                    pixel[0] = 0.25; pixel[1] = 0.125; pixel[2] = 0.0625; pixel[3] = 0.5
                }
            }
        }

        let destination = tempDirectory.appendingPathComponent("HDR-alpha.tiff")
        _ = try FormatAwareExporter.exportImage(
            artifacts: artifacts,
            destinationURL: destination,
            overrideFormat: .tiff16BitLZW,
            overrideGrainAmount: 0
        )

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        )
        XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, 16)
        XCTAssertEqual(properties[kCGImagePropertyOrientation as String] as? Int, 1)
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFCompression as String] as? Int, 5, "TIFF must stay LZW")
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake as String] as? String, "Apple")
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel as String] as? String, "iPhone 17 Pro")
        XCTAssertEqual(
            tiff?[kCGImagePropertyTIFFSoftware as String] as? String,
            MetadataReinjector.softwareTag
        )
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], [800])
        XCTAssertEqual(
            exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String,
            "2025:03:04 05:06:07"
        )
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        XCTAssertEqual(
            gps?[kCGImagePropertyGPSLatitude as String] as? Double ?? -1,
            37.7749,
            accuracy: 0.0001
        )

        let pixels = try decodePixels(at: destination)
        let hdr = pixel(pixels, x: 20, y: 20)
        XCTAssertEqual(hdr.0, 4.0, accuracy: 0.01, "Extended-linear red was not preserved")
        XCTAssertEqual(hdr.1, 2.0, accuracy: 0.01, "Extended-linear green was not preserved")
        XCTAssertEqual(hdr.2, 0.5, accuracy: 0.01)
        XCTAssertEqual(hdr.3, 1.0, accuracy: 0.001)

        let alpha = pixel(pixels, x: 50, y: 20)
        XCTAssertEqual(alpha.0, 0.25, accuracy: 0.005)
        XCTAssertEqual(alpha.1, 0.125, accuracy: 0.005)
        XCTAssertEqual(alpha.2, 0.0625, accuracy: 0.005)
        XCTAssertEqual(alpha.3, 0.5, accuracy: 0.005, "Alpha was not preserved by the Float16 TIFF path")
    }

    // MARK: - PNG: explicit 16-bit SDR contract

    func testSDRRasterQuantizationPreservesExactBlackAndTransparentAlpha() throws {
        let artifacts = try makeArtifacts(category: .standardAlphaRaster, hasAlpha: true)
        for (format, ext) in [(ExportFormat.png16Bit, "png"), (.jpeg95, "jpg")] {
            setAllPixels(artifacts, red: 0, green: 0, blue: 0, alpha: 1)
            let destination = tempDirectory.appendingPathComponent("exact-black.\(ext)")
            _ = try FormatAwareExporter.exportImage(artifacts: artifacts, destinationURL: destination,
                overrideFormat: format, overrideGrainAmount: 0)
            let sample = pixel(try decodePixels(at: destination), x: 20, y: 20)
            XCTAssertEqual(sample.0, 0, accuracy: 1e-7, "\(format) must encode zero as zero")
            XCTAssertEqual(sample.1, 0, accuracy: 1e-7)
            XCTAssertEqual(sample.2, 0, accuracy: 1e-7)
            XCTAssertEqual(sample.3, 1, accuracy: 1e-7)
        }
        setAllPixels(artifacts, red: 0, green: 0, blue: 0, alpha: 0)
        let transparent = tempDirectory.appendingPathComponent("exact-transparent.png")
        _ = try FormatAwareExporter.exportImage(artifacts: artifacts, destinationURL: transparent,
            overrideFormat: .png16Bit, overrideGrainAmount: 0)
        let sample = pixel(try decodePixels(at: transparent), x: 20, y: 20)
        XCTAssertEqual(sample.0, 0, accuracy: 1e-7)
        XCTAssertEqual(sample.1, 0, accuracy: 1e-7)
        XCTAssertEqual(sample.2, 0, accuracy: 1e-7)
        XCTAssertEqual(sample.3, 0, accuracy: 1e-7, "Transparent alpha must not gain a nonzero code value")
    }

    func testSDRDNGQuantizationRoundsOnceAndPreservesBlackAndWhite() throws {
        let artifacts = try makeArtifacts(category: .standardOpaqueRaster)
        let levels: [Float16] = [0, 0.25, 0.5, 0.75, 1]
        let expectedCodes: [UInt16] = [0, 16384, 32768, 49151, 65535]
        for y in 0..<Self.outputHeight {
            for x in 0..<Self.outputWidth {
                let sample = artifacts.outputBuffer.unsafePixelPointer(x: x, y: y)
                sample[0] = levels[x % levels.count]
                sample[1] = levels[x % levels.count]
                sample[2] = levels[x % levels.count]
                sample[3] = 1
            }
        }
        let destination = tempDirectory.appendingPathComponent("single-rounding.dng")
        _ = try FormatAwareExporter.exportImage(artifacts: artifacts, destinationURL: destination,
            overrideFormat: .linearDNG16Bit, overrideGrainAmount: 0)
        let tags = try parseTIFFTags(at: destination)
        let samples = try XCTUnwrap(stripData(tags, at: destination).first)
        for (x, expected) in expectedCodes.enumerated() {
            for channel in 0..<3 {
                XCTAssertEqual(readU16(samples, (x * 3 + channel) * 2), expected,
                    "SDR DNG code at level \(levels[x]) must be nearest integer to v × 65535")
            }
        }
        let decoded = try UniversalStripDecoder.decodeToMMap(imageURL: destination,
            destinationMMapURL: tempDirectory.appendingPathComponent("single-rounding-reingest.bin"))
        XCTAssertEqual(Float(decoded.sourceBuffer.unsafePixelPointer(x: 0, y: 0)[0]), 0)
        XCTAssertEqual(Float(decoded.sourceBuffer.unsafePixelPointer(x: 4, y: 0)[0]), 1)
    }

    func testPNG16BitSDRPrecisionAndAlphaRoundTrip() throws {
        let artifacts = try makeArtifacts(category: .standardAlphaRaster, hasAlpha: true)
        for y in 0..<Self.outputHeight {
            for x in 0..<Self.outputWidth {
                let pixel = artifacts.outputBuffer.unsafePixelPointer(x: x, y: y)
                if x < Self.outputWidth / 2 {
                    pixel[0] = 0.25; pixel[1] = 0.5; pixel[2] = 0.75; pixel[3] = 1.0
                } else {
                    pixel[0] = 0.125; pixel[1] = 0.25; pixel[2] = 0.375; pixel[3] = 0.5
                }
            }
        }

        let destination = tempDirectory.appendingPathComponent("SDR.png")
        _ = try FormatAwareExporter.exportImage(
            artifacts: artifacts,
            destinationURL: destination,
            overrideFormat: .png16Bit,
            overrideGrainAmount: 0
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        )
        XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, 16)
        XCTAssertEqual(properties[kCGImagePropertyOrientation as String] as? Int, 1)

        let pixels = try decodePixels(at: destination)
        let opaque = pixel(pixels, x: 20, y: 20)
        XCTAssertEqual(opaque.0, 0.25, accuracy: 0.002)
        XCTAssertEqual(opaque.1, 0.5, accuracy: 0.002)
        XCTAssertEqual(opaque.2, 0.75, accuracy: 0.002)
        XCTAssertEqual(opaque.3, 1.0, accuracy: 0.002)

        let alpha = pixel(pixels, x: 50, y: 20)
        XCTAssertEqual(alpha.0, 0.125, accuracy: 0.002)
        XCTAssertEqual(alpha.1, 0.25, accuracy: 0.002)
        XCTAssertEqual(alpha.2, 0.375, accuracy: 0.002)
        XCTAssertEqual(alpha.3, 0.5, accuracy: 0.002, "PNG alpha did not round-trip")
    }

    func testPNGHDRExportIsRefusedWithActionableErrorNamingTIFFAndDNG() throws {
        let artifacts = try makeArtifacts(category: .standardOpaqueRaster)
        setAllPixels(artifacts, red: 4.0, green: 4.0, blue: 4.0, alpha: 1.0)
        let destination = tempDirectory.appendingPathComponent("HDR-refused.png")

        do {
            _ = try FormatAwareExporter.exportImage(
                artifacts: artifacts,
                destinationURL: destination,
                overrideFormat: .png16Bit,
                overrideGrainAmount: 0
            )
            XCTFail("16-bit PNG must refuse extended-range output instead of clipping it")
        } catch let error as ScalerError {
            guard case .unsupportedFormatExport(let format, let reason) = error else {
                XCTFail("Unexpected ScalerError: \(error)")
                return
            }
            XCTAssertTrue(format.contains("PNG"), "Format description should name PNG: \(format)")
            XCTAssertTrue(reason.contains("TIFF"), "Reason must name LZW TIFF: \(reason)")
            XCTAssertTrue(reason.contains("DNG"), "Reason must name Linear DNG: \(reason)")
            XCTAssertTrue(error.errorDescription?.contains("TIFF") ?? false)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "A refused PNG export must not create a destination file"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "A refused export must not leave a partially written destination"
        )
    }

    // MARK: - HEIC capability

    func testHEICCapabilitySDRDecodeAndHDRVerifiedOrRefused() throws {
        let encoderAvailable = Self.hasHEICEncoder()
        print("HEIC_ENCODER_AVAILABLE=\(encoderAvailable)")

        // SDR HEIC remains supported: verify the decoded pixels, not just the depth property.
        if encoderAvailable {
            let sdrArtifacts = try makeArtifacts(category: .hdrHEIC)
            let sdrDestination = tempDirectory.appendingPathComponent("SDR.heic")
            _ = try FormatAwareExporter.exportImage(
                artifacts: sdrArtifacts,
                destinationURL: sdrDestination,
                overrideFormat: .heic10BitHDR,
                overrideGrainAmount: 0
            )
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(sdrDestination as CFURL, nil))
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
            )
            XCTAssertEqual(properties[kCGImagePropertyOrientation as String] as? Int, 1)
            print("HEIC_SDR_DECODED_DEPTH=\(properties[kCGImagePropertyDepth as String] as? Int ?? -1)")
            let pixels = try decodePixels(at: sdrDestination)
            let sample = pixel(pixels, x: 32, y: 10)
            XCTAssertEqual(sample.0, 32.0 / 63.0, accuracy: 0.05, "SDR HEIC red channel changed")
            XCTAssertEqual(sample.2, 0.5, accuracy: 0.05, "SDR HEIC blue channel changed")
            XCTAssertEqual(sample.3, 1.0, accuracy: 0.05)
        } else {
            print("HEIC_SDR_PATH=skipped(no encoder)")
        }

        // HDR HEIC: either the finalized file decodes with real extended-range highlights, or the
        // export must throw an actionable error naming TIFF/DNG. Nothing in between is acceptable.
        let hdrArtifacts = try makeArtifacts(category: .hdrHEIC)
        setAllPixels(hdrArtifacts, red: 4.0, green: 2.0, blue: 0.5, alpha: 1.0)
        let hdrDestination = tempDirectory.appendingPathComponent("HDR.heic")
        var refusalDescription: String?
        do {
            _ = try FormatAwareExporter.exportImage(
                artifacts: hdrArtifacts,
                destinationURL: hdrDestination,
                overrideFormat: .heic10BitHDR,
                overrideGrainAmount: 0
            )
            // Verified HDR path: prove it from the decoded file, not from a depth property.
            let pixels = try decodePixels(at: hdrDestination)
            let sample = pixel(pixels, x: 32, y: 24)
            XCTAssertGreaterThanOrEqual(
                sample.0, 3.0,
                "HEIC export succeeded but did not preserve the 4.0 HDR highlight"
            )
            XCTAssertGreaterThanOrEqual(
                sample.1, 1.2,
                "HEIC export succeeded but lost the saturated HDR colour patch"
            )
            print("HEIC_HDR_PATH=verified decoded=(\(sample.0), \(sample.1), \(sample.2))")
            if !encoderAvailable {
                XCTFail("HDR HEIC reported success without a HEIC encoder")
            }
        } catch let error as ScalerError {
            guard case .unsupportedFormatExport(let format, let reason) = error else {
                XCTFail("Unexpected ScalerError for HDR HEIC: \(error)")
                return
            }
            XCTAssertTrue(format.contains("HEIC"), "Format description should name HEIC: \(format)")
            XCTAssertTrue(reason.contains("TIFF"), "Refusal must name LZW TIFF: \(reason)")
            XCTAssertTrue(reason.contains("DNG"), "Refusal must name Linear DNG: \(reason)")
            XCTAssertTrue(
                reason.lowercased().contains("gain map"),
                "Refusal must document the regenerated ISO gain-map capability limit: \(reason)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: hdrDestination.path),
                "A refused HDR HEIC export must not publish an SDR file"
            )
            refusalDescription = error.errorDescription
            print("HEIC_HDR_PATH=refused reason=\(reason)")
        }
        if let refusalDescription {
            XCTAssertFalse(refusalDescription.isEmpty)
        }
        print("HEIC_CAPABILITY_SUPPORTS_EXTENDED_HDR=\(ExportFormat.heic10BitHDR.supportsExtendedHDR)")
    }

    func testStaleSourceGainMapIsNeverAttachedToProcessedHEIC() throws {
        try XCTSkipUnless(Self.hasHEICEncoder(), "HEIC encoder unavailable on this host")
        let staleGainMap = Data(repeating: 0xAB, count: 64)
        for sourceType in [HDRGainMapAuxiliaryType.legacyHDRGainMap, .isoGainMap] {
            let artifacts = try makeArtifacts(
                category: .hdrHEIC,
                hdrGainMapData: staleGainMap,
                hdrGainMapWidth: 8,
                hdrGainMapHeight: 8,
                hdrGainMapAuxiliaryType: sourceType
            )
            XCTAssertEqual(artifacts.metadata.hdrGainMapAuxiliaryType, sourceType)
            XCTAssertEqual(artifacts.metadata.hdrGainMapAuxiliaryData, staleGainMap)

            let destination = tempDirectory
                .appendingPathComponent("gain-map-\(sourceType.rawValue).heic")
            _ = try FormatAwareExporter.exportImage(
                artifacts: artifacts,
                destinationURL: destination,
                overrideFormat: .heic10BitHDR,
                overrideGrainAmount: 0
            )
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
            let legacy = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                source, 0, kCGImageAuxiliaryDataTypeHDRGainMap
            )
            let iso = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                source, 0, kCGImageAuxiliaryDataTypeISOGainMap
            )
            XCTAssertNil(legacy, "Stale legacy HDR gain map was re-attached to processed pixels")
            XCTAssertNil(iso, "Stale ISO gain map was re-attached to processed pixels")
        }
    }

    // MARK: - JPEG

    func testJPEGKeepsPremultipliedAlphaFlattening() throws {
        let artifacts = try makeArtifacts(category: .standardAlphaRaster)
        for y in 0..<Self.outputHeight {
            for x in 0..<Self.outputWidth {
                let pixel = artifacts.outputBuffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = 0.25; pixel[1] = 0.125; pixel[2] = 0.0625; pixel[3] = 0.5
            }
        }
        let destination = tempDirectory.appendingPathComponent("flatten.jpg")
        _ = try FormatAwareExporter.exportImage(
            artifacts: artifacts,
            destinationURL: destination,
            overrideFormat: .jpeg95,
            overrideGrainAmount: 0
        )
        let pixels = try decodePixels(at: destination)
        let sample = pixel(pixels, x: 20, y: 20)
        XCTAssertEqual(sample.0, 0.25, accuracy: 0.02, "Premultiplied red was not flattened as-is")
        XCTAssertEqual(sample.1, 0.125, accuracy: 0.02)
        XCTAssertEqual(sample.2, 0.0625, accuracy: 0.02)
        XCTAssertEqual(sample.3, 1.0, accuracy: 0.001, "JPEG must be opaque")
    }

    // MARK: - Atomic publication + alias safety

    func testFailedExportPreservesPreexistingDestinationAndCleansStaging() throws {
        let artifacts = try makeArtifacts(category: .standardOpaqueRaster)
        setAllPixels(artifacts, red: 4.0, green: 4.0, blue: 4.0, alpha: 1.0)
        let sentinel = Data("preexisting-destination-bytes".utf8)

        let pngDestination = tempDirectory.appendingPathComponent("existing.png")
        try sentinel.write(to: pngDestination)
        XCTAssertThrowsError(try FormatAwareExporter.exportImage(
            artifacts: artifacts,
            destinationURL: pngDestination,
            overrideFormat: .png16Bit,
            overrideGrainAmount: 0
        ))
        XCTAssertEqual(
            try Data(contentsOf: pngDestination),
            sentinel,
            "A failed PNG export destroyed a pre-existing destination"
        )
        assertNoStagingFilesLeft()

        if Self.hasHEICEncoder() {
            let heicDestination = tempDirectory.appendingPathComponent("existing.heic")
            try sentinel.write(to: heicDestination)
            do {
                _ = try FormatAwareExporter.exportImage(
                    artifacts: artifacts,
                    destinationURL: heicDestination,
                    overrideFormat: .heic10BitHDR,
                    overrideGrainAmount: 0
                )
                // If this host can truly preserve HDR, publishing over the destination is correct.
                XCTAssertNotEqual(try Data(contentsOf: heicDestination), sentinel)
                print("HEIC_HDR_PATH=verified (destination atomically replaced)")
            } catch {
                XCTAssertEqual(
                    try Data(contentsOf: heicDestination),
                    sentinel,
                    "A failed HDR HEIC export destroyed a pre-existing destination"
                )
                assertNoStagingFilesLeft()
                print("HEIC_HDR_STAGING_CLEANUP=verified")
            }
        }
    }

    func testEveryFormatRejectsSourceAndMMapAliasesWithoutWriting() throws {
        let artifacts = try makeArtifacts(category: .standardOpaqueRaster)
        try Data("original-source-bytes".utf8).write(to: artifacts.metadata.sourceURL)
        let inputs = [
            artifacts.metadata.sourceURL,
            artifacts.checkpoint.config.sourceImageURL,
            artifacts.sourceBuffer.fileURL,
            artifacts.outputBuffer.fileURL,
        ]
        let formats: [ExportFormat] = [
            .linearDNG16Bit, .tiff16BitLZW, .png16Bit, .heic10BitHDR, .jpeg95,
        ]

        for format in formats {
            for input in inputs {
                let original = try Data(contentsOf: input)
                let symlink = tempDirectory.appendingPathComponent(
                    "symlink-\(format.rawValue)-\(UUID().uuidString).bin"
                )
                try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: input)
                let hardlink = tempDirectory.appendingPathComponent(
                    "hardlink-\(format.rawValue)-\(UUID().uuidString).bin"
                )
                try FileManager.default.linkItem(at: input, to: hardlink)

                for destination in [input, symlink, hardlink] {
                    XCTAssertThrowsError(
                        try FormatAwareExporter.exportImage(
                            artifacts: artifacts,
                            destinationURL: destination,
                            overrideFormat: format,
                            overrideGrainAmount: 0
                        ),
                        "\(format.rawValue) accepted an aliased destination \(destination.path)"
                    ) { error in
                        guard let scalerError = error as? ScalerError else {
                            XCTFail("Unexpected error for \(format.rawValue): \(error)")
                            return
                        }
                        guard case .exportDestinationCreationFailed = scalerError else {
                            XCTFail(
                                "Expected alias rejection for \(format.rawValue), got \(scalerError)"
                            )
                            return
                        }
                    }
                    XCTAssertEqual(
                        try Data(contentsOf: input),
                        original,
                        "\(format.rawValue) modified an aliased input"
                    )
                }
            }
        }
    }

    // MARK: - DNG headroom + rendered-P3 calibration

    func testDNGFullConfigRecordsComputedHeadroomAndRenderedP3Calibration() throws {
        let sourceRaw = CameraRAWParameters(
            cameraMake: "Apple",
            cameraModel: "iPhone 17 Pro",
            colorMatrix1: Array(repeating: 9.0, count: 9),
            colorMatrix2: Array(repeating: 8.0, count: 9),
            asShotNeutral: [0.3, 1.0, 0.2],
            baselineExposure: 5.0,
            blackLevel: [12, 12, 12],
            whiteLevel: 16_383
        )
        let artifacts = try makeArtifacts(category: .cameraRAW, rawParameters: sourceRaw)
        for y in 0..<Self.outputHeight {
            for x in 0..<Self.outputWidth {
                let pixel = artifacts.outputBuffer.unsafePixelPointer(x: x, y: y)
                // Peak component = 4.0 (saturated red on the left; saturated green on the right),
                // so H = 4, BaselineExposure = log2(4) = 2.
                if x < Self.outputWidth / 2 {
                    pixel[0] = 4.0; pixel[1] = 2.0; pixel[2] = 0.5; pixel[3] = 1.0
                } else {
                    pixel[0] = 0.5; pixel[1] = 4.0; pixel[2] = 1.0; pixel[3] = 1.0
                }
            }
        }

        let destination = tempDirectory.appendingPathComponent("Headroom.dng")
        let result = try FormatAwareExporter.exportImageDetailed(
            artifacts: artifacts,
            destinationURL: destination,
            overrideFormat: .linearDNG16Bit,
            overrideGrainAmount: 0
        )
        XCTAssertEqual(result.finalLinearPeak, 4.0, accuracy: 0.002)
        XCTAssertEqual(result.dngHeadroomScale, 4.0, accuracy: 0.002)
        XCTAssertTrue(result.isHDR)
        XCTAssertEqual(result.actualScaleFactor, 4)
        XCTAssertEqual(result.format, .linearDNG16Bit)

        let tags = try parseTIFFTags(at: destination)
        XCTAssertEqual(try shortValue(tags, 274), 1, "Orientation must be upright (1)")
        XCTAssertEqual(try longValue(tags, 256), UInt32(Self.outputWidth))
        XCTAssertEqual(try longValue(tags, 257), UInt32(Self.outputHeight))
        XCTAssertEqual(try shortValues(tags, 50714), [0, 0, 0], "BlackLevel must stay 0")
        // R8: HDR output-referred representation is 16-bit IEEE Float samples at DNG 1.7 with
        // ColorimetricReference=2, WhiteLevel=1, BaselineExposure=0 and ProfileDynamicRange tag 52551.
        XCTAssertEqual(try shortValues(tags, 339), [3, 3, 3], "HDR DNG must use SampleFormat=Float16")
        XCTAssertEqual(try shortValue(tags, 50879), 2, "HDR DNG must be ColorimetricReference=2")
        XCTAssertEqual(longValues(tags, 50717), [1, 1, 1], "Float16 DNG WhiteLevel must be 1")
        let dngVersion = try XCTUnwrap(tags[50706]?.payload).map { $0 }
        XCTAssertEqual(dngVersion, [1, 7, 0, 0], "HDR DNG must declare DNGVersion 1.7.0.0")
        let backwardVersion = try XCTUnwrap(tags[50707]?.payload).map { $0 }
        XCTAssertEqual(backwardVersion, [1, 7, 0, 0], "HDR DNG backward version must be 1.7.0.0")
        XCTAssertEqual(
            try srationalValue(tags, 50730),
            0.0,
            accuracy: 1e-6,
            "BaselineExposure must be 0 for absolute Float16 samples"
        )
        XCTAssertEqual(try rationalValues(tags, 50728), [1.0, 1.0, 1.0], "AsShotNeutral must be {{1,1,1}}")

        // ProfileDynamicRange (52551) = SHORT version 1, SHORT dynamicRange 1, FLOAT HintMaxOutputValue H.
        let profileDynamicRange = try XCTUnwrap(tags[52551]?.payload)
        let profileValues = try XCTUnwrap(
            profileDynamicRangeValues(profileDynamicRange),
            "ProfileDynamicRange payload must be 8 bytes"
        )
        XCTAssertEqual(profileValues.version, 1, "ProfileDynamicRange version must be 1")
        XCTAssertEqual(profileValues.dynamicRange, 1, "ProfileDynamicRange must select HDR")
        XCTAssertEqual(
            profileValues.hint,
            4.0,
            accuracy: 0.0001,
            "ProfileDynamicRange HintMaxOutputValue must be H"
        )
        XCTAssertTrue(
            (tags[52551]?.payload?.count ?? 0) == 8,
            "ProfileDynamicRange payload must be 8 bytes"
        )

        let matrix = try srationalValues(tags, 50721)
        XCTAssertEqual(matrix.count, 9)
        let expectedMatrix = DNGExportMetadataBuilder.linearDisplayP3InverseXYZ
        for index in 0..<9 {
            XCTAssertEqual(
                matrix[index],
                Double(expectedMatrix[index]),
                accuracy: 2e-6,
                "DNG ColorMatrix1[\(index)] is not the rendered-P3 inverse"
            )
        }

        let descriptionData = try XCTUnwrap(tags[270]?.payload)
        let description = String(
            data: descriptionData.prefix { $0 != 0 },
            encoding: .utf8
        ) ?? ""
        XCTAssertTrue(
            description.contains("WorkingSpace=LinearDisplayP3"),
            "DNG ImageDescription marker missing working space: \(description)"
        )
        XCTAssertTrue(
            description.contains("HeadroomScale=4"),
            "DNG ImageDescription marker missing HeadroomScale=4: \(description)"
        )
        XCTAssertTrue(
            description.contains("HeadroomEV=2"),
            "DNG ImageDescription marker missing HeadroomEV=2: \(description)"
        )

        // Unique camera identity + a neutral Software tag (never a hardcoded Denoised marker).
        let uniqueModel = try asciiValue(tags, 50708)
        XCTAssertEqual(uniqueModel, "iPhone 17 Pro")
        let software = try asciiValue(tags, 305)
        XCTAssertEqual(software, "TruongScaler 1.0 (ImagingSuite)")
        XCTAssertFalse(software.contains("Denoised="), "Software must not carry a pipeline marker")

        // Group A's metadata-entry builder writes EXIF/GPS IFDs and XMP into the DNG.
        let fileData = try Data(contentsOf: destination)
        let exifIFD = try XCTUnwrap(nestedIFD(tags, pointerTag: 34665, in: fileData))
        XCTAssertEqual(try asciiValue(exifIFD, 36867), "2025:03:04 05:06:07")
        XCTAssertEqual(try shortValues(exifIFD, 34855), [800])
        XCTAssertEqual(try asciiValue(exifIFD, 42035), "Apple")
        let userComment = try asciiValue(exifIFD, 37510, skipASCIIPrefix: true)
        XCTAssertTrue(userComment.contains("Denoised=true"), "Actual pipeline flag missing: \(userComment)")
        XCTAssertTrue(userComment.contains("UpscaledFactor=4x"))
        XCTAssertTrue(userComment.contains("NoiserDenoised=false"))
        XCTAssertTrue(userComment.contains("Shot on iPhone 17 Pro"), "User comment was discarded")

        let gpsIFD = try XCTUnwrap(nestedIFD(tags, pointerTag: 34853, in: fileData))
        XCTAssertEqual(try asciiValue(gpsIFD, 1), "N")
        let latitude = try rationalValues(gpsIFD, 2)
        XCTAssertEqual(latitude.count, 3)
        XCTAssertEqual(latitude[0] + latitude[1] / 60 + latitude[2] / 3600, 37.7749, accuracy: 0.0002)
        XCTAssertEqual(try asciiValue(gpsIFD, 3), "W")

        let xmp = try XCTUnwrap(tags[700]?.payload)
        let xmpString = String(data: xmp, encoding: .utf8) ?? ""
        XCTAssertTrue(xmpString.contains("ImagingSuite:HeadroomScale=\"4\""), "XMP headroom missing")
        XCTAssertTrue(xmpString.contains("ImagingSuite:Denoised=\"true\""))

        // HDR strips carry absolute Float16 bit patterns: 4.0, 2.0, 0.5 with no headroom division.
        let strips = try stripData(tags, at: destination)
        XCTAssertFalse(strips.isEmpty)
        let first = strips[0]
        let red = Float(Float16(bitPattern: readU16(first, 0)))
        let green = Float(Float16(bitPattern: readU16(first, 2)))
        let blue = Float(Float16(bitPattern: readU16(first, 4)))
        XCTAssertEqual(red, 4.0, accuracy: 0.001, "R=4.0 must be stored as absolute Float16")
        XCTAssertEqual(green, 2.0, accuracy: 0.001, "G=2.0 must be stored as absolute Float16")
        XCTAssertEqual(blue, 0.5, accuracy: 0.001, "B=0.5 must be stored as absolute Float16")

        // Re-ingest through the independent suite reader: absolute Float16 samples must round-trip
        // without applying BaselineExposure, and headroom telemetry must come from the profile hint.
        let decoded = try UniversalStripDecoder.decodeToMMap(
            imageURL: destination,
            destinationMMapURL: tempDirectory.appendingPathComponent("HDR-headroom-reingest.bin")
        )
        XCTAssertEqual(decoded.decodedWidth, Self.outputWidth)
        XCTAssertEqual(decoded.decodedHeight, Self.outputHeight)
        XCTAssertEqual(decoded.metadata.linearHeadroomScale ?? -1, 4.0, accuracy: 0.002)
        XCTAssertEqual(decoded.globalMaxLinearComponent, 4.0, accuracy: 0.01)
        let decodedPixel = decoded.sourceBuffer.unsafePixelPointer(x: 20, y: 20)
        XCTAssertEqual(Float(decodedPixel[0]), 4.0, accuracy: 0.01)
        XCTAssertEqual(Float(decodedPixel[1]), 2.0, accuracy: 0.01)
        XCTAssertEqual(Float(decodedPixel[2]), 0.5, accuracy: 0.01)
        XCTAssertEqual(Float(decodedPixel[3]), 1.0, accuracy: 0.01)
    }

    /// R8 SDR: SDR content keeps the reviewed 16-bit integer representation at DNG 1.4 /
    /// ColorimetricReference 1 with WhiteLevel 65535, BaselineExposure 0 and no ProfileDynamicRange.
    func testDNGSDRUsesUInt16DNG14WithoutHDRProfile() throws {
        let artifacts = try makeArtifacts(category: .standardOpaqueRaster)
        for y in 0..<Self.outputHeight {
            for x in 0..<Self.outputWidth {
                let pixel = artifacts.outputBuffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = 0.25; pixel[1] = 0.5; pixel[2] = 0.75; pixel[3] = 1.0
            }
        }
        let destination = tempDirectory.appendingPathComponent("SDR.dng")
        let result = try FormatAwareExporter.exportImageDetailed(
            artifacts: artifacts,
            destinationURL: destination,
            overrideFormat: .linearDNG16Bit,
            overrideGrainAmount: 0
        )
        XCTAssertEqual(result.dngHeadroomScale, 1.0)
        XCTAssertFalse(result.isHDR)

        let tags = try parseTIFFTags(at: destination)
        XCTAssertEqual(try shortValues(tags, 339), [1, 1, 1], "SDR DNG must stay unsigned integer")
        XCTAssertEqual(try shortValue(tags, 50879), 1, "SDR DNG must be ColorimetricReference=1")
        XCTAssertEqual(longValues(tags, 50717), [65535, 65535, 65535])
        XCTAssertEqual(try shortValues(tags, 50714), [0, 0, 0])
        XCTAssertNil(tags[52551], "SDR DNG must not carry a ProfileDynamicRange tag")
        XCTAssertEqual(try XCTUnwrap(tags[50706]?.payload).map { $0 }, [1, 4, 0, 0])
        XCTAssertEqual(try XCTUnwrap(tags[50707]?.payload).map { $0 }, [1, 1, 0, 0])
        XCTAssertEqual(try srationalValue(tags, 50730), 0.0, accuracy: 1e-6)

        let strips = try stripData(tags, at: destination)
        let first = try XCTUnwrap(strips.first)
        XCTAssertEqual(readU16(first, 0), 16384, "R=0.25 must quantize as q/65535")
        XCTAssertEqual(readU16(first, 2), 32768, "G=0.5 must quantize as q/65535")
        XCTAssertEqual(readU16(first, 4), 49151, "B=0.75 must round 49151.25 to the nearest UInt16 code")
    }

    /// Grain-blended HDR content: the measured final component peak drives the Float16 profile hint
    /// and the re-ingested headroom telemetry, so the manifest/embedded-file values cannot drift.
    func testDetailedDNGHeadroomMatchesGrainBlendedPeak() throws {
        let artifacts = try makeArtifacts(category: .cameraRAW)
        for buffer in [artifacts.sourceBuffer, artifacts.outputBuffer] {
            for y in 0..<buffer.height {
                for x in 0..<buffer.width {
                    let pixel = buffer.unsafePixelPointer(x: x, y: y)
                    pixel[0] = 4.0; pixel[1] = 1.0; pixel[2] = 0.25; pixel[3] = 1.0
                }
            }
        }
        let destination = tempDirectory.appendingPathComponent("GrainHDR.dng")
        let result = try FormatAwareExporter.exportImageDetailed(
            artifacts: artifacts,
            destinationURL: destination,
            overrideFormat: .linearDNG16Bit,
            overrideGrainAmount: 0.35
        )
        XCTAssertEqual(result.finalLinearPeak, 4.0, accuracy: 0.01)
        XCTAssertEqual(result.dngHeadroomScale, 4.0, accuracy: 0.01)

        let tags = try parseTIFFTags(at: destination)
        XCTAssertEqual(try shortValues(tags, 339), [3, 3, 3])
        XCTAssertEqual(try shortValue(tags, 50879), 2)
        XCTAssertEqual(try srationalValue(tags, 50730), 0.0, accuracy: 1e-6)
        let profile = try XCTUnwrap(tags[52551]?.payload)
        let profileValues = try XCTUnwrap(profileDynamicRangeValues(profile))
        XCTAssertEqual(
            profileValues.hint,
            result.dngHeadroomScale,
            accuracy: 0.0001,
            "ProfileDynamicRange hint must equal the measured final peak"
        )

        let decoded = try UniversalStripDecoder.decodeToMMap(
            imageURL: destination,
            destinationMMapURL: tempDirectory.appendingPathComponent("GrainHDR-reingest.bin")
        )
        XCTAssertEqual(decoded.metadata.linearHeadroomScale ?? -1, result.dngHeadroomScale, accuracy: 0.01)
        let decodedPixel = decoded.sourceBuffer.unsafePixelPointer(x: 20, y: 20)
        XCTAssertEqual(Float(decodedPixel[0]), 4.0, accuracy: 0.02)
        XCTAssertEqual(Float(decodedPixel[1]), 1.0, accuracy: 0.02)
        XCTAssertEqual(Float(decodedPixel[2]), 0.25, accuracy: 0.02)
    }

    // MARK: - Additive capability API
    func testExportFormatCapabilityLabelsAreHonest() {
        let png = ExportFormat.png16Bit
        XCTAssertEqual(png.displayName, "16-bit SDR PNG")
        XCTAssertTrue(png.helpText.contains("refused"))
        XCTAssertFalse(png.supportsExtendedHDR)
        XCTAssertEqual(png.extendedHDRSupport, .unsupported)
        XCTAssertEqual(png.capability, .sdr16BitPNG)

        let tiff = ExportFormat.tiff16BitLZW
        XCTAssertTrue(tiff.displayName.contains("HDR"))
        XCTAssertTrue(tiff.supportsExtendedHDR)
        XCTAssertEqual(tiff.extendedHDRSupport, .supported)
        XCTAssertEqual(tiff.capability, .linearHDRTIFF)

        let dng = ExportFormat.linearDNG16Bit
        XCTAssertTrue(dng.supportsExtendedHDR)
        XCTAssertEqual(dng.capability, .linearHDRDNG)

        let heic = ExportFormat.heic10BitHDR
        XCTAssertTrue(heic.displayName.contains("HDR"))
        XCTAssertTrue(heic.shortHelp.lowercased().contains("verified"))
        XCTAssertEqual(heic.extendedHDRSupport, .verifiedAtRuntime)
        XCTAssertFalse(heic.supportsExtendedHDR, "HDR HEIC is runtime-verified, not guaranteed")
        XCTAssertTrue(heic.helpText.lowercased().contains("gain map"))
        XCTAssertEqual(heic.capability, .hdrHEIC)

        let jpeg = ExportFormat.jpeg95
        XCTAssertTrue(jpeg.displayName.contains("SDR"))
        XCTAssertFalse(jpeg.supportsExtendedHDR)
        XCTAssertEqual(jpeg.capability, .sdr8BitJPEG)

        for format in ExportFormat.allCases {
            XCTAssertFalse(format.displayName.isEmpty)
            XCTAssertFalse(format.shortHelp.isEmpty)
            XCTAssertFalse(format.helpText.isEmpty)
            XCTAssertFalse(format.capability.rawValue.isEmpty)
        }
    }

    // MARK: - Fixtures

    private func makeArtifacts(
        category: SourceImageCategory,
        exportFormat: ExportFormat = .autoMatchSource,
        hasAlpha: Bool = false,
        hdrGainMapData: Data? = nil,
        hdrGainMapWidth: Int? = nil,
        hdrGainMapHeight: Int? = nil,
        hdrGainMapAuxiliaryType: HDRGainMapAuxiliaryType? = nil,
        rawParameters: CameraRAWParameters? = nil
    ) throws -> CompletedPipelineArtifacts {
        let metadata = ImageMetadataPacket(
            sourceURL: tempDirectory.appendingPathComponent("IMG_0001.heic"),
            utTypeIdentifier: "public.heic",
            category: category,
            originalWidth: Self.sourceWidth,
            originalHeight: Self.sourceHeight,
            originalOrientation: 6,
            bitsPerComponent: 12,
            hasAlpha: hasAlpha,
            isoSpeedRatings: 800,
            rawPropertiesPlistData: try makeRawPropertiesPlistData(),
            iccProfileData: Self.sRGBICCProfileData(),
            hdrGainMapAuxiliaryData: hdrGainMapData,
            hdrGainMapWidth: hdrGainMapWidth,
            hdrGainMapHeight: hdrGainMapHeight,
            rawParameters: rawParameters,
            isAlreadyDenoisedBySuite: false,
            hdrGainMapAuxiliaryType: hdrGainMapAuxiliaryType
        )

        let sourceBuffer = try MMapBuffer(
            fileURL: tempDirectory.appendingPathComponent("source_rgba16f.bin"),
            width: Self.sourceWidth,
            height: Self.sourceHeight,
            deleteOnDeinit: true
        )
        for y in 0..<Self.sourceHeight {
            for x in 0..<Self.sourceWidth {
                let pixel = sourceBuffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = Float16(0.05 + 0.9 * Float(x) / Float(Self.sourceWidth - 1))
                pixel[1] = Float16(0.05 + 0.9 * Float(y) / Float(Self.sourceHeight - 1))
                pixel[2] = Float16(0.25)
                pixel[3] = 1.0
            }
        }

        let outputBuffer = try MMapBuffer(
            fileURL: tempDirectory.appendingPathComponent("output_rgba16f.bin"),
            width: Self.outputWidth,
            height: Self.outputHeight,
            deleteOnDeinit: true
        )
        for y in 0..<Self.outputHeight {
            for x in 0..<Self.outputWidth {
                let pixel = outputBuffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = Float16(Float(x) / Float(Self.outputWidth - 1))
                pixel[1] = Float16(Float(y) / Float(Self.outputHeight - 1))
                pixel[2] = 0.5
                pixel[3] = 1.0
            }
        }

        let config = UpscaleJobConfig(
            id: UUID(),
            sourceImageURL: metadata.sourceURL,
            scaleFactor: .x4,
            backbone: .quickSRNet,
            denoiseMode: .auto,
            naturalGrainAmount: 0.0,
            exportFormat: exportFormat
        )
        let checkpoint = JobCheckpointState(
            jobID: UUID(),
            config: config,
            tileConfig: TileConfiguration(tier: .tierA_HighMemory),
            sourceWidth: Self.sourceWidth,
            sourceHeight: Self.sourceHeight,
            paddedSourceWidth: 256,
            paddedSourceHeight: 256,
            outputWidth: Self.outputWidth,
            outputHeight: Self.outputHeight,
            globalMaxLuminance: 1.5,
            alphaCurveConstant: 16.0,
            didRunDenoise: true,
            sourceMMapFileName: "source_rgba16f.bin",
            outputMMapFileName: "output_rgba16f.bin",
            metadataPacketFileName: "metadata.plist",
            lastCompletedTileIndex: 0,
            totalTiles: 1
        )
        return CompletedPipelineArtifacts(
            checkpoint: checkpoint,
            metadata: metadata,
            sourceBuffer: sourceBuffer,
            outputBuffer: outputBuffer
        )
    }

    private func makeRawPropertiesPlistData() throws -> Data {
        let properties: [String: Any] = [
            kCGImagePropertyPixelWidth as String: Self.sourceWidth,
            kCGImagePropertyPixelHeight as String: Self.sourceHeight,
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifUserComment as String: "Shot on iPhone 17 Pro",
                kCGImagePropertyExifISOSpeedRatings as String: [800],
                kCGImagePropertyExifDateTimeOriginal as String: "2025:03:04 05:06:07",
                kCGImagePropertyExifFNumber as String: 1.78,
                kCGImagePropertyExifExposureTime as String: 0.008,
                kCGImagePropertyExifFocalLength as String: 24.0,
                kCGImagePropertyExifLensMake as String: "Apple",
                kCGImagePropertyExifLensModel as String: "iPhone 17 Pro back camera",
            ] as [String: Any],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Apple",
                kCGImagePropertyTIFFModel as String: "iPhone 17 Pro",
                kCGImagePropertyTIFFSoftware as String: "17.4",
                kCGImagePropertyTIFFOrientation as String: 6,
            ] as [String: Any],
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 37.7749,
                kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 122.4194,
                kCGImagePropertyGPSLongitudeRef as String: "W",
                kCGImagePropertyGPSAltitude as String: 15.5,
                kCGImagePropertyGPSAltitudeRef as String: 0,
            ] as [String: Any],
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: properties,
            format: .binary,
            options: 0
        )
    }

    private func setAllPixels(
        _ artifacts: CompletedPipelineArtifacts,
        red: Float,
        green: Float,
        blue: Float,
        alpha: Float
    ) {
        for y in 0..<artifacts.outputBuffer.height {
            for x in 0..<artifacts.outputBuffer.width {
                let pixel = artifacts.outputBuffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = Float16(red)
                pixel[1] = Float16(green)
                pixel[2] = Float16(blue)
                pixel[3] = Float16(alpha)
            }
        }
    }

    // MARK: - Decoded-pixel helpers

    private func pixel(_ pixels: [Float], x: Int, y: Int) -> (Float, Float, Float, Float) {
        let index = (y * Self.outputWidth + x) * 4
        return (pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3])
    }

    private func decodePixels(at url: URL) throws -> [Float] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = Self.outputWidth
        let height = Self.outputHeight
        let rowBytes = width * 16
        var buffer = [UInt8](repeating: 0, count: rowBytes * height)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
                | CGBitmapInfo.floatComponents.rawValue
        )
        var didDraw = false
        buffer.withUnsafeMutableBytes { rawBuffer in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 32,
                bytesPerRow: rowBytes,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            didDraw = true
        }
        try XCTSkipUnless(didDraw, "Float RGB CGContext unavailable on this host")
        return buffer.withUnsafeBytes { rawBuffer -> [Float] in
            let base = rawBuffer.baseAddress!.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: base, count: width * height * 4))
        }
    }

    private func assertNoStagingFilesLeft() {
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)) ?? []
        XCTAssertTrue(
            remaining.allSatisfy { !$0.contains(".staging-") },
            "Staging files were left behind: \(remaining.filter { $0.contains(".staging-") })"
        )
    }

    // MARK: - Minimal TIFF/DNG tag reader (independent of the writer)

    private struct TIFFTag {
        let type: UInt16
        let count: UInt32
        let payload: Data?
    }

    private func parseTIFFTags(at url: URL) throws -> [UInt16: TIFFTag] {
        let data = try Data(contentsOf: url)
        guard data.count >= 10, data[0] == 0x49, data[1] == 0x49 else {
            throw NSError(domain: "ExportContractTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Not a little-endian TIFF"])
        }
        guard readU16(data, 2) == 42 else {
            throw NSError(domain: "ExportContractTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unsupported TIFF magic"])
        }
        return parseIFD(data, at: Int(readU32(data, 4)))
    }

    private func parseIFD(_ data: Data, at ifdOffset: Int) -> [UInt16: TIFFTag] {
        guard ifdOffset + 2 <= data.count else { return [:] }
        let entryCount = Int(readU16(data, ifdOffset))
        var tags: [UInt16: TIFFTag] = [:]
        for index in 0..<entryCount {
            let entryOffset = ifdOffset + 2 + index * 12
            guard entryOffset + 12 <= data.count else { break }
            let tag = readU16(data, entryOffset)
            let type = readU16(data, entryOffset + 2)
            let count = readU32(data, entryOffset + 4)
            let valueOrOffset = readU32(data, entryOffset + 8)
            let elementSize = tiffTypeSize(type)
            let byteCount = Int(count) * elementSize
            var payload: Data?
            if byteCount <= 4 {
                let start = entryOffset + 8
                if start + byteCount <= data.count {
                    payload = data.subdata(in: start..<(start + byteCount))
                }
            } else {
                let start = Int(valueOrOffset)
                if start + byteCount <= data.count {
                    payload = data.subdata(in: start..<(start + byteCount))
                }
            }
            if tags[tag] == nil {
                tags[tag] = TIFFTag(type: type, count: count, payload: payload)
            }
        }
        return tags
    }

    private func nestedIFD(_ tags: [UInt16: TIFFTag], pointerTag: UInt16, in data: Data) -> [UInt16: TIFFTag]? {
        guard let payload = tags[pointerTag]?.payload, payload.count >= 4 else { return nil }
        let offset = Int(readU32(payload, 0))
        guard offset > 0 else { return nil }
        let nested = parseIFD(data, at: offset)
        return nested.isEmpty ? nil : nested
    }

    private func asciiValue(
        _ tags: [UInt16: TIFFTag],
        _ tag: UInt16,
        skipASCIIPrefix: Bool = false
    ) throws -> String {
        let payload = try XCTUnwrap(tags[tag]?.payload)
        var bytes = [UInt8](payload)
        if skipASCIIPrefix, bytes.count >= 8, Array(bytes.prefix(8)) == Array("ASCII\0\0\0".utf8) {
            bytes.removeFirst(8)
        }
        while bytes.last == 0 {
            bytes.removeLast()
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private func stripData(_ tags: [UInt16: TIFFTag], at url: URL) throws -> [Data] {
        let offsets = longValues(tags, 273)
        let counts = longValues(tags, 279)
        let data = try Data(contentsOf: url)
        var strips: [Data] = []
        for index in 0..<min(offsets.count, counts.count) {
            let start = Int(offsets[index])
            let end = start + Int(counts[index])
            guard end <= data.count else { continue }
            strips.append(data.subdata(in: start..<end))
        }
        return strips
    }

    private func tiffTypeSize(_ type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11: return 4
        case 5, 10, 12: return 8
        default: return 1
        }
    }

    private func shortValue(_ tags: [UInt16: TIFFTag], _ tag: UInt16) throws -> UInt16 {
        let payload = try XCTUnwrap(tags[tag]?.payload)
        return readU16(payload, 0)
    }

    private func shortValues(_ tags: [UInt16: TIFFTag], _ tag: UInt16) throws -> [UInt16] {
        let payload = try XCTUnwrap(tags[tag]?.payload)
        return (0..<(payload.count / 2)).map { readU16(payload, $0 * 2) }
    }

    private func longValue(_ tags: [UInt16: TIFFTag], _ tag: UInt16) throws -> UInt32 {
        let payload = try XCTUnwrap(tags[tag]?.payload)
        return readU32(payload, 0)
    }

    private func longValues(_ tags: [UInt16: TIFFTag], _ tag: UInt16) -> [UInt32] {
        guard let payload = tags[tag]?.payload else { return [] }
        return (0..<(payload.count / 4)).map { readU32(payload, $0 * 4) }
    }

    private func rationalValues(_ tags: [UInt16: TIFFTag], _ tag: UInt16) throws -> [Double] {
        let payload = try XCTUnwrap(tags[tag]?.payload)
        return (0..<(payload.count / 8)).map { index in
            let numerator = readU32(payload, index * 8)
            let denominator = readU32(payload, index * 8 + 4)
            return denominator == 0 ? 0 : Double(numerator) / Double(denominator)
        }
    }

    private func srationalValue(_ tags: [UInt16: TIFFTag], _ tag: UInt16) throws -> Double {
        let payload = try XCTUnwrap(tags[tag]?.payload)
        return srationalValue(payload, index: 0)
    }

    private func srationalValues(_ tags: [UInt16: TIFFTag], _ tag: UInt16) throws -> [Double] {
        let payload = try XCTUnwrap(tags[tag]?.payload)
        return (0..<(payload.count / 8)).map { srationalValue(payload, index: $0) }
    }

    private func srationalValue(_ payload: Data, index: Int) -> Double {
        let numerator = Int32(bitPattern: readU32(payload, index * 8))
        let denominator = Int32(bitPattern: readU32(payload, index * 8 + 4))
        return denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }

    private func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 3 < data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func readU16BE(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private func readU32BE(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 3 < data.count else { return 0 }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    // MARK: - ProfileDynamicRange (tag 52551)

    private struct ProfileDynamicRangePayload {
        let version: UInt16
        let dynamicRange: UInt16
        let hint: Float
        let bigEndian: Bool
    }

    /// DNG 1.7.1 ProfileDynamicRange (tag 52551) is an 8-byte UNDEFINED blob whose inner
    /// `SHORT version, SHORT dynamicRange, FLOAT HintMaxOutputValue` fields are BIG-endian even
    /// though the outer TIFF container is little-endian (the Adobe/ExifTool encoding). Accept the
    /// earlier suite little-endian payload as a fallback so legacy fixtures still parse.
    private func profileDynamicRangeValues(
        _ payload: Data
    ) -> ProfileDynamicRangePayload? {
        guard payload.count >= 8 else { return nil }
        let candidates = [
            ProfileDynamicRangePayload(
                version: readU16BE(payload, 0),
                dynamicRange: readU16BE(payload, 2),
                hint: Float(bitPattern: readU32BE(payload, 4)),
                bigEndian: true
            ),
            ProfileDynamicRangePayload(
                version: readU16(payload, 0),
                dynamicRange: readU16(payload, 2),
                hint: Float(bitPattern: readU32(payload, 4)),
                bigEndian: false
            ),
        ]
        return candidates.first { candidate in
            candidate.version == 1
                && (candidate.dynamicRange == 0 || candidate.dynamicRange == 1)
                && candidate.hint.isFinite
                && candidate.hint > 0
        }
    }

    // MARK: - Platform helpers

    private static func hasHEICEncoder() -> Bool {
        let supported = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return supported.contains("public.heic") || supported.contains("public.heif")
    }

    private static func sRGBICCProfileData() -> Data? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return colorSpace.copyICCData().map { $0 as Data }
    }
}

extension ExportContractTests {
    func testNoiserHistoryAndScalerEventSurviveRealExportReingestInEveryFormat() throws {
        let base = try makeArtifacts(category: .standardOpaqueRaster)
        let noiser = ImageProcessingHistory.Step(id: UUID(), app: "com.iantruong.truongnoiser", operation: "denoise",
            model: "fixture-trained-model", date: Date(timeIntervalSince1970: 1790000000),
            inputWidth: 16, inputHeight: 12, outputWidth: 16, outputHeight: 12)
        let history = ImageProcessingHistory(steps: [noiser])
        let metadata = base.metadata.withPipelineState(isDenoised: true, isAlreadyDenoisedByNoiser: true, processingHistory: history)
        let artifacts = CompletedPipelineArtifacts(checkpoint: base.checkpoint, metadata: metadata, sourceBuffer: base.sourceBuffer, outputBuffer: base.outputBuffer)
        let carried = try JSONDecoder().decode(PipelineSessionState.self, from: JSONEncoder().encode(metadata.pipelineSessionState))
        let redecoded = base.metadata.merging(sessionState: carried)
        XCTAssertTrue(redecoded.isAlreadyDenoisedByNoiser, "Handoff-only Noiser attribution must survive pipeline re-decode/resume")
        XCTAssertEqual(redecoded.processingHistory, history)
        let expected = FormatAwareExporter.processedMetadata(artifacts: artifacts)
        XCTAssertEqual(expected.processingHistory?.steps.map(\.operation), ["denoise", "upscale"])
        XCTAssertEqual(expected.processingHistory?.steps.last?.id, base.checkpoint.jobID)
        let repeated = CompletedPipelineArtifacts(checkpoint: base.checkpoint, metadata: expected, sourceBuffer: base.sourceBuffer, outputBuffer: base.outputBuffer)
        XCTAssertEqual(FormatAwareExporter.processedMetadata(artifacts: repeated).processingHistory, expected.processingHistory)
        let formats: [(ExportFormat, String)] = [(.linearDNG16Bit, "dng"), (.tiff16BitLZW, "tiff"), (.png16Bit, "png"), (.jpeg95, "jpg"), (.heic10BitHDR, "heic")]
        for (format, ext) in formats {
            if ext == "heic", !(CGImageDestinationCopyTypeIdentifiers() as! [String]).contains("public.heic") { continue }
            let url = tempDirectory.appendingPathComponent("history." + ext)
            _ = try FormatAwareExporter.exportImage(artifacts: artifacts, destinationURL: url, overrideFormat: format, overrideGrainAmount: 0)
            let decoded = try MetadataExtractor.extractMetadata(from: url)
            XCTAssertTrue(decoded.isAlreadyUpscaledBySuite, ext)
            XCTAssertTrue(decoded.isAlreadyDenoisedBySuite, ext)
            XCTAssertTrue(decoded.isAlreadyDenoisedByNoiser, ext)
            XCTAssertEqual(decoded.processingHistory, expected.processingHistory, ext)
            XCTAssertEqual(decoded.processingHistory?.steps.last?.outputWidth, base.outputBuffer.width, ext)
        }
    }
    func testLegacyUnknownDenoiseIsNotFalselyAttributedToNoiserAndFutureMarkersSurvive() throws {
        let history = ImageProcessingHistory(steps: [.init(id: UUID(), app: "com.iantruong.truongscaler", operation: "upscale",
            model: "QuickSRNet-Large", scale: 2, inputWidth: 12, inputHeight: 12, outputWidth: 24, outputHeight: 24)])
        let packet = try makeArtifacts(category: .standardOpaqueRaster).metadata
            .withPipelineState(isDenoised: true, isAlreadyDenoisedByNoiser: false, processingHistory: history)
        let props = MetadataReinjector.buildDestinationProperties(from: packet, upscaledWidth: 64, upscaledHeight: 48, exportFormat: .tiff16BitLZW)
        let exif = props[kCGImagePropertyExifDictionary] as? [String: Any]
        let comment = try XCTUnwrap(exif?[kCGImagePropertyExifUserComment as String] as? String)
        XCTAssertTrue(comment.contains("Denoised=true"))
        XCTAssertTrue(comment.contains("NoiserDenoised=false"))
        XCTAssertEqual(ImageProcessingHistory.parse(comment), history)
        XCTAssertNil(ImageProcessingHistory.parse("ProcessingHistoryV1=invalid"))
        XCTAssertNil(ImageProcessingHistory.parse("ProcessingHistoryV1=" + String(repeating: "A", count: 23000)))
        let unknown = packet.applyingSuiteHandoff(isDenoised: true, isUpscaled: false, upscaleFactor: nil, linearHeadroomScale: 1)
        XCTAssertTrue(unknown.isAlreadyDenoisedBySuite)
        XCTAssertFalse(unknown.isAlreadyDenoisedByNoiser, "Generic suite state does not identify its author")
    }
}
