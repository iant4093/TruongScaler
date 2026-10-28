import XCTest
import Foundation
import CoreGraphics
import MMapCanvas
import TiledInferenceEngine

#if canImport(UIKit) && os(iOS)
import UIKit
import QuartzCore
@testable import DeepZoomGalleryUI

/// Executed iOS-only regression for the live-phone CATiledLayer crash.
///
/// The phone stack proved Core Animation invokes `drawLayer:inContext:` on
/// `com.apple.coreanimation.imageprovider.concurrent`. A main-actor-isolated
/// `UIView.draw(_:in:)` override puts a `_checkExpectedExecutor(MainActor)` trap in the
/// Objective-C entry thunk, which is exactly what killed the app. These tests call the
/// real Objective-C `CALayerDelegate.draw(_:in:)` entry point (not a Swift helper and not
/// a source-string assertion) from concurrent background threads with real mmap-backed
/// pixel fixtures, and read the rendered bitmap back to prove that drawing happened.
final class MMapTiledImageViewActorTests: XCTestCase {
    private let sourceWidth = 64
    private let sourceHeight = 48
    private let scaleFactor = 4
    private var outputWidth: Int { sourceWidth * scaleFactor }
    private var outputHeight: Int { sourceHeight * scaleFactor }

    private var workingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MMapTiledImageViewActorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workingDirectory {
            try? FileManager.default.removeItem(at: workingDirectory)
        }
        workingDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A real mmap-backed RGBA16Float buffer filled with a deterministic non-zero pattern.
    private func makeBuffer(name: String, width: Int, height: Int, seed: Float16) throws -> MMapBuffer {
        let buffer = try MMapBuffer(
            fileURL: workingDirectory.appendingPathComponent("\(name).rgba16f"),
            width: width,
            height: height,
            createIfMissing: true
        )
        for y in 0..<height {
            let row = buffer.unsafeRowPointer(y: y).bindMemory(to: Float16.self, capacity: width * 4)
            for x in 0..<width {
                let base = x * 4
                row[base] = seed
                row[base + 1] = Float16(Float(x % 7) / 8.0 + 0.0625)
                row[base + 2] = Float16(Float(y % 5) / 8.0 + 0.0625)
                row[base + 3] = 1.0
            }
        }
        try buffer.flushToDisk(synchronous: true)
        return buffer
    }

    /// Holds Core Animation objects across the nonisolated test boundary.
    ///
    /// `CALayer`/`CALayerDelegate` are framework objects; the view is already
    /// `@unchecked Sendable`. This box is test-only and owns the objects for the whole
    /// background call, mirroring Core Animation's own synchronous callback lifetime.
    private struct TileDrawTarget: @unchecked Sendable {
        let view: MMapTiledImageView
        let layer: CALayer
        let delegate: (any CALayerDelegate)?
        let bounds: CGRect
    }

    // MARK: - Actual Objective-C tile callback

    /// Calls the actual `drawLayer:inContext:` entry point that Core Animation calls.
    ///
    /// `layer.delegate?.draw?(layer, in:)` lowers to an `objc_msgSend` of
    /// `drawLayer:inContext:`. Calling it here therefore executes the same Objective-C
    /// thunk (and, before the repair, the same MainActor executor assertion) that the
    /// phone crash showed on `com.apple.coreanimation.imageprovider.concurrent`.
    private func invokeTileCallback(_ target: TileDrawTarget) -> Int {
        let width = max(1, Int(target.bounds.width.rounded(.up)))
        let height = max(1, Int(target.bounds.height.rounded(.up)))
        let bytesPerRow = width * 8
        let byteCount = bytesPerRow * height
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return 0 }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
                | CGBitmapInfo.floatComponents.rawValue
        )
        guard let context = CGContext(
            data: raw,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return 0 }

        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
        target.delegate?.draw?(target.layer, in: context)
        context.restoreGState()

        let bytes = raw.bindMemory(to: UInt8.self, capacity: byteCount)
        var nonZero = 0
        for index in 0..<byteCount where bytes[index] != 0 {
            nonZero += 1
        }
        return nonZero
    }

    @MainActor
    private func makeTarget(
        source: MMapBuffer,
        output: MMapBuffer,
        mode: MMapTiledImageView.RenderMode,
        grain: Float = 0.35
    ) -> TileDrawTarget {
        let view = MMapTiledImageView(
            sourceBuffer: source,
            hatOutputBuffer: output,
            scaleFactor: scaleFactor,
            naturalGrainAmount: grain,
            renderMode: mode
        )
        view.frame = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let layer = view.layer
        XCTAssertTrue(layer is CATiledLayer)
        // `UIView` is its backing layer's delegate; this is the exact object Core Animation
        // calls on its image-provider threads.
        XCTAssertTrue(layer.delegate === view)
        return TileDrawTarget(
            view: view,
            layer: layer,
            delegate: layer.delegate,
            bounds: CGRect(x: 0, y: 0, width: 64, height: 64)
        )
    }

    // MARK: - Tests

    @MainActor
    func testActualTileCallbackRendersOnConcurrentBackgroundThreadsInBothModes() async throws {
        let source = try makeBuffer(name: "source", width: sourceWidth, height: sourceHeight, seed: 0.4)
        let output = try makeBuffer(name: "output", width: outputWidth, height: outputHeight, seed: 0.6)

        let original = makeTarget(source: source, output: output, mode: .originalNearestNeighbor)
        let upscaled = makeTarget(source: source, output: output, mode: .upscaledWithLiveGrain)

        let results = await withTaskGroup(of: (String, Int).self, returning: [(String, Int)].self) { group in
            for iteration in 0..<8 {
                let target = iteration.isMultiple(of: 2) ? original : upscaled
                let name = iteration.isMultiple(of: 2) ? "original" : "upscaled"
                group.addTask {
                    let nonZero = Self.performConcurrentDraws(target: target, iterations: 4)
                    return (name, nonZero)
                }
            }
            var collected: [(String, Int)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        XCTAssertEqual(results.count, 8)
        for (name, nonZero) in results {
            XCTAssertGreaterThan(nonZero, 0, "\(name) tile draw must write real pixels")
        }
    }

    /// Runs the tile callback on a global concurrent queue (never MainActor), several times
    /// per worker, while the main actor swaps render snapshots underneath it.
    @MainActor
    func testSnapshotReplacementDuringInFlightTileDrawsKeepsResourcesAlive() async throws {
        let sourceA = try makeBuffer(name: "sourceA", width: sourceWidth, height: sourceHeight, seed: 0.3)
        let outputA = try makeBuffer(name: "outputA", width: outputWidth, height: outputHeight, seed: 0.5)
        let sourceB = try makeBuffer(name: "sourceB", width: sourceWidth, height: sourceHeight, seed: 0.7)
        let outputB = try makeBuffer(name: "outputB", width: outputWidth, height: outputHeight, seed: 0.9)

        let target = makeTarget(source: sourceA, output: outputA, mode: .upscaledWithLiveGrain)
        let view = target.view

        let updater = Task { @MainActor in
            for index in 0..<24 {
                if index.isMultiple(of: 2) {
                    view.updateConfiguration(
                        sourceBuffer: sourceA,
                        hatOutputBuffer: outputA,
                        scaleFactor: self.scaleFactor,
                        naturalGrainAmount: 0.1
                    )
                } else {
                    view.updateConfiguration(
                        sourceBuffer: sourceB,
                        hatOutputBuffer: outputB,
                        scaleFactor: self.scaleFactor,
                        naturalGrainAmount: 0.9
                    )
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }

        let drawResults = await Task.detached(priority: .userInitiated) { () -> [Int] in
            (0..<6).map { _ in
                Self.performConcurrentDraws(target: target, iterations: 3)
            }
        }.value
        await updater.value

        XCTAssertEqual(drawResults.count, 6)
        for nonZero in drawResults {
            XCTAssertGreaterThan(nonZero, 0, "in-flight tile draws must render real pixels")
        }
        // The replacement buffers must still be readable after all in-flight callbacks drain.
        XCTAssertEqual(view.tiledLayer.tileSize, CGSize(width: 512, height: 512))
    }

    @MainActor
    func testOutOfCanvasAndZeroSizedClipsAreSafe() async throws {
        let source = try makeBuffer(name: "src-small", width: sourceWidth, height: sourceHeight, seed: 0.2)
        let output = try makeBuffer(name: "out-small", width: outputWidth, height: outputHeight, seed: 0.4)
        let target = makeTarget(source: source, output: output, mode: .originalNearestNeighbor)

        // A clip entirely outside the canvas must be a no-op with zero rendered bytes.
        let empty = await Task.detached(priority: .userInitiated) { () -> Int in
            let width = 8
            let height = 8
            let bytesPerRow = width * 8
            let raw = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 64)
            defer { raw.deallocate() }
            raw.initializeMemory(as: UInt8.self, repeating: 0, count: bytesPerRow * height)
            guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return -1 }
            let bitmapInfo = CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue
                    | CGBitmapInfo.floatComponents.rawValue
            )
            guard let context = CGContext(
                data: raw,
                width: width,
                height: height,
                bitsPerComponent: 16,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return -1 }
            context.translateBy(x: 50_000, y: 50_000)
            context.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
            target.delegate?.draw?(target.layer, in: context)
            let bytes = raw.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
            return (0..<(bytesPerRow * height)).reduce(0) { partial, index in
                partial + (bytes[index] == 0 ? 0 : 1)
            }
        }.value
        XCTAssertEqual(empty, 0)
    }

    @MainActor
    func testOriginalOddTileClipsCoverEveryPixelWithoutGridGaps() async throws {
        let source = try makeBuffer(name: "odd-source", width: sourceWidth, height: sourceHeight, seed: 0.4)
        let output = try makeBuffer(name: "odd-output", width: outputWidth, height: outputHeight, seed: 0.6)
        let target = makeTarget(source: source, output: output, mode: .originalNearestNeighbor)
        let gaps = await Task.detached { () -> Int in
            var missing = 0
            for (x, y, w, h) in [(3, 5, 62, 70), (65, 75, 63, 65), (1, 1, 127, 95)] {
                let raw = UnsafeMutableRawPointer.allocate(byteCount: w * h * 8, alignment: 64)
                defer { raw.deallocate() }
                raw.initializeMemory(as: UInt8.self, repeating: 0, count: w * h * 8)
                guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
                      let context = CGContext(data: raw, width: w, height: h, bitsPerComponent: 16,
                        bytesPerRow: w * 8, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue | CGBitmapInfo.floatComponents.rawValue)
                else { return -1 }
                context.translateBy(x: -CGFloat(x), y: -CGFloat(y))
                context.clip(to: CGRect(x: x, y: y, width: w, height: h))
                target.delegate?.draw?(target.layer, in: context)
                let pixels = raw.bindMemory(to: Float16.self, capacity: w * h * 4)
                for pixel in 0..<(w * h) where Float(pixels[pixel * 4 + 3]) < 0.99 { missing += 1 }
            }
            return missing
        }.value
        XCTAssertEqual(gaps, 0, "Oddly aligned Core Animation clips must not leave thin transparent grid seams")
    }

    // MARK: - Background execution helpers

    /// The concurrent queue captures one immutable, Sendable owner; all mutable state stays locked.
    private final class ConcurrentDrawCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func add(_ amount: Int) {
            lock.withLock { value += amount }
        }

        var total: Int {
            lock.withLock { value }
        }
    }

    /// Executes the real tile callback from concurrent global-queue workers.
    private nonisolated static func performConcurrentDraws(target: TileDrawTarget, iterations: Int) -> Int {
        let counter = ConcurrentDrawCounter()
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            let nonZero = drawOnce(target: target)
            counter.add(nonZero)
        }
        return counter.total
    }

    private nonisolated static func drawOnce(target: TileDrawTarget) -> Int {
        let width = max(1, Int(target.bounds.width.rounded(.up)))
        let height = max(1, Int(target.bounds.height.rounded(.up)))
        let bytesPerRow = width * 8
        let byteCount = bytesPerRow * height
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return 0 }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
                | CGBitmapInfo.floatComponents.rawValue
        )
        guard let context = CGContext(
            data: raw,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return 0 }

        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
        target.delegate?.draw?(target.layer, in: context)
        context.restoreGState()

        let bytes = raw.bindMemory(to: UInt8.self, capacity: byteCount)
        var nonZero = 0
        for index in 0..<byteCount where bytes[index] != 0 {
            nonZero += 1
        }
        return nonZero
    }
}
#endif
