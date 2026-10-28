import Foundation
import TruongScalerCore

/// Human-readable, additive capability description for each exported container.
///
/// The raw `ExportFormat` values and Codable representation are unchanged; this extension only adds
/// labels/help text and an explicit dynamic-range capability so UI code stops guessing from the
/// shared "16-bit" wording.
public enum ExportFormatCapability: String, Sendable, Equatable, CaseIterable {
    /// Route from the source: RAW → Linear DNG, HDR HEIF → HEIC (verified), alpha → PNG, else JPEG.
    case automatic
    /// 16-bit rendered Linear DNG: UInt16 SDR (DNG 1.4/reference 1) or absolute Float16 HDR
    /// (DNG 1.7/reference 2 with ProfileDynamicRange HintMaxOutputValue = H).
    case linearHDRDNG
    /// 16-bit LZW TIFF in extended-linear Display P3; lossless HDR and alpha.
    case linearHDRTIFF
    /// 16-bit SDR PNG. Extended-range output is refused explicitly instead of being clipped.
    case sdr16BitPNG
    /// HEIC: SDR always; HDR is attempted and verified after encoding, otherwise refused explicitly.
    /// A correct regenerated ISO gain map is not implemented, so stale source maps are never attached.
    case hdrHEIC
    /// 8-bit SDR JPEG with premultiplied alpha flattened onto black (opaque by contract).
    case sdr8BitJPEG
}

/// How a container handles extended-range (`> 1.0`) rendered components.
public enum ExportExtendedHDRSupport: String, Sendable, Equatable {
    /// Extended-linear samples are carried losslessly (TIFF) or with recorded headroom (Linear DNG).
    case supported
    /// HDR support exists only after the encoder is verified per export; otherwise the export throws.
    case verifiedAtRuntime
    /// The container is SDR-only; HDR content is refused with an actionable error.
    case unsupported
}

public extension ExportFormat {
    /// User-facing format name. Unlike `rawValue`, this states the actual dynamic range.
    var displayName: String {
        switch self {
        case .autoMatchSource:
            return "Match Source"
        case .linearDNG16Bit:
            return "Linear DNG (16-bit HDR)"
        case .tiff16BitLZW:
            return "16-bit LZW TIFF (HDR)"
        case .png16Bit:
            return "16-bit SDR PNG"
        case .heic10BitHDR:
            return "HDR HEIC (verified) or explicit error"
        case .jpeg95:
            return "JPEG (8-bit SDR)"
        }
    }

    /// One-line picker help.
    var shortHelp: String {
        switch self {
        case .autoMatchSource:
            return "Match the source: RAW → Linear DNG, HDR HEIF → HEIC (verified), alpha → PNG, else JPEG."
        case .linearDNG16Bit:
            return "16-bit Linear DNG in rendered linear Display P3; preserves HDR (Float16), SDR or both."
        case .tiff16BitLZW:
            return "16-bit LZW TIFF in extended linear Display P3; preserves HDR, alpha and metadata."
        case .png16Bit:
            return "16-bit SDR PNG. Refuses images with components above 1.0 instead of clipping them."
        case .heic10BitHDR:
            return "10-bit HEIC: SDR works; HDR is decoded back and verified, or the export fails."
        case .jpeg95:
            return "8-bit SDR JPEG; alpha is flattened onto black and HDR is not representable."
        }
    }

    /// Longer explanatory help (Settings/footer text).
    var helpText: String {
        switch self {
        case .autoMatchSource:
            return shortHelp
        case .linearDNG16Bit:
            return "Writes 16-bit LinearRaw samples in the rendered linear Display P3 working space. "
                + "SDR content (component peak H <= 1 + 1e-4) is quantized UInt16 at DNG 1.4 with "
                + "ColorimetricReference 1 and WhiteLevel 65535. Extended-range content is stored as "
                + "absolute Float16 samples at DNG 1.7 with ColorimetricReference 2, WhiteLevel 1 and "
                + "ProfileDynamicRange HintMaxOutputValue = H, so overrange highlights are payload "
                + "rather than a BaselineExposure multiplier. H is measured from the final "
                + "grain-blended output in a bounded pre-pass; BaselineExposure is always 0. Source "
                + "camera raw colour matrices are preserved only as camera identity, never as output "
                + "calibration."
        case .tiff16BitLZW:
            return "Writes half-float (16-bit) extended-linear Display P3 samples with LZW compression. "
                + "Because the samples are floating point, values above 1.0 are retained rather than "
                + "clipped, and the alpha channel and EXIF/GPS metadata survive."
        case .png16Bit:
            return "PNG is an integer 16-bit SDR container. If the rendered image contains components "
                + "above 1.0 (including after grain blending), the export is refused and names "
                + "16-bit LZW TIFF or 16-bit Linear DNG as HDR alternatives. It never clips silently."
        case .heic10BitHDR:
            return "SDR HEIC exports normally. For extended-range output the exporter attempts a native "
                + "extended-linear Float16 HEIC, then decodes the finalized file and compares real "
                + "highlight and colour patches. If the host codec loses HDR, the export is refused "
                + "with an actionable error naming TIFF/DNG; it never falls back to an SDR file. "
                + "A correctly regenerated ISO gain map is not implemented, so stale source gain maps "
                + "are never attached to the processed pixels. HDR HEIC is therefore a runtime-verified "
                + "capability, not a guaranteed one."
        case .jpeg95:
            return "Writes an 8-bit Display P3 JPEG at 0.95 quality. Premultiplied linear RGB is "
                + "flattened onto black before the transfer function and the output is opaque."
        }
    }

    /// True only for containers that carry extended-range samples without requiring runtime codec
    /// verification (Linear DNG and 16-bit LZW TIFF).
    var supportsExtendedHDR: Bool {
        switch self {
        case .linearDNG16Bit, .tiff16BitLZW:
            return true
        case .autoMatchSource, .png16Bit, .heic10BitHDR, .jpeg95:
            return false
        }
    }

    /// Explicit dynamic-range capability.
    var extendedHDRSupport: ExportExtendedHDRSupport {
        switch self {
        case .linearDNG16Bit, .tiff16BitLZW:
            return .supported
        case .heic10BitHDR:
            return .verifiedAtRuntime
        case .autoMatchSource, .png16Bit, .jpeg95:
            return .unsupported
        }
    }

    /// Coarse capability bucket for UI grouping.
    var capability: ExportFormatCapability {
        switch self {
        case .autoMatchSource:
            return .automatic
        case .linearDNG16Bit:
            return .linearHDRDNG
        case .tiff16BitLZW:
            return .linearHDRTIFF
        case .png16Bit:
            return .sdr16BitPNG
        case .heic10BitHDR:
            return .hdrHEIC
        case .jpeg95:
            return .sdr8BitJPEG
        }
    }
}
