import Foundation
#if os(iOS) || os(tvOS) || os(watchOS)
// `os_proc_available_memory()` is exposed by the `os` module (os/proc.h).
// The former `os.proc` submodule import does not exist and failed the arm64 iOS build.
import os
#endif

/// Device memory tier (`docs/DEVELOPMENT.md` Section 4.2).
public enum DeviceTier: String, Codable, Sendable, Equatable {
    /// >= 2.5 GB available memory -> 256×256 input tiles; overlap depends on the recorded model.
    case tierA_HighMemory
    /// < 2.5 GB available memory -> 192×192 input tiles; overlap depends on the recorded model.
    case tierB_ConstrainedMemory
}

/// Tile dimensions and overlap configuration for TruongScaler (`docs/DEVELOPMENT.md` Section 4.2).
public struct TileConfiguration: Codable, Sendable, Equatable {
    public let tier: DeviceTier
    public let inputTileSize: Int
    public let inputOverlap: Int

    public var effectiveInputStride: Int {
        inputTileSize - inputOverlap
    }

    /// Stored dimensions/overlap remain the complete Codable representation. Old QuickSRNet/EDSR
    /// checkpoints therefore retain 24/16px halos; a HAT-S job records its own 32px halo explicitly.
    public init(tier: DeviceTier, backbone: BackboneModelKind = .quickSRNet) {
        self.tier = tier
        switch tier {
        case .tierA_HighMemory:
            self.inputTileSize = 256
            self.inputOverlap = backbone == .hatSmall ? 32 : 24
        case .tierB_ConstrainedMemory:
            self.inputTileSize = 192
            self.inputOverlap = backbone == .hatSmall ? 32 : 16
        }
    }

    public func outputTileSize(for scale: ScaleFactor) -> Int {
        inputTileSize * scale.rawValue
    }

    public func outputOverlap(for scale: ScaleFactor) -> Int {
        inputOverlap * scale.rawValue
    }
}

/// Hardware memory and disk telemetry (`docs/DEVELOPMENT.md` Section 4.2).
public struct HardwareTelemetry: Sendable {
    /// 2.5 GiB (2,684,354,560 bytes)
    public static let tierAThresholdBytes: UInt64 = 2_684_354_560
    /// 1.5 GiB (1,610,612,736 bytes) safety margin for APFS scratch files
    public static let diskSafetyMarginBytes: Int64 = 1_610_612_736

    public static func currentAvailableMemoryBytes() -> UInt64 {
        // Verified against docs/DEVELOPMENT.md Section 4.2: prefer the platform
        // os_proc_available_memory() query on iOS/tvOS/watchOS and fall back to half of physical
        // memory on macOS host unit tests.
        #if os(iOS) || os(tvOS) || os(watchOS)
        let avail = os_proc_available_memory()
        if avail > 0 {
            return UInt64(avail)
        }
        #endif
        return ProcessInfo.processInfo.physicalMemory / 2
    }

    public static func resolveDeviceTier(overrideAvailableBytes: UInt64? = nil) -> DeviceTier {
        let bytes = overrideAvailableBytes ?? currentAvailableMemoryBytes()
        return bytes >= tierAThresholdBytes ? .tierA_HighMemory : .tierB_ConstrainedMemory
    }

    public static func makeTileConfiguration(
        overrideAvailableBytes: UInt64? = nil,
        backbone: BackboneModelKind = .quickSRNet
    ) -> TileConfiguration {
        TileConfiguration(tier: resolveDeviceTier(overrideAvailableBytes: overrideAvailableBytes), backbone: backbone)
    }

    /// Computes 64-byte aligned row stride with overflow checking:
    /// `((width * bytesPerPixel + 63) / 64) * 64`.
    public static func checkedAlignedRowBytes(width: Int, bytesPerPixel: Int = 8) throws -> Int {
        guard width > 0, bytesPerPixel > 0 else {
            throw ScalerError.invalidImageDimensions(width: width, height: bytesPerPixel)
        }
        let (rawBytes, rawOverflow) = width.multipliedReportingOverflow(by: bytesPerPixel)
        guard !rawOverflow else {
            throw ScalerError.invalidImageDimensions(width: width, height: bytesPerPixel)
        }
        let (paddedBytes, paddedOverflow) = rawBytes.addingReportingOverflow(63)
        guard !paddedOverflow, paddedBytes > 0 else {
            throw ScalerError.invalidImageDimensions(width: width, height: bytesPerPixel)
        }
        let (alignedRows, alignedOverflow) = (paddedBytes / 64).multipliedReportingOverflow(by: 64)
        guard !alignedOverflow, alignedRows > 0 else {
            throw ScalerError.invalidImageDimensions(width: width, height: bytesPerPixel)
        }
        return alignedRows
    }

    /// Computes total byte size of a 64-byte row-aligned mmap buffer with overflow checking.
    public static func checkedRequiredMMapBytes(
        width: Int,
        height: Int,
        bytesPerPixel: Int = 8
    ) throws -> Int64 {
        guard height > 0 else {
            throw ScalerError.invalidImageDimensions(width: width, height: height)
        }
        let rowBytes = try checkedAlignedRowBytes(width: width, bytesPerPixel: bytesPerPixel)
        let (total, overflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !overflow, total > 0, total <= Int64.max else {
            throw ScalerError.invalidImageDimensions(width: width, height: height)
        }
        return Int64(total)
    }

    /// Non-throwing compatibility wrapper. Returns 0 for unrepresentable geometry; production
    /// allocation paths must use `checkedAlignedRowBytes`.
    public static func alignedRowBytes(width: Int, bytesPerPixel: Int = 8) -> Int {
        (try? checkedAlignedRowBytes(width: width, bytesPerPixel: bytesPerPixel)) ?? 0
    }

    /// Non-throwing compatibility wrapper. Saturates at `Int64.max` for unrepresentable geometry so
    /// a disk-space check fails instead of trapping; production allocation paths use the checked API.
    public static func requiredMMapBytes(width: Int, height: Int, bytesPerPixel: Int = 8) -> Int64 {
        (try? checkedRequiredMMapBytes(width: width, height: height, bytesPerPixel: bytesPerPixel)) ?? Int64.max
    }

    /// Verifies that `directory` has at least `requiredBytes + diskSafetyMarginBytes` free space.
    public static func verifyDiskSpace(directory: URL, requiredBytes: Int64) throws {
        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        let available: Int64
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            available = important
        } else if let standard = values?.volumeAvailableCapacity {
            available = Int64(standard)
        } else {
            return
        }
        let (totalNeeded, overflow) = requiredBytes.addingReportingOverflow(diskSafetyMarginBytes)
        let requested = overflow ? Int64.max : totalNeeded
        if available < requested {
            throw ScalerError.insufficientDiskSpace(requiredBytes: requested, availableBytes: available)
        }
    }
}
