import XCTest
import Foundation
import MMapCanvas
@testable import MetalColorEngine

/// Lead-owned compatibility regression for the independent review's direct color probe:
/// the production `extractLogNormalizedRGBTile` call is made with only luminance telemetry and no
/// component argument. The processor must derive the bound from the immutable source canvas so a
/// saturated HDR red is not clipped by the old luminance-only assumption.
final class LinearColorContractTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ReviewProbeCompatibility-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testReviewDirectProbeSaturatedRedWithLuminanceOnlyCall() throws {
        let size = 2
        let fileURL = temporaryDirectory.appendingPathComponent("red4.bin")
        let source = try MMapBuffer(fileURL: fileURL, width: size, height: size, createIfMissing: true)
        for y in 0..<size {
            for x in 0..<size {
                let pixel = source.unsafePixelPointer(x: x, y: y)
                pixel[0] = 4.0
                pixel[1] = 0
                pixel[2] = 0
                pixel[3] = 1.0
            }
        }
        let tile = TileDescriptor(
            tileIndex: 0,
            row: 0,
            col: 0,
            inputOriginX: 0,
            inputOriginY: 0,
            inputSize: size,
            outputOriginX: 0,
            outputOriginY: 0,
            outputSize: size,
            actualLeftOverlapOut: 0,
            actualTopOverlapOut: 0
        )
        let processor = MetalColorProcessor(preferMetal: false)
        var tensors = try processor.extractLogNormalizedRGBTile(
            from: source,
            tile: tile,
            globalMaxLuminance: 1.0,
            alphaConstant: 16,
            forceCPU: true
        )
        // The review probe measures luminance 0.916 and floors it to 1.0; the derived component
        // peak must be 4.0 instead.
        try processor.decoupleLuminanceAndChrominance(tensors: &tensors, forceCPU: true)
        var output = [Float16](repeating: 0, count: size * size * 4)
        try output.withUnsafeMutableBufferPointer { destination in
            try tensors.planarTensorFP16.withUnsafeBufferPointer { yPlane in
                try processor.reconstructUpscaledTile(
                    upscaledYPlanarFP16: yPlane,
                    tensors: tensors,
                    scale: 1,
                    destinationRGBA16F: destination.baseAddress!,
                    forceCPU: true
                )
            }
        }
        XCTAssertEqual(Float(output[0]), 4.0, accuracy: 0.02)
        XCTAssertEqual(Float(output[1]), 0.0, accuracy: 0.005)
        XCTAssertEqual(Float(output[2]), 0.0, accuracy: 0.005)
    }
}
