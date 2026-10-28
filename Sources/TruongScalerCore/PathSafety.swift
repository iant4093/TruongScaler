import Foundation

/// Adapted directly from `TruongCam shared path-safety design`.
/// Lexical path containment validation so iOS `/private/var` vs `/var` symlinks never cause false containment errors.
public enum PathSafety {
    @discardableResult
    public static func assertContained(_ candidate: URL, in root: URL) throws -> URL {
        let rootComponents = normalizedComponents(of: root)
        let candidateComponents = normalizedComponents(of: candidate)
        guard !rootComponents.isEmpty,
              candidateComponents.count >= rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
            throw ScalerError.exportDestinationCreationFailed(candidate)
        }
        return candidate.standardizedFileURL
    }

    public static func safeRelativePath(_ relativePath: String) throws -> String {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty, !relativePath.hasPrefix("/") else {
            throw ScalerError.unsupportedImageFormat(relativePath)
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            if part.isEmpty || part == "." || part == ".." || part.contains("\0") {
                throw ScalerError.unsupportedImageFormat(relativePath)
            }
        }
        return parts.joined(separator: "/")
    }

    public static func childURL(in root: URL, relativePath: String) throws -> URL {
        let safe = try safeRelativePath(relativePath)
        let url = root.appendingPathComponent(safe, isDirectory: false).standardizedFileURL
        return try assertContained(url, in: root)
    }

    private static func normalizedComponents(of url: URL) -> [String] {
        var components = url.standardizedFileURL.pathComponents
        if components.count >= 3, components[0] == "/", components[1] == "private",
           components[2] == "var" || components[2] == "tmp" || components[2] == "etc" {
            components.remove(at: 1)
        }
        if components.count > 1, components.last == "/" {
            components.removeLast()
        }
        return components
    }
}
