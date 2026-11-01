import Foundation
import CryptoKit
import XCTest
@testable import TruongScalerCore

final class PortableSuiteHandoffTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PortableHandoffTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func makeDocument(in directory: URL, target: SuiteCompanionApp = .truongScaler,
                              bytes: Data = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0]),
                              expectedSHA: String? = nil,
                              originalName: String = "untouched.dng",
                              noiserFlag: Bool? = false,
                              history: ImageProcessingHistory? = nil) throws -> PortableSuiteHandoff.Document {
        let source = directory.appendingPathComponent("source.dng")
        try bytes.write(to: source)
        return try PortableSuiteHandoff.createDocument(exportedImageURL: source, originalFileName: originalName,
            sourceApp: target == .truongScaler ? .truongNoiser : .truongScaler, targetApp: target,
            isDenoised: true, isUpscaled: true, globalMaxLuminance: 2,
            upscaleFactor: 2, globalMaxLinearComponent: 4, directory: directory.appendingPathComponent("outgoing"),
            isDenoisedByNoiser: noiserFlag, processingHistory: history, expectedImageSHA256: expectedSHA)
    }

    private func children(_ directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    func testBothDirectionsStreamExactBytesAndRetainExplicitHistoryWithoutTrustingFilenameAsAPath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var bytes = Data(repeating: 0, count: 2 * 1024 * 1024 + 257)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: index * 17 + 31) }
        let history = ImageProcessingHistory(steps: [.init(id: UUID(), app: "unknown.previous.app", operation: "denoise",
            model: "opaque-legacy-model", inputWidth: 16, inputHeight: 12, outputWidth: 16, outputHeight: 12)])
        for target in [SuiteCompanionApp.truongScaler, .truongNoiser] {
            let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let document = try makeDocument(in: directory, target: target, bytes: bytes,
                expectedSHA: expected, originalName: "../../a-private-path/untouched.dng", noiserFlag: false, history: history)
            let incoming = directory.appendingPathComponent(target.rawValue)
            let payload = try PortableSuiteHandoff.importDocument(at: document.fileURL, expectedTarget: target, directory: incoming)
            let image = URL(fileURLWithPath: payload.imageFileURLPath)
            XCTAssertEqual(payload.targetApp, target)
            XCTAssertEqual(payload.originalFileName, "../../a-private-path/untouched.dng", "Display-only names remain opaque")
            XCTAssertEqual(image.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path,
                incoming.standardizedFileURL.path)
            XCTAssertEqual(image.lastPathComponent, "image.dng")
            XCTAssertEqual(try Data(contentsOf: image), bytes)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("source.dng")), bytes)
            XCTAssertEqual(payload.isDenoisedByNoiser, false, "The sender's app name does not invent processing attribution")
            XCTAssertEqual(payload.pipelineSessionState.isDenoisedByNoiser, false)
            XCTAssertEqual(payload.processingHistory, history)
            XCTAssertEqual(payload.pipelineSessionState.processingHistory, history)
            XCTAssertEqual(payload.upscaleFactor, 2)
            XCTAssertEqual(payload.globalMaxLinearComponent, 4)
        }
    }

    func testOutgoingDocumentRetainsItsCopyAndRetiresOnlyItsOwnDirectory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unrelated = directory.appendingPathComponent("keep-me.dng")
        try Data([11, 22]).write(to: unrelated)
        var document: PortableSuiteHandoff.Document? = try makeDocument(in: directory)
        let file = try XCTUnwrap(document?.fileURL)
        let source = directory.appendingPathComponent("source.dng")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        document = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data([11, 22]))
    }

    func testCorruptImageAndManifestAreRefusedWithoutPublishingAnImport() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try makeDocument(in: directory)
        let original = try Data(contentsOf: document.fileURL)
        let incoming = directory.appendingPathComponent("incoming")
        for change in ["image", "manifest", "checksum"] {
            var damaged = original
            if change == "image" { damaged[damaged.count - 33] ^= 1 }
            else if change == "checksum" { damaged[damaged.count - 1] ^= 1 }
            else {
                let range = try XCTUnwrap(damaged.range(of: Data("untouched.dng".utf8)))
                damaged[range.lowerBound] ^= 1 // Still valid JSON, but no longer the hashed metadata.
            }
            let file = directory.appendingPathComponent(change + ".truongscalerhandoff")
            try damaged.write(to: file)
            XCTAssertThrowsError(try PortableSuiteHandoff.importDocument(at: file, expectedTarget: .truongScaler, directory: incoming))
            XCTAssertTrue(children(incoming).isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: document.fileURL), original)
    }

    func testTruncationTrailingBytesAndUnboundedManifestLengthAreRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try makeDocument(in: directory)
        let original = try Data(contentsOf: document.fileURL)
        let magicCount = Data("TruongSuiteHandoff-v1\n".utf8).count
        var oversized = original
        oversized.replaceSubrange(magicCount..<(magicCount + 4), with: [255, 255, 255, 255])
        let cases = [Data(), Data(original.prefix(magicCount + 2)), Data(original.dropLast()), original + Data([0]), oversized]
        let incoming = directory.appendingPathComponent("incoming")
        for (index, bytes) in cases.enumerated() {
            let file = directory.appendingPathComponent("bad-\(index).truongscalerhandoff")
            try bytes.write(to: file)
            XCTAssertThrowsError(try PortableSuiteHandoff.importDocument(at: file, expectedTarget: .truongScaler, directory: incoming))
            XCTAssertTrue(children(incoming).isEmpty)
        }
    }

    func testSelfConsistentButUnsafeManifestCannotChoosePathsOrAnotherTarget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try makeDocument(in: directory)
        let original = try Data(contentsOf: document.fileURL)
        let incoming = directory.appendingPathComponent("incoming")
        for change in ["path", "extension", "size", "version", "target"] {
            let altered = try rewritten(original) { manifest in
                switch change {
                case "path":
                    var payload = try XCTUnwrap(manifest["payload"] as? [String: Any])
                    payload["imageFileURLPath"] = directory.appendingPathComponent("source.dng").path
                    manifest["payload"] = payload
                case "extension": manifest["imageExtension"] = "../../not-an-extension"
                case "size": manifest["imageBytes"] = PortableSuiteHandoff.maximumImageBytes + 1
                case "version": manifest["version"] = 99
                default:
                    var payload = try XCTUnwrap(manifest["payload"] as? [String: Any])
                    payload["sourceApp"] = SuiteCompanionApp.truongScaler.rawValue
                    payload["targetApp"] = SuiteCompanionApp.truongNoiser.rawValue
                    manifest["payload"] = payload
                }
            }
            let file = directory.appendingPathComponent(change + ".truongscalerhandoff")
            try altered.write(to: file)
            XCTAssertThrowsError(try PortableSuiteHandoff.importDocument(at: file, expectedTarget: .truongScaler, directory: incoming))
            XCTAssertTrue(children(incoming).isEmpty)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("source.dng").path))
    }

    func testExpectedSavedImageHashRefusesChangedBytesAndCleansOnlyItsPartialDocument() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try makeDocument(in: directory, expectedSHA: String(repeating: "0", count: 64)))
        XCTAssertTrue(children(directory.appendingPathComponent("outgoing")).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("source.dng").path))
    }

    func testPortableManifestRejectsRawInvalidHeadroomBeforeLegacyClamping() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try makeDocument(in: directory)
        let original = try Data(contentsOf: document.fileURL)
        let incoming = directory.appendingPathComponent("incoming")
        let cases: [(String, String, Any?)] = [
            ("negative-component", "globalMaxLinearComponent", -1),
            ("zero-component", "globalMaxLinearComponent", 0),
            ("component-below-luminance", "globalMaxLinearComponent", 1),
            ("missing-component", "globalMaxLinearComponent", nil),
            ("overflow-component", "globalMaxLinearComponent", Double.greatestFiniteMagnitude),
            ("negative-luminance", "globalMaxLuminance", -1),
            ("overflow-luminance", "globalMaxLuminance", Double.greatestFiniteMagnitude),
            ("invalid-factor-zero", "upscaleFactor", 0),
            ("invalid-factor-negative", "upscaleFactor", -1),
            ("invalid-factor-large", "upscaleFactor", 65),
            ("invalid-factor-fraction", "upscaleFactor", 1.5),
        ]
        for (name, key, value) in cases {
            let altered = try rewritten(original) { manifest in
                var payload = try XCTUnwrap(manifest["payload"] as? [String: Any])
                payload[key] = value
                manifest["payload"] = payload
            }
            let file = directory.appendingPathComponent(name + ".truongscalerhandoff")
            try altered.write(to: file)
            XCTAssertThrowsError(try PortableSuiteHandoff.importDocument(at: file,
                expectedTarget: .truongScaler, directory: incoming), name)
            XCTAssertTrue(children(incoming).isEmpty, name)
        }
        XCTAssertEqual(try Data(contentsOf: document.fileURL), original)
    }

    func testLegacyAppGroupHeadroomCompatibilityIsSeparateFromPortableValidation() throws {
        let payload = SharedSuiteHandoffPayload(sourceApp: .truongNoiser, targetApp: .truongScaler,
            imageFileURLPath: "/legacy/group/image.dng", originalFileName: "image.dng",
            isDenoised: true, isUpscaled: true, globalMaxLuminance: 2, globalMaxLinearComponent: 4)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        object["globalMaxLinearComponent"] = -1
        let decoded = try JSONDecoder().decode(SharedSuiteHandoffPayload.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.globalMaxLinearComponent, 2, "Do not break the historic App Group decoder")
        XCTAssertNil(decoded.upscaleFactor, "Prior upscale evidence may retain an unknown factor")
        XCTAssertNil(decoded.isDenoisedByNoiser)
    }

    func testPortableForwardingPreservesUnknownAttributionAndUpscaleFactor() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try makeDocument(in: directory)
        let altered = try rewritten(Data(contentsOf: document.fileURL)) { manifest in
            var payload = try XCTUnwrap(manifest["payload"] as? [String: Any])
            payload.removeValue(forKey: "upscaleFactor")
            payload.removeValue(forKey: "isDenoisedByNoiser")
            payload.removeValue(forKey: "processingHistory")
            manifest["payload"] = payload
        }
        let file = directory.appendingPathComponent("unknown-history.truongscalerhandoff")
        try altered.write(to: file)
        let received = try PortableSuiteHandoff.importDocument(at: file, expectedTarget: .truongScaler,
            directory: directory.appendingPathComponent("incoming"))
        XCTAssertTrue(received.isUpscaled)
        XCTAssertTrue(received.isDenoised)
        XCTAssertNil(received.upscaleFactor)
        XCTAssertNil(received.isDenoisedByNoiser)
        XCTAssertNil(received.processingHistory)
        XCTAssertNil(received.pipelineSessionState.isDenoisedByNoiser)
    }

    func testImportSynchronizesNewDirectoryLinksAndRetainedImageBeforeReturning() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data([11, 22, 33, 44])
        let document = try makeDocument(in: directory, bytes: bytes)
        let nested = directory.appendingPathComponent("nested")
        let receiver = nested.appendingPathComponent("receiver")
        let incoming = receiver.appendingPathComponent("imports")
        var synchronized: [String] = []
        let received = try PortableSuiteHandoff.importDocument(at: document.fileURL,
            expectedTarget: .truongScaler, directory: incoming, synchronizeDirectory: { url in
                synchronized.append(url.standardizedFileURL.path)
                if url.lastPathComponent.hasPrefix("import_") {
                    let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
                    XCTAssertEqual(names, ["untouched.dng"])
                    XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("untouched.dng")), bytes,
                        "The complete retained image must exist before directory publication")
                }
                try PortableSuiteHandoff.synchronizeDirectory(url)
            })
        let owned = URL(fileURLWithPath: received.imageFileURLPath).deletingLastPathComponent()
        XCTAssertEqual(synchronized, [directory, nested, receiver, owned, incoming].map { $0.standardizedFileURL.path })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: received.imageFileURLPath)), bytes)
    }

    func testDirectoryDurabilityFailureRefusesImportAndRetiresOnlyItsPartialCopy() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try makeDocument(in: directory)
        let incoming = directory.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: false)
        let unrelated = incoming.appendingPathComponent("keep.dng")
        try Data([55, 66]).write(to: unrelated)
        for failAtParent in [false, true] {
            var syncCount = 0
            XCTAssertThrowsError(try PortableSuiteHandoff.importDocument(at: document.fileURL,
                expectedTarget: .truongScaler, directory: incoming, synchronizeDirectory: { url in
                    syncCount += 1
                    if (url.standardizedFileURL == incoming.standardizedFileURL) == failAtParent {
                        throw POSIXError(.EIO)
                    }
                    try PortableSuiteHandoff.synchronizeDirectory(url)
                })) { error in
                    XCTAssertEqual((error as? POSIXError)?.code, .EIO)
                }
            XCTAssertEqual(syncCount, failAtParent ? 2 : 1)
            XCTAssertEqual(children(incoming), ["keep.dng"])
            XCTAssertEqual(try Data(contentsOf: unrelated), Data([55, 66]))
            XCTAssertTrue(FileManager.default.fileExists(atPath: document.fileURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("source.dng").path))
        }
    }

    func testLegacyPayloadDoesNotAttributeDenoisingToItsForwardingApp() throws {
        let payload = SharedSuiteHandoffPayload(sourceApp: .truongNoiser, targetApp: .truongScaler,
            imageFileURLPath: "/legacy/group/image.dng", originalFileName: "image.dng",
            isDenoised: true, isUpscaled: false, globalMaxLuminance: 1)
        let decoded = try JSONDecoder().decode(SharedSuiteHandoffPayload.self, from: JSONEncoder().encode(payload))
        XCTAssertNil(decoded.isDenoisedByNoiser)
        XCTAssertNil(decoded.processingHistory)
        XCTAssertNil(decoded.pipelineSessionState.isDenoisedByNoiser)
        XCTAssertTrue(decoded.isDenoised)
    }

    func testRetiringAnUnconsumedImportCannotDeleteTheOriginalOrOtherImports() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try makeDocument(in: directory)
        let incoming = directory.appendingPathComponent("incoming")
        let first = try PortableSuiteHandoff.importDocument(at: document.fileURL, expectedTarget: .truongScaler, directory: incoming)
        let second = try PortableSuiteHandoff.importDocument(at: document.fileURL, expectedTarget: .truongScaler, directory: incoming)
        PortableSuiteHandoff.retireUnconsumedImport(first, directory: incoming)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.imageFileURLPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.imageFileURLPath))
        let fake = SharedSuiteHandoffPayload(sourceApp: .truongNoiser, targetApp: .truongScaler,
            imageFileURLPath: directory.appendingPathComponent("source.dng").path, originalFileName: "source.dng",
            isDenoised: false, isUpscaled: false, globalMaxLuminance: 1)
        PortableSuiteHandoff.retireUnconsumedImport(fake, directory: incoming)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fake.imageFileURLPath))
    }

    func testRetiringUnconsumedImportsAcceptsRootsWithOrWithoutDirectoryHints() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try makeDocument(in: directory)
        let incomingPath = directory.appendingPathComponent("incoming").path
        for directoryHint in [false, true] {
            let importRoot = URL(fileURLWithPath: incomingPath, isDirectory: !directoryHint)
            let retirementRoot = URL(fileURLWithPath: incomingPath, isDirectory: directoryHint)
            let superseded = try PortableSuiteHandoff.importDocument(at: document.fileURL,
                expectedTarget: .truongScaler, directory: importRoot)
            let current = try PortableSuiteHandoff.importDocument(at: document.fileURL,
                expectedTarget: .truongScaler, directory: importRoot)
            PortableSuiteHandoff.retireUnconsumedImport(superseded, directory: retirementRoot)
            XCTAssertFalse(FileManager.default.fileExists(atPath: superseded.imageFileURLPath),
                "A directory hint must not strand a superseded import")
            XCTAssertTrue(FileManager.default.fileExists(atPath: current.imageFileURLPath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: document.fileURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("source.dng").path))
            PortableSuiteHandoff.retireUnconsumedImport(current, directory: retirementRoot)
        }
    }

    func testOnlyTheReceiversOwnInboxTransportCopyCanBeRetired() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try makeDocument(in: directory)
        let documents = directory.appendingPathComponent("app-documents")
        let inbox = documents.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let transport = inbox.appendingPathComponent("copy.truongscalerhandoff")
        try FileManager.default.copyItem(at: document.fileURL, to: transport)
        let received = try PortableSuiteHandoff.importDocument(at: transport, expectedTarget: .truongScaler,
            directory: directory.appendingPathComponent("received"))
        PortableSuiteHandoff.retireOwnedInboxCopy(document.fileURL, expectedTarget: .truongScaler, documentsDirectory: documents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.fileURL.path))
        PortableSuiteHandoff.retireOwnedInboxCopy(transport, expectedTarget: .truongScaler, documentsDirectory: documents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transport.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: received.imageFileURLPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("source.dng").path))
    }

    func testAbandonedDocumentCleanupKeepsCurrentAndUnrelatedDirectories() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try makeDocument(in: directory)
        let base = document.fileURL.deletingLastPathComponent().deletingLastPathComponent()
        let stale = base.appendingPathComponent("portable-handoff_\(UUID().uuidString)_\(UUID().uuidString)")
        let unrelated = base.appendingPathComponent("human-files")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        PortableSuiteHandoff.retireAbandonedPreparedDocuments(in: base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    /// Build a deliberately edited yet correctly checksummed external document. Validation must
    /// reject unsafe semantics even when an external producer can compute a valid digest.
    private func rewritten(_ document: Data, edit: (inout [String: Any]) throws -> Void) throws -> Data {
        let magic = Data("TruongSuiteHandoff-v1\n".utf8)
        let length = document[magic.count..<(magic.count + 4)].reduce(0) { ($0 << 8) | Int($1) }
        let oldManifest = document[(magic.count + 4)..<(magic.count + 4 + length)]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: oldManifest) as? [String: Any])
        try edit(&object)
        let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let count = UInt32(encoded.count)
        let payload = document[(magic.count + 4 + length)..<(document.count - 32)]
        let body = magic + Data([UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)]) + encoded + payload
        return body + Data(SHA256.hash(data: body))
    }
}
