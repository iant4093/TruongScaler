import Foundation
import MMapCanvas
import TruongScalerCore

/// Embedded capture metadata recovered from the suite writer's IFD0/EXIF/GPS structures.
///
/// ImageIO does not decode a rendered LinearRaw DNG on this SDK, so the suite reingest path must
/// recover the standard metadata from the TIFF IFDs directly. This is the subset the writer emits.
public struct LinearDNGEmbeddedMetadata: Sendable, Equatable {
    public let cameraMake: String?
    public let cameraModel: String?
    public let dateTime: String?
    public let dateTimeOriginal: String?
    public let dateTimeDigitized: String?
    public let exposureTime: Double?
    public let fNumber: Double?
    public let iso: Int?
    public let focalLength: Double?
    public let lensMake: String?
    public let lensModel: String?
    public let userComment: String?
    public let gpsLatitude: Double?
    public let gpsLatitudeRef: String?
    public let gpsLongitude: Double?
    public let gpsLongitudeRef: String?
    public let gpsAltitude: Double?
    public let gpsAltitudeRef: Int?

    public init(
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        dateTime: String? = nil,
        dateTimeOriginal: String? = nil,
        dateTimeDigitized: String? = nil,
        exposureTime: Double? = nil,
        fNumber: Double? = nil,
        iso: Int? = nil,
        focalLength: Double? = nil,
        lensMake: String? = nil,
        lensModel: String? = nil,
        userComment: String? = nil,
        gpsLatitude: Double? = nil,
        gpsLatitudeRef: String? = nil,
        gpsLongitude: Double? = nil,
        gpsLongitudeRef: String? = nil,
        gpsAltitude: Double? = nil,
        gpsAltitudeRef: Int? = nil
    ) {
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.dateTime = dateTime
        self.dateTimeOriginal = dateTimeOriginal
        self.dateTimeDigitized = dateTimeDigitized
        self.exposureTime = exposureTime
        self.fNumber = fNumber
        self.iso = iso
        self.focalLength = focalLength
        self.lensMake = lensMake
        self.lensModel = lensModel
        self.userComment = userComment
        self.gpsLatitude = gpsLatitude
        self.gpsLatitudeRef = gpsLatitudeRef
        self.gpsLongitude = gpsLongitude
        self.gpsLongitudeRef = gpsLongitudeRef
        self.gpsAltitude = gpsAltitude
        self.gpsAltitudeRef = gpsAltitudeRef
    }
}

/// Read-only, suite-marker summary of a little-endian TIFF/DNG file.
/// Produced by `LinearDNGTIFFReader.probe(imageURL:)` without decoding pixels.
public struct LinearDNGFileInfo: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let photometricInterpretation: Int
    public let orientation: Int
    public let bitsPerSample: [Int]
    public let samplesPerPixel: Int
    public let imageDescription: String?
    public let software: String?
    public let baselineExposure: Float?
    public let headroomScaleFromDescription: Float?
    /// DNGVersion (tag 50706) bytes, or nil when absent.
    public let dngVersion: [Int]?
    /// DNGBackwardVersion (tag 50707) bytes, or nil when absent.
    public let dngBackwardVersion: [Int]?
    /// ColorimetricReference (tag 50879): 1 = perceptual SDR, 2 = output-referred HDR.
    public let colorimetricReference: Int?
    /// TIFF SampleFormat (tag 339), one entry per sample: 1 = unsigned integer, 3 = IEEE float.
    public let sampleFormat: [Int]
    /// WhiteLevel (tag 50717) first sample, or nil when absent.
    public let whiteLevel: Int?
    /// ProfileDynamicRange (tag 52551) version, and DynamicRange value (0 SDR / 1 HDR).
    public let profileDynamicRangeVersion: Int?
    public let profileDynamicRangeValue: Int?
    /// ProfileDynamicRange `HintMaxOutputValue` (linear-gamma absolute peak), when present.
    public let profileDynamicRangeHint: Float?
    /// Standard capture metadata recovered from the writer's IFD0/EXIF/GPS tags.
    public let embeddedMetadata: LinearDNGEmbeddedMetadata?

    public init(
        width: Int,
        height: Int,
        photometricInterpretation: Int,
        orientation: Int,
        bitsPerSample: [Int],
        samplesPerPixel: Int,
        imageDescription: String?,
        software: String?,
        baselineExposure: Float?,
        headroomScaleFromDescription: Float?,
        embeddedMetadata: LinearDNGEmbeddedMetadata? = nil,
        dngVersion: [Int]? = nil,
        dngBackwardVersion: [Int]? = nil,
        colorimetricReference: Int? = nil,
        sampleFormat: [Int] = [],
        whiteLevel: Int? = nil,
        profileDynamicRangeVersion: Int? = nil,
        profileDynamicRangeValue: Int? = nil,
        profileDynamicRangeHint: Float? = nil
    ) {
        self.width = width
        self.height = height
        self.photometricInterpretation = photometricInterpretation
        self.orientation = orientation
        self.bitsPerSample = bitsPerSample
        self.samplesPerPixel = samplesPerPixel
        self.imageDescription = imageDescription
        self.software = software
        self.baselineExposure = baselineExposure
        self.headroomScaleFromDescription = headroomScaleFromDescription
        self.embeddedMetadata = embeddedMetadata
        self.dngVersion = dngVersion
        self.dngBackwardVersion = dngBackwardVersion
        self.colorimetricReference = colorimetricReference
        self.sampleFormat = sampleFormat
        self.whiteLevel = whiteLevel
        self.profileDynamicRangeVersion = profileDynamicRangeVersion
        self.profileDynamicRangeValue = profileDynamicRangeValue
        self.profileDynamicRangeHint = profileDynamicRangeHint
    }
}

/// Result of the independent strip decode of a suite rendered Linear DNG.
public struct LinearDNGTIFFDecodeResult: Sendable {
    public let width: Int
    public let height: Int
    /// Headroom telemetry `H`: the HDR `HintMaxOutputValue` (or measured peak fallback) for
    /// floating-point files, `2^BaselineExposure` for legacy integer files, and 1 for new SDR.
    public let headroomScale: Float
    public let baselineExposure: Float
    public let globalMaxLinearComponent: Float
    public let globalMaxLuminance: Float
    public let stripCount: Int
    /// TIFF SampleFormat: 1 = unsigned integer, 3 = IEEE float.
    public let sampleFormat: Int
    public let isFloat: Bool
    /// True only for legacy integer files that encoded overrange as `q/65535 * 2^BaselineExposure`.
    public let isLegacyIntegerHeadroom: Bool
    public let colorimetricReference: Int
    public let dngVersion: [Int]
    public let whiteLevel: Int
    public let profileDynamicRangeHint: Float?
    public let profileDynamicRangeValue: Int?

    public init(
        width: Int,
        height: Int,
        headroomScale: Float,
        baselineExposure: Float,
        globalMaxLinearComponent: Float,
        globalMaxLuminance: Float,
        stripCount: Int,
        sampleFormat: Int = 1,
        isFloat: Bool = false,
        isLegacyIntegerHeadroom: Bool = false,
        colorimetricReference: Int = 1,
        dngVersion: [Int] = [1, 4, 0, 0],
        whiteLevel: Int = 65_535,
        profileDynamicRangeHint: Float? = nil,
        profileDynamicRangeValue: Int? = nil
    ) {
        self.width = width
        self.height = height
        self.headroomScale = headroomScale
        self.baselineExposure = baselineExposure
        self.globalMaxLinearComponent = globalMaxLinearComponent
        self.globalMaxLuminance = globalMaxLuminance
        self.stripCount = stripCount
        self.sampleFormat = sampleFormat
        self.isFloat = isFloat
        self.isLegacyIntegerHeadroom = isLegacyIntegerHeadroom
        self.colorimetricReference = colorimetricReference
        self.dngVersion = dngVersion
        self.whiteLevel = whiteLevel
        self.profileDynamicRangeHint = profileDynamicRangeHint
        self.profileDynamicRangeValue = profileDynamicRangeValue
    }
}

/// Pure-Swift, little-endian TIFF/IFD strip reader for rendered suite LinearRaw DNGs
/// (`docs/DEVELOPMENT.md`).
///
/// This is deliberately independent of the C++ writer: it parses the file bytes directly and
/// streams uncompressed 16-bit chunky RGB strips into a destination `MMapBuffer` as
/// `Float16` RGBA (`alpha = 1`), scaling by `H = 2^BaselineExposure` (or the
/// `HeadroomScale=` marker when BaselineExposure is absent).
///
/// Supported subset (anything else is rejected with `ScalerError.metadataExtractionFailed`
/// or `ScalerError.stripDecodingFailed`):
/// - classic little-endian TIFF (`II`, magic 42); BigTIFF is not supported
/// - `Compression = 1`, `PhotometricInterpretation = 34892` (LinearRaw), `Orientation = 1`
/// - `BitsPerSample = {16,16,16}`, `SampleFormat = {1,1,1}`, 3 chunky samples
/// - strip offsets/byte counts, BlackLevel/WhiteLevel, BaselineExposure
///
/// Camera RAW/ProRAW files keep the `CIRAWFilter` path in `UniversalStripDecoder`.
public enum LinearDNGTIFFReader {
    /// Decodes a suite Linear DNG into `destinationMMapURL`.
    ///
    /// The source file is never modified and no sidecar/auxiliary data is written. Every
    /// attacker-controlled size (width, height, rows-per-strip, strip counts/offsets, row and
    /// total byte counts) is validated with checked arithmetic and file-size-derived bounds
    /// **before** any seek, allocation, mmap, stride or strip arithmetic. Impossible geometry
    /// throws `ScalerError.metadataExtractionFailed` / `.stripDecodingFailed`; it never traps.
    ///
    /// The destination row buffer is written directly through the `MMapBuffer` mapping so only
    /// one strip-sized input buffer is materialized at a time. A pre-existing destination is
    /// never the target of a malformed-file decode (all input validation happens first).
    @discardableResult
    public static func decode(
        imageURL: URL,
        destinationMMapURL: URL,
        stripHeight: Int = UniversalStripDecoder.defaultStripHeight,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) throws -> LinearDNGTIFFDecodeResult {
        guard !aliasesDestination(sourceURL: imageURL, destinationURL: destinationMMapURL) else {
            throw ScalerError.stripDecodingFailed(
                stripIndex: 0,
                rectDescription: "Source DNG and mmap destination must refer to different files"
            )
        }

        let fileSize = try regularFileSize(imageURL)
        guard fileSize >= 8 else { throw ScalerError.metadataExtractionFailed }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: imageURL)
        } catch {
            throw ScalerError.fileNotFound(imageURL)
        }
        defer { try? handle.close() }

        let header = try parseDirectory(handle: handle, fileSize: fileSize)
        let width = try requiredPositiveInt(header: header, tag: 256, name: "ImageWidth")
        let height = try requiredPositiveInt(header: header, tag: 257, name: "ImageLength")

        // ---- Sample representation (R8): integer UInt16 SDR or IEEE Float 16/32 HDR ----
        let bitsValues = try optionalSampleValues(header: header, tag: 258) ?? []
        let bitsTriple = try normalizedTriple(
            bitsValues,
            defaultValue: [16, 16, 16],
            name: "BitsPerSample"
        )
        let bitsPerSample = bitsTriple[0]
        let sampleFormatValues = try optionalSampleValues(header: header, tag: 339) ?? []
        let sampleFormatTriple = try normalizedTriple(
            sampleFormatValues,
            defaultValue: [1, 1, 1],
            name: "SampleFormat"
        )
        let sampleFormat = sampleFormatTriple[0]
        guard sampleFormat == 1 || sampleFormat == 3 else {
            throw ScalerError.metadataExtractionFailed
        }
        let isFloat = sampleFormat == 3
        if isFloat {
            guard bitsPerSample == 16 || bitsPerSample == 32 else {
                throw ScalerError.metadataExtractionFailed
            }
        } else {
            guard bitsPerSample == 16 else {
                throw ScalerError.metadataExtractionFailed
            }
        }

        guard try requiredInt(header: header, tag: 259) == 1 else {
            throw ScalerError.metadataExtractionFailed
        }
        guard try requiredInt(header: header, tag: 262) == 34892 else {
            throw ScalerError.metadataExtractionFailed
        }
        guard try requiredInt(header: header, tag: 277) == 3 else {
            throw ScalerError.metadataExtractionFailed
        }
        guard try requiredInt(header: header, tag: 284) == 1 else {
            throw ScalerError.metadataExtractionFailed
        }
        guard try requiredInt(header: header, tag: 274) == 1 else {
            throw ScalerError.metadataExtractionFailed
        }

        let dngVersion = ((try? byteValues(header: header, tag: 50706)) ?? []).map { Int($0) }
        let colorimetricReference = (try? requiredInt(header: header, tag: 50879)) ?? 1
        guard colorimetricReference == 1 || colorimetricReference == 2 else {
            throw ScalerError.metadataExtractionFailed
        }
        let profile = try profileDynamicRange(header: header)
        if let profile {
            guard profile.version == 1, profile.dynamicRange == 0 || profile.dynamicRange == 1 else {
                throw ScalerError.metadataExtractionFailed
            }
            guard profile.hint.isFinite else { throw ScalerError.metadataExtractionFailed }
            if profile.dynamicRange == 1 {
                // HDR output-referred profiles must be floating point and reference 2
                // (DNG 1.7.1 pp47, 94-95).
                guard isFloat, colorimetricReference == 2 else {
                    throw ScalerError.metadataExtractionFailed
                }
            }
        }
        if colorimetricReference == 2 {
            guard isFloat, versionAtLeast(dngVersion, major: 1, minor: 7) else {
                throw ScalerError.metadataExtractionFailed
            }
        }
        if isFloat, !versionAtLeast(dngVersion, major: 1, minor: 4) {
            throw ScalerError.metadataExtractionFailed
        }

        // Trusted-suite check: the rendered writer marks ImageDescription/Software.
        let imageDescription = try asciiValue(header: header, tag: 270)
        let software = try asciiValue(header: header, tag: 305)
        let suiteText = [imageDescription, software]
            .compactMap { $0 }
            .joined(separator: "\n")
            .lowercased()
        guard suiteText.contains("truongscaler") else {
            throw ScalerError.metadataExtractionFailed
        }

        let rowsPerStrip = try requiredPositiveInt(header: header, tag: 278, name: "RowsPerStrip")
        let blackLevel = try levelValue(header: header, tag: 50714) ?? 0
        let whiteLevel = try levelValue(header: header, tag: 50717)
            ?? (isFloat ? 1 : 65_535)
        guard whiteLevel > blackLevel else {
            throw ScalerError.metadataExtractionFailed
        }
        let whiteRange = whiteLevel - blackLevel

        var baselineExposure: Float = 0
        if let value = try? srationalValue(header: header, tag: 50730), value.isFinite {
            baselineExposure = Float(value)
        }

        let markerScale = parseHeadroomScale(from: imageDescription)
        // LEGACY (read-only) backward compatibility: the previous stage wrote integer samples
        // with overrange encoded as q/65535 * 2^BaselineExposure (and a matching HeadroomScale
        // marker). New integer SDR files use q/65535 with BaselineExposure 0 / H = 1.
        let isLegacyIntegerHeadroom = !isFloat && (
            abs(Double(baselineExposure)) > 1e-6
                || (markerScale.map { $0 > 1 + 1e-4 } ?? false)
        )
        var integerScale: Float = 1
        if isLegacyIntegerHeadroom {
            let fromBaseline = exp2(baselineExposure)
            let scale = (fromBaseline.isFinite && fromBaseline > 0)
                ? fromBaseline
                : (markerScale ?? 1)
            guard scale.isFinite, scale > 0, scale <= 65_504 else {
                throw ScalerError.metadataExtractionFailed
            }
            if let markerScale {
                let tolerance = max(0.001, scale * 0.001)
                guard abs(markerScale - scale) <= tolerance else {
                    throw ScalerError.metadataExtractionFailed
                }
            }
            integerScale = scale
        }
        let floatHint: Float? = {
            guard isFloat else { return nil }
            if let hint = profile?.hint, hint.isFinite, hint > 0 {
                return min(hint, 65_504)
            }
            if let markerScale, markerScale.isFinite, markerScale > 0 {
                return min(markerScale, 65_504)
            }
            return nil
        }()

        // ---- Strip geometry: checked arithmetic and file-size bounds before any I/O ----
        let stripOffsets = try uint32Values(header: header, tag: 273)
        let stripByteCounts = try uint32Values(header: header, tag: 279)
        guard !stripOffsets.isEmpty, stripOffsets.count == stripByteCounts.count else {
            throw ScalerError.metadataExtractionFailed
        }
        // ceil(height / rowsPerStrip) without an overflowing addition.
        let expectedStripCount = (height - 1) / rowsPerStrip + 1
        guard stripOffsets.count == expectedStripCount else {
            throw ScalerError.metadataExtractionFailed
        }

        let bytesPerSample = UInt64(bitsPerSample / 8) // 2 or 4
        let bytesPerPixel = try checkedMul(3, bytesPerSample)
        let height64 = UInt64(height)
        let width64 = UInt64(width)
        var previousEnd: UInt64 = 8
        for stripIndex in 0..<stripOffsets.count {
            let startRow = try checkedMul(UInt64(stripIndex), UInt64(rowsPerStrip))
            guard startRow < height64 else {
                throw ScalerError.stripDecodingFailed(
                    stripIndex: stripIndex,
                    rectDescription: "Strip start row is outside the image"
                )
            }
            let rowCount = min(UInt64(rowsPerStrip), height64 - startRow)
            let expectedBytes = try checkedMul(
                try checkedMul(rowCount, width64),
                bytesPerPixel
            )
            let offset = UInt64(stripOffsets[stripIndex])
            let byteCount = UInt64(stripByteCounts[stripIndex])
            let end = try checkedAdd(offset, byteCount)
            guard offset >= 8,
                  byteCount == expectedBytes,
                  offset >= previousEnd,
                  end <= fileSize else {
                throw ScalerError.stripDecodingFailed(
                    stripIndex: stripIndex,
                    rectDescription: "Strip offset/byte count is truncated, overlapping, or malformed"
                )
            }
            previousEnd = end
        }
        let totalPixelBytes = try checkedMul(try checkedMul(height64, width64), bytesPerPixel)
        guard totalPixelBytes <= fileSize else {
            throw ScalerError.metadataExtractionFailed
        }

        // Destination geometry (RGBA Float16, 64-byte aligned rows) checked before mmap.
        let widthBytes = try checkedMul(width64, 8)
        let paddedWidthBytes = try checkedAdd(widthBytes, 63)
        let rowBytes = (paddedWidthBytes / 64) * 64
        let destinationBytes = try checkedMul(rowBytes, height64)
        _ = try checkedInt(destinationBytes)

        // All input geometry is now proven representable and inside the actual file. Only now
        // open/create/truncate the destination.
        let destinationExisted = FileManager.default.fileExists(atPath: destinationMMapURL.path)
        let destination: MMapBuffer
        do {
            destination = try MMapBuffer(
                fileURL: destinationMMapURL,
                width: width,
                height: height,
                createIfMissing: true
            )
        } catch {
            if !destinationExisted {
                try? FileManager.default.removeItem(at: destinationMMapURL)
            }
            throw error
        }

        let rowByteCount = try checkedMul(width64, bytesPerPixel)
        let rowByteCountInt = try checkedInt(rowByteCount)
        let chunkRows = max(1, min(stripHeight, rowsPerStrip))
        let luminanceR: Float = 0.22897456
        let luminanceG: Float = 0.69173852
        let luminanceB: Float = 0.07928691
        let black = Float(blackLevel)
        let whiteRangeFloat = Float(whiteRange)
        var maximumComponent: Float = 1.0
        var maximumLuminance: Float = 1.0

        do {
            for stripIndex in 0..<stripOffsets.count {
                let stripOffset = UInt64(stripOffsets[stripIndex])
                let startRow = try checkedInt(
                    try checkedMul(UInt64(stripIndex), UInt64(rowsPerStrip))
                )
                let rowCount = min(rowsPerStrip, height - startRow)
                var chunkStart = 0
                while chunkStart < rowCount {
                    let rowsThisChunk = min(chunkRows, rowCount - chunkStart)
                    let chunkOffset = try checkedAdd(
                        stripOffset,
                        try checkedMul(UInt64(chunkStart), rowByteCount)
                    )
                    let chunkByteCount = try checkedMul(UInt64(rowsThisChunk), rowByteCount)
                    let chunkByteCountInt = try checkedInt(chunkByteCount)
                    let chunkData: Data
                    do {
                        chunkData = try readExactly(
                            handle: handle,
                            offset: chunkOffset,
                            byteCount: chunkByteCountInt,
                            fileSize: fileSize
                        )
                    } catch {
                        throw ScalerError.stripDecodingFailed(
                            stripIndex: stripIndex,
                            rectDescription: "Failed to read \(chunkByteCount) bytes at offset \(chunkOffset)"
                        )
                    }

                    chunkData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                        guard let base = raw.baseAddress else { return }
                        for rowInChunk in 0..<rowsThisChunk {
                            let destinationRow = startRow + chunkStart + rowInChunk
                            let sourceRow = base.advanced(by: rowInChunk * rowByteCountInt)
                            let output = destination.unsafeRowPointer(y: destinationRow)
                                .assumingMemoryBound(to: Float16.self)
                            if isFloat {
                                if bitsPerSample == 16 {
                                    let words = sourceRow.assumingMemoryBound(to: UInt16.self)
                                    for x in 0..<width {
                                        let sourceIndex = x * 3
                                        let red = float16Value(words[sourceIndex])
                                        let green = float16Value(words[sourceIndex + 1])
                                        let blue = float16Value(words[sourceIndex + 2])
                                        writeDecoded(
                                            output: output,
                                            x: x,
                                            red: red,
                                            green: green,
                                            blue: blue,
                                            maximumComponent: &maximumComponent,
                                            maximumLuminance: &maximumLuminance,
                                            luminanceR: luminanceR,
                                            luminanceG: luminanceG,
                                            luminanceB: luminanceB
                                        )
                                    }
                                } else {
                                    let words = sourceRow.assumingMemoryBound(to: UInt32.self)
                                    for x in 0..<width {
                                        let sourceIndex = x * 3
                                        let red = float32Value(words[sourceIndex])
                                        let green = float32Value(words[sourceIndex + 1])
                                        let blue = float32Value(words[sourceIndex + 2])
                                        writeDecoded(
                                            output: output,
                                            x: x,
                                            red: red,
                                            green: green,
                                            blue: blue,
                                            maximumComponent: &maximumComponent,
                                            maximumLuminance: &maximumLuminance,
                                            luminanceR: luminanceR,
                                            luminanceG: luminanceG,
                                            luminanceB: luminanceB
                                        )
                                    }
                                }
                            } else {
                                let pixels = sourceRow.assumingMemoryBound(to: UInt16.self)
                                for x in 0..<width {
                                    let sourceIndex = x * 3
                                    let red = decodeComponent(
                                        pixels[sourceIndex],
                                        black: black,
                                        whiteRange: whiteRangeFloat,
                                        scale: integerScale
                                    )
                                    let green = decodeComponent(
                                        pixels[sourceIndex + 1],
                                        black: black,
                                        whiteRange: whiteRangeFloat,
                                        scale: integerScale
                                    )
                                    let blue = decodeComponent(
                                        pixels[sourceIndex + 2],
                                        black: black,
                                        whiteRange: whiteRangeFloat,
                                        scale: integerScale
                                    )
                                    writeDecoded(
                                        output: output,
                                        x: x,
                                        red: red,
                                        green: green,
                                        blue: blue,
                                        maximumComponent: &maximumComponent,
                                        maximumLuminance: &maximumLuminance,
                                        luminanceR: luminanceR,
                                        luminanceG: luminanceG,
                                        luminanceB: luminanceB
                                    )
                                }
                            }
                        }
                    }

                    chunkStart += rowsThisChunk
                    progressHandler?(Double(startRow + chunkStart) / Double(height))
                }
            }

            _ = try performBlockingFlush(destination)
        } catch {
            // Never leave a half-decoded destination behind for a malformed input, but never
            // delete a destination that already existed before this decode.
            if !destinationExisted {
                try? FileManager.default.removeItem(at: destinationMMapURL)
            }
            throw error
        }

        let headroomScale: Float
        if isFloat {
            headroomScale = floatHint ?? max(1, maximumComponent)
        } else {
            headroomScale = isLegacyIntegerHeadroom ? integerScale : 1
        }
        return LinearDNGTIFFDecodeResult(
            width: width,
            height: height,
            headroomScale: headroomScale,
            baselineExposure: baselineExposure,
            globalMaxLinearComponent: maximumComponent,
            globalMaxLuminance: maximumLuminance,
            stripCount: stripOffsets.count,
            sampleFormat: Int(sampleFormat),
            isFloat: isFloat,
            isLegacyIntegerHeadroom: isLegacyIntegerHeadroom,
            colorimetricReference: colorimetricReference,
            dngVersion: dngVersion.count == 4 ? dngVersion : [1, 4, 0, 0],
            whiteLevel: whiteLevel,
            profileDynamicRangeHint: profile?.hint,
            profileDynamicRangeValue: profile?.dynamicRange
        )
    }

    /// Best-effort, non-throwing header probe used by `MetadataExtractor` to recognize suite
    /// Linear DNGs even when ImageIO does not surface `PhotometricInterpretation`.
    ///
    /// Hostile dimensions/strip tables are reported as-is; this probe never allocates by image
    /// size, seeks by untrusted byte count, or performs unchecked size arithmetic.
    public static func probe(imageURL: URL) -> LinearDNGFileInfo? {
        guard let fileSize = try? regularFileSize(imageURL),
              fileSize >= 8,
              let handle = try? FileHandle(forReadingFrom: imageURL) else { return nil }
        defer { try? handle.close() }
        guard let header = try? parseDirectory(handle: handle, fileSize: fileSize) else { return nil }
        let width = (try? requiredPositiveInt(header: header, tag: 256, name: "ImageWidth")) ?? 0
        let height = (try? requiredPositiveInt(header: header, tag: 257, name: "ImageLength")) ?? 0
        guard width > 0, height > 0 else { return nil }
        let description = (try? asciiValue(header: header, tag: 270)) ?? nil
        let software = (try? asciiValue(header: header, tag: 305)) ?? nil
        let baseline: Float? = {
            guard let value = try? srationalValue(header: header, tag: 50730) else { return nil }
            guard value.isFinite else { return nil }
            return Float(value)
        }()
        let profile = try? profileDynamicRange(header: header)
        return LinearDNGFileInfo(
            width: width,
            height: height,
            photometricInterpretation: (try? requiredInt(header: header, tag: 262)) ?? 0,
            orientation: (try? requiredInt(header: header, tag: 274)) ?? 1,
            bitsPerSample: ((try? uint16Values(header: header, tag: 258)) ?? []).map { Int($0) },
            samplesPerPixel: (try? requiredInt(header: header, tag: 277)) ?? 0,
            imageDescription: description,
            software: software,
            baselineExposure: baseline,
            headroomScaleFromDescription: parseHeadroomScale(from: description),
            embeddedMetadata: embeddedMetadata(header: header),
            dngVersion: ((try? byteValues(header: header, tag: 50706)) ?? []).map { Int($0) },
            dngBackwardVersion: ((try? byteValues(header: header, tag: 50707)) ?? []).map { Int($0) },
            colorimetricReference: (try? requiredInt(header: header, tag: 50879)),
            sampleFormat: ((try? uint16Values(header: header, tag: 339)) ?? []).map { Int($0) },
            whiteLevel: try? levelValue(header: header, tag: 50717),
            profileDynamicRangeVersion: profile?.version,
            profileDynamicRangeValue: profile?.dynamicRange,
            profileDynamicRangeHint: profile?.hint
        )
    }

    /// Parses `HeadroomScale=<H>` from a generated marker description.
    public static func parseHeadroomScale(from description: String?) -> Float? {
        guard let description else { return nil }
        let normalized = description
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        guard let range = normalized.range(of: "headroomscale=") else { return nil }
        let remainder = normalized[range.upperBound...]
        let value = remainder.prefix { character in
            character.isNumber || character == "." || character == "e" || character == "+" || character == "-"
        }
        guard let parsed = Float(value), parsed.isFinite, parsed > 0 else { return nil }
        return parsed
    }
}

// MARK: - Decoding helpers

private struct SuiteProfileDynamicRange {
    let version: Int
    let dynamicRange: Int
    let hint: Float
}

private extension LinearDNGTIFFReader {
    // Checked size arithmetic. Every untrusted TIFF count/offset/size flows through these; a
    // value that cannot be represented is a format error, never a Swift arithmetic trap.
    static func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw ScalerError.metadataExtractionFailed }
        return result
    }

    static func checkedMul(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw ScalerError.metadataExtractionFailed }
        return result
    }

    static func checkedInt(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else { throw ScalerError.metadataExtractionFailed }
        return Int(value)
    }

    /// Accepts a single shared value or one value per sample; anything else is rejected.
    static func normalizedTriple(
        _ values: [UInt16],
        defaultValue: [UInt16],
        name: String
    ) throws -> [UInt16] {
        if values.isEmpty { return defaultValue }
        if values.count == 1 {
            return [values[0], values[0], values[0]]
        }
        guard values.count == 3, values[0] == values[1], values[1] == values[2] else {
            throw ScalerError.metadataExtractionFailed
        }
        return values
    }

    static func decodeComponent(_ stored: UInt16, black: Float, whiteRange: Float, scale: Float) -> Float {
        let value = max(0, Float(stored) - black)
        return value / whiteRange * scale
    }

    static func float16Value(_ word: UInt16) -> Float {
        let value = Float(Float16(bitPattern: word))
        guard value.isFinite else { return 0 }
        return min(max(value, -65_504), 65_504)
    }

    static func float32Value(_ word: UInt32) -> Float {
        let value = Float(bitPattern: word)
        guard value.isFinite else { return 0 }
        return min(max(value, -65_504), 65_504)
    }

    static func writeDecoded(
        output: UnsafeMutablePointer<Float16>,
        x: Int,
        red: Float,
        green: Float,
        blue: Float,
        maximumComponent: inout Float,
        maximumLuminance: inout Float,
        luminanceR: Float,
        luminanceG: Float,
        luminanceB: Float
    ) {
        output[x * 4 + 0] = Float16(red)
        output[x * 4 + 1] = Float16(green)
        output[x * 4 + 2] = Float16(blue)
        output[x * 4 + 3] = 1.0

        if red > maximumComponent { maximumComponent = red }
        if green > maximumComponent { maximumComponent = green }
        if blue > maximumComponent { maximumComponent = blue }
        let luminance = luminanceR * red + luminanceG * green + luminanceB * blue
        if luminance > maximumLuminance { maximumLuminance = luminance }
    }

    static func versionAtLeast(_ version: [Int], major: Int, minor: Int) -> Bool {
        guard version.count >= 2 else { return !version.isEmpty && version[0] > major }
        if version[0] != major { return version[0] > major }
        return version[1] >= minor
    }

    /// Parses DNG ProfileDynamicRange (tag 52551, UNDEFINED count 8):
    /// SHORT Version, SHORT DynamicRange, FLOAT HintMaxOutputValue.
    ///
    /// The DNG 1.7.1 specification does not state the byte order of this packed struct.
    /// Adobe DNG files and ExifTool's DNG tag table use **big-endian** for the inner fields
    /// even in a little-endian TIFF (ExifTool: "ByteOrder => BigEndian, not indicated in
    /// spec"), so BE is the primary encoding. A little-endian version-1 payload is accepted
    /// as a compatibility fallback for non-Adobe writers.
    static func profileDynamicRange(header: TIFFHeader) throws -> SuiteProfileDynamicRange? {
        guard let field = field(header, tag: 52551) else { return nil }
        guard field.type == 7 || field.type == 1, field.count == 8 else {
            throw ScalerError.metadataExtractionFailed
        }
        let data = try payload(header: header, field: field)
        let bytes = [UInt8](data)
        guard bytes.count == 8 else { throw ScalerError.metadataExtractionFailed }

        let bigEndian = SuiteProfileDynamicRange(
            version: (Int(bytes[0]) << 8) | Int(bytes[1]),
            dynamicRange: (Int(bytes[2]) << 8) | Int(bytes[3]),
            hint: Float(bitPattern: UInt32(bytes[4]) << 24
                | UInt32(bytes[5]) << 16
                | UInt32(bytes[6]) << 8
                | UInt32(bytes[7]))
        )
        if bigEndian.version == 1 { return bigEndian }

        let littleEndian = SuiteProfileDynamicRange(
            version: Int(bytes[0]) | (Int(bytes[1]) << 8),
            dynamicRange: Int(bytes[2]) | (Int(bytes[3]) << 8),
            hint: Float(bitPattern: UInt32(bytes[4])
                | (UInt32(bytes[5]) << 8)
                | (UInt32(bytes[6]) << 16)
                | (UInt32(bytes[7]) << 24))
        )
        if littleEndian.version == 1 { return littleEndian }
        throw ScalerError.metadataExtractionFailed
    }

    static func aliasesDestination(sourceURL: URL, destinationURL: URL) -> Bool {
        if sourceURL.resolvingSymlinksInPath().standardizedFileURL
            == destinationURL.resolvingSymlinksInPath().standardizedFileURL {
            return true
        }
        guard let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let destinationAttributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path),
              let sourceDevice = sourceAttributes[.systemNumber] as? NSNumber,
              let sourceFile = sourceAttributes[.systemFileNumber] as? NSNumber,
              let destinationDevice = destinationAttributes[.systemNumber] as? NSNumber,
              let destinationFile = destinationAttributes[.systemFileNumber] as? NSNumber else { return false }
        return sourceDevice == destinationDevice && sourceFile == destinationFile
    }

    static func regularFileSize(_ url: URL) throws -> UInt64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            throw ScalerError.fileNotFound(url)
        }
        return size
    }

    static func performBlockingFlush(_ buffer: MMapBuffer) throws -> Bool {
        try buffer.flushToDisk(synchronous: true)
        return true
    }

    static func readExactly(
        handle: FileHandle,
        offset: UInt64,
        byteCount: Int,
        fileSize: UInt64
    ) throws -> Data {
        guard byteCount >= 0, offset <= fileSize, UInt64(byteCount) <= fileSize - offset else {
            throw ScalerError.metadataExtractionFailed
        }
        do {
            try handle.seek(toOffset: offset)
            guard byteCount > 0 else { return Data() }
            guard let data = try handle.read(upToCount: byteCount), data.count == byteCount else {
                throw ScalerError.metadataExtractionFailed
            }
            return data
        } catch let error as ScalerError {
            throw error
        } catch {
            throw ScalerError.metadataExtractionFailed
        }
    }
}

// MARK: - Minimal little-endian TIFF IFD0 parser

private struct TIFFField {
    let tag: UInt16
    let type: UInt16
    let count: UInt32
    let valueOrOffset: UInt32

    func byteCount() -> UInt64? {
        let size = TIFFField.typeSize(type)
        guard size > 0 else { return nil }
        let (result, overflow) = UInt64(count).multipliedReportingOverflow(by: size)
        return overflow ? nil : result
    }

    static func typeSize(_ type: UInt16) -> UInt64 {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11: return 4
        case 5, 10, 12: return 8
        default: return 0
        }
    }
}

private struct TIFFHeader {
    let handle: FileHandle
    let fileSize: UInt64
    let fields: [UInt16: TIFFField]
}

private extension LinearDNGTIFFReader {
    static func parseDirectory(handle: FileHandle, fileSize: UInt64) throws -> TIFFHeader {
        guard fileSize >= 8 else { throw ScalerError.metadataExtractionFailed }
        let prefix = try readExactly(handle: handle, offset: 0, byteCount: 8, fileSize: fileSize)
        let bytes = [UInt8](prefix)
        guard bytes[0] == 0x49, bytes[1] == 0x49 else {
            // Big-endian TIFF and non-TIFF containers are not this reader's subset.
            throw ScalerError.metadataExtractionFailed
        }
        let magic = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        guard magic == 42 else {
            throw ScalerError.metadataExtractionFailed
        }
        let ifdOffset = UInt32(bytes[4])
            | (UInt32(bytes[5]) << 8)
            | (UInt32(bytes[6]) << 16)
            | (UInt32(bytes[7]) << 24)
        let fields = try parseIFDEntries(handle: handle, fileSize: fileSize, offset: UInt64(ifdOffset))
        return TIFFHeader(handle: handle, fileSize: fileSize, fields: fields)
    }

    /// Follows a LONG pointer tag (ExifIFD 34665 / GPSIFD 34853) to a nested IFD.
    static func nestedHeader(pointerTag: UInt16, header: TIFFHeader) -> TIFFHeader? {
        guard let field = header.fields[pointerTag],
              field.type == 4,
              field.count == 1,
              field.valueOrOffset >= 8 else { return nil }
        guard let fields = try? parseIFDEntries(
            handle: header.handle,
            fileSize: header.fileSize,
            offset: UInt64(field.valueOrOffset)
        ) else { return nil }
        return TIFFHeader(handle: header.handle, fileSize: header.fileSize, fields: fields)
    }

    /// Recovers the standard IFD0/EXIF/GPS fields written by the suite DNG writer.
    static func embeddedMetadata(header: TIFFHeader) -> LinearDNGEmbeddedMetadata? {
        let exif = nestedHeader(pointerTag: 34665, header: header)
        let gps = nestedHeader(pointerTag: 34853, header: header)

        func ascii(_ tag: UInt16, _ source: TIFFHeader?) -> String? {
            guard let source else { return nil }
            return (try? asciiValue(header: source, tag: tag)) ?? nil
        }
        func rational(_ tag: UInt16, _ source: TIFFHeader?) -> Double? {
            guard let source else { return nil }
            return (try? srationalValue(header: source, tag: tag)) ?? nil
        }
        func coordinate(_ tag: UInt16, _ source: TIFFHeader?) -> Double? {
            guard let source,
                  let values = try? rationalValues(header: source, tag: tag),
                  values.count >= 3,
                  values.allSatisfy({ $0.isFinite }) else { return nil }
            return values[0] + values[1] / 60.0 + values[2] / 3600.0
        }
        func signedCoordinate(_ value: Double?, _ reference: String?, positive: String) -> Double? {
            guard let value else { return nil }
            guard let reference, reference.uppercased() != positive else { return value }
            return -value
        }

        let latitudeRef = ascii(1, gps)
        let longitudeRef = ascii(3, gps)
        let latitude = signedCoordinate(coordinate(2, gps), latitudeRef, positive: "N")
        let longitude = signedCoordinate(coordinate(4, gps), longitudeRef, positive: "E")
        let iso = exif.flatMap { source in
            ((try? uint16Values(header: source, tag: 34855)) ?? []).first.map { Int($0) }
        }

        let metadata = LinearDNGEmbeddedMetadata(
            cameraMake: ascii(271, header),
            cameraModel: ascii(272, header),
            dateTime: ascii(306, header),
            dateTimeOriginal: ascii(36867, exif),
            dateTimeDigitized: ascii(36868, exif),
            exposureTime: rational(33434, exif),
            fNumber: rational(33437, exif),
            iso: iso,
            focalLength: rational(37386, exif),
            lensMake: ascii(42035, exif),
            lensModel: ascii(42036, exif),
            userComment: exif.flatMap { userCommentValue(header: $0, tag: 37510) },
            gpsLatitude: latitude,
            gpsLatitudeRef: latitudeRef,
            gpsLongitude: longitude,
            gpsLongitudeRef: longitudeRef,
            gpsAltitude: rational(6, gps),
            gpsAltitudeRef: gps.flatMap { source in
                (try? requiredInt(header: source, tag: 5))
            }
        )
        let hasAnyValue = [
            metadata.cameraMake, metadata.cameraModel, metadata.dateTime,
            metadata.dateTimeOriginal, metadata.dateTimeDigitized,
            metadata.lensMake, metadata.lensModel, metadata.userComment,
            metadata.gpsLatitudeRef, metadata.gpsLongitudeRef,
        ].contains { $0?.isEmpty == false }
            || metadata.exposureTime != nil || metadata.fNumber != nil || metadata.iso != nil
            || metadata.focalLength != nil || metadata.gpsLatitude != nil
            || metadata.gpsLongitude != nil || metadata.gpsAltitude != nil
        return hasAnyValue ? metadata : nil
    }

    /// Reads an EXIF `UserComment` (tag 37510), dropping the 8-byte character-code prefix.
    static func userCommentValue(header: TIFFHeader, tag: UInt16) -> String? {
        guard let field = header.fields[tag] else { return nil }
        guard let data = try? payload(header: header, field: field), !data.isEmpty else { return nil }
        var bytes = Array(data)
        if bytes.count >= 8 {
            let prefix = String(bytes: bytes.prefix(8), encoding: .ascii) ?? ""
            if prefix.hasPrefix("ASCII") || prefix.hasPrefix("UNICODE") || prefix.hasPrefix("JIS") {
                bytes.removeFirst(8)
            }
        }
        while bytes.last == 0 { bytes.removeLast() }
        guard !bytes.isEmpty else { return nil }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Reads every RATIONAL value of a field (used for GPS degree/minute/second triplets).
    static func rationalValues(header: TIFFHeader, tag: UInt16) throws -> [Double] {
        guard let field = header.fields[tag],
              field.type == 5 || field.type == 10 else {
            throw ScalerError.metadataExtractionFailed
        }
        let data = try payload(header: header, field: field)
        let bytes = [UInt8](data)
        var values: [Double] = []
        values.reserveCapacity(bytes.count / 8)
        var index = 0
        while index + 7 < bytes.count {
            let numerator = UInt32(bytes[index])
                | (UInt32(bytes[index + 1]) << 8)
                | (UInt32(bytes[index + 2]) << 16)
                | (UInt32(bytes[index + 3]) << 24)
            let denominator = UInt32(bytes[index + 4])
                | (UInt32(bytes[index + 5]) << 8)
                | (UInt32(bytes[index + 6]) << 16)
                | (UInt32(bytes[index + 7]) << 24)
            guard denominator != 0 else {
                throw ScalerError.metadataExtractionFailed
            }
            values.append(Double(numerator) / Double(denominator))
            index += 8
        }
        return values
    }

    /// Parses one IFD entry table at `offset`. Empty IFDs (count 0) are valid and return `[:]`.
    static func parseIFDEntries(
        handle: FileHandle,
        fileSize: UInt64,
        offset: UInt64
    ) throws -> [UInt16: TIFFField] {        guard offset <= fileSize, fileSize - offset >= 2 else {
            throw ScalerError.metadataExtractionFailed
        }
        let countData = try readExactly(handle: handle, offset: offset, byteCount: 2, fileSize: fileSize)
        let entryCount = Int(UInt16(countData[countData.startIndex])
            | (UInt16(countData[countData.startIndex + 1]) << 8))
        guard entryCount <= 8192 else {
            throw ScalerError.metadataExtractionFailed
        }
        guard entryCount > 0 else { return [:] }
        let entriesByteCount = entryCount * 12 + 4
        let entriesOffset = try checkedAdd(offset, 2)
        let entriesEnd = try checkedAdd(entriesOffset, UInt64(entriesByteCount))
        guard entriesEnd <= fileSize else {
            throw ScalerError.metadataExtractionFailed
        }
        let entryData = try readExactly(
            handle: handle,
            offset: entriesOffset,
            byteCount: entriesByteCount,
            fileSize: fileSize
        )
        var fields: [UInt16: TIFFField] = [:]
        fields.reserveCapacity(entryCount)
        entryData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            for index in 0..<entryCount {
                let entry = base.advanced(by: index * 12).assumingMemoryBound(to: UInt8.self)
                let tag = UInt16(entry[0]) | (UInt16(entry[1]) << 8)
                let type = UInt16(entry[2]) | (UInt16(entry[3]) << 8)
                let count = UInt32(entry[4])
                    | (UInt32(entry[5]) << 8)
                    | (UInt32(entry[6]) << 16)
                    | (UInt32(entry[7]) << 24)
                let valueOrOffset = UInt32(entry[8])
                    | (UInt32(entry[9]) << 8)
                    | (UInt32(entry[10]) << 16)
                    | (UInt32(entry[11]) << 24)
                fields[tag] = TIFFField(tag: tag, type: type, count: count, valueOrOffset: valueOrOffset)
            }
        }
        return fields
    }

    static func field(_ header: TIFFHeader, tag: UInt16) -> TIFFField? {
        header.fields[tag]
    }

    static func payload(header: TIFFHeader, field: TIFFField) throws -> Data {
        guard let byteCount64 = field.byteCount() else {
            throw ScalerError.metadataExtractionFailed
        }
        guard byteCount64 <= UInt64(Int.max) else {
            throw ScalerError.metadataExtractionFailed
        }
        let byteCount = Int(byteCount64)
        if byteCount <= 4 {
            // Inline value bytes are the low bytes of the little-endian entry word.
            let value = field.valueOrOffset
            var inline = [UInt8](
                arrayLiteral: UInt8(value & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 24) & 0xFF)
            )
            inline.removeLast(4 - byteCount)
            return Data(inline)
        }
        let offset = UInt64(field.valueOrOffset)
        guard offset <= header.fileSize, byteCount64 <= header.fileSize - offset else {
            throw ScalerError.metadataExtractionFailed
        }
        return try readExactly(handle: header.handle, offset: offset, byteCount: byteCount, fileSize: header.fileSize)
    }

    static func byteValues(header: TIFFHeader, tag: UInt16) throws -> [UInt8] {
        guard let field = field(header, tag: tag) else { throw ScalerError.metadataExtractionFailed }
        guard field.type == 1 || field.type == 7 || field.type == 2 else {
            throw ScalerError.metadataExtractionFailed
        }
        return [UInt8](try payload(header: header, field: field))
    }

    /// A missing legacy sample tag may use its documented default. A present tag must have a
    /// valid shared/per-channel SHORT payload; malformed data must never select that default.
    static func optionalSampleValues(header: TIFFHeader, tag: UInt16) throws -> [UInt16]? {
        guard let field = field(header, tag: tag) else { return nil }
        guard field.type == 3, field.count == 1 || field.count == 3 else {
            throw ScalerError.metadataExtractionFailed
        }
        return try uint16Values(header: header, tag: tag)
    }

    static func uint16Values(header: TIFFHeader, tag: UInt16) throws -> [UInt16] {
        guard let field = field(header, tag: tag) else { throw ScalerError.metadataExtractionFailed }
        guard field.type == 3 else { throw ScalerError.metadataExtractionFailed }
        let data = try payload(header: header, field: field)
        var values: [UInt16] = []
        values.reserveCapacity(data.count / 2)
        let bytes = [UInt8](data)
        var index = 0
        while index + 1 < bytes.count {
            values.append(UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
            index += 2
        }
        return values
    }

    static func uint32Values(header: TIFFHeader, tag: UInt16) throws -> [UInt32] {
        guard let field = field(header, tag: tag) else { throw ScalerError.metadataExtractionFailed }
        guard field.type == 4 || field.type == 3 else { throw ScalerError.metadataExtractionFailed }
        let data = try payload(header: header, field: field)
        let bytes = [UInt8](data)
        var values: [UInt32] = []
        if field.type == 4 {
            values.reserveCapacity(bytes.count / 4)
            var index = 0
            while index + 3 < bytes.count {
                values.append(UInt32(bytes[index])
                    | (UInt32(bytes[index + 1]) << 8)
                    | (UInt32(bytes[index + 2]) << 16)
                    | (UInt32(bytes[index + 3]) << 24))
                index += 4
            }
        } else {
            var index = 0
            while index + 1 < bytes.count {
                values.append(UInt32(bytes[index]) | (UInt32(bytes[index + 1]) << 8))
                index += 2
            }
        }
        return values
    }

    static func requiredInt(header: TIFFHeader, tag: UInt16) throws -> Int {
        guard let field = field(header, tag: tag) else { throw ScalerError.metadataExtractionFailed }
        let data = try payload(header: header, field: field)
        let bytes = [UInt8](data)
        switch field.type {
        case 3:
            guard bytes.count >= 2 else { throw ScalerError.metadataExtractionFailed }
            return Int(UInt16(bytes[0]) | (UInt16(bytes[1]) << 8))
        case 4:
            guard bytes.count >= 4 else { throw ScalerError.metadataExtractionFailed }
            return Int(UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24))
        case 1:
            guard let first = bytes.first else { throw ScalerError.metadataExtractionFailed }
            return Int(first)
        default:
            throw ScalerError.metadataExtractionFailed
        }
    }

    static func requiredPositiveInt(header: TIFFHeader, tag: UInt16, name: String) throws -> Int {
        let value = try requiredInt(header: header, tag: tag)
        guard value > 0 else { throw ScalerError.metadataExtractionFailed }
        return value
    }

    static func levelValue(header: TIFFHeader, tag: UInt16) throws -> Int? {
        guard let field = field(header, tag: tag) else { return nil }
        switch field.type {
        case 3:
            let values = try uint16Values(header: header, tag: tag)
            return values.first.map { Int($0) }
        case 4:
            let values = try uint32Values(header: header, tag: tag)
            return values.first.map { Int($0) }
        default:
            throw ScalerError.metadataExtractionFailed
        }
    }

    static func asciiValue(header: TIFFHeader, tag: UInt16) throws -> String? {
        guard let field = field(header, tag: tag) else { return nil }
        guard field.type == 2 || field.type == 1 || field.type == 7 else {
            throw ScalerError.metadataExtractionFailed
        }
        let data = try payload(header: header, field: field)
        let bytes = data.prefix { $0 != 0 }
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw ScalerError.metadataExtractionFailed
        }
        return string
    }

    static func srationalValue(header: TIFFHeader, tag: UInt16) throws -> Double? {
        guard let field = field(header, tag: tag) else { return nil }
        guard field.type == 10 || field.type == 5 else {
            throw ScalerError.metadataExtractionFailed
        }
        let data = try payload(header: header, field: field)
        let bytes = [UInt8](data)
        guard bytes.count >= 8 else { throw ScalerError.metadataExtractionFailed }
        let numerator = Int32(bitPattern: UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24))
        let denominator = Int32(bitPattern: UInt32(bytes[4])
            | (UInt32(bytes[5]) << 8)
            | (UInt32(bytes[6]) << 16)
            | (UInt32(bytes[7]) << 24))
        guard denominator != 0 else { throw ScalerError.metadataExtractionFailed }
        return Double(numerator) / Double(denominator)
    }
}
