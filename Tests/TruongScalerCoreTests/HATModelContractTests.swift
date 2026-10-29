import Foundation
import XCTest
@testable import TruongScalerCore

final class HATModelContractTests: XCTestCase {
    func testHATIdentityIsDistinctAndSurvivesTheSavedRecipe() throws {
        XCTAssertEqual(BackboneModelKind.hatSmall.rawValue, "HAT_S")
        XCTAssertEqual(BackboneModelKind.hatSmall.displayName, "HAT-S (Best)")
        XCTAssertEqual(BackboneModelKind.edsrBaseline.displayName, "EDSR (Balanced)")
        XCTAssertEqual(BackboneModelKind.quickSRNet.displayName, "QuickSRNet (Fast)")
        let recipe = UpscaleJobConfig(sourceImageURL: URL(fileURLWithPath: "/tmp/original.dng"),
            backbone: .hatSmall, naturalGrainAmount: 0.2)
        let decoded = try JSONDecoder().decode(UpscaleJobConfig.self, from: JSONEncoder().encode(recipe))
        XCTAssertEqual(decoded, recipe)
        XCTAssertEqual(decoded.scaleFactor, .x2)
        XCTAssertEqual(decoded.denoiseMode, .off)
        XCTAssertEqual(decoded.backbone, .hatSmall)
        XCTAssertNotEqual(decoded.backbone, .quickSRNet)
        XCTAssertNotEqual(decoded.backbone, .edsrBaseline)
        for opaque in ["HAT-L", "HAT_S_vNext", "HAT_S_x4"] {
            let unknown = try JSONDecoder().decode(BackboneModelKind.self, from: JSONEncoder().encode(opaque))
            XCTAssertFalse(unknown.isSupported)
            XCTAssertEqual(unknown.rawValue, opaque)
        }
    }

    func testHATUses32PixelHalosWithoutChangingExistingModelGeometry() throws {
        for tier in [DeviceTier.tierA_HighMemory, .tierB_ConstrainedMemory] {
            let legacy = TileConfiguration(tier: tier)
            let expectedSize = tier == .tierA_HighMemory ? 256 : 192
            let expectedOldOverlap = tier == .tierA_HighMemory ? 24 : 16
            for originalModel in [BackboneModelKind.quickSRNet, .edsrBaseline] {
                let oldModel = TileConfiguration(tier: tier, backbone: originalModel)
                XCTAssertEqual(oldModel, legacy)
                XCTAssertEqual(oldModel.inputTileSize, expectedSize)
                XCTAssertEqual(oldModel.inputOverlap, expectedOldOverlap)
            }
            let hat = TileConfiguration(tier: tier, backbone: .hatSmall)
            XCTAssertEqual(hat.inputTileSize, expectedSize)
            XCTAssertEqual(hat.inputOverlap, 32)
            XCTAssertEqual(hat.effectiveInputStride, expectedSize - 32)
            XCTAssertEqual(hat.outputOverlap(for: .x2), 64)
            XCTAssertEqual(hat.outputTileSize(for: .x2), expectedSize * 2)
            XCTAssertEqual(try JSONDecoder().decode(TileConfiguration.self, from: JSONEncoder().encode(hat)), hat)
        }
        let selected = HardwareTelemetry.makeTileConfiguration(overrideAvailableBytes: 2_000_000_000, backbone: .hatSmall)
        XCTAssertEqual(selected, TileConfiguration(tier: .tierB_ConstrainedMemory, backbone: .hatSmall))
    }

    func testLegacyGeometryJSONRetainsItsExactStoredHalos() throws {
        for (tier, size, overlap) in [(DeviceTier.tierA_HighMemory, 256, 24), (.tierB_ConstrainedMemory, 192, 16)] {
            let data = Data("{\"tier\":\"\(tier.rawValue)\",\"inputTileSize\":\(size),\"inputOverlap\":\(overlap)}".utf8)
            let decoded = try JSONDecoder().decode(TileConfiguration.self, from: data)
            XCTAssertEqual(decoded, TileConfiguration(tier: tier, backbone: .quickSRNet))
            XCTAssertEqual(decoded, TileConfiguration(tier: tier, backbone: .edsrBaseline))
            XCTAssertNotEqual(decoded, TileConfiguration(tier: tier, backbone: .hatSmall))
            let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
            XCTAssertEqual(roundTrip?["inputOverlap"] as? Int, overlap)
            XCTAssertEqual(roundTrip?["inputTileSize"] as? Int, size)
            XCTAssertEqual(roundTrip?.count, 3, "No new field is required to decode an existing checkpoint")
        }
    }
}
