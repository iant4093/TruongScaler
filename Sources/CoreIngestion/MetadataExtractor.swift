import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import TruongScalerCore

/// Extracts all image properties, EXIF/TIFF/GPS/MakerApple dictionaries, RAW white balance/matrices,
/// and HDR Gain Maps via `ImageIO`.
/// Specification: `docs/DEVELOPMENT.md` Section 2.1.
public struct MetadataExtractor: Sendable {
    public static let rawFileExtensions: Set<String> = [
        "cr2", "cr3", "arw", "nef", "nrw", "dng", "raf", "orf", "rw2", "pef", "srw"
    ]

    public static func extractMetadata(from imageURL: URL) throws -> ImageMetadataPacket {
        // Step 1 — Validate that the source really exists and is a regular file.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: imageURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ScalerError.fileNotFound(imageURL)
        }

        // Step 2 — Create a lazy `CGImageSource`. `ShouldCache: false` keeps large RAW files off the heap.
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, sourceOptions) else {
            throw ScalerError.imageSourceCreationFailed(imageURL)
        }

        // Step 3 — UTType identifier + file extension classification hints.
        let utTypeString = (CGImageSourceGetType(source) as String?) ?? ""
        let fileExtension = imageURL.pathExtension.lowercased()

        // ImageIO does not expose rendered LinearRaw DNGs as decoded properties (it reports the
        // container as TIFF and returns no property dictionary). The independent TIFF probe is
        // therefore the authoritative fallback for suite-written rendered Linear DNGs.
        let tiffProbe = LinearDNGTIFFReader.probe(imageURL: imageURL)

        // Step 4 — Full ImageIO property dictionary (may legitimately fail for corrupt/empty files).
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            if let fallback = suiteLinearDNGMetadataFallback(
                imageURL: imageURL,
                probe: tiffProbe,
                utTypeIdentifier: utTypeString,
                fileExtension: fileExtension
            ) {
                return fallback
            }
            throw ScalerError.metadataExtractionFailed
        }

        // Step 5 — Raw pixel dimensions and EXIF orientation. `originalWidth`/`originalHeight` are the
        // *oriented display* dimensions: EXIF orientations 5...8 rotate by 90°/270° and therefore swap axes.
        guard let rawPixelWidth = intValue(properties[kCGImagePropertyPixelWidth as String]),
              let rawPixelHeight = intValue(properties[kCGImagePropertyPixelHeight as String]),
              rawPixelWidth > 0,
              rawPixelHeight > 0 else {
            throw ScalerError.metadataExtractionFailed
        }
        let reportedOrientation = intValue(properties[kCGImagePropertyOrientation as String]) ?? 1
        let orientation = (1...8).contains(reportedOrientation) ? reportedOrientation : 1
        let dimensionsAreSwapped = [5, 6, 7, 8].contains(orientation)
        let originalWidth = dimensionsAreSwapped ? rawPixelHeight : rawPixelWidth
        let originalHeight = dimensionsAreSwapped ? rawPixelWidth : rawPixelHeight

        // Step 6 — Bit depth / alpha.
        let bitsPerComponent = intValue(properties[kCGImagePropertyDepth as String]) ?? 8
        let hasAlpha = boolValue(properties[kCGImagePropertyHasAlpha as String]) ?? false

        // Step 7 — EXIF dictionaries and ISO.
        let exifDictionary = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiffDictionary = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let dngDictionary = properties[kCGImagePropertyDNGDictionary as String] as? [String: Any]
        let pngDictionary = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any]
        let markerAppleDictionary = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
        let iso = isoValue(from: exifDictionary)

        // Step 8 — Auxiliary HDR Gain Map (JPEG / HEIF / DNG). Probe each auxiliary type
        // explicitly so the packet records whether a legacy HDR gain map or an ISO gain map
        // was found; the two are not interchangeable.
        let legacyGainMapInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source,
            0,
            kCGImageAuxiliaryDataTypeHDRGainMap
        ) as? [String: Any]
        let isoGainMapInfo = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source,
            0,
            kCGImageAuxiliaryDataTypeISOGainMap
        ) as? [String: Any]
        let hdrGainMapInfo = legacyGainMapInfo ?? isoGainMapInfo
        let hdrGainMapAuxiliaryType: HDRGainMapAuxiliaryType? = legacyGainMapInfo != nil
            ? .legacyHDRGainMap
            : (isoGainMapInfo != nil ? .isoGainMap : nil)

        let hdrGainMapData: Data? = {
            guard let info = hdrGainMapInfo else { return nil }
            if let data = info[kCGImageAuxiliaryDataInfoData as String] as? Data { return data }
            if let data = info[kCGImageAuxiliaryDataInfoData as String] as? NSData { return data as Data }
            return nil
        }()

        let hdrGainMapDescription = hdrGainMapInfo?[kCGImageAuxiliaryDataInfoDataDescription as String]
            as? [String: Any]
        let hdrGainMapWidth = auxiliaryDimension(
            from: hdrGainMapDescription,
            primaryKey: kCGImagePropertyWidth as String,
            fallbackKey: "Width"
        )
        let hdrGainMapHeight = auxiliaryDimension(
            from: hdrGainMapDescription,
            primaryKey: kCGImagePropertyHeight as String,
            fallbackKey: "Height"
        )

        let hdrGainMapMetadataPlist: Data? = {
            guard let info = hdrGainMapInfo,
                  let metadata = info[kCGImageAuxiliaryDataInfoMetadata as String] else { return nil }
            return serializeImageMetadata(metadata)
        }()

        // Step 9 — Source category.
        let category = classifySource(
            fileExtension: fileExtension,
            utTypeIdentifier: utTypeString,
            bitsPerComponent: bitsPerComponent,
            hasAlpha: hasAlpha,
            hasHDRGainMap: hdrGainMapData != nil,
            tiffDictionary: tiffDictionary,
            markerAppleDictionary: markerAppleDictionary
        )

        // Cross-app "ImagingSuite" markers may live in EXIF UserComment, TIFF/PNG Software,
        // TIFF ImageDescription, or structured XMP. The independent TIFF probe covers suite
        // writer tags that ImageIO does not always surface (e.g. renderer ImageDescription).
        let rawMarkers: [String?] = [
            stringValue(exifDictionary?[kCGImagePropertyExifUserComment as String]),
            stringValue(tiffDictionary?[kCGImagePropertyTIFFSoftware as String]),
            stringValue(tiffDictionary?[kCGImagePropertyTIFFImageDescription as String]),
            stringValue(pngDictionary?[kCGImagePropertyPNGSoftware as String]),
            stringValue(properties[kCGImagePropertyProfileName as String]),
            tiffProbe?.imageDescription,
            tiffProbe?.software,
        ] + xmpStringValues(from: source)
        let markerText = normalizedMarkerText(rawMarkers)
        let history = rawMarkers.compactMap { $0.flatMap(ImageProcessingHistory.parse) }.first

        // Value-aware parsing: an explicit `Denoised=false` must win over a stale marker and
        // must never be reported as denoised.
        let isAlreadyDenoisedBySuite = markerBoolValue(for: ["denoised"], in: markerText) ?? false
        let isAlreadyDenoisedByNoiser = markerBoolValue(for: ["noiserdenoised"], in: markerText) ?? false
        let upscaledByAppFactor = markerIntValue(for: "upscaledfactor", in: markerText)
        let isAlreadyUpscaledBySuite = markerBoolValue(for: ["upscaledbyapp", "upscaled"], in: markerText)
            ?? (upscaledByAppFactor != nil
                || markerText.contains("upscaled=true")
                || markerText.contains("upscaled:true"))

        // DNG / RAW parameters. The DNG dictionary is only populated by ImageIO for true raw containers.
        let isRawSource = category == .cameraRAW || category == .appleProRAW
        let rawParameters = extractRawParameters(
            isRawSource: isRawSource,
            dngDictionary: dngDictionary,
            tiffDictionary: tiffDictionary
        )

        let isLinearDNG = isLinearRawDNG(properties: properties)
            || tiffProbe?.photometricInterpretation == 34892
        let suiteMarkerText = normalizedMarkerText([
            tiffProbe?.imageDescription,
            tiffProbe?.software,
            stringValue(tiffDictionary?[kCGImagePropertyTIFFImageDescription as String]),
            stringValue(tiffDictionary?[kCGImagePropertyTIFFSoftware as String]),
        ])
        let hasSuiteLinearDNGMarker = isLinearDNG && suiteMarkerText.contains("truongscaler")
        let linearHeadroomScale = resolveHeadroomScale(
            markerText: markerText,
            dngDictionary: dngDictionary,
            probe: tiffProbe
        )

        // Step 10 — Serialize a plist-safe copy of the complete property dictionary.
        let sanitizedProperties = sanitizeForPlist(properties)
        let rawPropertiesPlistData: Data? = {
            guard PropertyListSerialization.propertyList(sanitizedProperties, isValidFor: .binary) else {
                return nil
            }
            return try? PropertyListSerialization.data(
                fromPropertyList: sanitizedProperties,
                format: .binary,
                options: 0
            )
        }()

        // Step 11 — Return the fully populated packet.
        return ImageMetadataPacket(
            sourceURL: imageURL,
            utTypeIdentifier: utTypeString,
            category: category,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            originalOrientation: orientation,
            bitsPerComponent: bitsPerComponent,
            hasAlpha: hasAlpha,
            isoSpeedRatings: iso,
            rawPropertiesPlistData: rawPropertiesPlistData,
            iccProfileData: extractICCProfileData(from: source),
            hdrGainMapAuxiliaryData: hdrGainMapData,
            hdrGainMapWidth: hdrGainMapWidth,
            hdrGainMapHeight: hdrGainMapHeight,
            hdrGainMapMetadataPlist: hdrGainMapMetadataPlist,
            rawParameters: rawParameters,
            isAlreadyDenoisedBySuite: isAlreadyDenoisedBySuite,
            isAlreadyUpscaledBySuite: isAlreadyUpscaledBySuite,
            isLinearDNG: isLinearDNG,
            upscaledByAppFactor: upscaledByAppFactor,
            isAlreadyDenoisedByNoiser: isAlreadyDenoisedByNoiser,
            linearHeadroomScale: linearHeadroomScale,
            hasSuiteLinearDNGMarker: hasSuiteLinearDNGMarker,
            hdrGainMapAuxiliaryType: hdrGainMapAuxiliaryType,
            processingHistory: history
        )
    }
}

// MARK: - Suite Rendered Linear DNG Fallback

private extension MetadataExtractor {
    /// ImageIO reports a rendered LinearRaw DNG as `public.tiff` and returns no decoded property
    /// dictionary. For a trusted suite file (LinearRaw + suite marker) build the packet from the
    /// independent TIFF probe instead of failing extraction. Non-suite sources still fail.
    static func suiteLinearDNGMetadataFallback(
        imageURL: URL,
        probe: LinearDNGFileInfo?,
        utTypeIdentifier: String,
        fileExtension: String
    ) -> ImageMetadataPacket? {
        guard let probe,
              probe.photometricInterpretation == 34892,
              probe.width > 0,
              probe.height > 0 else { return nil }
        let markerText = normalizedMarkerText([probe.imageDescription, probe.software])
        guard markerText.contains("truongscaler") else { return nil }

        let denoised = markerBoolValue(for: ["denoised"], in: markerText) ?? false
        let noiserDenoised = markerBoolValue(for: ["noiserdenoised"], in: markerText) ?? false
        let factor = markerIntValue(for: "upscaledfactor", in: markerText)
        let upscaled = markerBoolValue(for: ["upscaledbyapp", "upscaled"], in: markerText)
            ?? (factor != nil)
        let headroom: Float? = {
            // New HDR DNGs declare the authoritative peak in DNG ProfileDynamicRange
            // (HintMaxOutputValue); the ImageDescription marker is descriptive only.
            if let hint = probe.profileDynamicRangeHint, hint.isFinite, hint > 0 {
                return clampedHeadroom(hint)
            }
            if let scale = markerFloatValue(for: "headroomscale", in: markerText) {
                return clampedHeadroom(scale)
            }
            if let baseline = probe.baselineExposure {
                return clampedHeadroom(Float(pow(2.0, Double(baseline))))
            }
            return nil
        }()
        let category: SourceImageCategory = fileExtension == "dng" ? .cameraRAW : .standardOpaqueRaster
        let embedded = probe.embeddedMetadata
        let rawPropertiesPlistData = suiteDNGPropertiesPlistData(
            embedded,
            imageDescription: probe.imageDescription
        )
        let rawParameters = embedded.map {
            CameraRAWParameters(cameraMake: $0.cameraMake, cameraModel: $0.cameraModel)
        }
        return ImageMetadataPacket(
            sourceURL: imageURL,
            utTypeIdentifier: utTypeIdentifier.isEmpty ? "com.adobe.raw-image" : utTypeIdentifier,
            category: category,
            originalWidth: probe.width,
            originalHeight: probe.height,
            originalOrientation: probe.orientation,
            bitsPerComponent: 16,
            hasAlpha: false,
            isoSpeedRatings: embedded?.iso,
            rawPropertiesPlistData: rawPropertiesPlistData,
            rawParameters: rawParameters,
            isAlreadyDenoisedBySuite: denoised,
            isAlreadyUpscaledBySuite: upscaled,
            isLinearDNG: true,
            upscaledByAppFactor: factor,
            isAlreadyDenoisedByNoiser: noiserDenoised,
            linearHeadroomScale: headroom,
            hasSuiteLinearDNGMarker: true,
            processingHistory: probe.imageDescription.flatMap(ImageProcessingHistory.parse)
        )
    }

    /// Rebuilds the ImageIO-shaped property list from the rendered DNG's own TIFF/EXIF/GPS tags,
    /// so a second export preserves capture time, exposure, ISO, lens, camera identity and GPS.
    static func suiteDNGPropertiesPlistData(
        _ metadata: LinearDNGEmbeddedMetadata?,
        imageDescription: String?
    ) -> Data? {
        var root: [String: Any] = [:]
        var tiff: [String: Any] = [:]
        var exif: [String: Any] = [:]
        var gps: [String: Any] = [:]

        if let metadata {
            if let value = metadata.cameraMake { tiff[kCGImagePropertyTIFFMake as String] = value }
            if let value = metadata.cameraModel { tiff[kCGImagePropertyTIFFModel as String] = value }
            if let value = metadata.dateTime { tiff[kCGImagePropertyTIFFDateTime as String] = value }
            if let value = metadata.dateTimeOriginal {
                exif[kCGImagePropertyExifDateTimeOriginal as String] = value
            }
            if let value = metadata.dateTimeDigitized {
                exif[kCGImagePropertyExifDateTimeDigitized as String] = value
            }
            if let value = metadata.exposureTime {
                exif[kCGImagePropertyExifExposureTime as String] = value
            }
            if let value = metadata.fNumber {
                exif[kCGImagePropertyExifFNumber as String] = value
            }
            if let value = metadata.iso {
                exif[kCGImagePropertyExifISOSpeedRatings as String] = [value]
            }
            if let value = metadata.focalLength {
                exif[kCGImagePropertyExifFocalLength as String] = value
            }
            if let value = metadata.lensMake {
                exif[kCGImagePropertyExifLensMake as String] = value
            }
            if let value = metadata.lensModel {
                exif[kCGImagePropertyExifLensModel as String] = value
            }
            if let value = metadata.userComment {
                exif[kCGImagePropertyExifUserComment as String] = value
            }
            if let value = metadata.gpsLatitude {
                gps[kCGImagePropertyGPSLatitude as String] = abs(value)
                gps[kCGImagePropertyGPSLatitudeRef as String] = metadata.gpsLatitudeRef
                    ?? (value < 0 ? "S" : "N")
            }
            if let value = metadata.gpsLongitude {
                gps[kCGImagePropertyGPSLongitude as String] = abs(value)
                gps[kCGImagePropertyGPSLongitudeRef as String] = metadata.gpsLongitudeRef
                    ?? (value < 0 ? "W" : "E")
            }
            if let value = metadata.gpsAltitude {
                gps[kCGImagePropertyGPSAltitude as String] = value
                gps[kCGImagePropertyGPSAltitudeRef as String] = metadata.gpsAltitudeRef
                    ?? (value < 0 ? 1 : 0)
            }
        }
        if let imageDescription {
            tiff[kCGImagePropertyTIFFImageDescription as String] = imageDescription
        }
        if !tiff.isEmpty { root[kCGImagePropertyTIFFDictionary as String] = tiff }
        if !exif.isEmpty { root[kCGImagePropertyExifDictionary as String] = exif }
        if !gps.isEmpty { root[kCGImagePropertyGPSDictionary as String] = gps }
        guard !root.isEmpty,
              PropertyListSerialization.propertyList(root, isValidFor: .binary) else { return nil }
        return try? PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
    }
}

// MARK: - Value Coercion Helpers

private extension MetadataExtractor {
    static func intValue(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    static func numberValue(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let float = value as? Float { return Double(float) }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func boolValue(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    static func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let data = value as? Data {
            return String(data: data, encoding: .utf8)
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func floatArrayValue(_ value: Any?) -> [Float]? {
        guard let value else { return nil }
        if let array = value as? [Any] {
            let floats = array.compactMap { numberValue($0).map(Float.init) }
            return floats.isEmpty ? nil : floats
        }
        if let array = value as? NSArray {
            let floats = array.compactMap { numberValue($0).map(Float.init) }
            return floats.isEmpty ? nil : floats
        }
        if let scalar = numberValue(value) { return [Float(scalar)] }
        return nil
    }

    static func isoValue(from exif: [String: Any]?) -> Int? {
        guard let exif else { return nil }
        if let ratings = exif[kCGImagePropertyExifISOSpeedRatings as String] {
            if let scalar = intValue(ratings) { return scalar }
            if let array = ratings as? [Any] {
                return array.compactMap { intValue($0) }.first
            }
            if let array = ratings as? NSArray {
                return array.compactMap { intValue($0) }.first
            }
        }
        // Apple occasionally writes EXIF 2.3 `ISOSpeed` instead of the legacy ratings array.
        return intValue(exif[kCGImagePropertyExifISOSpeed as String])
    }
}

// MARK: - Classification Helpers

private extension MetadataExtractor {
    static func classifySource(
        fileExtension: String,
        utTypeIdentifier: String,
        bitsPerComponent: Int,
        hasAlpha: Bool,
        hasHDRGainMap: Bool,
        tiffDictionary: [String: Any]?,
        markerAppleDictionary: [String: Any]?
    ) -> SourceImageCategory {
        // Apple ProRAW is a DNG that carries a MakerApple maker-note with an Apple/ProRAW fingerprint.
        if fileExtension == "dng" {
            let make = stringValue(tiffDictionary?[kCGImagePropertyTIFFMake as String])?.lowercased() ?? ""
            let model = stringValue(tiffDictionary?[kCGImagePropertyTIFFModel as String])?.lowercased() ?? ""
            let software = stringValue(tiffDictionary?[kCGImagePropertyTIFFSoftware as String])?.lowercased() ?? ""
            let hasMakerApple = markerAppleDictionary.map { !$0.isEmpty } ?? false
            let hasProRAWMarker = containsProRAWMarker(markerAppleDictionary)
                || make.contains("apple")
                || model.contains("apple")
                || software.contains("apple")
                || software.contains("proraw")
            if hasMakerApple && hasProRAWMarker {
                return .appleProRAW
            }
        }

        let conformsToRaw = UTType(utTypeIdentifier)?.conforms(to: .rawImage) == true
        if rawFileExtensions.contains(fileExtension) || conformsToRaw {
            return .cameraRAW
        }

        let lowercasedUTType = utTypeIdentifier.lowercased()
        let isHEIFContainer = lowercasedUTType.contains("heic") || lowercasedUTType.contains("heif")
        if isHEIFContainer && (bitsPerComponent >= 10 || hasHDRGainMap) {
            return .hdrHEIC
        }

        return hasAlpha ? .standardAlphaRaster : .standardOpaqueRaster
    }

    static func containsProRAWMarker(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let string = value as? String {
            return string.lowercased().contains("proraw")
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.contains { key, nestedValue in
                key.lowercased().contains("proraw") || containsProRAWMarker(nestedValue)
            }
        }
        if let array = value as? [Any] {
            return array.contains { containsProRAWMarker($0) }
        }
        if let dictionary = value as? NSDictionary {
            for (key, nestedValue) in dictionary {
                if let key = key as? String, key.lowercased().contains("proraw") {
                    return true
                }
                if containsProRAWMarker(nestedValue) { return true }
            }
        }
        return false
    }

    static func extractRawParameters(
        isRawSource: Bool,
        dngDictionary: [String: Any]?,
        tiffDictionary: [String: Any]?
    ) -> CameraRAWParameters? {
        guard isRawSource || dngDictionary != nil else { return nil }
        let cameraMake = stringValue(tiffDictionary?[kCGImagePropertyTIFFMake as String])
        let cameraModel = stringValue(tiffDictionary?[kCGImagePropertyTIFFModel as String])
            ?? stringValue(dngDictionary?[kCGImagePropertyDNGUniqueCameraModel as String])
            ?? stringValue(dngDictionary?[kCGImagePropertyDNGLocalizedCameraModel as String])
        return CameraRAWParameters(
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            colorMatrix1: floatArrayValue(dngDictionary?[kCGImagePropertyDNGColorMatrix1 as String]),
            colorMatrix2: floatArrayValue(dngDictionary?[kCGImagePropertyDNGColorMatrix2 as String]),
            asShotNeutral: floatArrayValue(dngDictionary?[kCGImagePropertyDNGAsShotNeutral as String]),
            baselineExposure: numberValue(dngDictionary?[kCGImagePropertyDNGBaselineExposure as String])
                .map(Float.init),
            blackLevel: floatArrayValue(dngDictionary?[kCGImagePropertyDNGBlackLevel as String]),
            whiteLevel: numberValue(dngDictionary?[kCGImagePropertyDNGWhiteLevel as String]).map(Float.init)
        )
    }

    static func isLinearRawDNG(properties: [String: Any]) -> Bool {
        // DNG PhotometricInterpretation == 34892 (`LinearRaw`). ImageIO exposes the TIFF/EP tag under the
        // TIFF dictionary on macOS; also accept a raw DNG-dictionary spelling for forward compatibility.
        let tiffDictionary = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let dngDictionary = properties[kCGImagePropertyDNGDictionary as String] as? [String: Any]
        let candidates: [Any?] = [
            tiffDictionary?[kCGImagePropertyTIFFPhotometricInterpretation as String],
            dngDictionary?[kCGImagePropertyTIFFPhotometricInterpretation as String],
            dngDictionary?["PhotometricInterpretation"],
            properties[kCGImagePropertyTIFFPhotometricInterpretation as String],
            properties["PhotometricInterpretation"],
        ]
        return candidates.contains { intValue($0) == 34892 }
    }
}

// MARK: - HDR Gain Map Helpers

private extension MetadataExtractor {
    static func auxiliaryDimension(
        from description: [String: Any]?,
        primaryKey: String,
        fallbackKey: String
    ) -> Int? {
        guard let description else { return nil }
        return intValue(description[primaryKey]) ?? intValue(description[fallbackKey])
    }

    static func serializeImageMetadata(_ value: Any) -> Data? {
        if let data = value as? Data { return data }
        if CFGetTypeID(value as CFTypeRef) != CGImageMetadataGetTypeID() {
            if let dictionary = value as? [String: Any] {
                let sanitized = sanitizeForPlist(dictionary)
                guard PropertyListSerialization.propertyList(sanitized, isValidFor: .binary) else {
                    return nil
                }
                return try? PropertyListSerialization.data(
                    fromPropertyList: sanitized,
                    format: .binary,
                    options: 0
                )
            }
            return nil
        }

        // swiftlint:disable:next force_cast -- CFGetTypeID above verifies the Core Foundation type.
        let metadata = value as! CGImageMetadata
        var tagEntries: [[String: Any]] = []
        let options = [kCGImageMetadataEnumerateRecursively: true] as CFDictionary
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, options) { path, tag in
            var entry: [String: Any] = [:]
            if let path = path as String? {
                entry["path"] = path
            }
            if let name = CGImageMetadataTagCopyName(tag) as String? {
                entry["name"] = name
            }
            if let prefix = CGImageMetadataTagCopyPrefix(tag) as String? {
                entry["prefix"] = prefix
            }
            if let namespace = CGImageMetadataTagCopyNamespace(tag) as String? {
                entry["namespace"] = namespace
            }
            if let tagValue = CGImageMetadataTagCopyValue(tag),
               let sanitized = sanitizeValueForPlist(tagValue) {
                entry["value"] = sanitized
            }
            if !entry.isEmpty {
                tagEntries.append(entry)
            }
            return true
        }
        guard !tagEntries.isEmpty else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: tagEntries, format: .binary, options: 0)
    }

    static func xmpStringValues(from source: CGImageSource) -> [String] {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return [] }
        var values: [String] = []
        let options = [kCGImageMetadataEnumerateRecursively: true] as CFDictionary
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, options) { path, tag in
            guard let tagValue = CGImageMetadataTagCopyValue(tag),
                  let string = stringValue(tagValue) else { return true }
            if let path = path as String? {
                // XMP stores the property name separately from its value. Keep the association so a
                // structured `ImagingSuite:Denoised` Boolean is recognized just like an EXIF marker.
                values.append("\(path)=\(string)")
            } else {
                values.append(string)
            }
            return true
        }
        return values
    }
}

// MARK: - Cross-App Marker Helpers

private extension MetadataExtractor {
    static func normalizedMarkerText(_ components: [String?]) -> String {
        components
            .compactMap { $0 }
            .joined(separator: "\n")
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
    }

    /// Finds `key=value` only when `key` starts a marker component, so `noiserdenoised=` does
    /// not accidentally satisfy a `denoised=` search.
    static func markerValue(for key: String, in text: String) -> String? {
        let keyPrefixDelimiters: Set<Character> = [";", ",", ":", "\n", "\t", "{", "(", "/", "|", " "]
        let valueDelimiters: Set<Character> = [";", ",", "\n", "\t", "}", ")", "|", " ", "\"", "'", "\0", "<", ">"]
        var searchStart = text.startIndex
        while let range = text.range(of: key, range: searchStart..<text.endIndex) {
            let precedesKey = range.lowerBound == text.startIndex
                || keyPrefixDelimiters.contains(text[text.index(before: range.lowerBound)])
            searchStart = range.upperBound
            guard precedesKey else { continue }
            guard searchStart < text.endIndex, text[searchStart] == "=" else { continue }
            var value = ""
            var index = text.index(after: searchStart)
            while index < text.endIndex {
                let character = text[index]
                if valueDelimiters.contains(character) { break }
                value.append(character)
                index = text.index(after: index)
            }
            return value
        }
        return nil
    }

    static func markerBoolValue(for keys: [String], in text: String) -> Bool? {
        for key in keys {
            guard let value = markerValue(for: key, in: text), !value.isEmpty else { continue }
            if value == "1" || value.hasPrefix("true") || value.hasPrefix("yes") {
                return true
            }
            if value == "0" || value.hasPrefix("false") || value.hasPrefix("no") {
                return false
            }
        }
        return nil
    }

    static func markerIntValue(for key: String, in text: String) -> Int? {
        guard let value = markerValue(for: key, in: text) else { return nil }
        let digits = value.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    static func markerFloatValue(for key: String, in text: String) -> Float? {
        guard let value = markerValue(for: key, in: text) else { return nil }
        let numeric = value.prefix { character in
            character.isNumber || character == "." || character == "e" || character == "+" || character == "-"
        }
        guard !numeric.isEmpty else { return nil }
        return Float(numeric)
    }

    /// Resolves the linear headroom scale `H` from the new DNG `ProfileDynamicRange`
    /// `HintMaxOutputValue`, then the suite marker, then legacy DNG `BaselineExposure`,
    /// clamped to the representable Float16 range. Nil when the source records none.
    static func resolveHeadroomScale(
        markerText: String,
        dngDictionary: [String: Any]?,
        probe: LinearDNGFileInfo?
    ) -> Float? {
        if let hint = probe?.profileDynamicRangeHint, hint.isFinite, hint > 0 {
            return clampedHeadroom(hint)
        }
        if let scale = markerFloatValue(for: "headroomscale", in: markerText) {
            return clampedHeadroom(scale)
        }
        let baselines: [Float?] = [
            numberValue(dngDictionary?[kCGImagePropertyDNGBaselineExposure as String]).map(Float.init),
            probe?.baselineExposure,
            markerFloatValue(for: "baselineexposure", in: markerText),
        ]
        for baseline in baselines {
            guard let baseline, baseline.isFinite else { continue }
            return clampedHeadroom(Float(pow(2.0, Double(baseline))))
        }
        return nil
    }

    static func clampedHeadroom(_ value: Float) -> Float? {
        guard value.isFinite, value > 0 else { return nil }
        return min(max(value, 1.0), 65_504.0)
    }
}

// MARK: - ICC Profile & Plist Sanitization Helpers

private extension MetadataExtractor {
    static func extractICCProfileData(from source: CGImageSource) -> Data? {
        // Thumbnail generation shares the source's embedded color profile but avoids decoding a full-size
        // 48MP raster merely to read its ICC payload.
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailWithTransform: false,
        ]
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        guard let image, let colorSpace = image.colorSpace, let profile = colorSpace.copyICCData() else {
            return nil
        }
        return profile as Data
    }

    static func sanitizeForPlist(_ dictionary: [String: Any]) -> [String: Any] {
        var sanitized: [String: Any] = [:]
        for (key, value) in dictionary {
            if let safeValue = sanitizeValueForPlist(value) {
                sanitized[key] = safeValue
            }
        }
        return sanitized
    }

    static func sanitizeValueForPlist(_ value: Any) -> Any? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number }
        if let data = value as? Data { return data }
        if let date = value as? Date { return date }
        if let array = value as? [Any] {
            return array.compactMap { sanitizeValueForPlist($0) }
        }
        if let dictionary = value as? [String: Any] {
            return sanitizeForPlist(dictionary)
        }
        if let dictionary = value as? NSDictionary {
            var sanitized: [String: Any] = [:]
            for (key, nestedValue) in dictionary {
                guard let key = key as? String,
                      let safeValue = sanitizeValueForPlist(nestedValue) else { continue }
                sanitized[key] = safeValue
            }
            return sanitized
        }

        // Fall back to CoreFoundation type inspection for CF values that do not bridge through `as?`.
        let typeID = CFGetTypeID(value as CFTypeRef)
        switch typeID {
        case CFStringGetTypeID():
            return value as? String
        case CFNumberGetTypeID(), CFBooleanGetTypeID():
            return value as? NSNumber
        case CFDataGetTypeID():
            return value as? Data
        case CFDateGetTypeID():
            return value as? Date
        case CFArrayGetTypeID():
            guard let array = value as? [Any] else { return nil }
            return array.compactMap { sanitizeValueForPlist($0) }
        case CFDictionaryGetTypeID():
            guard let dictionary = value as? NSDictionary else { return nil }
            var sanitized: [String: Any] = [:]
            for (key, nestedValue) in dictionary {
                guard let key = key as? String,
                      let safeValue = sanitizeValueForPlist(nestedValue) else { continue }
                sanitized[key] = safeValue
            }
            return sanitized
        default:
            // Color spaces, CGImageMetadata refs, etc. are not property-list types.
            return nil
        }
    }
}
