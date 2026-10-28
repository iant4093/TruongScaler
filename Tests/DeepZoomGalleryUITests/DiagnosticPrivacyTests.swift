import XCTest
import Foundation
import TruongScalerCore
@testable import DeepZoomGalleryUI
final class DiagnosticPrivacyTests: XCTestCase {
    func testActualMissingFolderReasonDoesNotPublishPrivateName() async throws {
        let privateName = "Review Private Client Folder-\(UUID().uuidString)"
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(privateName)
        let result = await BlockingLibraryFolderIO().validateFolder(at: missing)
        guard case .unavailable(let reason) = result else { return XCTFail("Missing fixture must fail validation") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewDiagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = Diagnostics(configuration: DiagnosticsConfiguration(directory: dir))
        d.record(category: .app, level: .warning, code: "library.saved_folder.unavailable", message: "saved folder unavailable", fields: ["reason": reason])
        d.flush()
        let summary = d.snapshot()
        print("REVIEW_PRIVATE_FOLDER_EVENT \(summary)")
        XCTAssertFalse(summary.contains(privateName), "Production folder-failure diagnostics must not publish the private folder name from localizedDescription")
    }
    func testSpacedAbsolutePathDoesNotLeavePrivateSuffix() {
        let redacted = Diagnostics.sanitize("failure at /private/var/mobile/Containers/Data/Application/ID/Documents/Private Client Photos/ConfidentialCapture.dng")
        print("REVIEW_SPACED_PATH \(redacted)")
        XCTAssertFalse(redacted.contains("ConfidentialCapture"))
        XCTAssertFalse(redacted.contains("Client Photos"))
    }
    #if os(macOS)
    func testFailedRolloverCannotGrowCurrentLogPastConfiguredBound() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewRollover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("truongscaler.log")
        try Data(repeating: 65, count: 1020).write(to: current)
        let blockedPrevious = dir.appendingPathComponent("truongscaler.log.1", isDirectory: true)
        try FileManager.default.createDirectory(at: blockedPrevious, withIntermediateDirectories: true)
        try Data([1]).write(to: blockedPrevious.appendingPathComponent("block"))
        // Immutable previous entry: removeItem/moveItem fail while the current file remains writable.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: blockedPrevious.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blockedPrevious.path) }
        let d = Diagnostics(configuration: DiagnosticsConfiguration(fileMaxBytes: 1024, directory: dir))
        for n in 0..<80 { d.record(category: .pipeline, code: "rollover.fixture", fields: ["sequence": "\(n)"]) }
        d.flush()
        let bytes = try current.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        print("REVIEW_FAILED_ROLLOVER_BYTES \(bytes)")
        XCTAssertLessThanOrEqual(bytes, 1024, "A failed rotation must skip/drop disk output rather than append past the retention bound")
        XCTAssertFalse(d.recentEvents().isEmpty, "Disk failure must remain neutral for in-memory logging")
    }
    #endif

}
