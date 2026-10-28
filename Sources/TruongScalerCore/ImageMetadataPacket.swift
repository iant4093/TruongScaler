import Foundation

/// Classification of the source image container (`docs/DEVELOPMENT.md` Section 4.4).
public enum SourceImageCategory: String, Codable, Sendable, Equatable {
    case cameraRAW
    case appleProRAW
    case hdrHEIC
    case standardAlphaRaster
    case standardOpaqueRaster
}

/// Which Apple/ISO auxiliary HDR gain map a source exposed. Recorded additively so a stale
/// legacy gain map is never silently treated as an ISO gain map (or vice versa).
public enum HDRGainMapAuxiliaryType: String, Codable, Sendable, Equatable {
    case legacyHDRGainMap
    case isoGainMap
}

/// Extracted DNG/RAW camera color and white balance parameters (`docs/DEVELOPMENT.md` Section 4.4).
public struct CameraRAWParameters: Codable, Sendable, Equatable {
    public let cameraMake: String?
    public let cameraModel: String?
    public let colorMatrix1: [Float]?
    public let colorMatrix2: [Float]?
    public let asShotNeutral: [Float]?
    public let baselineExposure: Float?
    public let blackLevel: [Float]?
    public let whiteLevel: Float?

    public init(
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        colorMatrix1: [Float]? = nil,
        colorMatrix2: [Float]? = nil,
        asShotNeutral: [Float]? = nil,
        baselineExposure: Float? = nil,
        blackLevel: [Float]? = nil,
        whiteLevel: Float? = nil
    ) {
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.colorMatrix1 = colorMatrix1
        self.colorMatrix2 = colorMatrix2
        self.asShotNeutral = asShotNeutral
        self.baselineExposure = baselineExposure
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
    }
}

/// Complete extracted source image metadata packet (`docs/DEVELOPMENT.md` Section 4.4).
///
/// The four pipeline/headroom fields are additive. They use a hand-written `Codable`
/// implementation so checkpoints/manifests written before the repair still decode with
/// their historic defaults instead of failing.
public struct ImageMetadataPacket: Codable, Sendable, Equatable {
    public let processingHistory: ImageProcessingHistory?
    public let sourceURL: URL
    public let utTypeIdentifier: String
    public let category: SourceImageCategory
    public let originalWidth: Int
    public let originalHeight: Int
    public let originalOrientation: Int
    public let bitsPerComponent: Int
    public let hasAlpha: Bool
    public let isoSpeedRatings: Int?
    public let rawPropertiesPlistData: Data?
    public let iccProfileData: Data?
    public let hdrGainMapAuxiliaryData: Data?
    public let hdrGainMapWidth: Int?
    public let hdrGainMapHeight: Int?
    public let hdrGainMapMetadataPlist: Data?
    public let rawParameters: CameraRAWParameters?
    public let isAlreadyDenoisedBySuite: Bool
    public let isAlreadyUpscaledBySuite: Bool
    public let isLinearDNG: Bool

    /// Actual completed in-app upscale factor (`UpscaledFactor=<n>x`), or nil when not upscaled.
    public let upscaledByAppFactor: Int?
    /// `NoiserDenoised=true` state of the upstream TruongNoiser pass (default false).
    public let isAlreadyDenoisedByNoiser: Bool
    /// Linear headroom scale `H` recorded by the suite DNG writer (`HeadroomScale=`/BaselineExposure).
    public let linearHeadroomScale: Float?
    /// True only when the source is a rendered suite LinearRaw DNG identified by the suite marker.
    public let hasSuiteLinearDNGMarker: Bool
    /// Which auxiliary gain-map type the source exposed (additive; nil when none).
    public let hdrGainMapAuxiliaryType: HDRGainMapAuxiliaryType?

    public init(
        sourceURL: URL,
        utTypeIdentifier: String,
        category: SourceImageCategory,
        originalWidth: Int,
        originalHeight: Int,
        originalOrientation: Int = 1,
        bitsPerComponent: Int = 16,
        hasAlpha: Bool = false,
        isoSpeedRatings: Int? = nil,
        rawPropertiesPlistData: Data? = nil,
        iccProfileData: Data? = nil,
        hdrGainMapAuxiliaryData: Data? = nil,
        hdrGainMapWidth: Int? = nil,
        hdrGainMapHeight: Int? = nil,
        hdrGainMapMetadataPlist: Data? = nil,
        rawParameters: CameraRAWParameters? = nil,
        isAlreadyDenoisedBySuite: Bool = false,
        isAlreadyUpscaledBySuite: Bool = false,
        isLinearDNG: Bool = false,
        upscaledByAppFactor: Int? = nil,
        isAlreadyDenoisedByNoiser: Bool = false,
        linearHeadroomScale: Float? = nil,
        hasSuiteLinearDNGMarker: Bool = false,
        hdrGainMapAuxiliaryType: HDRGainMapAuxiliaryType? = nil,
        processingHistory: ImageProcessingHistory? = nil
    ) {
        self.processingHistory = processingHistory
        self.sourceURL = sourceURL
        self.utTypeIdentifier = utTypeIdentifier
        self.category = category
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
        self.originalOrientation = originalOrientation
        self.bitsPerComponent = bitsPerComponent
        self.hasAlpha = hasAlpha
        self.isoSpeedRatings = isoSpeedRatings
        self.rawPropertiesPlistData = rawPropertiesPlistData
        self.iccProfileData = iccProfileData
        self.hdrGainMapAuxiliaryData = hdrGainMapAuxiliaryData
        self.hdrGainMapWidth = hdrGainMapWidth
        self.hdrGainMapHeight = hdrGainMapHeight
        self.hdrGainMapMetadataPlist = hdrGainMapMetadataPlist
        self.rawParameters = rawParameters
        self.isAlreadyDenoisedBySuite = isAlreadyDenoisedBySuite
        self.isAlreadyUpscaledBySuite = isAlreadyUpscaledBySuite
        self.isLinearDNG = isLinearDNG
        self.upscaledByAppFactor = upscaledByAppFactor
        self.isAlreadyDenoisedByNoiser = isAlreadyDenoisedByNoiser
        self.linearHeadroomScale = linearHeadroomScale
        self.hasSuiteLinearDNGMarker = hasSuiteLinearDNGMarker
        self.hdrGainMapAuxiliaryType = hdrGainMapAuxiliaryType
    }

    // MARK: - Codable (additive defaults for old checkpoints/manifests)

    private enum CodingKeys: String, CodingKey {
        case sourceURL
        case processingHistory
        case utTypeIdentifier
        case category
        case originalWidth
        case originalHeight
        case originalOrientation
        case bitsPerComponent
        case hasAlpha
        case isoSpeedRatings
        case rawPropertiesPlistData
        case iccProfileData
        case hdrGainMapAuxiliaryData
        case hdrGainMapWidth
        case hdrGainMapHeight
        case hdrGainMapMetadataPlist
        case rawParameters
        case isAlreadyDenoisedBySuite
        case isAlreadyUpscaledBySuite
        case isLinearDNG
        case upscaledByAppFactor
        case isAlreadyDenoisedByNoiser
        case linearHeadroomScale
        case hasSuiteLinearDNGMarker
        case hdrGainMapAuxiliaryType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        processingHistory = try container.decodeIfPresent(ImageProcessingHistory.self, forKey: .processingHistory)
        sourceURL = try container.decode(URL.self, forKey: .sourceURL)
        utTypeIdentifier = try container.decodeIfPresent(String.self, forKey: .utTypeIdentifier) ?? ""
        category = try container.decodeIfPresent(SourceImageCategory.self, forKey: .category) ?? .standardOpaqueRaster
        originalWidth = try container.decodeIfPresent(Int.self, forKey: .originalWidth) ?? 0
        originalHeight = try container.decodeIfPresent(Int.self, forKey: .originalHeight) ?? 0
        originalOrientation = try container.decodeIfPresent(Int.self, forKey: .originalOrientation) ?? 1
        bitsPerComponent = try container.decodeIfPresent(Int.self, forKey: .bitsPerComponent) ?? 8
        hasAlpha = try container.decodeIfPresent(Bool.self, forKey: .hasAlpha) ?? false
        isoSpeedRatings = try container.decodeIfPresent(Int.self, forKey: .isoSpeedRatings)
        rawPropertiesPlistData = try container.decodeIfPresent(Data.self, forKey: .rawPropertiesPlistData)
        iccProfileData = try container.decodeIfPresent(Data.self, forKey: .iccProfileData)
        hdrGainMapAuxiliaryData = try container.decodeIfPresent(Data.self, forKey: .hdrGainMapAuxiliaryData)
        hdrGainMapWidth = try container.decodeIfPresent(Int.self, forKey: .hdrGainMapWidth)
        hdrGainMapHeight = try container.decodeIfPresent(Int.self, forKey: .hdrGainMapHeight)
        hdrGainMapMetadataPlist = try container.decodeIfPresent(Data.self, forKey: .hdrGainMapMetadataPlist)
        rawParameters = try container.decodeIfPresent(CameraRAWParameters.self, forKey: .rawParameters)
        isAlreadyDenoisedBySuite = try container.decodeIfPresent(Bool.self, forKey: .isAlreadyDenoisedBySuite) ?? false
        isAlreadyUpscaledBySuite = try container.decodeIfPresent(Bool.self, forKey: .isAlreadyUpscaledBySuite) ?? false
        isLinearDNG = try container.decodeIfPresent(Bool.self, forKey: .isLinearDNG) ?? false
        upscaledByAppFactor = try container.decodeIfPresent(Int.self, forKey: .upscaledByAppFactor)
        isAlreadyDenoisedByNoiser = try container.decodeIfPresent(Bool.self, forKey: .isAlreadyDenoisedByNoiser) ?? false
        linearHeadroomScale = try container.decodeIfPresent(Float.self, forKey: .linearHeadroomScale)
        hasSuiteLinearDNGMarker = try container.decodeIfPresent(Bool.self, forKey: .hasSuiteLinearDNGMarker) ?? false
        hdrGainMapAuxiliaryType = try container.decodeIfPresent(HDRGainMapAuxiliaryType.self, forKey: .hdrGainMapAuxiliaryType)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(processingHistory, forKey: .processingHistory)
        try container.encode(sourceURL, forKey: .sourceURL)
        try container.encode(utTypeIdentifier, forKey: .utTypeIdentifier)
        try container.encode(category, forKey: .category)
        try container.encode(originalWidth, forKey: .originalWidth)
        try container.encode(originalHeight, forKey: .originalHeight)
        try container.encode(originalOrientation, forKey: .originalOrientation)
        try container.encode(bitsPerComponent, forKey: .bitsPerComponent)
        try container.encode(hasAlpha, forKey: .hasAlpha)
        try container.encodeIfPresent(isoSpeedRatings, forKey: .isoSpeedRatings)
        try container.encodeIfPresent(rawPropertiesPlistData, forKey: .rawPropertiesPlistData)
        try container.encodeIfPresent(iccProfileData, forKey: .iccProfileData)
        try container.encodeIfPresent(hdrGainMapAuxiliaryData, forKey: .hdrGainMapAuxiliaryData)
        try container.encodeIfPresent(hdrGainMapWidth, forKey: .hdrGainMapWidth)
        try container.encodeIfPresent(hdrGainMapHeight, forKey: .hdrGainMapHeight)
        try container.encodeIfPresent(hdrGainMapMetadataPlist, forKey: .hdrGainMapMetadataPlist)
        try container.encodeIfPresent(rawParameters, forKey: .rawParameters)
        try container.encode(isAlreadyDenoisedBySuite, forKey: .isAlreadyDenoisedBySuite)
        try container.encode(isAlreadyUpscaledBySuite, forKey: .isAlreadyUpscaledBySuite)
        try container.encode(isLinearDNG, forKey: .isLinearDNG)
        try container.encodeIfPresent(upscaledByAppFactor, forKey: .upscaledByAppFactor)
        try container.encode(isAlreadyDenoisedByNoiser, forKey: .isAlreadyDenoisedByNoiser)
        try container.encodeIfPresent(linearHeadroomScale, forKey: .linearHeadroomScale)
        try container.encode(hasSuiteLinearDNGMarker, forKey: .hasSuiteLinearDNGMarker)
        try container.encodeIfPresent(hdrGainMapAuxiliaryType, forKey: .hdrGainMapAuxiliaryType)
    }

    // MARK: - Pipeline state

    /// Snapshot of the additive pipeline state carried by this packet.
    public var pipelineSessionState: PipelineSessionState {
        PipelineSessionState(
            isDenoised: isAlreadyDenoisedBySuite,
            isUpscaled: isAlreadyUpscaledBySuite,
            upscaleFactor: upscaledByAppFactor,
            linearHeadroomScale: linearHeadroomScale,
            isDenoisedByNoiser: isAlreadyDenoisedByNoiser,
            processingHistory: processingHistory
        )
    }

    /// Merges a validated session state into this packet. `nil` fields preserve the current value;
    /// an explicit `false` clears an inherited true marker. Used by the executor after a fresh
    /// decode/resume so handoff-only state is not discarded when the source file is re-decoded.
    public func merging(sessionState: PipelineSessionState?) -> ImageMetadataPacket {
        guard let sessionState, !sessionState.isEmpty else { return self }
        return withPipelineState(
            isDenoised: sessionState.isDenoised,
            isUpscaled: sessionState.isUpscaled,
            upscaledByAppFactor: sessionState.upscaleFactor,
            linearHeadroomScale: sessionState.linearHeadroomScale,
            isAlreadyDenoisedByNoiser: sessionState.isDenoisedByNoiser,
            processingHistory: sessionState.processingHistory
        )
    }

    /// Applies a consumed cross-app handoff payload to the ingested metadata.
    ///
    /// Group D calls this from `StudioViewModel.handleIncomingHandoffURL` so the payload's
    /// denoise/upscale/factor/headroom state is recorded on the session metadata instead of
    /// being reflected only in the image path. `linearHeadroomScale` is clamped to a finite
    /// value >= 1.0; the payload's `globalMaxLuminance`/`globalMaxLinearComponent` are the
    /// independent headroom signal.
    public func applyingSuiteHandoff(
        isDenoised: Bool,
        isUpscaled: Bool,
        upscaleFactor: Int?,
        linearHeadroomScale: Float,
        denoisedByNoiser: Bool? = nil
    ) -> ImageMetadataPacket {
        withPipelineState(
            isDenoised: isDenoised,
            isUpscaled: isUpscaled,
            upscaledByAppFactor: upscaleFactor,
            linearHeadroomScale: linearHeadroomScale,
            isAlreadyDenoisedByNoiser: denoisedByNoiser
        )
    }

    /// Returns a copy with additive pipeline/headroom state replaced.
    ///
    /// Passing `nil` for a flag keeps the existing value, so callers must pass an explicit
    /// `false` to clear a stale `true` (the same rule the marker writer follows).
    public func withPipelineState(
        isDenoised: Bool? = nil,
        isUpscaled: Bool? = nil,
        upscaledByAppFactor: Int? = nil,
        linearHeadroomScale: Float? = nil,
        isAlreadyDenoisedByNoiser: Bool? = nil,
        processingHistory: ImageProcessingHistory? = nil
    ) -> ImageMetadataPacket {
        let resolvedHeadroom: Float? = {
            if let linearHeadroomScale, linearHeadroomScale.isFinite, linearHeadroomScale > 0 {
                return linearHeadroomScale
            }
            return self.linearHeadroomScale
        }()
        return ImageMetadataPacket(
            sourceURL: sourceURL,
            utTypeIdentifier: utTypeIdentifier,
            category: category,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            originalOrientation: originalOrientation,
            bitsPerComponent: bitsPerComponent,
            hasAlpha: hasAlpha,
            isoSpeedRatings: isoSpeedRatings,
            rawPropertiesPlistData: rawPropertiesPlistData,
            iccProfileData: iccProfileData,
            hdrGainMapAuxiliaryData: hdrGainMapAuxiliaryData,
            hdrGainMapWidth: hdrGainMapWidth,
            hdrGainMapHeight: hdrGainMapHeight,
            hdrGainMapMetadataPlist: hdrGainMapMetadataPlist,
            rawParameters: rawParameters,
            isAlreadyDenoisedBySuite: isDenoised ?? isAlreadyDenoisedBySuite,
            isAlreadyUpscaledBySuite: isUpscaled ?? isAlreadyUpscaledBySuite,
            isLinearDNG: isLinearDNG,
            upscaledByAppFactor: upscaledByAppFactor ?? self.upscaledByAppFactor,
            isAlreadyDenoisedByNoiser: isAlreadyDenoisedByNoiser ?? self.isAlreadyDenoisedByNoiser,
            linearHeadroomScale: resolvedHeadroom,
            hasSuiteLinearDNGMarker: hasSuiteLinearDNGMarker,
            hdrGainMapAuxiliaryType: hdrGainMapAuxiliaryType,
            processingHistory: processingHistory ?? self.processingHistory
        )
    }

    /// Smart Output Routing (`docs/DEVELOPMENT.md` Section 4.4).
    public func resolvedExportFormat(from requested: ExportFormat) -> ExportFormat {
        if requested != .autoMatchSource {
            return requested
        }
        switch category {
        case .cameraRAW, .appleProRAW:
            return .linearDNG16Bit
        case .hdrHEIC:
            return .heic10BitHDR
        case .standardAlphaRaster:
            return .png16Bit
        case .standardOpaqueRaster:
            return hasAlpha ? .png16Bit : .jpeg95
        }
    }

    public func shouldRunDenoiser(mode: DenoiseMode) -> Bool {
        switch mode {
        case .forceOn:
            return true
        case .off:
            return false
        case .auto:
            if isAlreadyDenoisedBySuite || isAlreadyDenoisedByNoiser {
                return false
            }
            let lowerUT = utTypeIdentifier.lowercased()
            let lowerExt = sourceURL.pathExtension.lowercased()
            if lowerUT == "public.jpeg" || lowerExt == "jpg" || lowerExt == "jpeg" {
                return true
            }
            if let iso = isoSpeedRatings, iso >= 800 {
                return true
            }
            return false
        }
    }
}
