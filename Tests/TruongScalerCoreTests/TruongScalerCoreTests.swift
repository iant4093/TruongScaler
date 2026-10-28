import Foundation
import XCTest
@testable import TruongScalerCore

final class TruongScalerCoreTests: XCTestCase {
    func testOpaquePreviousModelIdentifiersRemainLosslessWithoutBecomingSelectable() throws {
        for raw in ["retired-family-v1", "unavailable-family-v2"] {
            let data = try JSONEncoder().encode(raw)
            let decoded = try JSONDecoder().decode(BackboneModelKind.self, from: data)
            XCTAssertEqual(decoded.rawValue, raw)
            XCTAssertEqual(decoded.displayName, "Previous model")
            XCTAssertEqual(try JSONEncoder().encode(decoded), data)
            XCTAssertFalse(BackboneModelKind.allCases.contains(decoded))
        }
        XCTAssertEqual(BackboneModelKind.allCases, [.quickSRNet, .edsrBaseline])
    }

    func testTierSelectionAndTileMath() {
        let tierA = HardwareTelemetry.resolveDeviceTier(overrideAvailableBytes: 3_000_000_000)
        XCTAssertEqual(tierA, .tierA_HighMemory)
        let configA = TileConfiguration(tier: tierA)
        XCTAssertEqual(configA.inputTileSize, 256)
        XCTAssertEqual(configA.inputOverlap, 24)
        XCTAssertEqual(configA.effectiveInputStride, 232)
        XCTAssertEqual(configA.outputTileSize(for: .x4), 1024)
        XCTAssertEqual(configA.outputOverlap(for: .x4), 96)

        let tierB = HardwareTelemetry.resolveDeviceTier(overrideAvailableBytes: 2_000_000_000)
        XCTAssertEqual(tierB, .tierB_ConstrainedMemory)
        let configB = TileConfiguration(tier: tierB)
        XCTAssertEqual(configB.inputTileSize, 192)
        XCTAssertEqual(configB.inputOverlap, 16)
        XCTAssertEqual(configB.effectiveInputStride, 176)
        XCTAssertEqual(configB.outputTileSize(for: .x2), 384)
        XCTAssertEqual(configB.outputOverlap(for: .x2), 32)
    }

    func testRowAlignmentAndMMapByteCalculation() {
        XCTAssertEqual(HardwareTelemetry.alignedRowBytes(width: 4032, bytesPerPixel: 8), 32256)
        XCTAssertEqual(HardwareTelemetry.alignedRowBytes(width: 4032, bytesPerPixel: 8) % 64, 0)
        XCTAssertEqual(HardwareTelemetry.alignedRowBytes(width: 1001, bytesPerPixel: 8), 8064)
        XCTAssertEqual(HardwareTelemetry.requiredMMapBytes(width: 1001, height: 100, bytesPerPixel: 8), 806_400)
    }

    func testSmartExportRoutingAndAutoDenoise() {
        let rawPacket = ImageMetadataPacket(
            sourceURL: URL(fileURLWithPath: "/tmp/photo.cr3"),
            utTypeIdentifier: "com.canon.cr3-raw-image",
            category: .cameraRAW,
            originalWidth: 6000,
            originalHeight: 4000,
            isoSpeedRatings: 1600
        )
        XCTAssertEqual(rawPacket.resolvedExportFormat(from: .autoMatchSource), .linearDNG16Bit)
        XCTAssertTrue(rawPacket.shouldRunDenoiser(mode: .auto))

        let denoisedSuitePacket = ImageMetadataPacket(
            sourceURL: URL(fileURLWithPath: "/tmp/photo_denoised.dng"),
            utTypeIdentifier: "com.adobe.raw-image",
            category: .cameraRAW,
            originalWidth: 6000,
            originalHeight: 4000,
            isoSpeedRatings: 3200,
            isAlreadyDenoisedBySuite: true
        )
        // Must skip redundant pre-denoising when already denoised by TruongNoiser
        XCTAssertFalse(denoisedSuitePacket.shouldRunDenoiser(mode: .auto))

        let noiserPacket = ImageMetadataPacket(
            sourceURL: URL(fileURLWithPath: "/tmp/photo_noiser.dng"),
            utTypeIdentifier: "com.adobe.raw-image",
            category: .cameraRAW,
            originalWidth: 6000,
            originalHeight: 4000,
            isoSpeedRatings: 3200,
            isAlreadyDenoisedByNoiser: true
        )
        XCTAssertFalse(noiserPacket.shouldRunDenoiser(mode: .auto))

        let hdrPacket = ImageMetadataPacket(
            sourceURL: URL(fileURLWithPath: "/tmp/hdr.heic"),
            utTypeIdentifier: "public.heic",
            category: .hdrHEIC,
            originalWidth: 4032,
            originalHeight: 3024,
            bitsPerComponent: 10
        )
        XCTAssertEqual(hdrPacket.resolvedExportFormat(from: .autoMatchSource), .heic10BitHDR)

        let alphaPacket = ImageMetadataPacket(
            sourceURL: URL(fileURLWithPath: "/tmp/graphic.png"),
            utTypeIdentifier: "public.png",
            category: .standardAlphaRaster,
            originalWidth: 1024,
            originalHeight: 1024,
            hasAlpha: true,
            isoSpeedRatings: 100
        )
        XCTAssertEqual(alphaPacket.resolvedExportFormat(from: .autoMatchSource), .png16Bit)
        XCTAssertFalse(alphaPacket.shouldRunDenoiser(mode: .auto))
    }

    func testCheckpointSerializationRoundTrip() throws {
        let jobID = UUID()
        let config = UpscaleJobConfig(
            id: jobID,
            sourceImageURL: URL(fileURLWithPath: "/tmp/input.dng"),
            scaleFactor: .x4,
            backbone: .quickSRNet,
            denoiseMode: .auto,
            naturalGrainAmount: 0.20,
            exportFormat: .linearDNG16Bit
        )
        let checkpoint = JobCheckpointState(
            jobID: jobID,
            config: config,
            tileConfig: TileConfiguration(tier: .tierA_HighMemory),
            sourceWidth: 4032,
            sourceHeight: 3024,
            paddedSourceWidth: 4032,
            paddedSourceHeight: 3024,
            outputWidth: 16128,
            outputHeight: 12096,
            globalMaxLuminance: 6.5,
            didRunDenoise: true,
            sourceMMapFileName: "src.bin",
            outputMMapFileName: "out.bin",
            metadataPacketFileName: "meta.json",
            lastCompletedTileIndex: 17,
            totalTiles: 252,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(checkpoint)
        let decoded = try JSONDecoder().decode(JobCheckpointState.self, from: data)
        XCTAssertEqual(checkpoint, decoded)
    }

    func testAppGroupHandoffRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestHandoff_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let dummyDNG = tempDir.appendingPathComponent("sample.dng")
        try Data([0x49, 0x49, 0x2A, 0x00]).write(to: dummyDNG)

        // Contract §4: consume-incoming validation requires the target app to be TruongScaler,
        // so the historic round-trip fixture (previously targeting Noiser) now targets Scaler.
        let (payload, deepLink) = try AppGroupHandoffManager.createHandoffPackage(
            exportedImageURL: dummyDNG,
            originalFileName: "IMG_0001.DNG",
            sourceApp: .truongNoiser,
            targetApp: .truongScaler,
            isDenoised: false,
            isUpscaled: true,
            globalMaxLuminance: 4.2,
            overrideBaseDirectory: tempDir
        )
        XCTAssertEqual(deepLink.scheme, "truongscaler")
        let consumed = try AppGroupHandoffManager.consumeIncomingHandoff(from: deepLink, overrideBaseDirectory: tempDir)
        XCTAssertEqual(payload, consumed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: consumed.imageFileURLPath))
    }

    // MARK: - Handoff repair coverage

    func testHistoryMarkerIsCanonicalAndRetainsOpaqueStepFacts() throws {
        let id = UUID(uuidString: "D640B6AA-628D-42BA-B468-16AC5D197833")!
        let step = ImageProcessingHistory.Step(id: id, app: "com.example.future-editor",
            operation: "future:detail-pass", model: "UnknownModel_V9/Native-2x", scale: 2,
            date: Date(timeIntervalSinceReferenceDate: 1234.25),
            inputWidth: 48, inputHeight: 32, outputWidth: 96, outputHeight: 64)
        let expected = ImageProcessingHistory(steps: [step])
        let marker = try XCTUnwrap(expected.marker)
        XCTAssertEqual(Set((0..<64).compactMap { _ in expected.marker }), Set([marker]))
        XCTAssertEqual(ImageProcessingHistory.parse(marker), expected)
        let encoded = try XCTUnwrap(Data(base64Encoded: String(marker.dropFirst("ProcessingHistoryV1=".count))))
        let canonical = JSONEncoder(); canonical.outputFormatting = [.sortedKeys]
        XCTAssertEqual(encoded, try canonical.encode(expected))

        // Historic key order and unrecognized additive JSON fields are still accepted. Unknown
        // app/operation/model strings are opaque facts, not aliases for a supported Scaler model.
        let historicJSON = """
        {"futureTopLevel":{"hint":true},"steps":[{"outputHeight":64,"futureStepField":17,"operation":"future:detail-pass","inputHeight":32,"date":1234.25,"app":"com.example.future-editor","scale":2,"outputWidth":96,"id":"\(id.uuidString)","model":"UnknownModel_V9/Native-2x","inputWidth":48}],"version":1}
        """
        let historicMarker = "ProcessingHistoryV1=" + Data(historicJSON.utf8).base64EncodedString()
        let decoded = try XCTUnwrap(ImageProcessingHistory.parse(historicMarker))
        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(decoded.steps[0].model, "UnknownModel_V9/Native-2x")
        XCTAssertEqual(decoded.marker, marker)
    }

    func testFailedHandoffPublicationRemovesOnlyItsUnpublishedCopy() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handoffDirectory = directory.appendingPathComponent("Handoffs", isDirectory: true)
        let exportedURL = directory.appendingPathComponent("source.dng")
        let bytes = Data(repeating: 0x6C, count: 4096)
        try bytes.write(to: exportedURL)
        let (previous, deepLink) = try AppGroupHandoffManager.createHandoffPackage(
            exportedImageURL: exportedURL, originalFileName: "source.dng",
            sourceApp: .truongNoiser, targetApp: .truongScaler,
            isDenoised: true, isUpscaled: false, globalMaxLuminance: 1,
            overrideBaseDirectory: handoffDirectory
        )
        func packageBytes() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
                at: handoffDirectory, includingPropertiesForKeys: nil
            ).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        }
        let saved = try packageBytes()
        for invalidLuminance in [Float.nan, Float.infinity] {
            // Encoding fails after the real App Group byte copy. A failed operation must not
            // retain that DNG-sized orphan or remove any already published handoff.
            XCTAssertThrowsError(try AppGroupHandoffManager.createHandoffPackage(
                exportedImageURL: exportedURL, originalFileName: "source.dng",
                sourceApp: .truongNoiser, targetApp: .truongScaler,
                isDenoised: true, isUpscaled: false, globalMaxLuminance: invalidLuminance,
                overrideBaseDirectory: handoffDirectory
            ))
            XCTAssertEqual(try packageBytes(), saved)
            XCTAssertEqual(try Data(contentsOf: exportedURL), bytes)
        }
        XCTAssertEqual(try AppGroupHandoffManager.consumeIncomingHandoff(
            from: deepLink, overrideBaseDirectory: handoffDirectory
        ), previous)
    }

    func testHandoffRoundTripCarriesPipelineStateAndCopiesBytes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handoffDirectory = directory.appendingPathComponent("Handoffs", isDirectory: true)
        try FileManager.default.createDirectory(at: handoffDirectory, withIntermediateDirectories: true)

        let exportedURL = directory.appendingPathComponent("upscaled.dng")
        let bytes = Data(repeating: 0x5A, count: 4096)
        try bytes.write(to: exportedURL)

        let (payload, deepLink) = try AppGroupHandoffManager.createHandoffPackage(
            exportedImageURL: exportedURL,
            originalFileName: "IMG_0002.DNG",
            sourceApp: .truongNoiser,
            targetApp: .truongScaler,
            isDenoised: true,
            isUpscaled: true,
            globalMaxLuminance: 2.5,
            upscaleFactor: 4,
            globalMaxLinearComponent: 4.0,
            overrideBaseDirectory: handoffDirectory
        )
        XCTAssertEqual(deepLink.scheme, "truongscaler")
        XCTAssertEqual(payload.upscaleFactor, 4)
        XCTAssertEqual(payload.globalMaxLinearComponent, 4.0)
        XCTAssertEqual(payload.globalMaxLuminance, 2.5)
        // Byte copy semantics, not zero-copy: the staged path is a distinct file with equal bytes.
        XCTAssertNotEqual(
            URL(fileURLWithPath: payload.imageFileURLPath).standardizedFileURL,
            exportedURL.standardizedFileURL
        )
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: payload.imageFileURLPath)), bytes)

        let consumed = try AppGroupHandoffManager.consumeIncomingHandoff(
            from: deepLink,
            overrideBaseDirectory: handoffDirectory
        )
        XCTAssertEqual(consumed, payload)
        XCTAssertEqual(consumed.targetApp, .truongScaler)
        XCTAssertTrue(consumed.isDenoised)
        XCTAssertEqual(consumed.upscaleFactor, 4)
        XCTAssertEqual(consumed.globalMaxLinearComponent, 4.0, accuracy: 1e-6)
    }

    func testLegacyHandoffManifestDecodesAdditiveDefaults() throws {
        let handoffID = UUID()
        let stagedURL = "/tmp/legacy_handoff.dng"
        let legacyJSON: [String: Any] = [
            "handoffID": handoffID.uuidString,
            "sourceApp": "TruongNoiser",
            "targetApp": "TruongScaler",
            "imageFileURLPath": stagedURL,
            "originalFileName": "IMG_0003.DNG",
            "isDenoised": false,
            "isUpscaled": true,
            "globalMaxLuminance": 3.5,
            "createdAt": 0.0,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyJSON)
        let decoded = try JSONDecoder().decode(SharedSuiteHandoffPayload.self, from: data)
        XCTAssertNil(decoded.upscaleFactor)
        XCTAssertEqual(decoded.globalMaxLinearComponent, 3.5, accuracy: 1e-6)
        XCTAssertFalse(decoded.isDenoised)
        XCTAssertTrue(decoded.isUpscaled)
    }

    func testConsumeRejectsWrongTargetDifferentIdentityAndOutsideContainment() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handoffDirectory = directory.appendingPathComponent("Handoffs", isDirectory: true)
        try FileManager.default.createDirectory(at: handoffDirectory, withIntermediateDirectories: true)
        let stagedURL = handoffDirectory.appendingPathComponent("staged.dng")
        try Data([0x49, 0x49, 0x2A, 0x00]).write(to: stagedURL)

        func writeManifest(_ payload: SharedSuiteHandoffPayload, name: String) throws -> URL {
            let url = handoffDirectory.appendingPathComponent(name)
            try JSONEncoder().encode(payload).write(to: url)
            return url
        }
        func deepLink(_ id: UUID) -> URL {
            URL(string: "truongscaler://handoff?id=\(id.uuidString)")!
        }
        let base = SharedSuiteHandoffPayload(
            sourceApp: .truongNoiser,
            targetApp: .truongScaler,
            imageFileURLPath: stagedURL.path,
            originalFileName: "IMG_0004.DNG",
            isDenoised: false,
            isUpscaled: false,
            globalMaxLuminance: 1.0
        )

        // Wrong target app.
        let wrongTarget = SharedSuiteHandoffPayload(
            handoffID: base.handoffID,
            sourceApp: .truongNoiser,
            targetApp: .truongNoiser,
            imageFileURLPath: stagedURL.path,
            originalFileName: "IMG_0004.DNG",
            isDenoised: false,
            isUpscaled: false,
            globalMaxLuminance: 1.0
        )
        _ = try writeManifest(wrongTarget, name: "handoff_\(wrongTarget.handoffID.uuidString).json")
        XCTAssertThrowsError(try AppGroupHandoffManager.consumeIncomingHandoff(
            from: deepLink(wrongTarget.handoffID),
            overrideBaseDirectory: handoffDirectory
        )) { error in
            guard case ScalerError.unsupportedImageFormat(let reason) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("not TruongScaler"))
        }

        // Payload identity does not match the manifest filename requested by the deep link.
        let mismatched = SharedSuiteHandoffPayload(
            handoffID: base.handoffID,
            sourceApp: .truongNoiser,
            targetApp: .truongScaler,
            imageFileURLPath: stagedURL.path,
            originalFileName: "IMG_0004.DNG",
            isDenoised: false,
            isUpscaled: false,
            globalMaxLuminance: 1.0
        )
        let requestedID = UUID()
        _ = try writeManifest(mismatched, name: "handoff_\(requestedID.uuidString).json")
        XCTAssertThrowsError(try AppGroupHandoffManager.consumeIncomingHandoff(
            from: deepLink(requestedID),
            overrideBaseDirectory: handoffDirectory
        )) { error in
            XCTAssertEqual(error as? ScalerError, .fileNotFound(
                handoffDirectory.appendingPathComponent("handoff_\(requestedID.uuidString).json")
            ))
        }

        // Staged path outside the resolved Handoffs directory.
        let outsideURL = directory.appendingPathComponent("outside.dng")
        try Data([1, 2, 3, 4]).write(to: outsideURL)
        let outsidePayload = SharedSuiteHandoffPayload(
            handoffID: UUID(),
            sourceApp: .truongNoiser,
            targetApp: .truongScaler,
            imageFileURLPath: outsideURL.path,
            originalFileName: "IMG_0004.DNG",
            isDenoised: false,
            isUpscaled: false,
            globalMaxLuminance: 1.0
        )
        _ = try writeManifest(outsidePayload, name: "handoff_\(outsidePayload.handoffID.uuidString).json")
        XCTAssertThrowsError(try AppGroupHandoffManager.consumeIncomingHandoff(
            from: deepLink(outsidePayload.handoffID),
            overrideBaseDirectory: handoffDirectory
        )) { error in
            guard case ScalerError.exportDestinationCreationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        // A symlink inside Handoffs that resolves outside must be rejected.
        let symlinkURL = handoffDirectory.appendingPathComponent("escape.dng")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideURL)
        let symlinkPayload = SharedSuiteHandoffPayload(
            handoffID: UUID(),
            sourceApp: .truongNoiser,
            targetApp: .truongScaler,
            imageFileURLPath: symlinkURL.path,
            originalFileName: "IMG_0004.DNG",
            isDenoised: false,
            isUpscaled: false,
            globalMaxLuminance: 1.0
        )
        _ = try writeManifest(symlinkPayload, name: "handoff_\(symlinkPayload.handoffID.uuidString).json")
        XCTAssertThrowsError(try AppGroupHandoffManager.consumeIncomingHandoff(
            from: deepLink(symlinkPayload.handoffID),
            overrideBaseDirectory: handoffDirectory
        )) { error in
            guard case ScalerError.exportDestinationCreationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        // Missing and empty staged files.
        let missingPayload = SharedSuiteHandoffPayload(
            handoffID: UUID(),
            sourceApp: .truongNoiser,
            targetApp: .truongScaler,
            imageFileURLPath: handoffDirectory.appendingPathComponent("missing.dng").path,
            originalFileName: "IMG_0004.DNG",
            isDenoised: false,
            isUpscaled: false,
            globalMaxLuminance: 1.0
        )
        _ = try writeManifest(missingPayload, name: "handoff_\(missingPayload.handoffID.uuidString).json")
        XCTAssertThrowsError(try AppGroupHandoffManager.consumeIncomingHandoff(
            from: deepLink(missingPayload.handoffID),
            overrideBaseDirectory: handoffDirectory
        ))

        let emptyURL = handoffDirectory.appendingPathComponent("empty.dng")
        try Data().write(to: emptyURL)
        let emptyPayload = SharedSuiteHandoffPayload(
            handoffID: UUID(),
            sourceApp: .truongNoiser,
            targetApp: .truongScaler,
            imageFileURLPath: emptyURL.path,
            originalFileName: "IMG_0004.DNG",
            isDenoised: false,
            isUpscaled: false,
            globalMaxLuminance: 1.0
        )
        _ = try writeManifest(emptyPayload, name: "handoff_\(emptyPayload.handoffID.uuidString).json")
        XCTAssertThrowsError(try AppGroupHandoffManager.consumeIncomingHandoff(
            from: deepLink(emptyPayload.handoffID),
            overrideBaseDirectory: handoffDirectory
        ))
    }

    func testProductionHandoffWithoutAppGroupThrowsActionableError() throws {
        XCTAssertThrowsError(try AppGroupHandoffManager.resolvedHandoffBaseDirectory(
            overrideDirectory: nil,
            appGroupContainerURL: nil
        )) { error in
            XCTAssertEqual(
                error as? ScalerError,
                .appGroupUnavailable(identifier: AppGroupHandoffManager.appGroupIdentifier)
            )
            XCTAssertTrue((error as? ScalerError)?.errorDescription?.contains("App Group") ?? false)
        }
        // The production wrapper always goes through that resolver; the unentitled macOS test
        // runner returns nil from FileManager. Only assert the error shape if it throws, so this
        // test never depends on host entitlements.
        do {
            let resolved = try AppGroupHandoffManager.handoffBaseDirectory(overrideDirectory: nil)
            XCTAssertTrue(resolved.path.contains("Handoffs"))
        } catch {
            XCTAssertEqual(
                error as? ScalerError,
                .appGroupUnavailable(identifier: AppGroupHandoffManager.appGroupIdentifier)
            )
        }
    }

    func testAppGroupContainerResolutionUsesHandoffsDirectory() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let resolved = try AppGroupHandoffManager.resolvedHandoffBaseDirectory(
            overrideDirectory: nil,
            appGroupContainerURL: container
        )
        XCTAssertEqual(resolved.lastPathComponent, "Handoffs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
    }

    // MARK: - Metadata packet pipeline state

    func testImageMetadataPacketPipelineStateRoundTripAndAdditiveDefaults() throws {
        let packet = ImageMetadataPacket(
            sourceURL: URL(fileURLWithPath: "/tmp/linear.dng"),
            utTypeIdentifier: "com.adobe.raw-image",
            category: .cameraRAW,
            originalWidth: 100,
            originalHeight: 50,
            rawParameters: CameraRAWParameters(cameraMake: "TruongCam", cameraModel: "Model X"),
            isAlreadyDenoisedBySuite: false,
            isAlreadyUpscaledBySuite: true,
            isLinearDNG: true,
            upscaledByAppFactor: 4,
            isAlreadyDenoisedByNoiser: true,
            linearHeadroomScale: 4.0,
            hasSuiteLinearDNGMarker: true,
            hdrGainMapAuxiliaryType: .isoGainMap
        )
        let data = try JSONEncoder().encode(packet)
        let decoded = try JSONDecoder().decode(ImageMetadataPacket.self, from: data)
        XCTAssertEqual(decoded, packet)
        XCTAssertEqual(decoded.upscaledByAppFactor, 4)
        XCTAssertTrue(decoded.isAlreadyDenoisedByNoiser)
        XCTAssertEqual(decoded.linearHeadroomScale, 4.0)
        XCTAssertTrue(decoded.hasSuiteLinearDNGMarker)
        XCTAssertEqual(decoded.hdrGainMapAuxiliaryType, .isoGainMap)

        // Older checkpoint JSON without the additive keys decodes with defaults.
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["upscaledByAppFactor", "isAlreadyDenoisedByNoiser", "linearHeadroomScale",
                    "hasSuiteLinearDNGMarker", "hdrGainMapAuxiliaryType"] {
            object.removeValue(forKey: key)
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(ImageMetadataPacket.self, from: legacyData)
        XCTAssertNil(legacy.upscaledByAppFactor)
        XCTAssertFalse(legacy.isAlreadyDenoisedByNoiser)
        XCTAssertNil(legacy.linearHeadroomScale)
        XCTAssertFalse(legacy.hasSuiteLinearDNGMarker)
        XCTAssertNil(legacy.hdrGainMapAuxiliaryType)

        // The two gain-map auxiliary types are recorded distinctly and round-trip.
        let legacyGainMapPacket = ImageMetadataPacket(
            sourceURL: URL(fileURLWithPath: "/tmp/legacy_gainmap.heic"),
            utTypeIdentifier: "public.heic",
            category: .hdrHEIC,
            originalWidth: 10,
            originalHeight: 10,
            hdrGainMapAuxiliaryType: .legacyHDRGainMap
        )
        let legacyGainMapData = try JSONEncoder().encode(legacyGainMapPacket)
        let legacyGainMapDecoded = try JSONDecoder().decode(ImageMetadataPacket.self, from: legacyGainMapData)
        XCTAssertEqual(legacyGainMapDecoded.hdrGainMapAuxiliaryType, .legacyHDRGainMap)
        XCTAssertNotEqual(HDRGainMapAuxiliaryType.legacyHDRGainMap, .isoGainMap)
    }

    func testApplyingSuiteHandoffUpdatesPipelineState() {
        let packet = ImageMetadataPacket(
            sourceURL: URL(fileURLWithPath: "/tmp/source.dng"),
            utTypeIdentifier: "com.adobe.raw-image",
            category: .cameraRAW,
            originalWidth: 100,
            originalHeight: 50
        )
        let applied = packet.applyingSuiteHandoff(
            isDenoised: true,
            isUpscaled: true,
            upscaleFactor: 4,
            linearHeadroomScale: 3.75,
            denoisedByNoiser: true
        )
        XCTAssertTrue(applied.isAlreadyDenoisedBySuite)
        XCTAssertTrue(applied.isAlreadyUpscaledBySuite)
        XCTAssertEqual(applied.upscaledByAppFactor, 4)
        XCTAssertTrue(applied.isAlreadyDenoisedByNoiser)
        XCTAssertEqual(applied.linearHeadroomScale, 3.75)
        // Applying false clears the stale flag (explicit false round-trip).
        let cleared = applied.withPipelineState(isDenoised: false, isUpscaled: false)
        XCTAssertFalse(cleared.isAlreadyDenoisedBySuite)
        XCTAssertFalse(cleared.isAlreadyUpscaledBySuite)
        XCTAssertEqual(cleared.linearHeadroomScale, 3.75)
    }

    // MARK: - Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TruongScalerCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
