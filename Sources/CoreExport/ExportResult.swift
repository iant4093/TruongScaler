import Foundation
import TruongScalerCore

/// Additive, detailed outcome of a completed export.
///
/// `finalLinearPeak` is measured in the same bounded streaming pre-pass that drives the per-format
/// dynamic-range decisions, over the FINAL rendered pixels (including on-the-fly grain blending). It
/// is the maximum nonnegative R/G/B component, not luminance: a saturated red of 4.0 has a luminance
/// near 0.92, and using luminance would understate the container headroom.
///
/// `dngHeadroomScale` is `max(1, finalLinearPeak)`, the headroom recorded in the DNG container and
/// forwarded as the session's `linearHeadroomScale`; it is never derived from a checkpoint or
/// luminance estimate. The existing `FormatAwareExporter.exportImage -> URL` API is a wrapper over
/// this result, so existing callers and tests keep compiling unchanged.
public struct ExportResult: Sendable, Equatable {
    /// Published destination URL (the atomic rename target).
    public let url: URL
    /// Concrete resolved container format (never `.autoMatchSource`).
    public let format: ExportFormat
    /// Maximum nonnegative R/G/B component of the final rendered pixels after grain blending.
    public let finalLinearPeak: Float
    /// Actual artifact-derived upscale factor (2 or 4) used for filenames and metadata.
    public let actualScaleFactor: Int
    /// `max(1, finalLinearPeak)` — the DNG/session headroom scale.
    public let dngHeadroomScale: Float
    /// True when `finalLinearPeak` exceeds the extended-range threshold (`1 + 1e-4`).
    public let isHDR: Bool

    public init(
        url: URL,
        format: ExportFormat,
        finalLinearPeak: Float,
        actualScaleFactor: Int,
        dngHeadroomScale: Float,
        isHDR: Bool
    ) {
        self.url = url
        self.format = format
        self.finalLinearPeak = finalLinearPeak
        self.actualScaleFactor = max(1, actualScaleFactor)
        self.dngHeadroomScale = max(1, dngHeadroomScale)
        self.isHDR = isHDR
    }
}
