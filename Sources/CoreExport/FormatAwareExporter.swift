import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
import TruongScalerCore
import MMapCanvas
import CoreIngestion
import TiledInferenceEngine
import DNGWriterBridge

/// Streams the upscaled image from `outputBuffer` + `sourceBuffer` (for on-the-fly `LanczosGrainBlender`)
/// into the target file container (`.linearDNG16Bit`, `.tiff16BitLZW`, `.heic10BitHDR`, `.png16Bit`, `.jpeg95`)
/// without allocating a full-image copy in RAM.
///
/// Per-format dynamic-range contract (`docs/DEVELOPMENT.md`, implementation contract §5):
/// * **Linear DNG** — SDR: quantized 16-bit LinearRaw samples. HDR: absolute Float16 bit patterns
///   with DNG 1.7 / ColorimetricReference 2 / ProfileDynamicRange (H = final component peak).
/// * **16-bit LZW TIFF** — lossless Float16 extended-linear Display P3 (`> 1.0` and alpha survive).
/// * **16-bit PNG** — SDR only; HDR content is refused with an actionable error, never clipped.
/// * **HEIC** — SDR encodes normally. HDR is attempted from the real extended-linear canvas and then
///   decoded back; if the host codec cannot preserve the highlights the export is refused. A stale
///   source gain map is never re-attached, and no SDR fallback is ever labelled HDR.
/// * **JPEG** — 8-bit opaque SDR with premultiplied-alpha flattening retained.
///
/// Every format writes to a hidden sibling staging file and is published over the destination with an
/// atomic `rename(2)` only after the file is finalized (and, for HDR HEIC, verified). If anything
/// fails, the staging file is removed and a pre-existing destination stays byte-identical.
public struct FormatAwareExporter: Sendable {
    /// Number of rows handed to the C++ DNG writer per strip (matches its default).
    static let dngRowsPerStrip: Int = 256
    /// Maximum number of rows rendered per `CGDataProviderDirectCallbacks` chunk.
    static let rasterStripRows: Int = 256
    /// Bounded scratch budget for the output-peak pre-pass (and each raster/DNG strip scratch).
    static let rasterScratchBudgetBytes: Int = 16 * 1024 * 1024
    /// Bounded scratch budget for the headroom pre-pass.
    static let peakScratchBudgetBytes: Int = 16 * 1024 * 1024

    /// A rendered R/G/B component above this value is extended-range (HDR) content.
    /// The small tolerance absorbs Float16 quantization of nominally SDR samples.
    public static let hdrComponentThreshold: Float = 1.0 + 1e-4

    /// Artifact-derived effective scale factor used for metadata, DNG pipeline tags and filenames.
    ///
    /// The completed canvas ratio wins over persisted selectors, including legacy artifacts.
    /// Only exact 2×/4× artifact ratios are accepted; other ratios use the validated selector.
    public static func actualScaleFactor(
        artifacts: CompletedPipelineArtifacts
    ) -> Int {
        artifactScaleFactor(
            sourceWidth: artifacts.sourceBuffer.width,
            outputWidth: artifacts.outputBuffer.width,
            configuredScale: artifacts.checkpoint.config.scaleFactor.rawValue
        )
    }

    static func artifactScaleFactor(
        sourceWidth: Int,
        outputWidth: Int,
        configuredScale: Int
    ) -> Int {
        let configured = (configuredScale == 2 || configuredScale == 4) ? configuredScale : 4
        guard sourceWidth > 0, outputWidth > 0 else { return configured }
        let ratio = Double(outputWidth) / Double(sourceWidth)
        guard ratio.isFinite, ratio > 0, ratio < 8 else { return configured }
        let rounded = Int(ratio.rounded())
        return (rounded == 2 || rounded == 4) ? rounded : configured
    }

    /// One new event per actual completed job, independent of re-export format or retries.
    public static func processedMetadata(artifacts: CompletedPipelineArtifacts) -> ImageMetadataPacket {
        let c = artifacts.checkpoint
        let history = (artifacts.metadata.processingHistory ?? ImageProcessingHistory()).appending(.init(
            id: c.jobID, app: "com.iantruong.truongscaler", operation: "upscale", model: c.config.backbone.rawValue,
            scale: actualScaleFactor(artifacts: artifacts), date: c.updatedAt,
            inputWidth: artifacts.sourceBuffer.width, inputHeight: artifacts.sourceBuffer.height,
            outputWidth: artifacts.outputBuffer.width, outputHeight: artifacts.outputBuffer.height))
        return artifacts.metadata.withPipelineState(
            isDenoised: artifacts.metadata.isAlreadyDenoisedBySuite || artifacts.metadata.isAlreadyDenoisedByNoiser || c.didRunDenoise,
            isUpscaled: true, upscaledByAppFactor: actualScaleFactor(artifacts: artifacts), processingHistory: history)
    }

    /// Detailed export: publishes the container atomically and returns the measured final-component
    /// peak, actual artifact factor and DNG headroom scale alongside the URL.
    @discardableResult
    public static func exportImageDetailed(
        artifacts: CompletedPipelineArtifacts,
        destinationURL: URL,
        overrideFormat: ExportFormat? = nil,
        overrideGrainAmount: Float? = nil,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) throws -> ExportResult {
        let width = artifacts.outputBuffer.width
        let height = artifacts.outputBuffer.height
        guard width > 0, height > 0 else {
            throw ScalerError.invalidImageDimensions(width: width, height: height)
        }

        // ImageIO and the DNG bridge open their destination with truncation. Protect the original,
        // the checkpoint's source path and both live mmap sidecars, including aliases reached through
        // symlinks and hard links, BEFORE any staging/destination file is touched.
        for inputURL in [artifacts.metadata.sourceURL, artifacts.checkpoint.config.sourceImageURL,
                         artifacts.sourceBuffer.fileURL, artifacts.outputBuffer.fileURL] {
            guard !referToSameFile(inputURL, destinationURL) else {
                throw ScalerError.exportDestinationCreationFailed(destinationURL)
            }
        }

        let requestedFormat = overrideFormat ?? artifacts.checkpoint.config.exportFormat
        let resolvedFormat = artifacts.metadata.resolvedExportFormat(from: requestedFormat)

        let configuredGrain = overrideGrainAmount ?? artifacts.checkpoint.config.naturalGrainAmount
        let grainAmount = min(max(configuredGrain, 0.0), 1.0)
        // Derive grain alignment and metadata from the actual completed canvas.
        let scaleFactor = actualScaleFactor(artifacts: artifacts)
        var resultFormat = resolvedFormat

        progressHandler?(0.0)

        // A) Shared, bounded output peak pre-pass over the FINAL rendered pixels (including grain
        // blending). Used for PNG/HEIC format decisions and for the DNG headroom scale.
        let prePassProgress: (@Sendable (Double) -> Void)?
        if let progressHandler {
            prePassProgress = { fraction in
                let clamped = min(max(fraction, 0.0), 1.0)
                progressHandler(0.05 * clamped)
            }
        } else {
            prePassProgress = nil
        }
        let peak = OutputPeakMeter.measure(
            width: width,
            height: height,
            scaleFactor: scaleFactor,
            grainAmount: grainAmount,
            sourceBuffer: artifacts.sourceBuffer,
            outputBuffer: artifacts.outputBuffer,
            progressHandler: prePassProgress
        )
        let isHDRContent = peak.value > hdrComponentThreshold
        // Headroom recorded/forwarded for this export. For DNG the branch below replaces this with
        // the builder-resolved value that is actually written (1 for SDR, H for the Float16 HDR
        // profile), so the handoff state cannot disagree with the embedded file.
        var dngHeadroomScale = max(1, peak.value)
        let encodeProgress: (@Sendable (Double) -> Void)?
        if let progressHandler {
            encodeProgress = { fraction in
                let clamped = min(max(fraction, 0.0), 1.0)
                progressHandler(0.05 + 0.94 * clamped)
            }
        } else {
            encodeProgress = nil
        }

        switch resolvedFormat {
        case .png16Bit where isHDRContent:
            // C) Explicit 16-bit SDR contract: never clip HDR silently.
            throw pngHDRUnsupported(peak: peak.value)
        case .linearDNG16Bit:
            let stagingURL = makeStagingURL(for: destinationURL)
            defer { try? FileManager.default.removeItem(at: stagingURL) }
            dngHeadroomScale = try exportLinearDNG(
                artifacts: artifacts,
                stagingURL: stagingURL,
                grainAmount: grainAmount,
                scaleFactor: scaleFactor,
                outputPeak: peak.value,
                isHDRContent: isHDRContent,
                progressHandler: encodeProgress
            )
            try publish(stagingURL, over: destinationURL)
        case .tiff16BitLZW, .png16Bit, .heic10BitHDR, .jpeg95:
            let stagingURL = makeStagingURL(for: destinationURL)
            defer { try? FileManager.default.removeItem(at: stagingURL) }
            try exportRaster(
                artifacts: artifacts,
                stagingURL: stagingURL,
                destinationURL: destinationURL,
                resolvedFormat: resolvedFormat,
                grainAmount: grainAmount,
                scaleFactor: scaleFactor,
                isHDRContent: isHDRContent,
                outputPeak: peak,
                progressHandler: encodeProgress
            )
            try publish(stagingURL, over: destinationURL)
        case .autoMatchSource:
            // `resolvedExportFormat` never returns `.autoMatchSource`; defend anyway.
            resultFormat = .jpeg95
            let stagingURL = makeStagingURL(for: destinationURL)
            defer { try? FileManager.default.removeItem(at: stagingURL) }
            try exportRaster(
                artifacts: artifacts,
                stagingURL: stagingURL,
                destinationURL: destinationURL,
                resolvedFormat: .jpeg95,
                grainAmount: grainAmount,
                scaleFactor: scaleFactor,
                isHDRContent: isHDRContent,
                outputPeak: peak,
                progressHandler: encodeProgress
            )
            try publish(stagingURL, over: destinationURL)
        }

        progressHandler?(1.0)
        return ExportResult(
            url: destinationURL,
            format: resultFormat,
            finalLinearPeak: peak.value,
            actualScaleFactor: scaleFactor,
            dngHeadroomScale: dngHeadroomScale,
            isHDR: isHDRContent
        )
    }

    /// Backward-compatible URL-only export. Prefer `exportImageDetailed` when the caller needs the
    /// measured final component peak / actual factor / DNG headroom for handoff state.
    public static func exportImage(
        artifacts: CompletedPipelineArtifacts,
        destinationURL: URL,
        overrideFormat: ExportFormat? = nil,
        overrideGrainAmount: Float? = nil,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) throws -> URL {
        try exportImageDetailed(
            artifacts: artifacts,
            destinationURL: destinationURL,
            overrideFormat: overrideFormat,
            overrideGrainAmount: overrideGrainAmount,
            progressHandler: progressHandler
        ).url
    }

    // MARK: - Atomic publication

    /// Hidden sibling staging path in the destination directory so the final `rename(2)` is atomic
    /// (same filesystem) and the destination file is never opened with truncation.
    private static func makeStagingURL(for destinationURL: URL) -> URL {
        let name = destinationURL.lastPathComponent
        return destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(name).staging-\(UUID().uuidString)")
    }

    private static func publish(_ stagingURL: URL, over destinationURL: URL) throws {
        let status = stagingURL.path.withCString { stagingPath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(stagingPath, destinationPath)
            }
        }
        guard status == 0 else {
            throw ScalerError.exportDestinationCreationFailed(destinationURL)
        }
    }

    private static func referToSameFile(_ sourceURL: URL, _ destinationURL: URL) -> Bool {
        if sourceURL.resolvingSymlinksInPath().standardizedFileURL
            == destinationURL.resolvingSymlinksInPath().standardizedFileURL { return true }
        guard let source = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let destination = try? FileManager.default.attributesOfItem(atPath: destinationURL.path),
              let sourceDevice = source[.systemNumber] as? NSNumber,
              let sourceFile = source[.systemFileNumber] as? NSNumber,
              let destinationDevice = destination[.systemNumber] as? NSNumber,
              let destinationFile = destination[.systemFileNumber] as? NSNumber else { return false }
        return sourceDevice == destinationDevice && sourceFile == destinationFile
    }

    // MARK: - Actionable capability errors

    private static func pngHDRUnsupported(peak: Float) -> ScalerError {
        .unsupportedFormatExport(
            format: "16-bit SDR PNG (png16Bit)",
            reason: "the rendered image contains extended-range components up to \(peak) "
                + "(HDR threshold \(hdrComponentThreshold)). PNG is a 16-bit SDR container and "
                + "would clip highlights. Export as 16-bit LZW TIFF (linear HDR), 16-bit Linear DNG, "
                + "or choose this format for SDR content only."
        )
    }

    private static func heicHDRUnsupported(reason: String) -> ScalerError {
        .unsupportedFormatExport(
            format: "HDR HEIC (heic10BitHDR)",
            reason: reason
                + " A regenerated ISO gain map is not implemented, so a stale source gain map is "
                + "never attached to the processed pixels. Export as 16-bit LZW TIFF (linear HDR) "
                + "or 16-bit Linear DNG for guaranteed extended-range output."
        )
    }

    // MARK: - Path A: Streaming 16-bit Linear DNG

    /// Returns the DNG headroom scale (`H`) that was actually written: 1 for the SDR UInt16 profile
    /// or the measured final component peak for the Float16 HDR profile.
    @discardableResult
    private static func exportLinearDNG(
        artifacts: CompletedPipelineArtifacts,
        stagingURL: URL,
        grainAmount: Float,
        scaleFactor: Int,
        outputPeak: Float,
        isHDRContent: Bool,
        progressHandler: (@Sendable (Double) -> Void)?
    ) throws -> Float {
        let outputBuffer = artifacts.outputBuffer
        let width = outputBuffer.width
        let height = outputBuffer.height
        // H = max(1.0, peak of every nonnegative output R/G/B component after grain blending).
        // Saturated HDR colours are preserved per channel, not only through luminance.
        let headroom = max(1.0, outputPeak)
        // Bound the DNG strip scratch (one RGBA16F temp strip + the writer's RGB16 strip) by the
        // shared 16 MiB budget even at 780 MP output widths.
        let rowsForBudget = rasterScratchBudgetBytes / max(1, width * 8)
        let stripRows = max(1, min(dngRowsPerStrip, min(height, rowsForBudget)))

        // The rendered canvas is already in linear Display P3, so the DNG carries the rendered
        // working-space calibration (not the source camera's raw matrices), neutral white balance,
        // BaselineExposure = 0, the headroom/working-space ImageDescription marker, XMP, and the
        // actual pipeline flags (including explicit false values). Group A owns this builder.
        //
        // R8 dynamic range representation (Adobe DNG 1.7.1 pp. 20, 28-29, 36-37, 47):
        // * SDR  (H <= 1 + 1e-4): UInt16 q = round(clamp(v,0,1)*65535), DNG 1.4/backward 1.1,
        //   ColorimetricReference 1 (ICC perceptual), WhiteLevel 65535, BaselineExposure 0.
        // * HDR  (H >  1 + 1e-4): Float16 IEEE bit patterns carrying absolute linear Display P3
        //   components (no headroom division/quantization), DNG 1.7/backward 1.7,
        //   ColorimetricReference 2 (output-referred HDR), WhiteLevel 1, BaselineExposure 0,
        //   ProfileDynamicRange tag 52551 with HintMaxOutputValue = H.
        //
        // The measured final component peak is the single source of truth for the builder's
        // representation decision and the writer config; the strip fill follows the builder's
        // resolved `usesFloatSamples` so the bytes can never disagree with the declared tags.
        let pipelineState = DNGExportPipelineState(
            upscaledByApp: true,
            upscaledFactor: scaleFactor,
            denoised: artifacts.metadata.isAlreadyDenoisedBySuite || artifacts.metadata.isAlreadyDenoisedByNoiser || artifacts.checkpoint.didRunDenoise,
            noiserDenoised: artifacts.metadata.isAlreadyDenoisedByNoiser,
            headroomScale: headroom,
            processingHistory: processedMetadata(artifacts: artifacts).processingHistory
        )
        let dngMetadata = DNGExportMetadataBuilder.build(
            metadata: processedMetadata(artifacts: artifacts),
            pipelineState: pipelineState,
            headroomScale: headroom,
            sampleFormat: isHDRContent ? 3 : 1
        )
        // A source without capture time must not acquire different bytes on each save retry.
        // TIFF DateTime may describe the completed processing job; EXIF capture dates remain
        // absent unless supplied by the source. Never replace a recorded source capture time.
        let dateTime = dngMetadata.dateTime ?? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            return formatter.string(from: artifacts.checkpoint.updatedAt)
        }()

        let context = DNGStripFillContext(
            sourceBuffer: artifacts.sourceBuffer,
            outputBuffer: outputBuffer,
            width: width,
            height: height,
            scaleFactor: scaleFactor,
            grainAmount: grainAmount,
            isHDR: dngMetadata.usesFloatSamples,
            rowsPerStrip: stripRows,
            progressHandler: progressHandler
        )
        let colorMatrix = dngMetadata.colorMatrix1
        let asShotNeutral = dngMetadata.asShotNeutral

        try colorMatrix.withUnsafeBufferPointer { matrixBuffer in
            try asShotNeutral.withUnsafeBufferPointer { neutralBuffer in
                try withOptionalCString(dngMetadata.cameraMake) { makePointer in
                    try withOptionalCString(dngMetadata.cameraModel) { modelPointer in
                        try withOptionalCString(dngMetadata.uniqueCameraModel) { uniqueModelPointer in
                            try dngMetadata.software.withCString { softwarePointer in
                                try dngMetadata.imageDescription.withCString { descriptionPointer in
                                    try withOptionalCString(dateTime) { dateTimePointer in
                                        try withOptionalBytes(dngMetadata.xmpData) { xmpPointer, xmpCount in
                                            try dngMetadata.entries.withUnsafeBufferPointer { entriesBuffer in
                                                var config = DNGLinearExportConfig(
                                                    width: UInt32(width),
                                                    height: UInt32(height),
                                                    rowsPerStrip: UInt32(stripRows),
                                                    cameraMake: makePointer,
                                                    cameraModel: modelPointer,
                                                    colorMatrix1: matrixBuffer.baseAddress,
                                                    asShotNeutral: neutralBuffer.baseAddress,
                                                    // R8: BaselineExposure describes a default-brightness
                                                    // adjustment. New SDR/HDR float files carry absolute
                                                    // linear components, so it stays 0.
                                                    baselineExposure: dngMetadata.baselineExposure,
                                                    blackLevel: 0,
                                                    whiteLevel: dngMetadata.whiteLevel,
                                                    orientation: dngMetadata.orientation,
                                                    uniqueCameraModel: uniqueModelPointer,
                                                    software: softwarePointer,
                                                    imageDescription: descriptionPointer,
                                                    dateTime: dateTimePointer,
                                                    metadataEntries: entriesBuffer.baseAddress,
                                                    metadataEntryCount: entriesBuffer.count,
                                                    xmpData: xmpPointer,
                                                    xmpByteCount: xmpCount,
                                                    colorimetricReference: dngMetadata.colorimetricReference,
                                                    sampleFormat: dngMetadata.sampleFormat,
                                                    profileDynamicRange: dngMetadata.profileDynamicRange,
                                                    hintMaxOutputValue: dngMetadata.hintMaxOutputValue,
                                                    dngVersionMajor: dngMetadata.dngVersionMajor,
                                                    dngVersionMinor: dngMetadata.dngVersionMinor,
                                                    dngVersionPatch: dngMetadata.dngVersionPatch,
                                                    dngVersionBuild: dngMetadata.dngVersionBuild,
                                                    dngBackwardVersionMajor: dngMetadata.dngBackwardVersionMajor,
                                                    dngBackwardVersionMinor: dngMetadata.dngBackwardVersionMinor,
                                                    dngBackwardVersionPatch: dngMetadata.dngBackwardVersionPatch,
                                                    dngBackwardVersionBuild: dngMetadata.dngBackwardVersionBuild
                                                )

                                                var errorBuffer = [CChar](repeating: 0, count: 512)
                                                let info = Unmanaged.passUnretained(context).toOpaque()
                                                let success = stagingURL.path.withCString { pathPointer in
                                                    withExtendedLifetime(context) {
                                                        withExtendedLifetime(dngMetadata) {
                                                            TSWriteStreamingLinearDNG16(
                                                                pathPointer,
                                                                &config,
                                                                dngStripFillCallback,
                                                                info,
                                                                &errorBuffer,
                                                                errorBuffer.count
                                                            )
                                                        }
                                                    }
                                                }

                                                guard success else {
                                                    let message = errorBuffer.withUnsafeBufferPointer { buffer in
                                                        String(cString: buffer.baseAddress!)
                                                    }
                                                    throw ScalerError.dngWriteFailed(
                                                        message.isEmpty
                                                            ? "Unknown 16-bit Linear DNG writer failure"
                                                            : message
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return dngMetadata.headroomScale
    }

    // MARK: - Path B: Streaming CGImageDestination containers

    private static func exportRaster(
        artifacts: CompletedPipelineArtifacts,
        stagingURL: URL,
        destinationURL: URL,
        resolvedFormat: ExportFormat,
        grainAmount: Float,
        scaleFactor: Int,
        isHDRContent: Bool,
        outputPeak: OutputPeak,
        progressHandler: (@Sendable (Double) -> Void)?
    ) throws {
        let outputBuffer = artifacts.outputBuffer
        let width = outputBuffer.width
        let height = outputBuffer.height
        let isHEIC = resolvedFormat == .heic10BitHDR
        // HEIC SDR keeps the reviewed 16-bit integer path. HEIC HDR is only ever attempted with a
        // real extended-linear Float16 canvas, then verified by decoding the finalized file back.
        let usesFloatComponents = resolvedFormat == .tiff16BitLZW || (isHEIC && isHDRContent)
        let isEightBit: Bool
        let colorSpaceName: CFString
        switch resolvedFormat {
        case .jpeg95:
            isEightBit = true
            colorSpaceName = CGColorSpace.displayP3
        case .heic10BitHDR, .tiff16BitLZW, .png16Bit:
            isEightBit = false
            colorSpaceName = CGColorSpace.extendedLinearDisplayP3
        case .linearDNG16Bit, .autoMatchSource:
            throw ScalerError.exportDestinationCreationFailed(destinationURL)
        }

        guard let colorSpace = CGColorSpace(name: colorSpaceName) else {
            throw ScalerError.exportDestinationCreationFailed(destinationURL)
        }

        // Keep the streaming scratch buffer bounded even for 780 MP outputs: at most 16 MiB of
        // float scratch plus the same bound for the encoded bytes regardless of width.
        // The RGBA16F render scratch is 8 bytes/pixel; JPEG's byte scratch is 4 bytes/pixel.
        let bytesPerOutputPixel = isEightBit ? 4 : 8
        let rowsForBudget = rasterScratchBudgetBytes / max(1, width * max(8, bytesPerOutputPixel))
        let stripRows = max(1, min(rasterStripRows, min(height, rowsForBudget)))

        let context = RasterStreamProviderContext(
            sourceBuffer: artifacts.sourceBuffer,
            outputBuffer: outputBuffer,
            width: width,
            height: height,
            scaleFactor: scaleFactor,
            grainAmount: grainAmount,
            isEightBit: isEightBit,
            usesFloatComponents: usesFloatComponents,
            stripRows: stripRows,
            progressHandler: progressHandler
        )

        guard let provider = makeDirectProvider(for: context) else {
            throw ScalerError.exportDestinationCreationFailed(destinationURL)
        }

        let bitsPerComponent = isEightBit ? 8 : 16
        let bitsPerPixel = isEightBit ? 32 : 64
        let bitmapInfo: CGBitmapInfo = isEightBit
            ? CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            )
            : CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue
                    | (usesFloatComponents ? CGBitmapInfo.floatComponents.rawValue : 0)
            )

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: context.rowBytes,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw ScalerError.exportDestinationCreationFailed(destinationURL)
        }

        let destination: CGImageDestination
        do {
            destination = try makeImageDestination(url: stagingURL, format: resolvedFormat)
        } catch {
            if isHEIC && isHDRContent {
                throw heicHDRUnsupported(
                    reason: "this host does not provide a HEIC encoder able to accept the "
                        + "extended-linear Float16 canvas."
                )
            }
            throw error
        }
        let properties = MetadataReinjector.buildDestinationProperties(
            from: metadataWithPipelineState(
                processedMetadata(artifacts: artifacts),
                didRunDenoise: artifacts.checkpoint.didRunDenoise
            ),
            upscaledWidth: width,
            upscaledHeight: height,
            exportFormat: resolvedFormat,
            // R7: pass the actual decoded (upright) source buffer dimensions and the artifact-derived
            // factor. Deriving only from un-oriented metadata width mislabels transposing EXIF
            // orientations 5...8 (e.g. a 2x3 source with orientation 6 exports 6x4 as 2x, not 4x).
            actualSourceWidth: artifacts.sourceBuffer.width,
            actualSourceHeight: artifacts.sourceBuffer.height,
            actualScaleFactor: scaleFactor
        )
        var finalized = false
        withExtendedLifetime(context) {
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
            // NOTE: a source HDR gain map describes the SOURCE pixels. The processed canvas is
            // regenerated, so blindly re-attaching that auxiliary image would claim a
            // highlight reconstruction that does not match these pixels. Passthrough is removed
            // until a correctly regenerated ISO gain map is implemented (capability limit).
            finalized = CGImageDestinationFinalize(destination)
        }

        guard finalized else {
            if isHEIC && isHDRContent {
                throw heicHDRUnsupported(
                    reason: "this host's HEIC encoder rejected the extended-linear Float16 image."
                )
            }
            throw ScalerError.exportDestinationCreationFailed(destinationURL)
        }

        if isHEIC && isHDRContent {
            // Never trust the container's bit-depth property (it reports 10 on hosts that clip).
            // Decode the finalized bytes and compare real highlight/colour patches.
            try verifyHEICDecodedHighlights(
                fileURL: stagingURL,
                expectedPeak: outputPeak,
                artifacts: artifacts,
                grainAmount: grainAmount,
                scaleFactor: scaleFactor,
                width: width,
                height: height
            )
        }
    }

    /// Decodes the finalized HEIC back and verifies that the actual extended-range highlights and a
    /// few colour patches survived. Only small 1x1 crops are rasterized, so verification is bounded.
    private static func verifyHEICDecodedHighlights(
        fileURL: URL,
        expectedPeak: OutputPeak,
        artifacts: CompletedPipelineArtifacts,
        grainAmount: Float,
        scaleFactor: Int,
        width: Int,
        height: Int
    ) throws {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw heicHDRUnsupported(reason: "the encoded HDR HEIC could not be reopened for verification.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let encodedOrientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        guard encodedOrientation == 1 else {
            throw heicHDRUnsupported(
                reason: "the encoded HDR HEIC has orientation \(encodedOrientation), not the "
                    + "upright orientation 1 required for processed pixels."
            )
        }
        guard let decodedImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw heicHDRUnsupported(reason: "the encoded HDR HEIC could not be decoded back.")
        }
        guard decodedImage.width == width, decodedImage.height == height else {
            throw heicHDRUnsupported(
                reason: "the encoded HDR HEIC decoded to \(decodedImage.width)x\(decodedImage.height) "
                    + "instead of \(width)x\(height)."
            )
        }

        // Sample the actual peak pixel plus a small grid of colour patches.
        var samplePoints: [(x: Int, y: Int)] = [
            (min(max(expectedPeak.x, 0), width - 1), min(max(expectedPeak.y, 0), height - 1)),
            (max(0, width / 8), max(0, height / 8)),
            (max(0, width / 2), max(0, height / 2)),
            (max(0, (width * 7) / 8), max(0, (height * 7) / 8)),
        ]
        var seen = Set<Int>()
        samplePoints = samplePoints.filter { point in
            seen.insert(point.y * width + point.x).inserted
        }

        let scratchPixelCount = width * 4
        let scratch = UnsafeMutablePointer<Float16>.allocate(capacity: scratchPixelCount)
        scratch.initialize(repeating: 0, count: scratchPixelCount)
        defer {
            scratch.deinitialize(count: scratchPixelCount)
            scratch.deallocate()
        }

        for point in samplePoints {
            // Render exactly this output row again (same grain path) to obtain the expected value.
            StreamingRegionRenderer.render(
                outY: point.y,
                outHeight: 1,
                width: width,
                scaleFactor: scaleFactor,
                grainAmount: grainAmount,
                sourceBuffer: artifacts.sourceBuffer,
                outputBuffer: artifacts.outputBuffer,
                destinationRGBA16F: UnsafeMutableRawPointer(scratch),
                destinationRowBytes: width * 8
            )
            let pixel = scratch + point.x * 4
            let expected = [Float(pixel[0]), Float(pixel[1]), Float(pixel[2])]
            let decoded = try decodedHEICPixel(decodedImage, x: point.x, y: point.y, destinationURL: fileURL)
            let expectedMax = expected.max() ?? 0
            guard expectedMax.isFinite else { continue }
            if expectedMax > hdrComponentThreshold {
                let decodedMax = max(decoded.0, max(decoded.1, decoded.2))
                guard decodedMax >= expectedMax * 0.95 - 0.01 else {
                    throw heicHDRUnsupported(
                        reason: "the host HEIC codec did not preserve extended-range pixels: "
                            + "the output peak \(expectedMax) decoded back as \(decodedMax)."
                    )
                }
                let channels = [expected[0], expected[1], expected[2]]
                let decodedChannels = [decoded.0, decoded.1, decoded.2]
                for channel in 0..<3 where channels[channel] > hdrComponentThreshold {
                    guard decodedChannels[channel] >= channels[channel] * 0.85 - 0.01 else {
                        throw heicHDRUnsupported(
                            reason: "the host HEIC codec lost the HDR colour component at "
                                + "(\(point.x), \(point.y)): \(channels) decoded as "
                                + "\(decodedChannels)."
                        )
                    }
                }
            }
        }
    }

    private static func decodedHEICPixel(
        _ image: CGImage,
        x: Int,
        y: Int,
        destinationURL: URL
    ) throws -> (Float, Float, Float) {
        guard let crop = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            throw heicHDRUnsupported(reason: "the encoded HDR HEIC could not be cropped for verification.")
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
            throw ScalerError.exportDestinationCreationFailed(destinationURL)
        }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
                | CGBitmapInfo.floatComponents.rawValue
        )
        var buffer = [Float](repeating: 0, count: 4)
        var didDraw = false
        buffer.withUnsafeMutableBytes { rawBuffer in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 32,
                bytesPerRow: 16,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return }
            context.interpolationQuality = .none
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            didDraw = true
        }
        guard didDraw else {
            throw heicHDRUnsupported(reason: "the encoded HDR HEIC could not be rasterized for verification.")
        }
        return (buffer[0], buffer[1], buffer[2])
    }

    /// Returns a metadata packet whose `isAlreadyDenoisedBySuite` flag reflects the actual pipeline
    /// state, so the `Denoised=true` ImagingSuite tag is written only when the denoiser really ran
    /// (either upstream by TruongNoiser or in this job's Stage 2). `withPipelineState` preserves
    /// every additive Group A field and writes explicit false flags.
    private static func metadataWithPipelineState(
        _ metadata: ImageMetadataPacket,
        didRunDenoise: Bool
    ) -> ImageMetadataPacket {
        metadata.withPipelineState(
            isDenoised: metadata.isAlreadyDenoisedBySuite || metadata.isAlreadyDenoisedByNoiser || didRunDenoise
        )
    }

    private static func makeImageDestination(
        url: URL,
        format: ExportFormat
    ) throws -> CGImageDestination {
        for identifier in destinationTypeIdentifiers(for: format) {
            if let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                identifier as CFString,
                1,
                nil
            ) {
                return destination
            }
        }
        throw ScalerError.exportDestinationCreationFailed(url)
    }

    private static func destinationTypeIdentifiers(for format: ExportFormat) -> [String] {
        var identifiers: [String]
        switch format {
        case .tiff16BitLZW:
            identifiers = [UTType.tiff.identifier, "public.tiff"]
        case .png16Bit:
            identifiers = [UTType.png.identifier, "public.png"]
        case .jpeg95:
            identifiers = [UTType.jpeg.identifier, "public.jpeg"]
        case .heic10BitHDR:
            identifiers = [
                UTType.heic.identifier,
                "public.heic",
                "public.heif",
                "public.heics"
            ]
        case .linearDNG16Bit:
            identifiers = ["public.dng", "com.adobe.raw-image"]
        case .autoMatchSource:
            identifiers = [UTType.jpeg.identifier, "public.jpeg"]
        }
        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }
    }

    private static func withOptionalCString<T>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) throws -> T
    ) rethrows -> T {
        guard let value else { return try body(nil) }
        return try value.withCString { pointer in
            try body(pointer)
        }
    }

    private static func withOptionalBytes<T>(
        _ data: Data?,
        _ body: (UnsafeRawPointer?, Int) throws -> T
    ) rethrows -> T {
        guard let data, !data.isEmpty else { return try body(nil, 0) }
        return try data.withUnsafeBytes { rawBuffer in
            try body(rawBuffer.baseAddress, rawBuffer.count)
        }
    }

    private static func makeDirectProvider(
        for context: RasterStreamProviderContext
    ) -> CGDataProvider? {
        var callbacks = CGDataProviderDirectCallbacks()
        callbacks.version = 0
        callbacks.getBytesAtPosition = { info, destination, position, count in
            guard let info else { return 0 }
            let context = Unmanaged<RasterStreamProviderContext>
                .fromOpaque(info)
                .takeUnretainedValue()
            return context.copyBytes(
                into: destination,
                byteOffset: Int(position),
                byteCount: count
            )
        }
        callbacks.releaseInfo = { _ in
            // The context is owned by the exporting scope (`withExtendedLifetime`).
        }
        let info = Unmanaged.passUnretained(context).toOpaque()
        return CGDataProvider(
            directInfo: info,
            size: off_t(context.totalByteSize),
            callbacks: &callbacks
        )
    }
}

// MARK: - Shared Region Rendering

private enum StreamingRegionRenderer {
    /// Renders `[outY ..< outY + outHeight)` of the upscaled output. When a positive grain amount
    /// is requested the region is blended on the fly from the original source buffer; otherwise the
    /// already-upscaled output buffer is read directly.
    static func render(
        outY: Int,
        outHeight: Int,
        width: Int,
        scaleFactor: Int,
        grainAmount: Float,
        sourceBuffer: MMapBuffer,
        outputBuffer: MMapBuffer,
        destinationRGBA16F: UnsafeMutableRawPointer,
        destinationRowBytes: Int
    ) {
        if grainAmount > 0.0001, sourceBuffer.width > 0, sourceBuffer.height > 0 {
            LanczosGrainBlender.renderBlendedRegion(
                outX: 0,
                outY: outY,
                outWidth: width,
                outHeight: outHeight,
                scaleFactor: scaleFactor,
                naturalGrainAmount: grainAmount,
                sourceBuffer: sourceBuffer,
                hatOutputBuffer: outputBuffer,
                destinationRGBA16F: destinationRGBA16F,
                destinationRowBytes: destinationRowBytes
            )
        } else {
            outputBuffer.readRegion(
                x: 0,
                y: outY,
                regionWidth: width,
                regionHeight: outHeight,
                into: destinationRGBA16F,
                destinationRowBytes: destinationRowBytes
            )
        }
    }
}

// MARK: - Output Peak Pre-Pass

/// Result of the bounded output peak pre-pass: the maximum nonnegative R/G/B component of the final
/// rendered output (after grain blending) and where it occurred.
private struct OutputPeak: Sendable {
    let value: Float
    let x: Int
    let y: Int
}

private enum OutputPeakMeter {
    static func measure(
        width: Int,
        height: Int,
        scaleFactor: Int,
        grainAmount: Float,
        sourceBuffer: MMapBuffer,
        outputBuffer: MMapBuffer,
        progressHandler: (@Sendable (Double) -> Void)?
    ) -> OutputPeak {
        let budgetRows = max(1, FormatAwareExporter.peakScratchBudgetBytes / max(1, width * 8))
        let rowsPerBand = max(1, min(FormatAwareExporter.rasterStripRows, min(height, budgetRows)))
        let scratchCount = width * rowsPerBand * 4
        let scratch = UnsafeMutablePointer<Float16>.allocate(capacity: scratchCount)
        scratch.initialize(repeating: 0, count: scratchCount)
        defer {
            scratch.deinitialize(count: scratchCount)
            scratch.deallocate()
        }

        var peak: Float = 0
        var peakX = 0
        var peakY = 0
        var startRow = 0
        while startRow < height {
            let bandRows = min(rowsPerBand, height - startRow)
            StreamingRegionRenderer.render(
                outY: startRow,
                outHeight: bandRows,
                width: width,
                scaleFactor: scaleFactor,
                grainAmount: grainAmount,
                sourceBuffer: sourceBuffer,
                outputBuffer: outputBuffer,
                destinationRGBA16F: UnsafeMutableRawPointer(scratch),
                destinationRowBytes: width * 8
            )
            for row in 0..<bandRows {
                let rowPointer = scratch + row * width * 4
                for column in 0..<width {
                    let pixel = rowPointer + column * 4
                    for channel in 0..<3 {
                        let value = Float(pixel[channel])
                        guard value.isFinite else { continue }
                        if value > peak {
                            peak = value
                            peakX = column
                            peakY = startRow + row
                        }
                    }
                }
            }
            startRow += bandRows
            progressHandler?(Double(startRow) / Double(max(1, height)))
        }
        return OutputPeak(value: peak, x: peakX, y: peakY)
    }
}

// MARK: - DNG Strip Fill Context

private final class DNGStripFillContext: @unchecked Sendable {
    private let sourceBuffer: MMapBuffer
    private let outputBuffer: MMapBuffer
    private let width: Int
    private let height: Int
    private let scaleFactor: Int
    private let grainAmount: Float
    /// True when strips carry absolute Float16 bit patterns (the builder-declared HDR profile);
    /// otherwise strips are quantized UInt16 SDR samples.
    private let isHDR: Bool
    private let rowsPerStrip: Int
    private let progressHandler: (@Sendable (Double) -> Void)?
    private let stripBuffer: UnsafeMutablePointer<Float16>
    private var lastReportedRow: Int = -1

    init(
        sourceBuffer: MMapBuffer,
        outputBuffer: MMapBuffer,
        width: Int,
        height: Int,
        scaleFactor: Int,
        grainAmount: Float,
        isHDR: Bool,
        rowsPerStrip: Int,
        progressHandler: (@Sendable (Double) -> Void)?
    ) {
        self.sourceBuffer = sourceBuffer
        self.outputBuffer = outputBuffer
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
        self.grainAmount = grainAmount
        self.isHDR = isHDR
        self.rowsPerStrip = max(1, min(rowsPerStrip, height))
        self.progressHandler = progressHandler
        self.stripBuffer = UnsafeMutablePointer<Float16>.allocate(
            capacity: width * self.rowsPerStrip * 4
        )
        self.stripBuffer.initialize(repeating: 0, count: width * self.rowsPerStrip * 4)
    }

    deinit {
        stripBuffer.deinitialize(count: width * rowsPerStrip * 4)
        stripBuffer.deallocate()
    }

    func fill(
        startRow: Int,
        rowCount: Int,
        destination: UnsafeMutablePointer<UInt16>
    ) -> Bool {
        guard
            rowCount > 0,
            startRow >= 0,
            rowCount <= rowsPerStrip,
            startRow + rowCount <= height
        else {
            return false
        }

        StreamingRegionRenderer.render(
            outY: startRow,
            outHeight: rowCount,
            width: width,
            scaleFactor: scaleFactor,
            grainAmount: grainAmount,
            sourceBuffer: sourceBuffer,
            outputBuffer: outputBuffer,
            destinationRGBA16F: UnsafeMutableRawPointer(stripBuffer),
            destinationRowBytes: width * 8
        )

        let pixelCount = width * rowCount
        if isHDR {
            // R8: the C callback buffer is UInt16, but HDR samples are 16-bit IEEE floats. Write the
            // Float16 bit pattern of the absolute linear component: no headroom division, no
            // integer quantization. Negative/non-finite excursions become 0 so BlackLevel=0 and the
            // positive HDR profile stay well-defined.
            for index in 0..<pixelCount {
                let source = stripBuffer + index * 4
                let target = index * 3
                destination[target] = float16BitPattern(source[0])
                destination[target + 1] = float16BitPattern(source[1])
                destination[target + 2] = float16BitPattern(source[2])
            }
        } else {
            for index in 0..<pixelCount {
                let source = stripBuffer + index * 4
                let target = index * 3
                destination[target] = quantize16(source[0])
                destination[target + 1] = quantize16(source[1])
                destination[target + 2] = quantize16(source[2])
            }
        }

        reportProgress(rowsCompleted: startRow + rowCount)
        return true
    }

    /// `q = round(clamp(v, 0, 1) * 65535)` for the SDR UInt16 representation. Negative excursions
    /// (and non-finite values) become 0; DNG BlackLevel stays 0, so no undocumented brightness
    /// offset is introduced.
    @inline(__always)
    private func quantize16(_ value: Float16) -> UInt16 {
        let raw = Float(value)
        guard raw.isFinite else { return 0 }
        let clamped = min(max(raw, 0.0), 1.0)
        let scaled = (clamped * 65535.0).rounded()
        return UInt16(clamping: Int(scaled))
    }

    /// Absolute linear component -> little-endian Float16 IEEE bit pattern for HDR DNG strips.
    @inline(__always)
    private func float16BitPattern(_ value: Float16) -> UInt16 {
        let raw = Float(value)
        guard raw.isFinite else { return 0 }
        let clamped = min(max(raw, 0.0), 65_504)
        return Float16(clamped).bitPattern
    }

    private func reportProgress(rowsCompleted: Int) {
        guard let progressHandler, rowsCompleted > lastReportedRow else { return }
        lastReportedRow = rowsCompleted
        progressHandler(min(1.0, Double(rowsCompleted) / Double(max(1, height))))
    }
}

// MARK: - Raster Stream Provider Context

private final class RasterStreamProviderContext: @unchecked Sendable {
    let totalByteSize: Int
    let rowBytes: Int

    private let sourceBuffer: MMapBuffer
    private let outputBuffer: MMapBuffer
    private let width: Int
    private let height: Int
    private let scaleFactor: Int
    private let grainAmount: Float
    private let isEightBit: Bool
    private let usesFloatComponents: Bool
    private let rowsPerStrip: Int
    private let progressHandler: (@Sendable (Double) -> Void)?
    private let floatScratch: UnsafeMutablePointer<Float16>
    private let byteScratch: UnsafeMutablePointer<UInt8>
    private let scratchByteCount: Int
    private let lock = NSLock()
    private var lastReportedRow: Int = -1

    init(
        sourceBuffer: MMapBuffer,
        outputBuffer: MMapBuffer,
        width: Int,
        height: Int,
        scaleFactor: Int,
        grainAmount: Float,
        isEightBit: Bool,
        usesFloatComponents: Bool,
        stripRows: Int,
        progressHandler: (@Sendable (Double) -> Void)?
    ) {
        self.sourceBuffer = sourceBuffer
        self.outputBuffer = outputBuffer
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
        self.grainAmount = grainAmount
        self.isEightBit = isEightBit
        self.usesFloatComponents = usesFloatComponents
        self.rowsPerStrip = max(1, min(stripRows, height))
        self.progressHandler = progressHandler

        let bytesPerPixel = isEightBit ? 4 : 8
        self.rowBytes = width * bytesPerPixel
        self.totalByteSize = rowBytes * height
        self.scratchByteCount = width * self.rowsPerStrip * bytesPerPixel

        let floatCapacity = width * self.rowsPerStrip * 4
        self.floatScratch = UnsafeMutablePointer<Float16>.allocate(capacity: floatCapacity)
        self.floatScratch.initialize(repeating: 0, count: floatCapacity)
        self.byteScratch = UnsafeMutablePointer<UInt8>.allocate(capacity: scratchByteCount)
        self.byteScratch.initialize(repeating: 0, count: scratchByteCount)
    }

    deinit {
        floatScratch.deinitialize(count: width * rowsPerStrip * 4)
        floatScratch.deallocate()
        byteScratch.deinitialize(count: scratchByteCount)
        byteScratch.deallocate()
    }

    func copyBytes(
        into destination: UnsafeMutableRawPointer,
        byteOffset: Int,
        byteCount: Int
    ) -> Int {
        guard
            byteCount > 0,
            byteOffset >= 0,
            byteOffset < totalByteSize
        else {
            return 0
        }

        let requestedEnd = min(totalByteSize, byteOffset + byteCount)
        let startRow = byteOffset / rowBytes
        let endRow = min(height, (requestedEnd + rowBytes - 1) / rowBytes)

        lock.lock()
        defer { lock.unlock() }

        var written = 0
        var row = startRow
        while row < endRow {
            let rows = min(rowsPerStrip, endRow - row)
            renderAndEncode(startRow: row, rowCount: rows)

            let chunkStart = row * rowBytes
            let chunkEnd = chunkStart + rows * rowBytes
            let copyStart = max(byteOffset, chunkStart)
            let copyEnd = min(requestedEnd, chunkEnd)
            if copyEnd > copyStart {
                let offsetInChunk = copyStart - chunkStart
                memcpy(
                    destination.advanced(by: written),
                    byteScratch.advanced(by: offsetInChunk),
                    copyEnd - copyStart
                )
                written += copyEnd - copyStart
            }
            row += rows
        }

        reportProgress(rowsCompleted: endRow)
        return written
    }

    private func renderAndEncode(startRow: Int, rowCount: Int) {
        StreamingRegionRenderer.render(
            outY: startRow,
            outHeight: rowCount,
            width: width,
            scaleFactor: scaleFactor,
            grainAmount: grainAmount,
            sourceBuffer: sourceBuffer,
            outputBuffer: outputBuffer,
            destinationRGBA16F: UnsafeMutableRawPointer(floatScratch),
            destinationRowBytes: width * 8
        )

        let pixelCount = width * rowCount
        if isEightBit {
            for index in 0..<pixelCount {
                let source = floatScratch + index * 4
                let target = index * 4
                byteScratch[target] = encodeSRGB8(source[0])
                byteScratch[target + 1] = encodeSRGB8(source[1])
                byteScratch[target + 2] = encodeSRGB8(source[2])
                // JPEG is opaque: flatten premultiplied linear RGB onto black before its transfer
                // function rather than presenting gamma-encoded values as premultiplied alpha.
                byteScratch[target + 3] = 255
            }
        } else if usesFloatComponents {
            // TIFF accepts half-float pixels. Quantizing to UInt16 here silently
            // clipped every extended-linear component above 1.0 before the encoder saw it.
            let target = UnsafeMutableRawPointer(byteScratch).assumingMemoryBound(to: Float16.self)
            for index in 0..<(pixelCount * 4) {
                let value = Float(floatScratch[index])
                target[index] = value.isFinite ? Float16(min(max(value, 0), 65504)) : 0
            }
        } else {
            let target = UnsafeMutableRawPointer(byteScratch)
                .assumingMemoryBound(to: UInt16.self)
            for index in 0..<pixelCount {
                let source = floatScratch + index * 4
                let targetIndex = index * 4
                target[targetIndex] = encodeLinear16(source[0]).littleEndian
                target[targetIndex + 1] = encodeLinear16(source[1]).littleEndian
                target[targetIndex + 2] = encodeLinear16(source[2]).littleEndian
                target[targetIndex + 3] = encodeLinear16(source[3]).littleEndian
            }
        }
    }

    @inline(__always)
    private func encodeLinear16(_ value: Float16) -> UInt16 {
        let raw = Float(value)
        guard raw.isFinite else { return 0 }
        let clamped = min(max(raw, 0.0), 1.0)
        let scaled = (clamped * 65535.0).rounded()
        return UInt16(clamping: Int(scaled))
    }

    /// Extended-linear Display P3 -> 8-bit Display P3 (sRGB transfer function).
    @inline(__always)
    private func encodeSRGB8(_ value: Float16) -> UInt8 {
        let raw = Float(value)
        guard raw.isFinite else { return 0 }
        let clamped = min(max(raw, 0.0), 1.0)
        let encoded: Float
        if clamped <= 0.003_130_8 {
            encoded = 12.92 * clamped
        } else {
            encoded = 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
        }
        let scaled = (min(max(encoded, 0.0), 1.0) * 255.0).rounded()
        return UInt8(clamping: Int(scaled))
    }

    private func reportProgress(rowsCompleted: Int) {
        guard let progressHandler, rowsCompleted > lastReportedRow else { return }
        lastReportedRow = rowsCompleted
        progressHandler(min(1.0, Double(rowsCompleted) / Double(max(1, height))))
    }
}

// MARK: - DNG C Callback

private func dngStripFillCallback(
    _ userContext: UnsafeMutableRawPointer?,
    _ startRow: UInt32,
    _ rowCount: UInt32,
    _ dstRGB16Buffer: UnsafeMutablePointer<UInt16>?
) -> Bool {
    guard
        let userContext,
        let dstRGB16Buffer
    else {
        return false
    }
    let context = Unmanaged<DNGStripFillContext>
        .fromOpaque(userContext)
        .takeUnretainedValue()
    return context.fill(
        startRow: Int(startRow),
        rowCount: Int(rowCount),
        destination: dstRGB16Buffer
    )
}
