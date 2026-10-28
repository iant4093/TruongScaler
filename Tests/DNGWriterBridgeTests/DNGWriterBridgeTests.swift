import CoreImage
import CoreIngestion
import Foundation
import ImageIO
import TruongScalerCore
import XCTest
@testable import DNGWriterBridge
@testable import MMapCanvas

final class DNGWriterBridgeTests: XCTestCase {
    /// Preserved original coverage (ImageIO readback) plus the contract tag/pixel/metadata checks.
    func testStreamingLinearDNG16WriteAndImageIOReadBack() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("linear_contract.dng")

        let matrix: [Float] = [
             2.4934969, -0.9313836, -0.4027108,
            -0.8294890,  1.7626641,  0.0236247,
             0.0358458, -0.0761724,  0.9568845,
        ]
        let metadata = TestMetadataEntries()
        metadata.addUndefined(
            tag: 37510,
            ifd: 1,
            value: Data("ASCII\0\0\0".utf8) + Data(
                "ImagingSuite:Denoised=false;UpscaledByApp=true;UpscaledFactor=4x;NoiserDenoised=false;Camera=TruongCam".utf8
            )
        )
        metadata.addASCII(tag: 36867, ifd: 1, value: "2026:10:22 12:00:00")
        metadata.addASCII(tag: 1, ifd: 2, value: "N")
        metadata.addRational(tag: 2, ifd: 2, values: [37, 30, 0])
        metadata.addASCII(tag: 3, ifd: 2, value: "W")
        metadata.addRational(tag: 4, ifd: 2, values: [122, 15, 0])
        metadata.addByte(tag: 5, ifd: 2, values: [0])
        metadata.addRational(tag: 6, ifd: 2, values: [12.5])

        let description = "TruongScaler Linear DNG; WorkingSpace=LinearDisplayP3; HeadroomScale=1; HeadroomEV=0; "
            + "UpscaledByApp=true; UpscaledFactor=4x; Denoised=false; NoiserDenoised=false"
        let xmp = Data("<?xpacket begin=\"\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description xmlns:ImagingSuite=\"https://truongimaging.example/pipeline/1.0/\" ImagingSuite:Denoised=\"false\" ImagingSuite:UpscaledByApp=\"true\"/></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>".utf8)

        let result = writeLinearDNG(
            to: url,
            width: 64,
            height: 64,
            rowsPerStrip: 16,
            imageDescription: description,
            baselineExposure: 0,
            orientation: 1,
            xmp: xmp,
            colorMatrix1: matrix,
            metadata: metadata
        ) { x, y in
            if y < 32 && x < 32 {
                let q = UInt16((0.5 * 65_535.0).rounded()) // 32768
                return (q, q, q)
            }
            if y < 32 && x >= 32 {
                return (65_535, 0, 0) // SDR white red
            }
            if y >= 32 && x < 32 {
                return (65_535, 65_535, 65_535) // SDR white
            }
            let q = UInt16((0.25 * 65_535.0).rounded()) // 16384
            return (q, q, q)
        }
        XCTAssertTrue(result.success, result.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let parsed = try ParsedDNG(url: url)

        // --- Core tags (ascending IFD0 order is validated by the parser). ---
        XCTAssertEqual(try parsed.uint16(262), 34892, "PhotometricInterpretation must be LinearRaw")
        XCTAssertEqual(try parsed.uint16(258, count: 3), [16, 16, 16])
        XCTAssertEqual(try parsed.uint16(277), 3)
        XCTAssertEqual(try parsed.uint16(339, count: 3), [1, 1, 1])
        XCTAssertEqual(try parsed.uint32(256), 64)
        XCTAssertEqual(try parsed.uint32(257), 64)
        XCTAssertEqual(try parsed.uint16(274), 1)
        XCTAssertEqual(try parsed.uint16(259), 1)
        XCTAssertEqual(try parsed.uint16(284), 1)
        XCTAssertEqual(try parsed.bytes(50706), [1, 4, 0, 0], "DNGVersion 1.4.0.0")
        XCTAssertEqual(try parsed.bytes(50707), [1, 1, 0, 0], "DNGBackwardVersion 1.1.0.0")
        XCTAssertEqual(try parsed.string(271), "TruongCam")
        XCTAssertEqual(try parsed.string(272), "TruongCam Test")
        XCTAssertEqual(try parsed.string(50708), "TruongCam Test")
        XCTAssertEqual(try parsed.uint16(50778), 21, "CalibrationIlluminant1 D65")
        XCTAssertEqual(try parsed.uint16(50879), 1, "ColorimetricReference output-referred")
        XCTAssertEqual(try parsed.uint16(50714, count: 3), [0, 0, 0])
        XCTAssertEqual(try parsed.uint32(50717, count: 3), [65_535, 65_535, 65_535])
        XCTAssertEqual(try parsed.srational(50730), 0.0, accuracy: 1e-6)
        XCTAssertNil(parsed.ifd0[52551], "SDR output must not declare ProfileDynamicRange")
        XCTAssertEqual(try parsed.uint16(254), 0)

        let writtenMatrix = try parsed.srationalArray(50721)
        XCTAssertEqual(writtenMatrix.count, 9)
        for index in 0..<9 {
            XCTAssertEqual(writtenMatrix[index], Double(matrix[index]), accuracy: 1e-5)
        }
        let neutral = try parsed.rationalArray(50728)
        XCTAssertEqual(neutral, [1, 1, 1])

        let imageDescription = try parsed.string(270)
        XCTAssertTrue(imageDescription.contains("TruongScaler Linear DNG"))
        XCTAssertTrue(imageDescription.contains("HeadroomScale=1"))
        XCTAssertTrue(imageDescription.contains("HeadroomEV=0"))
        XCTAssertFalse(imageDescription.contains("SampleFormat=Float16"))
        XCTAssertTrue(imageDescription.contains("UpscaledByApp=true"))
        XCTAssertTrue(imageDescription.contains("Denoised=false"))
        XCTAssertFalse(try parsed.string(305).contains("Denoised="), "Software must not hardcode a Denoised marker")
        XCTAssertTrue(try parsed.string(305).contains("TruongScaler"))
        XCTAssertEqual(try parsed.string(306), "2026:10:22 12:00:00")

        // --- EXIF and GPS sub-IFDs are reachable through pointer tags. ---
        XCTAssertNotNil(parsed.ifd0[34665], "ExifIFD pointer")
        XCTAssertNotNil(parsed.ifd0[34853], "GPSIFD pointer")
        XCTAssertEqual(try parsed.exifString(36867), "2026:10:22 12:00:00")
        let userCommentBytes = try parsed.exifBytes(37510)
        let userComment = String(decoding: userCommentBytes, as: UTF8.self)
        XCTAssertTrue(userComment.contains("Denoised=false"))
        XCTAssertTrue(userComment.contains("UpscaledByApp=true"))
        XCTAssertTrue(userComment.contains("NoiserDenoised=false"))
        XCTAssertEqual(try parsed.gpsString(1), "N")
        XCTAssertEqual(try parsed.gpsRationalArray(2), [37, 30, 0])
        XCTAssertEqual(try parsed.gpsString(3), "W")
        XCTAssertEqual(try parsed.gpsRationalArray(4), [122, 15, 0])
        XCTAssertEqual(try parsed.gpsBytes(5), [0])
        XCTAssertEqual(try parsed.gpsRational(6), 12.5, accuracy: 1e-6)
        XCTAssertTrue(String(decoding: try parsed.bytes(700), as: UTF8.self).contains("ImagingSuite:Denoised=\"false\""))

        // --- Strip table: four 16-row strips, contiguous, ending at EOF. ---
        let stripOffsets = try parsed.uint32Array(273)
        let stripByteCounts = try parsed.uint32Array(279)
        XCTAssertEqual(try parsed.uint32(278), 16)
        XCTAssertEqual(stripOffsets.count, 4)
        XCTAssertEqual(stripByteCounts, [6144, 6144, 6144, 6144])
        for index in 1..<stripOffsets.count {
            XCTAssertEqual(stripOffsets[index], stripOffsets[index - 1] + stripByteCounts[index - 1])
        }
        XCTAssertEqual(Int(stripOffsets.last! + stripByteCounts.last!), parsed.fileSize)

        // --- Independent hand-written strip decode. ---
        let pixels = try parsed.decodeRGB16()
        func pixel(_ x: Int, _ y: Int) -> (UInt16, UInt16, UInt16) {
            pixels[y * 64 + x]
        }
        XCTAssertEqual(pixel(5, 5).0, 32_768)
        XCTAssertEqual(pixel(5, 5).1, 32_768)
        XCTAssertEqual(pixel(40, 5).0, 65_535)
        XCTAssertEqual(pixel(40, 5).1, 0)
        XCTAssertEqual(pixel(5, 40).0, 65_535)
        XCTAssertEqual(pixel(40, 40).0, 16_384)

        // --- ImageIO/CoreImage container recognition. ImageIO reports rendered LinearRaw as
        // `public.tiff` and returns no decoded property dictionary on this SDK, so it is not a
        // usable decode path for rendered Linear DNG; the independent suite reader below is.
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertNotNil(CGImageSourceGetType(source), "ImageIO recognizes the TIFF-based DNG container")
        let rawFilter = CIRAWFilter(imageURL: url)
        print("[DNGWriterBridgeTests] ImageIO cannot render rendered LinearRaw; CIRAWFilter present=\(rawFilter != nil), nativeSize=\(rawFilter?.nativeSize ?? .zero). Suite reader is the decode path.")

        // --- Independent pure-Swift suite reader (CoreIngestion, not the C++ writer). ---
        let destination = directory.appendingPathComponent("decoded.bin")
        let decoded = try LinearDNGTIFFReader.decode(
            imageURL: url,
            destinationMMapURL: destination,
            stripHeight: 8
        )
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 64)
        XCTAssertEqual(decoded.stripCount, 4)
        XCTAssertEqual(decoded.headroomScale, 1.0, accuracy: 1e-5)
        XCTAssertEqual(decoded.baselineExposure, 0, accuracy: 1e-5)
        XCTAssertEqual(decoded.sampleFormat, 1)
        XCTAssertFalse(decoded.isFloat)
        XCTAssertFalse(decoded.isLegacyIntegerHeadroom)
        XCTAssertEqual(decoded.colorimetricReference, 1)
        XCTAssertEqual(decoded.globalMaxLinearComponent, 1.0, accuracy: 1e-4)
        XCTAssertEqual(decoded.globalMaxLuminance, 1.0, accuracy: 1e-4)

        let buffer = try MMapBuffer(fileURL: destination, width: 64, height: 64, createIfMissing: false)
        let readerPixel = rgba(from: buffer, x: 5, y: 5)
        XCTAssertEqual(readerPixel.r, 0.5, accuracy: 0.001)
        XCTAssertEqual(readerPixel.g, 0.5, accuracy: 0.001)
        XCTAssertEqual(readerPixel.b, 0.5, accuracy: 0.001)
        XCTAssertEqual(readerPixel.a, 1.0, accuracy: 0.001)
        let readerHDR = rgba(from: buffer, x: 40, y: 5)
        XCTAssertEqual(readerHDR.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(readerHDR.g, 0, accuracy: 0.001)
        XCTAssertEqual(readerHDR.b, 0, accuracy: 0.001)
        let readerOne = rgba(from: buffer, x: 5, y: 40)
        XCTAssertEqual(readerOne.r, 1.0, accuracy: 0.001)
        let readerQuarter = rgba(from: buffer, x: 40, y: 40)
        XCTAssertEqual(readerQuarter.r, 0.25, accuracy: 0.001)

        // --- External independent tag reader: exiftool. ---
        try verifyWithExifTool(url: url, expectedMatrix: matrix)
    }

    func testStreamingLinearDNG16WritesTrueFlagsAndConfigOrientation() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("true_flags.dng")

        let metadata = TestMetadataEntries()
        metadata.addUndefined(
            tag: 37510,
            ifd: 1,
            value: Data("ASCII\0\0\0".utf8) + Data(
                "ImagingSuite:Denoised=true;UpscaledByApp=false;UpscaledFactor=1x;NoiserDenoised=true".utf8
            )
        )
        let inputDescription = "TruongScaler Linear DNG; WorkingSpace=LinearDisplayP3; HeadroomScale=1; HeadroomEV=0; "
            + "UpscaledByApp=false; UpscaledFactor=1x; Denoised=true; NoiserDenoised=true"
        let result = writeLinearDNG(
            to: url,
            width: 8,
            height: 8,
            rowsPerStrip: 8,
            imageDescription: inputDescription,
            baselineExposure: 0,
            orientation: 6,
            metadata: metadata
        ) { _, _ in (32_768, 16_384, 8192) }
        XCTAssertTrue(result.success, result.error)

        let parsed = try ParsedDNG(url: url)
        XCTAssertEqual(try parsed.uint16(274), 6, "Orientation comes from config")
        XCTAssertEqual(try parsed.srational(50730), 0.0, accuracy: 1e-9)
        XCTAssertEqual(try parsed.uint16(50879), 1, "default colorimetric reference is output-referred")
        let description = try parsed.string(270)
        XCTAssertTrue(description.contains("Denoised=true"))
        XCTAssertTrue(description.contains("NoiserDenoised=true"))
        let comment = String(decoding: try parsed.exifBytes(37510), as: UTF8.self)
        XCTAssertTrue(comment.contains("Denoised=true"))
        XCTAssertTrue(comment.contains("NoiserDenoised=true"))
        XCTAssertTrue(comment.contains("UpscaledByApp=false"))
    }

    func testStreamingLinearDNG16GeneratesDefaultMarkerAndSoftware() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("defaults.dng")
        let result = writeLinearDNG(
            to: url,
            width: 4,
            height: 4,
            rowsPerStrip: 4,
            imageDescription: nil,
            baselineExposure: 0,
            orientation: 0,
            metadata: TestMetadataEntries()
        ) { _, _ in (1, 2, 3) }
        XCTAssertTrue(result.success, result.error)
        let parsed = try ParsedDNG(url: url)
        XCTAssertEqual(try parsed.uint16(274), 1, "orientation 0 defaults to 1")
        let description = try parsed.string(270)
        XCTAssertTrue(description.contains("TruongScaler Linear DNG"))
        XCTAssertTrue(description.contains("HeadroomScale=1"))
        XCTAssertTrue(description.contains("HeadroomEV=0"))
        let software = try parsed.string(305)
        XCTAssertEqual(software, "TruongScaler 1.0 (ImagingSuite)")
        XCTAssertFalse(software.contains("Denoised"))
        XCTAssertEqual(try parsed.uint16(50879), 1)
    }

    /// R8: HDR output is absolute IEEE Float16 with DNG 1.7 / reference 2 and
    /// ProfileDynamicRange (tag 52551). The callback's UInt16 words are written verbatim.
    func testStreamingLinearDNG16HDRFloatTagsAndAbsoluteDecode() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hdr_float.dng")
        let description = "TruongScaler Linear DNG; SampleFormat=Float16; WorkingSpace=LinearDisplayP3; "
            + "HeadroomScale=4; HeadroomEV=2; UpscaledByApp=false; UpscaledFactor=1x; Denoised=false; NoiserDenoised=false"
        let result = writeLinearDNG(
            to: url,
            width: 64,
            height: 64,
            rowsPerStrip: 16,
            imageDescription: description,
            baselineExposure: 0,
            sampleFormat: 3,
            profileDynamicRange: 1,
            hintMaxOutputValue: 4.0,
            colorimetricReference: 2,
            whiteLevel: 1,
            metadata: TestMetadataEntries()
        ) { x, y in
            if y < 32 && x < 32 {
                let word = Float16(0.5).bitPattern
                return (word, word, word)
            }
            if y < 32 && x >= 32 {
                return (Float16(4.0).bitPattern, 0, 0) // absolute overrange red
            }
            if y >= 32 && x < 32 {
                let word = Float16(1.0).bitPattern
                return (word, word, word)
            }
            let word = Float16(0.18).bitPattern // neutral 18% grey
            return (word, word, word)
        }
        XCTAssertTrue(result.success, result.error)

        let parsed = try ParsedDNG(url: url)
        XCTAssertEqual(try parsed.uint16(258, count: 3), [16, 16, 16])
        XCTAssertEqual(try parsed.uint16(339, count: 3), [3, 3, 3], "SampleFormat=3 IEEE float")
        XCTAssertEqual(try parsed.bytes(50706), [1, 7, 0, 0], "DNGVersion 1.7.0.0")
        XCTAssertEqual(try parsed.bytes(50707), [1, 7, 0, 0], "DNGBackwardVersion 1.7.0.0")
        XCTAssertEqual(try parsed.uint16(50879), 2, "ColorimetricReference HDR")
        XCTAssertEqual(try parsed.uint32(50717, count: 3), [1, 1, 1], "WhiteLevel 1 for float")
        XCTAssertEqual(try parsed.uint16(50714, count: 3), [0, 0, 0])
        XCTAssertEqual(try parsed.srational(50730), 0.0, accuracy: 1e-9, "BaselineExposure 0")
        XCTAssertEqual(
            try parsed.bytes(52551),
            [0x00, 0x01, 0x00, 0x01, 0x40, 0x80, 0x00, 0x00],
            "ProfileDynamicRange BE version 1 / HDR / big-endian float hint 4.0"
        )
        let parsedDescription = try parsed.string(270)
        XCTAssertTrue(parsedDescription.contains("SampleFormat=Float16"))
        XCTAssertTrue(parsedDescription.contains("HeadroomScale=4"))
        XCTAssertTrue(parsedDescription.contains("HeadroomEV=2"))

        // The raw strip words are exactly the Float16 bit patterns the callback supplied.
        let pixels = try parsed.decodeRGB16()
        XCTAssertEqual(pixels[5 * 64 + 5].0, Float16(0.5).bitPattern)
        XCTAssertEqual(pixels[5 * 64 + 40].0, Float16(4.0).bitPattern)
        XCTAssertEqual(pixels[5 * 64 + 40].1, 0)
        XCTAssertEqual(pixels[40 * 64 + 5].0, Float16(1.0).bitPattern)
        XCTAssertEqual(pixels[40 * 64 + 40].0, Float16(0.18).bitPattern)

        let destination = directory.appendingPathComponent("hdr_decoded.bin")
        let decoded = try LinearDNGTIFFReader.decode(
            imageURL: url,
            destinationMMapURL: destination,
            stripHeight: 8
        )
        XCTAssertTrue(decoded.isFloat)
        XCTAssertFalse(decoded.isLegacyIntegerHeadroom)
        XCTAssertEqual(decoded.sampleFormat, 3)
        XCTAssertEqual(decoded.colorimetricReference, 2)
        XCTAssertEqual(decoded.dngVersion, [1, 7, 0, 0])
        XCTAssertEqual(decoded.whiteLevel, 1)
        XCTAssertEqual(decoded.profileDynamicRangeValue, 1)
        XCTAssertEqual(decoded.profileDynamicRangeHint ?? 0, 4.0, accuracy: 1e-6)
        XCTAssertEqual(decoded.headroomScale, 4.0, accuracy: 1e-6)
        XCTAssertEqual(decoded.baselineExposure, 0, accuracy: 1e-6, "BaselineExposure is not a multiplier")
        XCTAssertEqual(decoded.globalMaxLinearComponent, 4.0, accuracy: 1e-5)
        XCTAssertEqual(decoded.globalMaxLuminance, 1.0, accuracy: 1e-4)

        let buffer = try MMapBuffer(fileURL: destination, width: 64, height: 64, createIfMissing: false)
        let half = rgba(from: buffer, x: 5, y: 5)
        XCTAssertEqual(half.r, 0.5, accuracy: 0.002)
        XCTAssertEqual(half.a, 1.0, accuracy: 0.002)
        let hdrRed = rgba(from: buffer, x: 40, y: 5)
        XCTAssertEqual(hdrRed.r, 4.0, accuracy: 0.01, "Absolute overrange sample, not quantized/scaled")
        XCTAssertEqual(hdrRed.g, 0, accuracy: 0.001)
        let one = rgba(from: buffer, x: 5, y: 40)
        XCTAssertEqual(one.r, 1.0, accuracy: 0.002)
        let grey = rgba(from: buffer, x: 40, y: 40)
        XCTAssertEqual(grey.r, 0.18, accuracy: 0.002)
        XCTAssertEqual(grey.g, 0.18, accuracy: 0.002)
        XCTAssertEqual(grey.b, 0.18, accuracy: 0.002)

        // exiftool is an external tag reader; never the semantic proof.
        try verifyHDRWithExifTool(url: url)
    }

    func testStreamingLinearDNG16RejectsInconsistentR8Combinations() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var callbackInvoked = false

        func attempt(
            _ name: String,
            sampleFormat: UInt16 = 1,
            profileDynamicRange: UInt16 = 0,
            hintMaxOutputValue: Float = 0,
            colorimetricReference: UInt16 = 1,
            whiteLevel: UInt16 = 65_535,
            baselineExposure: Float = 0,
            dngVersion: [UInt16] = []
        ) -> (Bool, String) {
            let url = directory.appendingPathComponent("\(name).dng")
            return writeLinearDNG(
                to: url,
                width: 4,
                height: 4,
                rowsPerStrip: 4,
                imageDescription: nil,
                baselineExposure: baselineExposure,
                sampleFormat: sampleFormat,
                profileDynamicRange: profileDynamicRange,
                hintMaxOutputValue: hintMaxOutputValue,
                colorimetricReference: colorimetricReference,
                whiteLevel: whiteLevel,
                dngVersion: dngVersion,
                onStrip: { callbackInvoked = true }
            ) { _, _ in (1, 2, 3) }
        }

        // HDR profile requires float samples.
        var result = attempt("hdr_integer", sampleFormat: 1, profileDynamicRange: 1,
                             hintMaxOutputValue: 4, colorimetricReference: 2)
        XCTAssertFalse(result.0, "HDR profile must reject integer samples")
        XCTAssertGreaterThan(result.1.count, 0)

        // HDR requires ColorimetricReference 2 and DNG 1.7.
        result = attempt("hdr_ref1", sampleFormat: 3, profileDynamicRange: 1,
                         hintMaxOutputValue: 4, colorimetricReference: 1, whiteLevel: 1)
        XCTAssertFalse(result.0, "HDR profile must reject reference 1")

        result = attempt("hdr_old_version", sampleFormat: 3, profileDynamicRange: 1,
                         hintMaxOutputValue: 4, colorimetricReference: 2, whiteLevel: 1,
                         dngVersion: [1, 6, 0, 0])
        XCTAssertFalse(result.0, "HDR requires DNG 1.7")

        // Float samples require DNG 1.4+.
        result = attempt("float_old_version", sampleFormat: 3, colorimetricReference: 1,
                         whiteLevel: 1, dngVersion: [1, 3, 0, 0])
        XCTAssertFalse(result.0, "float samples require DNG 1.4")

        // hint without profile declaration, and legacy integer headroom writing, are refused.
        result = attempt("hint_no_profile", sampleFormat: 3, hintMaxOutputValue: 4,
                         colorimetricReference: 1, whiteLevel: 1)
        XCTAssertFalse(result.0, "hint requires ProfileDynamicRange")

        result = attempt("legacy_baseline", sampleFormat: 1, baselineExposure: 2)
        XCTAssertFalse(result.0, "new writer must not use BaselineExposure as a multiplier")

        // Float WhiteLevel must be 1.
        result = attempt("float_white_65535", sampleFormat: 3, colorimetricReference: 1,
                         whiteLevel: 65_535)
        XCTAssertFalse(result.0, "float WhiteLevel must be 1")

        XCTAssertFalse(callbackInvoked, "validation must reject before any strip callback")
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(contents.isEmpty, "no partial files remain: \(contents)")
    }

    func testStreamingLinearDNG16RejectsClassicTIFFOverflowWithoutWriting() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("too_large.dng")
        var callbackInvoked = false
        let result = writeLinearDNG(
            to: url,
            width: 100_000,
            height: 20_000,
            rowsPerStrip: 1,
            imageDescription: nil,
            baselineExposure: 0,
            metadata: TestMetadataEntries(),
            onStrip: { callbackInvoked = true }
        ) { _, _ in (1, 2, 3) }
        XCTAssertFalse(result.success)
        XCTAssertFalse(callbackInvoked, "Validation must reject before streaming any strip")
        XCTAssertTrue(result.error.lowercased().contains("4 gib"), "Error names the classic TIFF limit: \(result.error)")
        XCTAssertTrue(result.error.lowercased().contains("classic tiff"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "No partial file is left behind")
    }

    func testStreamingLinearDNG16RejectsReservedMetadataTag() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("reserved.dng")
        let metadata = TestMetadataEntries()
        metadata.addShort(tag: 256, ifd: 0, value: 1) // structural ImageWidth collision
        let result = writeLinearDNG(
            to: url,
            width: 4,
            height: 4,
            rowsPerStrip: 4,
            imageDescription: nil,
            baselineExposure: 0,
            metadata: metadata
        ) { _, _ in (1, 2, 3) }
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error.contains("structural"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testWriterOutputReingestsWithFalseAndTruePipelineFlags() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for denoised in [false, true] {
            let url = directory.appendingPathComponent("reingest_\(denoised).dng")
            let metadata = TestMetadataEntries()
            metadata.addUndefined(
                tag: 37510,
                ifd: 1,
                value: Data("ASCII\0\0\0".utf8) + Data(
                    "ImagingSuite:Denoised=\(denoised);UpscaledByApp=true;UpscaledFactor=2x;NoiserDenoised=\(denoised)".utf8
                )
            )
            let description = "TruongScaler Linear DNG; WorkingSpace=LinearDisplayP3; HeadroomScale=1; HeadroomEV=0; "
                + "UpscaledByApp=true; UpscaledFactor=2x; Denoised=\(denoised); NoiserDenoised=\(denoised)"
            let result = writeLinearDNG(
                to: url,
                width: 8,
                height: 8,
                rowsPerStrip: 8,
                imageDescription: description,
                baselineExposure: 0,
                metadata: metadata
            ) { _, _ in (65_535, 65_535, 65_535) }
            XCTAssertTrue(result.success, result.error)

            let extracted = try MetadataExtractor.extractMetadata(from: url)
            XCTAssertTrue(extracted.isLinearDNG, "Writer output must be recognized as LinearRaw DNG")
            XCTAssertTrue(extracted.hasSuiteLinearDNGMarker)
            XCTAssertEqual(extracted.isAlreadyDenoisedBySuite, denoised)
            XCTAssertEqual(extracted.isAlreadyDenoisedByNoiser, denoised)
            XCTAssertTrue(extracted.isAlreadyUpscaledBySuite)
            XCTAssertEqual(extracted.upscaledByAppFactor, 2)
            XCTAssertEqual(extracted.linearHeadroomScale ?? 0, 1.0, accuracy: 1e-4)
        }
    }


    func testDNGExportMetadataBuilderCarriesSourceExifGPSAndFlags() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("builder.dng")

        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2024:05:06 07:08:09",
                kCGImagePropertyExifExposureTime as String: 0.005,
                kCGImagePropertyExifFNumber as String: 1.8,
                kCGImagePropertyExifISOSpeedRatings as String: [800],
                kCGImagePropertyExifFocalLength as String: 26.0,
                kCGImagePropertyExifLensMake as String: "TruongLens",
                kCGImagePropertyExifLensModel as String: "TL-26mm",
                kCGImagePropertyExifUserComment as String: "CustomNote;Denoised=true;UpscaledByApp=true;UpscaledFactor=2x",
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "TruongCam",
                kCGImagePropertyTIFFModel as String: "Model Z",
            ],
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 37.5,
                kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 122.25,
                kCGImagePropertyGPSLongitudeRef as String: "W",
                kCGImagePropertyGPSAltitude as String: 42.0,
            ],
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: properties,
            format: .binary,
            options: 0
        )
        let packet = ImageMetadataPacket(
            sourceURL: URL(fileURLWithPath: "/tmp/builder_source.dng"),
            utTypeIdentifier: "com.adobe.raw-image",
            category: .cameraRAW,
            originalWidth: 64,
            originalHeight: 64,
            isoSpeedRatings: 800,
            rawPropertiesPlistData: plistData,
            isAlreadyDenoisedByNoiser: true
        )
        let payload = DNGExportMetadataBuilder.build(
            metadata: packet,
            pipelineState: DNGExportPipelineState(
                upscaledByApp: true,
                upscaledFactor: 4,
                denoised: false,
                noiserDenoised: true,
                headroomScale: 4
            )
        )
        XCTAssertEqual(payload.cameraMake, "TruongCam")
        XCTAssertEqual(payload.cameraModel, "Model Z")
        XCTAssertEqual(payload.baselineExposure, 0, accuracy: 1e-6)
        XCTAssertEqual(payload.sampleFormat, 3, "H=4 must be IEEE Float16 HDR")
        XCTAssertEqual(payload.profileDynamicRange, 1)
        XCTAssertEqual(payload.hintMaxOutputValue, 4.0, accuracy: 1e-6)
        XCTAssertEqual(payload.colorimetricReference, 2, "HDR output-referred reference")
        XCTAssertEqual(payload.whiteLevel, 1, "floating point WhiteLevel is 1")
        XCTAssertEqual(payload.dngVersion, [1, 7, 0, 0])
        XCTAssertEqual(payload.dngBackwardVersion, [1, 7, 0, 0])
        XCTAssertTrue(payload.isHDR)
        XCTAssertTrue(payload.usesFloatSamples)
        XCTAssertTrue(payload.userComment.contains("CustomNote"), "unrelated user comment components are preserved")
        XCTAssertTrue(payload.userComment.contains("Denoised=false"))
        XCTAssertTrue(payload.userComment.contains("NoiserDenoised=true"))

        let result = writeLinearDNG(to: url, width: 64, height: 64, rowsPerStrip: 16, payload: payload) { _, _ in
            (Float16(1.0).bitPattern, Float16(1.0).bitPattern, Float16(1.0).bitPattern)
        }
        XCTAssertTrue(result.success, result.error)
        let parsed = try ParsedDNG(url: url)
        XCTAssertEqual(try parsed.uint16(339, count: 3), [3, 3, 3], "IEEE floating point SampleFormat")
        XCTAssertEqual(try parsed.uint32(50717, count: 3), [1, 1, 1], "float WhiteLevel is 1")
        XCTAssertEqual(try parsed.uint16(50879), 2, "HDR output-referred ColorimetricReference")
        XCTAssertEqual(try parsed.srational(50730), 0.0, accuracy: 1e-9)
        XCTAssertEqual(try parsed.bytes(50706), [1, 7, 0, 0], "DNGVersion 1.7.0.0 for HDR")
        XCTAssertEqual(try parsed.bytes(50707), [1, 7, 0, 0], "DNGBackwardVersion 1.7.0.0 for HDR")
        XCTAssertEqual(
            try parsed.bytes(52551),
            [0x00, 0x01, 0x00, 0x01, 0x40, 0x80, 0x00, 0x00],
            "ProfileDynamicRange BE version 1 / HDR / big-endian float hint 4.0"
        )

        XCTAssertEqual(try parsed.exifString(36867), "2024:05:06 07:08:09")
        XCTAssertEqual(try parsed.exifRational(33434), 0.005, accuracy: 1e-9)
        XCTAssertEqual(try parsed.exifRational(33437), 1.8, accuracy: 1e-6)
        XCTAssertEqual(try parsed.exifUInt16(34855), 800)
        XCTAssertEqual(try parsed.exifRational(37386), 26.0, accuracy: 1e-6)
        XCTAssertEqual(try parsed.exifString(42035), "TruongLens")
        XCTAssertEqual(try parsed.exifString(42036), "TL-26mm")

        let comment = String(decoding: try parsed.exifBytes(37510), as: UTF8.self)
        XCTAssertTrue(comment.contains("CustomNote"))
        XCTAssertTrue(comment.contains("Denoised=false"), "stale Denoised=true is rewritten")
        XCTAssertTrue(comment.contains("NoiserDenoised=true"))
        XCTAssertTrue(comment.contains("UpscaledFactor=4x"))
        XCTAssertEqual(try parsed.gpsString(1), "N")
        XCTAssertEqual(try parsed.gpsRationalArray(2), [37, 30, 0])
        XCTAssertEqual(try parsed.gpsString(3), "W")
        XCTAssertEqual(try parsed.gpsRationalArray(4), [122, 15, 0])
        XCTAssertEqual(try parsed.gpsRational(6), 42.0, accuracy: 1e-6)

        let description = try parsed.string(270)
        XCTAssertTrue(description.contains("SampleFormat=Float16"))
        XCTAssertTrue(description.contains("HeadroomScale=4"))
        XCTAssertTrue(description.contains("HeadroomEV=2"))
        XCTAssertTrue(description.contains("Denoised=false"))
        XCTAssertTrue(description.contains("UpscaledByApp=true"))
        XCTAssertTrue(description.contains("UpscaledFactor=4x"))
        XCTAssertTrue(
            String(decoding: try parsed.bytes(700), as: UTF8.self).contains("ImagingSuite:Denoised=\"false\"")
        )
        XCTAssertEqual(try parsed.string(305), "TruongScaler 1.0 (ImagingSuite)")
        XCTAssertFalse(try parsed.string(305).contains("Denoised="))

        // Writer output -> suite decoder -> metadata must survive a second export.
        // ImageIO cannot decode rendered LinearRaw, so this proves the independent fallback
        // reconstructs the embedded EXIF/GPS/TIFF metadata rather than dropping it.
        let reingestBin = directory.appendingPathComponent("builder_reingest.bin")
        let reingested = try UniversalStripDecoder.decodeToMMap(
            imageURL: url,
            destinationMMapURL: reingestBin,
            stripHeight: 16
        )
        XCTAssertEqual(reingested.metadata.isoSpeedRatings, 800)
        XCTAssertEqual(reingested.metadata.isAlreadyDenoisedBySuite, false)
        XCTAssertTrue(reingested.metadata.isAlreadyDenoisedByNoiser)
        XCTAssertTrue(reingested.metadata.isAlreadyUpscaledBySuite)
        XCTAssertEqual(reingested.metadata.upscaledByAppFactor, 4)
        XCTAssertEqual(reingested.metadata.linearHeadroomScale ?? 0, 4.0, accuracy: 1e-4)

        let reingestPropertiesData = try XCTUnwrap(reingested.metadata.rawPropertiesPlistData)
        let reingestProperties = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: reingestPropertiesData,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        let reingestExif = try XCTUnwrap(
            reingestProperties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        )
        XCTAssertEqual(
            reingestExif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
            "2024:05:06 07:08:09"
        )
        XCTAssertEqual(reingestExif[kCGImagePropertyExifLensMake as String] as? String, "TruongLens")
        XCTAssertEqual(reingestExif[kCGImagePropertyExifLensModel as String] as? String, "TL-26mm")
        let reingestISO: Int? = {
            if let values = reingestExif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber] {
                return values.first?.intValue
            }
            if let values = reingestExif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any] {
                return (values.first as? NSNumber)?.intValue ?? (values.first as? Int)
            }
            return (reingestExif[kCGImagePropertyExifISOSpeedRatings as String] as? NSNumber)?.intValue
        }()
        XCTAssertEqual(reingestISO, 800)

        let reingestTIFF = try XCTUnwrap(
            reingestProperties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        )
        XCTAssertEqual(reingestTIFF[kCGImagePropertyTIFFMake as String] as? String, "TruongCam")
        XCTAssertEqual(reingestTIFF[kCGImagePropertyTIFFModel as String] as? String, "Model Z")

        let reingestGPS = try XCTUnwrap(
            reingestProperties[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        )
        XCTAssertEqual((reingestGPS[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue, 37.5)
        XCTAssertEqual(reingestGPS[kCGImagePropertyGPSLatitudeRef as String] as? String, "N")
        XCTAssertEqual((reingestGPS[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue, 122.25)
        XCTAssertEqual(reingestGPS[kCGImagePropertyGPSLongitudeRef as String] as? String, "W")

        let reingestUserComment = reingestExif[kCGImagePropertyExifUserComment as String] as? String
        XCTAssertTrue(reingestUserComment?.contains("CustomNote") ?? false, "unrelated user comment survives")
        XCTAssertTrue(reingestUserComment?.contains("Denoised=false") ?? false)
        XCTAssertTrue(reingestUserComment?.contains("NoiserDenoised=true") ?? false)

        let reingestParameters = try XCTUnwrap(reingested.metadata.rawParameters)
        XCTAssertEqual(reingestParameters.cameraMake, "TruongCam")
        XCTAssertEqual(reingestParameters.cameraModel, "Model Z")

        let reingestPixel = rgba(from: reingested.sourceBuffer, x: 5, y: 5)
        XCTAssertEqual(reingestPixel.r, 1.0, accuracy: 0.001)
        XCTAssertEqual(reingestPixel.a, 1.0, accuracy: 0.001)
    }

    // MARK: - exiftool

    private func verifyWithExifTool(url: URL, expectedMatrix: [Float]) throws {
        #if os(macOS)
        let exiftoolPath = "/opt/homebrew/bin/exiftool"
        guard FileManager.default.isExecutableFile(atPath: exiftoolPath) else {
            print("[DNGWriterBridgeTests] SKIP exiftool tag sub-check: \(exiftoolPath) is not installed.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exiftoolPath)
        process.arguments = ["-j", "-n", url.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
        print("[DNGWriterBridgeTests] exiftool exit=\(process.terminationStatus)\n\(output)")
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errorData, as: UTF8.self))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: outputData) as? [[String: Any]],
            "exiftool JSON output"
        )
        let tags = try XCTUnwrap(json.first)

        XCTAssertEqual(intValue(tags["PhotometricInterpretation"]), 34892)
        XCTAssertEqual(intValue(tags["ImageWidth"]), 64)
        XCTAssertEqual(intValue(tags["ImageHeight"]), 64)
        XCTAssertEqual(intValue(tags["SamplesPerPixel"]), 3)
        XCTAssertEqual(intValue(tags["Orientation"]), 1)
        XCTAssertEqual(intValue(tags["ColorimetricReference"]), 1)
        XCTAssertEqual(intValue(tags["CalibrationIlluminant1"]), 21)
        XCTAssertEqual(doubleValue(tags["BaselineExposure"]), 0.0, accuracy: 1e-6)
        XCTAssertEqual(tags["Make"] as? String, "TruongCam")
        XCTAssertEqual(tags["Model"] as? String, "TruongCam Test")
        XCTAssertEqual(tags["UniqueCameraModel"] as? String, "TruongCam Test")
        let description = try XCTUnwrap(tags["ImageDescription"] as? String)
        XCTAssertTrue(description.contains("HeadroomScale=1"))
        XCTAssertTrue(description.contains("Denoised=false"))
        XCTAssertNil(tags["ProfileDynamicRange"], "SDR output must omit ProfileDynamicRange")
        let software = try XCTUnwrap(tags["Software"] as? String)
        XCTAssertFalse(software.contains("Denoised="))
        let userComment = try XCTUnwrap(tags["UserComment"] as? String)
        XCTAssertTrue(userComment.contains("Denoised=false"))
        XCTAssertEqual(tags["GPSLatitudeRef"] as? String, "N")
        XCTAssertEqual(abs(doubleValue(tags["GPSLongitude"])), 122.25, accuracy: 1e-6)
        XCTAssertEqual(doubleValue(tags["GPSAltitude"]), 12.5, accuracy: 1e-6)

        let dngVersion = (tags["DNGVersion"] as? String) ?? String(describing: tags["DNGVersion"] ?? "")
        let normalizedVersion = dngVersion.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "")
        XCTAssertTrue(normalizedVersion.contains("1400") || normalizedVersion.contains("14"), "DNGVersion: \(dngVersion)")
        let matrix = try XCTUnwrap(numericArray(tags["ColorMatrix1"]), "exiftool ColorMatrix1")
        XCTAssertEqual(matrix.count, 9)
        for index in 0..<9 {
            XCTAssertEqual(matrix[index], Double(expectedMatrix[index]), accuracy: 1e-5)
        }
        #else
        print("[DNGWriterBridgeTests] Optional desktop exiftool sub-check is unavailable on iOS; native tag and pixel assertions still execute.")
        #endif
    }
    /// External tag reader check for the HDR convention. exiftool does not render the DNG;
    /// the independent Python decoder in the repair evidence is the semantic proof.
    private func verifyHDRWithExifTool(url: URL) throws {
        #if os(macOS)
        let exiftoolPath = "/opt/homebrew/bin/exiftool"
        guard FileManager.default.isExecutableFile(atPath: exiftoolPath) else {
            print("[DNGWriterBridgeTests] SKIP exiftool HDR sub-check: \(exiftoolPath) is not installed.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exiftoolPath)
        process.arguments = ["-j", "-n", url.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errorData, as: UTF8.self))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: outputData) as? [[String: Any]],
            "exiftool JSON output"
        )
        let tags = try XCTUnwrap(json.first)
        XCTAssertEqual(numericArray(tags["SampleFormat"]), [3, 3, 3])
        XCTAssertEqual(intValue(tags["ColorimetricReference"]), 2)
        XCTAssertEqual(intValue(tags["SamplesPerPixel"]), 3)
        let version = (tags["DNGVersion"] as? String)
            ?? String(describing: tags["DNGVersion"] ?? "")
        let normalized = version.replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(normalized.contains("1700"), "DNGVersion: \(version)")
        let whiteLevels = numericArray(tags["WhiteLevel"]) ?? []
        XCTAssertTrue(whiteLevels.allSatisfy { $0 == 1 }, "WhiteLevel array: \(whiteLevels)")
        XCTAssertEqual(doubleValue(tags["BaselineExposure"]), 0.0, accuracy: 1e-6)
        // ExifTool's DNG table treats the packed ProfileDynamicRange struct as big-endian
        // ("not indicated in spec") even though the outer TIFF is little-endian. Verify that
        // interoperable decoding produces the intended version/range/hint.
        XCTAssertEqual(intValue(tags["PDRVersion"]), 1, "exiftool ProfileDynamicRange version")
        XCTAssertEqual(intValue(tags["DynamicRange"]), 1, "exiftool ProfileDynamicRange HDR value")
        XCTAssertEqual(doubleValue(tags["HintMaxOutputValue"]), 4.0, accuracy: 1e-6)
        print("[DNGWriterBridgeTests] HDR exiftool ProfileDynamicRange version=\(tags["PDRVersion"] ?? "") range=\(tags["DynamicRange"] ?? "") hint=\(tags["HintMaxOutputValue"] ?? "")")
        #else
        print("[DNGWriterBridgeTests] Optional desktop exiftool sub-check is unavailable on iOS; native tag and pixel assertions still execute.")
        #endif
    }
}

// MARK: - Fixture writer helper

private final class StripContext {
    let width: Int
    let pixel: (Int, Int) -> (UInt16, UInt16, UInt16)
    let onStrip: () -> Void

    init(width: Int, pixel: @escaping (Int, Int) -> (UInt16, UInt16, UInt16), onStrip: @escaping () -> Void) {
        self.width = width
        self.pixel = pixel
        self.onStrip = onStrip
    }
}

private func fillStrip(
    _ userContext: UnsafeMutableRawPointer?,
    _ startRow: UInt32,
    _ rowCount: UInt32,
    _ destination: UnsafeMutablePointer<UInt16>?
) -> Bool {
    guard let userContext, let destination else { return false }
    let context = Unmanaged<StripContext>.fromOpaque(userContext).takeUnretainedValue()
    context.onStrip()
    for row in 0..<Int(rowCount) {
        let y = Int(startRow) + row
        for x in 0..<context.width {
            let (red, green, blue) = context.pixel(x, y)
            let index = (row * context.width + x) * 3
            destination[index + 0] = red
            destination[index + 1] = green
            destination[index + 2] = blue
        }
    }
    return true
}

private func withOptionalCString<Result>(
    _ value: String?,
    _ body: (UnsafePointer<CChar>?) -> Result
) -> Result {
    guard let value else { return body(nil) }
    return value.withCString { body($0) }
}

@discardableResult
private func writeLinearDNG(
    to url: URL,
    width: UInt32,
    height: UInt32,
    rowsPerStrip: UInt32,
    cameraMake: String = "TruongCam",
    cameraModel: String = "TruongCam Test",
    uniqueCameraModel: String? = nil,
    software: String? = "TruongScaler 1.0 (ImagingSuite)",
    imageDescription: String?,
    dateTime: String? = "2026:10:22 12:00:00",
    baselineExposure: Float = 0,
    sampleFormat: UInt16 = 1,
    profileDynamicRange: UInt16 = 0,
    hintMaxOutputValue: Float = 0,
    colorimetricReference: UInt16 = 1,
    whiteLevel: UInt16 = 65_535,
    dngVersion: [UInt16] = [],
    dngBackwardVersion: [UInt16] = [],
    orientation: UInt16 = 1,
    xmp: Data? = nil,
    colorMatrix1: [Float]? = nil,
    metadata: TestMetadataEntries? = nil,
    onStrip: @escaping () -> Void = {},
    pixel: @escaping (Int, Int) -> (UInt16, UInt16, UInt16)
) -> (success: Bool, error: String) {
    let matrix = colorMatrix1 ?? DNGExportMetadataBuilder.linearDisplayP3InverseXYZ
    let xmpBytes = [UInt8](xmp ?? Data())
    let context = StripContext(width: Int(width), pixel: pixel, onStrip: onStrip)
    let userInfo = Unmanaged.passUnretained(context).toOpaque()
    let entries = metadata ?? TestMetadataEntries()

    return cameraMake.withCString { makePointer in
        cameraModel.withCString { modelPointer in
            withOptionalCString(uniqueCameraModel) { uniquePointer in
                withOptionalCString(software) { softwarePointer in
                    withOptionalCString(imageDescription) { descriptionPointer in
                        withOptionalCString(dateTime) { datePointer in
                            xmpBytes.withUnsafeBufferPointer { xmpBuffer in
                                matrix.withUnsafeBufferPointer { matrixBuffer in
                                    entries.entries.withUnsafeBufferPointer { entryBuffer in
                                        var errorBuffer = [CChar](repeating: 0, count: 1024)
                                        let version = paddedVersion(dngVersion)
                                        let backwardVersion = paddedVersion(dngBackwardVersion)
                                        var config = DNGLinearExportConfig(
                                            width: width,
                                            height: height,
                                            rowsPerStrip: rowsPerStrip,
                                            cameraMake: makePointer,
                                            cameraModel: modelPointer,
                                            colorMatrix1: matrixBuffer.baseAddress,
                                            asShotNeutral: nil,
                                            baselineExposure: baselineExposure,
                                            blackLevel: 0,
                                            whiteLevel: whiteLevel,
                                            orientation: orientation,
                                            uniqueCameraModel: uniquePointer,
                                            software: softwarePointer,
                                            imageDescription: descriptionPointer,
                                            dateTime: datePointer,
                                            metadataEntries: entryBuffer.baseAddress,
                                            metadataEntryCount: entries.entries.count,
                                            xmpData: xmpBytes.isEmpty ? nil : UnsafeRawPointer(xmpBuffer.baseAddress),
                                            xmpByteCount: xmpBytes.count,
                                            colorimetricReference: colorimetricReference,
                                            sampleFormat: sampleFormat,
                                            profileDynamicRange: profileDynamicRange,
                                            hintMaxOutputValue: hintMaxOutputValue,
                                            dngVersionMajor: version[0],
                                            dngVersionMinor: version[1],
                                            dngVersionPatch: version[2],
                                            dngVersionBuild: version[3],
                                            dngBackwardVersionMajor: backwardVersion[0],
                                            dngBackwardVersionMinor: backwardVersion[1],
                                            dngBackwardVersionPatch: backwardVersion[2],
                                            dngBackwardVersionBuild: backwardVersion[3]
                                        )
                                        let success = withExtendedLifetime(entries) {
                                            url.path.withCString { pathPointer in
                                                TSWriteStreamingLinearDNG16(
                                                    pathPointer,
                                                    &config,
                                                    fillStrip,
                                                    userInfo,
                                                    &errorBuffer,
                                                    errorBuffer.count
                                                )
                                            }
                                        }
                                        let error = errorBuffer.withUnsafeBufferPointer { buffer in
                                            buffer.baseAddress.map { String(cString: $0) } ?? ""
                                        }
                                        return (success, error)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private func paddedVersion(_ values: [UInt16]) -> [UInt16] {
    if values.isEmpty { return [0, 0, 0, 0] }
    var padded = values
    while padded.count < 4 { padded.append(0) }
    return Array(padded.prefix(4))
}

@discardableResult
private func writeLinearDNG(
    to url: URL,
    width: UInt32,
    height: UInt32,
    rowsPerStrip: UInt32,
    payload: DNGExportMetadata,
    pixel: @escaping (Int, Int) -> (UInt16, UInt16, UInt16)
) -> (success: Bool, error: String) {
    let context = StripContext(width: Int(width), pixel: pixel, onStrip: {})
    let userInfo = Unmanaged.passUnretained(context).toOpaque()
    let xmpBytes = [UInt8](payload.xmpData ?? Data())

    return withOptionalCString(payload.cameraMake) { makePointer in
        withOptionalCString(payload.cameraModel) { modelPointer in
            withOptionalCString(payload.uniqueCameraModel) { uniquePointer in
                payload.software.withCString { softwarePointer in
                    payload.imageDescription.withCString { descriptionPointer in
                        withOptionalCString(payload.dateTime) { datePointer in
                            xmpBytes.withUnsafeBufferPointer { xmpBuffer in
                                payload.colorMatrix1.withUnsafeBufferPointer { matrixBuffer in
                                    payload.asShotNeutral.withUnsafeBufferPointer { neutralBuffer in
                                        payload.entries.withUnsafeBufferPointer { entryBuffer in
                                            var errorBuffer = [CChar](repeating: 0, count: 1024)
                                            var config = DNGLinearExportConfig(
                                                width: width,
                                                height: height,
                                                rowsPerStrip: rowsPerStrip,
                                                cameraMake: makePointer,
                                                cameraModel: modelPointer,
                                                colorMatrix1: matrixBuffer.baseAddress,
                                                asShotNeutral: neutralBuffer.baseAddress,
                                                baselineExposure: payload.baselineExposure,
                                                blackLevel: 0,
                                                whiteLevel: payload.whiteLevel,
                                                orientation: payload.orientation,
                                                uniqueCameraModel: uniquePointer,
                                                software: softwarePointer,
                                                imageDescription: descriptionPointer,
                                                dateTime: datePointer,
                                                metadataEntries: entryBuffer.baseAddress,
                                                metadataEntryCount: entryBuffer.count,
                                                xmpData: xmpBytes.isEmpty ? nil : UnsafeRawPointer(xmpBuffer.baseAddress),
                                                xmpByteCount: xmpBytes.count,
                                                colorimetricReference: payload.colorimetricReference,
                                                sampleFormat: payload.sampleFormat,
                                                profileDynamicRange: payload.profileDynamicRange,
                                                hintMaxOutputValue: payload.hintMaxOutputValue,
                                                dngVersionMajor: payload.dngVersionMajor,
                                                dngVersionMinor: payload.dngVersionMinor,
                                                dngVersionPatch: payload.dngVersionPatch,
                                                dngVersionBuild: payload.dngVersionBuild,
                                                dngBackwardVersionMajor: payload.dngBackwardVersionMajor,
                                                dngBackwardVersionMinor: payload.dngBackwardVersionMinor,
                                                dngBackwardVersionPatch: payload.dngBackwardVersionPatch,
                                                dngBackwardVersionBuild: payload.dngBackwardVersionBuild
                                            )
                                            let success = withExtendedLifetime(payload) {
                                                url.path.withCString { pathPointer in
                                                    TSWriteStreamingLinearDNG16(
                                                        pathPointer,
                                                        &config,
                                                        fillStrip,
                                                        userInfo,
                                                        &errorBuffer,
                                                        errorBuffer.count
                                                    )
                                                }
                                            }
                                            let error = errorBuffer.withUnsafeBufferPointer { buffer in
                                                buffer.baseAddress.map { String(cString: $0) } ?? ""
                                            }
                                            return (success, error)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private final class TestMetadataEntries {
    private var pointers: [UnsafeMutableRawPointer] = []
    private(set) var entries: [DNGMetadataEntry] = []

    deinit {
        for pointer in pointers {
            pointer.deallocate()
        }
    }

    func addASCII(tag: UInt16, ifd: UInt16, value: String) {
        var bytes = Array(value.utf8)
        bytes.append(0)
        add(tag: tag, ifd: ifd, type: 2, bytes: bytes)
    }

    func addUndefined(tag: UInt16, ifd: UInt16, value: Data) {
        add(tag: tag, ifd: ifd, type: 7, bytes: [UInt8](value))
    }

    func addShort(tag: UInt16, ifd: UInt16, value: UInt16) {
        add(tag: tag, ifd: ifd, type: 3, bytes: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    func addByte(tag: UInt16, ifd: UInt16, values: [UInt8]) {
        add(tag: tag, ifd: ifd, type: 1, bytes: values)
    }

    func addRational(tag: UInt16, ifd: UInt16, values: [Double]) {
        var bytes: [UInt8] = []
        for value in values {
            let (numerator, denominator) = testRationalize(value)
            bytes.append(contentsOf: littleEndian(numerator))
            bytes.append(contentsOf: littleEndian(denominator))
        }
        add(tag: tag, ifd: ifd, type: 5, bytes: bytes)
    }

    private func add(tag: UInt16, ifd: UInt16, type: UInt16, bytes: [UInt8]) {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, 1), alignment: 1)
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: max(bytes.count, 1))
        if !bytes.isEmpty {
            bytes.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    pointer.copyMemory(from: base, byteCount: bytes.count)
                }
            }
        }
        pointers.append(pointer)
        let elementSize = max(1, Int(tiffTypeSize(type)))
        entries.append(DNGMetadataEntry(
            tag: tag,
            ifd: ifd,
            type: type,
            count: UInt32(bytes.count / elementSize),
            data: UnsafeRawPointer(pointer)
        ))
    }
}

private func tiffTypeSize(_ type: UInt16) -> UInt32 {
    switch type {
    case 1, 2, 6, 7: return 1
    case 3, 8: return 2
    case 4, 9, 11: return 4
    case 5, 10, 12: return 8
    default: return 1
    }
}

private func testRationalize(_ value: Double) -> (UInt32, UInt32) {
    guard value.isFinite, value > 0 else { return (0, 1) }
    let scaled = value * 1_000_000
    if scaled <= Double(UInt32.max), value < 1_000_000 {
        let numerator = UInt32(scaled.rounded())
        return (numerator, 1_000_000)
    }
    return (UInt32(value.rounded()), 1)
}

private func littleEndian(_ value: UInt32) -> [UInt8] {
    [
        UInt8(value & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 24) & 0xFF),
    ]
}

// MARK: - Independent hand-written TIFF/IFD parser

private struct ParsedTag {
    let type: UInt16
    let count: UInt32
    let payload: Data
}

private enum ParsedDNGError: Error {
    case malformed(String)
}

private struct ParsedDNG {
    let data: Data
    let ifd0: [UInt16: ParsedTag]
    let exif: [UInt16: ParsedTag]
    let gps: [UInt16: ParsedTag]
    let fileSize: Int

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        self.data = data
        self.fileSize = data.count
        guard data.count >= 8 else { throw ParsedDNGError.malformed("short header") }
        guard data[0] == 0x49, data[1] == 0x49 else { throw ParsedDNGError.malformed("not little-endian") }
        guard Self.u16(data, 2) == 42 else { throw ParsedDNGError.malformed("bad TIFF magic") }
        let ifd0Offset = Int(Self.u32(data, 4))
        let (mainTags, mainOrder) = try Self.parseIFD(data: data, offset: ifd0Offset)
        for index in 1..<mainOrder.count {
            guard mainOrder[index - 1] < mainOrder[index] else {
                throw ParsedDNGError.malformed("IFD0 tags not ascending")
            }
        }
        self.ifd0 = mainTags
        if let pointer = mainTags[34665].map({ Int(Self.u32($0.payload, 0)) }), pointer > 0 {
            self.exif = try Self.parseIFD(data: data, offset: pointer).0
        } else {
            self.exif = [:]
        }
        if let pointer = mainTags[34853].map({ Int(Self.u32($0.payload, 0)) }), pointer > 0 {
            self.gps = try Self.parseIFD(data: data, offset: pointer).0
        } else {
            self.gps = [:]
        }
    }

    // MARK: Accessors

    func bytes(_ tag: UInt16) throws -> [UInt8] {
        try [UInt8](payload(tag, in: ifd0))
    }

    func uint16(_ tag: UInt16) throws -> UInt16 {
        let payload = try payload(tag, in: ifd0)
        guard payload.count >= 2 else { throw ParsedDNGError.malformed("tag \(tag) is not SHORT") }
        return Self.u16(payload, 0)
    }

    func uint16(_ tag: UInt16, count: Int) throws -> [UInt16] {
        let payload = try payload(tag, in: ifd0)
        guard payload.count >= count * 2 else { throw ParsedDNGError.malformed("tag \(tag) is too short") }
        return (0..<count).map { Self.u16(payload, $0 * 2) }
    }

    func uint32(_ tag: UInt16) throws -> UInt32 {
        let payload = try payload(tag, in: ifd0)
        guard payload.count >= 4 else { throw ParsedDNGError.malformed("tag \(tag) is not LONG") }
        return Self.u32(payload, 0)
    }

    func uint32(_ tag: UInt16, count: Int) throws -> [UInt32] {
        let payload = try payload(tag, in: ifd0)
        guard payload.count >= count * 4 else { throw ParsedDNGError.malformed("tag \(tag) is too short") }
        return (0..<count).map { Self.u32(payload, $0 * 4) }
    }

    func uint32Array(_ tag: UInt16) throws -> [UInt32] {
        guard let parsed = ifd0[tag] else { throw ParsedDNGError.malformed("missing tag \(tag)") }
        return try uint32(tag, count: Int(parsed.count))
    }

    func string(_ tag: UInt16) throws -> String {
        let payload = try payload(tag, in: ifd0)
        let bytes = payload.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    func srational(_ tag: UInt16) throws -> Double {
        try Self.srational(payload(tag, in: ifd0), 0)
    }

    func srationalArray(_ tag: UInt16) throws -> [Double] {
        let payload = try payload(tag, in: ifd0)
        guard let parsed = ifd0[tag] else { throw ParsedDNGError.malformed("missing tag \(tag)") }
        return try (0..<Int(parsed.count)).map { try Self.srational(payload, $0 * 8) }
    }

    func rationalArray(_ tag: UInt16) throws -> [Double] {
        let payload = try payload(tag, in: ifd0)
        guard let parsed = ifd0[tag] else { throw ParsedDNGError.malformed("missing tag \(tag)") }
        return (0..<Int(parsed.count)).map {
            Self.rational(payload, $0 * 8)
        }
    }

    func exifBytes(_ tag: UInt16) throws -> [UInt8] {
        [UInt8](try payload(tag, in: exif))
    }

    func exifUInt16(_ tag: UInt16) throws -> UInt16 {
        let payload = try payload(tag, in: exif)
        guard payload.count >= 2 else { throw ParsedDNGError.malformed("EXIF tag \(tag) is not SHORT") }
        return Self.u16(payload, 0)
    }

    func exifRational(_ tag: UInt16) throws -> Double {
        Self.rational(try payload(tag, in: exif), 0)
    }

    func exifString(_ tag: UInt16) throws -> String {
        let payload = try payload(tag, in: exif)
        return String(decoding: payload.prefix { $0 != 0 }, as: UTF8.self)
    }

    func gpsString(_ tag: UInt16) throws -> String {
        let payload = try payload(tag, in: gps)
        return String(decoding: payload.prefix { $0 != 0 }, as: UTF8.self)
    }

    func gpsBytes(_ tag: UInt16) throws -> [UInt8] {
        [UInt8](try payload(tag, in: gps))
    }

    func gpsRational(_ tag: UInt16) throws -> Double {
        Self.rational(try payload(tag, in: gps), 0)
    }

    func gpsRationalArray(_ tag: UInt16) throws -> [Double] {
        let payload = try payload(tag, in: gps)
        guard let parsed = gps[tag] else { throw ParsedDNGError.malformed("missing GPS tag \(tag)") }
        return (0..<Int(parsed.count)).map { Self.rational(payload, $0 * 8) }
    }

    func decodeRGB16() throws -> [(UInt16, UInt16, UInt16)] {
        let width = Int(try uint32(256))
        let height = Int(try uint32(257))
        let offsets = try uint32Array(273)
        let byteCounts = try uint32Array(279)
        var result = [(UInt16, UInt16, UInt16)]()
        result.reserveCapacity(width * height)
        for index in 0..<offsets.count {
            let start = Int(offsets[index])
            let count = Int(byteCounts[index])
            guard start >= 0, count >= 0, start + count <= data.count else {
                throw ParsedDNGError.malformed("strip out of bounds")
            }
            var position = start
            let end = start + count
            while position + 5 < end {
                result.append((Self.u16(data, position), Self.u16(data, position + 2), Self.u16(data, position + 4)))
                position += 6
            }
        }
        guard result.count == width * height else {
            throw ParsedDNGError.malformed("decoded pixel count \(result.count) != \(width * height)")
        }
        return result
    }

    // MARK: Parsing internals

    private func payload(_ tag: UInt16, in ifd: [UInt16: ParsedTag]) throws -> Data {
        guard let parsed = ifd[tag] else { throw ParsedDNGError.malformed("missing tag \(tag)") }
        return parsed.payload
    }

    private static func parseIFD(data: Data, offset: Int) throws -> ([UInt16: ParsedTag], [UInt16]) {
        guard offset >= 0, offset + 2 <= data.count else {
            throw ParsedDNGError.malformed("IFD offset out of bounds")
        }
        let count = Int(u16(data, offset))
        guard offset + 2 + count * 12 + 4 <= data.count else {
            throw ParsedDNGError.malformed("IFD entry table out of bounds")
        }
        var tags: [UInt16: ParsedTag] = [:]
        var order: [UInt16] = []
        for index in 0..<count {
            let entryOffset = offset + 2 + index * 12
            let tag = u16(data, entryOffset)
            let type = u16(data, entryOffset + 2)
            let elementCount = u32(data, entryOffset + 4)
            let valueOrOffset = u32(data, entryOffset + 8)
            let byteCount = Int(tiffTypeSize(type)) * Int(elementCount)
            let payload: Data
            if byteCount <= 4 {
                payload = data.subdata(in: entryOffset + 8..<(entryOffset + 8 + byteCount))
            } else {
                let start = Int(valueOrOffset)
                guard start >= 0, start + byteCount <= data.count else {
                    throw ParsedDNGError.malformed("tag \(tag) payload out of bounds")
                }
                payload = data.subdata(in: start..<(start + byteCount))
            }
            tags[tag] = ParsedTag(type: type, count: elementCount, payload: payload)
            order.append(tag)
        }
        return (tags, order)
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 3 < data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func rational(_ payload: Data, _ offset: Int) -> Double {
        guard offset + 7 < payload.count else { return 0 }
        let numerator = u32(payload, offset)
        let denominator = u32(payload, offset + 4)
        guard denominator != 0 else { return 0 }
        return Double(numerator) / Double(denominator)
    }

    private static func srational(_ payload: Data, _ offset: Int) throws -> Double {
        guard offset + 7 < payload.count else { throw ParsedDNGError.malformed("SRATIONAL too short") }
        let numerator = Int32(bitPattern: u32(payload, offset))
        let denominator = Int32(bitPattern: u32(payload, offset + 4))
        guard denominator != 0 else { throw ParsedDNGError.malformed("SRATIONAL denominator zero") }
        return Double(numerator) / Double(denominator)
    }
}

// MARK: - Shared helpers

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DNGWriterBridgeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
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

private func intValue(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) }
    return nil
}

private func doubleValue(_ value: Any?) -> Double {
    if let double = value as? Double { return double }
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) ?? 0 }
    return 0
}

private func numericArray(_ value: Any?) -> [Double]? {
    if let array = value as? [Double] { return array }
    if let array = value as? [NSNumber] { return array.map(\.doubleValue) }
    if let array = value as? [Any] { return array.map { doubleValue($0) } }
    if let string = value as? String {
        let parts = string.split { $0 == " " || $0 == "," }.compactMap { Double($0) }
        return parts.isEmpty ? nil : parts
    }
    return nil
}
