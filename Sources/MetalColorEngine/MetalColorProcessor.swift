import Foundation
import Metal
import TruongScalerCore
import MMapCanvas

/// Intermediate per-tile tensors for reversible log tone-mapping and YCbCr decoupling.
/// Specification: `docs/DEVELOPMENT.md` Section 4.
public struct PreparedTileTensors: @unchecked Sendable {
    public let tileSize: Int
    public let logConstantK: Float
    public let alphaConstant: Float
    /// Planar `[1, 3, T, T]` `Float16` buffer (`3 * T * T` elements)
    public var planarTensorFP16: [Float16]
    /// Planar `[T * T]` `Float32` Cb buffer
    public var cbPlane: [Float]
    /// Planar `[T * T]` `Float32` Cr buffer
    public var crPlane: [Float]
    /// Planar `[T * T]` `Float16` Alpha buffer
    public var alphaPlane: [Float16]

    public init(
        tileSize: Int,
        logConstantK: Float,
        alphaConstant: Float,
        planarTensorFP16: [Float16],
        cbPlane: [Float],
        crPlane: [Float],
        alphaPlane: [Float16]
    ) {
        self.tileSize = tileSize
        self.logConstantK = logConstantK
        self.alphaConstant = alphaConstant
        self.planarTensorFP16 = planarTensorFP16
        self.cbPlane = cbPlane
        self.crPlane = crPlane
        self.alphaPlane = alphaPlane
    }
}

/// Metal compute + CPU SIMD color processor for reversible log tone-mapping, Display P3 YCbCr decoupling,
/// and 4x4 Catmull-Rom bicubic chroma/alpha upscaling.
/// Specification: `docs/DEVELOPMENT.md` Sections 2-4.
public final class MetalColorProcessor: @unchecked Sendable {
    public let device: MTLDevice?
    public let commandQueue: MTLCommandQueue?

    /// Human-readable description of why Metal acceleration is unavailable (`nil` when it is available).
    /// `init(preferMetal:)` never throws: headless CLI runners without a Metal device or without the
    /// offline Metal toolchain silently fall back to the deterministic CPU path instead of crashing.
    public let metalUnavailabilityReason: String?

    /// Cache of auto-derived component peaks for callers that only pass luminance telemetry.
    /// Production always passes the checkpoint's component peak, so this is a compatibility path for
    /// direct API users (including the independent review probe). Source buffers are immutable while
    /// a job runs; the key includes the path and geometry.
    private let normalizationPeakCache = NSLock()
    private var cachedComponentPeaks: [String: Float] = [:]

    /// Embedded shader source so `swift test` CLI runners can compile the Metal library at runtime
    /// even when the Xcode offline Metal compiler is bypassed.
    public static let metalShaderSource: String = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct TileToneParams {
        uint inputSize;
        uint outputSize;
        uint scaleFactor;
        float alphaConstant;
        float logConstantK;
    };

    kernel void rgba16f_to_planar_log_rgb(
        device const half4* srcRGBA [[buffer(0)]],
        device half* dstPlanarRGB [[buffer(1)]],
        device half* dstAlpha [[buffer(2)]],
        constant TileToneParams& params [[buffer(3)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= params.inputSize || gid.y >= params.inputSize) return;
        uint idx = gid.y * params.inputSize + gid.x;
        uint planeSize = params.inputSize * params.inputSize;
        half4 px = srcRGBA[idx];

        float r = clamp(float(px.x), 0.0f, 65500.0f);
        float g = clamp(float(px.y), 0.0f, 65500.0f);
        float b = clamp(float(px.z), 0.0f, 65500.0f);

        float invK = 1.0f / max(params.logConstantK, 1e-6f);
        dstPlanarRGB[0 * planeSize + idx] = half(log(1.0f + params.alphaConstant * r) * invK);
        dstPlanarRGB[1 * planeSize + idx] = half(log(1.0f + params.alphaConstant * g) * invK);
        dstPlanarRGB[2 * planeSize + idx] = half(log(1.0f + params.alphaConstant * b) * invK);
        dstAlpha[idx] = px.w;
    }

    kernel void planar_log_rgb_to_replicated_y_and_cbcr(
        device const half* srcPlanarRGB [[buffer(0)]],
        device half* dstReplicatedY [[buffer(1)]],
        device float* dstCb [[buffer(2)]],
        device float* dstCr [[buffer(3)]],
        constant TileToneParams& params [[buffer(4)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= params.inputSize || gid.y >= params.inputSize) return;
        uint idx = gid.y * params.inputSize + gid.x;
        uint planeSize = params.inputSize * params.inputSize;

        float rn = clamp(float(srcPlanarRGB[0 * planeSize + idx]), 0.0f, 1.0f);
        float gn = clamp(float(srcPlanarRGB[1 * planeSize + idx]), 0.0f, 1.0f);
        float bn = clamp(float(srcPlanarRGB[2 * planeSize + idx]), 0.0f, 1.0f);

        float y  = 0.22897456f * rn + 0.69173852f * gn + 0.07928691f * bn;
        float cb = 0.54305895f * (bn - y);
        float cr = 0.64848699f * (rn - y);

        half yh = half(y);
        dstReplicatedY[0 * planeSize + idx] = yh;
        dstReplicatedY[1 * planeSize + idx] = yh;
        dstReplicatedY[2 * planeSize + idx] = yh;
        dstCb[idx] = cb;
        dstCr[idx] = cr;
    }

    inline float4 catmullRomWeights(float t) {
        float t2 = t * t;
        float w0 = t * (t * (-0.5f * t + 1.0f) - 0.5f);
        float w1 = t2 * (1.5f * t - 2.5f) + 1.0f;
        float w2 = t * (t * (-1.5f * t + 2.0f) + 0.5f);
        float w3 = t2 * (0.5f * t - 0.5f);
        return float4(w0, w1, w2, w3);
    }

    inline float stableExpMinusOne(float x) {
        // exp(x) rounds near 1 before subtraction, losing shadow bits. Metal has no expm1;
        // the degree-six series has < 1.1e-10 truncation error on [0, 0.125].
        if (x < 0.125f) {
            return x * (1.0f + x * (0.5f + x * (1.0f / 6.0f + x *
                (1.0f / 24.0f + x * (1.0f / 120.0f + x * (1.0f / 720.0f))))));
        }
        return exp(x) - 1.0f;
    }

    kernel void reconstruct_upscaled_rgba16f(
        device const half* srcUpscaledY [[buffer(0)]],
        device const float* srcCb [[buffer(1)]],
        device const float* srcCr [[buffer(2)]],
        device const half* srcAlpha [[buffer(3)]],
        device half4* dstUpscaledRGBA [[buffer(4)]],
        constant TileToneParams& params [[buffer(5)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= params.outputSize || gid.y >= params.outputSize) return;
        uint outIdx = gid.y * params.outputSize + gid.x;
        uint outPlaneSize = params.outputSize * params.outputSize;

        float yUp = (float(srcUpscaledY[0 * outPlaneSize + outIdx]) +
                     float(srcUpscaledY[1 * outPlaneSize + outIdx]) +
                     float(srcUpscaledY[2 * outPlaneSize + outIdx])) * (1.0f / 3.0f);

        float u = (float(gid.x) + 0.5f) / float(params.scaleFactor) - 0.5f;
        float v = (float(gid.y) + 0.5f) / float(params.scaleFactor) - 0.5f;
        int i0 = int(floor(u));
        int j0 = int(floor(v));
        float4 wx = catmullRomWeights(u - float(i0));
        float4 wy = catmullRomWeights(v - float(j0));
        float wvx[4] = {wx.x, wx.y, wx.z, wx.w};
        float wvy[4] = {wy.x, wy.y, wy.z, wy.w};

        float cbUp = 0.0f, crUp = 0.0f, aUp = 0.0f;
        int limit = int(params.inputSize) - 1;
        for (int n = -1; n <= 2; ++n) {
            int sy = clamp(j0 + n, 0, limit);
            float wy_n = wvy[n + 1];
            for (int m = -1; m <= 2; ++m) {
                int sx = clamp(i0 + m, 0, limit);
                float w = wy_n * wvx[m + 1];
                uint sIdx = uint(sy) * params.inputSize + uint(sx);
                cbUp += w * srcCb[sIdx];
                crUp += w * srcCr[sIdx];
                aUp  += w * float(srcAlpha[sIdx]);
            }
        }

        cbUp = clamp(cbUp, -0.55f, 0.55f);
        crUp = clamp(crUp, -0.55f, 0.55f);
        aUp  = clamp(aUp, 0.0f, 1.0f);

        float rn, bn, gn;
        {
            // Match the CPU's separately rounded Float operations. A fused Y + coefficient * Cr
            // changes the near-zero cancellation enough to cross a half-subnormal boundary.
            #pragma METAL fp contract(off)
            rn = clamp(yUp + 1.54205088f * crUp, 0.0f, 1.2f);
            bn = clamp(yUp + 1.84142182f * cbUp, 0.0f, 1.2f);
            // Inverse of the Display P3 forward matrix above:
            //   R = Y + 1.54205088 Cr, B = Y + 1.84142182 Cb,
            //   G = Y - 0.51043918 Cr - 0.21106322 Cb.
            // These green coefficients are the numerically inverted values of the
            // K_R/K_G/K_B luminances and the 0.54305895/0.64848699 chroma scales; they
            // are not independently rounded constants.
            gn = clamp(yUp - 0.51043918f * crUp - 0.21106322f * cbUp, 0.0f, 1.2f);
        }

        float invAlpha = 1.0f / max(params.alphaConstant, 1e-6f);
        float rLin = max(0.0f, stableExpMinusOne(rn * params.logConstantK) * invAlpha);
        float gLin = max(0.0f, stableExpMinusOne(gn * params.logConstantK) * invAlpha);
        float bLin = max(0.0f, stableExpMinusOne(bn * params.logConstantK) * invAlpha);

        dstUpscaledRGBA[outIdx] = half4(half(rLin), half(gLin), half(bLin), half(aUp));
    }
    """#

    // MARK: - Private Metal state

    /// Compiled pipeline states for the three kernels in `metalShaderSource`.
    private struct MetalPipelineCache {
        let forwardLogNormalizeRGB: MTLComputePipelineState
        let decoupleLuminanceChrominance: MTLComputePipelineState
        let reconstructUpscaledRGBA: MTLComputePipelineState
    }

    private struct PipelineCompilationResult {
        let cache: MetalPipelineCache?
        let failureReason: String?
    }

    /// Mirrors `struct TileToneParams` in the Metal source byte-for-byte (three `uint`s + two `float`s).
    private struct TileToneParams {
        var inputSize: UInt32
        var outputSize: UInt32
        var scaleFactor: UInt32
        var alphaConstant: Float
        var logConstantK: Float

        init(inputSize: Int, outputSize: Int, scaleFactor: Int, alphaConstant: Float, logConstantK: Float) {
            self.inputSize = UInt32(max(0, inputSize))
            self.outputSize = UInt32(max(0, outputSize))
            self.scaleFactor = UInt32(max(1, scaleFactor))
            self.alphaConstant = alphaConstant
            self.logConstantK = logConstantK
        }
    }

    /// Pre-clamped 4-tap Catmull-Rom sample positions (index + weight) for one output axis coordinate.
    private struct BicubicTap {
        var indices: SIMD4<Int32>
        var weights: SIMD4<Float>
    }

    private let pipelineCache: MetalPipelineCache?

    /// `true` when a Metal device, command queue, and all three compute pipeline states are ready.
    /// When `false` every method transparently uses the deterministic CPU SIMD fallback.
    public var isMetalAccelerationAvailable: Bool {
        pipelineCache != nil && commandQueue != nil && device != nil
    }

    // MARK: - Init

    public init(preferMetal: Bool = true) {
        if preferMetal, let dev = MTLCreateSystemDefaultDevice() {
            self.device = dev
            if let queue = dev.makeCommandQueue() {
                self.commandQueue = queue
                let result = Self.compilePipelines(device: dev)
                self.pipelineCache = result.cache
                self.metalUnavailabilityReason = result.failureReason
            } else {
                self.commandQueue = nil
                self.pipelineCache = nil
                self.metalUnavailabilityReason = "MTLCommandQueue creation failed; using CPU fallback."
            }
        } else {
            self.device = nil
            self.commandQueue = nil
            self.pipelineCache = nil
            self.metalUnavailabilityReason = preferMetal
                ? "No Metal device available; using CPU fallback."
                : "Metal disabled via init(preferMetal: false); using CPU fallback."
        }
    }

    /// Compiles the embedded shader source into the three compute pipeline states.
    /// Tries the SwiftPM resource bundle's `default.metallib` first (Xcode/device builds), then falls back
    /// to `makeLibrary(source:)` for `swift test` CLI runners where SwiftPM does not run the Metal compiler.
    private static func compilePipelines(device: MTLDevice) -> PipelineCompilationResult {
        var library: MTLLibrary?
        var bundledFailure: String?

        do {
            library = try device.makeDefaultLibrary(bundle: .module)
        } catch {
            bundledFailure = error.localizedDescription
        }

        if library == nil {
            do {
                library = try device.makeLibrary(source: metalShaderSource, options: nil)
            } catch {
                let bundled = bundledFailure ?? "no default.metallib in the resource bundle"
                let reason = "Metal shader compilation failed (bundle: \(bundled); runtime: \(error.localizedDescription)). Using CPU fallback."
                return PipelineCompilationResult(cache: nil, failureReason: reason)
            }
        }

        guard let compiledLibrary = library else {
            return PipelineCompilationResult(
                cache: nil,
                failureReason: "Metal library loading produced no library. Using CPU fallback."
            )
        }

        do {
            guard let forwardFunction = compiledLibrary.makeFunction(name: "rgba16f_to_planar_log_rgb"),
                  let decoupleFunction = compiledLibrary.makeFunction(name: "planar_log_rgb_to_replicated_y_and_cbcr"),
                  let reconstructFunction = compiledLibrary.makeFunction(name: "reconstruct_upscaled_rgba16f") else {
                return PipelineCompilationResult(
                    cache: nil,
                    failureReason: "Metal library is missing one or more color kernel functions. Using CPU fallback."
                )
            }

            let cache = MetalPipelineCache(
                forwardLogNormalizeRGB: try device.makeComputePipelineState(function: forwardFunction),
                decoupleLuminanceChrominance: try device.makeComputePipelineState(function: decoupleFunction),
                reconstructUpscaledRGBA: try device.makeComputePipelineState(function: reconstructFunction)
            )
            return PipelineCompilationResult(cache: cache, failureReason: nil)
        } catch {
            return PipelineCompilationResult(
                cache: nil,
                failureReason: "Metal compute pipeline creation failed: \(error.localizedDescription). Using CPU fallback."
            )
        }
    }

    // MARK: - Step 1: forward reversible log normalization

    public func extractLogNormalizedRGBTile(
        from sourceBuffer: MMapBuffer,
        tile: TileDescriptor,
        globalMaxLuminance: Float,
        globalMaxLinearComponent: Float? = nil,
        alphaConstant: Float = 16.0,
        forceCPU: Bool = false
    ) throws -> PreparedTileTensors {
        let tileSize = tile.inputSize
        _ = try Self.checkedElementCount(width: tileSize, height: tileSize, components: 4)
        guard !tile.inputOriginX.addingReportingOverflow(tileSize).overflow,
              !tile.inputOriginY.addingReportingOverflow(tileSize).overflow else {
            throw ScalerError.invalidImageDimensions(width: tileSize, height: tileSize)
        }

        let effectiveAlpha = Self.sanitizedAlphaConstant(alphaConstant)
        // Contract §R1: the forward log denominator must bound each RGB *component*, not luminance.
        // A saturated red of 4.0 has a luminance of only ~0.916; using luminance would produce a
        // normalized sample > 1 that the decouple/reconstruct safety clamps irreversibly clip.
        // The executor always passes the decoded component peak. Direct API callers that only pass
        // luminance get a conservative source-buffer component scan (cached per immutable buffer) so
        // the documented production color API cannot silently clip a saturated HDR component.
        let derivedPeak = globalMaxLinearComponent
            ?? self.derivedComponentPeak(from: sourceBuffer, fallbackLuminance: globalMaxLuminance)
        let normalizationPeak = Self.sanitizedMaxLuminance(derivedPeak)
        let logConstantK = log(1.0 + effectiveAlpha * normalizationPeak)

        let rgbaHalfTile = readTileRGBAHalf(from: sourceBuffer, tile: tile)

        if !forceCPU, isMetalAccelerationAvailable {
            return try extractMetal(
                rgbaHalfTile: rgbaHalfTile,
                tileSize: tileSize,
                alphaConstant: effectiveAlpha,
                logConstantK: logConstantK
            )
        }
        return extractCPU(
            rgbaHalfTile: rgbaHalfTile,
            tileSize: tileSize,
            alphaConstant: effectiveAlpha,
            logConstantK: logConstantK
        )
    }

    // MARK: - Trained model transfer domain

    /// The model sees peak-normalized, transfer-encoded luminance replicated across RGB.
    /// Chroma and alpha remain in the established reversible log pipeline. This prevents a
    /// change in model training primaries from relabeling/clipping the source's wide gamut.
    public func superResolutionInputTensor(from tensors: PreparedTileTensors) throws -> [Float16] {
        let plane = try Self.checkedElementCount(width: tensors.tileSize, height: tensors.tileSize, components: 1)
        guard tensors.planarTensorFP16.count == plane * 3 else {
            throw ScalerError.invalidImageDimensions(width: tensors.tileSize, height: tensors.tileSize)
        }
        let alpha = max(tensors.alphaConstant, 1e-6)
        let peak = max(expm1f(tensors.logConstantK) / alpha, 1e-6)
        var output = [Float16](repeating: 0, count: plane * 3)
        for index in output.indices {
            let value = Float(tensors.planarTensorFP16[index])
            guard value.isFinite else {
                throw ScalerError.modelInferenceFailed(modelName: "QuickSRNet-Large", tileIndex: 0,
                    reason: "Non-finite input luminance; refusing prediction.")
            }
            let linear = max(0, expm1f(value * tensors.logConstantK) / alpha)
            output[index] = Float16(Self.linearToSRGB(min(max(linear / peak, 0), 1)))
        }
        return output
    }

    /// Restore the model's transfer-encoded prediction to log luminance before the unchanged
    /// chroma/alpha reconstruction. Reject non-finite or out-of-contract output before commit.
    public func restoreSuperResolvedLuminance(
        _ prediction: [Float16], tensors: PreparedTileTensors, outputSize: Int,
        modelName: String, tileIndex: Int,
        predictionRange: ClosedRange<Float> = -0.02...1.02
    ) throws -> [Float16] {
        let count = try Self.checkedElementCount(width: outputSize, height: outputSize, components: 3)
        guard prediction.count == count else {
            throw ScalerError.modelInferenceFailed(modelName: modelName, tileIndex: tileIndex,
                reason: "Prediction element count does not match the native 2× tensor contract.")
        }
        let alpha = max(tensors.alphaConstant, 1e-6)
        let peak = max(expm1f(tensors.logConstantK) / alpha, 1e-6)
        var output = [Float16](repeating: 0, count: count)
        for index in prediction.indices {
            let encoded = Float(prediction[index])
            guard encoded.isFinite, predictionRange.contains(encoded) else {
                throw ScalerError.modelInferenceFailed(modelName: modelName, tileIndex: tileIndex,
                    reason: "Prediction contains a non-finite or out-of-range sample; refusing tile commit."
                        + (predictionRange.upperBound > 1.02 ? " Try QuickSRNet-Large for this photo." : ""))
            }
            let linear = Self.srgbToLinear(min(max(encoded, 0), 1)) * peak
            output[index] = Float16(log1pf(alpha * linear) / max(tensors.logConstantK, 1e-6))
        }
        return output
    }

    @inline(__always)
    private static func linearToSRGB(_ value: Float) -> Float {
        let x = min(max(value, 0.0), 1.0)
        return x <= 0.0031308 ? 12.92 * x : 1.055 * powf(x, 1.0 / 2.4) - 0.055
    }

    @inline(__always)
    private static func srgbToLinear(_ value: Float) -> Float {
        let x = min(max(value, 0.0), 1.0)
        return x <= 0.04045 ? x / 12.92 : powf((x + 0.055) / 1.055, 2.4)
    }

    // MARK: - Step 2: Display P3 YCbCr decoupling

    public func decoupleLuminanceAndChrominance(
        tensors: inout PreparedTileTensors,
        forceCPU: Bool = false
    ) throws {
        let tileSize = tensors.tileSize
        let planeCount = try Self.checkedElementCount(width: tileSize, height: tileSize, components: 1)
        let tensorCount = try Self.checkedElementCount(width: tileSize, height: tileSize, components: 3)
        guard tensors.planarTensorFP16.count == tensorCount,
              tensors.cbPlane.count == planeCount,
              tensors.crPlane.count == planeCount,
              tensors.alphaPlane.count == planeCount else {
            throw ScalerError.invalidImageDimensions(width: tileSize, height: tileSize)
        }

        if !forceCPU, isMetalAccelerationAvailable {
            try decoupleMetal(tensors: &tensors)
        } else {
            decoupleCPU(tensors: &tensors)
        }
    }

    // MARK: - Step 3: bicubic chroma/alpha upscale + inverse log reconstruction

    public func reconstructUpscaledTile(
        upscaledYPlanarFP16: UnsafeBufferPointer<Float16>,
        tensors: PreparedTileTensors,
        scaleFactor: ScaleFactor,
        destinationRGBA16F: UnsafeMutablePointer<Float16>,
        forceCPU: Bool = false
    ) throws {
        try reconstructUpscaledTile(
            upscaledYPlanarFP16: upscaledYPlanarFP16,
            tensors: tensors,
            scale: scaleFactor.rawValue,
            destinationRGBA16F: destinationRGBA16F,
            forceCPU: forceCPU
        )
    }

    /// Scale-factor-agnostic reconstruction entry point. `scale == 1` performs identity chroma/alpha
    /// resampling (the bicubic taps collapse to the exact integer pixel); production callers use `2`/`4`
    /// through the `ScaleFactor` overload above. Internal so the unit tests can exercise the identity case.
    func reconstructUpscaledTile(
        upscaledYPlanarFP16: UnsafeBufferPointer<Float16>,
        tensors: PreparedTileTensors,
        scale: Int,
        destinationRGBA16F: UnsafeMutablePointer<Float16>,
        forceCPU: Bool = false
    ) throws {
        let tileSize = tensors.tileSize
        let inputPlaneCount = try Self.checkedElementCount(width: tileSize, height: tileSize, components: 1)
        let inputTensorCount = try Self.checkedElementCount(width: tileSize, height: tileSize, components: 3)
        let (outputSize, sizeOverflow) = tileSize.multipliedReportingOverflow(by: scale)
        guard scale >= 1, !sizeOverflow else {
            throw ScalerError.invalidImageDimensions(width: tileSize, height: tileSize)
        }
        let outputPlaneCount = try Self.checkedElementCount(width: outputSize, height: outputSize, components: 1)
        let outputTensorCount = try Self.checkedElementCount(width: outputSize, height: outputSize, components: 3)
        _ = try Self.checkedElementCount(width: outputSize, height: outputSize, components: 4)

        guard tensors.planarTensorFP16.count == inputTensorCount,
              tensors.cbPlane.count == inputPlaneCount,
              tensors.crPlane.count == inputPlaneCount,
              tensors.alphaPlane.count == inputPlaneCount,
              upscaledYPlanarFP16.count >= outputTensorCount else {
            throw ScalerError.invalidImageDimensions(width: outputSize, height: outputSize)
        }

        if !forceCPU, isMetalAccelerationAvailable {
            try reconstructMetal(
                upscaledYPlanarFP16: upscaledYPlanarFP16,
                tensors: tensors,
                scale: scale,
                outputSize: outputSize,
                outputPlaneCount: outputPlaneCount,
                destinationRGBA16F: destinationRGBA16F
            )
        } else {
            reconstructCPU(
                upscaledYPlanarFP16: upscaledYPlanarFP16,
                tensors: tensors,
                scale: scale,
                outputSize: outputSize,
                outputPlaneCount: outputPlaneCount,
                destinationRGBA16F: destinationRGBA16F
            )
        }
    }

    /// Bicubic-upsamples the Cb/Cr chroma planes by the given scale factor using the exact 4x4
    /// Catmull-Rom (a = -0.5) separable kernel from `docs/DEVELOPMENT.md` Section 2.3.
    /// - Returns: planar `[sourceWidth * S, sourceHeight * S]` Cb and Cr buffers (row-major).
    public func upsampleChromaToOutput(
        cbPlane: [Float],
        crPlane: [Float],
        sourceWidth: Int,
        sourceHeight: Int,
        scaleFactor: ScaleFactor
    ) throws -> (cbPlane: [Float], crPlane: [Float]) {
        let sourceCount = try Self.checkedElementCount(width: sourceWidth, height: sourceHeight, components: 1)
        guard cbPlane.count == sourceCount,
              crPlane.count == sourceCount else {
            throw ScalerError.invalidImageDimensions(width: sourceWidth, height: sourceHeight)
        }

        let scale = scaleFactor.rawValue
        let (outputWidth, widthOverflow) = sourceWidth.multipliedReportingOverflow(by: scale)
        let (outputHeight, heightOverflow) = sourceHeight.multipliedReportingOverflow(by: scale)
        guard !widthOverflow, !heightOverflow else {
            throw ScalerError.invalidImageDimensions(width: sourceWidth, height: sourceHeight)
        }
        _ = try Self.checkedElementCount(width: outputWidth, height: outputHeight, components: 1)
        let upsampled = Self.bicubicUpsamplePlanes(
            cb: cbPlane,
            cr: crPlane,
            alpha: [Float](repeating: 0, count: sourceCount),
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            scale: scale
        )
        return (cbPlane: upsampled.cb, crPlane: upsampled.cr)
    }

    // MARK: - Tile extraction (shared by Metal + CPU paths)

    /// Copies the `T x T` RGBA `Float16` tile starting at `(tile.inputOriginX, tile.inputOriginY)` into a
    /// tightly packed row-major array (`4 * T * T` halves). Coordinates outside the source buffer are
    /// clamped to the nearest edge pixel, matching `MMapBuffer.unsafePixelPointer`.
    private func readTileRGBAHalf(from sourceBuffer: MMapBuffer, tile: TileDescriptor) -> [Float16] {
        let tileSize = tile.inputSize
        let originX = tile.inputOriginX
        let originY = tile.inputOriginY
        var rgba = [Float16](repeating: 0, count: 4 * tileSize * tileSize)

        let isFullyInside = originX >= 0
            && originY >= 0
            && originX + tileSize <= sourceBuffer.width
            && originY + tileSize <= sourceBuffer.height

        rgba.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            if isFullyInside {
                let rowByteCount = tileSize * sourceBuffer.bytesPerPixel
                for row in 0..<tileSize {
                    let sourceRow = sourceBuffer
                        .unsafeRowPointer(y: originY + row)
                        .advanced(by: originX * sourceBuffer.bytesPerPixel)
                    memcpy(destinationBase.advanced(by: row * rowByteCount), sourceRow, rowByteCount)
                }
            } else {
                let pixels = destinationBase.bindMemory(to: Float16.self, capacity: 4 * tileSize * tileSize)
                for row in 0..<tileSize {
                    for column in 0..<tileSize {
                        let sourcePixel = sourceBuffer.unsafePixelPointer(x: originX + column, y: originY + row)
                        let destinationIndex = (row * tileSize + column) * 4
                        pixels[destinationIndex] = sourcePixel[0]
                        pixels[destinationIndex + 1] = sourcePixel[1]
                        pixels[destinationIndex + 2] = sourcePixel[2]
                        pixels[destinationIndex + 3] = sourcePixel[3]
                    }
                }
            }
        }
        return rgba
    }

    // MARK: - CPU paths (deterministic SIMD fallback)

    private func extractCPU(
        rgbaHalfTile: [Float16],
        tileSize: Int,
        alphaConstant: Float,
        logConstantK: Float
    ) -> PreparedTileTensors {
        let planeCount = tileSize * tileSize
        var planarTensor = [Float16](repeating: 0, count: 3 * planeCount)
        var alphaPlane = [Float16](repeating: 0, count: planeCount)
        let inverseK = 1.0 / max(logConstantK, 1e-6)
        let alpha = alphaConstant

        rgbaHalfTile.withUnsafeBufferPointer { source in
            planarTensor.withUnsafeMutableBufferPointer { planar in
                alphaPlane.withUnsafeMutableBufferPointer { alphaDestination in
                    for index in 0..<planeCount {
                        let sourceIndex = index * 4
                        let r = Self.clampedHDRChannel(source[sourceIndex])
                        let g = Self.clampedHDRChannel(source[sourceIndex + 1])
                        let b = Self.clampedHDRChannel(source[sourceIndex + 2])
                        planar[index] = Float16(log(1.0 + alpha * r) * inverseK)
                        planar[planeCount + index] = Float16(log(1.0 + alpha * g) * inverseK)
                        planar[2 * planeCount + index] = Float16(log(1.0 + alpha * b) * inverseK)
                        alphaDestination[index] = source[sourceIndex + 3]
                    }
                }
            }
        }

        return PreparedTileTensors(
            tileSize: tileSize,
            logConstantK: logConstantK,
            alphaConstant: alphaConstant,
            planarTensorFP16: planarTensor,
            cbPlane: [Float](repeating: 0, count: planeCount),
            crPlane: [Float](repeating: 0, count: planeCount),
            alphaPlane: alphaPlane
        )
    }

    private func decoupleCPU(tensors: inout PreparedTileTensors) {
        let tileSize = tensors.tileSize
        let planeCount = tileSize * tileSize
        var planar = tensors.planarTensorFP16
        var cb = tensors.cbPlane
        var cr = tensors.crPlane
        let coefficients = SIMD3<Float>(0.22897456, 0.69173852, 0.07928691)

        for index in 0..<planeCount {
            let rn = Self.clampUnit(Float(planar[index]))
            let gn = Self.clampUnit(Float(planar[planeCount + index]))
            let bn = Self.clampUnit(Float(planar[2 * planeCount + index]))

            let rgb = SIMD3<Float>(rn, gn, bn)
            let y = rgb.x * coefficients.x + rgb.y * coefficients.y + rgb.z * coefficients.z
            let cbValue = 0.54305895 * (bn - y)
            let crValue = 0.64848699 * (rn - y)

            let yHalf = Float16(y)
            planar[index] = yHalf
            planar[planeCount + index] = yHalf
            planar[2 * planeCount + index] = yHalf
            cb[index] = cbValue
            cr[index] = crValue
        }

        tensors.planarTensorFP16 = planar
        tensors.cbPlane = cb
        tensors.crPlane = cr
    }

    private func reconstructCPU(
        upscaledYPlanarFP16: UnsafeBufferPointer<Float16>,
        tensors: PreparedTileTensors,
        scale: Int,
        outputSize: Int,
        outputPlaneCount: Int,
        destinationRGBA16F: UnsafeMutablePointer<Float16>
    ) {
        let tileSize = tensors.tileSize
        let alphaPlaneFloat = tensors.alphaPlane.map(Float.init)
        let upsampled = Self.bicubicUpsamplePlanes(
            cb: tensors.cbPlane,
            cr: tensors.crPlane,
            alpha: alphaPlaneFloat,
            sourceWidth: tileSize,
            sourceHeight: tileSize,
            scale: scale
        )

        let logConstantK = tensors.logConstantK
        let inverseAlpha = 1.0 / max(tensors.alphaConstant, 1e-6)
        let third: Float = 1.0 / 3.0
        let yPlane = upscaledYPlanarFP16
        let sourcePlaneCount = outputPlaneCount

        upsampled.cb.withUnsafeBufferPointer { cb in
            upsampled.cr.withUnsafeBufferPointer { cr in
                upsampled.alpha.withUnsafeBufferPointer { alpha in
                    for outputY in 0..<outputSize {
                        let rowStart = outputY * outputSize
                        for outputX in 0..<outputSize {
                            let index = rowStart + outputX
                            let yUp = (Float(yPlane[index])
                                + Float(yPlane[sourcePlaneCount + index])
                                + Float(yPlane[2 * sourcePlaneCount + index])) * third

                            let cbUp = min(max(cb[index], -0.55), 0.55)
                            let crUp = min(max(cr[index], -0.55), 0.55)
                            let aUp = min(max(alpha[index], 0.0), 1.0)

                            // Inverse of the Display P3 forward matrix:
                            //   R = Y + 1.54205088 Cr, B = Y + 1.84142182 Cb,
                            //   G = Y - 0.51043918 Cr - 0.21106322 Cb.
                            let rn = min(max(yUp + 1.54205088 * crUp, 0.0), 1.2)
                            let bn = min(max(yUp + 1.84142182 * cbUp, 0.0), 1.2)
                            let gn = min(max(yUp - 0.51043918 * crUp - 0.21106322 * cbUp, 0.0), 1.2)

                            let rLinear = max(0.0, Self.stableExpMinusOne(rn * logConstantK) * inverseAlpha)
                            let gLinear = max(0.0, Self.stableExpMinusOne(gn * logConstantK) * inverseAlpha)
                            let bLinear = max(0.0, Self.stableExpMinusOne(bn * logConstantK) * inverseAlpha)

                            let destinationIndex = index * 4
                            destinationRGBA16F[destinationIndex] = Float16(rLinear)
                            destinationRGBA16F[destinationIndex + 1] = Float16(gLinear)
                            destinationRGBA16F[destinationIndex + 2] = Float16(bLinear)
                            destinationRGBA16F[destinationIndex + 3] = Float16(aUp)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Metal paths

    private func extractMetal(
        rgbaHalfTile: [Float16],
        tileSize: Int,
        alphaConstant: Float,
        logConstantK: Float
    ) throws -> PreparedTileTensors {
        guard let metalDevice = device, let pipelines = pipelineCache else {
            throw ScalerError.metalDeviceUnavailable
        }
        let planeCount = tileSize * tileSize
        let halfStride = MemoryLayout<Float16>.stride

        guard let inputBuffer = Self.makeSharedBuffer(from: rgbaHalfTile, device: metalDevice),
              let planarBuffer = metalDevice.makeBuffer(length: 3 * planeCount * halfStride, options: .storageModeShared),
              let alphaBuffer = metalDevice.makeBuffer(length: planeCount * halfStride, options: .storageModeShared) else {
            throw ScalerError.metalExecutionFailed("Failed to allocate Metal buffers for log normalization.")
        }

        let params = TileToneParams(
            inputSize: tileSize,
            outputSize: tileSize,
            scaleFactor: 1,
            alphaConstant: alphaConstant,
            logConstantK: logConstantK
        )
        try dispatchMetal(
            pipeline: pipelines.forwardLogNormalizeRGB,
            buffers: [(inputBuffer, 0), (planarBuffer, 1), (alphaBuffer, 2)],
            params: params,
            paramsIndex: 3,
            gridWidth: tileSize,
            gridHeight: tileSize
        )

        return PreparedTileTensors(
            tileSize: tileSize,
            logConstantK: logConstantK,
            alphaConstant: alphaConstant,
            planarTensorFP16: Self.readHalfValues(from: planarBuffer, count: 3 * planeCount),
            cbPlane: [Float](repeating: 0, count: planeCount),
            crPlane: [Float](repeating: 0, count: planeCount),
            alphaPlane: Self.readHalfValues(from: alphaBuffer, count: planeCount)
        )
    }

    private func decoupleMetal(tensors: inout PreparedTileTensors) throws {
        guard let metalDevice = device, let pipelines = pipelineCache else {
            throw ScalerError.metalDeviceUnavailable
        }
        let tileSize = tensors.tileSize
        let planeCount = tileSize * tileSize
        let halfStride = MemoryLayout<Float16>.stride
        let floatStride = MemoryLayout<Float>.stride

        guard let inputBuffer = Self.makeSharedBuffer(from: tensors.planarTensorFP16, device: metalDevice),
              let replicatedYBuffer = metalDevice.makeBuffer(length: 3 * planeCount * halfStride, options: .storageModeShared),
              let cbBuffer = metalDevice.makeBuffer(length: planeCount * floatStride, options: .storageModeShared),
              let crBuffer = metalDevice.makeBuffer(length: planeCount * floatStride, options: .storageModeShared) else {
            throw ScalerError.metalExecutionFailed("Failed to allocate Metal buffers for YCbCr decoupling.")
        }

        let params = TileToneParams(
            inputSize: tileSize,
            outputSize: tileSize,
            scaleFactor: 1,
            alphaConstant: tensors.alphaConstant,
            logConstantK: tensors.logConstantK
        )
        try dispatchMetal(
            pipeline: pipelines.decoupleLuminanceChrominance,
            buffers: [(inputBuffer, 0), (replicatedYBuffer, 1), (cbBuffer, 2), (crBuffer, 3)],
            params: params,
            paramsIndex: 4,
            gridWidth: tileSize,
            gridHeight: tileSize
        )

        tensors.planarTensorFP16 = Self.readHalfValues(from: replicatedYBuffer, count: 3 * planeCount)
        tensors.cbPlane = Self.readFloatValues(from: cbBuffer, count: planeCount)
        tensors.crPlane = Self.readFloatValues(from: crBuffer, count: planeCount)
    }

    private func reconstructMetal(
        upscaledYPlanarFP16: UnsafeBufferPointer<Float16>,
        tensors: PreparedTileTensors,
        scale: Int,
        outputSize: Int,
        outputPlaneCount: Int,
        destinationRGBA16F: UnsafeMutablePointer<Float16>
    ) throws {
        guard let metalDevice = device, let pipelines = pipelineCache else {
            throw ScalerError.metalDeviceUnavailable
        }
        guard let yBaseAddress = upscaledYPlanarFP16.baseAddress else {
            throw ScalerError.invalidImageDimensions(width: outputSize, height: outputSize)
        }
        let tileSize = tensors.tileSize
        let halfStride = MemoryLayout<Float16>.stride

        guard let upscaledYBuffer = metalDevice.makeBuffer(
                bytes: UnsafeRawPointer(yBaseAddress),
                length: 3 * outputPlaneCount * halfStride,
                options: .storageModeShared
              ),
              let cbBuffer = Self.makeSharedBuffer(from: tensors.cbPlane, device: metalDevice),
              let crBuffer = Self.makeSharedBuffer(from: tensors.crPlane, device: metalDevice),
              let alphaBuffer = Self.makeSharedBuffer(from: tensors.alphaPlane, device: metalDevice),
              let outputBuffer = metalDevice.makeBuffer(length: 4 * outputPlaneCount * halfStride, options: .storageModeShared) else {
            throw ScalerError.metalExecutionFailed("Failed to allocate Metal buffers for RGBA reconstruction.")
        }

        let params = TileToneParams(
            inputSize: tileSize,
            outputSize: outputSize,
            scaleFactor: scale,
            alphaConstant: tensors.alphaConstant,
            logConstantK: tensors.logConstantK
        )
        try dispatchMetal(
            pipeline: pipelines.reconstructUpscaledRGBA,
            buffers: [
                (upscaledYBuffer, 0),
                (cbBuffer, 1),
                (crBuffer, 2),
                (alphaBuffer, 3),
                (outputBuffer, 4)
            ],
            params: params,
            paramsIndex: 5,
            gridWidth: outputSize,
            gridHeight: outputSize
        )

        let outputPointer = outputBuffer.contents().bindMemory(to: Float16.self, capacity: 4 * outputPlaneCount)
        destinationRGBA16F.update(from: outputPointer, count: 4 * outputPlaneCount)
    }

    private func dispatchMetal(
        pipeline: MTLComputePipelineState,
        buffers: [(buffer: MTLBuffer, index: Int)],
        params: TileToneParams,
        paramsIndex: Int,
        gridWidth: Int,
        gridHeight: Int
    ) throws {
        guard let metalDevice = device, let queue = commandQueue else {
            throw ScalerError.metalDeviceUnavailable
        }
        guard let paramsBuffer = Self.makeParamsBuffer(params, device: metalDevice) else {
            throw ScalerError.metalExecutionFailed("Failed to allocate Metal parameter buffer.")
        }
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw ScalerError.metalExecutionFailed("Failed to allocate MTLCommandBuffer.")
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw ScalerError.metalExecutionFailed("Failed to allocate MTLComputeCommandEncoder.")
        }

        encoder.setComputePipelineState(pipeline)
        for entry in buffers {
            encoder.setBuffer(entry.buffer, offset: 0, index: entry.index)
        }
        encoder.setBuffer(paramsBuffer, offset: 0, index: paramsIndex)

        let threadgroupWidth = max(1, pipeline.threadExecutionWidth)
        let maximumThreads = max(1, pipeline.maxTotalThreadsPerThreadgroup)
        let threadgroupHeight = max(1, min(16, maximumThreads / threadgroupWidth))
        encoder.dispatchThreads(
            MTLSize(width: max(1, gridWidth), height: max(1, gridHeight), depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadgroupWidth, height: threadgroupHeight, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard commandBuffer.status == .completed else {
            let description = commandBuffer.error?.localizedDescription
                ?? "Metal command buffer finished with status \(commandBuffer.status.rawValue)."
            throw ScalerError.metalExecutionFailed(description)
        }
    }

    // MARK: - Shared bicubic kernel

    /// Separable 4x4 Catmull-Rom (a = -0.5) upsampling of the Cb, Cr, and alpha planes.
    /// Exact mirror of `reconstruct_upscaled_rgba16f` in `ColorAndToneKernels.metal`.
    private static func bicubicUpsamplePlanes(
        cb: [Float],
        cr: [Float],
        alpha: [Float],
        sourceWidth: Int,
        sourceHeight: Int,
        scale: Int
    ) -> (cb: [Float], cr: [Float], alpha: [Float]) {
        let outputWidth = sourceWidth * scale
        let outputHeight = sourceHeight * scale
        let outputCount = outputWidth * outputHeight
        var outputCb = [Float](repeating: 0, count: outputCount)
        var outputCr = [Float](repeating: 0, count: outputCount)
        var outputAlpha = [Float](repeating: 0, count: outputCount)

        let tapsX = bicubicTaps(outputSize: outputWidth, inputSize: sourceWidth, scale: scale)
        let tapsY = bicubicTaps(outputSize: outputHeight, inputSize: sourceHeight, scale: scale)

        cb.withUnsafeBufferPointer { cbSource in
            cr.withUnsafeBufferPointer { crSource in
                alpha.withUnsafeBufferPointer { alphaSource in
                    outputCb.withUnsafeMutableBufferPointer { cbDestination in
                        outputCr.withUnsafeMutableBufferPointer { crDestination in
                            outputAlpha.withUnsafeMutableBufferPointer { alphaDestination in
                                for outputY in 0..<outputHeight {
                                    let tapY = tapsY[outputY]
                                    let rowStart = outputY * outputWidth
                                    for outputX in 0..<outputWidth {
                                        let tapX = tapsX[outputX]
                                        var accumulator = SIMD4<Float>(repeating: 0)
                                        for n in 0..<4 {
                                            let sourceRow = Int(tapY.indices[n]) * sourceWidth
                                            let weightY = tapY.weights[n]
                                            for m in 0..<4 {
                                                let sampleIndex = sourceRow + Int(tapX.indices[m])
                                                let weight = weightY * tapX.weights[m]
                                                let sample = SIMD4<Float>(
                                                    cbSource[sampleIndex],
                                                    crSource[sampleIndex],
                                                    alphaSource[sampleIndex],
                                                    0
                                                )
                                                accumulator += sample * weight
                                            }
                                        }
                                        let destinationIndex = rowStart + outputX
                                        cbDestination[destinationIndex] = accumulator.x
                                        crDestination[destinationIndex] = accumulator.y
                                        alphaDestination[destinationIndex] = accumulator.z
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return (outputCb, outputCr, outputAlpha)
    }

    /// Precomputes the 4 clamped source indices and Catmull-Rom weights for every output coordinate
    /// on one axis: `u = (x + 0.5) / scale - 0.5`, `i0 = floor(u)`, weights evaluated at `u - i0`.
    private static func bicubicTaps(outputSize: Int, inputSize: Int, scale: Int) -> [BicubicTap] {
        let limit = inputSize - 1
        var taps = [BicubicTap]()
        taps.reserveCapacity(outputSize)
        for outputIndex in 0..<outputSize {
            let coordinate = (Float(outputIndex) + 0.5) / Float(scale) - 0.5
            let baseIndex = Int(floor(coordinate))
            let fraction = coordinate - Float(baseIndex)
            let weights = catmullRomWeights(fraction)
            let indices = SIMD4<Int32>(
                Int32(min(max(baseIndex - 1, 0), limit)),
                Int32(min(max(baseIndex, 0), limit)),
                Int32(min(max(baseIndex + 1, 0), limit)),
                Int32(min(max(baseIndex + 2, 0), limit))
            )
            taps.append(BicubicTap(indices: indices, weights: weights))
        }
        return taps
    }

    /// Exact `catmullRomWeights` from `ColorAndToneKernels.metal` (a = -0.5).
    @inline(__always)
    private static func catmullRomWeights(_ t: Float) -> SIMD4<Float> {
        let t2 = t * t
        let w0 = t * (t * (-0.5 * t + 1.0) - 0.5)
        let w1 = t2 * (1.5 * t - 2.5) + 1.0
        let w2 = t * (t * (-1.5 * t + 2.0) + 0.5)
        let w3 = t2 * (0.5 * t - 0.5)
        return SIMD4<Float>(w0, w1, w2, w3)
    }

    // MARK: - Small helpers

    /// Cancellation-safe inverse log, mirrored in the Metal source. The input is nonnegative after
    /// channel reconstruction; at small exponents subtracting one from a rounded Float exp discards
    /// shadow precision before the result reaches Float16 storage.
    @inline(__always)
    private static func stableExpMinusOne(_ exponent: Float) -> Float {
        if exponent < 0.125 {
            return exponent * (1.0 + exponent * (0.5 + exponent * (1.0 / 6.0 + exponent *
                (1.0 / 24.0 + exponent * (1.0 / 120.0 + exponent * (1.0 / 720.0))))))
        }
        return exp(exponent) - 1
    }

    /// Validate sizes before multiplication or allocation. Public tensor descriptors can be decoded
    /// from persisted data; malformed dimensions must throw rather than trap on integer overflow.
    private static func checkedElementCount(width: Int, height: Int, components: Int) throws -> Int {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (elements, elementOverflow) = pixels.multipliedReportingOverflow(by: components)
        let (_, byteOverflow) = elements.multipliedReportingOverflow(by: MemoryLayout<Float>.stride)
        guard width > 0, height > 0,
              width <= Int(Int32.max), height <= Int(Int32.max),
              !pixelOverflow, !elementOverflow, !byteOverflow else {
            throw ScalerError.invalidImageDimensions(width: width, height: height)
        }
        return elements
    }

    private static func sanitizedAlphaConstant(_ value: Float) -> Float {
        guard value.isFinite, value > 0 else { return 16.0 }
        return value
    }

    /// Scans an immutable source canvas once for the maximum nonnegative R/G/B component and caches
    /// the result. Used only when a direct caller omits `globalMaxLinearComponent`; production passes
    /// the decoder/checkpoint peak explicitly. Invalid/empty geometry falls back to luminance.
    private func derivedComponentPeak(from sourceBuffer: MMapBuffer, fallbackLuminance: Float) -> Float {
        let width = sourceBuffer.width
        let height = sourceBuffer.height
        guard width > 0, height > 0 else { return fallbackLuminance }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (componentCount, componentOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !componentOverflow, componentCount > 0 else {
            return fallbackLuminance
        }
        let key = "\(sourceBuffer.fileURL.standardizedFileURL.path)|\(width)x\(height)|\(sourceBuffer.totalByteSize)"
        normalizationPeakCache.lock()
        if let cached = cachedComponentPeaks[key] {
            normalizationPeakCache.unlock()
            return max(cached, fallbackLuminance)
        }
        normalizationPeakCache.unlock()

        var peak: Float = 0
        for y in 0..<height {
            let row = sourceBuffer.unsafeRowPointer(y: y).assumingMemoryBound(to: Float16.self)
            for x in 0..<width {
                let index = x * 4
                let red = Float(row[index])
                let green = Float(row[index + 1])
                let blue = Float(row[index + 2])
                guard red.isFinite, green.isFinite, blue.isFinite else { continue }
                peak = max(peak, red, green, blue)
            }
        }
        let resolved = Self.sanitizedMaxLuminance(max(peak, fallbackLuminance))
        normalizationPeakCache.lock()
        cachedComponentPeaks[key] = resolved
        normalizationPeakCache.unlock()
        return resolved
    }

    private static func sanitizedMaxLuminance(_ value: Float) -> Float {
        // `K = log(1 + alpha * maxLuminance)` is only meaningful for a finite positive peak.
        // The spec assumes a peak >= 1.0, so values below that are raised to 1.0 rather than
        // producing an unbounded 1/K amplification.
        guard value.isFinite, value > 0 else { return 1.0 }
        return max(1.0, value)
    }

    @inline(__always)
    private static func clampedHDRChannel(_ value: Float16) -> Float {
        let converted = Float(value)
        guard converted.isFinite else { return 0 }
        return min(max(converted, 0.0), 65500.0)
    }

    @inline(__always)
    private static func clampUnit(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0.0), 1.0)
    }

    private static func makeSharedBuffer<T>(from values: [T], device: MTLDevice) -> MTLBuffer? {
        values.withUnsafeBytes { rawBuffer -> MTLBuffer? in
            guard let baseAddress = rawBuffer.baseAddress, rawBuffer.count > 0 else { return nil }
            return device.makeBuffer(bytes: baseAddress, length: rawBuffer.count, options: .storageModeShared)
        }
    }

    private static func makeParamsBuffer(_ params: TileToneParams, device: MTLDevice) -> MTLBuffer? {
        var mutableParams = params
        return withUnsafeBytes(of: &mutableParams) { rawBuffer -> MTLBuffer? in
            guard let baseAddress = rawBuffer.baseAddress, rawBuffer.count > 0 else { return nil }
            return device.makeBuffer(bytes: baseAddress, length: rawBuffer.count, options: .storageModeShared)
        }
    }

    private static func readHalfValues(from buffer: MTLBuffer, count: Int) -> [Float16] {
        let pointer = buffer.contents().bindMemory(to: Float16.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private static func readFloatValues(from buffer: MTLBuffer, count: Int) -> [Float] {
        let pointer = buffer.contents().bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }
}
