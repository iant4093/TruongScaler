import Foundation
import Darwin
import os
import TruongScalerCore

/// Disk-backed 16-bit half-float (`RGBAh`, 8 bytes/pixel, 64-byte row-aligned) POSIX `mmap` image buffer.
/// Specification: `docs/DEVELOPMENT.md` Section 1.1.
public final class MMapBuffer: @unchecked Sendable {
    public let fileURL: URL
    public let width: Int
    public let height: Int
    public let bytesPerPixel: Int = 8 // 4 x Float16 (R, G, B, A)
    public let rowBytes: Int          // 64-byte aligned: ((width * 8 + 63) / 64) * 64
    public let totalByteSize: Int

    private let fileDescriptor: Int32
    private let baseRawPointer: UnsafeMutableRawPointer
    private let deleteOnDeinit: Bool
    private let lock = OSAllocatedUnfairLock()

    /// Checked layout arithmetic for the mmap canvas.
    ///
    /// `rowBytes = ((width * bytesPerPixel + 63) / 64) * 64` and
    /// `totalByteSize = rowBytes * height`. Every intermediate is overflow-checked so absurd
    /// width/height values are rejected with `ScalerError.invalidImageDimensions` instead of
    /// trapping the process before any file is truncated or mapped.
    public static func checkedRowAndTotalBytes(
        width: Int,
        height: Int,
        bytesPerPixel: Int = 8
    ) throws -> (rowBytes: Int, totalByteSize: Int) {
        guard width > 0, height > 0, bytesPerPixel > 0 else {
            throw ScalerError.invalidImageDimensions(width: width, height: height)
        }
        let (rawBytes, rawOverflow) = width.multipliedReportingOverflow(by: bytesPerPixel)
        guard !rawOverflow else {
            throw ScalerError.invalidImageDimensions(width: width, height: height)
        }
        let (paddedBytes, paddedOverflow) = rawBytes.addingReportingOverflow(63)
        guard !paddedOverflow else {
            throw ScalerError.invalidImageDimensions(width: width, height: height)
        }
        // `(paddedBytes / 64) * 64 <= paddedBytes`, so this cannot overflow.
        let rowBytes = (paddedBytes / 64) * 64
        guard rowBytes > 0 else {
            throw ScalerError.invalidImageDimensions(width: width, height: height)
        }
        let (totalByteSize, totalOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !totalOverflow, totalByteSize > 0 else {
            throw ScalerError.invalidImageDimensions(width: width, height: height)
        }
        return (rowBytes, totalByteSize)
    }

    public init(
        fileURL: URL,
        width: Int,
        height: Int,
        createIfMissing: Bool = true,
        deleteOnDeinit: Bool = false
    ) throws {
        // Validate geometry with checked arithmetic BEFORE creating the parent directory, opening or
        // truncating the destination file, or calling mmap.
        let layout = try Self.checkedRowAndTotalBytes(width: width, height: height, bytesPerPixel: 8)
        self.fileURL = fileURL
        self.width = width
        self.height = height
        self.rowBytes = layout.rowBytes
        self.totalByteSize = layout.totalByteSize
        self.deleteOnDeinit = deleteOnDeinit

        let parentDir = fileURL.deletingLastPathComponent()
        if createIfMissing {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        let flags: Int32 = O_RDWR | (createIfMissing ? O_CREAT : 0)
        let fd = Darwin.open(fileURL.path, flags, 0o600)
        guard fd >= 0 else {
            throw ScalerError.mmapAllocationFailed(errno: errno, requestedBytes: totalByteSize)
        }

        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw ScalerError.mmapAllocationFailed(errno: err, requestedBytes: totalByteSize)
        }
        if createIfMissing {
            // Create mode owns the file: truncate to exactly the required canvas size so a reused or
            // larger stale file can never expose bytes from a previous job.
            if Darwin.ftruncate(fd, off_t(totalByteSize)) != 0 {
                let err = errno
                Darwin.close(fd)
                throw ScalerError.mmapAllocationFailed(errno: err, requestedBytes: totalByteSize)
            }
        } else {
            // Reopen mode never grows or shrinks an existing canvas. A missing/short/oversized file
            // means the checkpoint and its canvases disagree; reject before mapping or mutating it.
            guard st.st_size == off_t(totalByteSize) else {
                Darwin.close(fd)
                throw ScalerError.mmapAllocationFailed(errno: EINVAL, requestedBytes: totalByteSize)
            }
        }

        guard let mapped = Darwin.mmap(
            nil,
            totalByteSize,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            fd,
            0
        ), mapped != MAP_FAILED else {
            let err = errno
            Darwin.close(fd)
            throw ScalerError.mmapAllocationFailed(errno: err, requestedBytes: totalByteSize)
        }

        _ = Darwin.posix_madvise(mapped, totalByteSize, POSIX_MADV_SEQUENTIAL)
        self.fileDescriptor = fd
        self.baseRawPointer = mapped
    }

    deinit {
        if fileDescriptor >= 0 {
            _ = Darwin.munmap(baseRawPointer, totalByteSize)
            _ = Darwin.close(fileDescriptor)
        }
        if deleteOnDeinit {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    @inline(__always)
    public func unsafePixelPointer(x: Int, y: Int) -> UnsafeMutablePointer<Float16> {
        let clampedX = min(max(0, x), width - 1)
        let clampedY = min(max(0, y), height - 1)
        return baseRawPointer
            .advanced(by: clampedY * rowBytes + clampedX * bytesPerPixel)
            .assumingMemoryBound(to: Float16.self)
    }

    @inline(__always)
    public func unsafeRowPointer(y: Int) -> UnsafeMutableRawPointer {
        let clampedY = min(max(0, y), height - 1)
        return baseRawPointer.advanced(by: clampedY * rowBytes)
    }

    public func writeStrip(
        startY: Int,
        stripHeight: Int,
        from source: UnsafeRawPointer,
        sourceRowBytes: Int
    ) {
        guard stripHeight > 0, startY < height, sourceRowBytes > 0 else { return }
        let clampedStartY = max(0, startY)
        guard clampedStartY < height else { return }
        let maxRows = min(stripHeight, height - clampedStartY)
        guard maxRows > 0 else { return }
        // Row-pitch arithmetic is checked: untrusted source strides must never trap inside the copy.
        let (pixelBytes, pixelOverflow) = width.multipliedReportingOverflow(by: bytesPerPixel)
        guard !pixelOverflow else { return }
        let copyBytes = min(rowBytes, min(sourceRowBytes, pixelBytes))
        guard copyBytes > 0 else { return }
        nonisolated(unsafe) let srcPtr = source
        lock.withLock {
            for r in 0..<maxRows {
                let (sourceOffset, offsetOverflow) = r.multipliedReportingOverflow(by: sourceRowBytes)
                if offsetOverflow { break }
                let dstRow = baseRawPointer.advanced(by: (clampedStartY + r) * rowBytes)
                let srcRow = srcPtr.advanced(by: sourceOffset)
                memcpy(dstRow, srcRow, copyBytes)
            }
        }
    }

    /// Reflects an arbitrary (possibly wildly out-of-range) coordinate into `0 ..< limit` using the
    /// repeating reflection period `2 * limit - 2`. Uses `%` instead of a loop so huge coordinates
    /// cannot spin or trap.
    @inline(__always)
    private static func reflectCoordinate(_ coord: Int, limit: Int) -> Int {
        guard limit > 1 else { return 0 }
        let (doubleLimit, doubleOverflow) = limit.multipliedReportingOverflow(by: 2)
        let period: Int
        if doubleOverflow {
            period = Int.max
        } else {
            period = max(2, doubleLimit - 2)
        }
        var c = coord % period
        if c < 0 {
            c += period
        }
        if c >= limit {
            c = period - c
        }
        return min(max(0, c), limit - 1)
    }

    public func readRegion(
        x: Int,
        y: Int,
        regionWidth: Int,
        regionHeight: Int,
        into destination: UnsafeMutableRawPointer,
        destinationRowBytes: Int
    ) {
        guard regionWidth > 0, regionHeight > 0, destinationRowBytes > 0 else { return }
        let (byteCount, byteOverflow) = regionWidth.multipliedReportingOverflow(by: bytesPerPixel)
        guard !byteOverflow, byteCount > 0, destinationRowBytes >= byteCount else { return }
        // Guard the destination row-pitch multiplication as well.
        let (_, destinationOverflow) = (regionHeight - 1).multipliedReportingOverflow(by: destinationRowBytes)
        guard !destinationOverflow else { return }

        if x >= 0, y >= 0, regionWidth <= width, regionHeight <= height,
           x <= width - regionWidth, y <= height - regionHeight {
            for ry in 0..<regionHeight {
                let srcRow = baseRawPointer.advanced(by: (y + ry) * rowBytes + x * bytesPerPixel)
                let dstRow = destination.advanced(by: ry * destinationRowBytes)
                memcpy(dstRow, srcRow, byteCount)
            }
        } else {
            for ry in 0..<regionHeight {
                let (rawY, yOverflow) = y.addingReportingOverflow(ry)
                let effectiveY = yOverflow ? (ry >= 0 ? Int.max : Int.min) : rawY
                let sy = Self.reflectCoordinate(effectiveY, limit: height)
                let dstRow = destination.advanced(by: ry * destinationRowBytes)
                    .assumingMemoryBound(to: UInt64.self)
                let srcRowBase = baseRawPointer.advanced(by: sy * rowBytes)
                    .assumingMemoryBound(to: UInt64.self)
                for rx in 0..<regionWidth {
                    let (rawX, xOverflow) = x.addingReportingOverflow(rx)
                    let effectiveX = xOverflow ? (rx >= 0 ? Int.max : Int.min) : rawX
                    let sx = Self.reflectCoordinate(effectiveX, limit: width)
                    dstRow[rx] = srcRowBase[sx]
                }
            }
        }
    }

    public func flushToDisk(synchronous: Bool = true) throws {
        let flags = synchronous ? MS_SYNC : MS_ASYNC
        if Darwin.msync(baseRawPointer, totalByteSize, flags) != 0 {
            throw ScalerError.mmapSyncFailed(errno: errno)
        }
    }

    /// Flushes dirty pages covering rows `[startY ..< startY + rowCount]` with a page-aligned
    /// `msync(MS_SYNC)`. This is the per-tile durability primitive: only the rows the tile can have
    /// modified are flushed. Empty or out-of-range requests are a no-op.
    public func flushRange(startY: Int, rowCount: Int) throws {
        guard rowCount > 0, startY >= 0, startY < height else { return }
        let clampedRowCount = min(rowCount, height - startY)
        let pageSize = Int(Darwin.getpagesize())
        let startByte = startY * rowBytes
        let endByte = min(totalByteSize, (startY + clampedRowCount) * rowBytes)
        guard endByte > startByte else { return }
        // msync requires only the address to be page aligned; the length may be an arbitrary byte count.
        let alignedStart = (startByte / pageSize) * pageSize
        let length = endByte - alignedStart
        guard length > 0 else { return }
        if Darwin.msync(baseRawPointer.advanced(by: alignedStart), length, MS_SYNC) != 0 {
            throw ScalerError.mmapSyncFailed(errno: errno)
        }
    }

    public func releaseCleanPages(startY: Int, rowCount: Int) {
        guard rowCount > 0, startY >= 0, startY < height else { return }
        let clampedRowCount = min(rowCount, height - startY)
        let endRow = startY + clampedRowCount
        let pageSize = Int(Darwin.getpagesize())
        let startByte = startY * rowBytes
        let endByte = min(totalByteSize, endRow * rowBytes)
        // Round the start up to the next page boundary without overflowing `Int`.
        let remainder = startByte % pageSize
        let alignment = remainder == 0 ? 0 : pageSize - remainder
        let (candidateStart, startOverflow) = startByte.addingReportingOverflow(alignment)
        guard !startOverflow else { return }
        let alignedStart = candidateStart
        let alignedEnd = (endByte / pageSize) * pageSize
        guard alignedEnd > alignedStart else { return }
        let length = alignedEnd - alignedStart
        let ptr = baseRawPointer.advanced(by: alignedStart)
        _ = Darwin.msync(ptr, length, MS_SYNC)
        _ = Darwin.posix_madvise(ptr, length, POSIX_MADV_DONTNEED)
    }
}
