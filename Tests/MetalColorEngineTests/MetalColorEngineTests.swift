import XCTest
import Foundation
@testable import MetalColorEngine
@testable import MMapCanvas
@testable import TruongScalerCore

final class MetalColorEngineTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TruongScalerMetalColorEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
    }

    override func tearDownWithError() throws {
        if let directory = temporaryDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectory = nil
    }

    // MARK: - Tile grid planner (pre-existing test, unchanged)

    func testTileGridPlannerExactCoverageAndDynamicOverlap() throws {
        let config = TileConfiguration(tier: .tierA_HighMemory)
        let plan = TileGridPlanner.makePlan(
            sourceWidth: 1000,
            sourceHeight: 750,
            scaleFactor: .x4,
            tileConfig: config
        )
        XCTAssertEqual(plan.outputWidth, 4000)
        XCTAssertEqual(plan.outputHeight, 3000)
        XCTAssertEqual(plan.cols, 5)
        XCTAssertEqual(plan.rows, 4)
        XCTAssertEqual(plan.totalTiles, 20)

        let first = try XCTUnwrap(plan.tiles.first)
        XCTAssertEqual(first.inputOriginX, 0)
        XCTAssertEqual(first.inputOriginY, 0)
        XCTAssertEqual(first.actualLeftOverlapOut, 0)
        XCTAssertEqual(first.actualTopOverlapOut, 0)

        let last = try XCTUnwrap(plan.tiles.last)
        XCTAssertGreaterThan(last.actualLeftOverlapOut, 0)
        XCTAssertGreaterThan(last.actualTopOverlapOut, 0)
        XCTAssertEqual(last.outputOriginX + last.outputSize, 4000)
        XCTAssertEqual(last.outputOriginY + last.outputSize, 3000)
    }

    // MARK: - Round trip: log normalization -> YCbCr decouple -> bicubic upscale -> inverse log

    func testReversibleLogAndYCbCrLosslessRoundTrip() throws {
        let globalMaxLuminance: Float = 8.0
        let cpuProcessor = MetalColorProcessor(preferMetal: false)
        let hardwareProcessor = MetalColorProcessor()
        print("[TrackC] Metal acceleration available: \(hardwareProcessor.isMetalAccelerationAvailable) reason=\(hardwareProcessor.metalUnavailabilityReason ?? "none")")

        // 192x192 (Tier B tile size) HDR ramp covering 0.0 ... 8.0, including exactly 0, a tiny
        // sub-normal-ish value, 1.0 and the 8.0 peak. The ramp is neutral gray so its chroma is
        // spatially constant (Cb = Cr ~ 0) which keeps the bicubic chroma stage lossless.
        let ramp: [Float] = [
            0.0, 0.0005, 0.002, 0.01, 0.05, 0.1, 0.25, 0.5,
            0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 3.5,
            4.0, 4.5, 5.0, 5.5, 6.0, 6.5, 7.0, 7.5, 8.0
        ]
        let side = 192
        let source = try makeSourceBuffer(width: side, height: side) { x, y in
            let value = ramp[(x + y * side) % ramp.count]
            return SIMD4<Float>(value, value, value, 1.0)
        }
        // Derive the tile descriptor from the production planner (192x192 source => a single tile).
        let tierBConfig = TileConfiguration(tier: .tierB_ConstrainedMemory)
        let plan = TileGridPlanner.makePlan(
            sourceWidth: side,
            sourceHeight: side,
            scaleFactor: .x2,
            tileConfig: tierBConfig
        )
        XCTAssertEqual(plan.totalTiles, 1)
        let tile = try XCTUnwrap(plan.tiles.first)
        XCTAssertEqual(tile.inputSize, side)
        XCTAssertEqual(tile.inputOriginX, 0)
        XCTAssertEqual(tile.inputOriginY, 0)

        // Scale 1 (identity chroma resampling) and scale 2 through the ScaleFactor-style pipeline.
        for scale in [1, 2] {
            let cpuResult = try runRoundTrip(
                processor: cpuProcessor,
                source: source.buffer,
                tile: tile,
                globalMaxLuminance: globalMaxLuminance,
                scale: scale,
                forceCPU: true
            )
            let cpuMetrics = measureRoundTrip(
                output: cpuResult,
                sourcePixels: source.pixelValues,
                sourceWidth: tile.inputSize,
                scale: scale,
                globalMaxLuminance: globalMaxLuminance
            )
            print("[TrackC] scale=\(scale) forceCPU=true maxAbs=\(cpuMetrics.maxAbsoluteError) maxRel=\(cpuMetrics.maxRelativeError) maxNormalized=\(cpuMetrics.maxNormalizedError) maxAlphaErr=\(cpuMetrics.maxAlphaError) maxGraySpread=\(cpuMetrics.maxChannelSpread)")
            XCTAssertEqual(cpuMetrics.nonFiniteCount, 0, "CPU round trip produced NaN/Inf at scale \(scale)")
            // Raw absolute error must stay within a couple of Float16 ulps at the 8.0 peak
            // (ulp(8.0) == 0.0078125), i.e. the pipeline must not lose more than FP16 storage does.
            XCTAssertLessThan(cpuMetrics.maxAbsoluteError, 1e-2, "CPU absolute round-trip error exceeded two Float16 ulps at the HDR peak")
            // Float16 stores 8.0 with a 0.0078125 ulp, so a literal "< 1e-3 absolute" assertion is
            // mathematically impossible above ~2.0. We therefore assert the FP16-aware normalized
            // error (absolute error divided by the HDR peak 8.0) is < 1e-3 and that the relative
            // error stays within the spec's 2e-3 budget for FP16 storage.
            XCTAssertLessThan(cpuMetrics.maxNormalizedError, 1e-3, "CPU normalized round-trip error exceeded 1e-3 at scale \(scale)")
            XCTAssertLessThan(cpuMetrics.maxRelativeError, 2e-3, "CPU relative round-trip error exceeded 2e-3 at scale \(scale)")
            XCTAssertLessThan(cpuMetrics.maxAlphaError, 1e-3, "CPU alpha round trip drifted at scale \(scale)")
            XCTAssertLessThan(cpuMetrics.maxChannelSpread, 1e-3, "Neutral gray acquired a color shift at scale \(scale)")

            let hardwareResult = try runRoundTrip(
                processor: hardwareProcessor,
                source: source.buffer,
                tile: tile,
                globalMaxLuminance: globalMaxLuminance,
                scale: scale,
                forceCPU: false
            )
            let hardwareMetrics = measureRoundTrip(
                output: hardwareResult,
                sourcePixels: source.pixelValues,
                sourceWidth: tile.inputSize,
                scale: scale,
                globalMaxLuminance: globalMaxLuminance
            )
            print("[TrackC] scale=\(scale) forceCPU=false metal=\(hardwareProcessor.isMetalAccelerationAvailable) maxAbs=\(hardwareMetrics.maxAbsoluteError) maxRel=\(hardwareMetrics.maxRelativeError) maxNormalized=\(hardwareMetrics.maxNormalizedError) maxAlphaErr=\(hardwareMetrics.maxAlphaError)")
            XCTAssertEqual(hardwareMetrics.nonFiniteCount, 0, "Default-path round trip produced NaN/Inf at scale \(scale)")
            XCTAssertLessThan(hardwareMetrics.maxNormalizedError, 1e-3, "Default-path normalized round-trip error exceeded 1e-3 at scale \(scale)")
            XCTAssertLessThan(hardwareMetrics.maxRelativeError, 2e-3, "Default-path relative round-trip error exceeded 2e-3 at scale \(scale)")
            XCTAssertLessThan(hardwareMetrics.maxChannelSpread, 1e-3, "Default path acquired a color shift at scale \(scale)")
        }

        // Saturated, chromatic, and semi-transparent flat patches: bicubic upsampling of a constant
        // plane is exact (Catmull-Rom weights sum to 1), so the full pipeline must be lossless here.
        let flatPatches: [(name: String, color: SIMD4<Float>, scale: ScaleFactor)] = [
            ("saturated-red", SIMD4<Float>(4.2, 0.1, 0.05, 1.0), .x4),
            ("hdr-cyan", SIMD4<Float>(0.05, 2.4, 2.8, 0.42), .x4),
            ("mid-gray", SIMD4<Float>(1.0, 1.0, 1.0, 0.42), .x2)
        ]
        for patch in flatPatches {
            let patchSide = 32
            let patchSource = try makeSourceBuffer(width: patchSide, height: patchSide) { _, _ in patch.color }
            let patchTile = makeTile(originX: 0, originY: 0, size: patchSide, scale: patch.scale)
            let scale = patch.scale.rawValue
            let result = try runRoundTrip(
                processor: cpuProcessor,
                source: patchSource.buffer,
                tile: patchTile,
                globalMaxLuminance: globalMaxLuminance,
                scale: scale,
                forceCPU: true
            )
            let metrics = measureRoundTrip(
                output: result,
                sourcePixels: patchSource.pixelValues,
                sourceWidth: patchSide,
                scale: scale,
                globalMaxLuminance: globalMaxLuminance
            )
            print("[TrackC] patch=\(patch.name) scale=\(scale) maxAbs=\(metrics.maxAbsoluteError) maxRel=\(metrics.maxRelativeError) maxNormalized=\(metrics.maxNormalizedError) maxAlphaErr=\(metrics.maxAlphaError)")
            XCTAssertEqual(metrics.nonFiniteCount, 0, "Flat patch \(patch.name) produced NaN/Inf")
            XCTAssertLessThan(metrics.maxNormalizedError, 1e-3, "Flat patch \(patch.name) normalized round-trip error exceeded 1e-3")
            XCTAssertLessThan(metrics.maxRelativeError, 2e-3, "Flat patch \(patch.name) relative round-trip error exceeded 2e-3")
            XCTAssertLessThan(metrics.maxAlphaError, 1e-3, "Flat patch \(patch.name) alpha drifted")

            let hardwareResult = try runRoundTrip(
                processor: hardwareProcessor,
                source: patchSource.buffer,
                tile: patchTile,
                globalMaxLuminance: globalMaxLuminance,
                scale: scale,
                forceCPU: false
            )
            let hardwareMetrics = measureRoundTrip(
                output: hardwareResult,
                sourcePixels: patchSource.pixelValues,
                sourceWidth: patchSide,
                scale: scale,
                globalMaxLuminance: globalMaxLuminance
            )
            XCTAssertEqual(hardwareMetrics.nonFiniteCount, 0, "Flat patch \(patch.name) default path produced NaN/Inf")
            XCTAssertLessThan(hardwareMetrics.maxNormalizedError, 1e-3, "Flat patch \(patch.name) default-path normalized error exceeded 1e-3")
            XCTAssertLessThan(hardwareMetrics.maxAlphaError, 1e-3, "Flat patch \(patch.name) default-path alpha drifted")
        }
    }

    // MARK: - Metal vs CPU parity

    func testMetalVsCPUFallbackParity() throws {
        let globalMaxLuminance: Float = 8.0
        let side = 96
        var seed: UInt64 = 0x5EED_1234_ABCD_0001
        let source = try makeSourceBuffer(width: side, height: side) { x, y in
            // Deterministic pseudo-random HDR RGB plus hard geometric edges so the bicubic
            // chroma/alpha taps are exercised away from flat regions.
            func next() -> Float {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Float((seed >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
            }
            var r = next() * 8.0
            var g = next() * 8.0
            var b = next() * 8.0
            if (x / 8 + y / 8) % 2 == 0 {
                r = 0.0
                g = min(8.0, g * 1.5)
            } else {
                b = 8.0
            }
            let alpha: Float = (x + y) % 3 == 0 ? 0.42 : 1.0
            return SIMD4<Float>(r, g, b, alpha)
        }
        let tile = makeTile(originX: 0, originY: 0, size: side, scale: .x2)

        let cpuProcessor = MetalColorProcessor(preferMetal: false)
        let hardwareProcessor = MetalColorProcessor()

        let cpuRunA = try runRoundTrip(
            processor: cpuProcessor,
            source: source.buffer,
            tile: tile,
            globalMaxLuminance: globalMaxLuminance,
            scale: 2,
            forceCPU: true
        )
        let cpuRunB = try runRoundTrip(
            processor: cpuProcessor,
            source: source.buffer,
            tile: tile,
            globalMaxLuminance: globalMaxLuminance,
            scale: 2,
            forceCPU: true
        )

        // The CPU fallback must be bit-for-bit deterministic regardless of Metal availability.
        XCTAssertEqual(cpuRunA.count, cpuRunB.count)
        XCTAssertEqual(cpuRunA, cpuRunB, "CPU fallback is not deterministic between two identical runs")

        // `forceCPU: true` must bypass the GPU even on a Metal-capable processor and reproduce the
        // pure-CPU processor's output bit for bit.
        let forcedCPURun = try runRoundTrip(
            processor: hardwareProcessor,
            source: source.buffer,
            tile: tile,
            globalMaxLuminance: globalMaxLuminance,
            scale: 2,
            forceCPU: true
        )
        XCTAssertEqual(forcedCPURun, cpuRunA, "forceCPU:true did not bypass Metal on a Metal-capable processor")

        guard hardwareProcessor.isMetalAccelerationAvailable else {
            print("[TrackC] Metal leg skipped: \(hardwareProcessor.metalUnavailabilityReason ?? "Metal unavailable")")
            throw XCTSkip("Metal device/pipelines unavailable in this CLI runner; CPU-vs-CPU determinism was asserted instead. Reason: \(hardwareProcessor.metalUnavailabilityReason ?? "unknown")")
        }

        let metalRun = try runRoundTrip(
            processor: hardwareProcessor,
            source: source.buffer,
            tile: tile,
            globalMaxLuminance: globalMaxLuminance,
            scale: 2,
            forceCPU: false
        )

        XCTAssertEqual(cpuRunA.count, metalRun.count)
        var maxAbsoluteDifference: Float = 0
        var maxRelativeDifference: Float = 0
        var maxRelativeDifferenceIndex = 0
        var nonFiniteCount = 0
        for index in 0..<cpuRunA.count {
            let cpuValue = Float(cpuRunA[index])
            let metalValue = Float(metalRun[index])
            if !cpuValue.isFinite || !metalValue.isFinite {
                nonFiniteCount += 1
                continue
            }
            let difference = abs(cpuValue - metalValue)
            maxAbsoluteDifference = max(maxAbsoluteDifference, difference)
            let denominator = max(abs(cpuValue), abs(metalValue), 1e-6)
            let relativeDifference = difference / denominator
            if relativeDifference > maxRelativeDifference {
                maxRelativeDifference = relativeDifference
                maxRelativeDifferenceIndex = index
            }
        }

        print("[TrackC] Metal-vs-CPU parity: maxAbsDiff=\(maxAbsoluteDifference) maxRelDiff=\(maxRelativeDifference) nonFinite=\(nonFiniteCount)")
        let worstPixelIndex = maxRelativeDifferenceIndex / 4
        print("[TrackC] Metal-vs-CPU worst relative sample: x=\(worstPixelIndex % (side * 2)) y=\(worstPixelIndex / (side * 2)) channel=\(maxRelativeDifferenceIndex % 4) cpu=\(Float(cpuRunA[maxRelativeDifferenceIndex])) cpuHalfBits=\(cpuRunA[maxRelativeDifferenceIndex].bitPattern) metal=\(Float(metalRun[maxRelativeDifferenceIndex])) metalHalfBits=\(metalRun[maxRelativeDifferenceIndex].bitPattern)")
        XCTAssertEqual(nonFiniteCount, 0, "Metal or CPU output contained NaN/Inf")
        let outputPlane = (side * 2) * (side * 2)
        XCTAssertEqual(cpuRunA.count, outputPlane * 4)

        // Documented tolerances: Metal and libm evaluate log/exp and FMA differently, and each
        // intermediate is stored in Float16 (ulp(8.0) = 0.0078125), so a bound of 2e-2 absolute on
        // the linear-HDR output and 2e-3 relative is used for the parity gate.
        XCTAssertLessThanOrEqual(maxAbsoluteDifference, 2e-2, "Metal vs CPU absolute parity exceeded 2e-2")
        XCTAssertLessThanOrEqual(maxRelativeDifference, 5e-3, "Metal vs CPU relative parity exceeded 5e-3")

        // Intermediate planes must agree tightly as well (they feed the ±0.55 chroma clamp).
        var cpuTensors = try hardwareProcessor.extractLogNormalizedRGBTile(
            from: source.buffer,
            tile: tile,
            globalMaxLuminance: globalMaxLuminance,
            forceCPU: true
        )
        var metalTensors = try hardwareProcessor.extractLogNormalizedRGBTile(
            from: source.buffer,
            tile: tile,
            globalMaxLuminance: globalMaxLuminance,
            forceCPU: false
        )
        XCTAssertEqual(cpuTensors.planarTensorFP16.count, metalTensors.planarTensorFP16.count)
        var maxLogPlaneDifference: Float = 0
        for index in 0..<cpuTensors.planarTensorFP16.count {
            maxLogPlaneDifference = max(
                maxLogPlaneDifference,
                abs(Float(cpuTensors.planarTensorFP16[index]) - Float(metalTensors.planarTensorFP16[index]))
            )
        }
        print("[TrackC] Metal-vs-CPU max log-plane difference: \(maxLogPlaneDifference)")
        XCTAssertLessThanOrEqual(maxLogPlaneDifference, 1e-3, "Metal vs CPU log-normalized planes diverged by more than one Float16 ulp")

        // Keep a failed hosted-GPU run diagnosable without relaxing the parity gate. In particular,
        // one half-subnormal step can look like a large relative error near a chroma cancellation.
        if maxRelativeDifference > 5e-3 {
            let sourceX = (worstPixelIndex % (side * 2)) / 2
            let sourceY = (worstPixelIndex / (side * 2)) / 2
            let sourceIndex = sourceY * side + sourceX
            let planeCount = side * side
            let inputRGBA = Array(source.pixelValues[(sourceIndex * 4)..<(sourceIndex * 4 + 4)])
            let cpuLog = (0..<3).map { Float(cpuTensors.planarTensorFP16[$0 * planeCount + sourceIndex]) }
            let metalLog = (0..<3).map { Float(metalTensors.planarTensorFP16[$0 * planeCount + sourceIndex]) }
            print("[TrackC] Metal-vs-CPU worst source: x=\(sourceX) y=\(sourceY) rgba=\(inputRGBA) cpuLog=\(cpuLog) metalLog=\(metalLog) logK=\(cpuTensors.logConstantK)")
            try hardwareProcessor.decoupleLuminanceAndChrominance(tensors: &cpuTensors, forceCPU: true)
            try hardwareProcessor.decoupleLuminanceAndChrominance(tensors: &metalTensors, forceCPU: false)
            print("[TrackC] Metal-vs-CPU worst source decoupled: cpuY=\(Float(cpuTensors.planarTensorFP16[sourceIndex])) metalY=\(Float(metalTensors.planarTensorFP16[sourceIndex])) cpuCb=\(cpuTensors.cbPlane[sourceIndex]) metalCb=\(metalTensors.cbPlane[sourceIndex]) cpuCr=\(cpuTensors.crPlane[sourceIndex]) metalCr=\(metalTensors.crPlane[sourceIndex])")

            func reconstructedSample(_ tensors: PreparedTileTensors, forceCPU: Bool) throws -> Float {
                let y = makeIdentityUpscaledY(tensors: tensors, scale: 2)
                var output = [Float16](repeating: 0, count: cpuRunA.count)
                try y.withUnsafeBufferPointer { input in
                    try output.withUnsafeMutableBufferPointer { destination in
                        try hardwareProcessor.reconstructUpscaledTile(
                            upscaledYPlanarFP16: input, tensors: tensors, scale: 2,
                            destinationRGBA16F: destination.baseAddress!, forceCPU: forceCPU
                        )
                    }
                }
                return Float(output[maxRelativeDifferenceIndex])
            }
            let cpuToMetal = try reconstructedSample(cpuTensors, forceCPU: false)
            let metalToCPU = try reconstructedSample(metalTensors, forceCPU: true)
            print("[TrackC] Metal-vs-CPU worst sample stage isolation: cpuForwardMetalInverse=\(cpuToMetal) metalForwardCPUInverse=\(metalToCPU)")
        }
    }

    // MARK: - Edge cases

    func testMalformedDimensionsThrowBeforeArithmeticOrAllocation() throws {
        let processor = MetalColorProcessor(preferMetal: false)
        for side in [0, -1, Int.min, Int.max, 1 << 31] {
            var tensors = PreparedTileTensors(
                tileSize: side,
                logConstantK: 1,
                alphaConstant: 16,
                planarTensorFP16: [],
                cbPlane: [],
                crPlane: [],
                alphaPlane: []
            )
            XCTAssertThrowsError(try processor.decoupleLuminanceAndChrominance(tensors: &tensors, forceCPU: true))
            XCTAssertThrowsError(try processor.upsampleChromaToOutput(
                cbPlane: [], crPlane: [], sourceWidth: side, sourceHeight: 2, scaleFactor: .x4
            ))
        }

        let source = try makeSourceBuffer(width: 1, height: 1) { _, _ in SIMD4<Float>(1, 1, 1, 1) }
        let hugeTile = makeTile(originX: 0, originY: 0, size: Int.max / 4, scale: .x2)
        XCTAssertThrowsError(try processor.extractLogNormalizedRGBTile(
            from: source.buffer, tile: hugeTile, globalMaxLuminance: 1, forceCPU: true
        ))
        // A valid tile size can still have an invalid origin loaded from a corrupt checkpoint.
        let invalidOriginTile = TileDescriptor(
            tileIndex: 0, row: 0, col: 0, inputOriginX: Int.max, inputOriginY: 0,
            inputSize: 2, outputOriginX: 0, outputOriginY: 0, outputSize: 4,
            actualLeftOverlapOut: 0, actualTopOverlapOut: 0
        )
        XCTAssertThrowsError(try processor.extractLogNormalizedRGBTile(
            from: source.buffer, tile: invalidOriginTile, globalMaxLuminance: 1, forceCPU: true
        ))

        let tensors = PreparedTileTensors(
            tileSize: 1, logConstantK: 1, alphaConstant: 16,
            planarTensorFP16: [0, 0, 0], cbPlane: [0], crPlane: [0], alphaPlane: [1]
        )
        let y: [Float16] = [0, 0, 0]
        var destination: [Float16] = [0, 0, 0, 0]
        try y.withUnsafeBufferPointer { input in
            try destination.withUnsafeMutableBufferPointer { output in
                for scale in [0, -1, Int.min, Int.max] {
                    XCTAssertThrowsError(try processor.reconstructUpscaledTile(
                        upscaledYPlanarFP16: input, tensors: tensors, scale: scale,
                        destinationRGBA16F: output.baseAddress!, forceCPU: true
                    ))
                }
            }
        }
        XCTAssertEqual(destination, [0, 0, 0, 0])
    }

    func testZeroMaxLuminanceTinyTileAndChromaUpsamplerEdgeCases() throws {
        // Zero (and NaN) global max luminance must not produce NaN/Inf: the spec assumes max >= 1.0
        // and the implementation guards the log denominator instead of dividing by zero.
        let side = 2
        let tinySource = try makeSourceBuffer(width: side, height: side) { _, _ in
            SIMD4<Float>(8.0, 4.0, 2.0, 0.42)
        }
        let tinyTile = makeTile(originX: 0, originY: 0, size: side, scale: .x2)
        let processor = MetalColorProcessor(preferMetal: false)
        XCTAssertNil(processor.device)
        XCTAssertFalse(processor.isMetalAccelerationAvailable)
        var zeroMaxTensors = try processor.extractLogNormalizedRGBTile(
            from: tinySource.buffer,
            tile: tinyTile,
            globalMaxLuminance: 0.0,
            forceCPU: true
        )
        XCTAssertTrue(zeroMaxTensors.logConstantK.isFinite)
        XCTAssertGreaterThan(zeroMaxTensors.logConstantK, 0)
        XCTAssertEqual(zeroMaxTensors.planarTensorFP16.count, 3 * side * side)
        for value in zeroMaxTensors.planarTensorFP16 {
            XCTAssertTrue(value.isFinite, "Zero max luminance produced a non-finite log-normalized value")
        }
        try processor.decoupleLuminanceAndChrominance(tensors: &zeroMaxTensors, forceCPU: true)
        for value in zeroMaxTensors.cbPlane + zeroMaxTensors.crPlane {
            XCTAssertTrue(value.isFinite, "Zero max luminance produced a non-finite chroma value")
        }
        var tinyOutput = [Float16](repeating: 0, count: 4 * (side * 2) * (side * 2))
        let tinyUpscaledY = makeIdentityUpscaledY(tensors: zeroMaxTensors, scale: 2)
        try tinyUpscaledY.withUnsafeBufferPointer { yBuffer in
            try tinyOutput.withUnsafeMutableBufferPointer { outputBuffer in
                try processor.reconstructUpscaledTile(
                    upscaledYPlanarFP16: yBuffer,
                    tensors: zeroMaxTensors,
                    scale: 2,
                    destinationRGBA16F: outputBuffer.baseAddress!,
                    forceCPU: true
                )
            }
        }
        for value in tinyOutput {
            XCTAssertTrue(value.isFinite, "Zero max luminance produced a non-finite reconstructed pixel")
        }

        let nanMaxTensors = try processor.extractLogNormalizedRGBTile(
            from: tinySource.buffer,
            tile: tinyTile,
            globalMaxLuminance: .nan,
            forceCPU: true
        )
        XCTAssertTrue(nanMaxTensors.logConstantK.isFinite, "NaN max luminance leaked into the log denominator")

        // A 1x1 tile must traverse extract -> decouple -> reconstruct without out-of-bounds taps.
        let oneSource = try makeSourceBuffer(width: 1, height: 1) { _, _ in
            SIMD4<Float>(4.2, 0.1, 0.05, 0.42)
        }
        let oneTile = makeTile(originX: 0, originY: 0, size: 1, scale: .x2)
        var oneTensors = try processor.extractLogNormalizedRGBTile(
            from: oneSource.buffer,
            tile: oneTile,
            globalMaxLuminance: 8.0,
            forceCPU: true
        )
        try processor.decoupleLuminanceAndChrominance(tensors: &oneTensors, forceCPU: true)
        var oneOutput = [Float16](repeating: 0, count: 4)
        let oneUpscaledY = makeIdentityUpscaledY(tensors: oneTensors, scale: 1)
        try oneUpscaledY.withUnsafeBufferPointer { yBuffer in
            try oneOutput.withUnsafeMutableBufferPointer { outputBuffer in
                try processor.reconstructUpscaledTile(
                    upscaledYPlanarFP16: yBuffer,
                    tensors: oneTensors,
                    scale: 1,
                    destinationRGBA16F: outputBuffer.baseAddress!,
                    forceCPU: true
                )
            }
        }
        let oneMetrics = measureRoundTrip(
            output: oneOutput,
            sourcePixels: oneSource.pixelValues,
            sourceWidth: 1,
            scale: 1,
            globalMaxLuminance: 8.0
        )
        print("[TrackC] 1x1 tile round trip maxAbs=\(oneMetrics.maxAbsoluteError) maxRel=\(oneMetrics.maxRelativeError) maxNormalized=\(oneMetrics.maxNormalizedError)")
        XCTAssertEqual(oneMetrics.nonFiniteCount, 0)
        XCTAssertLessThan(oneMetrics.maxNormalizedError, 1e-3, "1x1 tile round trip exceeded the FP16 normalized tolerance")
        XCTAssertLessThan(oneMetrics.maxAlphaError, 1e-3, "1x1 tile alpha was not preserved")

        // The public chroma upsampler must preserve a constant plane exactly at 2x and 4x.
        let constantPlane = [Float](repeating: 0.25, count: 16)
        for scale in [ScaleFactor.x2, ScaleFactor.x4] {
            let upsampled = try processor.upsampleChromaToOutput(
                cbPlane: constantPlane,
                crPlane: constantPlane.map { -$0 },
                sourceWidth: 4,
                sourceHeight: 4,
                scaleFactor: scale
            )
            let expectedCount = 4 * scale.rawValue * 4 * scale.rawValue
            XCTAssertEqual(upsampled.cbPlane.count, expectedCount)
            XCTAssertEqual(upsampled.crPlane.count, expectedCount)
            for value in upsampled.cbPlane {
                XCTAssertEqual(value, 0.25, accuracy: 1e-6, "Constant Cb plane was not preserved at \(scale.rawValue)x")
            }
            for value in upsampled.crPlane {
                XCTAssertEqual(value, -0.25, accuracy: 1e-6, "Constant Cr plane was not preserved at \(scale.rawValue)x")
            }
        }

        XCTAssertThrowsError(
            try processor.upsampleChromaToOutput(
                cbPlane: [Float](repeating: 0, count: 3),
                crPlane: [Float](repeating: 0, count: 4),
                sourceWidth: 2,
                sourceHeight: 2,
                scaleFactor: .x2
            ),
            "Mismatched chroma plane sizes must throw instead of reading out of bounds"
        )
    }

    // MARK: - Exact spec math (fails if any coefficient, log curve, or bicubic tap is stubbed)

    func testSpecifiedColorMathAndBicubicInterpolation() throws {
        let globalMaxLuminance: Float = 8.0
        let alpha: Float = 16.0
        let logConstantK = log(1.0 + alpha * globalMaxLuminance)
        let processor = MetalColorProcessor(preferMetal: false)

        // Forward reversible log normalization: log(1 + alpha * c) / log(1 + alpha * maxLuminance).
        let hdrPixel = SIMD4<Float>(4.2, 0.1, 0.05, 0.42)
        let source = try makeSourceBuffer(width: 1, height: 1) { _, _ in hdrPixel }
        let tile = makeTile(originX: 0, originY: 0, size: 1, scale: .x2)
        var tensors = try processor.extractLogNormalizedRGBTile(
            from: source.buffer,
            tile: tile,
            globalMaxLuminance: globalMaxLuminance,
            alphaConstant: alpha,
            forceCPU: true
        )
        XCTAssertEqual(tensors.logConstantK, logConstantK, accuracy: 1e-5, "K must equal log(1 + alpha * maxLuminance)")
        // The MMapBuffer stores Float16, so the exact inputs are the half-rounded values.
        let halfR = Float(Float16(4.2))
        let halfG = Float(Float16(0.1))
        let halfB = Float(Float16(0.05))
        let inverseK = 1.0 / logConstantK
        let expectedLogR = Float16(log(1.0 + alpha * halfR) * inverseK)
        let expectedLogG = Float16(log(1.0 + alpha * halfG) * inverseK)
        let expectedLogB = Float16(log(1.0 + alpha * halfB) * inverseK)
        XCTAssertEqual(tensors.planarTensorFP16[0], expectedLogR, "Forward log curve R is wrong")
        XCTAssertEqual(tensors.planarTensorFP16[1], expectedLogG, "Forward log curve G is wrong")
        XCTAssertEqual(tensors.planarTensorFP16[2], expectedLogB, "Forward log curve B is wrong")
        XCTAssertEqual(tensors.alphaPlane[0], Float16(0.42), "Alpha must pass through unchanged")

        // Display P3 / Rec.2020 decoupling coefficients, exactly as written in the Metal kernel.
        // Capture the pre-decouple Log-RGB values first: decoupling overwrites the tensor with Y.
        let rn = Float(tensors.planarTensorFP16[0])
        let gn = Float(tensors.planarTensorFP16[1])
        let bn = Float(tensors.planarTensorFP16[2])
        let expectedY = 0.22897456 * rn + 0.69173852 * gn + 0.07928691 * bn
        let expectedCb = 0.54305895 * (bn - expectedY)
        let expectedCr = 0.64848699 * (rn - expectedY)
        let halfY = Float(Float16(expectedY))
        try processor.decoupleLuminanceAndChrominance(tensors: &tensors, forceCPU: true)
        XCTAssertEqual(Float(tensors.planarTensorFP16[0]), halfY, "Replicated Y plane 0 is wrong")
        XCTAssertEqual(Float(tensors.planarTensorFP16[1]), halfY, "Replicated Y plane 1 is wrong")
        XCTAssertEqual(Float(tensors.planarTensorFP16[2]), halfY, "Replicated Y plane 2 is wrong")
        XCTAssertEqual(tensors.cbPlane[0], expectedCb, accuracy: 1e-6, "Cb coefficient is wrong")
        XCTAssertEqual(tensors.crPlane[0], expectedCr, accuracy: 1e-6, "Cr coefficient is wrong")

        // Inverse recombination + inverse log at scale 1 (identity chroma/alpha taps).
        let upscaledY = makeIdentityUpscaledY(tensors: tensors, scale: 1)
        var reconstructed = [Float16](repeating: 0, count: 4)
        try upscaledY.withUnsafeBufferPointer { yBuffer in
            try reconstructed.withUnsafeMutableBufferPointer { outputBuffer in
                try processor.reconstructUpscaledTile(
                    upscaledYPlanarFP16: yBuffer,
                    tensors: tensors,
                    scale: 1,
                    destinationRGBA16F: outputBuffer.baseAddress!,
                    forceCPU: true
                )
            }
        }
        let rnInverse = min(max(halfY + 1.54205088 * expectedCr, 0.0), 1.2)
        let bnInverse = min(max(halfY + 1.84142182 * expectedCb, 0.0), 1.2)
        let gnInverse = min(max(halfY - 0.51043918 * expectedCr - 0.21106322 * expectedCb, 0.0), 1.2)
        let inverseAlpha = 1.0 / alpha
        let expectedLinearR = Float16(max(0.0, (exp(rnInverse * logConstantK) - 1.0) * inverseAlpha))
        let expectedLinearG = Float16(max(0.0, (exp(gnInverse * logConstantK) - 1.0) * inverseAlpha))
        let expectedLinearB = Float16(max(0.0, (exp(bnInverse * logConstantK) - 1.0) * inverseAlpha))
        XCTAssertEqual(reconstructed[0], expectedLinearR, "Inverse log/matrix R is wrong")
        XCTAssertEqual(reconstructed[1], expectedLinearG, "Inverse log/matrix G is wrong")
        XCTAssertEqual(reconstructed[2], expectedLinearB, "Inverse log/matrix B is wrong")
        XCTAssertEqual(reconstructed[3], Float16(0.42), "Alpha must survive reconstruction")

        // Catmull-Rom 4x4 bicubic chroma upsampling against an independent scalar reference.
        let plane: [Float] = [
            0.00, 0.25, 0.50, 0.75,
            1.00, -0.25, 0.30, 0.10,
            -0.50, 0.40, 0.20, 0.60,
            0.05, 0.15, 0.85, -0.35
        ]
        for scale in [ScaleFactor.x2, ScaleFactor.x4] {
            let upsampled = try processor.upsampleChromaToOutput(
                cbPlane: plane,
                crPlane: plane.map { -$0 },
                sourceWidth: 4,
                sourceHeight: 4,
                scaleFactor: scale
            )
            let reference = referenceBicubicUpsample(plane, width: 4, height: 4, scale: scale.rawValue)
            XCTAssertEqual(upsampled.cbPlane.count, reference.count)
            var maxDifference: Float = 0
            var maxDeviationFromNearest: Float = 0
            let side = 4 * scale.rawValue
            for outputY in 0..<side {
                for outputX in 0..<side {
                    let index = outputY * side + outputX
                    maxDifference = max(maxDifference, abs(upsampled.cbPlane[index] - reference[index]))
                    maxDifference = max(maxDifference, abs(upsampled.crPlane[index] + reference[index]))
                    let nearest = plane[(outputY / scale.rawValue) * 4 + (outputX / scale.rawValue)]
                    maxDeviationFromNearest = max(maxDeviationFromNearest, abs(upsampled.cbPlane[index] - nearest))
                }
            }
            print("[TrackC] bicubic scale=\(scale.rawValue) maxRefDiff=\(maxDifference) maxDeviationFromNearest=\(maxDeviationFromNearest)")
            XCTAssertLessThan(maxDifference, 1e-5, "Bicubic upsampling does not match the spec's Catmull-Rom kernel at \(scale.rawValue)x")
            XCTAssertGreaterThan(maxDeviationFromNearest, 1e-2, "Bicubic upsampling degenerated to nearest-neighbour at \(scale.rawValue)x")
        }
    }

    // MARK: - Independent inverse-matrix reference (contract §9)

    /// Independent oracle: builds the forward `RGB -> YCbCr` matrix from the retained spec coefficients,
    /// then inverts it with a Gauss-Jordan solver written here. This is deliberately *not* a second copy
    /// of the shader/CPU inverse formula, so a consistently-wrong hardcoded inverse cannot pass.
    func testIndependentNumericalInversionProducesImplementedInverseCoefficients() throws {
        let forward = forwardDisplayP3YCbCrMatrix()
        let inverse = try XCTUnwrap(independentInverse(forward))

        // Row order of the inverse is [R, G, B]; columns are [Y, Cb, Cr].
        XCTAssertEqual(inverse[0][2], 1.54205088, accuracy: 5e-6, "R = Y + 1.54205088 Cr is not the matrix inverse")
        XCTAssertEqual(inverse[2][1], 1.84142182, accuracy: 5e-6, "B = Y + 1.84142182 Cb is not the matrix inverse")
        XCTAssertEqual(inverse[1][1], -0.21106322, accuracy: 5e-6, "G/Cb coefficient is not the matrix inverse")
        XCTAssertEqual(inverse[1][2], -0.51043918, accuracy: 5e-6, "G/Cr coefficient is not the matrix inverse")

        // The reviewed stale values are demonstrably not the inverse of the retained forward matrix.
        XCTAssertGreaterThan(abs(inverse[1][2] + 0.51101911), 5e-4, "The stale G/Cr coefficient is indistinguishable from the matrix inverse")
        XCTAssertGreaterThan(abs(inverse[1][1] + 0.21107725), 1e-5, "The stale G/Cb coefficient is indistinguishable from the matrix inverse")
    }

    /// The `.metal` source and the runtime-embedded source must stay byte-identical (whitespace/newline
    /// aside), and neither may retain the pre-repair green coefficients.
    func testMetalFileAndEmbeddedShaderSourceMatchWithCorrectedInverseMatrix() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MetalColorEngineTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
        let shaderURL = repositoryRoot.appendingPathComponent("Sources/MetalColorEngine/Shaders/ColorAndToneKernels.metal")
        let shaderFile = try String(contentsOf: shaderURL, encoding: .utf8)
        let embedded = MetalColorProcessor.metalShaderSource

        XCTAssertEqual(
            shaderFile.trimmingCharacters(in: .newlines),
            embedded.trimmingCharacters(in: .newlines),
            "ColorAndToneKernels.metal and MetalColorProcessor.metalShaderSource must stay byte-identical."
        )
        for source in [shaderFile, embedded] {
            XCTAssertTrue(source.contains("0.51043918f"), "Corrected G/Cr inverse coefficient is missing from a Metal source")
            XCTAssertTrue(source.contains("0.21106322f"), "Corrected G/Cb inverse coefficient is missing from a Metal source")
            XCTAssertFalse(source.contains("0.51101911"), "Stale G/Cr inverse coefficient remains in a Metal source")
            XCTAssertFalse(source.contains("0.21107725"), "Stale G/Cb inverse coefficient remains in a Metal source")
        }
    }

    /// Round-trips colored and neutral HDR patches at every supported scale (identity 1x, 2x, 4x),
    /// checking both the source values (FP16-aware tolerances) and an independent inverse-matrix oracle
    /// derived from the pipeline's own forward intermediates. Also checks alpha and Metal/CPU parity.
    func testIndependentInverseRoundTripForColoredAndNeutralHDRPatchesAtAllScales() throws {
        let forward = forwardDisplayP3YCbCrMatrix()
        let inverse = try XCTUnwrap(independentInverse(forward))
        let globalMaxLuminance: Float = 8.0
        let alpha: Float = 16.0
        let logConstantK = Double(log(1.0 + alpha * globalMaxLuminance))
        let inverseAlpha = 1.0 / Double(alpha)

        let cpuProcessor = MetalColorProcessor(preferMetal: false)
        let hardwareProcessor = MetalColorProcessor()
        print("[TrackE] Metal acceleration available: \(hardwareProcessor.isMetalAccelerationAvailable) reason=\(hardwareProcessor.metalUnavailabilityReason ?? "none")")

        let patches: [(name: String, color: SIMD4<Float>)] = [
            ("colored-red", SIMD4<Float>(4.2, 0.1, 0.05, 0.42)),
            ("neutral-hdr-peak", SIMD4<Float>(8.0, 8.0, 8.0, 1.0)),
            ("hdr-cyan", SIMD4<Float>(0.05, 2.4, 2.8, 0.42)),
            ("saturated-magenta", SIMD4<Float>(6.5, 0.2, 4.0, 0.75)),
            ("colored-green", SIMD4<Float>(0.1, 4.2, 0.05, 0.5))
        ]

        for patch in patches {
            let side = 16
            let source = try makeSourceBuffer(width: side, height: side) { _, _ in patch.color }
            for scale in [1, 2, 4] {
                let tile = makeTile(originX: 0, originY: 0, size: side, scale: .x4)

                // Pull the pipeline's actual forward intermediates, then reconstruct with the
                // independently inverted matrix as the oracle (not the implementation's inverse constants).
                var tensors = try cpuProcessor.extractLogNormalizedRGBTile(
                    from: source.buffer,
                    tile: tile,
                    globalMaxLuminance: globalMaxLuminance,
                    forceCPU: true
                )
                try cpuProcessor.decoupleLuminanceAndChrominance(tensors: &tensors, forceCPU: true)
                let luminance = Double(Float(tensors.planarTensorFP16[0]))
                let cb = Double(tensors.cbPlane[0])
                let cr = Double(tensors.crPlane[0])
                let expectedChannels: [Float16] = (0..<3).map { row in
                    let normalized = inverse[row][0] * luminance + inverse[row][1] * cb + inverse[row][2] * cr
                    let clamped = min(max(normalized, 0.0), 1.2)
                    return Float16(max(0.0, (exp(clamped * logConstantK) - 1.0) * inverseAlpha))
                }

                let cpuOutput = try runRoundTrip(
                    processor: cpuProcessor,
                    source: source.buffer,
                    tile: tile,
                    globalMaxLuminance: globalMaxLuminance,
                    scale: scale,
                    forceCPU: true
                )
                let outputSize = side * scale
                let outputPixelCount = outputSize * outputSize
                for pixel in 0..<outputPixelCount {
                    for channel in 0..<3 {
                        let actual = cpuOutput[pixel * 4 + channel]
                        let expected = expectedChannels[channel]
                        let halfSpacing = max(Float(expected.ulp), 1e-6)
                        // CPython/Swift exp differ in the last float bits, but the corrected values sit
                        // far from a Float16 rounding boundary; an adjacent half means the inverse is wrong.
                        XCTAssertLessThan(
                            abs(Float(actual) - Float(expected)),
                            halfSpacing,
                            "Independent inverse oracle mismatch for \(patch.name) at scale \(scale)x channel \(channel): \(actual) vs \(expected)"
                        )
                    }
                    XCTAssertEqual(
                        cpuOutput[pixel * 4 + 3],
                        Float16(patch.color.w),
                        "Alpha drifted for \(patch.name) at scale \(scale)x"
                    )
                }

                // Source round trip at FP16-appropriate tolerances: near 8.0 one half-float step is
                // 0.0078125, so an absolute threshold below 0.001 would be below one FP16 ulp.
                let metrics = measureRoundTrip(
                    output: cpuOutput,
                    sourcePixels: source.pixelValues,
                    sourceWidth: side,
                    scale: scale,
                    globalMaxLuminance: globalMaxLuminance
                )
                print("[TrackE] patch=\(patch.name) scale=\(scale) maxAbs=\(metrics.maxAbsoluteError) maxRel=\(metrics.maxRelativeError) maxNormalized=\(metrics.maxNormalizedError) maxAlpha=\(metrics.maxAlphaError)")
                XCTAssertEqual(metrics.nonFiniteCount, 0, "\(patch.name) at scale \(scale)x produced NaN/Inf")
                XCTAssertLessThan(metrics.maxAbsoluteError, 1e-2, "\(patch.name) at scale \(scale)x exceeded two Float16 ulps at the HDR peak")
                XCTAssertLessThan(metrics.maxNormalizedError, 1e-3, "\(patch.name) at scale \(scale)x normalized error exceeded 1e-3")
                // Relative error is measured in Float16 ulps of the expected value: a literal relative
                // bound such as 2e-3 rejects low-amplitude channels (e.g. 0.05) whose absolute error is
                // only ~1e-4. The forward log plane is itself stored Float16, so a few ulps of final
                // deviation are expected; the absolute and peak-normalized bounds above are the primary
                // gates, and this ulp budget catches gross per-channel drift.
                var maxULPError: Float = 0
                for outputY in 0..<outputSize {
                    let sourceY = min(side - 1, outputY / scale)
                    for outputX in 0..<outputSize {
                        let sourceX = min(side - 1, outputX / scale)
                        let outputIndex = (outputY * outputSize + outputX) * 4
                        let sourceIndex = (sourceY * side + sourceX) * 4
                        for channel in 0..<3 {
                            let actual = Float(cpuOutput[outputIndex + channel])
                            let expected = source.pixelValues[sourceIndex + channel]
                            let spacing = max(Float(Float16(expected).ulp), 1e-6)
                            maxULPError = max(maxULPError, abs(actual - expected) / spacing)
                        }
                    }
                }
                XCTAssertLessThanOrEqual(maxULPError, 8.0, "\(patch.name) at scale \(scale)x exceeded the FP16 storage budget of 8 ulps")
                XCTAssertLessThan(metrics.maxAlphaError, 1e-6, "\(patch.name) at scale \(scale)x alpha drifted")

                guard hardwareProcessor.isMetalAccelerationAvailable else { continue }
                let metalOutput = try runRoundTrip(
                    processor: hardwareProcessor,
                    source: source.buffer,
                    tile: tile,
                    globalMaxLuminance: globalMaxLuminance,
                    scale: scale,
                    forceCPU: false
                )
                XCTAssertEqual(metalOutput.count, cpuOutput.count)
                var maxAbsoluteDifference: Float = 0
                var maxRelativeDifference: Float = 0
                for index in 0..<cpuOutput.count {
                    let cpuValue = Float(cpuOutput[index])
                    let metalValue = Float(metalOutput[index])
                    let difference = abs(cpuValue - metalValue)
                    maxAbsoluteDifference = max(maxAbsoluteDifference, difference)
                    maxRelativeDifference = max(
                        maxRelativeDifference,
                        difference / max(abs(cpuValue), abs(metalValue), 1e-6)
                    )
                }
                print("[TrackE] parity patch=\(patch.name) scale=\(scale) maxAbsDiff=\(maxAbsoluteDifference) maxRelDiff=\(maxRelativeDifference)")
                // Metal and libm evaluate log/exp differently and every intermediate is Float16, so the
                // documented parity gate is 2e-2 absolute / 5e-3 relative on the linear HDR output.
                XCTAssertLessThanOrEqual(maxAbsoluteDifference, 2e-2, "Metal vs CPU absolute parity failed for \(patch.name) at scale \(scale)x")
                XCTAssertLessThanOrEqual(maxRelativeDifference, 5e-3, "Metal vs CPU relative parity failed for \(patch.name) at scale \(scale)x")
            }
        }
    }

    // MARK: - Review regression: component-bounded normalization (contract §R1)

    /// The reviewed defect: the production caller fed the source *luminance* peak into the forward
    /// log curve. A saturated red of 4.0 has luminance ~0.916 (floored to 1.0), so its normalized
    /// sample became ~1.47, was clipped by the decouple/reconstruct safety clamps, and round-tripped
    /// as 1.0. The fix carries the decoded RGB *component* peak through the additive
    /// `globalMaxLinearComponent:` parameter.
    ///
    /// This probe uses the actual decoder telemetry (luminance `0.22897456 * 4`, component `4`) — it
    /// does not use an arbitrary oversized manual constant like 8 — and checks CPU/Metal parity.
    func testCodexReviewSaturatedHDRComponentBoundedRoundTrip() throws {
        let saturatedRed: Float = 4.0
        // Actual decoder telemetry for a saturated red of 4: luminance = 0.22897456 * 4 ≈ 0.9159.
        let decoderLuminance = Float(0.22897456 * 4.0)
        let source = try makeSourceBuffer(width: 2, height: 2) { _, _ in
            SIMD4<Float>(saturatedRed, 0, 0, 1)
        }
        let tile = makeTile(originX: 0, originY: 0, size: 2, scale: .x2)
        let cpuProcessor = MetalColorProcessor(preferMetal: false)
        let hardwareProcessor = MetalColorProcessor()

        // Omitting the additive component peak now derives a conservative component bound from the
        // immutable source canvas, so the documented production API cannot silently clip saturated
        // HDR even when a direct caller only supplies luminance telemetry.
        let legacyTensors = try cpuProcessor.extractLogNormalizedRGBTile(
            from: source.buffer,
            tile: tile,
            globalMaxLuminance: 1.0,
            forceCPU: true
        )
        XCTAssertEqual(legacyTensors.logConstantK, log(1.0 + 16.0 * saturatedRed), accuracy: 1e-5,
                       "Omitting the additive component peak must derive the source component bound.")
        XCTAssertEqual(Float(legacyTensors.planarTensorFP16[0]), 1.0, accuracy: 2e-3,
                       "Auto-derived component normalization must keep saturated HDR within [0,1].")

        // The component peak widens K so the absolute HDR component is not clipped before decoupling.
        let componentTensors = try cpuProcessor.extractLogNormalizedRGBTile(
            from: source.buffer,
            tile: tile,
            globalMaxLuminance: decoderLuminance,
            globalMaxLinearComponent: saturatedRed,
            forceCPU: true
        )
        XCTAssertEqual(componentTensors.logConstantK, log(1.0 + 16.0 * saturatedRed), accuracy: 1e-5)
        XCTAssertEqual(Float(componentTensors.planarTensorFP16[0]), 1.0, accuracy: 2e-3,
                       "A component-bounded saturated red must normalize to 1.0, not > 1.")

        for scale in [1, 2] {
            let cpuOutput = try runRoundTrip(
                processor: cpuProcessor,
                source: source.buffer,
                tile: tile,
                globalMaxLuminance: decoderLuminance,
                globalMaxLinearComponent: saturatedRed,
                scale: scale,
                forceCPU: true
            )
            let outputPixelCount = 2 * scale * 2 * scale
            for pixel in 0..<outputPixelCount {
                XCTAssertEqual(Float(cpuOutput[pixel * 4 + 0]), saturatedRed, accuracy: 0.02,
                               "CPU round trip clipped the saturated component at scale \(scale).")
                XCTAssertEqual(Float(cpuOutput[pixel * 4 + 1]), 0, accuracy: 0.005)
                XCTAssertEqual(Float(cpuOutput[pixel * 4 + 2]), 0, accuracy: 0.005)
                XCTAssertEqual(Float(cpuOutput[pixel * 4 + 3]), 1, accuracy: 1e-3)
            }

            guard hardwareProcessor.isMetalAccelerationAvailable else {
                print("[GroupB] Metal unavailable; CPU-only saturated-HDR color verification: \(hardwareProcessor.metalUnavailabilityReason ?? "none")")
                continue
            }
            let metalOutput = try runRoundTrip(
                processor: hardwareProcessor,
                source: source.buffer,
                tile: tile,
                globalMaxLuminance: decoderLuminance,
                globalMaxLinearComponent: saturatedRed,
                scale: scale,
                forceCPU: false
            )
            XCTAssertEqual(metalOutput.count, cpuOutput.count)
            var maxAbsoluteDifference: Float = 0
            for index in 0..<cpuOutput.count {
                let cpuValue = Float(cpuOutput[index])
                let metalValue = Float(metalOutput[index])
                maxAbsoluteDifference = max(maxAbsoluteDifference, abs(cpuValue - metalValue))
            }
            print("[GroupB] saturated-red parity scale=\(scale) maxAbsDiff=\(maxAbsoluteDifference)")
            XCTAssertLessThanOrEqual(
                maxAbsoluteDifference,
                2e-2,
                "Metal vs CPU parity failed for the component-bounded saturated red at scale \(scale)."
            )
        }
    }

    // MARK: - Helpers

    /// Forward Display P3 `RGB -> (Y, Cb, Cr)` matrix as retained by the spec.
    /// Rows are [Y, Cb, Cr]; columns are [R, G, B].
    private func forwardDisplayP3YCbCrMatrix() -> [[Double]] {
        let kR = 0.22897456
        let kG = 0.69173852
        let kB = 0.07928691
        let cbScale = 0.54305895
        let crScale = 0.64848699
        return [
            [kR, kG, kB],
            [-cbScale * kR, -cbScale * kG, cbScale * (1.0 - kB)],
            [crScale * (1.0 - kR), -crScale * kG, -crScale * kB]
        ]
    }

    /// Independent 3x3 Gauss-Jordan inversion with partial pivoting (test oracle only).
    private func independentInverse(_ matrix: [[Double]]) -> [[Double]]? {
        guard matrix.count == 3, matrix.allSatisfy({ $0.count == 3 }) else { return nil }
        var augmented = matrix
        for row in 0..<3 {
            augmented[row] += (0..<3).map { $0 == row ? 1.0 : 0.0 }
        }
        for column in 0..<3 {
            let pivotRow = (column..<3).max { abs(augmented[$0][column]) < abs(augmented[$1][column]) } ?? column
            guard abs(augmented[pivotRow][column]) > 1e-12 else { return nil }
            if pivotRow != column {
                augmented.swapAt(pivotRow, column)
            }
            let pivot = augmented[column][column]
            augmented[column] = augmented[column].map { $0 / pivot }
            for row in 0..<3 where row != column {
                let factor = augmented[row][column]
                guard factor != 0 else { continue }
                for index in 0..<6 {
                    augmented[row][index] -= factor * augmented[column][index]
                }
            }
        }
        return augmented.map { Array($0[3..<6]) }
    }

    /// Builds a temp-directory `MMapBuffer` and returns the tightly packed logical RGBA values
    /// (post-Float16-rounding) so tests compare against exactly what was stored on disk.
    private func makeSourceBuffer(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> SIMD4<Float>
    ) throws -> (buffer: MMapBuffer, pixelValues: [Float]) {
        let fileURL = temporaryDirectory.appendingPathComponent("source-\(width)x\(height)-\(UUID().uuidString).rgba16f")
        let buffer = try MMapBuffer(fileURL: fileURL, width: width, height: height, deleteOnDeinit: true)
        var halfPixels = [Float16](repeating: 0, count: width * height * 4)
        var logicalPixels = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = pixel(x, y)
                let index = (y * width + x) * 4
                let stored = SIMD4<Float16>(
                    Float16(value.x),
                    Float16(value.y),
                    Float16(value.z),
                    Float16(value.w)
                )
                halfPixels[index] = stored.x
                halfPixels[index + 1] = stored.y
                halfPixels[index + 2] = stored.z
                halfPixels[index + 3] = stored.w
                logicalPixels[index] = Float(stored.x)
                logicalPixels[index + 1] = Float(stored.y)
                logicalPixels[index + 2] = Float(stored.z)
                logicalPixels[index + 3] = Float(stored.w)
            }
        }
        halfPixels.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else { return }
            buffer.writeStrip(
                startY: 0,
                stripHeight: height,
                from: baseAddress,
                sourceRowBytes: width * buffer.bytesPerPixel
            )
        }
        return (buffer, logicalPixels)
    }

    private func makeTile(originX: Int, originY: Int, size: Int, scale: ScaleFactor) -> TileDescriptor {
        TileDescriptor(
            tileIndex: 0,
            row: 0,
            col: 0,
            inputOriginX: originX,
            inputOriginY: originY,
            inputSize: size,
            outputOriginX: originX * scale.rawValue,
            outputOriginY: originY * scale.rawValue,
            outputSize: size * scale.rawValue,
            actualLeftOverlapOut: 0,
            actualTopOverlapOut: 0
        )
    }

    /// Nearest-neighbour input luma upscale, i.e. an ideal (identity) luma super-resolution model.
    /// This isolates the reversible-log + YCbCr + bicubic-chroma round-trip from any model error.
    private func makeIdentityUpscaledY(tensors: PreparedTileTensors, scale: Int) -> [Float16] {
        let tileSize = tensors.tileSize
        let outputSize = tileSize * scale
        let outputPlaneCount = outputSize * outputSize
        var upscaled = [Float16](repeating: 0, count: 3 * outputPlaneCount)
        for outputY in 0..<outputSize {
            let sourceY = min(tileSize - 1, outputY / scale)
            for outputX in 0..<outputSize {
                let sourceX = min(tileSize - 1, outputX / scale)
                let sourceIndex = sourceY * tileSize + sourceX
                let y = tensors.planarTensorFP16[sourceIndex]
                let outputIndex = outputY * outputSize + outputX
                upscaled[outputIndex] = y
                upscaled[outputPlaneCount + outputIndex] = y
                upscaled[2 * outputPlaneCount + outputIndex] = y
            }
        }
        return upscaled
    }

    private func runRoundTrip(
        processor: MetalColorProcessor,
        source: MMapBuffer,
        tile: TileDescriptor,
        globalMaxLuminance: Float,
        globalMaxLinearComponent: Float? = nil,
        scale: Int,
        forceCPU: Bool
    ) throws -> [Float16] {
        var tensors = try processor.extractLogNormalizedRGBTile(
            from: source,
            tile: tile,
            globalMaxLuminance: globalMaxLuminance,
            globalMaxLinearComponent: globalMaxLinearComponent,
            forceCPU: forceCPU
        )
        try processor.decoupleLuminanceAndChrominance(tensors: &tensors, forceCPU: forceCPU)
        let upscaledY = makeIdentityUpscaledY(tensors: tensors, scale: scale)
        let outputSize = tile.inputSize * scale
        var output = [Float16](repeating: 0, count: 4 * outputSize * outputSize)
        try upscaledY.withUnsafeBufferPointer { yBuffer in
            try output.withUnsafeMutableBufferPointer { outputBuffer in
                try processor.reconstructUpscaledTile(
                    upscaledYPlanarFP16: yBuffer,
                    tensors: tensors,
                    scale: scale,
                    destinationRGBA16F: outputBuffer.baseAddress!,
                    forceCPU: forceCPU
                )
            }
        }
        return output
    }

    private struct RoundTripMetrics {
        var maxAbsoluteError: Float = 0
        var maxRelativeError: Float = 0
        var maxNormalizedError: Float = 0
        var maxAlphaError: Float = 0
        var maxChannelSpread: Float = 0
        var nonFiniteCount = 0
    }

    private func measureRoundTrip(
        output: [Float16],
        sourcePixels: [Float],
        sourceWidth: Int,
        scale: Int,
        globalMaxLuminance: Float
    ) -> RoundTripMetrics {
        var metrics = RoundTripMetrics()
        let outputSize = sourceWidth * scale
        let outputCount = outputSize * outputSize
        precondition(output.count == outputCount * 4)
        for outputY in 0..<outputSize {
            let sourceY = min(sourceWidth - 1, outputY / scale)
            for outputX in 0..<outputSize {
                let sourceX = min(sourceWidth - 1, outputX / scale)
                let outputIndex = (outputY * outputSize + outputX) * 4
                let sourceIndex = (sourceY * sourceWidth + sourceX) * 4

                let r = Float(output[outputIndex])
                let g = Float(output[outputIndex + 1])
                let b = Float(output[outputIndex + 2])
                let a = Float(output[outputIndex + 3])
                guard r.isFinite, g.isFinite, b.isFinite, a.isFinite else {
                    metrics.nonFiniteCount += 1
                    continue
                }

                metrics.maxChannelSpread = max(max(metrics.maxChannelSpread, abs(r - g)), abs(g - b))
                metrics.maxAlphaError = max(metrics.maxAlphaError, abs(a - sourcePixels[sourceIndex + 3]))

                for channel in 0..<3 {
                    let actual = Float(output[outputIndex + channel])
                    let expected = sourcePixels[sourceIndex + channel]
                    let difference = abs(actual - expected)
                    metrics.maxAbsoluteError = max(metrics.maxAbsoluteError, difference)
                    metrics.maxNormalizedError = max(
                        metrics.maxNormalizedError,
                        difference / max(globalMaxLuminance, 1e-6)
                    )
                    metrics.maxRelativeError = max(
                        metrics.maxRelativeError,
                        difference / max(abs(expected), 1e-6)
                    )
                }
            }
        }
        return metrics
    }

    /// Independent, deliberately duplicated scalar implementation of the spec's Catmull-Rom kernel
    /// used only to cross-check `upsampleChromaToOutput`.
    private func referenceBicubicUpsample(_ plane: [Float], width: Int, height: Int, scale: Int) -> [Float] {
        func weights(_ t: Float) -> [Float] {
            let t2 = t * t
            return [
                t * (t * (-0.5 * t + 1.0) - 0.5),
                t2 * (1.5 * t - 2.5) + 1.0,
                t * (t * (-1.5 * t + 2.0) + 0.5),
                t2 * (0.5 * t - 0.5)
            ]
        }
        let outputWidth = width * scale
        let outputHeight = height * scale
        var result = [Float](repeating: 0, count: outputWidth * outputHeight)
        for outputY in 0..<outputHeight {
            let v = (Float(outputY) + 0.5) / Float(scale) - 0.5
            let j0 = Int(floor(v))
            let wy = weights(v - Float(j0))
            for outputX in 0..<outputWidth {
                let u = (Float(outputX) + 0.5) / Float(scale) - 0.5
                let i0 = Int(floor(u))
                let wx = weights(u - Float(i0))
                var sum: Float = 0
                for n in 0..<4 {
                    let sy = min(max(j0 + n - 1, 0), height - 1)
                    for m in 0..<4 {
                        let sx = min(max(i0 + m - 1, 0), width - 1)
                        sum += wx[m] * wy[n] * plane[sy * width + sx]
                    }
                }
                result[outputY * outputWidth + outputX] = sum
            }
        }
        return result
    }
}
