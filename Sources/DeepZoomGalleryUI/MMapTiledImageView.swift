import Foundation
import CoreGraphics
import os
import TruongScalerCore
import MMapCanvas
import TiledInferenceEngine

#if canImport(UIKit)
import UIKit
import QuartzCore

public final class MMapTiledImageView: UIView, @unchecked Sendable {
    public enum RenderMode: Sendable {
        case originalNearestNeighbor
        case upscaledWithLiveGrain
    }

    private struct RenderConfiguration: @unchecked Sendable {
        var sourceBuffer: MMapBuffer
        var hatOutputBuffer: MMapBuffer
        var scaleFactor: Int
        var naturalGrainAmount: Float
        var renderMode: RenderMode
    }

    private let stateLock: OSAllocatedUnfairLock<RenderConfiguration>

    override public class var layerClass: AnyClass {
        CATiledLayer.self
    }

    public var tiledLayer: CATiledLayer {
        // swiftlint:disable:next force_cast -- layerClass guarantees this UIKit invariant.
        layer as! CATiledLayer
    }

    public init(
        sourceBuffer: MMapBuffer,
        hatOutputBuffer: MMapBuffer,
        scaleFactor: Int,
        naturalGrainAmount: Float,
        renderMode: RenderMode
    ) {
        let initial = RenderConfiguration(
            sourceBuffer: sourceBuffer,
            hatOutputBuffer: hatOutputBuffer,
            scaleFactor: max(1, scaleFactor),
            naturalGrainAmount: naturalGrainAmount,
            renderMode: renderMode
        )
        self.stateLock = OSAllocatedUnfairLock(initialState: initial)
        super.init(frame: CGRect(x: 0, y: 0, width: hatOutputBuffer.width, height: hatOutputBuffer.height))
        self.isOpaque = true
        self.backgroundColor = .black
        self.contentScaleFactor = 1.0
        self.tiledLayer.tileSize = CGSize(width: 512, height: 512)
        self.tiledLayer.levelsOfDetail = 5
        self.tiledLayer.levelsOfDetailBias = 4 // Up to 16x zoom
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func updateConfiguration(
        sourceBuffer: MMapBuffer,
        hatOutputBuffer: MMapBuffer,
        scaleFactor: Int,
        naturalGrainAmount: Float
    ) {
        let needsRedraw = stateLock.withLock { state -> Bool in
            let changed = state.sourceBuffer.fileURL != sourceBuffer.fileURL
                || state.hatOutputBuffer.fileURL != hatOutputBuffer.fileURL
                || state.scaleFactor != max(1, scaleFactor)
                || abs(state.naturalGrainAmount - naturalGrainAmount) > 0.001
            state.sourceBuffer = sourceBuffer
            state.hatOutputBuffer = hatOutputBuffer
            state.scaleFactor = max(1, scaleFactor)
            state.naturalGrainAmount = naturalGrainAmount
            return changed
        }
        if bounds.size != CGSize(width: hatOutputBuffer.width, height: hatOutputBuffer.height) {
            frame = CGRect(x: 0, y: 0, width: hatOutputBuffer.width, height: hatOutputBuffer.height)
        }
        if needsRedraw {
            tiledLayer.setNeedsDisplay()
        }
    }

    /// Core Animation calls this method through `drawLayer:inContext:` on one or more
    /// background image-provider threads (`CATiledLayer.h`). `UIView` is `@MainActor`, so an
    /// isolated override would put a MainActor executor assertion in the Objective-C entry
    /// thunk and trap on the live phone's `com.apple.coreanimation.imageprovider.concurrent`
    /// queue. This entry point is therefore deliberately `nonisolated`; it only touches the
    /// lock-copied render snapshot below, never UIKit or MainActor state. View/layer setup,
    /// configuration updates and invalidation stay isolated on the main actor.
    nonisolated override public func draw(_ layer: CALayer, in ctx: CGContext) {
        // Copying the snapshot under the lock retains both mmap buffers and every scalar for the
        // full callback, so a main-actor replacement can swap/deallocate old render resources
        // while this tile is in flight without affecting it.
        let config = stateLock.withLock { $0 }
        let canvasWidth = config.hatOutputBuffer.width
        let canvasHeight = config.hatOutputBuffer.height
        guard canvasWidth > 0, canvasHeight > 0,
              config.sourceBuffer.width > 0, config.sourceBuffer.height > 0 else { return }
        let fullBounds = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)

        // Reject null/non-finite/inverted clips before converting to Int, and intersect with the
        // canvas first so the checked integer conversion can never overflow or go negative.
        let rawClip = ctx.boundingBoxOfClipPath
        guard !rawClip.isNull, !rawClip.isInfinite,
              rawClip.origin.x.isFinite, rawClip.origin.y.isFinite,
              rawClip.width.isFinite, rawClip.height.isFinite,
              rawClip.width > 0, rawClip.height > 0 else { return }
        let clipRect = rawClip.integral.intersection(fullBounds)
        guard !clipRect.isNull, !clipRect.isEmpty else { return }

        let outX = Int(clipRect.origin.x)
        let outY = Int(clipRect.origin.y)
        let outW = Int(clipRect.width)
        let outH = Int(clipRect.height)
        guard outW > 0, outH > 0,
              outX >= 0, outY >= 0,
              outX <= canvasWidth - 1, outY <= canvasHeight - 1 else { return }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
                | CGBitmapInfo.floatComponents.rawValue
        )

        switch config.renderMode {
        case .upscaledWithLiveGrain:
            guard outW <= Int.max / 8 else { return }
            let rowBytes = outW * 8
            guard outH <= Int.max / rowBytes else { return }
            let byteCount = rowBytes * outH
            let tempBuf = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
            defer { tempBuf.deallocate() }

            LanczosGrainBlender.renderBlendedRegion(
                outX: outX,
                outY: outY,
                outWidth: outW,
                outHeight: outH,
                scaleFactor: config.scaleFactor,
                naturalGrainAmount: config.naturalGrainAmount,
                sourceBuffer: config.sourceBuffer,
                hatOutputBuffer: config.hatOutputBuffer,
                destinationRGBA16F: tempBuf,
                destinationRowBytes: rowBytes
            )

            let data = Data(bytes: tempBuf, count: byteCount)
            guard let provider = CGDataProvider(data: data as CFData),
                  let cgImage = CGImage(
                      width: outW,
                      height: outH,
                      bitsPerComponent: 16,
                      bitsPerPixel: 64,
                      bytesPerRow: rowBytes,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo,
                      provider: provider,
                      decode: nil,
                      shouldInterpolate: false,
                      intent: .defaultIntent
                  ) else { return }

            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: clipRect.minX, y: clipRect.maxY)
            ctx.scaleBy(x: 1.0, y: -1.0)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: clipRect.width, height: clipRect.height))
            ctx.restoreGState()

        case .originalNearestNeighbor:
            let s = max(1, config.scaleFactor)
            // Cover both clip endpoints, including odd output coordinates, and retain a source
            // sampling halo. Rounding only the clip width left a one-pixel gap at some tile edges.
            // The halo lets interpolation use the same neighbours on either side of a tile boundary.
            let srcX = max(0, min(config.sourceBuffer.width - 1, outX / s - 2))
            let srcY = max(0, min(config.sourceBuffer.height - 1, outY / s - 2))
            let srcEndX = min(config.sourceBuffer.width, (outX + outW + s - 1) / s + 2)
            let srcEndY = min(config.sourceBuffer.height, (outY + outH + s - 1) / s + 2)
            let srcW = max(1, srcEndX - srcX)
            let srcH = max(1, srcEndY - srcY)

            guard srcW <= Int.max / 8 else { return }
            let rowBytes = srcW * 8
            guard srcH <= Int.max / rowBytes else { return }
            let byteCount = rowBytes * srcH
            let tempBuf = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
            defer { tempBuf.deallocate() }

            config.sourceBuffer.readRegion(
                x: srcX,
                y: srcY,
                regionWidth: srcW,
                regionHeight: srcH,
                into: tempBuf,
                destinationRowBytes: rowBytes
            )

            let data = Data(bytes: tempBuf, count: byteCount)
            guard let provider = CGDataProvider(data: data as CFData),
                  let cgImage = CGImage(
                      width: srcW,
                      height: srcH,
                      bitsPerComponent: 16,
                      bitsPerPixel: 64,
                      bytesPerRow: rowBytes,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo,
                      provider: provider,
                      decode: nil,
                      shouldInterpolate: false,
                      intent: .defaultIntent
                  ) else { return }

            let drawRect = CGRect(
                x: CGFloat(srcX * s),
                y: CGFloat(srcY * s),
                width: CGFloat(srcW * s),
                height: CGFloat(srcH * s)
            )
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.translateBy(x: drawRect.minX, y: drawRect.maxY)
            ctx.scaleBy(x: 1.0, y: -1.0)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: drawRect.width, height: drawRect.height))
            ctx.restoreGState()
        }
    }
}
#endif
