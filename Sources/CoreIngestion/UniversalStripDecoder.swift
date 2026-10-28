import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import MMapCanvas
import TruongScalerCore

/// Result of decoding a source image into a disk-backed `MMapBuffer`.
/// Specification: `docs/DEVELOPMENT.md` Section 2.2.
public struct DecodedSourceResult: Sendable {
    public let metadata: ImageMetadataPacket
    public let sourceBuffer: MMapBuffer
    public let globalMaxLuminance: Float
    /// Maximum nonnegative R/G/B component (not just luminance) seen during decode.
    /// This is the value the DNG/TIFF headroom pre-pass must use so saturated HDR colours
    /// are not clipped. Additive with a backwards-compatible default.
    public let globalMaxLinearComponent: Float
    public let decodedWidth: Int
    public let decodedHeight: Int

    public init(
        metadata: ImageMetadataPacket,
        sourceBuffer: MMapBuffer,
        globalMaxLuminance: Float,
        globalMaxLinearComponent: Float? = nil,
        decodedWidth: Int,
        decodedHeight: Int
    ) {
        self.metadata = metadata
        self.sourceBuffer = sourceBuffer
        self.globalMaxLuminance = globalMaxLuminance
        self.globalMaxLinearComponent = globalMaxLinearComponent ?? globalMaxLuminance
        self.decodedWidth = decodedWidth
        self.decodedHeight = decodedHeight
    }
}

/// Decodes any supported RAW, ProRAW, HDR HEIC, TIFF, PNG, or JPEG image in horizontal strips of 512 rows
/// directly into a disk-backed `MMapBuffer` in `extendedLinearDisplayP3` (`CIFormat.RGBAh`).
/// Specification: `docs/DEVELOPMENT.md` Section 2.2.
public struct UniversalStripDecoder: Sendable {
    public static let defaultStripHeight: Int = 512

    /// Linear Display P3 luminance coefficients (Rec. 709-ish Y against P3 primaries).
    private static let luminanceR: Float = 0.22897456
    private static let luminanceG: Float = 0.69173852
    private static let luminanceB: Float = 0.07928691
    private static let maximumLuminanceClamp: Float = 65_500.0

    public static func decodeToMMap(
        imageURL: URL,
        destinationMMapURL: URL,
        stripHeight: Int = defaultStripHeight,
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        deleteDestinationOnDeinit: Bool = false
    ) throws -> DecodedSourceResult {
        // Rendering is lazy. Mapping the input file as the output would truncate it before CoreImage
        // reads its pixels, including when the two paths are aliases through a symlink or hard link.
        guard !referToSameFile(imageURL, destinationMMapURL) else {
            throw ScalerError.stripDecodingFailed(
                stripIndex: 0,
                rectDescription: "Source image and mmap destination must refer to different files"
            )
        }
        // Step 1 — Metadata extraction doubles as the file-existence / format validation gate.
        let metadata = try MetadataExtractor.extractMetadata(from: imageURL)

        // Step 1b — Trusted suite rendered Linear DNGs take the independent pure-Swift TIFF
        // strip reader. External camera RAW/ProRAW keeps the `CIRAWFilter` path below.
        if metadata.isLinearDNG && metadata.hasSuiteLinearDNGMarker {
            let decoded = try LinearDNGTIFFReader.decode(
                imageURL: imageURL,
                destinationMMapURL: destinationMMapURL,
                stripHeight: stripHeight,
                progressHandler: progressHandler
            )
            let sourceBuffer = try MMapBuffer(
                fileURL: destinationMMapURL,
                width: decoded.width,
                height: decoded.height,
                createIfMissing: false,
                deleteOnDeinit: deleteDestinationOnDeinit
            )
            return DecodedSourceResult(
                metadata: metadata,
                sourceBuffer: sourceBuffer,
                globalMaxLuminance: decoded.globalMaxLuminance,
                globalMaxLinearComponent: decoded.globalMaxLinearComponent,
                decodedWidth: decoded.width,
                decodedHeight: decoded.height
            )
        }

        // Step 2 — Build an orientation-baked CIImage for the source category.
        let sourceImage = try makeSourceImage(imageURL: imageURL, metadata: metadata)

        // Step 3 — Normalize the CoreImage origin to (0, 0) and derive the oriented decode size.
        var normalizedImage = sourceImage
        let sourceExtent = normalizedImage.extent
        guard sourceExtent.origin.x.isFinite,
              sourceExtent.origin.y.isFinite,
              sourceExtent.width.isFinite,
              sourceExtent.height.isFinite,
              sourceExtent.width > 0,
              sourceExtent.height > 0 else {
            throw ScalerError.metadataExtractionFailed
        }
        if sourceExtent.origin.x != 0 || sourceExtent.origin.y != 0 {
            normalizedImage = normalizedImage.transformed(
                by: CGAffineTransform(translationX: -sourceExtent.origin.x, y: -sourceExtent.origin.y)
            )
        }
        let width = Int(normalizedImage.extent.width.rounded())
        let height = Int(normalizedImage.extent.height.rounded())
        guard width > 0, height > 0 else {
            throw ScalerError.invalidImageDimensions(width: width, height: height)
        }

        // Step 4 — Disk-backed RGBA16Float destination.
        let sourceBuffer = try MMapBuffer(
            fileURL: destinationMMapURL,
            width: width,
            height: height,
            createIfMissing: true,
            deleteOnDeinit: deleteDestinationOnDeinit
        )

        // Step 5 — Extended-linear Display P3 rendering context (half-float working format).
        guard let linearDisplayP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
            throw ScalerError.metadataExtractionFailed
        }
        let ciContext = CIContext(options: [
            .workingFormat: CIFormat.RGBAh,
            .workingColorSpace: linearDisplayP3,
            .outputColorSpace: linearDisplayP3,
            .cacheIntermediates: false,
            .allowLowPower: false,
        ])

        // Disk writes/flushes are serialized through a decoder-owned BlockingIOOwner so page faults and
        // msync() never block the Swift concurrency cooperative pool.
        let blockingIOOwner = BlockingIOOwner(label: "com.truongscaler.coreingestion.strip-decoder")

        // Step 6 — Reusable strip buffer sized for one horizontal band (never a full-image RGBA copy).
        let effectiveStripHeight = min(max(1, stripHeight), height)
        let stripRowBytes = sourceBuffer.rowBytes
        let stripBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: stripRowBytes * effectiveStripHeight,
            alignment: 64
        )
        defer { stripBuffer.deallocate() }
        nonisolated(unsafe) let stripPointer = stripBuffer

        var maximumLuminance: Float = 1.0
        var maximumComponent: Float = 1.0
        var startY = 0

        while startY < height {
            let currentStripHeight = min(effectiveStripHeight, height - startY)
            let ciY = CGFloat(height - startY - currentStripHeight)
            let stripBounds = CGRect(
                x: 0,
                y: ciY,
                width: CGFloat(width),
                height: CGFloat(currentStripHeight)
            )

            // Top-down raster row [startY] maps to CoreImage's bottom-left Y coordinate [ciY].
            autoreleasepool {
                ciContext.render(
                    normalizedImage,
                    toBitmap: stripPointer,
                    rowBytes: stripRowBytes,
                    bounds: stripBounds,
                    format: .RGBAh,
                    colorSpace: linearDisplayP3
                )
            }

            // Step 7 — Sanitize non-finite samples in place and scan global linear luminance.
            let pixelRows = currentStripHeight
            for row in 0..<pixelRows {
                let rowPointer = stripPointer
                    .advanced(by: row * stripRowBytes)
                    .assumingMemoryBound(to: Float16.self)
                for column in 0..<width {
                    let pixel = rowPointer + column * 4
                    var red = Float(pixel[0])
                    var green = Float(pixel[1])
                    var blue = Float(pixel[2])
                    if !red.isFinite {
                        red = 0
                        pixel[0] = 0
                    }
                    if !green.isFinite {
                        green = 0
                        pixel[1] = 0
                    }
                    if !blue.isFinite {
                        blue = 0
                        pixel[2] = 0
                    }
                    let safeRed = max(0, red)
                    let safeGreen = max(0, green)
                    let safeBlue = max(0, blue)
                    let componentMaximum = max(safeRed, max(safeGreen, safeBlue))
                    if componentMaximum > maximumComponent {
                        maximumComponent = min(componentMaximum, maximumLuminanceClamp)
                    }
                    let luminance = luminanceR * safeRed
                        + luminanceG * safeGreen
                        + luminanceB * safeBlue
                    if luminance > maximumLuminance {
                        maximumLuminance = min(luminance, maximumLuminanceClamp)
                    }
                }
            }

            // Step 8 — Serialize the mmap write (and page advisory) through the BlockingIOOwner.
            let stripStartY = startY
            let stripRowCount = currentStripHeight
            _ = try performBlockingIO(on: blockingIOOwner) {
                sourceBuffer.writeStrip(
                    startY: stripStartY,
                    stripHeight: stripRowCount,
                    from: stripPointer,
                    sourceRowBytes: stripRowBytes
                )
                sourceBuffer.releaseCleanPages(startY: stripStartY, rowCount: stripRowCount)
                return true
            }

            startY += currentStripHeight
            progressHandler?(Double(startY) / Double(height))
        }

        // Step 9 — Durable flush before handing the mmap buffer to the pipeline.
        _ = try performBlockingIO(on: blockingIOOwner) {
            try sourceBuffer.flushToDisk(synchronous: true)
            return true
        }

        return DecodedSourceResult(
            metadata: metadata,
            sourceBuffer: sourceBuffer,
            globalMaxLuminance: maximumLuminance,
            globalMaxLinearComponent: maximumComponent,
            decodedWidth: width,
            decodedHeight: height
        )
    }
}

// MARK: - Source Image Construction

private extension UniversalStripDecoder {
    static func referToSameFile(_ sourceURL: URL, _ destinationURL: URL) -> Bool {
        if sourceURL.resolvingSymlinksInPath().standardizedFileURL
            == destinationURL.resolvingSymlinksInPath().standardizedFileURL {
            return true
        }
        guard let sourceAttributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let destinationAttributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path),
              let sourceDevice = sourceAttributes[.systemNumber] as? NSNumber,
              let sourceFile = sourceAttributes[.systemFileNumber] as? NSNumber,
              let destinationDevice = destinationAttributes[.systemNumber] as? NSNumber,
              let destinationFile = destinationAttributes[.systemFileNumber] as? NSNumber else { return false }
        return sourceDevice == destinationDevice && sourceFile == destinationFile
    }

    static func makeSourceImage(imageURL: URL, metadata: ImageMetadataPacket) throws -> CIImage {
        switch metadata.category {
        case .cameraRAW, .appleProRAW:
            guard let rawFilter = CIRAWFilter(imageURL: imageURL) else {
                throw ScalerError.imageSourceCreationFailed(imageURL)
            }
            rawFilter.sharpnessAmount = 0.0
            rawFilter.boostAmount = 0.0
            rawFilter.luminanceNoiseReductionAmount = 0.0
            rawFilter.colorNoiseReductionAmount = 0.0
            if rawFilter.isMoireReductionSupported {
                rawFilter.moireReductionAmount = 0.5
            }
            // `CIRAWFilter` seeds `orientation` from the file metadata; assigning it explicitly keeps
            // orientation baking deterministic for any decoder version.
            let rawOrientation = UInt32(clamping: metadata.originalOrientation)
            if let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) {
                rawFilter.orientation = orientation
            }
            guard let outputImage = rawFilter.outputImage else {
                throw ScalerError.imageSourceCreationFailed(imageURL)
            }
            return outputImage

        case .hdrHEIC, .standardAlphaRaster, .standardOpaqueRaster:
            guard let image = CIImage(
                contentsOf: imageURL,
                options: [
                    .applyOrientationProperty: true,
                    .toneMapHDRtoSDR: false,
                    // Gain-map JPEG/HEIF stores an SDR base. Disabling tone mapping alone does not
                    // apply that gain map; explicit expansion restores the extended linear samples.
                    .expandToHDR: true,
                    .cacheImmediately: false,
                ]
            ) else {
                throw ScalerError.imageSourceCreationFailed(imageURL)
            }
            // Some runtimes expose the gain-map plane but omit its reconstruction metadata and
            // silently return only the SDR base, even for an explicit expansion request. Refuse
            // that graph before the caller creates/truncates a destination mmap.
            try validateNativeGainMapExpansion(
                hasGainMap: metadata.hdrGainMapAuxiliaryData != nil,
                contentHeadroom: image.contentHeadroom
            )
            return image
        }
    }

}

extension UniversalStripDecoder {
    static func validateNativeGainMapExpansion(hasGainMap: Bool, contentHeadroom: Float) throws {
        guard !hasGainMap || (contentHeadroom.isFinite && contentHeadroom > 1) else {
            throw ScalerError.hdrGainMapExpansionUnavailable
        }
    }
}

// MARK: - BlockingIOOwner Synchronous Bridge

/// A decode call is synchronous by contract, while `BlockingIOOwner` exposes only async entry points.
/// This bridge hops the disk work onto the owner's serial queue and blocks only the decoder's calling
/// thread until the serialized write/flush completes.
private extension UniversalStripDecoder {
    static func performBlockingIO<T: Sendable>(
        on owner: BlockingIOOwner,
        _ work: @Sendable @escaping () throws -> T
    ) throws -> T {
        let completion = DispatchSemaphore(value: 0)
        let resultBox = IOCompletionBox<T>()
        Task.detached(priority: .userInitiated) {
            do {
                let value = try await owner.run(work)
                resultBox.store(.success(value))
            } catch {
                resultBox.store(.failure(error))
            }
            completion.signal()
        }
        completion.wait()
        guard let result = resultBox.load() else {
            throw ScalerError.stripDecodingFailed(
                stripIndex: 0,
                rectDescription: "BlockingIOOwner completed without producing a result"
            )
        }
        return try result.get()
    }
}

private final class IOCompletionBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func store(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
