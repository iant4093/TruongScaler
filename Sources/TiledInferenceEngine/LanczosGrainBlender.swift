import Foundation
import Accelerate
import TruongScalerCore
import MMapCanvas

/// Real-time on-the-fly Accelerate `vImage` Lanczos-3 (`kvImageHighQualityResampling`) ROI scaler & blender.
/// Specification: `docs/DEVELOPMENT.md` Section 3.
public struct LanczosGrainBlender: Sendable {
    /// Renders the requested output canvas region `[outX ..< outX + outWidth, outY ..< outY + outHeight]`
    /// into `destinationRGBA16F` (row stride: `destinationRowBytes`).
    ///
    /// * `naturalGrainAmount <= 0.0001`: the AI/HAT output is copied directly (zero Lanczos overhead).
    /// * Otherwise the matching source ROI (expanded by a 3-pixel halo for the 6-tap Lanczos-3 kernel)
    ///   is scaled with `vImageScale_ARGBFFFF(..., kvImageHighQualityResampling | kvImageEdgeExtend)`
    ///   and linearly blended in Float16:
    ///   `final = (1 - beta) * hatOutput + beta * lanczosOutput`.
    ///
    /// All border math is clamped/reflected through `MMapBuffer.readRegion`, so tiny (1 × 1) regions,
    /// regions that extend past the source canvas, and canvas edges never read or write out of bounds.
    public static func renderBlendedRegion(
        outX: Int,
        outY: Int,
        outWidth: Int,
        outHeight: Int,
        scaleFactor: Int,
        naturalGrainAmount: Float,
        sourceBuffer: MMapBuffer,
        hatOutputBuffer: MMapBuffer,
        destinationRGBA16F: UnsafeMutableRawPointer,
        destinationRowBytes: Int
    ) {
        guard outWidth > 0, outHeight > 0, destinationRowBytes >= 8 else { return }
        // Never write more columns than the caller's destination row can hold.
        let copyWidth = min(outWidth, destinationRowBytes / 8)
        guard copyWidth > 0 else { return }
        let scale = max(1, scaleFactor)

        // Step 1: seed the destination with the AI/HAT result. `readRegion` reflects out-of-canvas
        // coordinates, so edge/oversized ROIs are safe.
        hatOutputBuffer.readRegion(
            x: outX,
            y: outY,
            regionWidth: copyWidth,
            regionHeight: outHeight,
            into: destinationRGBA16F,
            destinationRowBytes: destinationRowBytes
        )

        // Step 2: clamp beta into [0, 1]; NaN/non-finite requests are treated as "no grain".
        let clampedGrain: Float
        if naturalGrainAmount.isFinite {
            clampedGrain = min(max(naturalGrainAmount, 0.0), 1.0)
        } else {
            clampedGrain = 0.0
        }
        guard clampedGrain > 0.0001 else { return }
        let beta = clampedGrain

        let sourceWidth = sourceBuffer.width
        let sourceHeight = sourceBuffer.height
        guard sourceWidth > 0, sourceHeight > 0 else { return }

        // Step 3: corresponding source ROI with a 3-pixel Lanczos-3 kernel margin.
        let rawStartX = floorDivide(outX, by: scale) - 3
        let rawStartY = floorDivide(outY, by: scale) - 3
        let rawEndX = ceilDivide(outX + copyWidth, by: scale) + 3
        let rawEndY = ceilDivide(outY + outHeight, by: scale) + 3

        let srcStartX = min(max(0, rawStartX), sourceWidth - 1)
        let srcStartY = min(max(0, rawStartY), sourceHeight - 1)
        let srcEndX = min(sourceWidth, max(srcStartX + 1, rawEndX))
        let srcEndY = min(sourceHeight, max(srcStartY + 1, rawEndY))
        let srcWidth = srcEndX - srcStartX
        let srcHeight = srcEndY - srcStartY
        guard srcWidth > 0, srcHeight > 0 else { return }
        // Guard against absurd scale values producing unreasonably large scratch allocations.
        guard srcWidth <= 32_768, srcHeight <= 32_768, scale <= 64 else { return }
        let dstWidth = srcWidth * scale
        let dstHeight = srcHeight * scale
        guard dstWidth <= 65_536, dstHeight <= 65_536 else { return }

        // Step 4: read the Float16 ROI and widen it to interleaved 32-bit floats (ARGBFFFF layout).
        let sourceHalfCount = srcWidth * srcHeight * 4
        var sourceHalf = [Float16](repeating: 0, count: sourceHalfCount)
        sourceHalf.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            sourceBuffer.readRegion(
                x: srcStartX,
                y: srcStartY,
                regionWidth: srcWidth,
                regionHeight: srcHeight,
                into: baseAddress,
                destinationRowBytes: srcWidth * 8
            )
        }

        var sourceFloat = [Float](repeating: 0, count: sourceHalfCount)
        for index in 0..<sourceHalfCount {
            sourceFloat[index] = Float(sourceHalf[index])
        }

        // Step 5: vImage Lanczos-3 scale. `vImageBuffer_Init` allocates a 64-byte-aligned row layout.
        var scaledBuffer = vImage_Buffer()
        let initStatus = vImageBuffer_Init(
            &scaledBuffer,
            vImagePixelCount(dstHeight),
            vImagePixelCount(dstWidth),
            128, // ARGBFFFF stores four 32-bit channels per pixel.
            vImage_Flags(kvImageNoFlags)
        )
        guard initStatus == kvImageNoError, scaledBuffer.data != nil else { return }
        defer { free(scaledBuffer.data) }

        let didScale = sourceFloat.withUnsafeMutableBufferPointer { sourceBufferPointer -> Bool in
            guard let sourceBase = sourceBufferPointer.baseAddress else { return false }
            var sourceImage = vImage_Buffer(
                data: sourceBase,
                height: vImagePixelCount(srcHeight),
                width: vImagePixelCount(srcWidth),
                rowBytes: srcWidth * 4 * MemoryLayout<Float>.stride
            )
            let status = vImageScale_ARGBFFFF(
                &sourceImage,
                &scaledBuffer,
                nil,
                vImage_Flags(kvImageHighQualityResampling | kvImageEdgeExtend)
            )
            return status == kvImageNoError
        }
        guard didScale else { return }

        // Step 6: offset into the scaled ROI and blend `(1 - beta) * hat + beta * lanczos` in Float16.
        let localOffsetX = outX - srcStartX * scale
        let localOffsetY = outY - srcStartY * scale

        let destinationStartX = max(0, -localOffsetX)
        let destinationStartY = max(0, -localOffsetY)
        let lanczosStartX = max(0, localOffsetX)
        let lanczosStartY = max(0, localOffsetY)
        let blendColumns = min(copyWidth - destinationStartX, dstWidth - lanczosStartX)
        let blendRows = min(outHeight - destinationStartY, dstHeight - lanczosStartY)
        guard blendColumns > 0, blendRows > 0 else { return }

        let destinationPixels = destinationRGBA16F.assumingMemoryBound(to: Float16.self)
        let destinationRowStrideInFloats16 = destinationRowBytes / MemoryLayout<Float16>.stride
        let lanczosPixels = scaledBuffer.data.assumingMemoryBound(to: Float.self)
        let lanczosRowStrideInFloats = scaledBuffer.rowBytes / MemoryLayout<Float>.stride
        let inverseBeta = 1.0 - beta

        for row in 0..<blendRows {
            let lanczosRowOffset = (lanczosStartY + row) * lanczosRowStrideInFloats
            let destinationRowOffset = (destinationStartY + row) * destinationRowStrideInFloats16
            for column in 0..<blendColumns {
                let lanczosPixelOffset = lanczosRowOffset + (lanczosStartX + column) * 4
                let destinationPixelOffset = destinationRowOffset + (destinationStartX + column) * 4
                for channel in 0..<4 {
                    let hatValue = Float(destinationPixels[destinationPixelOffset + channel])
                    let lanczosValue = lanczosPixels[lanczosPixelOffset + channel]
                    let blendedValue: Float
                    if lanczosValue.isFinite {
                        blendedValue = inverseBeta * hatValue + beta * lanczosValue
                    } else {
                        blendedValue = hatValue
                    }
                    let sanitizedValue: Float
                    if blendedValue.isFinite {
                        sanitizedValue = min(max(blendedValue, -65_504.0), 65_504.0)
                    } else {
                        sanitizedValue = hatValue.isFinite ? hatValue : 0.0
                    }
                    destinationPixels[destinationPixelOffset + channel] = Float16(sanitizedValue)
                }
            }
        }
    }

    // MARK: - Integer division helpers

    @inline(__always)
    private static func floorDivide(_ value: Int, by divisor: Int) -> Int {
        precondition(divisor > 0)
        let quotient = value / divisor
        let remainder = value % divisor
        return remainder != 0 && value < 0 ? quotient - 1 : quotient
    }

    @inline(__always)
    private static func ceilDivide(_ value: Int, by divisor: Int) -> Int {
        precondition(divisor > 0)
        return value >= 0 ? (value + divisor - 1) / divisor : value / divisor
    }
}
