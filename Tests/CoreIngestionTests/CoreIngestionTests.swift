import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import CoreIngestion
@testable import MMapCanvas
@testable import TruongScalerCore

final class CoreIngestionTests: XCTestCase {
    // MARK: - 16-bit PNG Strip Decoding

    func testStripDecodeSynthetic16BitPNGAndHDRHeadroom() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let width = 600
        let height = 700 // Two default 512-row strips.
        let imageURL = directory.appendingPathComponent("quadrants_16bit.png")
        try write16BitQuadrantPNG(to: imageURL, width: width, height: height)
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))

        // --- Metadata extraction (ImageIO properties, EXIF, ICC, plist payload). ---
        let metadata = try MetadataExtractor.extractMetadata(from: imageURL)
        XCTAssertEqual(metadata.sourceURL.standardizedFileURL, imageURL.standardizedFileURL)
        XCTAssertEqual(metadata.utTypeIdentifier, UTType.png.identifier)
        XCTAssertEqual(metadata.category, .standardOpaqueRaster)
        XCTAssertEqual(metadata.originalWidth, width)
        XCTAssertEqual(metadata.originalHeight, height)
        XCTAssertEqual(metadata.originalOrientation, 1)
        XCTAssertEqual(metadata.bitsPerComponent, 16)
        XCTAssertFalse(metadata.hasAlpha)
        XCTAssertEqual(metadata.isoSpeedRatings, 640)
        XCTAssertTrue(metadata.isAlreadyDenoisedBySuite, "EXIF UserComment ImagingSuite:Denoised=true marker")
        XCTAssertTrue(metadata.isAlreadyUpscaledBySuite, "TIFF Software UpscaledByApp/UpscaledFactor marker")
        XCTAssertFalse(metadata.isLinearDNG)
        XCTAssertNil(metadata.rawParameters)
        XCTAssertNil(metadata.hdrGainMapAuxiliaryData)
        XCTAssertNil(metadata.hdrGainMapWidth)
        XCTAssertNil(metadata.hdrGainMapHeight)
        XCTAssertNil(metadata.hdrGainMapMetadataPlist)
        XCTAssertNil(metadata.hdrGainMapAuxiliaryType)

        let iccProfileData = try XCTUnwrap(metadata.iccProfileData, "16-bit Display P3 Linear PNG must expose ICC")
        XCTAssertGreaterThan(iccProfileData.count, 100)

        let rawPropertiesData = try XCTUnwrap(metadata.rawPropertiesPlistData)
        let rawProperties = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: rawPropertiesData, options: [], format: nil)
                as? [String: Any]
        )
        XCTAssertEqual(integerValue(rawProperties[kCGImagePropertyPixelWidth as String]), width)
        XCTAssertEqual(integerValue(rawProperties[kCGImagePropertyPixelHeight as String]), height)
        XCTAssertEqual(integerValue(rawProperties[kCGImagePropertyDepth as String]), 16)
        let exif = try XCTUnwrap(rawProperties[kCGImagePropertyExifDictionary as String] as? [String: Any])
        let isoRatings = try XCTUnwrap(exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])
        XCTAssertEqual(isoRatings.first?.intValue, 640)
        XCTAssertEqual(
            exif[kCGImagePropertyExifUserComment as String] as? String,
            "ImagingSuite:Denoised=true"
        )

        // --- Strip decode into an RGBA16Float mmap. ---
        let destinationURL = directory.appendingPathComponent("source_rgba16f.bin")
        let recorder = ProgressRecorder()
        let decoded = try UniversalStripDecoder.decodeToMMap(
            imageURL: imageURL,
            destinationMMapURL: destinationURL,
            progressHandler: { value in recorder.record(value) }
        )
        let progress = recorder.snapshot()

        XCTAssertEqual(decoded.decodedWidth, width)
        XCTAssertEqual(decoded.decodedHeight, height)
        XCTAssertEqual(decoded.metadata.sourceURL.standardizedFileURL, metadata.sourceURL.standardizedFileURL)
        XCTAssertEqual(decoded.metadata.category, metadata.category)
        XCTAssertEqual(decoded.metadata.originalWidth, metadata.originalWidth)
        XCTAssertEqual(decoded.metadata.originalHeight, metadata.originalHeight)
        XCTAssertEqual(decoded.metadata.bitsPerComponent, metadata.bitsPerComponent)
        XCTAssertEqual(decoded.metadata.iccProfileData, metadata.iccProfileData)

        // The serialized binary plist uses ImageIO's (unordered) dictionary iteration, so compare the
        // decoded property-list *contents* rather than byte-for-byte Data.
        let decodedRawProperties = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: try XCTUnwrap(decoded.metadata.rawPropertiesPlistData),
                options: [],
                format: nil
            ) as? NSDictionary
        )
        XCTAssertTrue(decodedRawProperties.isEqual(rawProperties as NSDictionary))
        XCTAssertEqual(decoded.sourceBuffer.width, width)
        XCTAssertEqual(decoded.sourceBuffer.height, height)
        XCTAssertEqual(decoded.sourceBuffer.bytesPerPixel, 8)
        XCTAssertEqual(
            decoded.sourceBuffer.rowBytes,
            HardwareTelemetry.alignedRowBytes(width: width, bytesPerPixel: 8)
        )
        XCTAssertEqual(decoded.sourceBuffer.fileURL.standardizedFileURL, destinationURL.standardizedFileURL)
        XCTAssertTrue(decoded.globalMaxLuminance.isFinite)
        XCTAssertEqual(decoded.globalMaxLuminance, 1.0, accuracy: 1e-6, "SDR source clamps headroom to at least 1.0")

        // Two 512-row strips for a 700-row image, with monotonically increasing 0...1 progress.
        XCTAssertEqual(progress.count, 2)
        XCTAssertEqual(progress[0], 512.0 / 700.0, accuracy: 1e-9)
        XCTAssertEqual(progress[1], 1.0, accuracy: 1e-9)

        // --- Pixel fidelity read back from the mmap. ---
        let topLeft = rgba(from: decoded.sourceBuffer, x: 10, y: 10)
        XCTAssertEqual(topLeft.r, 0.80, accuracy: 0.02)
        XCTAssertEqual(topLeft.g, 0.10, accuracy: 0.02)
        XCTAssertEqual(topLeft.b, 0.10, accuracy: 0.02)
        XCTAssertEqual(topLeft.a, 1.0, accuracy: 0.001)

        let topRight = rgba(from: decoded.sourceBuffer, x: width - 11, y: 10)
        XCTAssertEqual(topRight.r, 0.10, accuracy: 0.02)
        XCTAssertEqual(topRight.g, 0.80, accuracy: 0.02)
        XCTAssertEqual(topRight.b, 0.10, accuracy: 0.02)

        let bottomLeft = rgba(from: decoded.sourceBuffer, x: 10, y: height - 11)
        XCTAssertEqual(bottomLeft.r, 0.10, accuracy: 0.02)
        XCTAssertEqual(bottomLeft.g, 0.10, accuracy: 0.02)
        XCTAssertEqual(bottomLeft.b, 0.80, accuracy: 0.02)

        let bottomRight = rgba(from: decoded.sourceBuffer, x: width - 11, y: height - 11)
        XCTAssertEqual(bottomRight.r, 0.75, accuracy: 0.02)
        XCTAssertEqual(bottomRight.g, 0.75, accuracy: 0.02)
        XCTAssertEqual(bottomRight.b, 0.75, accuracy: 0.02)

        // The top-down raster must not be vertically inverted: top row is red-dominant, bottom row is
        // blue-dominant, and the white bottom-right quadrant belongs to the *second* strip.
        XCTAssertGreaterThan(topLeft.r, topLeft.b + 0.5)
        XCTAssertGreaterThan(bottomLeft.b, bottomLeft.r + 0.5)
        XCTAssertGreaterThan(bottomRight.r, 0.6)

        // The data must be durable in the destination file, not merely resident in the first mapping.
        let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
        XCTAssertEqual(
            (attributes[.size] as? NSNumber)?.intValue,
            decoded.sourceBuffer.totalByteSize
        )
        let reopened = try MMapBuffer(
            fileURL: destinationURL,
            width: width,
            height: height,
            createIfMissing: false
        )
        let persistedTopLeft = rgba(from: reopened, x: 10, y: 10)
        XCTAssertEqual(persistedTopLeft.r, topLeft.r, accuracy: 0.001)
        XCTAssertEqual(persistedTopLeft.g, topLeft.g, accuracy: 0.001)
        XCTAssertEqual(persistedTopLeft.b, topLeft.b, accuracy: 0.001)
    }

    // MARK: - HDR Headroom Scan

    func testGlobalMaxLuminanceScansHDRFloatTIFF() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let width = 64
        let height = 48
        let imageURL = directory.appendingPathComponent("hdr_float.tiff")
        try writeHDRFloatTIFF(to: imageURL, width: width, height: height)

        let metadata = try MetadataExtractor.extractMetadata(from: imageURL)
        XCTAssertEqual(metadata.category, .standardAlphaRaster)
        XCTAssertEqual(metadata.bitsPerComponent, 16)
        XCTAssertTrue(metadata.hasAlpha)
        XCTAssertEqual(metadata.originalWidth, width)
        XCTAssertEqual(metadata.originalHeight, height)

        let destinationURL = directory.appendingPathComponent("hdr_source_rgba16f.bin")
        let recorder = ProgressRecorder()
        let decoded = try UniversalStripDecoder.decodeToMMap(
            imageURL: imageURL,
            destinationMMapURL: destinationURL,
            stripHeight: 16,
            progressHandler: { value in recorder.record(value) }
        )

        XCTAssertEqual(decoded.decodedWidth, width)
        XCTAssertEqual(decoded.decodedHeight, height)

        // The top-left quadrant contains a 4.0 extended-linear white; headroom must reflect it.
        let hdrPixel = rgba(from: decoded.sourceBuffer, x: 4, y: 4)
        XCTAssertEqual(hdrPixel.r, 4.0, accuracy: 0.01)
        XCTAssertEqual(hdrPixel.g, 4.0, accuracy: 0.01)
        XCTAssertEqual(hdrPixel.b, 4.0, accuracy: 0.01)
        XCTAssertEqual(decoded.globalMaxLuminance, 4.0, accuracy: 0.01)

        let sdrPixel = rgba(from: decoded.sourceBuffer, x: width - 5, y: height - 5)
        XCTAssertEqual(sdrPixel.r, 0.5, accuracy: 0.01)
        XCTAssertEqual(sdrPixel.g, 0.5, accuracy: 0.01)
        XCTAssertEqual(sdrPixel.b, 0.5, accuracy: 0.01)

        let progress = recorder.snapshot()
        XCTAssertEqual(progress.count, 3)
        XCTAssertEqual(progress[0], 16.0 / 48.0, accuracy: 1e-9)
        XCTAssertEqual(progress[1], 32.0 / 48.0, accuracy: 1e-9)
        XCTAssertEqual(progress[2], 1.0, accuracy: 1e-9)
    }

    // MARK: - EXIF Orientation Baking + Cross-App Markers

    func testNativeGainMapGateRefusesSDRGraphsAndPreservesOrdinaryRasterInputs() throws {
        for headroom in [Float(0), 1, .nan, .infinity] {
            XCTAssertThrowsError(try UniversalStripDecoder.validateNativeGainMapExpansion(
                hasGainMap: true, contentHeadroom: headroom
            )) { XCTAssertEqual($0 as? ScalerError, .hdrGainMapExpansionUnavailable) }
        }
        XCTAssertNoThrow(try UniversalStripDecoder.validateNativeGainMapExpansion(hasGainMap: true, contentHeadroom: 4))
        XCTAssertNoThrow(try UniversalStripDecoder.validateNativeGainMapExpansion(hasGainMap: false, contentHeadroom: 1))
        XCTAssertNoThrow(try UniversalStripDecoder.validateNativeGainMapExpansion(hasGainMap: false, contentHeadroom: 0))
    }

    func testGainMapJPEGPreservesHDRorRefusesUnsupportedNativeExpansionBeforeWriting() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let linearP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let outputP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let sdrColor = try XCTUnwrap(CIColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1, colorSpace: linearP3))
        let hdrColor = try XCTUnwrap(CIColor(red: 4, green: 4, blue: 4, alpha: 1, colorSpace: linearP3))
        let sdrImage = CIImage(color: sdrColor).cropped(to: extent)
        let hdrImage = CIImage(color: hdrColor).cropped(to: extent).settingContentHeadroom(4)
        let context = CIContext(options: [.workingColorSpace: linearP3])
        let imageURL = directory.appendingPathComponent("gainmap.jpg")
        try context.writeJPEGRepresentation(of: sdrImage, to: imageURL, colorSpace: outputP3, options: [.hdrImage: hdrImage])
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(imageURL as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap))
        let metadata = try MetadataExtractor.extractMetadata(from: imageURL)
        XCTAssertNotNil(metadata.hdrGainMapAuxiliaryData)
        XCTAssertEqual(metadata.hdrGainMapAuxiliaryType, .isoGainMap)
        let native = try XCTUnwrap(CIImage(contentsOf: imageURL,
            options: [.expandToHDR: true, .toneMapHDRtoSDR: false]))
        let originalBytes = try Data(contentsOf: imageURL)
        let destination = directory.appendingPathComponent("hdr.bin")
        let missingDestination = directory.appendingPathComponent("missing.bin")
        let sentinel = Data(repeating: 0xB7, count: 128)
        try sentinel.write(to: destination)
        if !native.contentHeadroom.isFinite || native.contentHeadroom <= 1 {
            // Unsupported native expansion is an exercised refusal, never an SDR success or a skip.
            for target in [destination, missingDestination] {
                XCTAssertThrowsError(try UniversalStripDecoder.decodeToMMap(
                    imageURL: imageURL, destinationMMapURL: target, stripHeight: 17
                )) { XCTAssertEqual($0 as? ScalerError, .hdrGainMapExpansionUnavailable) }
            }
            XCTAssertEqual(try Data(contentsOf: destination), sentinel)
            XCTAssertFalse(FileManager.default.fileExists(atPath: missingDestination.path))
            XCTAssertEqual(try Data(contentsOf: imageURL), originalBytes)
            print("GAINMAP_NATIVE_EXPANSION=REFUSED_BEFORE_WRITE headroom=\(native.contentHeadroom)")
        } else {
            let decoded = try UniversalStripDecoder.decodeToMMap(
                imageURL: imageURL, destinationMMapURL: destination, stripHeight: 17
            )
            XCTAssertEqual(decoded.globalMaxLuminance, 4, accuracy: 0.15)
            let pixel = rgba(from: decoded.sourceBuffer, x: 30, y: 30)
            XCTAssertEqual(pixel.r, 4, accuracy: 0.15)
            XCTAssertEqual(pixel.g, 4, accuracy: 0.15)
            XCTAssertEqual(pixel.b, 4, accuracy: 0.15)
            XCTAssertEqual(try Data(contentsOf: imageURL), originalBytes)
            print("GAINMAP_NATIVE_EXPANSION=HDR_VERIFIED peak=\(decoded.globalMaxLuminance)")
        }
    }

    func testGainMapAuxiliaryTypeDistinctionLegacyVsISO() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let linearP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let outputP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let sdrColor = try XCTUnwrap(CIColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1, colorSpace: linearP3))
        let hdrColor = try XCTUnwrap(CIColor(red: 4, green: 4, blue: 4, alpha: 1, colorSpace: linearP3))
        let sdrImage = CIImage(color: sdrColor).cropped(to: extent)
        let hdrImage = CIImage(color: hdrColor).cropped(to: extent).settingContentHeadroom(4)
        let context = CIContext(options: [.workingColorSpace: linearP3])
        let isoURL = directory.appendingPathComponent("iso_gainmap.jpg")
        try context.writeJPEGRepresentation(
            of: sdrImage,
            to: isoURL,
            colorSpace: outputP3,
            options: [.hdrImage: hdrImage]
        )

        let isoMetadata = try MetadataExtractor.extractMetadata(from: isoURL)
        XCTAssertEqual(isoMetadata.hdrGainMapAuxiliaryType, .isoGainMap)
        XCTAssertNotNil(isoMetadata.hdrGainMapAuxiliaryData)
        XCTAssertNotNil(isoMetadata.hdrGainMapWidth)
        XCTAssertNotNil(isoMetadata.hdrGainMapHeight)

        // Re-attach the same auxiliary payload under the legacy HDRGainMap key. ImageIO exposes
        // it as the legacy type, so the packet must distinguish it from ISO gain maps.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(isoURL as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let payload = try XCTUnwrap(CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source,
            0,
            kCGImageAuxiliaryDataTypeISOGainMap
        ))
        let legacyURL = directory.appendingPathComponent("legacy_gainmap.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            legacyURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddAuxiliaryDataInfo(destination, kCGImageAuxiliaryDataTypeHDRGainMap, payload)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let legacyMetadata = try MetadataExtractor.extractMetadata(from: legacyURL)
        XCTAssertEqual(legacyMetadata.hdrGainMapAuxiliaryType, .legacyHDRGainMap)
        XCTAssertNotNil(legacyMetadata.hdrGainMapAuxiliaryData, "legacy gain-map payload is preserved")
        XCTAssertNotEqual(legacyMetadata.hdrGainMapAuxiliaryType, isoMetadata.hdrGainMapAuxiliaryType)
    }

    func testDecodeBakesEXIFOrientationAndExtractsSuiteMarkers() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceWidth = 40
        let sourceHeight = 30
        let imageURL = directory.appendingPathComponent("orientation6.png")
        try writeOrientedPNG(to: imageURL, width: sourceWidth, height: sourceHeight, orientation: 6)

        let metadata = try MetadataExtractor.extractMetadata(from: imageURL)
        XCTAssertEqual(metadata.originalOrientation, 6)
        // 90° rotation (EXIF 6) swaps the reported display dimensions.
        XCTAssertEqual(metadata.originalWidth, sourceHeight)
        XCTAssertEqual(metadata.originalHeight, sourceWidth)
        XCTAssertEqual(metadata.isoSpeedRatings, 800)
        XCTAssertTrue(metadata.isAlreadyDenoisedBySuite)
        XCTAssertTrue(metadata.isAlreadyUpscaledBySuite)

        let destinationURL = directory.appendingPathComponent("rotated_rgba16f.bin")
        let recorder = ProgressRecorder()
        let decoded = try UniversalStripDecoder.decodeToMMap(
            imageURL: imageURL,
            destinationMMapURL: destinationURL,
            stripHeight: 16,
            progressHandler: { value in recorder.record(value) }
        )

        XCTAssertEqual(decoded.decodedWidth, sourceHeight)
        XCTAssertEqual(decoded.decodedHeight, sourceWidth)
        XCTAssertEqual(recorder.snapshot(), [16.0 / 40.0, 32.0 / 40.0, 1.0])

        // The source's left half is red and right half is blue. Orientation 6 rotates 90° clockwise, so the
        // output's top half must be red and bottom half blue (proving orientation was baked, not ignored).
        let topPixel = rgba(from: decoded.sourceBuffer, x: 5, y: 5)
        let bottomPixel = rgba(from: decoded.sourceBuffer, x: 5, y: sourceWidth - 5)
        XCTAssertGreaterThan(topPixel.r, 0.30)
        XCTAssertLessThan(topPixel.b, 0.10)
        XCTAssertGreaterThan(bottomPixel.b, 0.30)
        XCTAssertLessThan(bottomPixel.r, 0.10)
    }

    // MARK: - Failure Modes

    func testDecodeRejectsDestinationAliasingSourceWithoutChangingOriginal() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageURL = directory.appendingPathComponent("original.png")
        try write16BitQuadrantPNG(to: imageURL, width: 16, height: 12)
        let originalData = try Data(contentsOf: imageURL)
        let symlinkURL = directory.appendingPathComponent("symlink.bin")
        let hardlinkURL = directory.appendingPathComponent("hardlink.bin")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: imageURL)
        try FileManager.default.linkItem(at: imageURL, to: hardlinkURL)

        for destinationURL in [imageURL, symlinkURL, hardlinkURL] {
            XCTAssertThrowsError(try UniversalStripDecoder.decodeToMMap(
                imageURL: imageURL, destinationMMapURL: destinationURL
            )) { error in
                guard case ScalerError.stripDecodingFailed = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: imageURL), originalData)
        }
    }

    func testStructuredXMPPipelineMarkersRespectTheirValues() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixtureURL = directory.appendingPathComponent("fixture.png")
        try write16BitQuadrantPNG(to: fixtureURL, width: 8, height: 8)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(fixtureURL as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        for value in ["true", "false"] {
            let metadata = CGImageMetadataCreateMutable()
            XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(
                metadata,
                "https://truongimaging.example/pipeline/1.0/" as CFString,
                "ImagingSuite" as CFString,
                nil
            ))
            for name in ["Denoised", "Upscaled"] {
                XCTAssertTrue(CGImageMetadataSetValueWithPath(
                    metadata,
                    nil,
                    "ImagingSuite:\(name)" as CFString,
                    value as CFString
                ))
            }
            let imageURL = directory.appendingPathComponent("xmp_\(value).png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
                imageURL as CFURL, UTType.png.identifier as CFString, 1, nil
            ))
            // Only the custom XMP is written; the fixture's EXIF/TIFF markers are deliberately omitted.
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))

            let extracted = try MetadataExtractor.extractMetadata(from: imageURL)
            XCTAssertEqual(extracted.isAlreadyDenoisedBySuite, value == "true")
            XCTAssertEqual(extracted.isAlreadyUpscaledBySuite, value == "true")
        }
    }

    func testMissingAndCorruptSourcesThrowScalerErrors() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let missingURL = directory.appendingPathComponent("does_not_exist.png")
        XCTAssertThrowsError(try MetadataExtractor.extractMetadata(from: missingURL)) { error in
            XCTAssertEqual(error as? ScalerError, .fileNotFound(missingURL))
        }
        XCTAssertThrowsError(
            try UniversalStripDecoder.decodeToMMap(
                imageURL: missingURL,
                destinationMMapURL: directory.appendingPathComponent("missing_rgba16f.bin")
            )
        ) { error in
            XCTAssertEqual(error as? ScalerError, .fileNotFound(missingURL))
        }

        let corruptURL = directory.appendingPathComponent("corrupt.png")
        try Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05]).write(to: corruptURL)
        XCTAssertThrowsError(try MetadataExtractor.extractMetadata(from: corruptURL)) { error in
            XCTAssertEqual(error as? ScalerError, .metadataExtractionFailed)
        }
        XCTAssertThrowsError(
            try UniversalStripDecoder.decodeToMMap(
                imageURL: corruptURL,
                destinationMMapURL: directory.appendingPathComponent("corrupt_rgba16f.bin")
            )
        ) { error in
            XCTAssertEqual(error as? ScalerError, .metadataExtractionFailed)
        }
    }


    // MARK: - Suite rendered Linear DNG re-ingest

    func testSuiteLinearDNGReingestRestoresHDRDimensionsAndPipelineFlags() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for denoised in [false, true] {
            let imageURL = directory.appendingPathComponent("suite_linear_\(denoised).dng")
            let description = "TruongScaler Linear DNG; WorkingSpace=LinearDisplayP3; HeadroomScale=4; HeadroomEV=2; "
                + "UpscaledByApp=true; UpscaledFactor=4x; Denoised=\(denoised); NoiserDenoised=true"
            let data = try makeSuiteLinearDNGData(
                width: 32,
                height: 8,
                rowsPerStrip: 4,
                headroomScale: 4,
                imageDescription: description,
                software: "TruongScaler 1.0 (ImagingSuite)"
            ) { x, y in
                if y < 2 { return (4, 4, 4) }              // saturated HDR white (luminance peak)
                if y < 4 { return (4, 0, 0) }              // saturated HDR red (component peak)
                if y < 6 { return (1, 1, 1) }
                return (0.5, 0.5, 0.5)
            }
            try data.write(to: imageURL)
            let originalBytes = try Data(contentsOf: imageURL)

            let metadata = try MetadataExtractor.extractMetadata(from: imageURL)
            XCTAssertTrue(metadata.isLinearDNG)
            XCTAssertTrue(metadata.hasSuiteLinearDNGMarker)
            XCTAssertEqual(metadata.category, .cameraRAW)
            XCTAssertEqual(metadata.originalWidth, 32)
            XCTAssertEqual(metadata.originalHeight, 8)
            XCTAssertEqual(metadata.originalOrientation, 1)
            XCTAssertEqual(metadata.bitsPerComponent, 16)
            XCTAssertEqual(metadata.linearHeadroomScale ?? 0, 4.0, accuracy: 1e-4)
            XCTAssertEqual(metadata.isAlreadyDenoisedBySuite, denoised)
            XCTAssertTrue(metadata.isAlreadyUpscaledBySuite)
            XCTAssertEqual(metadata.upscaledByAppFactor, 4)
            XCTAssertTrue(metadata.isAlreadyDenoisedByNoiser)
            XCTAssertEqual(metadata.hdrGainMapAuxiliaryType, nil)

            let destinationURL = directory.appendingPathComponent("suite_\(denoised)_rgba16f.bin")
            let recorder = ProgressRecorder()
            let decoded = try UniversalStripDecoder.decodeToMMap(
                imageURL: imageURL,
                destinationMMapURL: destinationURL,
                stripHeight: 2,
                progressHandler: { recorder.record($0) }
            )
            XCTAssertEqual(decoded.decodedWidth, 32)
            XCTAssertEqual(decoded.decodedHeight, 8)
            XCTAssertEqual(decoded.metadata.hasSuiteLinearDNGMarker, true)
            XCTAssertEqual(decoded.globalMaxLinearComponent, 4.0, accuracy: 1e-4)
            XCTAssertEqual(decoded.globalMaxLuminance, 4.0, accuracy: 1e-4)
            // H = 2^BaselineExposure = 4 restores the > 1.0 HDR samples.
            let hdrWhite = rgba(from: decoded.sourceBuffer, x: 10, y: 0)
            XCTAssertEqual(hdrWhite.r, 4.0, accuracy: 0.001)
            XCTAssertEqual(hdrWhite.g, 4.0, accuracy: 0.001)
            XCTAssertEqual(hdrWhite.a, 1.0, accuracy: 0.001)
            let hdrRed = rgba(from: decoded.sourceBuffer, x: 10, y: 2)
            XCTAssertEqual(hdrRed.r, 4.0, accuracy: 0.001)
            XCTAssertEqual(hdrRed.g, 0, accuracy: 0.001)
            let one = rgba(from: decoded.sourceBuffer, x: 10, y: 4)
            XCTAssertEqual(one.r, 1.0, accuracy: 0.001)
            let half = rgba(from: decoded.sourceBuffer, x: 10, y: 6)
            XCTAssertEqual(half.r, 0.5, accuracy: 0.001)
            XCTAssertFalse(recorder.snapshot().isEmpty)

            // Re-read through the independent reader directly (test proves the suite path, not ImageIO).
            let directURL = directory.appendingPathComponent("suite_\(denoised)_direct.bin")
            let direct = try LinearDNGTIFFReader.decode(imageURL: imageURL, destinationMMapURL: directURL)
            XCTAssertEqual(direct.headroomScale, 4.0, accuracy: 1e-4)
            XCTAssertEqual(direct.stripCount, 2)
            XCTAssertEqual(direct.globalMaxLinearComponent, 4.0, accuracy: 1e-4)

            // No sidecar expansion / source mutation.
            XCTAssertEqual(try Data(contentsOf: imageURL), originalBytes)
            let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertFalse(contents.contains { $0.lowercased().hasSuffix(".xmp") })
            XCTAssertFalse(contents.contains { $0.contains("_rgba16f.bin.tmp") })
        }
    }

    func testSuiteLinearDNGRejectsTruncatedAndMalformedInput() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let description = "TruongScaler Linear DNG; WorkingSpace=LinearDisplayP3; HeadroomScale=4; HeadroomEV=2; "
            + "UpscaledByApp=true; UpscaledFactor=4x; Denoised=false; NoiserDenoised=false"
        let validData = try makeSuiteLinearDNGData(
            width: 16,
            height: 8,
            rowsPerStrip: 8,
            headroomScale: 4,
            imageDescription: description,
            software: "TruongScaler 1.0 (ImagingSuite)"
        ) { _, _ in (1, 1, 1) }

        let sourceURL = directory.appendingPathComponent("valid.dng")
        try validData.write(to: sourceURL)
        let originalBytes = try Data(contentsOf: sourceURL)

        // Truncated strip payload: header intact but the strip table runs past EOF.
        let truncatedURL = directory.appendingPathComponent("truncated.dng")
        try validData.dropLast(64).write(to: truncatedURL)
        let destinationURL = directory.appendingPathComponent("truncated_rgba16f.bin")
        XCTAssertThrowsError(try LinearDNGTIFFReader.decode(
            imageURL: truncatedURL,
            destinationMMapURL: destinationURL
        )) { error in
            guard case ScalerError.stripDecodingFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path), "No partial destination is left behind")

        XCTAssertThrowsError(try UniversalStripDecoder.decodeToMMap(
            imageURL: truncatedURL,
            destinationMMapURL: directory.appendingPathComponent("truncated_pipeline.bin")
        )) { error in
            guard case ScalerError.stripDecodingFailed = error else {
                return XCTFail("Unexpected pipeline error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: truncatedURL), validData.dropLast(64))
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(Set(contents), Set(["valid.dng", "truncated.dng"]), "No sidecars or leftover destinations: \(contents)")

        // Wrong photometric interpretation (RGB instead of LinearRaw) is rejected by the reader.
        let wrongPhotometric = try makeSuiteLinearDNGData(
            width: 16,
            height: 8,
            rowsPerStrip: 8,
            headroomScale: 4,
            imageDescription: description,
            software: "TruongScaler 1.0 (ImagingSuite)",
            photometricInterpretation: 2
        ) { _, _ in (1, 1, 1) }
        let wrongURL = directory.appendingPathComponent("wrong_photometric.dng")
        try wrongPhotometric.write(to: wrongURL)
        let info = try XCTUnwrap(LinearDNGTIFFReader.probe(imageURL: wrongURL))
        XCTAssertEqual(info.photometricInterpretation, 2)
        XCTAssertThrowsError(try LinearDNGTIFFReader.decode(
            imageURL: wrongURL,
            destinationMMapURL: directory.appendingPathComponent("wrong.bin")
        )) { error in
            XCTAssertEqual(error as? ScalerError, .metadataExtractionFailed)
        }

        // BigTIFF / big-endian / corrupt magic is not this reader's subset.
        let corruptURL = directory.appendingPathComponent("corrupt.dng")
        try Data([0x4D, 0x4D, 0x00, 0x2B, 0x00, 0x00, 0x00, 0x08]).write(to: corruptURL)
        XCTAssertThrowsError(try LinearDNGTIFFReader.decode(
            imageURL: corruptURL,
            destinationMMapURL: directory.appendingPathComponent("corrupt.bin")
        )) { error in
            XCTAssertEqual(error as? ScalerError, .metadataExtractionFailed)
        }
        // ImageIO also cannot extract a corrupt source, so the app-facing extractor still fails.
        XCTAssertThrowsError(try MetadataExtractor.extractMetadata(from: corruptURL))

        // Destination aliasing the DNG source is rejected before any write.
        XCTAssertThrowsError(try LinearDNGTIFFReader.decode(
            imageURL: sourceURL,
            destinationMMapURL: sourceURL
        )) { error in
            guard case ScalerError.stripDecodingFailed = error else {
                return XCTFail("Unexpected alias error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
    }

    func testMalformedPresentDNGSampleTagsRejectBeforeChangingDestination() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let description = "TruongScaler Linear DNG; WorkingSpace=LinearDisplayP3; HeadroomScale=1"
        let sdr = try makeSuiteLinearDNGData(
            width: 8, height: 4, rowsPerStrip: 2, headroomScale: 1,
            imageDescription: description, software: "TruongScaler", legacyIntegerEncoding: false
        ) { _, _ in (0.5, 0.25, 0.125) }
        let hdr = try makeSuiteFloatDNGData(
            width: 8, height: 4, rowsPerStrip: 2, hintMaxOutputValue: 4,
            imageDescription: description, software: "TruongScaler"
        ) { _, _ in (4, 0.5, 0.25) }
        let mutations: [(name: String, type: UInt16?, count: UInt32?, offset: UInt32?)] = [
            ("wrong-type", 1, nil, nil),
            ("empty", nil, 0, nil),
            ("outside-file", nil, nil, UInt32.max),
        ]
        let sentinel = Data(repeating: 0xA7, count: 4096)
        let sampleTags: [UInt16] = [258, 339]

        for (kind, valid) in [("sdr", sdr), ("hdr", hdr)] {
            for tag in sampleTags {
                for mutation in mutations {
                    let name = "\(kind)-\(tag)-\(mutation.name)"
                    let malformed = try patchingSampleTag(
                        valid, tag: tag, type: mutation.type, count: mutation.count,
                        valueOrOffset: mutation.offset
                    )
                    let source = directory.appendingPathComponent("\(name).dng")
                    let destination = directory.appendingPathComponent("\(name).bin")
                    let missingDestination = directory.appendingPathComponent("\(name)-missing.bin")
                    try malformed.write(to: source)
                    try sentinel.write(to: destination)

                    XCTAssertThrowsError(try LinearDNGTIFFReader.decode(
                        imageURL: source, destinationMMapURL: destination
                    ), name) { error in
                        XCTAssertEqual(error as? ScalerError, .metadataExtractionFailed, name)
                    }
                    XCTAssertEqual(try Data(contentsOf: destination), sentinel, name)
                    XCTAssertThrowsError(try UniversalStripDecoder.decodeToMMap(
                        imageURL: source, destinationMMapURL: destination
                    ), name)
                    XCTAssertEqual(try Data(contentsOf: destination), sentinel, name)
                    XCTAssertThrowsError(try LinearDNGTIFFReader.decode(
                        imageURL: source, destinationMMapURL: missingDestination
                    ), name)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: missingDestination.path), name)
                    XCTAssertEqual(try Data(contentsOf: source), malformed, name)
                }
            }
        }
    }

    func testAbsentDNGSampleTagsPreserveLegacyDefaults() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = try makeSuiteLinearDNGData(
            width: 8, height: 4, rowsPerStrip: 2, headroomScale: 1,
            imageDescription: "TruongScaler Linear DNG; HeadroomScale=1",
            software: "TruongScaler", legacyIntegerEncoding: false
        ) { _, _ in (0.5, 0.25, 0.125) }

        let absentTagCases: [[UInt16]] = [[258], [339], [258, 339]]
        for absentTags in absentTagCases {
            // Rename only the selected entry IDs to unknown private tags. All payload bytes,
            // offsets and dimensions remain identical to the independent valid fixture.
            var data = valid
            for tag in absentTags {
                data = try patchingSampleTag(data, tag: tag, replacementTag: tag + 50_000)
            }
            let label = absentTags.map { String($0) }.joined(separator: "-")
            let source = directory.appendingPathComponent("absent-\(label).dng")
            let destination = directory.appendingPathComponent("absent-\(label).bin")
            try data.write(to: source)
            let decoded = try LinearDNGTIFFReader.decode(imageURL: source, destinationMMapURL: destination)
            XCTAssertEqual(decoded.sampleFormat, 1)
            XCTAssertFalse(decoded.isFloat)
            let canvas = try MMapBuffer(fileURL: destination, width: 8, height: 4, createIfMissing: false)
            let pixel = rgba(from: canvas, x: 3, y: 2)
            XCTAssertEqual(pixel.r, 0.5, accuracy: 0.001)
            XCTAssertEqual(pixel.g, 0.25, accuracy: 0.001)
            XCTAssertEqual(pixel.b, 0.125, accuracy: 0.001)
            XCTAssertEqual(try Data(contentsOf: source), data)
        }
    }

    func testStructuredXMPFalsePipelineFlagsDoNotInheritStaleTrue() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtureURL = directory.appendingPathComponent("false_flags.png")
        try write16BitQuadrantPNG(to: fixtureURL, width: 8, height: 8)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(fixtureURL as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let metadata = CGImageMetadataCreateMutable()
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(
            metadata,
            "https://truongimaging.example/pipeline/1.0/" as CFString,
            "ImagingSuite" as CFString,
            nil
        ))
        // Explicit false must win even when an EXIF UserComment says true.
        CGImageMetadataSetValueWithPath(metadata, nil, "ImagingSuite:Denoised" as CFString, "false" as CFString)
        CGImageMetadataSetValueWithPath(metadata, nil, "ImagingSuite:UpscaledByApp" as CFString, "false" as CFString)
        CGImageMetadataSetValueWithPath(metadata, nil, "ImagingSuite:UpscaledFactor" as CFString, "4x" as CFString)
        CGImageMetadataSetValueWithPath(metadata, nil, "ImagingSuite:NoiserDenoised" as CFString, "true" as CFString)
        let imageURL = directory.appendingPathComponent("false_flags_written.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            imageURL as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let extracted = try MetadataExtractor.extractMetadata(from: imageURL)
        XCTAssertFalse(extracted.isAlreadyDenoisedBySuite, "Denoised=false must not be treated as denoised")
        XCTAssertFalse(extracted.isAlreadyUpscaledBySuite, "explicit UpscaledByApp=false wins over factor text")
        XCTAssertEqual(extracted.upscaledByAppFactor, 4)
        XCTAssertTrue(extracted.isAlreadyDenoisedByNoiser)
        XCTAssertNil(extracted.linearHeadroomScale)
    }

    // MARK: - R3 hostile geometry regressions

    /// The review's suite-marked DNG declares UInt32.max width/height/RowsPerStrip with one
    /// tiny strip. It must throw, not trap, leave a pre-existing destination byte-identical,
    /// and create no large file.
    func testOverflowDimensionsFixtureThrowsAndLeavesDestinationUnchanged() throws {
        let fixture = fixturesDirectory().appendingPathComponent("overflow-dimensions.dng")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path), "fixture missing at \(fixture.path)")
        let fixtureSize = try Data(contentsOf: fixture).count
        XCTAssertLessThan(fixtureSize, 1_000_000, "review fixture is small; no huge test allocation")

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("preexisting.bin")
        let sentinel = Data(repeating: 0xAB, count: 4096)
        try sentinel.write(to: destination)
        let directoryBytesBefore = directoryByteSize(directory)

        // The probe is non-throwing and reports the hostile dimensions without allocating.
        let info = try XCTUnwrap(LinearDNGTIFFReader.probe(imageURL: fixture))
        XCTAssertEqual(info.width, Int(UInt32.max))
        XCTAssertEqual(info.height, Int(UInt32.max))

        XCTAssertThrowsError(try LinearDNGTIFFReader.decode(
            imageURL: fixture,
            destinationMMapURL: destination
        )) { error in
            switch error {
            case ScalerError.metadataExtractionFailed, ScalerError.stripDecodingFailed:
                break
            default:
                XCTFail("Unexpected hostile-geometry error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: destination), sentinel, "pre-existing destination was modified")
        XCTAssertEqual(directoryByteSize(directory), directoryBytesBefore, "decode grew the directory")
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(contents, ["preexisting.bin"], "no partial destination was created: \(contents)")

        // The production ingestion route reaches the same checked reader.
        let pipelineDestination = directory.appendingPathComponent("pipeline.bin")
        XCTAssertThrowsError(try UniversalStripDecoder.decodeToMMap(
            imageURL: fixture,
            destinationMMapURL: pipelineDestination
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pipelineDestination.path))
    }

    /// Boundary width/height/RowsPerStrip and truncation cases built from a valid fixture.
    /// All reject from file-size-derived bounds before mmap/allocation.
    func testHostileBoundaryGeometryAndTruncationThrowWithoutDestinationChanges() throws {
        let description = "TruongScaler Linear DNG; WorkingSpace=LinearDisplayP3; HeadroomScale=1; HeadroomEV=0; "
            + "UpscaledByApp=false; UpscaledFactor=1x; Denoised=false; NoiserDenoised=false"
        let valid = try makeSuiteLinearDNGData(
            width: 16,
            height: 8,
            rowsPerStrip: 8,
            headroomScale: 1,
            imageDescription: description,
            software: "TruongScaler 1.0 (ImagingSuite)",
            legacyIntegerEncoding: false
        ) { _, _ in (1, 1, 1) }

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("preexisting.bin")
        let sentinel = Data(repeating: 0x5A, count: 1024)
        try sentinel.write(to: destination)

        let cases: [(String, Data)] = [
            ("width_max", try patchingUInt32Tag(valid, tag: 256, value: UInt32.max)),
            ("height_max", try patchingUInt32Tag(valid, tag: 257, value: UInt32.max)),
            ("huge_rows_per_strip", {
                let heightMax = try! patchingUInt32Tag(valid, tag: 257, value: UInt32.max)
                return try! patchingUInt32Tag(heightMax, tag: 278, value: UInt32.max)
            }()),
            ("truncated", valid.dropLast(64)),
        ]

        for (name, data) in cases {
            let url = directory.appendingPathComponent("\(name).dng")
            try data.write(to: url)
            XCTAssertThrowsError(try LinearDNGTIFFReader.decode(
                imageURL: url,
                destinationMMapURL: destination
            ), "\(name) must throw") { error in
                switch error {
                case ScalerError.metadataExtractionFailed, ScalerError.stripDecodingFailed:
                    break
                default:
                    XCTFail("\(name): unexpected error \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: destination), sentinel, "\(name) changed the destination")
        }

        XCTAssertLessThan(directoryByteSize(directory), 1_000_000, "no huge file was written")
    }

    // MARK: - R8 legacy + float HDR re-ingest

    /// Backward compatibility: the previous-stage integer fixture (H=4 encoded as
    /// q/65535 * 2^BaselineExposure) still reads via the explicitly labelled legacy path.
    func testLegacyIntegerSuiteDNGFixtureStillDecodesWithOldHeadroomPath() throws {
        let fixture = fixturesDirectory().appendingPathComponent("independent.dng")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path), "fixture missing at \(fixture.path)")

        let info = try XCTUnwrap(LinearDNGTIFFReader.probe(imageURL: fixture))
        XCTAssertEqual(info.width, 64)
        XCTAssertEqual(info.height, 64)
        XCTAssertEqual(info.sampleFormat, [1, 1, 1])
        XCTAssertEqual(info.dngVersion, [1, 4, 0, 0])
        XCTAssertEqual(info.dngBackwardVersion, [1, 1, 0, 0])
        XCTAssertEqual(info.colorimetricReference, 1)
        XCTAssertEqual(info.baselineExposure ?? 0, 2.0, accuracy: 1e-6)
        XCTAssertEqual(info.headroomScaleFromDescription ?? 0, 4.0, accuracy: 1e-6)
        XCTAssertNil(info.profileDynamicRangeHint)

        let metadata = try MetadataExtractor.extractMetadata(from: fixture)
        XCTAssertTrue(metadata.isLinearDNG)
        XCTAssertTrue(metadata.hasSuiteLinearDNGMarker)
        XCTAssertEqual(metadata.linearHeadroomScale ?? 0, 4.0, accuracy: 1e-4)
        XCTAssertEqual(metadata.originalWidth, 64)
        XCTAssertEqual(metadata.originalHeight, 64)

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("legacy.bin")
        let decoded = try LinearDNGTIFFReader.decode(imageURL: fixture, destinationMMapURL: destination)
        XCTAssertTrue(decoded.isLegacyIntegerHeadroom, "legacy integer overrange must be labelled")
        XCTAssertFalse(decoded.isFloat)
        XCTAssertEqual(decoded.sampleFormat, 1)
        XCTAssertEqual(decoded.headroomScale, 4.0, accuracy: 1e-5)
        XCTAssertEqual(decoded.baselineExposure, 2.0, accuracy: 1e-5)
        XCTAssertEqual(decoded.globalMaxLinearComponent, 4.0, accuracy: 1e-3)
        // Saturated red 4.0 has luminance ~0.916; the neutral 1.0 patches set the luminance max.
        XCTAssertEqual(decoded.globalMaxLuminance, 1.0, accuracy: 1e-3)
        XCTAssertEqual(decoded.stripCount, 4)

        let buffer = try MMapBuffer(fileURL: destination, width: 64, height: 64, createIfMissing: false)
        let half = rgba(from: buffer, x: 5, y: 5)
        XCTAssertEqual(half.r, 0.5, accuracy: 0.002)
        let red = rgba(from: buffer, x: 40, y: 5)
        XCTAssertEqual(red.r, 4.0, accuracy: 0.01)
        XCTAssertEqual(red.g, 0, accuracy: 0.001)
        let one = rgba(from: buffer, x: 5, y: 40)
        XCTAssertEqual(one.r, 1.0, accuracy: 0.002)
        let lower = rgba(from: buffer, x: 40, y: 40)
        XCTAssertEqual(lower.r, 1.0, accuracy: 0.002)

        // The production ingestion route keeps the same legacy behavior.
        let pipelineBin = directory.appendingPathComponent("legacy_pipeline.bin")
        let pipeline = try UniversalStripDecoder.decodeToMMap(imageURL: fixture, destinationMMapURL: pipelineBin)
        XCTAssertEqual(pipeline.globalMaxLinearComponent, 4.0, accuracy: 1e-3)
        XCTAssertEqual(rgba(from: pipeline.sourceBuffer, x: 40, y: 5).r, 4.0, accuracy: 0.01)
    }

    /// New SDR integer files are q/65535 with BaselineExposure 0 and no headroom multiplier.
    func testNewIntegerSDRDecodesQuantizedWithoutHeadroomMultiplier() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sdr_new.dng")
        let description = "TruongScaler Linear DNG; WorkingSpace=LinearDisplayP3; HeadroomScale=1; HeadroomEV=0; "
            + "UpscaledByApp=false; UpscaledFactor=1x; Denoised=false; NoiserDenoised=false"
        let data = try makeSuiteLinearDNGData(
            width: 16,
            height: 6,
            rowsPerStrip: 3,
            headroomScale: 1,
            imageDescription: description,
            software: "TruongScaler 1.0 (ImagingSuite)",
            legacyIntegerEncoding: false
        ) { x, y in
            if y < 2 { return (0.5, 0.5, 0.5) }
            if y < 4 { return (1, 1, 1) }
            return (0.25, 0.25, 0.25)
        }
        try data.write(to: url)

        let metadata = try MetadataExtractor.extractMetadata(from: url)
        XCTAssertEqual(metadata.linearHeadroomScale ?? 0, 1.0, accuracy: 1e-4)

        let destination = directory.appendingPathComponent("sdr_new.bin")
        let decoded = try LinearDNGTIFFReader.decode(imageURL: url, destinationMMapURL: destination)
        XCTAssertFalse(decoded.isFloat)
        XCTAssertFalse(decoded.isLegacyIntegerHeadroom)
        XCTAssertEqual(decoded.headroomScale, 1.0, accuracy: 1e-6)
        XCTAssertEqual(decoded.baselineExposure, 0, accuracy: 1e-6)
        XCTAssertEqual(decoded.sampleFormat, 1)

        let buffer = try MMapBuffer(fileURL: destination, width: 16, height: 6, createIfMissing: false)
        XCTAssertEqual(rgba(from: buffer, x: 5, y: 0).r, 0.5, accuracy: 0.001)
        XCTAssertEqual(rgba(from: buffer, x: 5, y: 2).r, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgba(from: buffer, x: 5, y: 4).r, 0.25, accuracy: 0.001)
    }

    /// New HDR float files store absolute values; the DNG ProfileDynamicRange hint (not the
    /// descriptive ImageDescription marker) is the headroom source of truth.
    func testSuiteFloatHDRProfileHintDrivesHeadroomAndAbsoluteSamples() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hdr_new.dng")
        // Deliberately inconsistent descriptive marker: the profile hint below must win.
        let description = "TruongScaler Linear DNG; SampleFormat=Float16; WorkingSpace=LinearDisplayP3; "
            + "HeadroomScale=1; HeadroomEV=0; UpscaledByApp=false; UpscaledFactor=1x; Denoised=false; NoiserDenoised=false"
        let data = try makeSuiteFloatDNGData(
            width: 32,
            height: 8,
            rowsPerStrip: 4,
            hintMaxOutputValue: 4,
            imageDescription: description,
            software: "TruongScaler 1.0 (ImagingSuite)"
        ) { x, y in
            if y < 2 { return (4, 4, 4) }              // saturated HDR white
            if y < 4 { return (4, 0, 0) }              // saturated HDR red (component peak)
            if y < 6 { return (1, 1, 1) }
            return (0.18, 0.18, 0.18)                  // neutral 18% grey
        }
        try data.write(to: url)
        let originalBytes = try Data(contentsOf: url)

        let info = try XCTUnwrap(LinearDNGTIFFReader.probe(imageURL: url))
        XCTAssertEqual(info.sampleFormat, [3, 3, 3])
        XCTAssertEqual(info.dngVersion, [1, 7, 0, 0])
        XCTAssertEqual(info.dngBackwardVersion, [1, 7, 0, 0])
        XCTAssertEqual(info.colorimetricReference, 2)
        XCTAssertEqual(info.whiteLevel, 1)
        XCTAssertEqual(info.profileDynamicRangeVersion, 1)
        XCTAssertEqual(info.profileDynamicRangeValue, 1)
        XCTAssertEqual(info.profileDynamicRangeHint ?? 0, 4.0, accuracy: 1e-6)

        let metadata = try MetadataExtractor.extractMetadata(from: url)
        XCTAssertTrue(metadata.isLinearDNG)
        XCTAssertTrue(metadata.hasSuiteLinearDNGMarker)
        XCTAssertEqual(metadata.linearHeadroomScale ?? 0, 4.0, accuracy: 1e-4,
                       "the ProfileDynamicRange hint must override the descriptive marker")

        let destination = directory.appendingPathComponent("hdr_new.bin")
        let recorder = ProgressRecorder()
        let decoded = try UniversalStripDecoder.decodeToMMap(
            imageURL: url,
            destinationMMapURL: destination,
            stripHeight: 2,
            progressHandler: { recorder.record($0) }
        )
        XCTAssertEqual(decoded.decodedWidth, 32)
        XCTAssertEqual(decoded.decodedHeight, 8)
        XCTAssertEqual(decoded.globalMaxLinearComponent, 4.0, accuracy: 1e-5)
        XCTAssertEqual(decoded.globalMaxLuminance, 4.0, accuracy: 1e-5)
        XCTAssertFalse(recorder.snapshot().isEmpty)

        let white = rgba(from: decoded.sourceBuffer, x: 10, y: 0)
        XCTAssertEqual(white.r, 4.0, accuracy: 0.01)
        XCTAssertEqual(white.g, 4.0, accuracy: 0.01)
        XCTAssertEqual(white.a, 1.0, accuracy: 0.002)
        let red = rgba(from: decoded.sourceBuffer, x: 10, y: 2)
        XCTAssertEqual(red.r, 4.0, accuracy: 0.01)
        XCTAssertEqual(red.g, 0, accuracy: 0.001)
        let one = rgba(from: decoded.sourceBuffer, x: 10, y: 4)
        XCTAssertEqual(one.r, 1.0, accuracy: 0.002)
        let grey = rgba(from: decoded.sourceBuffer, x: 10, y: 6)
        XCTAssertEqual(grey.r, 0.18, accuracy: 0.002)
        XCTAssertEqual(grey.g, 0.18, accuracy: 0.002)
        XCTAssertEqual(grey.b, 0.18, accuracy: 0.002)

        let directBin = directory.appendingPathComponent("hdr_direct.bin")
        let direct = try LinearDNGTIFFReader.decode(imageURL: url, destinationMMapURL: directBin)
        XCTAssertTrue(direct.isFloat)
        XCTAssertFalse(direct.isLegacyIntegerHeadroom)
        XCTAssertEqual(direct.sampleFormat, 3)
        XCTAssertEqual(direct.colorimetricReference, 2)
        XCTAssertEqual(direct.dngVersion, [1, 7, 0, 0])
        XCTAssertEqual(direct.whiteLevel, 1)
        XCTAssertEqual(direct.headroomScale, 4.0, accuracy: 1e-6)
        XCTAssertEqual(direct.baselineExposure, 0, accuracy: 1e-6)
        XCTAssertEqual(direct.profileDynamicRangeHint ?? 0, 4.0, accuracy: 1e-6)
        XCTAssertEqual(try Data(contentsOf: url), originalBytes, "source DNG must never be modified")
    }

    /// Compatibility fallback for non-Adobe writers that use little-endian inner fields.
    func testReaderAcceptsLittleEndianProfileDynamicRangeFallback() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hdr_le_pdr.dng")
        let description = "TruongScaler Linear DNG; SampleFormat=Float16; WorkingSpace=LinearDisplayP3; "
            + "HeadroomScale=4; HeadroomEV=2"
        let be = try makeSuiteFloatDNGData(
            width: 8, height: 4, rowsPerStrip: 2, hintMaxOutputValue: 4,
            imageDescription: description, software: "TruongScaler 1.0 (ImagingSuite)"
        ) { _, _ in (0.5, 0.5, 0.5) }
        let le = try patchingProfileDynamicRangeToLittleEndian(be)
        try le.write(to: url)

        let info = try XCTUnwrap(LinearDNGTIFFReader.probe(imageURL: url))
        XCTAssertEqual(info.profileDynamicRangeVersion, 1)
        XCTAssertEqual(info.profileDynamicRangeValue, 1)
        XCTAssertEqual(info.profileDynamicRangeHint ?? 0, 4.0, accuracy: 1e-6)

        let destination = directory.appendingPathComponent("hdr_le_pdr.bin")
        let decoded = try LinearDNGTIFFReader.decode(imageURL: url, destinationMMapURL: destination)
        XCTAssertEqual(decoded.profileDynamicRangeHint ?? 0, 4.0, accuracy: 1e-6)
        XCTAssertEqual(decoded.headroomScale, 4.0, accuracy: 1e-6)
        XCTAssertTrue(decoded.isFloat)
    }

}

// MARK: - Fixtures

private enum FixtureError: Error {
    case imageCreationFailed
    case destinationCreationFailed
    case finalizeFailed
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private struct RGBA {
    let r: Float
    let g: Float
    let b: Float
    let a: Float
}

private func rgba(from buffer: MMapBuffer, x: Int, y: Int) -> RGBA {
    let pixel = buffer.unsafePixelPointer(x: x, y: y)
    return RGBA(r: Float(pixel[0]), g: Float(pixel[1]), b: Float(pixel[2]), a: Float(pixel[3]))
}

private func integerValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let int = value as? Int { return int }
    return nil
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoreIngestionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Writes a 600×700-style 16-bit PNG with four distinctly colored quadrants. The image is tagged with
/// `extendedLinearDisplayP3` so decoding into the same working color space is effectively identity.
private func write16BitQuadrantPNG(to url: URL, width: Int, height: Int) throws {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
    var pixels = [UInt16](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let isTop = y < height / 2
            let isLeft = x < width / 2
            let rgb: (Double, Double, Double)
            switch (isTop, isLeft) {
            case (true, true): rgb = (0.80, 0.10, 0.10)
            case (true, false): rgb = (0.10, 0.80, 0.10)
            case (false, true): rgb = (0.10, 0.10, 0.80)
            case (false, false): rgb = (0.75, 0.75, 0.75)
            }
            let offset = (y * width + x) * 4
            pixels[offset + 0] = UInt16((rgb.0 * 65_535.0).rounded())
            pixels[offset + 1] = UInt16((rgb.1 * 65_535.0).rounded())
            pixels[offset + 2] = UInt16((rgb.2 * 65_535.0).rounded())
            pixels[offset + 3] = 65_535
        }
    }

    let data = pixels.withUnsafeBytes { Data($0) }
    let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
    let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
    )
    let image = try XCTUnwrap(CGImage(
        width: width,
        height: height,
        bitsPerComponent: 16,
        bitsPerPixel: 64,
        bytesPerRow: width * 8,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ))
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ))
    let properties: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifISOSpeedRatings: [640],
            kCGImagePropertyExifUserComment: "ImagingSuite:Denoised=true",
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFSoftware: "TruongImagingSuite 1.0 (ImagingSuite:UpscaledByApp=true;UpscaledFactor=2x)",
        ],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw FixtureError.finalizeFailed }
}

/// Writes a 16-bit half-float TIFF whose top-left quadrant is a 4.0 extended-linear white and whose
/// remaining quadrants are 0.5 gray. This exercises the > 1.0 HDR headroom scan end-to-end.
private func writeHDRFloatTIFF(to url: URL, width: Int, height: Int) throws {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
    var pixels = [Float16](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let isTopLeftQuadrant = x < width / 2 && y < height / 2
            let value: Float16 = isTopLeftQuadrant ? 4.0 : 0.5
            let offset = (y * width + x) * 4
            pixels[offset + 0] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
            pixels[offset + 3] = 1.0
        }
    }

    let data = pixels.withUnsafeBytes { Data($0) }
    let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
    let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue
            | CGBitmapInfo.floatComponents.rawValue
    )
    let image = try XCTUnwrap(CGImage(
        width: width,
        height: height,
        bitsPerComponent: 16,
        bitsPerPixel: 64,
        bytesPerRow: width * 8,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ))
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.tiff.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyDepth: 16] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw FixtureError.finalizeFailed }
}

/// Writes an 8-bit sRGB PNG (left half red, right half blue) with EXIF orientation 6 plus cross-app markers.
private func writeOrientedPNG(to url: URL, width: Int, height: Int, orientation: Int) throws {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            if x < width / 2 {
                pixels[offset + 0] = 204
                pixels[offset + 1] = 26
                pixels[offset + 2] = 26
            } else {
                pixels[offset + 0] = 26
                pixels[offset + 1] = 26
                pixels[offset + 2] = 204
            }
            pixels[offset + 3] = 255
        }
    }

    let data = pixels.withUnsafeBytes { Data($0) }
    let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    let image = try XCTUnwrap(CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ))
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ))
    let properties: [CFString: Any] = [
        kCGImagePropertyOrientation: orientation,
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifISOSpeedRatings: [800],
            kCGImagePropertyExifUserComment: "ImagingSuite:Denoised=true",
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFSoftware: "TruongImagingSuite 1.0 (ImagingSuite:UpscaledByApp=true;UpscaledFactor=2x)",
        ],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw FixtureError.finalizeFailed }
}

// MARK: - Suite rendered Linear DNG fixture writer
//
// Deliberately independent of `DNGWriterBridge`: the fixture is hand-built here so the
// ingestion tests prove the decoder against a second writer and not the C++ implementation.

private struct SuiteFixtureTag {
    let tag: UInt16
    let type: UInt16
    let count: UInt32
    let payload: [UInt8]
}

private func fixtureLE16(_ value: UInt16) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
}

private func fixtureLE32(_ value: UInt32) -> [UInt8] {
    [
        UInt8(value & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 24) & 0xFF),
    ]
}

private func fixtureBE16(_ value: UInt16) -> [UInt8] {
    [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

private func fixtureBE32(_ value: UInt32) -> [UInt8] {
    [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
}

private func fixtureASCII(_ value: String) -> [UInt8] {
    var bytes = Array(value.utf8)
    bytes.append(0)
    return bytes
}

private func fixtureSrational(_ values: [Double]) -> [UInt8] {
    var bytes: [UInt8] = []
    for value in values {
        let numerator = Int32((value * 1_000_000).rounded())
        bytes.append(contentsOf: fixtureLE32(UInt32(bitPattern: numerator)))
        bytes.append(contentsOf: fixtureLE32(1_000_000))
    }
    return bytes
}

private func fixtureRational(_ values: [Double]) -> [UInt8] {
    var bytes: [UInt8] = []
    for value in values {
        let numerator = UInt32((max(0, value) * 10_000).rounded())
        bytes.append(contentsOf: fixtureLE32(numerator))
        bytes.append(contentsOf: fixtureLE32(10_000))
    }
    return bytes
}

private func makeSuiteLinearDNGData(
    width: Int,
    height: Int,
    rowsPerStrip: Int,
    headroomScale: Float,
    imageDescription: String,
    software: String,
    photometricInterpretation: UInt16 = 34892,
    legacyIntegerEncoding: Bool = true,
    pixel: (Int, Int) -> (Double, Double, Double)
) throws -> Data {
    let safeRows = max(1, min(rowsPerStrip, height))
    let stripCount = (height + safeRows - 1) / safeRows
    // Legacy (previous stage) encoding: q = v/H * 65535, BaselineExposure = log2(H).
    // New SDR encoding: q = clamp(v,0,1) * 65535, BaselineExposure = 0.
    let headroom = legacyIntegerEncoding ? Double(max(headroomScale, 0.001)) : 1.0
    let baselineExposure = legacyIntegerEncoding ? log2(headroom) : 0.0
    let matrix: [Double] = [
         2.4934969119414254, -0.9313836179191239, -0.40271078445071684,
        -0.8294889695615747,  1.7626640603183463,  0.023624685841943577,
         0.0358458302437845, -0.07617238926804182, 0.9568845240076872,
    ]

    // Pixel strips (encoding: q = round(clamp(v,0,H)/H * 65535)).
    var pixels: [UInt8] = []
    pixels.reserveCapacity(width * height * 6)
    for y in 0..<height {
        for x in 0..<width {
            let (red, green, blue) = pixel(x, y)
            for value in [red, green, blue] {
                let clamped = min(max(value, 0), headroom)
                let quantized = UInt16((clamped / headroom * 65_535.0).rounded())
                pixels.append(contentsOf: fixtureLE16(quantized))
            }
        }
    }

    var stripByteCounts: [UInt8] = []
    for strip in 0..<stripCount {
        let rows = min(safeRows, height - strip * safeRows)
        stripByteCounts.append(contentsOf: fixtureLE32(UInt32(rows * width * 6)))
    }

    let tags: [SuiteFixtureTag] = [
        SuiteFixtureTag(tag: 254, type: 4, count: 1, payload: fixtureLE32(0)),
        SuiteFixtureTag(tag: 256, type: 4, count: 1, payload: fixtureLE32(UInt32(width))),
        SuiteFixtureTag(tag: 257, type: 4, count: 1, payload: fixtureLE32(UInt32(height))),
        SuiteFixtureTag(tag: 258, type: 3, count: 3, payload: fixtureLE16(16) + fixtureLE16(16) + fixtureLE16(16)),
        SuiteFixtureTag(tag: 259, type: 3, count: 1, payload: fixtureLE16(1)),
        SuiteFixtureTag(tag: 262, type: 3, count: 1, payload: fixtureLE16(photometricInterpretation)),
        SuiteFixtureTag(tag: 270, type: 2, count: UInt32(fixtureASCII(imageDescription).count), payload: fixtureASCII(imageDescription)),
        SuiteFixtureTag(tag: 271, type: 2, count: UInt32(fixtureASCII("TruongCamFixture").count), payload: fixtureASCII("TruongCamFixture")),
        SuiteFixtureTag(tag: 272, type: 2, count: UInt32(fixtureASCII("Fixture Linear RAW").count), payload: fixtureASCII("Fixture Linear RAW")),
        SuiteFixtureTag(tag: 273, type: 4, count: UInt32(stripCount), payload: [UInt8](repeating: 0, count: stripCount * 4)),
        SuiteFixtureTag(tag: 274, type: 3, count: 1, payload: fixtureLE16(1)),
        SuiteFixtureTag(tag: 277, type: 3, count: 1, payload: fixtureLE16(3)),
        SuiteFixtureTag(tag: 278, type: 4, count: 1, payload: fixtureLE32(UInt32(safeRows))),
        SuiteFixtureTag(tag: 279, type: 4, count: UInt32(stripCount), payload: stripByteCounts),
        SuiteFixtureTag(tag: 284, type: 3, count: 1, payload: fixtureLE16(1)),
        SuiteFixtureTag(tag: 305, type: 2, count: UInt32(fixtureASCII(software).count), payload: fixtureASCII(software)),
        SuiteFixtureTag(tag: 339, type: 3, count: 3, payload: fixtureLE16(1) + fixtureLE16(1) + fixtureLE16(1)),
        SuiteFixtureTag(tag: 50706, type: 1, count: 4, payload: [1, 4, 0, 0]),
        SuiteFixtureTag(tag: 50707, type: 1, count: 4, payload: [1, 1, 0, 0]),
        SuiteFixtureTag(tag: 50708, type: 2, count: UInt32(fixtureASCII("Fixture Linear RAW").count), payload: fixtureASCII("Fixture Linear RAW")),
        SuiteFixtureTag(tag: 50714, type: 3, count: 3, payload: fixtureLE16(0) + fixtureLE16(0) + fixtureLE16(0)),
        SuiteFixtureTag(tag: 50717, type: 4, count: 3, payload: fixtureLE32(65_535) + fixtureLE32(65_535) + fixtureLE32(65_535)),
        SuiteFixtureTag(tag: 50721, type: 10, count: 9, payload: fixtureSrational(matrix)),
        SuiteFixtureTag(tag: 50728, type: 5, count: 3, payload: fixtureRational([1, 1, 1])),
        SuiteFixtureTag(tag: 50730, type: 10, count: 1, payload: fixtureSrational([baselineExposure])),
        SuiteFixtureTag(tag: 50778, type: 3, count: 1, payload: fixtureLE16(21)),
        SuiteFixtureTag(tag: 50879, type: 3, count: 1, payload: fixtureLE16(1)),
    ]

    var sorted = tags.sorted { $0.tag < $1.tag }
    let ifdByteCount = 2 + sorted.count * 12 + 4
    var extraCursor = 8 + ifdByteCount
    var extraOffsets: [UInt16: Int] = [:]
    for tag in sorted where tag.payload.count > 4 {
        extraCursor = (extraCursor + 1) & ~1
        extraOffsets[tag.tag] = extraCursor
        extraCursor += tag.payload.count
    }
    let firstStripOffset = (extraCursor + 15) & ~15

    var stripOffsets: [UInt8] = []
    var offsetCursor = firstStripOffset
    for strip in 0..<stripCount {
        let rows = min(safeRows, height - strip * safeRows)
        stripOffsets.append(contentsOf: fixtureLE32(UInt32(offsetCursor)))
        offsetCursor += rows * width * 6
    }
    sorted = sorted.map { tag in
        guard tag.tag == 273 else { return tag }
        return SuiteFixtureTag(tag: 273, type: 4, count: UInt32(stripCount), payload: stripOffsets)
    }

    var output = [UInt8](repeating: 0, count: firstStripOffset + pixels.count)
    output[0] = 0x49
    output[1] = 0x49
    output[2] = 42
    output[3] = 0
    for (index, byte) in fixtureLE32(8).enumerated() { output[4 + index] = byte }
    for (index, byte) in fixtureLE16(UInt16(sorted.count)).enumerated() { output[8 + index] = byte }
    for (index, tag) in sorted.enumerated() {
        let entryOffset = 10 + index * 12
        for (byteIndex, byte) in fixtureLE16(tag.tag).enumerated() { output[entryOffset + byteIndex] = byte }
        for (byteIndex, byte) in fixtureLE16(tag.type).enumerated() { output[entryOffset + 2 + byteIndex] = byte }
        for (byteIndex, byte) in fixtureLE32(tag.count).enumerated() { output[entryOffset + 4 + byteIndex] = byte }
        if tag.payload.count <= 4 {
            for (byteIndex, byte) in tag.payload.enumerated() { output[entryOffset + 8 + byteIndex] = byte }
        } else {
            let offset = extraOffsets[tag.tag] ?? 0
            for (byteIndex, byte) in fixtureLE32(UInt32(offset)).enumerated() { output[entryOffset + 8 + byteIndex] = byte }
            for (byteIndex, byte) in tag.payload.enumerated() { output[offset + byteIndex] = byte }
        }
    }
    let nextIFDOffset = 10 + sorted.count * 12
    for (index, byte) in fixtureLE32(0).enumerated() { output[nextIFDOffset + index] = byte }
    for (index, byte) in pixels.enumerated() { output[firstStripOffset + index] = byte }
    return Data(output)
}

// MARK: - Independent float HDR fixture + hostile-geometry test helpers

/// Hand-built DNG 1.7 / ColorimetricReference 2 / Float16 fixture whose writer is independent
/// of both `DNGWriterBridge` and `LinearDNGTIFFReader`.
private func makeSuiteFloatDNGData(
    width: Int,
    height: Int,
    rowsPerStrip: Int,
    hintMaxOutputValue: Float,
    imageDescription: String,
    software: String,
    pixel: (Int, Int) -> (Double, Double, Double)
) throws -> Data {
    let safeRows = max(1, min(rowsPerStrip, height))
    let stripCount = (height + safeRows - 1) / safeRows
    let matrix: [Double] = [
         2.4934969119414254, -0.9313836179191239, -0.40271078445071684,
        -0.8294889695615747,  1.7626640603183463,  0.023624685841943577,
         0.0358458302437845, -0.07617238926804182, 0.9568845240076872,
    ]

    var pixels: [UInt8] = []
    pixels.reserveCapacity(width * height * 6)
    for y in 0..<height {
        for x in 0..<width {
            let (red, green, blue) = pixel(x, y)
            for value in [red, green, blue] {
                let word = Float16(Float(value)).bitPattern
                pixels.append(contentsOf: fixtureLE16(word))
            }
        }
    }

    var stripByteCounts: [UInt8] = []
    for strip in 0..<stripCount {
        let rows = min(safeRows, height - strip * safeRows)
        stripByteCounts.append(contentsOf: fixtureLE32(UInt32(rows * width * 6)))
    }

    let hintBits = Float(hintMaxOutputValue).bitPattern
    // Adobe/ExifTool convention: inner ProfileDynamicRange struct is big-endian.
    let profileDynamicRange = fixtureBE16(1) + fixtureBE16(1) + fixtureBE32(hintBits)
    let tags: [SuiteFixtureTag] = [
        SuiteFixtureTag(tag: 254, type: 4, count: 1, payload: fixtureLE32(0)),
        SuiteFixtureTag(tag: 256, type: 4, count: 1, payload: fixtureLE32(UInt32(width))),
        SuiteFixtureTag(tag: 257, type: 4, count: 1, payload: fixtureLE32(UInt32(height))),
        SuiteFixtureTag(tag: 258, type: 3, count: 3, payload: fixtureLE16(16) + fixtureLE16(16) + fixtureLE16(16)),
        SuiteFixtureTag(tag: 259, type: 3, count: 1, payload: fixtureLE16(1)),
        SuiteFixtureTag(tag: 262, type: 3, count: 1, payload: fixtureLE16(34892)),
        SuiteFixtureTag(tag: 270, type: 2, count: UInt32(fixtureASCII(imageDescription).count), payload: fixtureASCII(imageDescription)),
        SuiteFixtureTag(tag: 271, type: 2, count: UInt32(fixtureASCII("TruongCamFixture").count), payload: fixtureASCII("TruongCamFixture")),
        SuiteFixtureTag(tag: 272, type: 2, count: UInt32(fixtureASCII("Fixture Linear RAW").count), payload: fixtureASCII("Fixture Linear RAW")),
        SuiteFixtureTag(tag: 273, type: 4, count: UInt32(stripCount), payload: [UInt8](repeating: 0, count: stripCount * 4)),
        SuiteFixtureTag(tag: 274, type: 3, count: 1, payload: fixtureLE16(1)),
        SuiteFixtureTag(tag: 277, type: 3, count: 1, payload: fixtureLE16(3)),
        SuiteFixtureTag(tag: 278, type: 4, count: 1, payload: fixtureLE32(UInt32(safeRows))),
        SuiteFixtureTag(tag: 279, type: 4, count: UInt32(stripCount), payload: stripByteCounts),
        SuiteFixtureTag(tag: 284, type: 3, count: 1, payload: fixtureLE16(1)),
        SuiteFixtureTag(tag: 305, type: 2, count: UInt32(fixtureASCII(software).count), payload: fixtureASCII(software)),
        SuiteFixtureTag(tag: 339, type: 3, count: 3, payload: fixtureLE16(3) + fixtureLE16(3) + fixtureLE16(3)),
        SuiteFixtureTag(tag: 50706, type: 1, count: 4, payload: [1, 7, 0, 0]),
        SuiteFixtureTag(tag: 50707, type: 1, count: 4, payload: [1, 7, 0, 0]),
        SuiteFixtureTag(tag: 50708, type: 2, count: UInt32(fixtureASCII("Fixture Linear RAW").count), payload: fixtureASCII("Fixture Linear RAW")),
        SuiteFixtureTag(tag: 50714, type: 3, count: 3, payload: fixtureLE16(0) + fixtureLE16(0) + fixtureLE16(0)),
        SuiteFixtureTag(tag: 50717, type: 4, count: 3, payload: fixtureLE32(1) + fixtureLE32(1) + fixtureLE32(1)),
        SuiteFixtureTag(tag: 50721, type: 10, count: 9, payload: fixtureSrational(matrix)),
        SuiteFixtureTag(tag: 50728, type: 5, count: 3, payload: fixtureRational([1, 1, 1])),
        SuiteFixtureTag(tag: 50730, type: 10, count: 1, payload: fixtureSrational([0])),
        SuiteFixtureTag(tag: 50778, type: 3, count: 1, payload: fixtureLE16(21)),
        SuiteFixtureTag(tag: 50879, type: 3, count: 1, payload: fixtureLE16(2)),
        SuiteFixtureTag(tag: 52551, type: 7, count: 8, payload: profileDynamicRange),
    ]

    var sorted = tags.sorted { $0.tag < $1.tag }
    let ifdByteCount = 2 + sorted.count * 12 + 4
    var extraCursor = 8 + ifdByteCount
    var extraOffsets: [UInt16: Int] = [:]
    for tag in sorted where tag.payload.count > 4 {
        extraCursor = (extraCursor + 1) & ~1
        extraOffsets[tag.tag] = extraCursor
        extraCursor += tag.payload.count
    }
    let firstStripOffset = (extraCursor + 15) & ~15

    var stripOffsets: [UInt8] = []
    var offsetCursor = firstStripOffset
    for strip in 0..<stripCount {
        let rows = min(safeRows, height - strip * safeRows)
        stripOffsets.append(contentsOf: fixtureLE32(UInt32(offsetCursor)))
        offsetCursor += rows * width * 6
    }
    sorted = sorted.map { tag in
        guard tag.tag == 273 else { return tag }
        return SuiteFixtureTag(tag: 273, type: 4, count: UInt32(stripCount), payload: stripOffsets)
    }

    var output = [UInt8](repeating: 0, count: firstStripOffset + pixels.count)
    output[0] = 0x49
    output[1] = 0x49
    output[2] = 42
    output[3] = 0
    for (index, byte) in fixtureLE32(8).enumerated() { output[4 + index] = byte }
    for (index, byte) in fixtureLE16(UInt16(sorted.count)).enumerated() { output[8 + index] = byte }
    for (index, tag) in sorted.enumerated() {
        let entryOffset = 10 + index * 12
        for (byteIndex, byte) in fixtureLE16(tag.tag).enumerated() { output[entryOffset + byteIndex] = byte }
        for (byteIndex, byte) in fixtureLE16(tag.type).enumerated() { output[entryOffset + 2 + byteIndex] = byte }
        for (byteIndex, byte) in fixtureLE32(tag.count).enumerated() { output[entryOffset + 4 + byteIndex] = byte }
        if tag.payload.count <= 4 {
            for (byteIndex, byte) in tag.payload.enumerated() { output[entryOffset + 8 + byteIndex] = byte }
        } else {
            let offset = extraOffsets[tag.tag] ?? 0
            for (byteIndex, byte) in fixtureLE32(UInt32(offset)).enumerated() { output[entryOffset + 8 + byteIndex] = byte }
            for (byteIndex, byte) in tag.payload.enumerated() { output[offset + byteIndex] = byte }
        }
    }
    let nextIFDOffset = 10 + sorted.count * 12
    for (index, byte) in fixtureLE32(0).enumerated() { output[nextIFDOffset + index] = byte }
    for (index, byte) in pixels.enumerated() { output[firstStripOffset + index] = byte }
    return Data(output)
}

private func fixturesDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
}

/// Mutates a sample-tag entry in the independent fixture while retaining all source pixel bytes.
private func patchingSampleTag(
    _ data: Data,
    tag: UInt16,
    replacementTag: UInt16? = nil,
    type: UInt16? = nil,
    count: UInt32? = nil,
    valueOrOffset: UInt32? = nil
) throws -> Data {
    var bytes = [UInt8](data)
    guard bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x49 else {
        throw FixtureError.imageCreationFailed
    }
    let ifdOffset = Int(bytes[4]) | (Int(bytes[5]) << 8)
        | (Int(bytes[6]) << 16) | (Int(bytes[7]) << 24)
    guard ifdOffset <= bytes.count - 2 else { throw FixtureError.imageCreationFailed }
    let entryCount = Int(bytes[ifdOffset]) | (Int(bytes[ifdOffset + 1]) << 8)
    for index in 0..<entryCount {
        let entry = ifdOffset + 2 + index * 12
        guard entry <= bytes.count - 12 else { throw FixtureError.imageCreationFailed }
        let entryTag = UInt16(bytes[entry]) | (UInt16(bytes[entry + 1]) << 8)
        guard entryTag == tag else { continue }
        for (offset, value) in [(0, replacementTag), (2, type)] {
            if let value {
                bytes.replaceSubrange((entry + offset)..<(entry + offset + 2), with: fixtureLE16(value))
            }
        }
        for (offset, value) in [(4, count), (8, valueOrOffset)] {
            if let value {
                bytes.replaceSubrange((entry + offset)..<(entry + offset + 4), with: fixtureLE32(value))
            }
        }
        return Data(bytes)
    }
    throw FixtureError.imageCreationFailed
}

/// Rewrites one inline LONG (count 1) IFD0 tag in a hand-built suite fixture. Used to create
/// hostile boundary geometry without materializing huge pixel arrays.
private func patchingUInt32Tag(_ data: Data, tag: UInt16, value: UInt32) throws -> Data {
    var bytes = [UInt8](data)
    guard bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x49 else {
        throw FixtureError.imageCreationFailed
    }
    let ifdOffset = Int(bytes[4])
        | (Int(bytes[5]) << 8)
        | (Int(bytes[6]) << 16)
        | (Int(bytes[7]) << 24)
    guard ifdOffset + 2 <= bytes.count else { throw FixtureError.imageCreationFailed }
    let entryCount = Int(bytes[ifdOffset]) | (Int(bytes[ifdOffset + 1]) << 8)
    for index in 0..<entryCount {
        let entry = ifdOffset + 2 + index * 12
        let entryTag = UInt16(bytes[entry]) | (UInt16(bytes[entry + 1]) << 8)
        guard entryTag == tag else { continue }
        let type = UInt16(bytes[entry + 2]) | (UInt16(bytes[entry + 3]) << 8)
        let count = UInt32(bytes[entry + 4])
            | (UInt32(bytes[entry + 5]) << 8)
            | (UInt32(bytes[entry + 6]) << 16)
            | (UInt32(bytes[entry + 7]) << 24)
        guard type == 4, count == 1 else { throw FixtureError.imageCreationFailed }
        for (byteIndex, byte) in fixtureLE32(value).enumerated() {
            bytes[entry + 8 + byteIndex] = byte
        }
        return Data(bytes)
    }
    throw FixtureError.imageCreationFailed
}

/// Rewrites the big-endian ProfileDynamicRange inner struct as little-endian. Used to prove the
/// reader's non-Adobe compatibility fallback (the writer only emits BE).
private func patchingProfileDynamicRangeToLittleEndian(_ data: Data) throws -> Data {
    var bytes = [UInt8](data)
    let ifdOffset = Int(bytes[4])
        | (Int(bytes[5]) << 8)
        | (Int(bytes[6]) << 16)
        | (Int(bytes[7]) << 24)
    let entryCount = Int(bytes[ifdOffset]) | (Int(bytes[ifdOffset + 1]) << 8)
    for index in 0..<entryCount {
        let entry = ifdOffset + 2 + index * 12
        let entryTag = UInt16(bytes[entry]) | (UInt16(bytes[entry + 1]) << 8)
        guard entryTag == 52551 else { continue }
        let payloadOffset = Int(bytes[entry + 8])
            | (Int(bytes[entry + 9]) << 8)
            | (Int(bytes[entry + 10]) << 16)
            | (Int(bytes[entry + 11]) << 24)
        guard payloadOffset + 8 <= bytes.count else { throw FixtureError.imageCreationFailed }
        let bigEndian = Array(bytes[payloadOffset..<(payloadOffset + 8)])
        let littleEndian = [
            bigEndian[1], bigEndian[0],
            bigEndian[3], bigEndian[2],
            bigEndian[7], bigEndian[6], bigEndian[5], bigEndian[4],
        ]
        for (offset, byte) in littleEndian.enumerated() { bytes[payloadOffset + offset] = byte }
        return Data(bytes)
    }
    throw FixtureError.imageCreationFailed
}

private func directoryByteSize(_ url: URL) -> Int {
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: []
    )) ?? []
    return contents.reduce(0) { total, item in
        let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return total + size
    }
}
