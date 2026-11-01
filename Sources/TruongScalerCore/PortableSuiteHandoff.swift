import Foundation
import CryptoKit
import Darwin

extension SuiteCompanionApp {
    public var handoffDocumentTypeIdentifier: String {
        switch self {
        case .truongNoiser: return "com.iantruong.imagingsuite.handoff.noiser"
        case .truongScaler: return "com.iantruong.imagingsuite.handoff.scaler"
        }
    }
    public var handoffDocumentExtension: String {
        switch self {
        case .truongNoiser: return "truongnoiserhandoff"
        case .truongScaler: return "truongscalerhandoff"
        }
    }
}

/// An OS-transferred document carries its own bytes. It never asks another sandbox to read a
/// private path or assumes separately signed apps share an App Group. The trailing SHA-256 covers
/// the framing, manifest and image; it detects corruption, not the identity of the sending app.
public enum PortableSuiteHandoff {
    public static let maximumManifestBytes = 65_536
    public static let maximumImageBytes: UInt64 = 8 * 1024 * 1024 * 1024
    private static let magic = Data("TruongSuiteHandoff-v1\n".utf8)
    private static let chunkBytes = 2 * 1024 * 1024
    private static let processToken = UUID().uuidString

    public enum Failure: Error, LocalizedError, Sendable {
        case invalidDocument
        case wrongTarget(SuiteCompanionApp)
        case changedSource
        case checksumMismatch
        case insufficientSpace
        public var errorDescription: String? {
            switch self {
            case .invalidDocument: return "This companion-app document is incomplete or unsupported. Send the photo again from the other app."
            case .wrongTarget(let target): return "This document is for \(target.rawValue). Open it in that app instead."
            case .changedSource: return "The photo changed while its companion-app copy was being prepared. Please try again."
            case .checksumMismatch: return "The companion-app document failed its integrity check. Send the photo again."
            case .insufficientSpace: return "There is not enough free space to prepare or receive this photo. Free some space and try again."
            }
        }
    }

    /// Retain through the native Open In controller's complete send/dismissal lifetime.
    /// Only the unique directory allocated by this instance is retired; source photos are untouched.
    public final class Document: Sendable {
        public let fileURL: URL
        public let payload: SharedSuiteHandoffPayload
        private let ownedDirectory: URL
        fileprivate init(fileURL: URL, payload: SharedSuiteHandoffPayload, ownedDirectory: URL) {
            self.fileURL = fileURL; self.payload = payload; self.ownedDirectory = ownedDirectory
        }
        deinit { try? FileManager.default.removeItem(at: ownedDirectory) }
    }

    private struct Manifest: Codable {
        let version: Int
        let payload: SharedSuiteHandoffPayload
        let imageExtension: String
        let imageBytes: UInt64

        private enum CodingKeys: String, CodingKey { case version, payload, imageExtension, imageBytes }

        /// The App Group payload intentionally tolerates old missing/invalid component peaks.
        /// A new portable manifest has a stricter wire contract: inspect its actual numbers
        /// before that legacy decoder can clamp them into apparently valid metadata.
        private struct RawNumbers: Decodable {
            let globalMaxLuminance: Float
            let globalMaxLinearComponent: Float
            let upscaleFactor: Int?
        }

        init(version: Int, payload: SharedSuiteHandoffPayload, imageExtension: String, imageBytes: UInt64) {
            self.version = version; self.payload = payload
            self.imageExtension = imageExtension; self.imageBytes = imageBytes
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decode(Int.self, forKey: .version)
            let raw = try values.decode(RawNumbers.self, forKey: .payload)
            guard raw.globalMaxLuminance.isFinite, raw.globalMaxLuminance >= 0,
                  raw.globalMaxLinearComponent.isFinite,
                  raw.globalMaxLinearComponent >= max(1, raw.globalMaxLuminance),
                  raw.upscaleFactor.map({ (1...64).contains($0) }) ?? true else {
                throw Failure.invalidDocument
            }
            // Unknown legacy attribution/factors remain unknown. Forwarding from Noiser
            // is not evidence that Noiser denoised an untouched image.
            payload = try values.decode(SharedSuiteHandoffPayload.self, forKey: .payload)
            imageExtension = try values.decode(String.self, forKey: .imageExtension)
            imageBytes = try values.decode(UInt64.self, forKey: .imageBytes)
        }
    }

    public static func createDocument(
        exportedImageURL: URL, originalFileName: String,
        sourceApp: SuiteCompanionApp, targetApp: SuiteCompanionApp,
        isDenoised: Bool, isUpscaled: Bool, globalMaxLuminance: Float,
        upscaleFactor: Int?, globalMaxLinearComponent: Float,
        directory: URL, isDenoisedByNoiser: Bool? = nil,
        processingHistory: ImageProcessingHistory? = nil, expectedImageSHA256: String? = nil
    ) throws -> Document {
        var coordinationError: NSError?
        var result: Result<Document, Error>?
        NSFileCoordinator().coordinate(readingItemAt: exportedImageURL, options: [], error: &coordinationError) { source in
            result = Result {
                try writeDocument(source: source, originalFileName: originalFileName,
                    sourceApp: sourceApp, targetApp: targetApp, isDenoised: isDenoised,
                    isUpscaled: isUpscaled, globalMaxLuminance: globalMaxLuminance,
                    upscaleFactor: upscaleFactor, globalMaxLinearComponent: globalMaxLinearComponent,
                    directory: directory, isDenoisedByNoiser: isDenoisedByNoiser,
                    processingHistory: processingHistory, expectedImageSHA256: expectedImageSHA256)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure.invalidDocument }
        return try result.get()
    }

    private static func writeDocument(
        source: URL, originalFileName: String, sourceApp: SuiteCompanionApp, targetApp: SuiteCompanionApp,
        isDenoised: Bool, isUpscaled: Bool, globalMaxLuminance: Float,
        upscaleFactor: Int?, globalMaxLinearComponent: Float, directory: URL,
        isDenoisedByNoiser: Bool?, processingHistory: ImageProcessingHistory?, expectedImageSHA256: String?
    ) throws -> Document {
        let bytes = try regularFileSize(source)
        let ext = source.pathExtension.lowercased()
        guard validExtension(ext), bytes > 0, bytes <= maximumImageBytes,
              sourceApp != targetApp, originalFileName.utf8.count <= 2048,
              processingHistory.map({ $0.marker != nil }) ?? true,
              expectedImageSHA256.map({ $0.utf8.count == 64 && $0.lowercased().utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) ?? true,
              globalMaxLuminance.isFinite, globalMaxLuminance >= 0,
              globalMaxLinearComponent.isFinite, globalMaxLinearComponent >= max(1, globalMaxLuminance),
              upscaleFactor.map({ (1...64).contains($0) }) ?? true else { throw Failure.invalidDocument }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try requireSpace(bytes: bytes, at: directory)
        let owned = directory.appendingPathComponent("portable-handoff_\(processToken)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: owned) } }
        let file = owned.appendingPathComponent("Open in \(targetApp.rawValue).\(targetApp.handoffDocumentExtension)")
        let payload = SharedSuiteHandoffPayload(sourceApp: sourceApp, targetApp: targetApp,
            imageFileURLPath: "", originalFileName: originalFileName, isDenoised: isDenoised,
            isUpscaled: isUpscaled, globalMaxLuminance: globalMaxLuminance,
            upscaleFactor: upscaleFactor, globalMaxLinearComponent: globalMaxLinearComponent,
            isDenoisedByNoiser: isDenoisedByNoiser, processingHistory: processingHistory)
        let manifest = try JSONEncoder().encode(Manifest(version: 1, payload: payload, imageExtension: ext, imageBytes: bytes))
        guard manifest.count <= UInt32(maximumManifestBytes) else { throw Failure.invalidDocument }
        let count = UInt32(manifest.count)
        let prefix = magic + Data([UInt8((count >> 24) & 255), UInt8((count >> 16) & 255),
                                  UInt8((count >> 8) & 255), UInt8(count & 255)]) + manifest
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw Failure.invalidDocument }
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: file)
        defer { try? input.close(); try? output.close() }
        var hash = SHA256(); hash.update(data: prefix)
        var imageHash = SHA256()
        try output.write(contentsOf: prefix)
        var remaining = bytes
        while remaining > 0 {
            let chunk = try readExactly(input, count: Int(min(UInt64(chunkBytes), remaining)))
            hash.update(data: chunk); imageHash.update(data: chunk); try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
        guard try input.read(upToCount: 1)?.isEmpty != false,
              try regularFileSize(source) == bytes else { throw Failure.changedSource }
        let copiedImageSHA256 = imageHash.finalize().map { String(format: "%02x", $0) }.joined()
        if let expectedImageSHA256, copiedImageSHA256 != expectedImageSHA256.lowercased() { throw Failure.changedSource }
        try output.write(contentsOf: Data(hash.finalize()))
        try output.synchronize()
        complete = true
        return Document(fileURL: file, payload: payload, ownedDirectory: owned)
    }

    /// The caller holds the OS-provided security-scope grant for the complete await/copy operation.
    /// Accepted image bytes live in a unique durable directory so a saved job can resume after
    /// relaunch. Failed transfers publish no image. The manifest never controls a filesystem path.
    public static func importDocument(
        at documentURL: URL, expectedTarget: SuiteCompanionApp, directory: URL
    ) throws -> SharedSuiteHandoffPayload {
        try importDocument(at: documentURL, expectedTarget: expectedTarget, directory: directory,
            synchronizeDirectory: synchronizeDirectory)
    }

    /// Internal injection seam exercises failed directory durability without mutating global
    /// state or depending on a particular volume failure. Production uses the overload above.
    static func importDocument(
        at documentURL: URL, expectedTarget: SuiteCompanionApp, directory: URL,
        synchronizeDirectory: @escaping (URL) throws -> Void
    ) throws -> SharedSuiteHandoffPayload {
        guard documentURL.isFileURL,
              documentURL.pathExtension.lowercased() == expectedTarget.handoffDocumentExtension else {
            throw Failure.invalidDocument
        }
        var coordinationError: NSError?
        var result: Result<SharedSuiteHandoffPayload, Error>?
        NSFileCoordinator().coordinate(readingItemAt: documentURL, options: [], error: &coordinationError) { source in
            result = Result { try readDocument(source: source, expectedTarget: expectedTarget, directory: directory,
                synchronizeDirectory: synchronizeDirectory) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Failure.invalidDocument }
        return try result.get()
    }

    private static func readDocument(source: URL, expectedTarget: SuiteCompanionApp, directory: URL,
        synchronizeDirectory: (URL) throws -> Void) throws -> SharedSuiteHandoffPayload {
        let fileBytes = try regularFileSize(source)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let signature = try readExactly(input, count: magic.count)
        guard signature == magic else { throw Failure.invalidDocument }
        let lengthBytes = try readExactly(input, count: 4)
        let count = lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard count > 0, count <= maximumManifestBytes else { throw Failure.invalidDocument }
        let manifestData = try readExactly(input, count: Int(count))
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        let payload = manifest.payload
        guard manifest.version == 1, validExtension(manifest.imageExtension),
              manifest.imageBytes > 0, manifest.imageBytes <= maximumImageBytes,
              payload.imageFileURLPath.isEmpty, payload.originalFileName.utf8.count <= 2048,
              payload.sourceApp != payload.targetApp,
              payload.processingHistory.map({ $0.marker != nil }) ?? true,
              payload.globalMaxLuminance.isFinite, payload.globalMaxLuminance >= 0,
              payload.globalMaxLinearComponent.isFinite,
              payload.globalMaxLinearComponent >= max(1, payload.globalMaxLuminance),
              payload.upscaleFactor.map({ (1...64).contains($0) }) ?? true,
              payload.createdAt.timeIntervalSince1970.isFinite,
              fileBytes == UInt64(magic.count + 4 + manifestData.count + 32) + manifest.imageBytes else {
            throw Failure.invalidDocument
        }
        guard payload.targetApp == expectedTarget else { throw Failure.wrongTarget(payload.targetApp) }
        try createDurableImportRoot(directory, synchronizeDirectory: synchronizeDirectory)
        try requireSpace(bytes: manifest.imageBytes, at: directory)
        let owned = directory.appendingPathComponent("import_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: owned) } }
        let image = owned.appendingPathComponent(importedFilename(original: payload.originalFileName, extension: manifest.imageExtension))
        guard FileManager.default.createFile(atPath: image.path, contents: nil) else { throw Failure.invalidDocument }
        let output = try FileHandle(forWritingTo: image)
        defer { try? output.close() }
        var hash = SHA256(); hash.update(data: signature + lengthBytes + manifestData)
        var remaining = manifest.imageBytes
        while remaining > 0 {
            let chunk = try readExactly(input, count: Int(min(UInt64(chunkBytes), remaining)))
            hash.update(data: chunk); try output.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
        let checksum = try readExactly(input, count: 32)
        guard checksum == Data(hash.finalize()) else { throw Failure.checksumMismatch }
        guard try input.read(upToCount: 1)?.isEmpty != false,
              try regularFileSize(source) == fileBytes else { throw Failure.changedSource }
        try output.synchronize()
        // File fsync alone does not persist its directory entry or the unique import
        // directory's entry in its parent. A saved checkpoint may retain this image
        // after the Inbox transport is retired, so both links must be durable first.
        try synchronizeDirectory(owned)
        try synchronizeDirectory(directory)
        complete = true
        return SharedSuiteHandoffPayload(handoffID: payload.handoffID, sourceApp: payload.sourceApp,
            targetApp: payload.targetApp, imageFileURLPath: image.path, originalFileName: payload.originalFileName,
            isDenoised: payload.isDenoised, isUpscaled: payload.isUpscaled,
            globalMaxLuminance: payload.globalMaxLuminance, upscaleFactor: payload.upscaleFactor,
            globalMaxLinearComponent: payload.globalMaxLinearComponent, isDenoisedByNoiser: payload.isDenoisedByNoiser,
            processingHistory: payload.processingHistory, createdAt: payload.createdAt)
    }

    /// Only for an accepted import superseded before ingestion. Never retire a source used by a
    /// current/saved job, and never derive a deletion path from the document's original filename.
    public static func retireUnconsumedImport(_ payload: SharedSuiteHandoffPayload, directory: URL) {
        let image = URL(fileURLWithPath: payload.imageFileURLPath).standardizedFileURL
        let parent = image.deletingLastPathComponent()
        // Directory hints can add a trailing slash to otherwise identical file
        // URLs. Compare standardized filesystem paths so a superseded import is
        // retired regardless of how its private root URL was constructed.
        guard directory.isFileURL,
              parent.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              parent.lastPathComponent.hasPrefix("import_"),
              UUID(uuidString: String(parent.lastPathComponent.dropFirst(7))) != nil,
              validExtension(image.pathExtension),
              image.lastPathComponent == importedFilename(original: payload.originalFileName, extension: image.pathExtension) else { return }
        try? FileManager.default.removeItem(at: parent)
    }

    /// Only call for this app's private outgoing staging root. Preserve all documents created by
    /// this process (including another scene's active send); retire precisely named directories
    /// left by earlier processes whose deinitializers could not run after termination.
    public static func retireAbandonedPreparedDocuments(in directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for entry in entries {
            let parts = entry.lastPathComponent.split(separator: "_")
            guard parts.count == 3, parts[0] == "portable-handoff", String(parts[1]) != processToken,
                  UUID(uuidString: String(parts[1])) != nil, UUID(uuidString: String(parts[2])) != nil,
                  let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// iOS copies Open In documents into this app's own Documents/Inbox when opening-in-place is
    /// disabled. Once the independently owned image is verified, retire only that transport copy.
    /// Provider originals, arbitrary selected folders and the sending app's document are untouched.
    public static func retireOwnedInboxCopy(_ url: URL, expectedTarget: SuiteCompanionApp, documentsDirectory: URL) {
        let inbox = documentsDirectory.appendingPathComponent("Inbox", isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.pathExtension.lowercased() == expectedTarget.handoffDocumentExtension,
              candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == inbox,
              candidate.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL == inbox else { return }
        try? FileManager.default.removeItem(at: candidate)
    }

    private static func importedFilename(original: String, extension ext: String) -> String {
        // Retain a normal camera filename for useful output names, but never interpret separators,
        // dot paths or control characters supplied by a document producer as path instructions.
        let stem = (original as NSString).deletingPathExtension
        guard !stem.isEmpty, stem != ".", stem != "..", stem.utf8.count <= 180,
              !stem.contains("/"), !stem.contains("\\"),
              stem.rangeOfCharacter(from: .controlCharacters) == nil else { return "image." + ext }
        return stem + "." + ext
    }

    private static func validExtension(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16 && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
    }
    private static func regularFileSize(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0 else { throw Failure.invalidDocument }
        return UInt64(size)
    }
    private static func readExactly(_ file: FileHandle, count: Int) throws -> Data {
        var result = Data(); result.reserveCapacity(count)
        while result.count < count {
            guard let next = try file.read(upToCount: count - result.count), !next.isEmpty else { throw Failure.invalidDocument }
            result.append(next)
        }
        return result
    }
    private static func requireSpace(bytes: UInt64, at directory: URL) throws {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage,
           free >= 0, UInt64(free) < bytes + 64 * 1024 * 1024 { throw Failure.insufficientSpace }
    }

    /// Create only the missing app-owned directory chain, retaining each new link
    /// in its parent. Bound traversal rather than walking/syncing to the volume root.
    private static func createDurableImportRoot(_ directory: URL,
        synchronizeDirectory: (URL) throws -> Void) throws {
        let manager = FileManager.default
        var missing: [URL] = []
        var ancestor = directory.standardizedFileURL
        while !manager.fileExists(atPath: ancestor.path) {
            guard missing.count < 32 else { throw CocoaError(.fileWriteInvalidFileName) }
            missing.append(ancestor)
            let parent = ancestor.deletingLastPathComponent()
            guard parent != ancestor else { throw CocoaError(.fileWriteInvalidFileName) }
            ancestor = parent
        }
        for child in missing.reversed() {
            try manager.createDirectory(at: child, withIntermediateDirectories: false)
            try synchronizeDirectory(child.deletingLastPathComponent())
        }
    }

    static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
