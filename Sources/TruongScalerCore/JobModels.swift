import Foundation

/// Super-resolution scale factor (`docs/DEVELOPMENT.md` Section 4.3).
public enum ScaleFactor: Int, Codable, CaseIterable, Sendable, Identifiable {
    case x2 = 2
    case x4 = 4

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .x2: return "2× Super-Resolution"
        case .x4: return "4× Super-Resolution"
        }
    }
}

/// Primary super-resolution backbone model (`docs/DEVELOPMENT.md` Section 4.3).
public struct BackboneModelKind: RawRepresentable, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let quickSRNet = Self(rawValue: "QuickSRNet-Large")
    public static let edsrBaseline = Self(rawValue: "EDSR-baseline")
    public static let hatSmall = Self(rawValue: "HAT_S")
    public static let unavailable = Self(rawValue: "unavailable-model")
    public static var allCases: [Self] { [.quickSRNet, .edsrBaseline, .hatSmall] }
    public var id: String { rawValue }
    public var isSupported: Bool { Self.allCases.contains(self) }
    public var displayName: String {
        switch self {
        case .quickSRNet: return "QuickSRNet (Fast)"
        case .edsrBaseline: return "EDSR (Balanced)"
        case .hatSmall: return "HAT-S (Best)"
        default: return "Previous model"
        }
    }

    /// Describes the intended time/detail tradeoff, without asserting measured phone speed,
    /// accelerator placement or universal image-quality superiority.
    public var processingHint: String {
        switch self {
        case .quickSRNet: return "The fast option for everyday enlargement."
        case .edsrBaseline: return "Balances processing time and detail."
        case .hatSmall: return "A larger, detail-focused model. Expect slower processing."
        default: return "This saved photo retains its original model identity."
        }
    }

    /// QuickSRNet clips internally; the other official regressors return raw overshoot. Allow
    /// bounded edge ringing before display-domain restoration, but refuse large excursions and
    /// non-finite samples. Adversarial checker/noise cases remain errors, never silent fallbacks.
    public var predictionSampleRange: ClosedRange<Float> {
        self == .edsrBaseline || self == .hatSmall ? -0.25...1.25 : -0.02...1.02
    }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
}

/// Pre-upscale denoising mode (`docs/DEVELOPMENT.md` Section 4.3).
public enum DenoiseMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto
    case forceOn
    case off

    public var id: String { rawValue }
}

/// Target export container format (`docs/DEVELOPMENT.md` Section 4.3).
public enum ExportFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case autoMatchSource
    case linearDNG16Bit
    case tiff16BitLZW
    case heic10BitHDR
    case png16Bit
    case jpeg95

    public var id: String { rawValue }
}

/// Session-level pipeline state carried from ingestion/handoff into execution, resume, export and
/// outgoing handoff. `nil` means "preserve the value already on the metadata packet"; an explicit
/// `false` clears an inherited true marker.
public struct PipelineSessionState: Codable, Sendable, Equatable {
    public var isDenoised: Bool?
    public var isUpscaled: Bool?
    public var upscaleFactor: Int?
    public var linearHeadroomScale: Float?
    public var isDenoisedByNoiser: Bool?
    public var processingHistory: ImageProcessingHistory?

    public init(
        isDenoised: Bool? = nil,
        isUpscaled: Bool? = nil,
        upscaleFactor: Int? = nil,
        linearHeadroomScale: Float? = nil,
        isDenoisedByNoiser: Bool? = nil,
        processingHistory: ImageProcessingHistory? = nil
    ) {
        self.isDenoised = isDenoised
        self.isUpscaled = isUpscaled
        self.upscaleFactor = upscaleFactor
        self.linearHeadroomScale = linearHeadroomScale
        self.isDenoisedByNoiser = isDenoisedByNoiser
        self.processingHistory = processingHistory
    }

    public var isEmpty: Bool {
        isDenoised == nil && isUpscaled == nil && upscaleFactor == nil && linearHeadroomScale == nil && isDenoisedByNoiser == nil && processingHistory == nil
    }
}

/// User-configured super-resolution job parameters (`docs/DEVELOPMENT.md` Section 4.3).
public struct UpscaleJobConfig: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceImageURL: URL
    public var scaleFactor: ScaleFactor
    public var backbone: BackboneModelKind
    public var denoiseMode: DenoiseMode
    public var naturalGrainAmount: Float
    public var exportFormat: ExportFormat
    /// Validated session state from a handoff or a forwarding session. Merged into the decoded
    /// metadata before the denoise decision and persisted in the checkpoint.
    public var sessionState: PipelineSessionState?

    public init(
        id: UUID = UUID(),
        sourceImageURL: URL,
        scaleFactor: ScaleFactor = .x2,
        backbone: BackboneModelKind = .quickSRNet,
        denoiseMode: DenoiseMode = .off,
        naturalGrainAmount: Float = 0.15,
        exportFormat: ExportFormat = .autoMatchSource,
        sessionState: PipelineSessionState? = nil
    ) {
        self.id = id
        self.sourceImageURL = sourceImageURL
        self.scaleFactor = scaleFactor
        self.backbone = backbone
        self.denoiseMode = denoiseMode
        self.naturalGrainAmount = min(max(naturalGrainAmount, 0.0), 1.0)
        self.exportFormat = exportFormat
        self.sessionState = sessionState
    }
}

/// Pipeline execution lifecycle stage (`docs/DEVELOPMENT.md` Section 4.3).
public enum JobStage: String, Codable, Sendable, Equatable {
    case idle
    case ingestingAndDecodingStrips
    case denoisingAndUpscalingTiles
    case pausedOnDisk
    case readyForInspection
    case exportingContainer
    case completed
    case failed
}

/// Atomic tile-level checkpoint state persisted to disk (`docs/DEVELOPMENT.md` Section 4.3).
public struct JobCheckpointState: Codable, Sendable, Equatable {
    /// Version of the durable per-tile undo-journal transaction protocol (`TileUndoJournal`).
    public static let currentTransactionJournalVersion = 1
    /// Version 2 checkpoints guarantee `globalMaxLinearComponent` was derived from the decoded RGB
    /// component peak (not luminance). Older checkpoints are rescanned before resume.
    public static let currentNormalizationPeakVersion = 2

    public let jobID: UUID
    public let config: UpscaleJobConfig
    public let tileConfig: TileConfiguration
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let paddedSourceWidth: Int
    public let paddedSourceHeight: Int
    public let outputWidth: Int
    public let outputHeight: Int
    public let globalMaxLuminance: Float
    /// Per-channel linear component peak used for DNG/export headroom. Older checkpoints decode with
    /// this defaulted to `globalMaxLuminance`.
    public let globalMaxLinearComponent: Float
    public let alphaCurveConstant: Float
    public let didRunDenoise: Bool
    public let sourceMMapFileName: String
    public let outputMMapFileName: String
    public let metadataPacketFileName: String
    public var lastCompletedTileIndex: Int
    public let totalTiles: Int
    public var updatedAt: Date
    /// Additive recovery-protocol version. Older JSON without it decodes as version 1.
    public let transactionJournalVersion: Int
    /// Additive normalization-protocol version. Older JSON without it decodes as version 1 and is
    /// rescanned on resume because its component peak may only be luminance.
    public let normalizationPeakVersion: Int

    private enum CodingKeys: String, CodingKey {
        case jobID
        case config
        case tileConfig
        case sourceWidth
        case sourceHeight
        case paddedSourceWidth
        case paddedSourceHeight
        case outputWidth
        case outputHeight
        case globalMaxLuminance
        case globalMaxLinearComponent
        case alphaCurveConstant
        case didRunDenoise
        case sourceMMapFileName
        case outputMMapFileName
        case metadataPacketFileName
        case lastCompletedTileIndex
        case totalTiles
        case updatedAt
        case transactionJournalVersion
        case normalizationPeakVersion
    }

    public init(
        jobID: UUID,
        config: UpscaleJobConfig,
        tileConfig: TileConfiguration,
        sourceWidth: Int,
        sourceHeight: Int,
        paddedSourceWidth: Int,
        paddedSourceHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        globalMaxLuminance: Float,
        globalMaxLinearComponent: Float? = nil,
        alphaCurveConstant: Float = 16.0,
        didRunDenoise: Bool,
        sourceMMapFileName: String,
        outputMMapFileName: String,
        metadataPacketFileName: String,
        lastCompletedTileIndex: Int = -1,
        totalTiles: Int,
        updatedAt: Date = Date(),
        transactionJournalVersion: Int = JobCheckpointState.currentTransactionJournalVersion,
        normalizationPeakVersion: Int = 1
    ) {
        self.jobID = jobID
        self.config = config
        self.tileConfig = tileConfig
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.paddedSourceWidth = paddedSourceWidth
        self.paddedSourceHeight = paddedSourceHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.globalMaxLuminance = globalMaxLuminance
        self.globalMaxLinearComponent = globalMaxLinearComponent ?? globalMaxLuminance
        self.alphaCurveConstant = alphaCurveConstant
        self.didRunDenoise = didRunDenoise
        self.sourceMMapFileName = sourceMMapFileName
        self.outputMMapFileName = outputMMapFileName
        self.metadataPacketFileName = metadataPacketFileName
        self.lastCompletedTileIndex = lastCompletedTileIndex
        self.totalTiles = totalTiles
        self.updatedAt = updatedAt
        self.transactionJournalVersion = transactionJournalVersion
        self.normalizationPeakVersion = normalizationPeakVersion
    }

    /// Custom decode so checkpoints written before the durable-journal fields existed still load:
    /// `globalMaxLinearComponent` falls back to `globalMaxLuminance`, and the journal version to 1.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try container.decode(UUID.self, forKey: .jobID)
        config = try container.decode(UpscaleJobConfig.self, forKey: .config)
        tileConfig = try container.decode(TileConfiguration.self, forKey: .tileConfig)
        sourceWidth = try container.decode(Int.self, forKey: .sourceWidth)
        sourceHeight = try container.decode(Int.self, forKey: .sourceHeight)
        paddedSourceWidth = try container.decode(Int.self, forKey: .paddedSourceWidth)
        paddedSourceHeight = try container.decode(Int.self, forKey: .paddedSourceHeight)
        outputWidth = try container.decode(Int.self, forKey: .outputWidth)
        outputHeight = try container.decode(Int.self, forKey: .outputHeight)
        globalMaxLuminance = try container.decode(Float.self, forKey: .globalMaxLuminance)
        globalMaxLinearComponent = try container.decodeIfPresent(Float.self, forKey: .globalMaxLinearComponent)
            ?? globalMaxLuminance
        alphaCurveConstant = try container.decode(Float.self, forKey: .alphaCurveConstant)
        didRunDenoise = try container.decode(Bool.self, forKey: .didRunDenoise)
        sourceMMapFileName = try container.decode(String.self, forKey: .sourceMMapFileName)
        outputMMapFileName = try container.decode(String.self, forKey: .outputMMapFileName)
        metadataPacketFileName = try container.decode(String.self, forKey: .metadataPacketFileName)
        lastCompletedTileIndex = try container.decode(Int.self, forKey: .lastCompletedTileIndex)
        totalTiles = try container.decode(Int.self, forKey: .totalTiles)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        transactionJournalVersion = try container.decodeIfPresent(Int.self, forKey: .transactionJournalVersion)
            ?? JobCheckpointState.currentTransactionJournalVersion
        normalizationPeakVersion = try container.decodeIfPresent(Int.self, forKey: .normalizationPeakVersion)
            ?? 1
    }
}
