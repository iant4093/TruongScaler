import SwiftUI
import Foundation
import ImageIO
import TruongScalerCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 1. Native Liquid Glass 44pt Circular Button (Exact TruongCam ViewerGlassIcon)

public struct ViewerGlassIcon: View {
    public let symbol: String

    public init(symbol: String) {
        self.symbol = symbol
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: Circle())
    }
}

// MARK: - 2. Metadata Plist Extraction Helper

public enum MetadataPropertyReader {
    public static func rawProperties(from packet: ImageMetadataPacket) -> [String: Any] {
        guard let data = packet.rawPropertiesPlistData,
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    public static func exifDictionary(from packet: ImageMetadataPacket) -> [String: Any] {
        let props = rawProperties(from: packet)
        return (props[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
    }

    public static func tiffDictionary(from packet: ImageMetadataPacket) -> [String: Any] {
        let props = rawProperties(from: packet)
        return (props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
    }

    public static func shortFormatLabel(from packet: ImageMetadataPacket) -> String {
        let ext = packet.sourceURL.pathExtension.lowercased()
        switch ext {
        case "dng": return "DNG"
        case "cr2", "cr3", "arw", "nef", "raf", "orf", "rw2": return ext.uppercased()
        case "tif", "tiff": return "TIFF"
        case "heic", "heif": return "HEIF"
        case "png": return "PNG"
        case "jpg", "jpeg": return "JPEG"
        default: return packet.utTypeIdentifier.uppercased()
        }
    }
}

// MARK: - 3. Single-Line Camera Settings Below Fitted Photo (Exact TruongCam PhotoSettingsBelowImage)

public struct PhotoSettingsBelowImage: View {
    public let metadata: ImageMetadataPacket

    public init(metadata: ImageMetadataPacket) {
        self.metadata = metadata
    }

    public var settingsComponents: [String] {
        var parts: [String] = []
        let exif = MetadataPropertyReader.exifDictionary(from: metadata)

        if let expTime = exif[kCGImagePropertyExifExposureTime as String] as? Double, expTime > 0 {
            if expTime < 1.0 {
                parts.append("1/\(Int((1.0 / expTime).rounded()))s")
            } else {
                parts.append(String(format: "%.1fs", expTime))
            }
        }
        if let iso = metadata.isoSpeedRatings {
            parts.append("ISO \(iso)")
        } else if let isoArr = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], let iso = isoArr.first {
            parts.append("ISO \(iso)")
        }
        if let fNum = exif[kCGImagePropertyExifFNumber as String] as? Double {
            parts.append(String(format: "ƒ/%.1f", fNum))
        }
        if let focal35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int {
            parts.append("\(focal35) mm")
        } else if let focal = exif[kCGImagePropertyExifFocalLength as String] as? Double {
            parts.append("\(Int(focal.rounded())) mm")
        }

        if parts.isEmpty {
            parts.append("\(metadata.originalWidth) × \(metadata.originalHeight)")
            parts.append(MetadataPropertyReader.shortFormatLabel(from: metadata))
        }
        return parts
    }

    public var body: some View {
        Text(settingsComponents.joined(separator: "   ·   "))
            .font(.system(.caption, design: .rounded).weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.5), in: Capsule())
            .accessibilityIdentifier("photoCaptureSettings")
    }
}

// MARK: - 4. Native Bottom Progress Bar

/// Quiet compact chrome for fast jobs. The percentage follows durable tile commits; the Details
/// sheet retains measured phases, current tile and timings. Preparation never invents a tile count.
public struct ProcessingProgressBarView: View {
    public let progress: JobProgressPresentation
    public let onStop: () -> Void
    public let onShowDetails: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(progress: JobProgressPresentation, onStop: @escaping () -> Void, onShowDetails: @escaping () -> Void) {
        self.progress = progress; self.onStop = onStop; self.onShowDetails = onShowDetails
    }

    private var content: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                Button(action: onShowDetails) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(progress.compactTitle).font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                            Text(progress.compactSubtitle)
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 2)
                        Text(progress.compactPercentText).font(.caption.monospacedDigit())
                        Image(systemName: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Processing details")
                Button(action: onStop) {
                    Image(systemName: "stop.fill").font(.caption.weight(.semibold))
                        .frame(width: 44, height: 44).background(.white.opacity(0.13), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(progress.isStopping)
                .accessibilityLabel(progress.isStopping ? "Stopping" : "Stop processing")
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12))
                    Capsule().fill(.white.opacity(0.85))
                        .frame(width: geometry.size.width * progress.compactFraction)
                        .animation(reduceMotion ? nil : .linear(duration: 0.2), value: progress.completedTiles)
                }
            }.frame(height: 2)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .foregroundStyle(.white).tint(.white)
        .contentTransition(.identity)
    }

    public var body: some View {
        Group {
            #if os(iOS)
            if #available(iOS 26, *) { content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24)) }
            else { content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24)) }
            #else
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            #endif
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .accessibilityIdentifier("photo-processing-progress")
    }
}

// MARK: - Processing details

public struct ProcessingDetailsSheet: View {
    public let progress: JobProgressPresentation
    @Environment(\.dismiss) private var dismiss
    public init(progress: JobProgressPresentation) { self.progress = progress }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Process", value: progress.processTitle)
                    LabeledContent("Tiles", value: progress.hasTilePlan ? "\(progress.completedTiles) / \(progress.totalTiles)" : (progress.isWaitingForForeground ? "Not started" : "Preparing"))
                    LabeledContent("Elapsed", value: JobProgressPresentation.format(seconds: progress.elapsedSeconds))
                    LabeledContent("Remaining", value: progress.remainingText)
                }
                if !progress.isWaitingForForeground {
                    Section("Photo") {
                        if let model = progress.modelName { LabeledContent("Model", value: model) }
                        if let w = progress.sourceWidth, let h = progress.sourceHeight { LabeledContent("Input", value: "\(w) × \(h)") }
                        if let w = progress.outputWidth, let h = progress.outputHeight { LabeledContent("Output", value: "\(w) × \(h)") }
                    }
                }
            }
            .monospacedDigit()
            .contentTransition(.identity)
            .transaction { $0.animation = nil }
            .navigationTitle("Processing details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 5. On-Demand Photo Information Sheet (Exact TruongCam MetadataInspector)

public struct MetadataInspectorSheet: View {
    public let metadata: ImageMetadataPacket
    public let sourceFilename: String
    public let outputDimensionsText: String
    public let pipelineSummaryText: String
    public let upscaleModelText: String?
    public let fileByteCountOverride: Int64?
    @Environment(\.dismiss) private var dismiss

    public init(
        metadata: ImageMetadataPacket,
        sourceFilename: String,
        outputDimensionsText: String,
        pipelineSummaryText: String,
        upscaleModelText: String? = nil,
        fileByteCountOverride: Int64? = nil
    ) {
        self.metadata = metadata
        self.sourceFilename = sourceFilename
        self.outputDimensionsText = outputDimensionsText
        self.pipelineSummaryText = pipelineSummaryText
        self.upscaleModelText = upscaleModelText
        self.fileByteCountOverride = fileByteCountOverride
    }

    private var heroValues: [String] {
        let exif = MetadataPropertyReader.exifDictionary(from: metadata)
        var items: [String] = []
        if let expTime = exif[kCGImagePropertyExifExposureTime as String] as? Double, expTime > 0 {
            items.append(expTime < 1.0 ? "1/\(Int((1.0 / expTime).rounded()))s" : String(format: "%.1fs", expTime))
        }
        if let iso = metadata.isoSpeedRatings {
            items.append("ISO \(iso)")
        } else if let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first {
            items.append("ISO \(iso)")
        }
        if let fNum = exif[kCGImagePropertyExifFNumber as String] as? Double {
            items.append(String(format: "ƒ/%.1f", fNum))
        }
        return items
    }

    private var fileByteCount: Int64? {
        if let fileByteCountOverride { return fileByteCountOverride }
        let values = try? metadata.sourceURL.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map { Int64($0) }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if !heroValues.isEmpty {
                        HStack(spacing: 12) {
                            ForEach(heroValues, id: \.self) { value in
                                Text(value)
                                    .font(.title2.weight(.semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.vertical, 16)
                    }

                    row("Dimensions", outputDimensionsText)
                        .padding(.vertical, 4)

                    if let bytes = fileByteCount {
                        row("File size", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                            .padding(.vertical, 4)
                    }

                    row("Format", MetadataPropertyReader.shortFormatLabel(from: metadata))
                        .padding(.vertical, 4)

                    let tiff = MetadataPropertyReader.tiffDictionary(from: metadata)
                    if let make = metadata.rawParameters?.cameraMake ?? (tiff[kCGImagePropertyTIFFMake as String] as? String) {
                        row("Manufacturer", make).padding(.vertical, 4)
                    }
                    if let model = metadata.rawParameters?.cameraModel ?? (tiff[kCGImagePropertyTIFFModel as String] as? String) {
                        row("Camera model", model).padding(.vertical, 4)
                    }

                    row("EXIF color space", "Display P3")
                        .padding(.vertical, 4)

                    let exif = MetadataPropertyReader.exifDictionary(from: metadata)
                    if let focal = exif[kCGImagePropertyExifFocalLength as String] as? Double {
                        if let focal35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int {
                            row("Focal length", "\(focal35) mm equivalent (\(String(format: "%.2f", focal)) mm actual)")
                                .padding(.vertical, 4)
                        } else {
                            row("Focal length", String(format: "%.2f mm", focal))
                                .padding(.vertical, 4)
                        }
                    }

                    if let upscaleModelText {
                        row("Upscale model", upscaleModelText)
                            .padding(.vertical, 4)
                            .accessibilityIdentifier("photo-upscale-model")
                    }

                    row("Upscaled", metadata.isAlreadyUpscaledBySuite
                        ? "Yes · TruongScaler" + (metadata.upscaledByAppFactor.map { " · \($0)×" } ?? "") : "Not recorded")
                        .padding(.vertical, 4)
                    row("Denoised", metadata.isAlreadyDenoisedByNoiser ? "Yes · TruongNoiser"
                        : metadata.isAlreadyDenoisedBySuite ? "Yes · app not recorded" : "Not recorded")
                        .padding(.vertical, 4)
                    if metadata.isAlreadyUpscaledBySuite {
                        Text("Before compares the exact input to this upscale with its saved result. Earlier denoising, if recorded, is present on both sides.")
                            .font(.footnote).foregroundStyle(.secondary).padding(.vertical, 8)
                    }

                    row("File", sourceFilename)
                        .padding(.vertical, 4)
                }
                .padding(12)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .padding()
            }
            .navigationTitle("Photo information")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 6. Native Export Share Sheet + Save DNG/Original to Photos Activity (Shared with TruongCam ExportPresenter)

#if canImport(UIKit)
import UIKit
import Photos
import LinkPresentation
import UniformTypeIdentifiers
import CryptoKit
import os

/// Supplying metadata avoids asking the share sheet to decode a huge Linear DNG merely to
/// discover its title/preview. The activity still receives the original file, without recompression.
final class PhotoShareItem: NSObject, UIActivityItemSource {
    let url: URL
    init(url: URL) { self.url = url }
    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }
    func activityViewController(_ controller: UIActivityViewController, itemForActivityType: UIActivity.ActivityType?) -> Any? { url }
    func activityViewController(_ controller: UIActivityViewController, dataTypeIdentifierForActivityType: UIActivity.ActivityType?) -> String {
        UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
    }
    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = url.lastPathComponent
        if let icon = UIImage(systemName: "photo") { metadata.iconProvider = NSItemProvider(object: icon) }
        return metadata
    }
}

public final class SaveOriginalToPhotosActivity: UIActivity, @unchecked Sendable {
    private let filesLock = OSAllocatedUnfairLock(initialState: [URL]())

    public override init() {
        super.init()
    }

    public override class var activityCategory: UIActivity.Category { .action }
    public override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType("com.iantruong.imagingsuite.saveOriginalToPhotos")
    }
    public override var activityTitle: String? { "Save Original to Photos" }
    public override var activityImage: UIImage? { UIImage(systemName: "photo.badge.plus") }

    public override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        activityItems.compactMap { ($0 as? URL) ?? ($0 as? PhotoShareItem)?.url }.contains { $0.isFileURL }
    }

    public override func prepare(withActivityItems activityItems: [Any]) {
        let urls = activityItems.compactMap { ($0 as? URL) ?? ($0 as? PhotoShareItem)?.url }.filter { $0.isFileURL }
        filesLock.withLock { $0 = urls }
    }

    public override func perform() {
        let urls = filesLock.withLock { $0 }
        Task {
            do {
                var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                if status == .notDetermined {
                    status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                }
                guard status == .authorized || status == .limited else {
                    await MainActor.run { self.activityDidFinish(false) }
                    return
                }
                try await PHPhotoLibrary.shared().performChanges {
                    for url in urls {
                        let options = PHAssetResourceCreationOptions()
                        options.originalFilename = url.lastPathComponent
                        options.contentType = UTType(filenameExtension: url.pathExtension)
                        options.shouldMoveFile = false
                        PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: options)
                    }
                }
                await MainActor.run { self.activityDidFinish(true) }
            } catch {
                await MainActor.run { self.activityDidFinish(false) }
            }
        }
    }
}
#endif
