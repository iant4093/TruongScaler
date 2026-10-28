import Foundation
import TruongScalerCore

/// Scaler's product contract: native 2× super-resolution only.
///
/// Every app job is constructed here with native 2× super-resolution and denoising disabled.
/// Legacy job identifiers remain decodable for inspection and non-destructive refusal.
public enum ScalerSRPolicy {
    public static let denoiseMode: DenoiseMode = .off
    public static let scaleFactor: ScaleFactor = .x2
    public static let backbone: BackboneModelKind = .quickSRNet
    public static let summary = "Super-resolution only · no denoise"

    /// The single app production constructor. Every model choice still requires 2× and denoise off.
    public static func makeJobConfig(
        id: UUID = UUID(),
        sourceImageURL: URL,
        model: BackboneModelKind = backbone,
        naturalGrainAmount: Float,
        exportFormat: ExportFormat,
        sessionState: PipelineSessionState?
    ) -> UpscaleJobConfig {
        UpscaleJobConfig(
            id: id,
            sourceImageURL: sourceImageURL,
            scaleFactor: scaleFactor,
            backbone: model,
            denoiseMode: denoiseMode,
            naturalGrainAmount: naturalGrainAmount,
            exportFormat: exportFormat,
            sessionState: sessionState
        )
    }

    public enum ConfigurationError: Error, LocalizedError, Sendable {
        case requiresNativeTwoTimesJob
        case incompatibleSavedJob

        public var errorDescription: String? {
            switch self {
            case .requiresNativeTwoTimesJob:
                return "TruongScaler requires a supported native 2× model, with denoising off."
            case .incompatibleSavedJob:
                return "This saved job uses an older scale or model. Start a new 2× enlargement from the original photo. The saved job and its output were left unchanged."
            }
        }
    }

    /// Enforced again at the production app adapter, before the engine touches source/checkpoint files.
    public static func validateJobConfig(_ config: UpscaleJobConfig) throws {
        guard config.scaleFactor == scaleFactor, config.backbone.isSupported,
              config.denoiseMode == denoiseMode else {
            throw ConfigurationError.requiresNativeTwoTimesJob
        }
    }

    public enum ResumeDisposition: Sendable, Equatable {
        case compatible
        case refused(reason: String)

        public var isRefused: Bool {
            if case .refused = self { return true }
            return false
        }
    }

    /// Non-destructive policy for any legacy checkpoint presented for resume.
    ///
    /// A checkpoint that already ran the retired processing stage, or whose stored config would run it for remaining tiles,
    /// cannot be resumed under the SR-only contract: doing so would mix denoised and non-denoised
    /// tiles in one canvas. The checkpoint/output are never deleted or relabeled; the caller gets an
    /// actionable refusal and can start a new SR-only job from the original photo.
    public static func resumeDisposition(for checkpoint: JobCheckpointState) -> ResumeDisposition {
        if checkpoint.didRunDenoise {
            return .refused(
                reason: "This saved job already used the retired denoise stage (tile "
                    + "\(max(0, checkpoint.lastCompletedTileIndex + 1)) of \(checkpoint.totalTiles)). "
                    + "Resuming would mix denoised and non-denoised tiles. Start a new SR-only job from the original photo; denoising belongs to TruongNoiser."
            )
        }
        if checkpoint.config.denoiseMode != .off {
            return .refused(
                reason: "This saved job was configured to denoise tiles, which Scaler no longer does. "
                    + "Start a new SR-only job from the original photo; denoising belongs to TruongNoiser."
            )
        }
        let (width, widthOverflow) = checkpoint.sourceWidth.multipliedReportingOverflow(by: scaleFactor.rawValue)
        let (height, heightOverflow) = checkpoint.sourceHeight.multipliedReportingOverflow(by: scaleFactor.rawValue)
        guard checkpoint.config.scaleFactor == scaleFactor, checkpoint.config.backbone.isSupported,
              checkpoint.sourceWidth > 0, checkpoint.sourceHeight > 0,
              !widthOverflow, !heightOverflow,
              checkpoint.outputWidth == width, checkpoint.outputHeight == height else {
            return .refused(reason: ConfigurationError.incompatibleSavedJob.localizedDescription)
        }
        return .compatible
    }

    /// Throwing adapter used at a resume entry point. Leaves all artifacts untouched on refusal.
    public static func validateResume(_ checkpoint: JobCheckpointState) throws {
        if checkpoint.didRunDenoise || checkpoint.config.denoiseMode != .off {
            throw ScalerError.srOnlyResumeOfLegacyDenoiseJob(
                completedTiles: max(0, checkpoint.lastCompletedTileIndex + 1),
                totalTiles: checkpoint.totalTiles
            )
        }
        if resumeDisposition(for: checkpoint).isRefused {
            throw ConfigurationError.incompatibleSavedJob
        }
    }
}
