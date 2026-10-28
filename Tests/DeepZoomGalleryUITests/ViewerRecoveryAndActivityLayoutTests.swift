#if canImport(UIKit)
import XCTest
import UIKit
import SwiftUI
import TruongScalerCore
import ScalerActivityUI
import TiledInferenceEngine
@testable import DeepZoomGalleryUI

@MainActor
final class ViewerRecoveryAndActivityLayoutTests: XCTestCase {
    private func brightPixels(_ image: CGImage) throws -> Int {
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: rgba.count, by: 4).filter { rgba[$0] > 120 && rgba[$0 + 1] > 120 }.count
    }

    private func render<V: View>(_ view: V, size: CGSize, name: String) throws -> CGImage {
        // An 80×36 UIWindow inherits phone safe-area insets larger than its own height and
        // produces an empty image. Lay out the real component in its constrained slot inside a
        // normal phone-sized host, then capture that slot. No production layout is overridden.
        let hostSize = CGSize(width: max(390, size.width), height: max(844, size.height))
        let root = view.preferredColorScheme(.dark)
            .frame(width: size.width, height: size.height)
            .frame(width: hostSize.width, height: hostSize.height)
            .background(.black)
        let host = UIHostingController(rootView: root)
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: hostSize))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        for _ in 0..<5 {
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
        let image = UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.translateBy(x: -(hostSize.width - size.width) / 2,
                                           y: -(hostSize.height - size.height) / 2)
            host.view.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = URL(fileURLWithPath: "/tmp/truongscaler-recovery-activity-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try image.pngData()?.write(to: directory.appendingPathComponent(name + ".png"))
        window.isHidden = true
        return try XCTUnwrap(image.cgImage)
    }

    func testEmptyLoadingAndFailedViewerAlwaysRendersRecoveryControls() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = StudioViewModel(workingDirectory: directory)
        for (name, stage) in [("loading", JobStage.ingestingAndDecodingStrips), ("failed", .failed), ("cancelled", .idle)] {
            model.currentStage = stage
            model.errorMessage = stage == .failed ? "The fixture could not be opened." : nil
            let image = try render(StudioWorkspaceView(viewModel: model), size: CGSize(width: 390, height: 844), name: "recovery-" + name)
            XCTAssertGreaterThan(try brightPixels(image), 150, "A bufferless viewer must not be an empty black trap")
        }
    }

    func testBackButtonOccupiesSamePixelsWhileOpeningLoadedAndFailed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = StudioViewModel(workingDirectory: directory)
        let artifact = try StudioTestArtifacts.make(directory: directory, sourceURL: directory.appendingPathComponent("photo.dng"))
        let host = UIHostingController(rootView: StudioWorkspaceView(viewModel: model))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host; window.makeKeyAndVisible(); host.view.frame = window.bounds
        defer { window.isHidden = true }
        var rectangles: [CGRect] = []
        for stage in [JobStage.ingestingAndDecodingStrips, .idle, .failed] {
            model.currentStage = stage
            model.sourceBuffer = stage == .idle ? artifact.sourceBuffer : nil
            model.metadata = stage == .idle ? artifact.metadata : nil
            for _ in 0..<4 { window.layoutIfNeeded(); host.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { host.view.layer.render(in: $0.cgContext) }
            let cg = try XCTUnwrap(image.cgImage)
            var rgba = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            rgba.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
            var points: [CGPoint] = []
            for y in 0..<140 { for x in 0..<75 {
                let i = (y * cg.width + x) * 4
                if rgba[i] > 150 && rgba[i + 1] > 150 && rgba[i + 2] > 150 { points.append(CGPoint(x: x, y: y)) }
            } }
            XCTAssertGreaterThan(points.count, 10)
            let xs = points.map(\.x), ys = points.map(\.y)
            rectangles.append(CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0)))
        }
        for rect in rectangles.dropFirst() {
            XCTAssertEqual(rect.minX, rectangles[0].minX, accuracy: 1, "Back position must not jump during decode")
            XCTAssertEqual(rect.minY, rectangles[0].minY, accuracy: 1)
            XCTAssertEqual(rect.width, rectangles[0].width, accuracy: 1)
            XCTAssertEqual(rect.height, rectangles[0].height, accuracy: 1)
        }
    }

    func testCompactAndMinimalActivityViewsFitTheirRealSlots() throws {
        for count in [0, 1, 233, 234] {
            let state = UpscaleActivityAttributes.ContentState(stageTitle: "Upscaling tile 234 of 234",
                completedTiles: count, totalTiles: 234, progressFraction: 0.1,
                estimatedSecondsRemaining: 3360, startedAt: Date().addingTimeInterval(-65))
            let compact = UIHostingController(rootView: CompactUpscaleProgress(state: state))
            let compactSize = compact.sizeThatFits(in: CGSize(width: 34, height: 18))
            XCTAssertLessThanOrEqual(compactSize.width, 34)
            XCTAssertLessThanOrEqual(compactSize.height, 18)
            let minimal = UIHostingController(rootView: MinimalUpscaleProgress(state: state))
            let minimalSize = minimal.sizeThatFits(in: CGSize(width: 16, height: 16))
            XCTAssertLessThanOrEqual(minimalSize.width, 16)
            XCTAssertLessThanOrEqual(minimalSize.height, 16)
            let image = try render(HStack { CompactUpscaleSymbol(state: state); CompactUpscaleProgress(state: state) }
                .padding(8).background(.black).ignoresSafeArea(),
                size: CGSize(width: 80, height: 36), name: "compact-\(count)")
            XCTAssertGreaterThan(try brightPixels(image), 40, "The actual compact percentage must render inside its slot")
        }
    }

    func testExpandedActivityKeepsLongPhaseAndETAWithinNarrowWidth() throws {
        let state = UpscaleActivityAttributes.ContentState(stageTitle: "Preparing the super-resolution model for the first tile",
            completedTiles: 0, totalTiles: 234, progressFraction: 0.1, estimatedSecondsRemaining: 3360,
            startedAt: Date().addingTimeInterval(-65))
        let host = UIHostingController(rootView: UpscaleActivityDetails(state: state))
        let fit = host.sizeThatFits(in: CGSize(width: 250, height: 200))
        XCTAssertLessThanOrEqual(fit.width, 250)
        XCTAssertLessThanOrEqual(fit.height, 140)
        _ = try render(UpscaleActivityDetails(state: state).padding(12).background(.black),
                       size: CGSize(width: 280, height: 160), name: "expanded-long-phase")
    }

    func testCaptureFixedTwoTimesOptionsForm() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = StudioViewModel(workingDirectory: directory)
        let source = directory.appendingPathComponent("synthetic.dng")
        model.metadata = ImageMetadataPacket(sourceURL: source, utTypeIdentifier: "com.adobe.dng",
            category: .cameraRAW, originalWidth: 3024, originalHeight: 4032)
        let image = try render(UpscaleOptionsFormSheet(viewModel: model, onPickFileOrFolder: {}),
            size: CGSize(width: 390, height: 1400), name: "options-two-times-only")
        XCTAssertGreaterThan(try brightPixels(image), 150)
    }

    func testCompactProcessingBarKeepsOneHeightAcrossFastTilePhases() throws {
        for width in [CGFloat(320), 390, 844] {
            var heights: [CGFloat] = []
            for phase in [PipelinePhase.preparingModels, .extractingTile, .predictingSuperResolution,
                          .blendingTile, .committingTile, .tileCommitted] {
                let progress = JobProgressPresentation(phase: phase, completedTiles: 117, totalTiles: 234)
                let view = ProcessingProgressBarView(progress: progress, onStop: {}, onShowDetails: {})
                let host = UIHostingController(rootView: view)
                let fit = host.sizeThatFits(in: CGSize(width: width, height: 100))
                heights.append(fit.height)
                XCTAssertGreaterThanOrEqual(fit.height, 80, "The Stop control needs breathing room within the card")
                XCTAssertLessThanOrEqual(fit.height, 90)
            }
            XCTAssertLessThan((heights.max() ?? 0) - (heights.min() ?? 0), 0.5)
        }
        for (name, stopping) in [("processing-compact", false), ("processing-stopping", true)] {
            let progress = JobProgressPresentation(phase: .committingTile, completedTiles: 117,
                totalTiles: 234, isStopping: stopping)
            let image = try render(ProcessingProgressBarView(progress: progress, onStop: {}, onShowDetails: {}),
                size: CGSize(width: 390, height: 90), name: name)
            XCTAssertGreaterThan(try brightPixels(image), 150)
        }
    }
}
#endif
