import XCTest
import Foundation
import CoreGraphics
import ImageIO
import CoreIngestion
@testable import CoreExport
@testable import TiledInferenceEngine
@testable import MMapCanvas
@testable import TruongScalerCore

/// Thread-safe collector for `@Sendable` progress callbacks.
private final class ProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class CoreExportTests: XCTestCase {
    private static let sourceWidth = 16
    private static let sourceHeight = 12
    private static let scaleFactor = 4
    private static let outputWidth = sourceWidth * scaleFactor
    private static let outputHeight = sourceHeight * scaleFactor

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CoreExportTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    // MARK: - Export Across All Formats

    func testExportAllFormatsAndEXIFPreservation() async throws {
        let artifacts = try makeArtifacts(category: .standardOpaqueRaster)
        let formats: [ExportFormat] = [
            .linearDNG16Bit,
            .tiff16BitLZW,
            .png16Bit,
            .heic10BitHDR,
            .jpeg95
        ]

        var verified: [ExportFormat] = []
        var heicSkipped = false

        for format in formats {
            if format == .heic10BitHDR && !Self.hasHEICEncoder() {
                heicSkipped = true
                continue
            }

            let destinationURL = tempDirectory
                .appendingPathComponent("IMG_0001_4x.\(Self.fileExtension(for: format))")
            let progress = ProgressProbe()
            do {
                let returnedURL = try FormatAwareExporter.exportImage(
                    artifacts: artifacts,
                    destinationURL: destinationURL,
                    overrideFormat: format,
                    overrideGrainAmount: 0.0,
                    progressHandler: { progress.record($0) }
                )
                XCTAssertEqual(returnedURL, destinationURL)
            } catch {
                if format == .heic10BitHDR && !Self.hasHEICEncoder() {
                    heicSkipped = true
                    continue
                }
                XCTFail("Export failed for \(format.rawValue): \(error)")
                continue
            }

            if format == .linearDNG16Bit {
                // Apple ImageIO does not open rendered LinearRaw DNGs; the suite's independent
                // TIFF reader is the contract's DNG-aware decode path.
                try assertSuiteLinearDNG(at: destinationURL)
            } else {
                try assertExportedFile(at: destinationURL, format: format)
                try assertPixelFidelity(at: destinationURL, format: format)
            }

            let progressValues = progress.snapshot
            XCTAssertFalse(progressValues.isEmpty, "No progress reported for \(format.rawValue)")
            XCTAssertEqual(progressValues.first ?? -1, 0.0, accuracy: 0.0001)
            XCTAssertEqual(progressValues.last ?? -1, 1.0, accuracy: 0.0001)
            XCTAssertTrue(
                progressValues.allSatisfy { $0 >= 0.0 && $0 <= 1.0 },
                "Progress out of 0...1 for \(format.rawValue): \(progressValues)"
            )
            verified.append(format)
        }

        let expectedCount = heicSkipped ? formats.count - 1 : formats.count
        XCTAssertEqual(verified.count, expectedCount, "Verified formats: \(verified)")
        XCTAssertTrue(verified.contains(.linearDNG16Bit))
        XCTAssertTrue(verified.contains(.tiff16BitLZW))
        XCTAssertTrue(verified.contains(.png16Bit))
        XCTAssertTrue(verified.contains(.jpeg95))
        if !heicSkipped {
            XCTAssertTrue(verified.contains(.heic10BitHDR))
        }

        if heicSkipped {
            throw XCTSkip("HEIC encoder unavailable on this host; other formats were verified.")
        }
    }

    func testExportFormatResolutionUsesMetadataAndOverridePrecedence() throws {
        // No override: `.autoMatchSource` resolves to Linear DNG for a camera RAW packet.
        let rawArtifacts = try makeArtifacts(category: .cameraRAW)
        let rawURL = tempDirectory.appendingPathComponent("IMG_0002_auto.dng")
        _ = try FormatAwareExporter.exportImage(
            artifacts: rawArtifacts,
            destinationURL: rawURL,
            overrideGrainAmount: 0.0
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawURL.path))
        let rawInfo = try XCTUnwrap(LinearDNGTIFFReader.probe(imageURL: rawURL))
        XCTAssertEqual(rawInfo.width, Self.outputWidth)
        XCTAssertEqual(rawInfo.height, Self.outputHeight)
        XCTAssertEqual(rawInfo.photometricInterpretation, 34892)
        XCTAssertEqual(rawInfo.bitsPerSample, [16, 16, 16])
        XCTAssertEqual(rawInfo.orientation, 1)
        XCTAssertEqual(rawInfo.headroomScaleFromDescription ?? -1, 1.0, accuracy: 0.0001)
        let rawDecoded = try UniversalStripDecoder.decodeToMMap(
            imageURL: rawURL,
            destinationMMapURL: tempDirectory.appendingPathComponent("raw-auto.bin")
        )
        XCTAssertEqual(rawDecoded.decodedWidth, Self.outputWidth)
        XCTAssertEqual(rawDecoded.decodedHeight, Self.outputHeight)
        XCTAssertTrue(rawDecoded.metadata.hasSuiteLinearDNGMarker)
        XCTAssertEqual(rawDecoded.metadata.linearHeadroomScale ?? -1, 1.0, accuracy: 0.0001)

        // Explicit override wins over the checkpoint configuration.
        let jpegArtifacts = try makeArtifacts(
            category: .standardOpaqueRaster,
            exportFormat: .jpeg95
        )
        let pngURL = tempDirectory.appendingPathComponent("IMG_0003_override.png")
        _ = try FormatAwareExporter.exportImage(
            artifacts: jpegArtifacts,
            destinationURL: pngURL,
            overrideFormat: .png16Bit,
            overrideGrainAmount: 0.0
        )
        let pngHeader = Array(try Data(contentsOf: pngURL).prefix(8))
        XCTAssertEqual(
            pngHeader,
            [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
            "Override format did not produce a PNG container"
        )
    }

    func testExportWithGrainBlendingStreamsBlendedRows() throws {
        let artifacts = try makeArtifacts(category: .standardOpaqueRaster)
        let destinationURL = tempDirectory.appendingPathComponent("IMG_0004_grain.png")
        let progress = ProgressProbe()

        let returnedURL = try FormatAwareExporter.exportImage(
            artifacts: artifacts,
            destinationURL: destinationURL,
            overrideFormat: .png16Bit,
            overrideGrainAmount: 0.35,
            progressHandler: { progress.record($0) }
        )
        XCTAssertEqual(returnedURL, destinationURL)

        let imageSource = try XCTUnwrap(
            CGImageSourceCreateWithURL(destinationURL as CFURL, nil)
        )
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
        )
        XCTAssertEqual(
            properties[kCGImagePropertyPixelWidth as String] as? Int,
            Self.outputWidth
        )
        XCTAssertEqual(
            properties[kCGImagePropertyPixelHeight as String] as? Int,
            Self.outputHeight
        )
        XCTAssertEqual(
            properties[kCGImagePropertyOrientation as String] as? Int,
            1
        )
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))

        let progressValues = progress.snapshot
        XCTAssertEqual(progressValues.first ?? -1, 0.0, accuracy: 0.0001)
        XCTAssertEqual(progressValues.last ?? -1, 1.0, accuracy: 0.0001)
    }

    // MARK: - MetadataReinjector

    func testExportRejectsSourceAndMMapDestinationAliasesWithoutWriting() throws {
        let artifacts = try makeArtifacts(category: .standardOpaqueRaster)
        try Data("original-file-content".utf8).write(to: artifacts.metadata.sourceURL)
        for input in [artifacts.metadata.sourceURL, artifacts.sourceBuffer.fileURL, artifacts.outputBuffer.fileURL] {
            let original = try Data(contentsOf: input)
            let symlink = tempDirectory.appendingPathComponent("alias-\(UUID().uuidString).png")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: input)
            let hardlink = tempDirectory.appendingPathComponent("hardlink-\(UUID().uuidString).png")
            try FileManager.default.linkItem(at: input, to: hardlink)
            for destination in [input, symlink, hardlink] {
                XCTAssertThrowsError(try FormatAwareExporter.exportImage(
                    artifacts: artifacts, destinationURL: destination,
                    overrideFormat: .png16Bit, overrideGrainAmount: 0
                ))
                XCTAssertEqual(try Data(contentsOf: input), original)
            }
        }
    }

    func testHDRTIFFRetainsExtendedLinearHighlights() throws {
        let artifacts = try makeArtifacts(category: .standardOpaqueRaster, globalMaxLuminance: 4)
        for y in 0..<artifacts.outputBuffer.height {
            for x in 0..<artifacts.outputBuffer.width {
                let pixel = artifacts.outputBuffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = 4; pixel[1] = 4; pixel[2] = 4; pixel[3] = 1
            }
        }
        let destination = tempDirectory.appendingPathComponent("HDR.tiff")
        _ = try FormatAwareExporter.exportImage(artifacts: artifacts, destinationURL: destination,
            overrideFormat: .tiff16BitLZW, overrideGrainAmount: 0)
        let decoded = try UniversalStripDecoder.decodeToMMap(imageURL: destination,
            destinationMMapURL: tempDirectory.appendingPathComponent("HDR-tiff.bin"))
        let pixel = decoded.sourceBuffer.unsafePixelPointer(x: 20, y: 20)
        XCTAssertEqual(Float(pixel[0]), 4, accuracy: 0.01)
        XCTAssertEqual(Float(pixel[1]), 4, accuracy: 0.01)
        XCTAssertEqual(Float(pixel[2]), 4, accuracy: 0.01)
    }

    func testJPEGFlattensPremultipliedAlphaBeforeTransferFunction() throws {
        let artifacts = try makeArtifacts(category: .standardAlphaRaster)
        for y in 0..<artifacts.outputBuffer.height {
            for x in 0..<artifacts.outputBuffer.width {
                let pixel = artifacts.outputBuffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = 0.25; pixel[1] = 0.125; pixel[2] = 0.0625; pixel[3] = 0.5
            }
        }
        let destination = tempDirectory.appendingPathComponent("alpha.jpg")
        _ = try FormatAwareExporter.exportImage(artifacts: artifacts, destinationURL: destination,
            overrideFormat: .jpeg95, overrideGrainAmount: 0)
        let decoded = try UniversalStripDecoder.decodeToMMap(imageURL: destination,
            destinationMMapURL: tempDirectory.appendingPathComponent("alpha-jpeg.bin"))
        let pixel = decoded.sourceBuffer.unsafePixelPointer(x: 20, y: 20)
        XCTAssertEqual(Float(pixel[0]), 0.25, accuracy: 0.015)
        XCTAssertEqual(Float(pixel[1]), 0.125, accuracy: 0.015)
        XCTAssertEqual(Float(pixel[2]), 0.0625, accuracy: 0.015)
        XCTAssertEqual(Float(pixel[3]), 1, accuracy: 0.001)
    }

    func testMetadataReinjectorHandlesNilAndMalformedPropertyLists() throws {
        // 1. nil rawPropertiesPlistData must not crash and must still produce dimensions/orientation.
        let nilMetadata = makeMetadata(rawPropertiesPlistData: nil)
        let nilProperties = MetadataReinjector.buildDestinationProperties(
            from: nilMetadata,
            upscaledWidth: 128,
            upscaledHeight: 96,
            exportFormat: .jpeg95
        )
        XCTAssertEqual(nilProperties[kCGImagePropertyPixelWidth] as? Int, 128)
        XCTAssertEqual(nilProperties[kCGImagePropertyPixelHeight] as? Int, 96)
        XCTAssertEqual(nilProperties[kCGImagePropertyOrientation] as? Int, 1)
        XCTAssertEqual(
            nilProperties[kCGImageDestinationLossyCompressionQuality] as? Double,
            0.95
        )
        let nilExif = nilProperties[kCGImagePropertyExifDictionary] as? [String: Any]
        XCTAssertEqual(
            nilExif?[kCGImagePropertyExifPixelXDimension as String] as? Int,
            128
        )
        XCTAssertEqual(
            nilExif?[kCGImagePropertyExifPixelYDimension as String] as? Int,
            96
        )
        let nilComment = nilExif?[kCGImagePropertyExifUserComment as String] as? String ?? ""
        XCTAssertTrue(nilComment.contains("UpscaledByApp=true"))
        XCTAssertTrue(nilComment.contains("UpscaledFactor=4x"))
        XCTAssertTrue(nilComment.contains("Denoised=true"))
        let nilTiff = nilProperties[kCGImagePropertyTIFFDictionary] as? [String: Any]
        XCTAssertEqual(
            nilTiff?[kCGImagePropertyTIFFSoftware as String] as? String,
            MetadataReinjector.softwareTag
        )
        XCTAssertEqual(
            nilTiff?[kCGImagePropertyTIFFOrientation as String] as? Int,
            1
        )

        // 2. Malformed property list data (not a plist) must also degrade gracefully.
        let malformedMetadata = makeMetadata(
            rawPropertiesPlistData: Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01])
        )
        let malformedProperties = MetadataReinjector.buildDestinationProperties(
            from: malformedMetadata,
            upscaledWidth: 64,
            upscaledHeight: 48,
            exportFormat: .png16Bit
        )
        XCTAssertEqual(malformedProperties[kCGImagePropertyPixelWidth] as? Int, 64)
        XCTAssertEqual(malformedProperties[kCGImagePropertyPixelHeight] as? Int, 48)
        XCTAssertEqual(malformedProperties[kCGImagePropertyOrientation] as? Int, 1)
        XCTAssertEqual(malformedProperties[kCGImagePropertyDepth] as? Int, 16)
        XCTAssertNotNil(malformedProperties[kCGImagePropertyExifDictionary])

        // 3. Realistic plist data is deep-merged: nested EXIF/TIFF/GPS/top-level keys survive.
        let plistMetadata = makeMetadata(
            rawPropertiesPlistData: try makeRawPropertiesPlistData()
        )
        let merged = MetadataReinjector.buildDestinationProperties(
            from: plistMetadata,
            upscaledWidth: 64,
            upscaledHeight: 48,
            exportFormat: .tiff16BitLZW
        )
        XCTAssertEqual(merged[kCGImagePropertyPixelWidth] as? Int, 64)
        XCTAssertEqual(merged[kCGImagePropertyPixelHeight] as? Int, 48)
        XCTAssertEqual(merged[kCGImagePropertyOrientation] as? Int, 1)
        XCTAssertEqual(merged[kCGImagePropertyDepth] as? Int, 16)
        XCTAssertEqual(merged[kCGImagePropertyDPIWidth] as? Int, 300)

        let mergedExif = merged[kCGImagePropertyExifDictionary] as? [String: Any]
        XCTAssertEqual(
            mergedExif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int],
            [800]
        )
        XCTAssertEqual(
            mergedExif?[kCGImagePropertyExifDateTimeOriginal as String] as? String,
            "2025:03:04 05:06:07"
        )
        XCTAssertEqual(
            mergedExif?[kCGImagePropertyExifPixelXDimension as String] as? Int,
            64
        )
        XCTAssertEqual(
            mergedExif?[kCGImagePropertyExifPixelYDimension as String] as? Int,
            48
        )
        let mergedComment = mergedExif?[kCGImagePropertyExifUserComment as String] as? String ?? ""
        XCTAssertTrue(mergedComment.contains("Shot on iPhone 17 Pro"))
        XCTAssertTrue(mergedComment.contains("UpscaledByApp=true"))
        XCTAssertTrue(mergedComment.contains("UpscaledFactor=4x"))

        let mergedTiff = merged[kCGImagePropertyTIFFDictionary] as? [String: Any]
        XCTAssertEqual(
            mergedTiff?[kCGImagePropertyTIFFMake as String] as? String,
            "Apple"
        )
        XCTAssertEqual(
            mergedTiff?[kCGImagePropertyTIFFModel as String] as? String,
            "iPhone 17 Pro"
        )
        XCTAssertEqual(
            mergedTiff?[kCGImagePropertyTIFFCompression as String] as? Int,
            5
        )
        XCTAssertEqual(
            mergedTiff?[kCGImagePropertyTIFFOrientation as String] as? Int,
            1
        )

        let mergedGPS = merged[kCGImagePropertyGPSDictionary] as? [String: Any]
        XCTAssertEqual(
            mergedGPS?[kCGImagePropertyGPSLatitude as String] as? Double ?? -1,
            37.7749,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            mergedGPS?[kCGImagePropertyGPSLongitudeRef as String] as? String,
            "W"
        )
        XCTAssertNotNil(merged[kCGImagePropertyProfileName])
    }

    // MARK: - Fixtures

    private func makeArtifacts(
        category: SourceImageCategory,
        exportFormat: ExportFormat = .autoMatchSource,
        globalMaxLuminance: Float = 1.5
    ) throws -> CompletedPipelineArtifacts {
        let metadata = ImageMetadataPacket(
            sourceURL: tempDirectory.appendingPathComponent("IMG_0001.heic"),
            utTypeIdentifier: "public.heic",
            category: category,
            originalWidth: Self.sourceWidth,
            originalHeight: Self.sourceHeight,
            originalOrientation: 6,
            bitsPerComponent: 12,
            hasAlpha: false,
            isoSpeedRatings: 800,
            rawPropertiesPlistData: try makeRawPropertiesPlistData(),
            iccProfileData: Self.sRGBICCProfileData(),
            isAlreadyDenoisedBySuite: false
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
                pixel[2] = Float16(0.5)
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
            globalMaxLuminance: globalMaxLuminance,
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

    private func makeMetadata(rawPropertiesPlistData: Data?) -> ImageMetadataPacket {
        ImageMetadataPacket(
            sourceURL: tempDirectory.appendingPathComponent("IMG_0001.heic"),
            utTypeIdentifier: "public.heic",
            category: .standardOpaqueRaster,
            originalWidth: Self.sourceWidth,
            originalHeight: Self.sourceHeight,
            originalOrientation: 6,
            bitsPerComponent: 12,
            hasAlpha: false,
            isoSpeedRatings: 800,
            rawPropertiesPlistData: rawPropertiesPlistData,
            iccProfileData: Self.sRGBICCProfileData(),
            isAlreadyDenoisedBySuite: true
        )
    }

    private func makeRawPropertiesPlistData() throws -> Data {
        let properties: [String: Any] = [
            kCGImagePropertyPixelWidth as String: Self.sourceWidth,
            kCGImagePropertyPixelHeight as String: Self.sourceHeight,
            kCGImagePropertyOrientation as String: 6,
            kCGImagePropertyDPIWidth as String: 300,
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifUserComment as String: "Shot on iPhone 17 Pro",
                kCGImagePropertyExifISOSpeedRatings as String: [800],
                kCGImagePropertyExifDateTimeOriginal as String: "2025:03:04 05:06:07",
                kCGImagePropertyExifFNumber as String: 1.78,
                kCGImagePropertyExifPixelXDimension as String: Self.sourceWidth,
                kCGImagePropertyExifPixelYDimension as String: Self.sourceHeight
            ] as [String: Any],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Apple",
                kCGImagePropertyTIFFModel as String: "iPhone 17 Pro",
                kCGImagePropertyTIFFSoftware as String: "17.4",
                kCGImagePropertyTIFFOrientation as String: 6
            ] as [String: Any],
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 37.7749,
                kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 122.4194,
                kCGImagePropertyGPSLongitudeRef as String: "W"
            ] as [String: Any],
            kCGImagePropertyMakerAppleDictionary as String: [
                "3": 12,
                "8": 1.0
            ] as [String: Any]
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: properties,
            format: .binary,
            options: 0
        )
    }

    // MARK: - Assertions

    private func assertExportedFile(at url: URL, format: ExportFormat) throws {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Missing export file for \(format.rawValue)"
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(fileSize, 0, "Empty export file for \(format.rawValue)")

        let imageSource = try XCTUnwrap(
            CGImageSourceCreateWithURL(url as CFURL, nil),
            "CGImageSource creation failed for \(format.rawValue)"
        )
        XCTAssertEqual(CGImageSourceGetCount(imageSource), 1)

        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
            "Missing properties for \(format.rawValue)"
        )
        XCTAssertEqual(
            properties[kCGImagePropertyPixelWidth as String] as? Int,
            Self.outputWidth,
            "Width mismatch for \(format.rawValue)"
        )
        XCTAssertEqual(
            properties[kCGImagePropertyPixelHeight as String] as? Int,
            Self.outputHeight,
            "Height mismatch for \(format.rawValue)"
        )
        XCTAssertEqual(
            properties[kCGImagePropertyOrientation as String] as? Int,
            1,
            "Orientation was not reset to 1 for \(format.rawValue)"
        )

        let decodedImage = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
            "Could not decode exported image for \(format.rawValue)"
        )
        XCTAssertEqual(decodedImage.width, Self.outputWidth)
        XCTAssertEqual(decodedImage.height, Self.outputHeight)

        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(
            tiff?[kCGImagePropertyTIFFMake as String] as? String,
            "Apple",
            "TIFF Make not preserved for \(format.rawValue)"
        )
        XCTAssertEqual(
            tiff?[kCGImagePropertyTIFFModel as String] as? String,
            "iPhone 17 Pro",
            "TIFF Model not preserved for \(format.rawValue)"
        )

        if format == .linearDNG16Bit {
            // The C bridge owns the fixed DNG IFD: arbitrary EXIF/GPS passthrough is not part of
            // its contract, but dimensions, depth, orientation and camera identity are.
            XCTAssertEqual(
                properties[kCGImagePropertyDepth as String] as? Int,
                16,
                "Linear DNG is not 16-bit"
            )
            XCTAssertEqual(
                tiff?[kCGImagePropertyTIFFOrientation as String] as? Int,
                1
            )
            return
        }

        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertEqual(
            exif?[kCGImagePropertyExifPixelXDimension as String] as? Int,
            Self.outputWidth,
            "EXIF PixelXDimension mismatch for \(format.rawValue)"
        )
        XCTAssertEqual(
            exif?[kCGImagePropertyExifPixelYDimension as String] as? Int,
            Self.outputHeight,
            "EXIF PixelYDimension mismatch for \(format.rawValue)"
        )
        XCTAssertEqual(
            exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int],
            [800],
            "EXIF ISO not preserved for \(format.rawValue)"
        )
        XCTAssertEqual(
            exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String,
            "2025:03:04 05:06:07",
            "EXIF DateTimeOriginal not preserved for \(format.rawValue)"
        )

        let userComment = userCommentString(from: exif)
        XCTAssertTrue(
            userComment.contains("UpscaledByApp=true"),
            "Missing UpscaledByApp tag for \(format.rawValue): \(userComment)"
        )
        XCTAssertTrue(
            userComment.contains("UpscaledFactor=4x"),
            "Missing UpscaledFactor tag for \(format.rawValue): \(userComment)"
        )
        XCTAssertTrue(
            userComment.contains("Denoised=true"),
            "Missing Denoised tag for \(format.rawValue): \(userComment)"
        )
        XCTAssertTrue(
            userComment.contains("Shot on iPhone 17 Pro"),
            "Pre-existing UserComment was discarded for \(format.rawValue): \(userComment)"
        )

        XCTAssertEqual(
            tiff?[kCGImagePropertyTIFFSoftware as String] as? String,
            MetadataReinjector.softwareTag,
            "TIFF Software mismatch for \(format.rawValue)"
        )
        XCTAssertEqual(
            tiff?[kCGImagePropertyTIFFOrientation as String] as? Int,
            1,
            "TIFF Orientation was not reset for \(format.rawValue)"
        )

        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        XCTAssertEqual(
            gps?[kCGImagePropertyGPSLatitude as String] as? Double ?? -1.0,
            37.7749,
            accuracy: 0.0001,
            "GPS latitude not preserved for \(format.rawValue)"
        )
        XCTAssertEqual(
            gps?[kCGImagePropertyGPSLongitudeRef as String] as? String,
            "W",
            "GPS longitude ref not preserved for \(format.rawValue)"
        )

        let makerApple = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
        XCTAssertEqual(
            makerApple?["3"] as? Int,
            12,
            "MakerApple dictionary not preserved for \(format.rawValue)"
        )

        switch format {
        case .png16Bit:
            XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, 16)
        case .tiff16BitLZW:
            XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, 16)
            XCTAssertEqual(
                tiff?[kCGImagePropertyTIFFCompression as String] as? Int,
                5,
                "TIFF is not LZW compressed"
            )
        case .heic10BitHDR:
            let depth = properties[kCGImagePropertyDepth as String] as? Int ?? 0
            XCTAssertGreaterThanOrEqual(depth, 10, "HEIC is not 10-bit")
        case .jpeg95:
            XCTAssertEqual(properties[kCGImagePropertyDepth as String] as? Int, 8)
        case .linearDNG16Bit, .autoMatchSource:
            break
        }
    }

    /// Decodes a suite-written rendered Linear DNG through the independent pure-Swift TIFF reader
    /// (Apple ImageIO does not open LinearRaw DNGs) and checks pixels + the headroom marker.
    private func assertSuiteLinearDNG(at url: URL) throws {
        let info = try XCTUnwrap(LinearDNGTIFFReader.probe(imageURL: url), "DNG probe failed")
        XCTAssertEqual(info.width, Self.outputWidth)
        XCTAssertEqual(info.height, Self.outputHeight)
        XCTAssertEqual(info.photometricInterpretation, 34892, "DNG is not LinearRaw")
        XCTAssertEqual(info.orientation, 1)
        XCTAssertEqual(info.bitsPerSample, [16, 16, 16])
        XCTAssertEqual(info.samplesPerPixel, 3)
        XCTAssertEqual(info.headroomScaleFromDescription ?? -1, 1.0, accuracy: 0.0001,
                       "SDR fixture must record HeadroomScale=1")
        XCTAssertEqual(info.baselineExposure ?? -1, 0.0, accuracy: 0.0001)
        XCTAssertTrue(info.software?.contains("ImagingSuite") ?? false)

        // Re-ingest through the app decoder: it must detect the suite LinearRaw marker and decode
        // through the independent TIFF reader instead of `CIRAWFilter`.
        let mmapURL = tempDirectory.appendingPathComponent("dng-\(UUID().uuidString).bin")
        let decoded = try UniversalStripDecoder.decodeToMMap(imageURL: url, destinationMMapURL: mmapURL)
        XCTAssertEqual(decoded.decodedWidth, Self.outputWidth)
        XCTAssertEqual(decoded.decodedHeight, Self.outputHeight)
        XCTAssertEqual(decoded.metadata.originalWidth, Self.outputWidth)
        XCTAssertEqual(decoded.metadata.originalHeight, Self.outputHeight)
        XCTAssertEqual(decoded.metadata.originalOrientation, 1)
        XCTAssertTrue(decoded.metadata.isLinearDNG)
        XCTAssertTrue(decoded.metadata.hasSuiteLinearDNGMarker)
        XCTAssertEqual(decoded.metadata.linearHeadroomScale ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertEqual(decoded.globalMaxLinearComponent, 1.0, accuracy: 0.002)
        let pixel = decoded.sourceBuffer.unsafePixelPointer(x: 20, y: 10)
        XCTAssertEqual(Float(pixel[0]), 20.0 / Float(Self.outputWidth - 1), accuracy: 0.003)
        XCTAssertEqual(Float(pixel[1]), 10.0 / Float(Self.outputHeight - 1), accuracy: 0.003)
        XCTAssertEqual(Float(pixel[2]), 0.5, accuracy: 0.003)
        XCTAssertEqual(Float(pixel[3]), 1.0, accuracy: 0.001)
    }

    /// Verifies that the streamed pixel data actually reaches the container: the synthetic output
    /// buffer holds R = x/(w-1), G = y/(h-1), B = 0.5 at full alpha. PNG/TIFF/JPEG are lossless or
    /// near-lossless in the linear Display P3 working space, so sampled pixels must match.
    private func assertPixelFidelity(at url: URL, format: ExportFormat) throws {
        switch format {
        case .linearDNG16Bit, .heic10BitHDR, .autoMatchSource:
            // DNG applies its own headroom mapping and HEIC 10-bit HDR applies tone mapping; both
            // are validated structurally by `assertExportedFile`.
            return
        case .png16Bit, .tiff16BitLZW, .jpeg95:
            break
        }

        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decodedImage = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        )
        let width = Self.outputWidth
        let height = Self.outputHeight
        let rowBytes = width * 16
        var buffer = [UInt8](repeating: 0, count: rowBytes * height)
        let colorSpace = try XCTUnwrap(
            CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        )
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
            ) else {
                return
            }
            context.interpolationQuality = .none
            context.draw(
                decodedImage,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            didDraw = true
        }
        try XCTSkipUnless(didDraw, "Float RGB CGContext unavailable on this host")

        let pixels = buffer.withUnsafeBytes { rawBuffer -> [Float] in
            let base = rawBuffer.baseAddress!.assumingMemoryBound(to: Float.self)
            return Array(UnsafeBufferPointer(start: base, count: width * height * 4))
        }

        let tolerance: Float = format == .jpeg95 ? 0.04 : 0.002
        let row = 10
        for x in [0, 32, width - 1] {
            let index = (row * width + x) * 4
            let expectedRed = Float(x) / Float(width - 1)
            XCTAssertEqual(
                pixels[index],
                expectedRed,
                accuracy: tolerance,
                "Red pixel mismatch at x=\(x) for \(format.rawValue)"
            )
            XCTAssertEqual(
                pixels[index + 2],
                0.5,
                accuracy: tolerance,
                "Blue pixel mismatch at x=\(x) for \(format.rawValue)"
            )
            XCTAssertEqual(
                pixels[index + 3],
                1.0,
                accuracy: 0.02,
                "Alpha pixel mismatch at x=\(x) for \(format.rawValue)"
            )
        }
    }

    private func userCommentString(from exif: [String: Any]?) -> String {
        guard let value = exif?[kCGImagePropertyExifUserComment as String] else { return "" }
        if let string = value as? String {
            return string
        }
        if let data = value as? Data {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return "\(value)"
    }

    // MARK: - Platform Helpers

    private static func hasHEICEncoder() -> Bool {
        let supported = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return supported.contains("public.heic") || supported.contains("public.heif")
    }

    private static func fileExtension(for format: ExportFormat) -> String {
        switch format {
        case .linearDNG16Bit, .autoMatchSource:
            return "dng"
        case .tiff16BitLZW:
            return "tiff"
        case .png16Bit:
            return "png"
        case .heic10BitHDR:
            return "heic"
        case .jpeg95:
            return "jpg"
        }
    }

    private static func sRGBICCProfileData() -> Data? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return colorSpace.copyICCData().map { $0 as Data }
    }
}
