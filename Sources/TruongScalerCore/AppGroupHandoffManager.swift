import Foundation

/// Companion app identifier in the ImagingSuite (`docs/DEVELOPMENT.md` Section 4.5).
public enum SuiteCompanionApp: String, Codable, Sendable {
    case truongNoiser = "TruongNoiser"
    case truongScaler = "TruongScaler"

    public var urlScheme: String {
        switch self {
        case .truongNoiser: return "truongnoiser"
        case .truongScaler: return "truongscaler"
        }
    }
}

/// Byte-copying handoff manifest written into `group.com.iantruong.imagingsuite`
/// (`docs/DEVELOPMENT.md` Section 4.5).
///
/// The staged image is produced with `FileManager.copyItem`; the handoff is **not** zero-copy.
/// The three additive pipeline fields decode with historic defaults (nil / 1.0) so manifests
/// written before the repair still load.
public struct SharedSuiteHandoffPayload: Codable, Sendable, Equatable {
    public let handoffID: UUID
    public let sourceApp: SuiteCompanionApp
    public let targetApp: SuiteCompanionApp
    public let imageFileURLPath: String
    public let originalFileName: String
    public let isDenoised: Bool
    public let isUpscaled: Bool
    public let globalMaxLuminance: Float
    /// Actual completed upscale factor, or nil when the upstream app did not upscale.
    public let upscaleFactor: Int?
    /// Maximum nonnegative linear RGB component of the processed image (>= globalMaxLuminance).
    public let globalMaxLinearComponent: Float
    public let createdAt: Date

    public init(
        handoffID: UUID = UUID(),
        sourceApp: SuiteCompanionApp,
        targetApp: SuiteCompanionApp,
        imageFileURLPath: String,
        originalFileName: String,
        isDenoised: Bool,
        isUpscaled: Bool,
        globalMaxLuminance: Float,
        upscaleFactor: Int? = nil,
        globalMaxLinearComponent: Float = 1.0,
        createdAt: Date = Date()
    ) {
        self.handoffID = handoffID
        self.sourceApp = sourceApp
        self.targetApp = targetApp
        self.imageFileURLPath = imageFileURLPath
        self.originalFileName = originalFileName
        self.isDenoised = isDenoised
        self.isUpscaled = isUpscaled
        self.globalMaxLuminance = globalMaxLuminance
        self.upscaleFactor = upscaleFactor
        self.globalMaxLinearComponent = globalMaxLinearComponent.isFinite && globalMaxLinearComponent > 0
            ? max(globalMaxLinearComponent, globalMaxLuminance)
            : max(1.0, globalMaxLuminance)
        self.createdAt = createdAt
    }

    /// Session state carried by this payload, ready for `ImageMetadataPacket.merging` and
    /// `UpscaleJobConfig.sessionState`.
    public var pipelineSessionState: PipelineSessionState {
        PipelineSessionState(
            isDenoised: isDenoised,
            isUpscaled: isUpscaled,
            upscaleFactor: upscaleFactor,
            linearHeadroomScale: globalMaxLinearComponent,
            isDenoisedByNoiser: sourceApp == .truongNoiser ? isDenoised : nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case handoffID
        case sourceApp
        case targetApp
        case imageFileURLPath
        case originalFileName
        case isDenoised
        case isUpscaled
        case globalMaxLuminance
        case upscaleFactor
        case globalMaxLinearComponent
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        handoffID = try container.decode(UUID.self, forKey: .handoffID)
        sourceApp = try container.decode(SuiteCompanionApp.self, forKey: .sourceApp)
        targetApp = try container.decode(SuiteCompanionApp.self, forKey: .targetApp)
        imageFileURLPath = try container.decode(String.self, forKey: .imageFileURLPath)
        originalFileName = try container.decodeIfPresent(String.self, forKey: .originalFileName) ?? ""
        isDenoised = try container.decodeIfPresent(Bool.self, forKey: .isDenoised) ?? false
        isUpscaled = try container.decodeIfPresent(Bool.self, forKey: .isUpscaled) ?? false
        let luminance = try container.decodeIfPresent(Float.self, forKey: .globalMaxLuminance) ?? 1.0
        globalMaxLuminance = luminance
        upscaleFactor = try container.decodeIfPresent(Int.self, forKey: .upscaleFactor)
        let component = try container.decodeIfPresent(Float.self, forKey: .globalMaxLinearComponent)
            ?? luminance
        globalMaxLinearComponent = component.isFinite && component > 0 ? max(component, luminance) : max(1.0, luminance)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(handoffID, forKey: .handoffID)
        try container.encode(sourceApp, forKey: .sourceApp)
        try container.encode(targetApp, forKey: .targetApp)
        try container.encode(imageFileURLPath, forKey: .imageFileURLPath)
        try container.encode(originalFileName, forKey: .originalFileName)
        try container.encode(isDenoised, forKey: .isDenoised)
        try container.encode(isUpscaled, forKey: .isUpscaled)
        try container.encode(globalMaxLuminance, forKey: .globalMaxLuminance)
        try container.encodeIfPresent(upscaleFactor, forKey: .upscaleFactor)
        try container.encode(globalMaxLinearComponent, forKey: .globalMaxLinearComponent)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// Manages cross-app file handoffs via `group.com.iantruong.imagingsuite`
/// (`docs/DEVELOPMENT.md` Section 4.5).
///
/// The staged image is a byte copy (`copyItem`) into the shared `Handoffs` directory; this is
/// not a zero-copy file handoff. Production always requires the real App Group container:
/// when it is unavailable `ScalerError.appGroupUnavailable` is thrown and no app-private
/// temporary fallback is used. Tests and explicit callers may supply an override directory.
public struct AppGroupHandoffManager: Sendable {
    public static let appGroupIdentifier = "group.com.iantruong.imagingsuite"

    /// Resolves the `Handoffs` directory, creating it when needed.
    ///
    /// - Parameter overrideDirectory: explicit test/integration override; skips the App Group
    ///   lookup entirely. Production callers pass `nil`.
    public static func handoffBaseDirectory(overrideDirectory: URL? = nil) throws -> URL {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
        return try resolvedHandoffBaseDirectory(
            overrideDirectory: overrideDirectory,
            appGroupContainerURL: containerURL
        )
    }

    /// Testable resolver. Production passes the real `containerURL`; tests pass `nil` to prove
    /// the missing-App-Group error without depending on entitlements, or a temporary directory
    /// to exercise the group-container layout.
    public static func resolvedHandoffBaseDirectory(
        overrideDirectory: URL?,
        appGroupContainerURL: URL?
    ) throws -> URL {
        let base: URL
        if let overrideDirectory {
            base = overrideDirectory
        } else {
            guard let appGroupContainerURL else {
                throw ScalerError.appGroupUnavailable(identifier: appGroupIdentifier)
            }
            base = appGroupContainerURL.appendingPathComponent("Handoffs", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            if overrideDirectory != nil {
                throw ScalerError.exportDestinationCreationFailed(base)
            }
            // The group container exists but is not usable by this process (missing entitlement,
            // sandbox denial, unwritable container). Never fall back to app-private storage.
            throw ScalerError.appGroupUnavailable(identifier: appGroupIdentifier)
        }
        return base
    }

    public static func createHandoffPackage(
        exportedImageURL: URL,
        originalFileName: String,
        sourceApp: SuiteCompanionApp,
        targetApp: SuiteCompanionApp,
        isDenoised: Bool,
        isUpscaled: Bool,
        globalMaxLuminance: Float,
        upscaleFactor: Int? = nil,
        globalMaxLinearComponent: Float? = nil,
        overrideBaseDirectory: URL? = nil
    ) throws -> (payload: SharedSuiteHandoffPayload, deepLinkURL: URL) {
        guard FileManager.default.fileExists(atPath: exportedImageURL.path) else {
            throw ScalerError.fileNotFound(exportedImageURL)
        }
        let baseDir = try handoffBaseDirectory(overrideDirectory: overrideBaseDirectory)
        let handoffID = UUID()
        let ext = exportedImageURL.pathExtension.isEmpty ? "dng" : exportedImageURL.pathExtension
        let stagedImageURL = baseDir.appendingPathComponent("handoff_\(handoffID.uuidString).\(ext)")
        let manifestURL = baseDir.appendingPathComponent("handoff_\(handoffID.uuidString).json")
        var attemptedImageCopy = false
        var attemptedManifestWrite = false
        var published = false
        defer {
            // A failed publication has no usable deep link. Retire only this call's unique
            // partial/package files, never the source export or an earlier completed handoff.
            if !published {
                if attemptedImageCopy { try? FileManager.default.removeItem(at: stagedImageURL) }
                if attemptedManifestWrite { try? FileManager.default.removeItem(at: manifestURL) }
            }
        }

        if stagedImageURL.standardizedFileURL != exportedImageURL.standardizedFileURL {
            if FileManager.default.fileExists(atPath: stagedImageURL.path) {
                try FileManager.default.removeItem(at: stagedImageURL)
            }
            // Deliberate byte copy across the App Group boundary (not zero-copy).
            attemptedImageCopy = true
            try FileManager.default.copyItem(at: exportedImageURL, to: stagedImageURL)
        }

        let payload = SharedSuiteHandoffPayload(
            handoffID: handoffID,
            sourceApp: sourceApp,
            targetApp: targetApp,
            imageFileURLPath: stagedImageURL.path,
            originalFileName: originalFileName,
            isDenoised: isDenoised,
            isUpscaled: isUpscaled,
            globalMaxLuminance: globalMaxLuminance,
            upscaleFactor: upscaleFactor,
            globalMaxLinearComponent: globalMaxLinearComponent ?? max(1.0, globalMaxLuminance)
        )

        let data = try JSONEncoder().encode(payload)
        attemptedManifestWrite = true
        try data.write(to: manifestURL, options: .atomic)

        let deepLinkURL = URL(string: "\(targetApp.urlScheme)://handoff?id=\(handoffID.uuidString)")!
        published = true
        return (payload, deepLinkURL)
    }

    /// Consumes the manifest referenced by a deep link after strict validation:
    /// target app is TruongScaler, the requested id matches the manifest filename and payload,
    /// the staged file is contained in the resolved `Handoffs` directory (lexically and after
    /// resolving symlinks), exists as a non-empty regular file.
    public static func consumeIncomingHandoff(
        from deepLinkURL: URL,
        overrideBaseDirectory: URL? = nil
    ) throws -> SharedSuiteHandoffPayload {
        guard let components = URLComponents(url: deepLinkURL, resolvingAgainstBaseURL: false),
              components.host == "handoff",
              let idString = components.queryItems?.first(where: { $0.name == "id" })?.value,
              let handoffID = UUID(uuidString: idString) else {
            throw ScalerError.fileNotFound(deepLinkURL)
        }
        let baseDir = try handoffBaseDirectory(overrideDirectory: overrideBaseDirectory)
        let manifestName = "handoff_\(handoffID.uuidString).json"
        let manifestURL = baseDir.appendingPathComponent(manifestName)
        guard manifestURL.lastPathComponent == manifestName,
              FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ScalerError.fileNotFound(manifestURL)
        }
        let data = try Data(contentsOf: manifestURL)
        let payload = try JSONDecoder().decode(SharedSuiteHandoffPayload.self, from: data)
        guard payload.targetApp == .truongScaler else {
            throw ScalerError.unsupportedImageFormat(
                "Handoff target is \(payload.targetApp.rawValue), not TruongScaler"
            )
        }
        guard payload.handoffID == handoffID else {
            throw ScalerError.fileNotFound(manifestURL)
        }

        let stagedURL = URL(fileURLWithPath: payload.imageFileURLPath)
        // Lexical containment first (works for /var vs /private/var), then symlink resolution so
        // a link inside Handoffs cannot escape the shared directory.
        _ = try PathSafety.assertContained(stagedURL.standardizedFileURL, in: baseDir)
        let resolvedBase = baseDir.resolvingSymlinksInPath().standardizedFileURL
        let resolvedStaged = stagedURL.resolvingSymlinksInPath().standardizedFileURL
        _ = try PathSafety.assertContained(resolvedStaged, in: resolvedBase)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stagedURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ScalerError.fileNotFound(stagedURL)
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: stagedURL.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size > 0 else {
            throw ScalerError.fileNotFound(stagedURL)
        }
        return payload
    }
}
