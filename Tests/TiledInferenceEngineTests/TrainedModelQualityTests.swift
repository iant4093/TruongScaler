import XCTest
import Foundation
import CoreGraphics
import CoreML
@testable import TiledInferenceEngine
@testable import TruongScalerCore
@testable import MMapCanvas
@testable import CoreIngestion
@testable import CoreExport
@testable import MetalColorEngine

/// Local real-photo, multi-tile, HDR/alpha quality coverage using the real trained
/// production models. The CC0 photographic fixtures and their provenance live in
/// `Tests/TiledInferenceEngineTests/Fixtures/quality/`; full outputs and comparison crops are
/// written under `build/test-results/quality/`.
final class TrainedModelQualityTests: XCTestCase {
    private struct Metrics: Codable {
        let mse: Double
        let mae: Double
        let maxAbs: Double
        let psnrDB: Double
        let channelBias: [Double]
        let sampleCount: Int
    }

    private struct AlphaMetrics: Codable {
        let mae: Double
        let maxAbs: Double
        let referenceRange: [Double]
        let outputRange: [Double]
    }

    private struct HaloMetrics: Codable {
        let edgeSampleCount: Int
        let meanOvershoot: Double
        let maxOvershoot: Double
    }

    private struct SeamMetrics: Codable {
        let horizontalRatio: Double
        let verticalRatio: Double
        let horizontalBoundaryMAE: Double
        let verticalBoundaryMAE: Double
        let interiorColumnMAE: Double
        let interiorRowMAE: Double
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TruongScalerQuality-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static var modelsDirectory: URL {
        repositoryRoot.appendingPathComponent("Targets/TruongScalerApp/Models", isDirectory: true)
    }

    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/quality", isDirectory: true)
    }

    private static var evidenceDirectory: URL {
        // Generated quality results stay in the ignored build tree; CI may choose a separate run directory.
        if let override = ProcessInfo.processInfo.environment["TRUONGSCALER_QUALITY_EVIDENCE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return repositoryRoot.appendingPathComponent(
            "build/test-results/quality",
            isDirectory: true
        )
    }

    private func fixture(_ name: String) -> URL {
        Self.fixturesDirectory.appendingPathComponent(name)
    }

    private func prepareEvidenceDirectory() throws -> URL {
        let directory = Self.evidenceDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["source", "outputs", "reingest", "metrics"] {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return directory
    }

    private func makeExecutor(computeUnits: MLComputeUnits = .cpuAndGPU) -> TiledPipelineExecutor {
        let registry = CoreMLModelRegistry(
            initialComputeUnits: computeUnits,
            customSearchDirectories: [Self.modelsDirectory],
            availabilityPolicy: .requireProductionModels
        )
        let store = JobCheckpointStore(directory: directory)
        return TiledPipelineExecutor(
            workingDirectory: directory,
            modelRegistry: registry,
            checkpointStore: store
        )
    }

    private func run(
        source: URL,
        backbone: BackboneModelKind,
        scale: ScaleFactor,
        denoise: DenoiseMode,
        tier: DeviceTier
    ) async throws -> CompletedPipelineArtifacts {
        let executor = makeExecutor()
        let config = UpscaleJobConfig(
            sourceImageURL: source,
            scaleFactor: scale,
            backbone: backbone,
            denoiseMode: denoise,
            naturalGrainAmount: 0.0,
            exportFormat: .tiff16BitLZW
        )
        return try await executor.executeOrResumeJob(config: config, overrideTier: tier)
    }

    private func save(
        _ artifacts: CompletedPipelineArtifacts,
        label: String,
        format: ExportFormat = .tiff16BitLZW
    ) throws -> URL {
        let evidence = try prepareEvidenceDirectory()
        let ext = format == .png16Bit ? "png" : "tiff"
        let output = evidence.appendingPathComponent("outputs/\(label)-output.\(ext)")
        _ = try FormatAwareExporter.exportImageDetailed(
            artifacts: artifacts,
            destinationURL: output,
            overrideFormat: format
        )
        let sourceCopy = evidence.appendingPathComponent("source/\(artifacts.checkpoint.config.sourceImageURL.lastPathComponent)")
        if !FileManager.default.fileExists(atPath: sourceCopy.path) {
            try? FileManager.default.copyItem(at: artifacts.checkpoint.config.sourceImageURL, to: sourceCopy)
        }
        return output
    }

    private func decode(_ url: URL, label: String, saveEvidence: Bool = false) throws -> DecodedSourceResult {
        let destination = directory.appendingPathComponent("\(label)-reingest.rgba16f.bin")
        let result = try UniversalStripDecoder.decodeToMMap(
            imageURL: url,
            destinationMMapURL: destination,
            stripHeight: 64
        )
        if saveEvidence {
            let evidence = try prepareEvidenceDirectory()
            let target = evidence.appendingPathComponent("reingest/\(label)-reingest.rgba16f.bin")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: destination, to: target)
        }
        return result
    }

    // MARK: - Metrics

    private func compareRGB(_ output: MMapBuffer, _ reference: MMapBuffer, border: Int = 16) -> Metrics {
        XCTAssertEqual(output.width, reference.width)
        XCTAssertEqual(output.height, reference.height)
        var mse = 0.0
        var mae = 0.0
        var maxAbs = 0.0
        var bias = [0.0, 0.0, 0.0]
        var count = 0
        for y in border..<(output.height - border) {
            for x in border..<(output.width - border) {
                let a = output.unsafePixelPointer(x: x, y: y)
                let b = reference.unsafePixelPointer(x: x, y: y)
                for channel in 0..<3 {
                    let d = Double(a[channel]) - Double(b[channel])
                    mse += d * d
                    mae += abs(d)
                    maxAbs = max(maxAbs, abs(d))
                    bias[channel] += d
                    count += 1
                }
            }
        }
        let norm = Double(max(1, count))
        mse /= norm
        mae /= norm
        bias = bias.map { $0 / norm }
        return Metrics(
            mse: mse,
            mae: mae,
            maxAbs: maxAbs,
            psnrDB: mse > 0 ? 10.0 * log10(1.0 / mse) : 999.0,
            channelBias: bias,
            sampleCount: count
        )
    }

    private func compareAlpha(_ output: MMapBuffer, _ reference: MMapBuffer, border: Int = 16) -> AlphaMetrics {
        var mae = 0.0
        var maxAbs = 0.0
        var outputMin = Float.greatestFiniteMagnitude
        var outputMax = -Float.greatestFiniteMagnitude
        var referenceMin = Float.greatestFiniteMagnitude
        var referenceMax = -Float.greatestFiniteMagnitude
        var count = 0
        for y in border..<(output.height - border) {
            for x in border..<(output.width - border) {
                let a = Float(output.unsafePixelPointer(x: x, y: y)[3])
                let b = Float(reference.unsafePixelPointer(x: x, y: y)[3])
                mae += Double(abs(a - b))
                maxAbs = max(maxAbs, Double(abs(a - b)))
                outputMin = min(outputMin, a); outputMax = max(outputMax, a)
                referenceMin = min(referenceMin, b); referenceMax = max(referenceMax, b)
                count += 1
            }
        }
        let norm = Double(max(1, count))
        return AlphaMetrics(
            mae: mae / norm,
            maxAbs: maxAbs,
            referenceRange: [Double(referenceMin), Double(referenceMax)],
            outputRange: [Double(outputMin), Double(outputMax)]
        )
    }

    private func haloMetrics(_ output: MMapBuffer, _ reference: MMapBuffer, step: Int = 2) -> HaloMetrics {
        @inline(__always) func luma(_ pointer: UnsafeMutablePointer<Float16>) -> Double {
            0.2126 * Double(pointer[0]) + 0.7152 * Double(pointer[1]) + 0.0722 * Double(pointer[2])
        }
        var total = 0.0
        var maximum = 0.0
        var count = 0
        var y = 2
        while y < output.height - 2 {
            var x = 2
            while x < output.width - 2 {
                let r0 = reference.unsafePixelPointer(x: x, y: y)
                let o0 = output.unsafePixelPointer(x: x, y: y)
                var referenceMin = Double.greatestFiniteMagnitude
                var referenceMax = -Double.greatestFiniteMagnitude
                var localGradient = 0.0
                for dy in -2...2 {
                    for dx in -2...2 where dx != 0 || dy != 0 {
                        let r = reference.unsafePixelPointer(x: x + dx, y: y + dy)
                        let value = luma(r)
                        referenceMin = min(referenceMin, value)
                        referenceMax = max(referenceMax, value)
                        localGradient = max(localGradient, abs(value - luma(r0)))
                    }
                }
                if localGradient > 0.15 {
                    let value = luma(o0)
                    let overshoot = max(0.0, max(value - referenceMax, referenceMin - value))
                    total += overshoot
                    maximum = max(maximum, overshoot)
                    count += 1
                }
                x += step
            }
            y += step
        }
        return HaloMetrics(
            edgeSampleCount: count,
            meanOvershoot: total / Double(max(1, count)),
            maxOvershoot: maximum
        )
    }

    private func detailEnergy(_ buffer: MMapBuffer, step: Int = 2) -> Double {
        var accumulator = 0.0
        var count = 0
        var y = 1
        while y < buffer.height - 1 {
            var x = 1
            while x < buffer.width - 1 {
                let center = buffer.unsafePixelPointer(x: x, y: y)
                let left = buffer.unsafePixelPointer(x: x - 1, y: y)
                let right = buffer.unsafePixelPointer(x: x + 1, y: y)
                let up = buffer.unsafePixelPointer(x: x, y: y - 1)
                let down = buffer.unsafePixelPointer(x: x, y: y + 1)
                let luma: (UnsafeMutablePointer<Float16>) -> Double = {
                    0.2126 * Double($0[0]) + 0.7152 * Double($0[1]) + 0.0722 * Double($0[2])
                }
                accumulator += abs(4 * luma(center) - luma(left) - luma(right) - luma(up) - luma(down))
                count += 1
                x += step
            }
            y += step
        }
        return accumulator / Double(max(1, count))
    }

    private func seamMetrics(
        _ output: MMapBuffer,
        plan: TileGridPlan,
        scale: Int
    ) -> SeamMetrics {
        let boundaryColumns = plan.tiles.filter { $0.col > 0 }.map { $0.outputOriginX }.uniqueSorted()
        let boundaryRows = plan.tiles.filter { $0.row > 0 }.map { $0.outputOriginY }.uniqueSorted()
        var boundaryColumnValues: [Double] = []
        var interiorColumnValues: [Double] = []
        for x in 1..<output.width where x % 8 == 0 {
            var sum = 0.0
            var count = 0
            for y in stride(from: 8, to: output.height - 8, by: 8) {
                let left = output.unsafePixelPointer(x: x - 1, y: y)
                let right = output.unsafePixelPointer(x: x, y: y)
                for c in 0..<3 { sum += Double(abs(Float(left[c]) - Float(right[c]))) }
                count += 3
            }
            let value = sum / Double(max(1, count))
            if boundaryColumns.contains(where: { abs($0 - x) <= 1 }) {
                boundaryColumnValues.append(value)
            } else {
                interiorColumnValues.append(value)
            }
        }
        var boundaryRowValues: [Double] = []
        var interiorRowValues: [Double] = []
        for y in 1..<output.height where y % 8 == 0 {
            var sum = 0.0
            var count = 0
            for x in stride(from: 8, to: output.width - 8, by: 8) {
                let up = output.unsafePixelPointer(x: x, y: y - 1)
                let down = output.unsafePixelPointer(x: x, y: y)
                for c in 0..<3 { sum += Double(abs(Float(up[c]) - Float(down[c]))) }
                count += 3
            }
            let value = sum / Double(max(1, count))
            if boundaryRows.contains(where: { abs($0 - y) <= 1 }) {
                boundaryRowValues.append(value)
            } else {
                interiorRowValues.append(value)
            }
        }
        func median(_ values: [Double]) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        let horizontalBoundary = median(boundaryColumnValues)
        let verticalBoundary = median(boundaryRowValues)
        let interiorColumn = median(interiorColumnValues)
        let interiorRow = median(interiorRowValues)
        return SeamMetrics(
            horizontalRatio: horizontalBoundary / max(interiorColumn, 1e-8),
            verticalRatio: verticalBoundary / max(interiorRow, 1e-8),
            horizontalBoundaryMAE: horizontalBoundary,
            verticalBoundaryMAE: verticalBoundary,
            interiorColumnMAE: interiorColumn,
            interiorRowMAE: interiorRow
        )
    }

    private func writeMetrics(_ value: some Encodable, label: String) throws {
        let evidence = try prepareEvidenceDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(
            to: evidence.appendingPathComponent("metrics/\(label).json"),
            options: .atomic
        )
    }

    private func jsonDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScalerError.modelInferenceFailed(modelName: "quality-metrics", tileIndex: 0, reason: "Metrics did not encode as a JSON object")
        }
        return object
    }

    private func writeAny(_ value: [String: Any], label: String) throws {
        let evidence = try prepareEvidenceDirectory()
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: evidence.appendingPathComponent("metrics/\(label).json"), options: .atomic)
    }

    // MARK: - Native 2× required-model production quality

    func testNativeTwoTimesRealPhotoQualityAtBothTileSizes() async throws {
        for backbone in BackboneModelKind.allCases {
            let reference = try decode(fixture("photo_flower_hr_1024x768.png"), label: "flower-reference").sourceBuffer
            for tier in [DeviceTier.tierA_HighMemory, .tierB_ConstrainedMemory] {
                let label = backbone.rawValue + "-flower-" + tier.rawValue
                let artifacts = try await run(source: fixture("photo_flower_lr_512x384.png"), backbone: backbone,
                    scale: .x2, denoise: .off, tier: tier)
                let plan = TileGridPlanner.makePlan(sourceWidth: 512, sourceHeight: 384, scaleFactor: .x2,
                    tileConfig: artifacts.checkpoint.tileConfig)
                XCTAssertGreaterThan(plan.totalTiles, 1)
                XCTAssertEqual(artifacts.outputBuffer.width, 1024)
                XCTAssertEqual(artifacts.outputBuffer.height, 768)
                XCTAssertFalse(artifacts.checkpoint.didRunDenoise)
                let url = try save(artifacts, label: label)
                let reingested = try decode(url, label: label)
                let metrics = compareRGB(reingested.sourceBuffer, reference)
                let seams = seamMetrics(reingested.sourceBuffer, plan: plan, scale: 2)
                let halos = haloMetrics(reingested.sourceBuffer, reference)
                try writeMetrics(metrics, label: label + "-rgb")
                try writeMetrics(seams, label: label + "-seams")
                try writeMetrics(halos, label: label + "-halos")
                print("[quality] \(label) PSNR=\(metrics.psnrDB) MAE=\(metrics.mae) seams=\(seams.horizontalRatio)/\(seams.verticalRatio)")
                XCTAssertGreaterThan(metrics.psnrDB, 25)
                XCTAssertLessThan(metrics.mae, 0.05)
                XCTAssertLessThan(metrics.channelBias.map(abs).reduce(0,+), 0.03)
                XCTAssertLessThan(seams.horizontalRatio, 8)
                XCTAssertLessThan(seams.verticalRatio, 8)
                XCTAssertLessThan(halos.meanOvershoot, 0.05)
            }
        }
    }

    func testLandscapeNativeTwoTimesQualityAndColor() async throws {
        for backbone in BackboneModelKind.allCases {
            let reference = try decode(fixture("photo_landscape_hr_1024x768.png"), label: "landscape-reference").sourceBuffer
            let artifacts = try await run(source: fixture("photo_landscape_lr_512x384.png"), backbone: backbone,
                scale: .x2, denoise: .off, tier: .tierB_ConstrainedMemory)
            let output = try decode(try save(artifacts, label: backbone.rawValue + "-landscape"), label: "landscape")
            let metrics = compareRGB(output.sourceBuffer, reference)
            try writeMetrics(metrics, label: backbone.rawValue + "-landscape-rgb")
            XCTAssertGreaterThan(metrics.psnrDB, 25)
            XCTAssertLessThan(metrics.mae, 0.05)
            XCTAssertLessThan(metrics.channelBias.map(abs).reduce(0,+), 0.03)
        }
    }

    func testHDRAndAlphaThroughRequiredNativeTwoTimesModel() async throws {
        for backbone in BackboneModelKind.allCases {
            let hdr = try await run(source: fixture("photo_flower_hdr_512x384.tiff"), backbone: backbone,
                scale: .x2, denoise: .off, tier: .tierB_ConstrainedMemory)
            let destination = try prepareEvidenceDirectory().appendingPathComponent("outputs/\(backbone.rawValue)-hdr.tiff")
            let result = try FormatAwareExporter.exportImageDetailed(artifacts: hdr, destinationURL: destination,
                overrideFormat: .tiff16BitLZW)
            let reingested = try decode(destination, label: "hdr")
            XCTAssertTrue(result.isHDR)
            XCTAssertGreaterThanOrEqual(result.finalLinearPeak, 3.5)
            XCTAssertGreaterThanOrEqual(reingested.globalMaxLinearComponent, 3.5)
            XCTAssertEqual(reingested.decodedWidth, 1024)
            XCTAssertEqual(reingested.decodedHeight, 768)
            let source = fixture("photo_flower_alpha_lr_512x384.png")
            let alpha = try await run(source: source, backbone: backbone, scale: .x2, denoise: .off, tier: .tierB_ConstrainedMemory)
            let alphaOutput = try decode(try save(alpha, label: backbone.rawValue + "-alpha"), label: "alpha")
            let reference = try decode(fixture("photo_flower_alpha_hr_1024x768.png"), label: "alpha-reference")
            let metrics = compareAlpha(alphaOutput.sourceBuffer, reference.sourceBuffer)
            try writeMetrics(metrics, label: backbone.rawValue + "-alpha")
            XCTAssertGreaterThan(metrics.outputRange[1] - metrics.outputRange[0], 0.5)
            XCTAssertLessThan(metrics.mae, 0.20)
        }
    }

    func testSavedModelWinsOverCurrentSelectionOnRealResume() async throws {
        for backbone in [BackboneModelKind.edsrBaseline, .hatSmall] {
            let source = fixture("photo_flower_lr_512x384.png")
            let artifacts = try await run(source: source, backbone: backbone, scale: .x2,
                denoise: .off, tier: .tierB_ConstrainedMemory)
            let bytes = try Data(contentsOf: artifacts.outputBuffer.fileURL)
            let newSelection = UpscaleJobConfig(sourceImageURL: source, scaleFactor: .x2,
                backbone: .quickSRNet, denoiseMode: .off)
            let resumed = try await makeExecutor().executeOrResumeJob(config: newSelection,
                existingCheckpoint: artifacts.checkpoint)
            XCTAssertEqual(resumed.checkpoint.config.backbone, backbone)
            XCTAssertEqual(resumed.checkpoint.jobID, artifacts.checkpoint.jobID)
            XCTAssertEqual(resumed.checkpoint.tileConfig, artifacts.checkpoint.tileConfig)
            if backbone == .hatSmall { XCTAssertEqual(resumed.checkpoint.tileConfig.inputOverlap, 32) }
            XCTAssertEqual(try Data(contentsOf: resumed.outputBuffer.fileURL), bytes)
        }
    }

    func testAdditionalModelsRejectAdversarialPhotoBeforeCommittingAnyTile() async throws {
        for backbone in [BackboneModelKind.edsrBaseline, .hatSmall] {
            let recorder = BenchmarkRecorder()
            let executor = makeExecutor()
            let config = UpscaleJobConfig(sourceImageURL: fixture("adversarial_1px_checker_512x384.png"),
                scaleFactor: .x2, backbone: backbone, denoiseMode: .off, naturalGrainAmount: 0)
            do {
                _ = try await executor.executeOrResumeJob(config: config, overrideTier: .tierB_ConstrainedMemory,
                    progressHandler: { recorder.record($0) })
                XCTFail("An unsafe trained prediction must be refused")
            } catch let error as ScalerError {
                guard case .modelInferenceFailed(_, _, let reason) = error else {
                    return XCTFail("Expected prediction failure, got \(error)")
                }
                XCTAssertTrue(reason.contains("out-of-range"), reason)
            }
            XCTAssertEqual(recorder.updates.map(\.completedTiles).max(), 0)
            let store = JobCheckpointStore(directory: directory)
            let checkpoint = try await store.load(jobID: config.id)
            XCTAssertEqual(checkpoint.lastCompletedTileIndex, -1)
            XCTAssertEqual(checkpoint.config.backbone, backbone)
            let jobJournalPrefix = "journal_\(config.id.uuidString)_"
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .contains { $0.hasPrefix(jobJournalPrefix) }, "Unsafe predictions must not begin a durable tile transaction")
        }
    }

    func testRequiredModelProductionPipelineBenchmark() async throws {
        for backbone in BackboneModelKind.allCases {
            let recorder = BenchmarkRecorder()
            let executor = makeExecutor(computeUnits: .all)
            let config = UpscaleJobConfig(sourceImageURL: fixture("photo_flower_lr_512x384.png"), scaleFactor: .x2,
                backbone: backbone, denoiseMode: .off, naturalGrainAmount: 0, exportFormat: .tiff16BitLZW)
            let start = ContinuousClock.now
            let artifacts = try await executor.executeOrResumeJob(config: config, overrideTier: .tierA_HighMemory,
                progressHandler: { recorder.record($0) })
            let elapsed = start.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let updates = recorder.updates
            let timed = updates.compactMap(\.timings)
            XCTAssertFalse(timed.isEmpty)
            XCTAssertEqual(artifacts.checkpoint.lastCompletedTileIndex + 1, artifacts.checkpoint.totalTiles)
            let data: [String: Any] = ["platform": ProcessInfo.processInfo.operatingSystemVersionString + "; local Mac/simulator; physical-phone performance NOT_RUN", "model": backbone.rawValue,
                "sourceWidth":512,"sourceHeight":384,"scale":2,"totalTiles":artifacts.checkpoint.totalTiles,
                "wholePipelineSeconds":seconds,"tileTimings":try timed.map { try jsonDictionary($0) }]
            try writeAny(data, label: backbone.rawValue + "-production-benchmark")
            print("MODEL_PRODUCTION_BENCHMARK model=\(backbone.rawValue) seconds=\(seconds)")
        }
    }
}

private final class BenchmarkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PipelineProgressUpdate] = []
    func record(_ update: PipelineProgressUpdate) { lock.lock(); storage.append(update); lock.unlock() }
    var updates: [PipelineProgressUpdate] { lock.lock(); defer { lock.unlock() }; return storage }
}

private extension Array where Element: Hashable {
    func uniqueSorted() -> [Element] {
        Array(Set(self)).sorted { "\($0)" < "\($1)" }
    }
}

private extension Array where Element == Int {
    func uniqueSorted() -> [Int] { Array(Set(self)).sorted() }
}
