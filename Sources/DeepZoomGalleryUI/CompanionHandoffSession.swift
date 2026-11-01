import Foundation
import TruongScalerCore

enum PreparedSuiteHandoff: Sendable {
    case appGroup(payload: SharedSuiteHandoffPayload, deepLinkURL: URL)
    case document(PortableSuiteHandoff.Document)
}

/// The native Open In presenter retains this independently of the displayed photo until the OS
/// finishes sending or the user dismisses its menu. The document owns only its private byte copy.
public final class CompanionHandoffSession: Identifiable, Sendable {
    public let id = UUID()
    let document: PortableSuiteHandoff.Document
    public var targetApp: SuiteCompanionApp { document.payload.targetApp }
    public var fileURL: URL { document.fileURL }
    init(document: PortableSuiteHandoff.Document) { self.document = document }
}

extension StudioHandoffManaging {
    /// Existing explicit App Group test adapters remain usable. Production overrides this with
    /// OS-mediated documents; it does not infer remote sandbox access from a local group lookup.
    func prepareOutgoingHandoff(
        exportedImageURL: URL, originalFileName: String, isDenoised: Bool, isUpscaled: Bool,
        globalMaxLuminance: Float, upscaleFactor: Int?, globalMaxLinearComponent: Float,
        isDenoisedByNoiser: Bool?, processingHistory: ImageProcessingHistory?, expectedImageSHA256: String?
    ) async throws -> PreparedSuiteHandoff {
        let package = try await createHandoffPackage(exportedImageURL: exportedImageURL,
            originalFileName: originalFileName, isDenoised: isDenoised, isUpscaled: isUpscaled,
            globalMaxLuminance: globalMaxLuminance, upscaleFactor: upscaleFactor,
            globalMaxLinearComponent: globalMaxLinearComponent)
        return .appGroup(payload: package.payload, deepLinkURL: package.deepLinkURL)
    }

    func retireUnconsumedHandoff(_ payload: SharedSuiteHandoffPayload) async { }
}

extension ExternalApplicationOpening {
    func openWithResult(_ url: URL) async -> Bool {
        await open(url)
        return true
    }
}
