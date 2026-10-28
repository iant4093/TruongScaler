import Foundation
import ImageIO
import TruongScalerCore
import DNGWriterBridge

/// Logical pipeline state applied to the rendered Linear DNG metadata.
///
/// All four markers are written explicitly, including `false`, so a re-ingested file cannot
/// inherit a stale `true`. `headroomScale` is the rendered headroom `H` (`BaselineExposure =
/// log2(H)`), not the source camera's exposure.
public struct DNGExportPipelineState: Sendable, Equatable {
    public var upscaledByApp: Bool
    public var upscaledFactor: Int?
    public var denoised: Bool
    public var noiserDenoised: Bool
    public var processingHistory: ImageProcessingHistory?
    public var headroomScale: Float

    public init(
        upscaledByApp: Bool = false,
        upscaledFactor: Int? = nil,
        denoised: Bool = false,
        noiserDenoised: Bool = false,
        headroomScale: Float = 1,
        processingHistory: ImageProcessingHistory? = nil
    ) {
        self.processingHistory = processingHistory
        self.upscaledByApp = upscaledByApp
        self.upscaledFactor = upscaledFactor
        self.denoised = denoised
        self.noiserDenoised = noiserDenoised
        self.headroomScale = headroomScale.isFinite && headroomScale > 0 ? headroomScale : 1
    }
}

/// Immutable, Sendable bundle of DNG header metadata for `TSWriteStreamingLinearDNG16`.
///
/// `entries` are `DNGMetadataEntry` values whose `data` pointers refer to buffers owned by
/// this object, so the payload must stay alive until the C writer call completes (the writer
/// also copies the bytes during the call).
public final class DNGExportMetadata: @unchecked Sendable {
    public let entries: [DNGMetadataEntry]
    public let xmpData: Data?
    public let imageDescription: String
    public let userComment: String
    public let software: String
    public let cameraMake: String?
    public let cameraModel: String?
    public let uniqueCameraModel: String?
    public let dateTime: String?
    public let orientation: UInt16
    public let headroomScale: Float
    /// Rendered linear Display P3 `ColorMatrix1` (XYZ(D65) -> linear Display P3), row-major.
    public let colorMatrix1: [Float]
    /// Rendered pixels are white-balanced, so `AsShotNeutral` is `{1,1,1}`.
    public let asShotNeutral: [Float]
    /// Always 0 for newly written files. Kept so callers can pass it to the C config; the
    /// previous headroom multiplier convention is read-only backward compatibility.
    public let baselineExposure: Float

    // ---- R8 representation fields (surface them to `DNGLinearExportConfig`) ----
    /// TIFF SampleFormat written to tag 339: `1` unsigned integer (SDR), `3` IEEE Float16 (HDR).
    public let sampleFormat: UInt16
    /// `1` writes DNG ProfileDynamicRange (tag 52551) for an HDR profile; `0` omits it (SDR).
    public let profileDynamicRange: UInt16
    /// HDR `HintMaxOutputValue` (absolute linear component peak); `0` when omitted.
    public let hintMaxOutputValue: Float
    /// DNG `ColorimetricReference` (tag 50879): `1` perceptual SDR, `2` output-referred HDR.
    public let colorimetricReference: UInt16
    /// `WhiteLevel` (tag 50717): `65535` for UInt16 SDR, `1` for floating point samples.
    public let whiteLevel: UInt16
    public let dngVersionMajor: UInt16
    public let dngVersionMinor: UInt16
    public let dngVersionPatch: UInt16
    public let dngVersionBuild: UInt16
    public let dngBackwardVersionMajor: UInt16
    public let dngBackwardVersionMinor: UInt16
    public let dngBackwardVersionPatch: UInt16
    public let dngBackwardVersionBuild: UInt16

    /// True when the file declares an HDR profile (float samples + ProfileDynamicRange).
    public var isHDR: Bool { profileDynamicRange == 1 }
    /// True when samples are IEEE floating point bit patterns.
    public var usesFloatSamples: Bool { sampleFormat == 3 }
    public var dngVersion: [UInt16] {
        [dngVersionMajor, dngVersionMinor, dngVersionPatch, dngVersionBuild]
    }
    public var dngBackwardVersion: [UInt16] {
        [dngBackwardVersionMajor, dngBackwardVersionMinor,
         dngBackwardVersionPatch, dngBackwardVersionBuild]
    }

    private let ownedBuffers: [OwnedBuffer]

    fileprivate init(
        pendingEntries: [PendingEntry],
        xmpData: Data?,
        imageDescription: String,
        userComment: String,
        software: String,
        cameraMake: String?,
        cameraModel: String?,
        uniqueCameraModel: String?,
        dateTime: String?,
        orientation: UInt16,
        headroomScale: Float,
        colorMatrix1: [Float],
        sampleFormat: UInt16,
        profileDynamicRange: UInt16,
        hintMaxOutputValue: Float,
        colorimetricReference: UInt16,
        whiteLevel: UInt16,
        dngVersion: (UInt16, UInt16, UInt16, UInt16),
        dngBackwardVersion: (UInt16, UInt16, UInt16, UInt16)
    ) {
        var buffers: [OwnedBuffer] = []
        buffers.reserveCapacity(pendingEntries.count)
        var converted: [DNGMetadataEntry] = []
        converted.reserveCapacity(pendingEntries.count)
        for pending in pendingEntries {
            let buffer = OwnedBuffer(bytes: pending.payload)
            buffers.append(buffer)
            converted.append(DNGMetadataEntry(
                tag: pending.tag,
                ifd: pending.ifd,
                type: pending.type,
                count: pending.count,
                data: UnsafeRawPointer(buffer.pointer)
            ))
        }
        self.ownedBuffers = buffers
        self.entries = converted
        self.xmpData = xmpData
        self.imageDescription = imageDescription
        self.userComment = userComment
        self.software = software
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.uniqueCameraModel = uniqueCameraModel
        self.dateTime = dateTime
        self.orientation = orientation
        self.headroomScale = headroomScale
        self.colorMatrix1 = colorMatrix1
        self.asShotNeutral = [1, 1, 1]
        self.baselineExposure = 0
        self.sampleFormat = sampleFormat
        self.profileDynamicRange = profileDynamicRange
        self.hintMaxOutputValue = hintMaxOutputValue
        self.colorimetricReference = colorimetricReference
        self.whiteLevel = whiteLevel
        self.dngVersionMajor = dngVersion.0
        self.dngVersionMinor = dngVersion.1
        self.dngVersionPatch = dngVersion.2
        self.dngVersionBuild = dngVersion.3
        self.dngBackwardVersionMajor = dngBackwardVersion.0
        self.dngBackwardVersionMinor = dngBackwardVersion.1
        self.dngBackwardVersionPatch = dngBackwardVersion.2
        self.dngBackwardVersionBuild = dngBackwardVersion.3
    }
}

/// Builds the rendered Linear DNG metadata/additive EXIF/GPS/XMP payload from a source
/// `ImageMetadataPacket`. Group B (`FormatAwareExporter`) calls this from
/// `exportLinearDNG`; the source camera's raw calibration is never forwarded to the writer.
///
/// Preserved fields: capture time (`DateTimeOriginal`/`DateTimeDigitized`), exposure time,
/// FNumber, ISO, focal length, lens make/model, Make/Model, GPS latitude/longitude/altitude
/// with refs, unrelated EXIF `UserComment` components, and the rendered working-space
/// calibration. MakerNote bytes are not exposed by ImageIO and are documented as not
/// preserved.
public enum DNGExportMetadataBuilder {
    /// Rendered working-space ColorMatrix1 from contract §2 (XYZ(D65) -> linear Display P3).
    public static let linearDisplayP3InverseXYZ: [Float] = [
         2.4934969, -0.9313836, -0.4027108,
        -0.8294890,  1.7626641,  0.0236247,
         0.0358458, -0.0761724,  0.9568845,
    ]

    /// Builds metadata using the packet's additive pipeline state.
    public static func build(metadata: ImageMetadataPacket) -> DNGExportMetadata {
        let state = DNGExportPipelineState(
            upscaledByApp: metadata.isAlreadyUpscaledBySuite,
            upscaledFactor: metadata.upscaledByAppFactor,
            denoised: metadata.isAlreadyDenoisedBySuite || metadata.isAlreadyDenoisedByNoiser,
            noiserDenoised: metadata.isAlreadyDenoisedByNoiser,
            headroomScale: metadata.linearHeadroomScale ?? 1
        )
        return build(metadata: metadata, pipelineState: state)
    }

    /// Builds metadata with an explicit actual pipeline state (the exporter knows what ran).
    ///
    /// The optional `headroomScale` is the measured **final** component peak (`H`) of the
    /// grain-blended artifact; when nil, `pipelineState.headroomScale` is used. `sampleFormat`
    /// is the explicit representation decision (`1` = UInt16 SDR, `3` = Float16 HDR, `0` =
    /// derive from `H`). H > 1 + 1e-4 always resolves to Float16 HDR; requesting integer
    /// samples for an overrange artifact is upgraded to Float16 so overrange is never clipped.
    public static func build(
        metadata: ImageMetadataPacket,
        pipelineState: DNGExportPipelineState,
        headroomScale: Float? = nil,
        sampleFormat: UInt16 = 0
    ) -> DNGExportMetadata {
        let resolved = resolvedRepresentation(
            headroomScale: headroomScale ?? pipelineState.headroomScale,
            requestedSampleFormat: sampleFormat
        )
        var effectiveState = pipelineState
        effectiveState.processingHistory = pipelineState.processingHistory ?? metadata.processingHistory
        effectiveState.headroomScale = resolved.headroomScale
        let properties = deserializeProperties(metadata.rawPropertiesPlistData)
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]

        let cameraMake = nonEmpty(metadata.rawParameters?.cameraMake)
            ?? nonEmpty(stringValue(tiff[kCGImagePropertyTIFFMake as String]))
        let cameraModel = nonEmpty(metadata.rawParameters?.cameraModel)
            ?? nonEmpty(stringValue(tiff[kCGImagePropertyTIFFModel as String]))
        let uniqueCameraModel = cameraModel ?? "TruongScaler Linear RAW"

        let originalDescription = nonEmpty(stringValue(tiff[kCGImagePropertyTIFFImageDescription as String]))
        let userComment = mergedUserComment(
            original: extractUserComment(exif[kCGImagePropertyExifUserComment as String]),
            state: effectiveState
        )
        let imageDescription = mergedImageDescription(
            headroomScale: resolved.hdr ? resolved.headroomScale : 1,
            state: effectiveState,
            original: originalDescription,
            sampleFormat: resolved.sampleFormat
        )
        let software = "TruongScaler 1.0 (ImagingSuite)"
        let dateTime = nonEmpty(stringValue(exif[kCGImagePropertyExifDateTimeOriginal as String]))
            ?? nonEmpty(stringValue(tiff[kCGImagePropertyTIFFDateTime as String]))

        var entries: [PendingEntry] = []

        // EXIF IFD -------------------------------------------------------------
        if let original = nonEmpty(stringValue(exif[kCGImagePropertyExifDateTimeOriginal as String])) {
            entries.append(asciiEntry(tag: 36867, ifd: 1, value: truncatedDateTime(original)))
        }
        if let digitized = nonEmpty(stringValue(exif[kCGImagePropertyExifDateTimeDigitized as String])) {
            entries.append(asciiEntry(tag: 36868, ifd: 1, value: truncatedDateTime(digitized)))
        }
        if let exposure = numberValue(exif[kCGImagePropertyExifExposureTime as String]), exposure > 0 {
            entries.append(rationalEntry(tag: 33434, ifd: 1, values: [exposure]))
        }
        if let fNumber = numberValue(exif[kCGImagePropertyExifFNumber as String]), fNumber > 0 {
            entries.append(rationalEntry(tag: 33437, ifd: 1, values: [fNumber]))
        }
        if let iso = isoValue(exif: exif, fallback: metadata.isoSpeedRatings), iso > 0 {
            entries.append(shortEntry(tag: 34855, ifd: 1, value: UInt16(clamping: iso)))
        }
        if let focalLength = numberValue(exif[kCGImagePropertyExifFocalLength as String]), focalLength > 0 {
            entries.append(rationalEntry(tag: 37386, ifd: 1, values: [focalLength]))
        }
        if let lensMake = nonEmpty(stringValue(exif[kCGImagePropertyExifLensMake as String])) {
            entries.append(asciiEntry(tag: 42035, ifd: 1, value: lensMake))
        }
        if let lensModel = nonEmpty(stringValue(exif[kCGImagePropertyExifLensModel as String])) {
            entries.append(asciiEntry(tag: 42036, ifd: 1, value: lensModel))
        }
        entries.append(userCommentEntry(tag: 37510, ifd: 1, value: userComment))

        // GPS IFD --------------------------------------------------------------
        if let latitude = gpsDegrees(gps[kCGImagePropertyGPSLatitude as String]),
           let longitude = gpsDegrees(gps[kCGImagePropertyGPSLongitude as String]) {
            let latitudeRef = gpsReference(gps[kCGImagePropertyGPSLatitudeRef as String], positive: "N", negative: "S", signValue: latitude)
            let longitudeRef = gpsReference(gps[kCGImagePropertyGPSLongitudeRef as String], positive: "E", negative: "W", signValue: longitude)
            entries.append(byteEntry(tag: 0, ifd: 2, value: [2, 3, 0, 0])) // GPSVersionID
            entries.append(asciiEntry(tag: 1, ifd: 2, value: latitudeRef))
            entries.append(rationalEntry(tag: 2, ifd: 2, values: coordinateTriplet(abs(latitude))))
            entries.append(asciiEntry(tag: 3, ifd: 2, value: longitudeRef))
            entries.append(rationalEntry(tag: 4, ifd: 2, values: coordinateTriplet(abs(longitude))))
            if let altitude = numberValue(gps[kCGImagePropertyGPSAltitude as String]) {
                let altitudeRef = (altitude < 0) ? UInt8(1) : UInt8(0)
                entries.append(byteEntry(tag: 5, ifd: 2, value: [altitudeRef]))
                entries.append(rationalEntry(tag: 6, ifd: 2, values: [abs(altitude)]))
            }
        }

        let xmpData = buildXMP(
            software: software,
            imageDescription: imageDescription,
            state: effectiveState,
            cameraMake: cameraMake,
            cameraModel: cameraModel
        ).data(using: .utf8)

        return DNGExportMetadata(
            pendingEntries: entries,
            xmpData: xmpData,
            imageDescription: imageDescription,
            userComment: userComment,
            software: software,
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            uniqueCameraModel: uniqueCameraModel,
            dateTime: dateTime,
            orientation: 1,
            headroomScale: resolved.hdr ? resolved.headroomScale : 1,
            colorMatrix1: linearDisplayP3InverseXYZ,
            sampleFormat: resolved.sampleFormat,
            profileDynamicRange: resolved.hdr ? 1 : 0,
            hintMaxOutputValue: resolved.hdr ? resolved.headroomScale : 0,
            colorimetricReference: resolved.hdr ? 2 : 1,
            whiteLevel: resolved.sampleFormat == 3 ? 1 : 65_535,
            dngVersion: resolved.hdr ? (1, 7, 0, 0) : (1, 4, 0, 0),
            dngBackwardVersion: resolved.hdr ? (1, 7, 0, 0) : (1, 1, 0, 0)
        )
    }

    /// Resolved representation decision for one export.
    public struct DNGRepresentation: Sendable, Equatable {
        /// Logical headroom `H` (>= 1); the measured final component peak.
        public let headroomScale: Float
        /// `1` = UInt16 SDR, `3` = IEEE Float16.
        public let sampleFormat: UInt16
        /// True when ProfileDynamicRange/ColorimetricReference 2/DNG 1.7 apply.
        public let hdr: Bool
    }

    /// Applies the contract representation rule: `H <= 1 + 1e-4` is quantized UInt16 SDR;
    /// `H > 1 + 1e-4` is absolute Float16 HDR. Values are clamped to the Float16 range.
    public static func resolvedRepresentation(
        headroomScale: Float,
        requestedSampleFormat: UInt16 = 0
    ) -> DNGRepresentation {
        let raw = headroomScale.isFinite && headroomScale > 0 ? headroomScale : 1
        let headroom = min(max(raw, 1), 65_504)
        let hdr = headroom > 1 + 1e-4
        let requested = requestedSampleFormat
        let sampleFormat: UInt16
        switch requested {
        case 3:
            sampleFormat = 3
        case 1:
            // 16-bit integers cannot represent overrange without clipping; upgrade to Float16.
            sampleFormat = hdr ? 3 : 1
        default:
            sampleFormat = hdr ? 3 : 1
        }
        return DNGRepresentation(
            headroomScale: headroom,
            sampleFormat: sampleFormat,
            hdr: hdr && sampleFormat == 3
        )
    }

    // MARK: - Marker text

    public static func mergedImageDescription(
        headroomScale: Float,
        state: DNGExportPipelineState,
        original: String?,
        sampleFormat: UInt16 = 0
    ) -> String {
        let safeScale = headroomScale.isFinite && headroomScale > 0 ? headroomScale : 1
        let ev = log2(Double(safeScale))
        var components = [
            "TruongScaler Linear DNG",
        ]
        if sampleFormat == 3 {
            components.append("SampleFormat=Float16")
        }
        components.append(contentsOf: [
            "WorkingSpace=LinearDisplayP3",
            "HeadroomScale=\(format(safeScale))",
            "HeadroomEV=\(format(Float(ev)))",
        ])
        components.append(contentsOf: pipelineComponents(state: state))
        if let original, !original.lowercased().contains("truongscaler") {
            components.append("OriginalDescription=\(singleLine(original))")
        }
        return components.joined(separator: "; ")
    }

    public static func mergedUserComment(original: String?, state: DNGExportPipelineState) -> String {
        let preserved = sanitizedUserCommentComponents(original).filter { !(state.processingHistory != nil && $0.hasPrefix("ProcessingHistoryV1=")) }
        return (pipelineComponents(state: state) + preserved).joined(separator: ";")
    }

    /// The four pipeline markers with explicit true/false values.
    public static func pipelineComponents(state: DNGExportPipelineState) -> [String] {
        let factor = max(1, state.upscaledFactor ?? 1)
        var components = [
            "UpscaledByApp=\(state.upscaledByApp ? "true" : "false")",
            "ScalerUpscaled=\(state.upscaledByApp ? "true" : "false")",
            "UpscaledFactor=\(factor)x",
            "Denoised=\(state.denoised ? "true" : "false")",
            "NoiserDenoised=\(state.noiserDenoised ? "true" : "false")",
        ]
        if let marker = state.processingHistory?.marker { components.append(marker) }
        return components
    }

    public static func sanitizedUserCommentComponents(_ original: String?) -> [String] {
        guard let original, !original.isEmpty else { return [] }
        let ownedFragments = [
            "denoised=",
            "upscaledbyapp=",
            "scalerupscaled=",
            "upscaledfactor=",
            "noiserdenoised=",
            "upscaled=",
            "imagingsuite:denoised",
            "imagingsuite:upscaled",
        ]
        return original
            .replacingOccurrences(of: "\n", with: ";")
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { component in
                let lowered = component.lowercased()
                return !ownedFragments.contains { lowered.contains($0) }
            }
    }

    // MARK: - XMP

    public static func buildXMP(
        software: String,
        imageDescription: String,
        state: DNGExportPipelineState,
        cameraMake: String?,
        cameraModel: String?
    ) -> String {
        let factor = max(1, state.upscaledFactor ?? 1)
        let makeAttribute = cameraMake.map { "\n    tiff:Make=\"\(xmlEscape($0))\"" } ?? ""
        let modelAttribute = cameraModel.map { "\n    tiff:Model=\"\(xmlEscape($0))\"" } ?? ""
        return """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:tiff="http://ns.adobe.com/tiff/1.0/"
            xmlns:ImagingSuite="https://truongimaging.example/pipeline/1.0/"
            xmp:CreatorTool="\(xmlEscape(software))"
            ImagingSuite:Denoised="\(state.denoised ? "true" : "false")"
            ImagingSuite:UpscaledByApp="\(state.upscaledByApp ? "true" : "false")"
            ImagingSuite:UpscaledFactor="\(factor)x"
            ImagingSuite:NoiserDenoised="\(state.noiserDenoised ? "true" : "false")"
            ImagingSuite:HeadroomScale="\(format(state.headroomScale))"
            ImagingSuite:WorkingSpace="LinearDisplayP3"\(makeAttribute)\(modelAttribute)>
           <dc:description>
            <rdf:Alt>
             <rdf:li xml:lang="x-default">\(xmlEscape(imageDescription))</rdf:li>
            </rdf:Alt>
           </dc:description>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    // MARK: - Property extraction helpers

    private static func deserializeProperties(_ data: Data?) -> [String: Any] {
        guard let data,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else { return [:] }
        return dictionary
    }

    private static func isoValue(exif: [String: Any], fallback: Int?) -> Int? {
        if let ratings = exif[kCGImagePropertyExifISOSpeedRatings as String] {
            if let number = ratings as? NSNumber { return number.intValue }
            if let array = ratings as? [Any] {
                for item in array {
                    if let number = item as? NSNumber { return number.intValue }
                }
            }
        }
        if let value = numberValue(exif[kCGImagePropertyExifISOSpeed as String]) {
            return Int(value)
        }
        return fallback
    }

    private static func extractUserComment(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let string = raw as? String { return string }
        var bytes: [UInt8]?
        if let data = raw as? Data { bytes = [UInt8](data) }
        if let data = raw as? NSData { bytes = [UInt8](data) }
        guard var commentBytes = bytes else { return nil }
        if commentBytes.count >= 8 {
            let asciiPrefix = Array("ASCII\0\0\0".utf8)
            if Array(commentBytes.prefix(8)) == asciiPrefix {
                commentBytes.removeFirst(8)
            }
        }
        return String(bytes: commentBytes, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    private static func gpsDegrees(_ raw: Any?) -> Double? {
        guard let raw else { return nil }
        if let number = raw as? NSNumber { return number.doubleValue }
        if let string = raw as? String {
            let separators = CharacterSet(charactersIn: ", ")
            let parts = string.components(separatedBy: separators).compactMap(Double.init)
            if parts.count >= 3 {
                return parts[0] + parts[1] / 60 + parts[2] / 3600
            }
            return Double(string.replacingOccurrences(of: ",", with: "."))
        }
        if let array = raw as? [Any] {
            let values = array.compactMap { ($0 as? NSNumber)?.doubleValue }
            if values.count >= 3 {
                return values[0] + values[1] / 60 + values[2] / 3600
            }
        }
        return nil
    }

    private static func gpsReference(_ raw: Any?, positive: String, negative: String, signValue: Double) -> String {
        let fallback = signValue < 0 ? negative : positive
        guard let string = stringValue(raw)?.uppercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return fallback
        }
        let first = String(string.prefix(1))
        if first == positive || first == negative { return first }
        return fallback
    }

    private static func coordinateTriplet(_ degrees: Double) -> [Double] {
        let safe = max(0, degrees)
        let wholeDegrees = floor(safe)
        let minutesTotal = (safe - wholeDegrees) * 60
        let wholeMinutes = floor(minutesTotal)
        let seconds = (minutesTotal - wholeMinutes) * 60
        return [wholeDegrees, wholeMinutes, seconds]
    }

    private static func truncatedDateTime(_ value: String) -> String {
        String(value.prefix(19))
    }

    private static func singleLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: ";", with: ",")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let data = value as? Data { return String(data: data, encoding: .utf8) }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func numberValue(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let float = value as? Float { return Double(float) }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func format(_ value: Float) -> String {
        let formatted = String(format: "%.6g", Double(value))
        return formatted
    }
}

// MARK: - Entry encoding helpers

private enum TIFFType: UInt16 {
    case byte = 1
    case ascii = 2
    case short = 3
    case long = 4
    case rational = 5
    case undefined = 7
}

private struct PendingEntry {
    let tag: UInt16
    let ifd: UInt16
    let type: UInt16
    let count: UInt32
    let payload: [UInt8]
}

private final class OwnedBuffer {
    let pointer: UnsafeMutableRawPointer

    init(bytes: [UInt8]) {
        let count = max(bytes.count, 1)
        pointer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        if !bytes.isEmpty {
            bytes.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    pointer.copyMemory(from: base, byteCount: bytes.count)
                }
            }
        }
    }

    deinit {
        pointer.deallocate()
    }
}

private extension DNGExportMetadataBuilder {
    static func asciiEntry(tag: UInt16, ifd: UInt16, value: String) -> PendingEntry {
        var payload = Array(value.utf8)
        payload.append(0)
        return PendingEntry(tag: tag, ifd: ifd, type: TIFFType.ascii.rawValue, count: UInt32(payload.count), payload: payload)
    }

    static func undefinedEntry(tag: UInt16, ifd: UInt16, value: String) -> PendingEntry {
        let marker = Array("ASCII\0\0\0".utf8)
        let payload = marker + Array(value.utf8)
        return PendingEntry(tag: tag, ifd: ifd, type: TIFFType.undefined.rawValue, count: UInt32(payload.count), payload: payload)
    }

    static func userCommentEntry(tag: UInt16, ifd: UInt16, value: String) -> PendingEntry {
        undefinedEntry(tag: tag, ifd: ifd, value: value)
    }

    static func shortEntry(tag: UInt16, ifd: UInt16, value: UInt16) -> PendingEntry {
        PendingEntry(
            tag: tag,
            ifd: ifd,
            type: TIFFType.short.rawValue,
            count: 1,
            payload: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
        )
    }

    static func byteEntry(tag: UInt16, ifd: UInt16, value: [UInt8]) -> PendingEntry {
        PendingEntry(tag: tag, ifd: ifd, type: TIFFType.byte.rawValue, count: UInt32(value.count), payload: value)
    }

    static func rationalEntry(tag: UInt16, ifd: UInt16, values: [Double]) -> PendingEntry {
        var payload: [UInt8] = []
        payload.reserveCapacity(values.count * 8)
        for value in values {
            let (numerator, denominator) = rationalize(value)
            appendLittleEndian(numerator, to: &payload)
            appendLittleEndian(denominator, to: &payload)
        }
        return PendingEntry(
            tag: tag,
            ifd: ifd,
            type: TIFFType.rational.rawValue,
            count: UInt32(values.count),
            payload: payload
        )
    }

    static func rationalize(_ value: Double) -> (UInt32, UInt32) {
        guard value.isFinite, value > 0 else { return (0, 1) }
        if abs(value - value.rounded()) < 1e-9, value.rounded() <= Double(UInt32.max) {
            return (UInt32(value.rounded()), 1)
        }
        let candidates: [UInt32] = [10, 100, 1000, 10_000, 100_000, 1_000_000]
        var bestNumerator: UInt32 = 1
        var bestDenominator: UInt32 = 1
        var bestError = Double.greatestFiniteMagnitude
        for denominator in candidates {
            let scaled = value * Double(denominator)
            guard scaled <= Double(UInt32.max) else { continue }
            let numerator = UInt32(scaled.rounded())
            let error = abs(value - Double(numerator) / Double(denominator))
            if error < bestError {
                bestError = error
                bestNumerator = numerator
                bestDenominator = denominator
            }
        }
        let divisor = greatestCommonDivisor(bestNumerator, bestDenominator)
        if divisor > 1 {
            bestNumerator /= divisor
            bestDenominator /= divisor
        }
        return (bestNumerator, bestDenominator)
    }

    static func greatestCommonDivisor(_ a: UInt32, _ b: UInt32) -> UInt32 {
        var x = a
        var y = b
        while y != 0 {
            let remainder = x % y
            x = y
            y = remainder
        }
        return max(x, 1)
    }

    static func appendLittleEndian(_ value: UInt32, to payload: inout [UInt8]) {
        payload.append(UInt8(value & 0xFF))
        payload.append(UInt8((value >> 8) & 0xFF))
        payload.append(UInt8((value >> 16) & 0xFF))
        payload.append(UInt8((value >> 24) & 0xFF))
    }
}
