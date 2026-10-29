import XCTest
import Foundation
import CryptoKit
import CoreExport
import ImageIO
import MMapCanvas
import TiledInferenceEngine
import UniformTypeIdentifiers
import TruongScalerCore
@testable import DeepZoomGalleryUI

final class ProcessedLibraryStoreTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ProcessedLibrary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func folder(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func draft(id: UUID = UUID(), model: String = "EDSR-baseline") -> ProcessedPhotoDraft {
        ProcessedPhotoDraft(id: id, modelRawValue: model, sourceWidth: 16, sourceHeight: 12,
            outputWidth: 32, outputHeight: 24, scaleFactor: 2, grainAmount: 0.15,
            processedAt: Date(timeIntervalSince1970: 1_792_962_000), formatRawValue: ExportFormat.png16Bit.rawValue)
    }
    private func source() throws -> URL {
        let url = directory.appendingPathComponent("ordinary-camera.dng")
        try Data(repeating: 73, count: 2 * 1024 * 1024 + 37).write(to: url)
        return url
    }
    private func exported() throws -> URL {
        let url = directory.appendingPathComponent("export.png")
        try Data([1,3,5,7,9,11,13]).write(to: url)
        return url
    }

    func testOriginalIsFrozenAndDeduplicatedAndRecordsReopenAfterStoreRestart() async throws {
        let root = try folder("Chosen output"), input = try source(), output = try exported()
        let store = ProcessedLibraryStore()
        try await store.validateWritableFolder(root)
        let first = try await store.archiveOriginal(at: input, named: input.lastPathComponent, under: root)
        let second = try await store.archiveOriginal(at: input, named: input.lastPathComponent, under: root)
        XCTAssertEqual(first.relativePath, second.relativePath)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("comparison-originals").path).count, 1)
        // Changes in an input folder after archiving cannot alter the saved comparison source.
        try Data([0,0,0]).write(to: input)
        let archived = try await store.originalURL(first, under: root)
        XCTAssertEqual(try Data(contentsOf: archived).count, 2 * 1024 * 1024 + 37)
        let specification = draft()
        let record = try await store.publish(exportedURL: output, original: first, draft: specification, under: root)
        XCTAssertTrue(record.outputRelativePath.hasPrefix("originals/2026/"))
        XCTAssertEqual(record.metadataRelativePath, "metadata/" + (record.outputRelativePath as NSString).deletingPathExtension + ".json")
        let restarted = ProcessedLibraryStore()
        let records = try await restarted.records(under: root)
        XCTAssertEqual(records, [record])
        let opened = try await restarted.open(record, under: root)
        XCTAssertNotNil(opened.originalURL)
        XCTAssertNil(opened.comparisonUnavailableReason)
        XCTAssertEqual(try Data(contentsOf: opened.outputURL), try Data(contentsOf: output))
        XCTAssertEqual(record.modelLabel, "EDSR (Balanced)")
        let repeated = try await restarted.publish(exportedURL: output, original: first, draft: specification, under: root)
        XCTAssertEqual(repeated, record, "Retrying one completed job must not create another result")
        do {
            _ = try await restarted.publish(exportedURL: output, original: first,
                draft: draft(id: specification.id, model: "QuickSRNet-Large"), under: root)
            XCTFail("A job UUID cannot be relabelled with another model")
        } catch {}
    }

    func testPortableFolderMoveAndMissingOriginalStillPermitViewingTheResult() async throws {
        let root = try folder("before move"), store = ProcessedLibraryStore()
        let original = try await store.archiveOriginal(at: source(), named: "camera.dng", under: root)
        let record = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root)
        let moved = directory.appendingPathComponent("after move")
        try FileManager.default.moveItem(at: root, to: moved)
        let reloaded = try await ProcessedLibraryStore().records(under: moved)
        XCTAssertEqual(reloaded, [record])
        let opened = try await store.open(record, under: moved)
        XCTAssertNotNil(opened.originalURL)
        try FileManager.default.removeItem(at: moved.appendingPathComponent(record.original.relativePath))
        let missing = try await store.open(record, under: moved)
        XCTAssertNil(missing.originalURL)
        XCTAssertNotNil(missing.comparisonUnavailableReason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: missing.outputURL.path))
    }

    func testChangedArchivedOriginalStillPermitsVerifiedOutputOnly() async throws {
        let root = try folder("changed-original-output"), store = ProcessedLibraryStore()
        let original = try await store.archiveOriginal(at: source(), named: "camera.dng", under: root)
        let record = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root)
        let changedBytes = Data([42, 43, 44])
        let archived = root.appendingPathComponent(original.relativePath)
        try changedBytes.write(to: archived)

        let opened = try await store.open(record, under: root)
        XCTAssertEqual(opened.outputURL, root.appendingPathComponent(record.outputRelativePath))
        XCTAssertEqual(try ProcessedLibraryStore.hash(opened.outputURL), record.outputSHA256)
        XCTAssertNil(opened.originalURL)
        XCTAssertNotNil(opened.comparisonUnavailableReason)
        XCTAssertEqual(try Data(contentsOf: archived), changedBytes)
    }

    func testSymlinkedArchivedOriginalFileAndParentStillPermitVerifiedOutputOnly() async throws {
        for linkParent in [false, true] {
            let label = linkParent ? "parent" : "file"
            let root = try folder("symlink-original-output-" + label)
            let outside = try folder("symlink-original-target-" + label), store = ProcessedLibraryStore()
            let original = try await store.archiveOriginal(at: source(), named: "camera.dng", under: root)
            let record = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root)
            let archived = root.appendingPathComponent(original.relativePath)
            let target = outside.appendingPathComponent(archived.lastPathComponent)
            // Matching bytes would pass the hash check if opening followed the symlink.
            let originalBytes = try Data(contentsOf: archived)
            try originalBytes.write(to: target)
            let link = linkParent ? archived.deletingLastPathComponent() : archived
            let destination = linkParent ? outside : target
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
            let output = root.appendingPathComponent(record.outputRelativePath)
            let outputBytes = try Data(contentsOf: output)
            let metadata = root.appendingPathComponent(record.metadataRelativePath)
            let metadataBytes = try Data(contentsOf: metadata)

            XCTAssertThrowsError(try ProcessedLibraryStore.resolve(original.relativePath, under: root))
            let opened = try await store.open(record, under: root)
            XCTAssertEqual(opened.outputURL, output)
            XCTAssertNil(opened.originalURL, "A symlinked \(label) cannot supply comparison bytes")
            XCTAssertNotNil(opened.comparisonUnavailableReason)
            XCTAssertEqual(try Data(contentsOf: output), outputBytes)
            XCTAssertEqual(try Data(contentsOf: metadata), metadataBytes)
            XCTAssertEqual(try Data(contentsOf: target), originalBytes)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), destination.path)
        }
    }

    func testMergedPortableRootsPreserveDistinctResultsWithTheSameJobIdentity() async throws {
        let firstRoot = try folder("first-output"), secondRoot = try folder("second-output")
        let merged = try folder("merged-output"), store = ProcessedLibraryStore(), input = try source()
        let firstOriginal = try await store.archiveOriginal(at: input, named: "camera.dng", under: firstRoot)
        let secondOriginal = try await store.archiveOriginal(at: input, named: "camera.dng", under: secondRoot)
        let firstDraft = draft()
        let secondDraft = ProcessedPhotoDraft(id: firstDraft.id, modelRawValue: firstDraft.modelRawValue,
            sourceWidth: firstDraft.sourceWidth, sourceHeight: firstDraft.sourceHeight,
            outputWidth: firstDraft.outputWidth, outputHeight: firstDraft.outputHeight,
            scaleFactor: firstDraft.scaleFactor, grainAmount: firstDraft.grainAmount,
            processedAt: firstDraft.processedAt.addingTimeInterval(2 * 24 * 60 * 60), formatRawValue: firstDraft.formatRawValue)
        let exported = try exported()
        let first = try await store.publish(exportedURL: exported, original: firstOriginal, draft: firstDraft, under: firstRoot)
        let secondBytes = Data([2, 4, 6, 8, 10, 12, 14])
        try secondBytes.write(to: exported)
        let second = try await store.publish(exportedURL: exported, original: secondOriginal, draft: secondDraft, under: secondRoot)
        // The same saved job can be published in independent portable roots on different days.
        // A user merging those roots must keep both files and their authoritative record IDs.
        for (root, record) in [(firstRoot, first), (secondRoot, second)] {
            for path in [record.original.relativePath, record.outputRelativePath, record.metadataRelativePath] {
                let destination = merged.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: destination.path) { continue } // Deduplicated identical original.
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: root.appendingPathComponent(path), to: destination)
            }
        }
        let records = try await store.records(under: merged)
        XCTAssertEqual(records, [second, first])
        XCTAssertEqual(records.map(\.id), [firstDraft.id, firstDraft.id])
        XCTAssertNotEqual(first.outputRelativePath, second.outputRelativePath)
        let openedFirst = try await store.open(first, under: merged), openedSecond = try await store.open(second, under: merged)
        XCTAssertNotEqual(openedFirst.outputURL, openedSecond.outputURL)
        XCTAssertEqual(try Data(contentsOf: openedFirst.outputURL), Data([1, 3, 5, 7, 9, 11, 13]))
        XCTAssertEqual(try Data(contentsOf: openedSecond.outputURL), secondBytes)
        for record in records {
            XCTAssertEqual(try JSONDecoder().decode(ProcessedPhotoRecord.self,
                from: Data(contentsOf: merged.appendingPathComponent(record.metadataRelativePath))), record)
        }
        // Retrying the older saved canvas must not reuse the newer same-UUID sibling merely
        // because its model and archived source match. The generated bytes identify this result.
        try Data([1, 3, 5, 7, 9, 11, 13]).write(to: exported)
        let retried = try await store.publish(exportedURL: exported, original: firstOriginal, draft: firstDraft, under: merged)
        XCTAssertEqual(retried, first)
        XCTAssertEqual(try Data(contentsOf: openedSecond.outputURL), secondBytes)
        let afterRetry = try await store.records(under: merged)
        XCTAssertEqual(afterRetry, records)
    }

    func testPublishedRetryRefusesChangedConfigurationOrExportBytesWithoutRelabelling() async throws {
        for change in ["dimensions", "grain", "format", "bytes"] {
            let root = try folder("published-retry-" + change), store = ProcessedLibraryStore()
            let original = try await store.archiveOriginal(at: source(), named: "camera.dng", under: root)
            let specification = draft(), exported = try exported()
            let record = try await store.publish(exportedURL: exported, original: original, draft: specification, under: root)
            let output = root.appendingPathComponent(record.outputRelativePath)
            let metadata = root.appendingPathComponent(record.metadataRelativePath)
            let outputBytes = try Data(contentsOf: output), metadataBytes = try Data(contentsOf: metadata)
            let changed = ProcessedPhotoDraft(id: specification.id, modelRawValue: specification.modelRawValue,
                sourceWidth: change == "dimensions" ? 32 : specification.sourceWidth,
                sourceHeight: change == "dimensions" ? 24 : specification.sourceHeight,
                outputWidth: change == "dimensions" ? 64 : specification.outputWidth,
                outputHeight: change == "dimensions" ? 48 : specification.outputHeight,
                scaleFactor: specification.scaleFactor, grainAmount: change == "grain" ? 0.3 : specification.grainAmount,
                processedAt: specification.processedAt.addingTimeInterval(2 * 24 * 60 * 60),
                formatRawValue: change == "format" ? ExportFormat.linearDNG16Bit.rawValue : specification.formatRawValue)
            if change == "bytes" { try Data([20, 30, 40, 50, 60, 70, 80]).write(to: exported) }
            do {
                _ = try await store.publish(exportedURL: exported, original: original, draft: changed, under: root)
                XCTFail("A published UUID is not permission to reuse a different result for \(change)")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: output), outputBytes)
            XCTAssertEqual(try Data(contentsOf: metadata), metadataBytes)
            let listed = try await store.records(under: root)
            XCTAssertEqual(listed, [record])
        }
    }

    func testRealReexportsRemainRetryableAcrossFormatsAndWallClockSeconds() async throws {
        let input = try RealPipelineImageFixture.makePNG(in: directory, name: "undated-original.png")
        // Isolate real container/metadata encoding with a small completed SDR canvas. Model
        // inference/reference fidelity has separate required-production-model coverage.
        let artifacts = try StudioTestArtifacts.make(directory: directory, sourceURL: input,
            configuredScale: .x2, sourceWidth: 48, sourceHeight: 32, grain: 0,
            denoiseMode: .off, didRunDenoise: false)
        for buffer in [artifacts.sourceBuffer, artifacts.outputBuffer] {
            for y in 0..<buffer.height {
                for x in 0..<buffer.width {
                    let pixel = buffer.unsafePixelPointer(x: x, y: y)
                    pixel[0] = Float16(0.1 + 0.6 * Float(x) / Float(max(1, buffer.width - 1)))
                    pixel[1] = Float16(0.1 + 0.5 * Float(y) / Float(max(1, buffer.height - 1)))
                    pixel[2] = 0.25
                    pixel[3] = 1
                }
            }
        }
        var formats: [(ExportFormat, String)] = [(.linearDNG16Bit, "dng"), (.tiff16BitLZW, "tiff"),
            (.png16Bit, "png"), (.jpeg95, "jpg")]
        if (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(UTType.heic.identifier) == true {
            formats.append((.heic10BitHDR, "heic"))
        }
        let store = ProcessedLibraryStore()
        var firstExports: [(ExportFormat, URL, ArchivedOriginal, ProcessedPhotoDraft, ProcessedPhotoRecord, URL)] = []
        for (format, ext) in formats {
            let root = try folder("real-retry-library-" + format.rawValue)
            let exportDirectory = try folder("real-first-export-" + format.rawValue)
            let exported = exportDirectory.appendingPathComponent("result." + ext)
            _ = try FormatAwareExporter.exportImage(artifacts: artifacts, destinationURL: exported,
                overrideFormat: format, overrideGrainAmount: 0)
            let original = try await store.archiveOriginal(at: input, named: input.lastPathComponent, under: root)
            let specification = ProcessedPhotoDraft(id: artifacts.checkpoint.jobID,
                modelRawValue: artifacts.checkpoint.config.backbone.rawValue,
                sourceWidth: artifacts.sourceBuffer.width, sourceHeight: artifacts.sourceBuffer.height,
                outputWidth: artifacts.outputBuffer.width, outputHeight: artifacts.outputBuffer.height,
                scaleFactor: 2, grainAmount: 0, processedAt: artifacts.checkpoint.updatedAt,
                formatRawValue: format.rawValue)
            let record = try await store.publish(exportedURL: exported, original: original, draft: specification, under: root)
            firstExports.append((format, root, original, specification, record, exported))
        }
        // Missing capture dates previously fell back to std::time(now) inside the DNG writer.
        // Ensure real repeated encoding crosses a second boundary instead of masking that field.
        try await Task.sleep(for: .milliseconds(1100))
        for (format, root, original, specification, record, firstURL) in firstExports {
            do {
                let exportDirectory = try folder("real-second-export-" + format.rawValue)
                let secondURL = exportDirectory.appendingPathComponent(firstURL.lastPathComponent)
                _ = try FormatAwareExporter.exportImage(artifacts: artifacts, destinationURL: secondURL,
                    overrideFormat: format, overrideGrainAmount: 0)
                XCTAssertEqual(try Data(contentsOf: secondURL), try Data(contentsOf: firstURL),
                    "The same completed artifact must keep stable container/metadata bytes for \(format)")
                let later = ProcessedPhotoDraft(id: specification.id, modelRawValue: specification.modelRawValue,
                    sourceWidth: specification.sourceWidth, sourceHeight: specification.sourceHeight,
                    outputWidth: specification.outputWidth, outputHeight: specification.outputHeight,
                    scaleFactor: specification.scaleFactor, grainAmount: specification.grainAmount,
                    processedAt: specification.processedAt.addingTimeInterval(2 * 24 * 60 * 60),
                    formatRawValue: specification.formatRawValue)
                let retried = try await store.publish(exportedURL: secondURL, original: original, draft: later, under: root)
                XCTAssertEqual(retried, record, "A normal real \(format) retry must reuse the authoritative saved path/date")
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(record.outputRelativePath)), try Data(contentsOf: firstURL))
                let listed = try await store.records(under: root)
                XCTAssertEqual(listed, [record])
            } catch {
                XCTFail("A normal real \(format) re-export/retry failed: \(error)")
            }
        }
        XCTAssertGreaterThanOrEqual(firstExports.count, 4)
    }

    func testIndistinguishablePublishedCopiesCannotBeChosenByRetry() async throws {
        let root = try folder("ambiguous-published"), store = ProcessedLibraryStore()
        let original = try await store.archiveOriginal(at: source(), named: "camera.dng", under: root)
        let specification = draft(), exported = try exported()
        let first = try await store.publish(exportedURL: exported, original: original, draft: specification, under: root)
        // Equivalent to merging another root that published this same deterministic job later.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(first.metadataRelativePath))) as? [String: Any])
        object["outputRelativePath"] = "originals/2026/10/30/TS_\(first.id.uuidString.lowercased()).png"
        object["processedAt"] = first.processedAt.addingTimeInterval(2 * 24 * 60 * 60).timeIntervalSinceReferenceDate
        let secondData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let second = try JSONDecoder().decode(ProcessedPhotoRecord.self, from: secondData)
        let secondOutput = root.appendingPathComponent(second.outputRelativePath)
        let secondMetadata = root.appendingPathComponent(second.metadataRelativePath)
        try FileManager.default.createDirectory(at: secondOutput.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondMetadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent(first.outputRelativePath), to: secondOutput)
        try secondData.write(to: secondMetadata)
        let listed = try await store.records(under: root)
        XCTAssertEqual(listed, [second, first])
        do {
            _ = try await store.publish(exportedURL: exported, original: original, draft: specification, under: root)
            XCTFail("A retry must not arbitrarily choose one portable path when both match")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: secondMetadata), secondData)
        XCTAssertEqual(try Data(contentsOf: secondOutput), try Data(contentsOf: exported))
        let after = try await store.records(under: root)
        XCTAssertEqual(after, listed)
    }

    func testChangedOutputIsNeverPresentedAsAnUnchangedProcessedResult() async throws {
        let root = try folder("output"), store = ProcessedLibraryStore()
        let original = try await store.archiveOriginal(at: source(), named: "camera.dng", under: root)
        let record = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root)
        try Data([8,8,8]).write(to: root.appendingPathComponent(record.outputRelativePath))
        do { _ = try await store.open(record, under: root); XCTFail("Changed result bytes must be detected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
    }

    func testInterruptedImagePublicationRecoversOnlyAfterBothHashesMatch() async throws {
        let root = try folder("output"), store = ProcessedLibraryStore()
        let original = try await store.archiveOriginal(at: source(), named: "camera.dng", under: root)
        let record = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(record.metadataRelativePath))
        let stage = root.appendingPathComponent(".staging/recovery.pending.json")
        try JSONEncoder().encode(record).write(to: stage)
        let recovered = try await ProcessedLibraryStore().records(under: root)
        XCTAssertEqual(recovered, [record])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertEqual(try JSONDecoder().decode(ProcessedPhotoRecord.self,
            from: Data(contentsOf: root.appendingPathComponent(record.metadataRelativePath))), record)
    }

    func testFailedPublicationCleansOnlyItsPrivateImageStage() async throws {
        for failure in ["missing-export", "blocked-output"] {
            let root = try folder(failure), store = ProcessedLibraryStore(), input = try source()
            let originalBytes = try Data(contentsOf: input)
            let original = try await store.archiveOriginal(at: input, named: "source.dng", under: root)
            let specification = draft()
            let output = directory.appendingPathComponent("large-export-\(failure).png")
            if failure == "blocked-output" {
                try originalBytes.write(to: output)
                try Data([99]).write(to: root.appendingPathComponent("originals"))
            }
            do {
                _ = try await store.publish(exportedURL: output, original: original, draft: specification, under: root)
                XCTFail("The failed publication must be reported")
            } catch {}
            let stage = root.appendingPathComponent(".staging/\(specification.id.uuidString.lowercased()).image")
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path), "A failed save must not retain its large unpublished image copy")
            XCTAssertEqual(try Data(contentsOf: input), originalBytes)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(original.relativePath)), originalBytes)
            if failure == "blocked-output" {
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("originals")), Data([99]))
                let pending = root.appendingPathComponent(".staging/\(specification.id.uuidString.lowercased()).pending.json")
                XCTAssertEqual(try JSONDecoder().decode(ProcessedPhotoRecord.self, from: Data(contentsOf: pending)).id, specification.id,
                    "Cleanup must preserve the durable intent for later recovery")
                XCTAssertEqual(try Data(contentsOf: output), originalBytes)
            }
        }
    }

    func testSameJobConflictingPendingIntentIsNeverOverwrittenByRetry() async throws {
        let root = try folder("same-job-conflict"), store = ProcessedLibraryStore()
        let original = try await store.archiveOriginal(at: source(), named: "source.dng", under: root)
        let specification = draft(), exported = try exported()
        let record = try await store.publish(exportedURL: exported, original: original, draft: specification, under: root)
        let metadata = root.appendingPathComponent(record.metadataRelativePath)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        object["modelRawValue"] = BackboneModelKind.quickSRNet.rawValue
        let intent = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        try FileManager.default.removeItem(at: metadata)
        let output = root.appendingPathComponent(record.outputRelativePath), changed = Data([99, 100])
        try changed.write(to: output)
        let pending = root.appendingPathComponent(".staging/\(specification.id.uuidString.lowercased()).pending.json")
        try intent.write(to: pending)
        do {
            _ = try await store.publish(exportedURL: exported, original: original, draft: specification, under: root)
            XCTFail("A conflicting same-job intent must require recovery rather than relabelling")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: pending), intent)
        XCTAssertEqual(try Data(contentsOf: output), changed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".staging/\(specification.id.uuidString.lowercased()).image").path))
    }

    func testIdenticalPendingIntentCanFinishPublicationOnRetry() async throws {
        let root = try folder("same-job-identical"), store = ProcessedLibraryStore()
        let original = try await store.archiveOriginal(at: source(), named: "source.dng", under: root)
        let specification = draft(), exported = try exported()
        let record = try await store.publish(exportedURL: exported, original: original, draft: specification, under: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(record.metadataRelativePath))
        try FileManager.default.removeItem(at: root.appendingPathComponent(record.outputRelativePath))
        let pending = root.appendingPathComponent(".staging/\(specification.id.uuidString.lowercased()).pending.json")
        try JSONEncoder().encode(record).write(to: pending)
        // Real save retries create a fresh Date(); crossing a day must not move or relabel the intent.
        let later = ProcessedPhotoDraft(id: specification.id, modelRawValue: specification.modelRawValue,
            sourceWidth: specification.sourceWidth, sourceHeight: specification.sourceHeight,
            outputWidth: specification.outputWidth, outputHeight: specification.outputHeight,
            scaleFactor: specification.scaleFactor, grainAmount: specification.grainAmount,
            processedAt: specification.processedAt.addingTimeInterval(2 * 24 * 60 * 60), formatRawValue: specification.formatRawValue)
        let retried = try await store.publish(exportedURL: exported, original: original, draft: later, under: root)
        XCTAssertEqual(retried, record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        let records = try await store.records(under: root)
        XCTAssertEqual(records, [record])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(record.outputRelativePath)), try Data(contentsOf: exported))
    }

    func testPathsAndSymlinksCannotEscapeTheChosenRoot() async throws {
        let root = try folder("output"), outside = try folder("outside")
        for path in ["../outside/file", "/absolute", "originals/../../file", "originals//file", "originals/./file"] {
            XCTAssertThrowsError(try ProcessedLibraryStore.resolve(path, under: root))
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("originals"), withDestinationURL: outside)
        XCTAssertThrowsError(try ProcessedLibraryStore.resolve("originals/file.png", under: root))
        let store = ProcessedLibraryStore()
        let original = try await store.archiveOriginal(at: source(), named: "camera.dng", under: root)
        do { _ = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root); XCTFail("Escaping output must fail") }
        catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testArbitraryInputFolderIncludesLooseAndNestedRawsAlongsideOriginalsFolder() throws {
        let root = try folder("Any RAW folder")
        for relative in ["top.DNG", "session/another.NEF", "originals/third.ARW", "session/nested/fourth.RAF"] {
            let file = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: file)
        }
        let items = StudioViewModel.scanLibraryItemsSynchronously(at: root)
        XCTAssertEqual(Set(items.map(\.filename)), ["top.DNG", "another.NEF", "third.ARW", "fourth.RAF"])
    }
}

extension ProcessedLibraryStoreTests {
    func testTrashRestorePurgeNeverChangesInputOrSharedComparisonOriginal() async throws {
        let root = try folder("output"), store = ProcessedLibraryStore(), input = try source()
        let inputBytes = try Data(contentsOf: input)
        let original = try await store.archiveOriginal(at: input, named: "camera.dng", under: root)
        let record = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root)
        let sibling = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root)
        try await store.trash(record: record, under: root)
        var rows = try await store.records(under: root)
        XCTAssertEqual(rows, [sibling])
        let entryRows = try await store.trashed(under: root)
        let entry = try XCTUnwrap(entryRows.first)
        XCTAssertEqual(entry.record, record)
        try await ProcessedLibraryStore().restore(entry, under: root)
        rows = try await store.records(under: root)
        XCTAssertEqual(Set(rows.map(\.id)), [record.id, sibling.id])
        let openedRecord = try await store.open(record, under: root)
        XCTAssertNotNil(openedRecord.originalURL)
        try await store.trash(record: record, under: root)
        let againRows = try await store.trashed(under: root)
        let again = try XCTUnwrap(againRows.first)
        try await store.permanentlyDelete(again, under: root)
        let empty = try await store.trashed(under: root)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(try Data(contentsOf: input), inputBytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(original.relativePath)), inputBytes)
        let openedSibling = try await store.open(sibling, under: root)
        XCTAssertNotNil(openedSibling.originalURL)
    }
    func testRestoreConflictAndChangedTrashAreRefusedBeforeAnyMove() async throws {
        let root = try folder("output"), store = ProcessedLibraryStore()
        let original = try await store.archiveOriginal(at: source(), named: "source.dng", under: root)
        let record = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root)
        try await store.trash(record: record, under: root)
        let entryRows = try await store.trashed(under: root)
        let entry = try XCTUnwrap(entryRows.first)
        let url = root.appendingPathComponent(record.outputRelativePath)
        try Data([99]).write(to: url)
        do { try await store.restore(entry, under: root); XCTFail("Never overwrite a destination") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), Data([99]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(record.metadataRelativePath).path))
        try FileManager.default.removeItem(at: url)
        let stored = root.appendingPathComponent(entry.directory + "/" + entry.files[0].storedName)
        try Data([100]).write(to: stored)
        do { try await store.permanentlyDelete(entry, under: root); XCTFail("Never purge changed bytes") } catch {}
        XCTAssertEqual(try Data(contentsOf: stored), Data([100]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testInterruptedMoveRestoreAndPurgeRecoverFromDurableIntent() async throws {
        let root = try folder("output"), store = ProcessedLibraryStore()
        let original = try await store.archiveOriginal(at: source(), named: "source.dng", under: root)
        let record = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root)
        let entry = try ProcessedLibraryStore.makeTrash(paths: [record.outputRelativePath, record.metadataRelativePath], record: record, under: root)
        try ProcessedLibraryStore.writeTrash(entry, under: root)
        let first = entry.files[0]
        try FileManager.default.moveItem(at: root.appendingPathComponent(first.originalPath), to: root.appendingPathComponent(entry.directory + "/" + first.storedName))
        let movedRows = try await ProcessedLibraryStore().trashed(under: root)
        let moved = try XCTUnwrap(movedRows.first)
        XCTAssertEqual(moved.state, .trashed)
        var restoring = moved; restoring.state = .restoring
        try ProcessedLibraryStore.writeTrash(restoring, under: root)
        try FileManager.default.moveItem(at: root.appendingPathComponent(moved.directory + "/" + first.storedName), to: root.appendingPathComponent(first.originalPath))
        let restored = try await ProcessedLibraryStore().records(under: root)
        XCTAssertEqual(restored, [record])
        try await store.trash(record: record, under: root)
        let purgingRows = try await store.trashed(under: root)
        var purging = try XCTUnwrap(purgingRows.first)
        purging.state = .purging
        try ProcessedLibraryStore.writeTrash(purging, under: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(purging.directory + "/" + purging.files[0].storedName))
        let empty = try await ProcessedLibraryStore().trashed(under: root)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(original.relativePath).path))
    }
    func testInvalidTrashEntriesDoNotHideHealthyResultsOrOtherTrash() async throws {
        for corruption in ["digest", "identity", "byte-count-overflow"] {
            let root = try folder("isolated-trash-" + corruption), store = ProcessedLibraryStore()
            let original = try await store.archiveOriginal(at: source(), named: "source.dng", under: root)
            let keep = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root)
            let bad = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root)
            let goodTrash = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root)
            try await store.trash(record: bad, under: root); try await store.trash(record: goodTrash, under: root)
            let entries = try await store.trashed(under: root)
            let invalid = try XCTUnwrap(entries.first { $0.record?.id == bad.id })
            let good = try XCTUnwrap(entries.first { $0.record?.id == goodTrash.id })
            let manifest = root.appendingPathComponent(invalid.directory + "/entry.json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
            if corruption == "identity" { object["id"] = UUID().uuidString }
            else {
                var files = try XCTUnwrap(object["files"] as? [[String: Any]])
                if corruption == "digest" { files[0]["sha256"] = "invalid-digest" }
                else { files[files.count - 1]["bytes"] = NSNumber(value: Int64.max) }
                object["files"] = files
            }
            let damaged = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try damaged.write(to: manifest, options: .atomic)
            let retained = try invalid.files.map { try Data(contentsOf: root.appendingPathComponent(invalid.directory + "/" + $0.storedName)) }
            let visible = try await store.records(under: root)
            XCTAssertEqual(visible.map(\.id), [keep.id])
            let remaining = try await store.trashed(under: root)
            XCTAssertEqual(remaining.map(\.id), [good.id])
            do { try await store.restore(invalid, under: root); XCTFail("An invalid entry must remain untouched") } catch {}
            let added = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root)
            let afterPublish = try await store.records(under: root)
            XCTAssertEqual(Set(afterPublish.map(\.id)), [keep.id, added.id])
            XCTAssertEqual(try Data(contentsOf: manifest), damaged)
            for (index, file) in invalid.files.enumerated() {
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(invalid.directory + "/" + file.storedName)), retained[index])
            }
        }
    }

    func testConflictingPendingRecordDoesNotBlockUnrelatedListingOrPublication() async throws {
        let root = try folder("isolated-pending"), store = ProcessedLibraryStore()
        let original = try await store.archiveOriginal(at: source(), named: "source.dng", under: root)
        let keep = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root)
        let conflict = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root)
        let metadata = root.appendingPathComponent(conflict.metadataRelativePath)
        let metadataBytes = try Data(contentsOf: metadata)
        let output = root.appendingPathComponent(conflict.outputRelativePath), outputBytes = try Data(contentsOf: output)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: metadataBytes) as? [String: Any])
        object["modelRawValue"] = BackboneModelKind.quickSRNet.rawValue
        let conflictingIntent = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let pending = root.appendingPathComponent(".staging/conflict.pending.json")
        try conflictingIntent.write(to: pending, options: .atomic)
        let listed = try await store.records(under: root)
        XCTAssertEqual(Set(listed.map(\.id)), [keep.id, conflict.id])
        let added = try await store.publish(exportedURL: exported(), original: original, draft: draft(), under: root)
        let afterPublish = try await store.records(under: root)
        XCTAssertEqual(Set(afterPublish.map(\.id)), [keep.id, conflict.id, added.id])
        XCTAssertEqual(try Data(contentsOf: pending), conflictingIntent)
        XCTAssertEqual(try Data(contentsOf: metadata), metadataBytes)
        XCTAssertEqual(try Data(contentsOf: output), outputBytes)
    }

    func testShareSnapshotsHaveIndependentLifetimeAndRefuseChangedExpectedBytes() async throws {
        let input = try source(), original = try Data(contentsOf: input)
        let preparer = PhotoSharePreparer()
        var session: PhotoShareSession? = try await preparer.prepare([input], surface: .viewer)
        let privateURL = try XCTUnwrap(session?.fileURLs.first)
        XCTAssertNotEqual(privateURL, input)
        try Data([7]).write(to: input)
        XCTAssertEqual(try Data(contentsOf: privateURL), original)
        session = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateURL.path))
        do { _ = try await preparer.prepare([input], surface: .viewer, expectedHashes: [input: String(repeating: "0", count: 64)]); XCTFail("Changed result cannot be shared as verified") } catch {}
    }
}
