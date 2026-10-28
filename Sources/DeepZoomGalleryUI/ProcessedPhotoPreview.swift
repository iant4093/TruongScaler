import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import TiledInferenceEngine
import TruongScalerCore

/// Small SDR browsing cache, never used for comparison, export or inference. Sample the real mmap
/// into at most 384² pixels off MainActor instead of asking ImageIO to decode a huge Linear DNG.
struct ProcessedPhotoPreview: Sendable {
    private let io = BlockingIOOwner(label: "com.truongscaler.processed-preview")
    func write(artifacts: CompletedPipelineArtifacts, to url: URL) async throws {
        try await io.run {
            let source = artifacts.outputBuffer
            let ratio = min(1, 384.0 / Double(max(source.width, source.height)))
            let width = max(1, Int(Double(source.width) * ratio)), height = max(1, Int(Double(source.height) * ratio))
            var pixels = [Float16](repeating: 0, count: width * height * 4)
            // Four distributed samples per cell suppress aliasing with bounded reads and scratch.
            for y in 0..<height {
                for x in 0..<width {
                    var sum = SIMD4<Float>(repeating: 0)
                    for dy in [0.25, 0.75] {
                        let sy = min(source.height - 1, Int((Double(y) + dy) / Double(height) * Double(source.height)))
                        let row = source.unsafeRowPointer(y: sy).bindMemory(to: Float16.self, capacity: source.width * 4)
                        for dx in [0.25, 0.75] {
                            let sx = min(source.width - 1, Int((Double(x) + dx) / Double(width) * Double(source.width)))
                            for c in 0..<4 { sum[c] += Float(row[sx * 4 + c]) * 0.25 }
                        }
                    }
                    for c in 0..<4 { pixels[(y * width + x) * 4 + c] = Float16(sum[c]) }
                }
            }
            let data = pixels.withUnsafeBytes { Data($0) }
            guard let color = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
                  let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                    bytesPerRow: width * 8, space: color,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue | CGBitmapInfo.floatComponents.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { throw CocoaError(.fileWriteUnknown) }
            context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let thumbnail = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
            else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}
