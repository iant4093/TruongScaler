import Foundation
import TruongScalerCore

/// Resolved saved library bookmark (off-main result type).
struct ResolvedLibraryFolder: Sendable, Equatable {
    let url: URL
    let isStale: Bool
}

struct LibraryFolderIOError: Error, Sendable, Equatable {
    let message: String
}

/// Result of validating a selected library folder.
///
/// The scan root is resolved inside the same off-main validation read so the view model never
/// performs a MainActor `fileExists`/`contentsOfDirectory` after validation.
enum LibraryFolderValidation: Sendable, Equatable {
    case available(scanRoot: URL)
    case unavailable(reason: String)
}

/// Classification of a URL returned by the Files picker. The caller must open a validation grant
/// before this off-main probe so an external picker URL is readable under its own scope.
enum ImportedURLCategory: Sendable, Equatable {
    case directory(scanRoot: URL)
    case file
    case unavailable(reason: String)
}

/// Off-main filesystem seam for the saved library folder.
///
/// Contract:
/// * `resolveBookmark`/`createBookmark`/`validateFolder` may do blocking filesystem or bookmark work
///   and therefore must run off the caller's executor (production uses `BlockingIOOwner`).
/// * The caller must hold an independently owned security-scope grant open while `validateFolder`
///   performs its first metadata/listing access. The grant is released exactly once after the
///   validation await drains. `validateFolder` deliberately does not start a second scope: opening
///   the validation grant and balancing it is the view model's ownership responsibility.
protocol LibraryFolderIO: Sendable {
    func resolveBookmark(_ data: Data) async -> Result<ResolvedLibraryFolder, LibraryFolderIOError>
    func createBookmark(for url: URL) async -> Data?
    func validateFolder(at url: URL) async -> LibraryFolderValidation
    /// Classifies a Files-picker result (folder vs single file). The caller must hold a scope grant
    /// open for the URL before this probe, exactly like `validateFolder`.
    func classifyImportedURL(at url: URL) async -> ImportedURLCategory
}

/// Production implementation: every blocking folder/bookmark read runs on a dedicated serial I/O
/// queue, never on MainActor. Validation uses bounded resource metadata (not a redundant full
/// directory enumeration); the actual scan later uses its own independently owned operation grant.
struct BlockingLibraryFolderIO: LibraryFolderIO {
    private let owner = BlockingIOOwner(label: "com.truongscaler.library-folder-io")

    func resolveBookmark(_ data: Data) async -> Result<ResolvedLibraryFolder, LibraryFolderIOError> {
        await owner.runInfallible {
            do {
                let resolved = try BookmarkRootGrant.resolveBookmarkData(data)
                return .success(ResolvedLibraryFolder(url: resolved.url, isStale: resolved.isStale))
            } catch {
                return .failure(LibraryFolderIOError(message: error.localizedDescription))
            }
        }
    }

    func createBookmark(for url: URL) async -> Data? {
        await owner.runInfallible {
            // BookmarkRootGrant opens and balances the URL's security scope internally.
            try? BookmarkRootGrant.createBookmarkData(for: url)
        }
    }

    func classifyImportedURL(at url: URL) async -> ImportedURLCategory {
        await owner.runInfallible {
            do {
                // First access for a picker URL happens only after the caller opened its grant.
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
                guard values.isReadable != false,
                      FileManager.default.isReadableFile(atPath: url.path) else {
                    return .unavailable(reason: "The selected item is not readable.")
                }
                guard values.isDirectory == true else { return .file }
                return .directory(scanRoot: url)
            } catch {
                return .unavailable(reason: error.localizedDescription)
            }
        }
    }

    func validateFolder(at url: URL) async -> LibraryFolderValidation {
        await owner.runInfallible {
            do {
                // This is the first filesystem access. The caller already holds the validation
                // grant; `startAccessingSecurityScopedResource()` is therefore not called here.
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
                guard values.isDirectory == true,
                      values.isReadable != false,
                      FileManager.default.isReadableFile(atPath: url.path) else {
                    return .unavailable(
                        reason: "The folder is missing, is not a directory, or is not readable."
                    )
                }

                // Any selected folder is a recursive input root, including loose RAWs next to an
                // originals subfolder. Known application metadata is filtered by the scanner.
                return .available(scanRoot: url)
            } catch {
                return .unavailable(reason: error.localizedDescription)
            }
        }
    }
}
