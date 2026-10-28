import Foundation
import CryptoKit
import TruongScalerCore
#if canImport(Darwin)
import Darwin
#endif

public enum PhotoShareSurface: Sendable { case library, viewer }

/// A share owns private byte-for-byte snapshots until its presenting sheet actually disappears.
/// It never lends a live library URL to an extension that may outlive a folder selection.
public final class PhotoShareSession: Identifiable, Sendable {
    public let id: UUID
    public let surface: PhotoShareSurface
    public let fileURLs: [URL]
    private let directory: URL
    init(id: UUID, surface: PhotoShareSurface, fileURLs: [URL], directory: URL) {
        self.id = id; self.surface = surface; self.fileURLs = fileURLs; self.directory = directory
    }
    func retireSnapshots() { try? FileManager.default.removeItem(at: directory) }
    deinit { retireSnapshots() }
}

actor PhotoSharePreparer {
    private let io = BlockingIOOwner(label: "com.truongscaler.share-snapshot")
    func prepare(_ urls: [URL], surface: PhotoShareSurface, expectedHashes: [URL: String] = [:]) async throws -> PhotoShareSession {
        try await io.run {
            let id = UUID()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TruongScaler-share-\(id.uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            do {
                var snapshots: [URL] = []
                for (index, input) in urls.enumerated() {
                    let folder = directory.appendingPathComponent(String(index))
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    let target = folder.appendingPathComponent(input.lastPathComponent)
                    var coordinationError: NSError?, copyError: Error?
                    NSFileCoordinator().coordinate(readingItemAt: input, options: [], error: &coordinationError) { source in
                        do {
                            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                            guard values.isRegularFile == true else { throw ProcessedLibraryError.changedFile }
                            #if canImport(Darwin)
                            if clonefile(source.path, target.path, 0) != 0 {
                                try FileManager.default.copyItem(at: source, to: target)
                            }
                            #else
                            try FileManager.default.copyItem(at: source, to: target)
                            #endif
                            let copy = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                            guard copy.isRegularFile == true, copy.isSymbolicLink != true,
                                  copy.fileSize == values.fileSize else { throw ProcessedLibraryError.changedFile }
                        } catch { copyError = error }
                    }
                    if let error = coordinationError ?? copyError as NSError? { throw error }
                    if let expected = expectedHashes[input] {
                        guard try ProcessedLibraryStore.hash(target) == expected else { throw ProcessedLibraryError.changedFile }
                    }
                    snapshots.append(target)
                }
                return PhotoShareSession(id: id, surface: surface, fileURLs: snapshots, directory: directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }
    }
}
