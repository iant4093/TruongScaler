import Foundation
import ImageIO
import CoreGraphics
import TruongScalerCore

/// Reconstructs the complete `ImageIO` property dictionary from `ImageMetadataPacket`
/// and updates dimensions, orientation, and `ImagingSuite` pipeline tags.
/// Specification: `docs/DEVELOPMENT.md` Section 2.1.
public struct MetadataReinjector: Sendable {
    /// Canonical software attribution written to the `{TIFF}` dictionary on every export.
    /// Pipeline flags carry machine-readable processing history.
    public static let softwareTag = "TruongScaler (ImagingSuite)"
    /// Cross-app marker consumed by TruongNoiser / TruongScaler ingestion.
    public static let imagingSuiteMarker = "UpscaledByApp=true"

    public static func buildDestinationProperties(
        from metadata: ImageMetadataPacket,
        upscaledWidth: Int,
        upscaledHeight: Int,
        exportFormat: ExportFormat,
        actualSourceWidth: Int? = nil,
        actualSourceHeight: Int? = nil,
        actualScaleFactor: Int? = nil
    ) -> [CFString: Any] {
        // Step 1 — Deserialize the source property list. Malformed or absent payloads are
        // treated as an empty dictionary: export must never fail because of bad metadata.
        var root = deserializeProperties(metadata.rawPropertiesPlistData)

        let width = upscaledWidth > 0 ? upscaledWidth : max(1, metadata.originalWidth)
        let height = upscaledHeight > 0 ? upscaledHeight : max(1, metadata.originalHeight)

        // Step 2 — Top-level pixel dimensions & orientation. Orientation 1 is correct because
        // Stage 1 already baked EXIF orientation into the decoded RGBA16F source.
        var topLevelPatch: [String: Any] = [
            kCGImagePropertyPixelWidth as String: width,
            kCGImagePropertyPixelHeight as String: height,
            kCGImagePropertyOrientation as String: 1
        ]
        if let profileName = iccProfileName(from: metadata.iccProfileData) {
            topLevelPatch[kCGImagePropertyProfileName as String] = profileName
        }
        root = mergeDictionaries(root, topLevelPatch)

        // Step 3 — EXIF dictionary: updated pixel dimensions + explicit ImagingSuite pipeline state
        // in `UserComment`. The factor and both boolean states are written even when false so a
        // previous true marker cannot be inherited by a later non-denoised/non-upscaled export.
        // Every unrelated EXIF key and user-comment component is preserved (deep merge).
        // The exported canvas dimensions are the authoritative actual factor. Use the upright
        // decoded source dimensions when the caller provides them (the exporter does); otherwise
        // fall back to orientation-aware metadata dimensions, never a stale selector/source factor.
        let scaleFactor = actualScaleFactor ?? derivedScaleFactor(
            sourceWidth: actualSourceWidth ?? orientedSourceWidth(metadata),
            upscaledWidth: width
        )
        var tagString = pipelineTags(
            scaleFactor: scaleFactor,
            wasDenoised: metadata.isAlreadyDenoisedBySuite,
            isUpscaled: true,
            noiserDenoised: metadata.isAlreadyDenoisedByNoiser
        )
        if let marker = metadata.processingHistory?.marker { tagString += ";" + marker }
        var exif = dictionary(root[kCGImagePropertyExifDictionary as String])
        let existingComment = normalizedUserComment(exif[kCGImagePropertyExifUserComment as String])
        let preservedComment = existingComment?
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isPipelineTagComponent($0) && !(metadata.processingHistory != nil && $0.hasPrefix("ProcessingHistoryV1=")) }
            .joined(separator: ";")
        let userComment: String
        if let preservedComment, !preservedComment.isEmpty {
            userComment = "\(preservedComment);\(tagString)"
        } else {
            userComment = tagString
        }
        let exifPatch: [String: Any] = [
            kCGImagePropertyExifPixelXDimension as String: width,
            kCGImagePropertyExifPixelYDimension as String: height,
            kCGImagePropertyExifUserComment as String: userComment
        ]
        exif = mergeDictionaries(exif, exifPatch)
        root[kCGImagePropertyExifDictionary as String] = exif

        // Step 4 — TIFF dictionary: orientation 1 (already baked) + canonical software string.
        var tiff = dictionary(root[kCGImagePropertyTIFFDictionary as String])
        let tiffPatch: [String: Any] = [
            kCGImagePropertyTIFFOrientation as String: 1,
            kCGImagePropertyTIFFSoftware as String: softwareTag
        ]
        tiff = mergeDictionaries(tiff, tiffPatch)

        // Step 5 — Format-specific encoder options.
        switch exportFormat {
        case .jpeg95, .heic10BitHDR:
            root[kCGImageDestinationLossyCompressionQuality as String] = 0.95
        case .tiff16BitLZW:
            tiff[kCGImagePropertyTIFFCompression as String] = 5 // LZW
            root[kCGImagePropertyDepth as String] = 16
        case .png16Bit:
            root[kCGImagePropertyDepth as String] = 16
        case .linearDNG16Bit, .autoMatchSource:
            break
        }
        root[kCGImagePropertyTIFFDictionary as String] = tiff

        // Convert the String-keyed dictionary into the documented `[CFString: Any]` shape.
        var result: [CFString: Any] = [:]
        result.reserveCapacity(root.count)
        for (key, value) in root {
            result[key as CFString] = value
        }
        return result
    }

    // MARK: - Pipeline Tag Helpers

    /// Builds the canonical pipeline marker string, e.g.
    /// `UpscaledByApp=true;UpscaledFactor=4x;Denoised=false;NoiserDenoised=false`.
    ///
    /// All four components are always present. Writing explicit `=false` values is required so a
    /// non-denoised/non-upscaled export cannot inherit a stale `true` marker from its source.
    public static func pipelineTags(
        scaleFactor: Int,
        wasDenoised: Bool,
        isUpscaled: Bool = true,
        noiserDenoised: Bool = false
    ) -> String {
        [
            "UpscaledByApp=\(isUpscaled)",
            "ScalerUpscaled=\(isUpscaled)",
            "UpscaledFactor=\(max(1, scaleFactor))x",
            "Denoised=\(wasDenoised)",
            "NoiserDenoised=\(noiserDenoised)",
        ].joined(separator: ";")
    }

    /// Returns the upright source width. Production passes the decoded source buffer width
    /// explicitly; this fallback handles direct callers and transposing EXIF orientations.
    static func orientedSourceWidth(_ metadata: ImageMetadataPacket) -> Int {
        let orientation = metadata.originalOrientation
        let swapsAxes = (5...8).contains(orientation)
        let width = swapsAxes ? metadata.originalHeight : metadata.originalWidth
        return max(1, width)
    }

    /// Derives the effective scale factor from source vs. upscaled dimensions.
    public static func derivedScaleFactor(sourceWidth: Int, upscaledWidth: Int) -> Int {
        guard sourceWidth > 0, upscaledWidth > 0 else { return 4 }
        let ratio = Double(upscaledWidth) / Double(sourceWidth)
        let rounded = Int(ratio.rounded())
        if rounded >= 3 { return 4 }
        if rounded == 2 { return 2 }
        return max(2, rounded)
    }

    /// Backward-compatible name for callers that only have the metadata width.
    public static func derivedScaleFactor(originalWidth: Int, upscaledWidth: Int) -> Int {
        derivedScaleFactor(sourceWidth: originalWidth, upscaledWidth: upscaledWidth)
    }

    private static func isPipelineTagComponent(_ component: String) -> Bool {
        let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("UpscaledByApp=")
            || trimmed.hasPrefix("ScalerUpscaled=")
            || trimmed.hasPrefix("UpscaledFactor=")
            || trimmed.hasPrefix("Denoised=")
            || trimmed.hasPrefix("NoiserDenoised=")
            || trimmed.hasPrefix("ImagingSuite:")
    }

    private static func normalizedUserComment(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let data as Data:
            return String(data: data, encoding: .utf8)?
                .replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case let array as [String]:
            return array.joined(separator: ";")
        default:
            return nil
        }
    }

    // MARK: - Property List Helpers

    /// Deserializes `rawPropertiesPlistData`, returning an empty dictionary for nil/garbage input.
    static func deserializeProperties(_ data: Data?) -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard
            let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        else {
            return [:]
        }
        if let dictionary = object as? [String: Any] {
            return sanitizedDictionary(dictionary)
        }
        if let dictionary = object as? [AnyHashable: Any] {
            var converted: [String: Any] = [:]
            converted.reserveCapacity(dictionary.count)
            for (key, value) in dictionary {
                guard let stringKey = key as? String else { continue }
                converted[stringKey] = value
            }
            return sanitizedDictionary(converted)
        }
        return [:]
    }

    /// Recursively drops keys whose values cannot be represented in a property list / ImageIO
    /// properties dictionary, keeping the export path crash-free for host-app supplied data.
    private static func sanitizedDictionary(_ dictionary: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        result.reserveCapacity(dictionary.count)
        for (key, value) in dictionary {
            if let sanitized = sanitizeValue(value) {
                result[key] = sanitized
            }
        }
        return result
    }

    private static func sanitizeValue(_ value: Any) -> Any? {
        switch value {
        case let dictionary as [String: Any]:
            return sanitizedDictionary(dictionary)
        case let dictionary as [AnyHashable: Any]:
            var converted: [String: Any] = [:]
            for (key, nestedValue) in dictionary {
                guard let stringKey = key as? String, let sanitized = sanitizeValue(nestedValue) else {
                    continue
                }
                converted[stringKey] = sanitized
            }
            return converted
        case let array as [Any]:
            return array.compactMap { sanitizeValue($0) }
        case is NSNull:
            return nil
        case is String, is NSNumber, is Data, is Date:
            return value
        default:
            return nil
        }
    }

    private static func dictionary(_ value: Any?) -> [String: Any] {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        if let dictionary = value as? [AnyHashable: Any] {
            var converted: [String: Any] = [:]
            for (key, nestedValue) in dictionary {
                if let stringKey = key as? String {
                    converted[stringKey] = nestedValue
                }
            }
            return converted
        }
        return [:]
    }

    /// Recursive deep merge: dictionaries are merged key-by-key, all other values are replaced.
    static func mergeDictionaries(_ base: [String: Any], _ patch: [String: Any]) -> [String: Any] {
        var result = base
        for (key, patchValue) in patch {
            if
                let patchDictionary = patchValue as? [String: Any],
                let baseDictionary = result[key] as? [String: Any]
            {
                result[key] = mergeDictionaries(baseDictionary, patchDictionary)
            } else {
                result[key] = patchValue
            }
        }
        return result
    }

    private static func iccProfileName(from iccData: Data?) -> String? {
        guard let iccData, !iccData.isEmpty else { return nil }
        guard let colorSpace = CGColorSpace(iccData: iccData as CFData) else { return nil }
        return colorSpace.name as String?
    }
}
