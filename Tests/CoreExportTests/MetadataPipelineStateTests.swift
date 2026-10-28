import XCTest
import Foundation
import ImageIO
@testable import CoreExport
@testable import TruongScalerCore

/// Lead-owned integration coverage for the raster (non-DNG) pipeline-state markers.
///
/// The DNG path is covered by `DNGWriterBridgeTests`/`ExportContractTests`; these tests make sure a
/// second export of a non-denoised/upstream-Noiser image cannot inherit a stale `Denoised=true`
/// component, that unrelated user comments survive, and that the factor is derived from the actual
/// completed dimensions rather than an inherited selector/handoff value.
final class MetadataPipelineStateTests: XCTestCase {
    private func makePacket(
        userComment: String?,
        upscaledByAppFactor: Int? = nil,
        isAlreadyDenoisedBySuite: Bool = false,
        isAlreadyDenoisedByNoiser: Bool = false
    ) throws -> ImageMetadataPacket {
        var root: [String: Any] = [:]
        var exif: [String: Any] = [:]
        if let userComment {
            exif[kCGImagePropertyExifUserComment as String] = userComment
        }
        root[kCGImagePropertyExifDictionary as String] = exif
        let plist = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .binary,
            options: 0
        )
        return ImageMetadataPacket(
            sourceURL: URL(fileURLWithPath: "/tmp/IMG_0001.jpg"),
            utTypeIdentifier: "public.jpeg",
            category: .standardOpaqueRaster,
            originalWidth: 32,
            originalHeight: 24,
            rawPropertiesPlistData: plist,
            isAlreadyDenoisedBySuite: isAlreadyDenoisedBySuite,
            isAlreadyUpscaledBySuite: true,
            upscaledByAppFactor: upscaledByAppFactor,
            isAlreadyDenoisedByNoiser: isAlreadyDenoisedByNoiser
        )
    }

    private func userCommentComponents(_ properties: [CFString: Any]) -> Set<String> {
        let exif = properties[kCGImagePropertyExifDictionary] as? [String: Any]
        let comment = exif?[kCGImagePropertyExifUserComment as String] as? String ?? ""
        return Set(comment.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) })
    }

    func testRasterExportWritesExplicitFalseStateAndPreservesUnrelatedComment() throws {
        let packet = try makePacket(
            userComment: "My note;Denoised=true;UpscaledFactor=2x;NoiserDenoised=false",
            upscaledByAppFactor: nil,
            isAlreadyDenoisedBySuite: false,
            isAlreadyDenoisedByNoiser: true
        )
        let properties = MetadataReinjector.buildDestinationProperties(
            from: packet,
            upscaledWidth: 128,
            upscaledHeight: 96,
            exportFormat: .tiff16BitLZW
        )
        let components = userCommentComponents(properties)
        XCTAssertTrue(components.contains("UpscaledByApp=true"))
        XCTAssertTrue(components.contains("UpscaledFactor=4x"), "128/32 is the actual completed factor")
        XCTAssertTrue(components.contains("Denoised=false"), "stale Denoised=true must be replaced")
        XCTAssertTrue(components.contains("NoiserDenoised=true"), "upstream Noiser state must survive")
        XCTAssertFalse(components.contains("Denoised=true"))

        let exif = properties[kCGImagePropertyExifDictionary] as? [String: Any]
        let comment = exif?[kCGImagePropertyExifUserComment as String] as? String ?? ""
        XCTAssertTrue(comment.contains("My note"), "unrelated user comment text must be retained")
    }

    func testInheritedFactorCannotRelabelCompletedCanvas() throws {
        // A handoff/source may carry 2x, but the completed canvas is 16->64 (4x). The exported
        // filename/metadata must describe the artifact, not the inherited value.
        let packet = try makePacket(
            userComment: nil,
            upscaledByAppFactor: 2,
            isAlreadyDenoisedBySuite: false,
            isAlreadyDenoisedByNoiser: false
        )
        let properties = MetadataReinjector.buildDestinationProperties(
            from: packet,
            upscaledWidth: 128,
            upscaledHeight: 96,
            exportFormat: .png16Bit
        )
        let components = userCommentComponents(properties)
        XCTAssertTrue(components.contains("UpscaledFactor=4x"))
        XCTAssertFalse(components.contains("UpscaledFactor=2x"))
    }

    func testDenoisedTrueIsWrittenWhenThePipelineActuallyRan() throws {
        let packet = try makePacket(
            userComment: "Denoised=false",
            isAlreadyDenoisedBySuite: true,
            isAlreadyDenoisedByNoiser: false
        )
        let properties = MetadataReinjector.buildDestinationProperties(
            from: packet,
            upscaledWidth: 128,
            upscaledHeight: 96,
            exportFormat: .jpeg95
        )
        let components = userCommentComponents(properties)
        XCTAssertTrue(components.contains("Denoised=true"))
        XCTAssertTrue(components.contains("NoiserDenoised=false"))
    }
}
