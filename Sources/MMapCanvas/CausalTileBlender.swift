import Foundation
import TruongScalerCore

/// Writes an upscaled tile into `outputBuffer` using idempotent causal top-left raised-cosine ramp feathering.
/// Specification: `docs/DEVELOPMENT.md` Section 1.2.
///
/// All coordinate/stride arithmetic is overflow-checked. Untrusted tile geometry (a corrupt checkpoint
/// or tile plan) is skipped instead of trapping, and the weight tables are bounded by the visible
/// (clipped) region so absurd overlap values cannot force a huge allocation.
public struct CausalTileBlender: Sendable {
    public static func writeAndFeatherTile(
        tilePointer: UnsafeRawPointer,
        tileRowBytes: Int,
        tileWidth: Int,
        tileHeight: Int,
        destX: Int,
        destY: Int,
        leftOverlap: Int,
        topOverlap: Int,
        into outputBuffer: MMapBuffer
    ) {
        guard tileWidth > 0, tileHeight > 0, tileRowBytes > 0 else { return }
        // Each pixel is 4 x Float16 = 8 bytes; reject geometry whose byte math cannot be represented.
        let (requiredRowBytes, requiredOverflow) = tileWidth.multipliedReportingOverflow(by: 8)
        guard !requiredOverflow, tileRowBytes >= requiredRowBytes else { return }
        guard tileWidth <= Int.max / 4, tileHeight <= Int.max / 4 else { return }

        let outW = outputBuffer.width
        let outH = outputBuffer.height

        // Clip the iteration range to the visible canvas intersection. This keeps untrusted
        // destX/destY/tile sizes from overflowing and bounds the weight tables by the visible region.
        let lxStart: Int
        if destX >= 0 {
            lxStart = 0
        } else {
            let (value, overflow) = 0.subtractingReportingOverflow(destX)
            guard !overflow else { return }
            lxStart = min(value, tileWidth)
        }
        let (rawLxEnd, lxEndOverflow) = outW.subtractingReportingOverflow(destX)
        guard !lxEndOverflow else { return }
        let lxEnd = min(tileWidth, rawLxEnd)
        guard lxStart < lxEnd else { return }

        let lyStart: Int
        if destY >= 0 {
            lyStart = 0
        } else {
            let (value, overflow) = 0.subtractingReportingOverflow(destY)
            guard !overflow else { return }
            lyStart = min(value, tileHeight)
        }
        let (rawLyEnd, lyEndOverflow) = outH.subtractingReportingOverflow(destY)
        guard !lyEndOverflow else { return }
        let lyEnd = min(tileHeight, rawLyEnd)
        guard lyStart < lyEnd else { return }

        // Precompute raised-cosine ramp weights. Only indices below the overlap (and below the
        // visible range) differ from 1.0, so size the tables by that bound.
        let wxCount = leftOverlap > 0 ? min(lxEnd, min(leftOverlap, tileWidth)) : 0
        var wxTable = [Float](repeating: 1.0, count: wxCount)
        if wxCount > 0 {
            let invLeft = Float.pi / Float(leftOverlap)
            for lx in 0..<wxCount {
                wxTable[lx] = 0.5 - 0.5 * cosf(invLeft * (Float(lx) + 0.5))
            }
        }

        let wyCount = topOverlap > 0 ? min(lyEnd, min(topOverlap, tileHeight)) : 0
        var wyTable = [Float](repeating: 1.0, count: wyCount)
        if wyCount > 0 {
            let invTop = Float.pi / Float(topOverlap)
            for ly in 0..<wyCount {
                wyTable[ly] = 0.5 - 0.5 * cosf(invTop * (Float(ly) + 0.5))
            }
        }

        // Preserve scalar ordering for callers whose tile aliases the mapped canvas.
        let (lastRowOffset, spanOverflow) = (tileHeight - 1).multipliedReportingOverflow(by: tileRowBytes)
        let (sourceSpan, sourceSpanOverflow) = lastRowOffset.addingReportingOverflow(requiredRowBytes)
        let sourceStart = UInt(bitPattern: tilePointer)
        let destinationStart = UInt(bitPattern: outputBuffer.unsafeRowPointer(y: 0))
        let (sourceEnd, sourceEndOverflow) = sourceStart.addingReportingOverflow(UInt(max(0, sourceSpan)))
        let (destinationEnd, destinationEndOverflow) = destinationStart.addingReportingOverflow(UInt(outputBuffer.totalByteSize))
        let canBulkCopy = !spanOverflow && !sourceSpanOverflow && !sourceEndOverflow && !destinationEndOverflow
            && (sourceEnd <= destinationStart || destinationEnd <= sourceStart)

        for ly in lyStart..<lyEnd {
            // Bounds are clipped to the canvas, so these additions cannot overflow here, but keep the
            // reporting-overflow guard for defense in depth.
            let (gy, gyOverflow) = destY.addingReportingOverflow(ly)
            guard !gyOverflow else { break }
            guard gy >= 0, gy < outH else { continue }
            let (rowOffset, rowOverflow) = ly.multipliedReportingOverflow(by: tileRowBytes)
            guard !rowOverflow else { break }
            let wy = ly < wyCount ? wyTable[ly] : 1.0
            let srcRow = tilePointer.advanced(by: rowOffset).assumingMemoryBound(to: Float16.self)
            let dstRow = outputBuffer.unsafeRowPointer(y: gy).assumingMemoryBound(to: Float16.self)

            // Most of a tile has unit weight. Copy that contiguous row suffix once, preserving
            // its exact Float16 bits, rather than running four scalar stores and geometry checks
            // for every interior pixel. Feathered pixels retain the original arithmetic below.
            let copyStart = canBulkCopy && wy >= 0.99999 ? max(lxStart, wxCount) : lxEnd
            if copyStart < lxEnd {
                let (gx, overflow) = destX.addingReportingOverflow(copyStart)
                guard !overflow, gx >= 0, gx < outW else { continue }
                memmove(dstRow.advanced(by: gx * 4), srcRow.advanced(by: copyStart * 4),
                        (lxEnd - copyStart) * 8)
            }
            for lx in lxStart..<min(copyStart, lxEnd) {
                let (gx, gxOverflow) = destX.addingReportingOverflow(lx)
                guard !gxOverflow else { continue }
                guard gx >= 0, gx < outW else { continue }
                let wx = lx < wxCount ? wxTable[lx] : 1.0
                let w = wx * wy
                let (srcOffset, srcOverflow) = lx.multipliedReportingOverflow(by: 4)
                guard !srcOverflow else { continue }
                let (dstOffset, dstOverflow) = gx.multipliedReportingOverflow(by: 4)
                guard !dstOverflow else { continue }

                if w >= 0.99999 {
                    dstRow[dstOffset + 0] = srcRow[srcOffset + 0]
                    dstRow[dstOffset + 1] = srcRow[srcOffset + 1]
                    dstRow[dstOffset + 2] = srcRow[srcOffset + 2]
                    dstRow[dstOffset + 3] = srcRow[srcOffset + 3]
                } else {
                    let invW = 1.0 - w
                    let rNew = Float(srcRow[srcOffset + 0])
                    let gNew = Float(srcRow[srcOffset + 1])
                    let bNew = Float(srcRow[srcOffset + 2])
                    let aNew = Float(srcRow[srcOffset + 3])

                    let rOld = Float(dstRow[dstOffset + 0])
                    let gOld = Float(dstRow[dstOffset + 1])
                    let bOld = Float(dstRow[dstOffset + 2])
                    let aOld = Float(dstRow[dstOffset + 3])

                    dstRow[dstOffset + 0] = Float16(invW * rOld + w * rNew)
                    dstRow[dstOffset + 1] = Float16(invW * gOld + w * gNew)
                    dstRow[dstOffset + 2] = Float16(invW * bOld + w * bNew)
                    dstRow[dstOffset + 3] = Float16(invW * aOld + w * aNew)
                }
            }
        }
    }
}
