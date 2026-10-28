import XCTest
@testable import TruongScalerCore
@testable import MMapCanvas

final class MMapCanvasTests: XCTestCase {
    func testBlenderBulkCopyDoesNotReorderAnAliasedFeatherPrefix() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("alias-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = try MMapBuffer(fileURL: url, width: 10, height: 1, createIfMissing: true)
        for x in 0..<10 {
            let pixel = buffer.unsafePixelPointer(x: x, y: 0)
            for channel in 0..<4 { pixel[channel] = Float16(Float(x + 1) / 16) }
        }
        let weight: Float = 0.5 - 0.5 * cosf(Float.pi / 4 * 2.5)
        let expected = Float16((1 - weight) * (1.0 / 16) + weight * (3.0 / 16))
        CausalTileBlender.writeAndFeatherTile(tilePointer: buffer.unsafeRowPointer(y: 0),
            tileRowBytes: buffer.rowBytes, tileWidth: 10, tileHeight: 1,
            destX: -2, destY: 0, leftOverlap: 4, topOverlap: 0, into: buffer)
        XCTAssertEqual(buffer.unsafePixelPointer(x: 0, y: 0)[0].bitPattern, expected.bitPattern)
        XCTAssertEqual(buffer.unsafePixelPointer(x: 2, y: 0)[0], Float16(5.0 / 16))
    }

    func testMMapBufferReadWriteAndPersistence() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmap_persist_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            let buffer = try MMapBuffer(fileURL: tempURL, width: 128, height: 128, createIfMissing: true)
            for y in 0..<128 {
                for x in 0..<128 {
                    let px = buffer.unsafePixelPointer(x: x, y: y)
                    px[0] = Float16(Float(x) / 128.0)
                    px[1] = Float16(Float(y) / 128.0)
                    px[2] = Float16(0.5)
                    px[3] = Float16(1.0)
                }
            }
            try buffer.flushToDisk(synchronous: true)
        }

        let reopened = try MMapBuffer(fileURL: tempURL, width: 128, height: 128, createIfMissing: false)
        let samplePx = reopened.unsafePixelPointer(x: 64, y: 32)
        XCTAssertEqual(Float(samplePx[0]), 64.0 / 128.0, accuracy: 1e-3)
        XCTAssertEqual(Float(samplePx[1]), 32.0 / 128.0, accuracy: 1e-3)
        XCTAssertEqual(Float(samplePx[2]), 0.5, accuracy: 1e-3)
        XCTAssertEqual(Float(samplePx[3]), 1.0, accuracy: 1e-3)
    }

    func testBoundaryReflectionReadRegion() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmap_reflect_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let buffer = try MMapBuffer(fileURL: tempURL, width: 100, height: 100, createIfMissing: true)
        for y in 0..<100 {
            for x in 0..<100 {
                let px = buffer.unsafePixelPointer(x: x, y: y)
                px[0] = Float16(Float(x + y) * 0.01)
                px[1] = Float16(0.25)
                px[2] = Float16(0.75)
                px[3] = Float16(1.0)
            }
        }

        let regionW = 256
        let regionH = 256
        let dstRowBytes = regionW * 8
        let rawDst = UnsafeMutableRawPointer.allocate(byteCount: dstRowBytes * regionH, alignment: 64)
        defer { rawDst.deallocate() }

        buffer.readRegion(
            x: -16,
            y: -16,
            regionWidth: regionW,
            regionHeight: regionH,
            into: rawDst,
            destinationRowBytes: dstRowBytes
        )

        let floats = rawDst.assumingMemoryBound(to: Float16.self)
        for i in 0..<(regionW * regionH * 4) {
            XCTAssertFalse(floats[i].isNaN)
        }
        // Check reflected pixel at (-1, -1) -> should reflect to (1, 1) -> value (1+1)*0.01 = 0.02
        let rx = 15 // x = -16 + 15 = -1 -> reflects to 1
        let ry = 15 // y = -16 + 15 = -1 -> reflects to 1
        let idx = (ry * regionW + rx) * 4
        XCTAssertEqual(Float(floats[idx + 0]), 0.02, accuracy: 1e-3)
        XCTAssertEqual(Float(floats[idx + 3]), 1.0, accuracy: 1e-3)
    }

    func testCausalTileBlenderZeroSeamErrorOnConstantAndLinearGradient() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mmap_blend_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let canvasSize = 512
        let tileSize = 280
        let overlap = 48
        let stride = tileSize - overlap // 232 (0 and 232 cover 0..<512)
        let outputBuffer = try MMapBuffer(fileURL: tempURL, width: canvasSize, height: canvasSize, createIfMissing: true)

        let tileRowBytes = tileSize * 8
        let tileBuf = UnsafeMutableRawPointer.allocate(byteCount: tileRowBytes * tileSize, alignment: 64)
        defer { tileBuf.deallocate() }
        let tilePixels = tileBuf.assumingMemoryBound(to: Float16.self)

        let origins = [0, stride]
        for (rowIdx, oy) in origins.enumerated() {
            for (colIdx, ox) in origins.enumerated() {
                for ly in 0..<tileSize {
                    for lx in 0..<tileSize {
                        let gx = ox + lx
                        let gy = oy + ly
                        let pIdx = (ly * tileSize + lx) * 4
                        tilePixels[pIdx + 0] = Float16(Float(gx) / Float(canvasSize))
                        tilePixels[pIdx + 1] = Float16(Float(gy) / Float(canvasSize))
                        tilePixels[pIdx + 2] = Float16(0.42)
                        tilePixels[pIdx + 3] = Float16(1.0)
                    }
                }
                CausalTileBlender.writeAndFeatherTile(
                    tilePointer: tileBuf,
                    tileRowBytes: tileRowBytes,
                    tileWidth: tileSize,
                    tileHeight: tileSize,
                    destX: ox,
                    destY: oy,
                    leftOverlap: colIdx > 0 ? overlap : 0,
                    topOverlap: rowIdx > 0 ? overlap : 0,
                    into: outputBuffer
                )
            }
        }

        var maxErr: Float = 0.0
        for y in 0..<canvasSize {
            for x in 0..<canvasSize {
                let px = outputBuffer.unsafePixelPointer(x: x, y: y)
                let expectedR = Float(x) / Float(canvasSize)
                let expectedG = Float(y) / Float(canvasSize)
                let errR = abs(Float(px[0]) - expectedR)
                let errG = abs(Float(px[1]) - expectedG)
                let errB = abs(Float(px[2]) - 0.42)
                maxErr = max(maxErr, max(errR, max(errG, errB)))
            }
        }
        XCTAssertLessThan(maxErr, 1e-3, "Expected zero visible seam across 4-way tile overlap")
    }

    // MARK: - Strict reopen / range flush

    func testMMapBufferStrictReopenRejectsMissingTruncatedAndOversizedFiles() throws {
        let directory = try makeScratchDirectory("mmap-strict")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Missing file: reopen mode must never create it.
        let missingURL = directory.appendingPathComponent("missing.bin")
        XCTAssertThrowsError(try MMapBuffer(
            fileURL: missingURL,
            width: 16,
            height: 8,
            createIfMissing: false
        )) { error in
            guard case ScalerError.mmapAllocationFailed = error else {
                XCTFail("Expected mmapAllocationFailed for a missing reopen, got \(error)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))

        // Create mode truncates to exactly rowBytes * height.
        let canvasURL = directory.appendingPathComponent("canvas.bin")
        try Data(repeating: 0x7f, count: 100_000).write(to: canvasURL)
        let expectedTotal: Int
        do {
            let created = try MMapBuffer(fileURL: canvasURL, width: 40, height: 24, createIfMissing: true)
            XCTAssertEqual(created.rowBytes % 64, 0, "Rows must stay 64-byte aligned.")
            XCTAssertEqual(created.rowBytes, ((40 * 8 + 63) / 64) * 64)
            expectedTotal = created.totalByteSize
            fillIntegerPattern(created)
            try created.flushToDisk(synchronous: true)
        }
        XCTAssertEqual(try fileSize(canvasURL), expectedTotal, "Create mode must truncate stale bytes exactly.")

        // Truncated file: reject without extending it.
        do {
            let handle = try FileHandle(forWritingTo: canvasURL)
            try handle.truncate(atOffset: 8)
            try handle.close()
        }
        XCTAssertEqual(try fileSize(canvasURL), 8)
        XCTAssertThrowsError(try MMapBuffer(
            fileURL: canvasURL,
            width: 40,
            height: 24,
            createIfMissing: false
        )) { error in
            guard case ScalerError.mmapAllocationFailed = error else {
                XCTFail("Expected mmapAllocationFailed for a truncated reopen, got \(error)")
                return
            }
        }
        XCTAssertEqual(try fileSize(canvasURL), 8, "A rejected reopen must never extend the file.")

        // Oversized file: also reject without truncating it.
        let oversizedURL = directory.appendingPathComponent("oversized.bin")
        do {
            let created = try MMapBuffer(fileURL: oversizedURL, width: 40, height: 24, createIfMissing: true)
            try created.flushToDisk(synchronous: true)
        }
        let oversizedTotal = try fileSize(oversizedURL)
        do {
            let handle = try FileHandle(forWritingTo: oversizedURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x00]))
            try handle.close()
        }
        XCTAssertThrowsError(try MMapBuffer(
            fileURL: oversizedURL,
            width: 40,
            height: 24,
            createIfMissing: false
        )) { error in
            guard case ScalerError.mmapAllocationFailed = error else {
                XCTFail("Expected mmapAllocationFailed for an oversized reopen, got \(error)")
                return
            }
        }
        XCTAssertEqual(try fileSize(oversizedURL), oversizedTotal + 1, "A rejected reopen must never truncate the file.")

        // Wrong dimensions for the stored byte size are also rejected.
        let wrongDimensionsURL = directory.appendingPathComponent("wrong-dimensions.bin")
        do {
            let created = try MMapBuffer(fileURL: wrongDimensionsURL, width: 40, height: 24, createIfMissing: true)
            try created.flushToDisk(synchronous: true)
        }
        XCTAssertThrowsError(try MMapBuffer(
            fileURL: wrongDimensionsURL,
            width: 80,
            height: 24,
            createIfMissing: false
        )) { error in
            guard case ScalerError.mmapAllocationFailed = error else {
                XCTFail("Expected mmapAllocationFailed for mismatched dimensions, got \(error)")
                return
            }
        }
    }

    func testMMapBufferFlushRangeAndBoundaryReflectionArePreserved() throws {
        let directory = try makeScratchDirectory("mmap-flush-range")
        defer { try? FileManager.default.removeItem(at: directory) }
        let canvasURL = directory.appendingPathComponent("canvas.bin")

        do {
            let buffer = try MMapBuffer(fileURL: canvasURL, width: 64, height: 48, createIfMissing: true)
            fillIntegerPattern(buffer)
            XCTAssertEqual(buffer.rowBytes % 64, 0)

            // Empty / out-of-range requests are documented no-ops.
            try buffer.flushRange(startY: 0, rowCount: 0)
            try buffer.flushRange(startY: 48, rowCount: 5)
            try buffer.flushRange(startY: 1_000, rowCount: 1)
            try buffer.flushRange(startY: -4, rowCount: 3)

            // Flush only the rows a tile would have touched.
            try buffer.flushRange(startY: 10, rowCount: 5)

            // Boundary reflection still reads in-bounds pixels for out-of-bounds coordinates.
            let regionW = 6
            let regionH = 6
            let rawRegion = UnsafeMutableRawPointer.allocate(byteCount: regionW * regionH * 8, alignment: 8)
            defer { rawRegion.deallocate() }
            buffer.readRegion(
                x: -2,
                y: -2,
                regionWidth: regionW,
                regionHeight: regionH,
                into: rawRegion,
                destinationRowBytes: regionW * 8
            )
            let regionPixels = rawRegion.assumingMemoryBound(to: Float16.self)
            // (-2, -2) reflects to (2, 2); (-1, -1) to (1, 1); (0, 0) stays (0, 0).
            XCTAssertEqual(Float(regionPixels[(0 * regionW + 0) * 4]), 2 * 8 + 2)
            XCTAssertEqual(Float(regionPixels[(1 * regionW + 1) * 4]), 1 * 8 + 1)
            XCTAssertEqual(Float(regionPixels[(2 * regionW + 2) * 4]), 0)
        }

        let reopened = try MMapBuffer(fileURL: canvasURL, width: 64, height: 48, createIfMissing: false)
        for y in stride(from: 10, to: 15, by: 1) {
            for x in 0..<64 {
                XCTAssertEqual(Float(reopened.unsafePixelPointer(x: x, y: y)[0]), Float(y * 8 + x % 8))
            }
        }
        XCTAssertEqual(Float(reopened.unsafePixelPointer(x: 0, y: 47)[0]), Float(47 * 8))
    }

    // MARK: - Durable tile undo journal

    func testTileUndoJournalPublishRestoreRoundTripAndCleanup() throws {
        let directory = try makeScratchDirectory("journal-roundtrip")
        defer { try? FileManager.default.removeItem(at: directory) }

        let canvasURL = directory.appendingPathComponent("canvas.bin")
        let canvas = try MMapBuffer(fileURL: canvasURL, width: 96, height: 80, createIfMissing: true)
        fillIntegerPattern(canvas)
        try canvas.flushToDisk(synchronous: true)

        let journal = TileUndoJournal(workingDirectory: directory)
        let jobID = UUID()
        let rect = try XCTUnwrap(TileJournalRect.clipped(
            destX: 40,
            destY: 30,
            size: 64,
            canvasWidth: canvas.width,
            canvasHeight: canvas.height
        ))
        XCTAssertEqual(rect, TileJournalRect(x: 40, y: 30, width: 56, height: 50))

        let before = snapshot(canvas)
        let manifest = try journal.publish(jobID: jobID, tileIndex: 3, rect: rect, from: canvas)

        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.jobID, jobID)
        XCTAssertEqual(manifest.tileIndex, 3)
        XCTAssertEqual(manifest.x, rect.x)
        XCTAssertEqual(manifest.y, rect.y)
        XCTAssertEqual(manifest.width, rect.width)
        XCTAssertEqual(manifest.height, rect.height)
        XCTAssertEqual(manifest.byteCount, 56 * 8 * 50)
        XCTAssertEqual(manifest.sha256.count, 64)
        XCTAssertTrue(manifest.sha256.allSatisfy { $0.isHexDigit })

        let undoURL = try journal.undoFileURL(jobID: jobID, tileIndex: 3)
        let manifestURL = try journal.manifestFileURL(jobID: jobID, tileIndex: 3)
        XCTAssertEqual(try fileSize(undoURL), manifest.byteCount)
        XCTAssertGreaterThan(try fileSize(manifestURL), 0)
        XCTAssertEqual(try fileSize(canvasURL), canvas.totalByteSize)

        // Mutate the entire canvas, then restore only the journaled rectangle.
        fillConstant(canvas, value: 9)
        let records = try journal.scan(jobID: jobID)
        XCTAssertEqual(records.count, 1)
        try journal.restore(records[0], into: canvas, expectedJobID: jobID, expectedTileIndex: 3, expectedRect: rect)

        let after = snapshot(canvas)
        for y in 0..<canvas.height {
            for x in 0..<canvas.width {
                let offset = (y * canvas.width + x) * 4
                for channel in 0..<4 {
                    let inside = x >= rect.x && x < rect.x + rect.width
                        && y >= rect.y && y < rect.y + rect.height
                    XCTAssertEqual(
                        after[offset + channel],
                        inside ? before[offset + channel] : 9,
                        "x=\(x) y=\(y) channel=\(channel)"
                    )
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: undoURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))

        // `discard(committedTiles:)` keeps uncommitted journals and removes committed ones.
        _ = try journal.publish(jobID: jobID, tileIndex: 1, rect: rect, from: canvas)
        _ = try journal.publish(jobID: jobID, tileIndex: 2, rect: rect, from: canvas)
        try journal.discard(committedTiles: 1, jobID: jobID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try journal.manifestFileURL(jobID: jobID, tileIndex: 1).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try journal.manifestFileURL(jobID: jobID, tileIndex: 2).path))
    }

    func testTileUndoJournalRejectsCorruptTruncatedAndMismatchedJournals() throws {
        let directory = try makeScratchDirectory("journal-reject")
        defer { try? FileManager.default.removeItem(at: directory) }

        let canvas = try MMapBuffer(
            fileURL: directory.appendingPathComponent("canvas.bin"),
            width: 64,
            height: 48,
            createIfMissing: true
        )
        fillIntegerPattern(canvas)
        try canvas.flushToDisk(synchronous: true)

        let journal = TileUndoJournal(workingDirectory: directory)
        let jobID = UUID()
        let rect = try XCTUnwrap(TileJournalRect.clipped(
            destX: 0, destY: 0, size: 64, canvasWidth: 64, canvasHeight: 48
        ))
        _ = try journal.publish(jobID: jobID, tileIndex: 0, rect: rect, from: canvas)

        let undoURL = try journal.undoFileURL(jobID: jobID, tileIndex: 0)
        let manifestURL = try journal.manifestFileURL(jobID: jobID, tileIndex: 0)
        let originalUndo = try Data(contentsOf: undoURL)
        let originalManifest = try Data(contentsOf: manifestURL)
        let canvasBefore = snapshot(canvas)

        func assertRestoreRejected(
            expectedJobID: UUID? = nil,
            expectedTileIndex: Int? = nil,
            expectedRect: TileJournalRect? = nil,
            line: UInt = #line
        ) {
            do {
                let record = try journal.scan(jobID: jobID).first
                let resolved = try XCTUnwrap(record, line: line)
                try journal.restore(
                    resolved,
                    into: canvas,
                    expectedJobID: expectedJobID,
                    expectedTileIndex: expectedTileIndex,
                    expectedRect: expectedRect
                )
                XCTFail("Restore must reject this journal.", line: line)
            } catch let error as ScalerError {
                guard case .checkpointCorrupted = error else {
                    XCTFail("Expected checkpointCorrupted, got \(error)", line: line)
                    return
                }
            } catch {
                XCTFail("Expected checkpointCorrupted, got \(error)", line: line)
            }
            XCTAssertEqual(snapshot(canvas), canvasBefore, "A rejected restore must not modify output.", line: line)
        }

        // Truncated undo bytes.
        try Data(originalUndo.prefix(11)).write(to: undoURL)
        assertRestoreRejected()
        XCTAssertEqual(try fileSize(undoURL), 11, "A rejected journal must not be rewritten or grown.")
        XCTAssertEqual(try fileSize(manifestURL), originalManifest.count)

        // Same-size digest mismatch.
        var flipped = originalUndo
        flipped[0] ^= 0xFF
        try flipped.write(to: undoURL)
        assertRestoreRejected()

        // Valid bytes but mismatched identity / tile / rectangle expectations.
        try originalUndo.write(to: undoURL)
        assertRestoreRejected(expectedJobID: UUID())
        assertRestoreRejected(expectedTileIndex: 1)
        assertRestoreRejected(expectedRect: TileJournalRect(x: 4, y: 0, width: 60, height: 48))
        XCTAssertTrue(FileManager.default.fileExists(atPath: undoURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))

        // Structurally invalid manifest byteCount.
        var manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: originalManifest) as? [String: Any]
        )
        manifestObject["byteCount"] = 1
        try JSONSerialization.data(withJSONObject: manifestObject).write(to: manifestURL)
        XCTAssertThrowsError(try journal.scan(jobID: jobID)) { error in
            guard case ScalerError.checkpointCorrupted = error else {
                XCTFail("Expected checkpointCorrupted, got \(error)")
                return
            }
        }

        // Manifest identity must match the filename (wrong job ID / wrong tile index).
        manifestObject["byteCount"] = rect.byteCount
        manifestObject["jobID"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: manifestObject).write(to: manifestURL)
        XCTAssertThrowsError(try journal.scan(jobID: jobID))

        manifestObject["jobID"] = jobID.uuidString
        manifestObject["tileIndex"] = 9
        try JSONSerialization.data(withJSONObject: manifestObject).write(to: manifestURL)
        XCTAssertThrowsError(try journal.scan(jobID: jobID))

        // Restore the valid manifest, then prove an unpublished `.undo` orphan and a leftover temp file
        // are cleaned up without being treated as (or modifying) output.
        try originalManifest.write(to: manifestURL)
        try Data([0x00]).write(to: try journal.undoFileURL(jobID: jobID, tileIndex: 5))
        let tempURL = directory.appendingPathComponent("journal_\(jobID.uuidString)_4.undo.tmp-\(UUID().uuidString)")
        try Data([0x01]).write(to: tempURL)
        let surviving = try journal.scan(jobID: jobID)
        XCTAssertEqual(surviving.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try journal.undoFileURL(jobID: jobID, tileIndex: 5).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        XCTAssertEqual(snapshot(canvas), canvasBefore)
        XCTAssertEqual(try fileSize(canvas.fileURL), canvas.totalByteSize)
    }

    func testTileUndoJournalRecoverRestoresUncommittedAndRejectsMultipleUncommitted() throws {
        let directory = try makeScratchDirectory("journal-recover")
        defer { try? FileManager.default.removeItem(at: directory) }

        let canvas = try MMapBuffer(
            fileURL: directory.appendingPathComponent("canvas.bin"),
            width: 96,
            height: 80,
            createIfMissing: true
        )
        fillIntegerPattern(canvas)
        try canvas.flushToDisk(synchronous: true)

        let journal = TileUndoJournal(workingDirectory: directory)
        let jobID = UUID()
        let rect0 = try XCTUnwrap(TileJournalRect.clipped(destX: 0, destY: 0, size: 48, canvasWidth: 96, canvasHeight: 80))
        let rect1 = try XCTUnwrap(TileJournalRect.clipped(destX: 48, destY: 0, size: 48, canvasWidth: 96, canvasHeight: 80))
        let rect2 = try XCTUnwrap(TileJournalRect.clipped(destX: 0, destY: 48, size: 48, canvasWidth: 96, canvasHeight: 80))
        let expectedRects = [0: rect0, 1: rect1, 2: rect2]

        let pristine = snapshot(canvas)
        _ = try journal.publish(jobID: jobID, tileIndex: 0, rect: rect0, from: canvas)
        fillRect(canvas, rect: rect0, value: 3)
        let afterTile0 = snapshot(canvas)

        _ = try journal.publish(jobID: jobID, tileIndex: 1, rect: rect1, from: canvas)
        fillRect(canvas, rect: rect1, value: 5)

        // Tile 0 is committed; only tile 1's rollback applies.
        let restoredTileIndex = try journal.recover(
            jobID: jobID,
            lastCompletedTileIndex: 0,
            totalTiles: 3,
            expectedRects: expectedRects,
            into: canvas
        )
        XCTAssertEqual(restoredTileIndex, 1)
        let recovered = snapshot(canvas)
        for y in 0..<canvas.height {
            for x in 0..<canvas.width {
                let offset = (y * canvas.width + x) * 4
                let inRect0 = x < 48 && y < 48
                let inRect1 = x >= 48 && y < 48
                if inRect0 {
                    XCTAssertEqual(recovered[offset], afterTile0[offset], "Committed tile must not roll back.")
                } else if inRect1 {
                    XCTAssertEqual(recovered[offset], pristine[offset], "Uncommitted tile must roll back exactly.")
                } else {
                    XCTAssertEqual(recovered[offset], pristine[offset])
                }
            }
        }
        XCTAssertTrue(try journal.scan(jobID: jobID).isEmpty, "Recovery must consume both sidecars.")

        // Two uncommitted journals are impossible in a correct sequence: fail before touching output.
        _ = try journal.publish(jobID: jobID, tileIndex: 1, rect: rect1, from: canvas)
        _ = try journal.publish(jobID: jobID, tileIndex: 2, rect: rect2, from: canvas)
        let beforeReject = snapshot(canvas)
        XCTAssertThrowsError(try journal.recover(
            jobID: jobID,
            lastCompletedTileIndex: 0,
            totalTiles: 3,
            expectedRects: expectedRects,
            into: canvas
        )) { error in
            guard case ScalerError.checkpointCorrupted = error else {
                XCTFail("Expected checkpointCorrupted, got \(error)")
                return
            }
        }
        XCTAssertEqual(snapshot(canvas), beforeReject)
        XCTAssertEqual(try fileSize(canvas.fileURL), canvas.totalByteSize)

        // A journal whose tile index is outside the plan is unexpected state.
        XCTAssertThrowsError(try journal.recover(
            jobID: jobID,
            lastCompletedTileIndex: 2,
            totalTiles: 2,
            expectedRects: expectedRects,
            into: canvas
        ))
    }

    // MARK: - Helpers

    private func makeScratchDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MMapCanvasTests_\(label)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Integer-valued Float16 channels so restored bytes compare exactly.
    private func fillIntegerPattern(_ buffer: MMapBuffer) {
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let pixel = buffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = Float16(y * 8 + x % 8)
                pixel[1] = Float16(y % 32)
                pixel[2] = Float16(x % 16)
                pixel[3] = Float16(1)
            }
        }
    }

    private func fillConstant(_ buffer: MMapBuffer, value: Float) {
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let pixel = buffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = Float16(value)
                pixel[1] = Float16(value)
                pixel[2] = Float16(value)
                pixel[3] = Float16(value)
            }
        }
    }

    private func fillRect(_ buffer: MMapBuffer, rect: TileJournalRect, value: Float) {
        for y in rect.y..<(rect.y + rect.height) {
            for x in rect.x..<(rect.x + rect.width) {
                let pixel = buffer.unsafePixelPointer(x: x, y: y)
                pixel[0] = Float16(value)
                pixel[1] = Float16(value)
                pixel[2] = Float16(value)
                pixel[3] = Float16(value)
            }
        }
    }

    private func snapshot(_ buffer: MMapBuffer) -> [Float16] {
        var pixels = [Float16](repeating: 0, count: buffer.width * buffer.height * 4)
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let source = buffer.unsafePixelPointer(x: x, y: y)
                let offset = (y * buffer.width + x) * 4
                pixels[offset] = source[0]
                pixels[offset + 1] = source[1]
                pixels[offset + 2] = source[2]
                pixels[offset + 3] = source[3]
            }
        }
        return pixels
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? -1
    }
}

// MARK: - R2 review probes: crash-safe recovery cleanup + exact frontier

extension MMapCanvasTests {
    func testCodexReviewRejectsUnexpectedFutureJournal() throws {
        let directory = try makeScratchDirectory("review-future-journal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let canvas = try MMapBuffer(
            fileURL: directory.appendingPathComponent("canvas.bin"),
            width: 16,
            height: 16,
            createIfMissing: true
        )
        fillConstant(canvas, value: 2)
        let journal = TileUndoJournal(workingDirectory: directory)
        let jobID = UUID()
        let rect = TileJournalRect(x: 0, y: 0, width: 8, height: 8)
        try journal.publish(jobID: jobID, tileIndex: 3, rect: rect, from: canvas)
        fillConstant(canvas, value: 9)
        let before = snapshot(canvas)
        XCTAssertThrowsError(try journal.recover(
            jobID: jobID,
            lastCompletedTileIndex: 0,
            totalTiles: 4,
            expectedRects: [0: rect, 1: rect, 2: rect, 3: rect],
            into: canvas
        ), "Only tile 1 can be uncommitted after committed tile 0") { error in
            guard case ScalerError.checkpointCorrupted = error else {
                XCTFail("Expected checkpointCorrupted, got \(error)")
                return
            }
        }
        XCTAssertEqual(snapshot(canvas), before, "Unexpected journal must not mutate output")
        XCTAssertEqual(try fileSize(canvas.fileURL), canvas.totalByteSize)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try journal.manifestFileURL(jobID: jobID, tileIndex: 3).path
        ), "A rejected journal must not be deleted before validation completes.")
    }

    /// Exact review probe state: the old cleanup ordering deleted `.undo` but crashed before removing
    /// the pending manifest. The canvas still holds the exact journaled pre-blend bytes, so the live
    /// canvas digest proves nothing needs rewriting; recovery must be resumable, not `checkpointCorrupted`.
    func testCodexReviewRecoveryCleanupInterruptionRemainsResumable() throws {
        let directory = try makeScratchDirectory("review-cleanup-interruption")
        defer { try? FileManager.default.removeItem(at: directory) }
        let canvas = try MMapBuffer(
            fileURL: directory.appendingPathComponent("canvas.bin"),
            width: 16,
            height: 16,
            createIfMissing: true
        )
        fillConstant(canvas, value: 2)
        try canvas.flushToDisk(synchronous: true)
        let journal = TileUndoJournal(workingDirectory: directory)
        let jobID = UUID()
        let rect = TileJournalRect(x: 0, y: 0, width: 8, height: 8)
        try journal.publish(jobID: jobID, tileIndex: 0, rect: rect, from: canvas)
        let pristine = snapshot(canvas)

        // Exact persistent state reached during the old successful restore cleanup: restored/flushed
        // canvas, undo unlink complete, manifest unlink not yet done. No process-kill claim.
        try FileManager.default.removeItem(at: try journal.undoFileURL(jobID: jobID, tileIndex: 0))
        let recovered = try journal.recover(
            jobID: jobID,
            lastCompletedTileIndex: -1,
            totalTiles: 1,
            expectedRects: [0: rect],
            into: canvas
        )
        XCTAssertEqual(recovered, 0)
        XCTAssertEqual(snapshot(canvas), pristine, "Already-restored canvas must not be rewritten.")
        XCTAssertTrue(try journal.scan(jobID: jobID).isEmpty)
        XCTAssertNil(try journal.recover(
            jobID: jobID,
            lastCompletedTileIndex: -1,
            totalTiles: 1,
            expectedRects: [0: rect],
            into: canvas
        ), "Repeated recovery of a clean journal must be a no-op.")
    }

    /// A pending manifest with missing undo bytes is corrupt (and must not be accepted as success)
    /// when the live canvas rectangle does not match the recorded original-bytes digest.
    func testCodexReviewPendingManifestWithMissingUndoAndChangedCanvasIsCorrupt() throws {
        let directory = try makeScratchDirectory("review-missing-undo-mismatch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let canvas = try MMapBuffer(
            fileURL: directory.appendingPathComponent("canvas.bin"),
            width: 16,
            height: 16,
            createIfMissing: true
        )
        fillConstant(canvas, value: 2)
        try canvas.flushToDisk(synchronous: true)
        let journal = TileUndoJournal(workingDirectory: directory)
        let jobID = UUID()
        let rect = TileJournalRect(x: 0, y: 0, width: 8, height: 8)
        try journal.publish(jobID: jobID, tileIndex: 0, rect: rect, from: canvas)
        try FileManager.default.removeItem(at: try journal.undoFileURL(jobID: jobID, tileIndex: 0))

        // The canvas rectangle no longer matches the journaled original bytes: rollback cannot be
        // proven, so this is corruption — not silent success.
        fillRect(canvas, rect: rect, value: 9)
        let before = snapshot(canvas)
        XCTAssertThrowsError(try journal.recover(
            jobID: jobID,
            lastCompletedTileIndex: -1,
            totalTiles: 1,
            expectedRects: [0: rect],
            into: canvas
        )) { error in
            guard case ScalerError.checkpointCorrupted = error else {
                XCTFail("Expected checkpointCorrupted, got \(error)")
                return
            }
        }
        XCTAssertEqual(snapshot(canvas), before, "Corrupt state must not mutate the canvas.")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try journal.manifestFileURL(jobID: jobID, tileIndex: 0).path
        ), "Corrupt state must fail closed without deleting the pending manifest.")
    }

    /// Deterministic fault injection at every recovery/cleanup boundary. Each boundary persists a
    /// partial state, then a fresh `recover` must resume idempotently to exact pristine pixels.
    /// This is persistent-state simulation, NOT a SIGKILL claim.
    func testCodexReviewRecoveryFaultBoundariesAreIdempotentAndPixelExact() throws {
        struct SimulatedInterruption: Error {}

        for faultPoint in TileJournalRecoveryFaultPoint.allCases {
            let directory = try makeScratchDirectory("fault-\(faultPoint.rawValue)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let canvas = try MMapBuffer(
                fileURL: directory.appendingPathComponent("canvas.bin"),
                width: 16,
                height: 16,
                createIfMissing: true
            )
            fillConstant(canvas, value: 2)
            try canvas.flushToDisk(synchronous: true)
            let pristine = snapshot(canvas)

            let journal = TileUndoJournal(workingDirectory: directory)
            let jobID = UUID()
            let rect = TileJournalRect(x: 2, y: 2, width: 8, height: 8)
            try journal.publish(jobID: jobID, tileIndex: 0, rect: rect, from: canvas)
            fillRect(canvas, rect: rect, value: 9)
            XCTAssertNotEqual(snapshot(canvas), pristine)

            let manifestURL = try journal.manifestFileURL(jobID: jobID, tileIndex: 0)
            let undoURL = try journal.undoFileURL(jobID: jobID, tileIndex: 0)
            let markerURL = try journal.restoredMarkerFileURL(jobID: jobID, tileIndex: 0)

            XCTAssertThrowsError(try journal.recover(
                jobID: jobID,
                lastCompletedTileIndex: -1,
                totalTiles: 1,
                expectedRects: [0: rect],
                into: canvas,
                faultHandler: { point in
                    if point == faultPoint { throw SimulatedInterruption() }
                }
            )) { error in
                XCTAssertTrue(
                    error is SimulatedInterruption,
                    "Expected a simulated interruption at \(faultPoint), got \(error)"
                )
            }

            // Assert the exact durable state each boundary leaves behind.
            switch faultPoint {
            case .afterRollbackWriteBeforeFlush, .afterRollbackFlush:
                XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path), "\(faultPoint)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: undoURL.path), "\(faultPoint)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path), "\(faultPoint)")
            case .afterManifestRetirementBeforeUndoRemoval:
                XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path), "\(faultPoint)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: undoURL.path), "\(faultPoint)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path), "\(faultPoint)")
            case .afterUndoRemovalBeforeMarkerRemoval:
                XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path), "\(faultPoint)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: undoURL.path), "\(faultPoint)")
                XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path), "\(faultPoint)")
            case .afterMarkerRemovalBeforeDirectorySync, .afterCleanupCompleted:
                XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path), "\(faultPoint)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: undoURL.path), "\(faultPoint)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path), "\(faultPoint)")
            }

            // Resuming must finish the rollback from whatever durable state was left behind.
            let recovered = try journal.recover(
                jobID: jobID,
                lastCompletedTileIndex: -1,
                totalTiles: 1,
                expectedRects: [0: rect],
                into: canvas
            )
            switch faultPoint {
            case .afterMarkerRemovalBeforeDirectorySync, .afterCleanupCompleted:
                XCTAssertNil(recovered, "Cleanup had already finished at \(faultPoint)")
            default:
                XCTAssertEqual(recovered, 0, "Recovery must report the rolled-back tile at \(faultPoint)")
            }
            XCTAssertEqual(snapshot(canvas), pristine, "Exact pristine pixels after \(faultPoint)")
            XCTAssertEqual(try fileSize(canvas.fileURL), canvas.totalByteSize, "\(faultPoint)")
            XCTAssertTrue(try journal.scan(jobID: jobID).isEmpty, "\(faultPoint)")
            XCTAssertNil(try journal.recover(
                jobID: jobID,
                lastCompletedTileIndex: -1,
                totalTiles: 1,
                expectedRects: [0: rect],
                into: canvas
            ), "Repeated recovery must be idempotent at \(faultPoint)")
            XCTAssertEqual(snapshot(canvas), pristine, "Repeated recovery must not change pixels at \(faultPoint)")
        }
    }

    func testUnreadableJournalDirectoryRefusesRecoveryAndPreservesPendingOverlap() throws {
        let fileManager = FileManager.default
        let directory = try makeScratchDirectory("journal-unreadable-directory")
        let originalPermissions = try XCTUnwrap(
            fileManager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        )
        defer {
            try? fileManager.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: directory.path)
            try? fileManager.removeItem(at: directory)
        }

        let canvas = try MMapBuffer(
            fileURL: directory.appendingPathComponent("canvas.bin"), width: 16, height: 16
        )
        fillConstant(canvas, value: 2)
        try canvas.flushToDisk(synchronous: true)
        let committedPixels = snapshot(canvas)
        let journal = TileUndoJournal(workingDirectory: directory)
        let jobID = UUID()
        let rect = TileJournalRect(x: 6, y: 0, width: 10, height: 12)
        try journal.publish(jobID: jobID, tileIndex: 1, rect: rect, from: canvas)

        // Reproduce an interrupted causal blend over a previously committed tile's overlap.
        let tile = [Float16](repeating: 9, count: 12 * 12 * 4)
        tile.withUnsafeBytes { bytes in
            CausalTileBlender.writeAndFeatherTile(
                tilePointer: bytes.baseAddress!, tileRowBytes: 12 * 8,
                tileWidth: 12, tileHeight: 12, destX: 6, destY: 0,
                leftOverlap: 6, topOverlap: 0, into: canvas
            )
        }
        try canvas.flushRange(startY: rect.y, rowCount: rect.height)
        let interruptedPixels = snapshot(canvas)
        XCTAssertNotEqual(interruptedPixels, committedPixels)
        let manifestURL = try journal.manifestFileURL(jobID: jobID, tileIndex: 1)
        let undoURL = try journal.undoFileURL(jobID: jobID, tileIndex: 1)
        let manifestBytes = try Data(contentsOf: manifestURL)
        let undoBytes = try Data(contentsOf: undoURL)

        // Named sidecar reads remain possible with owner write/execute permission, while listing
        // fails. Recovery must distinguish that failure from a successfully read empty directory.
        try fileManager.setAttributes([.posixPermissions: 0o300], ofItemAtPath: directory.path)
        let enumerationDenied: Bool
        do {
            _ = try fileManager.contentsOfDirectory(atPath: directory.path)
            enumerationDenied = false
        } catch {
            enumerationDenied = true
        }
        guard enumerationDenied else {
            throw XCTSkip("This host bypasses directory read permissions; the denial fixture is unavailable.")
        }
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBytes)
        XCTAssertEqual(try Data(contentsOf: undoURL), undoBytes)

        XCTAssertThrowsError(try journal.recover(
            jobID: jobID, lastCompletedTileIndex: 0, totalTiles: 2,
            expectedRects: [1: rect], into: canvas
        ))
        XCTAssertThrowsError(try journal.scan(jobID: jobID))
        XCTAssertThrowsError(try journal.discard(committedTiles: 0, jobID: jobID))
        XCTAssertThrowsError(try journal.removeAllJournalFiles(jobID: jobID))
        XCTAssertEqual(snapshot(canvas), interruptedPixels, "Refused recovery must not write the canvas.")
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBytes)
        XCTAssertEqual(try Data(contentsOf: undoURL), undoBytes)

        try fileManager.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: directory.path)
        XCTAssertEqual(try journal.recover(
            jobID: jobID, lastCompletedTileIndex: 0, totalTiles: 2,
            expectedRects: [1: rect], into: canvas
        ), 1)
        XCTAssertEqual(snapshot(canvas), committedPixels, "Restored access must permit exact rollback.")
        XCTAssertTrue(try journal.scan(jobID: jobID).isEmpty)
        XCTAssertNil(try journal.recover(
            jobID: jobID, lastCompletedTileIndex: 0, totalTiles: 2,
            expectedRects: [1: rect], into: canvas
        ))
        XCTAssertEqual(snapshot(canvas), committedPixels)
    }

    func testCodexReviewCorruptRestoredMarkersAreRejectedBeforeMutation() throws {
        // 1. Malformed marker JSON.
        do {
            let state = try makeRestoredMarkerState("marker-malformed")
            defer { try? FileManager.default.removeItem(at: state.directory) }
            try Data("not-a-manifest".utf8).write(to: state.markerURL)
            let before = snapshot(state.canvas)
            assertMarkerCorrupted(state, canvasBefore: before)
            XCTAssertTrue(FileManager.default.fileExists(atPath: state.markerURL.path))
        }

        // 2. Marker whose embedded job ID disagrees with its filename/job.
        do {
            let state = try makeRestoredMarkerState("marker-wrong-job")
            defer { try? FileManager.default.removeItem(at: state.directory) }
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: state.markerURL)) as? [String: Any]
            )
            object["jobID"] = UUID().uuidString
            try JSONSerialization.data(withJSONObject: object).write(to: state.markerURL)
            let before = snapshot(state.canvas)
            assertMarkerCorrupted(state, canvasBefore: before)
            XCTAssertTrue(FileManager.default.fileExists(atPath: state.markerURL.path))
        }

        // 3. Marker for a future tile that is not the exact next frontier.
        do {
            let directory = try makeScratchDirectory("marker-future-tile")
            defer { try? FileManager.default.removeItem(at: directory) }
            let canvas = try MMapBuffer(
                fileURL: directory.appendingPathComponent("canvas.bin"),
                width: 16,
                height: 16,
                createIfMissing: true
            )
            fillConstant(canvas, value: 2)
            let journal = TileUndoJournal(workingDirectory: directory)
            let jobID = UUID()
            let rect = TileJournalRect(x: 0, y: 0, width: 8, height: 8)
            let manifest = TileJournalManifest(
                jobID: jobID,
                tileIndex: 3,
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: rect.height,
                byteCount: rect.byteCount,
                sha256: String(repeating: "ab", count: 32)
            )
            let markerURL = try journal.restoredMarkerFileURL(jobID: jobID, tileIndex: 3)
            try JSONEncoder().encode(manifest).write(to: markerURL)
            let before = snapshot(canvas)
            XCTAssertThrowsError(try journal.recover(
                jobID: jobID,
                lastCompletedTileIndex: 0,
                totalTiles: 4,
                expectedRects: [0: rect, 1: rect, 2: rect, 3: rect],
                into: canvas
            )) { error in
                guard case ScalerError.checkpointCorrupted = error else {
                    XCTFail("Expected checkpointCorrupted, got \(error)")
                    return
                }
            }
            XCTAssertEqual(snapshot(canvas), before)
            XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        }

        // 4. A pending manifest and a restored marker for the same tile cannot coexist.
        do {
            let directory = try makeScratchDirectory("marker-pending-conflict")
            defer { try? FileManager.default.removeItem(at: directory) }
            let canvas = try MMapBuffer(
                fileURL: directory.appendingPathComponent("canvas.bin"),
                width: 16,
                height: 16,
                createIfMissing: true
            )
            fillConstant(canvas, value: 2)
            let journal = TileUndoJournal(workingDirectory: directory)
            let jobID = UUID()
            let rect = TileJournalRect(x: 0, y: 0, width: 8, height: 8)
            try journal.publish(jobID: jobID, tileIndex: 0, rect: rect, from: canvas)
            let manifestURL = try journal.manifestFileURL(jobID: jobID, tileIndex: 0)
            let markerURL = try journal.restoredMarkerFileURL(jobID: jobID, tileIndex: 0)
            try Data(contentsOf: manifestURL).write(to: markerURL)
            let before = snapshot(canvas)
            XCTAssertThrowsError(try journal.recover(
                jobID: jobID,
                lastCompletedTileIndex: -1,
                totalTiles: 1,
                expectedRects: [0: rect],
                into: canvas
            )) { error in
                guard case ScalerError.checkpointCorrupted = error else {
                    XCTFail("Expected checkpointCorrupted, got \(error)")
                    return
                }
            }
            XCTAssertEqual(snapshot(canvas), before)
        }
    }

    // MARK: - R3 review probes: hostile mmap geometry

    func testCodexReviewMMapBufferRejectsHostileGeometryWithoutTouchingDestination() throws {
        let directory = try makeScratchDirectory("mmap-hostile-geometry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let preexisting = directory.appendingPathComponent("preexisting.bin")
        try Data(repeating: 0x2a, count: 4096).write(to: preexisting)
        let originalSize = try fileSize(preexisting)

        let cases: [(width: Int, height: Int)] = [
            (Int.max, 1),
            (Int.max / 8 + 1, 1),
            (Int.max / 8, 2),
            (1024, Int.max),
            (Int.max, Int.max),
            (0, 16),
            (-1, 16),
            (16, -1),
        ]
        for (width, height) in cases {
            XCTAssertThrowsError(try MMapBuffer(
                fileURL: preexisting,
                width: width,
                height: height,
                createIfMissing: true
            ), "width=\(width) height=\(height)") { error in
                guard case ScalerError.invalidImageDimensions = error else {
                    XCTFail("Expected invalidImageDimensions for \(width)x\(height), got \(error)")
                    return
                }
            }
            XCTAssertEqual(
                try fileSize(preexisting),
                originalSize,
                "A rejected \(width)x\(height) canvas must leave the preexisting destination unchanged."
            )

            // Reopen mode must also reject before mapping and never grow/truncate the file.
            XCTAssertThrowsError(try MMapBuffer(
                fileURL: preexisting,
                width: width,
                height: height,
                createIfMissing: false
            ))
            XCTAssertEqual(
                try fileSize(preexisting),
                originalSize,
                "A rejected \(width)x\(height) reopen must leave the preexisting destination unchanged."
            )

            let missing = directory.appendingPathComponent("missing-\(UUID().uuidString).bin")
            XCTAssertThrowsError(try MMapBuffer(
                fileURL: missing,
                width: width,
                height: height,
                createIfMissing: false
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        }
    }

    func testCodexReviewCheckedRowAndTotalArithmeticMatchesAlignment() throws {
        let layout = try MMapBuffer.checkedRowAndTotalBytes(width: 40, height: 24)
        XCTAssertEqual(layout.rowBytes, ((40 * 8 + 63) / 64) * 64)
        XCTAssertEqual(layout.rowBytes % 64, 0)
        XCTAssertEqual(layout.totalByteSize, layout.rowBytes * 24)

        XCTAssertThrowsError(try MMapBuffer.checkedRowAndTotalBytes(width: Int.max, height: 1))
        XCTAssertThrowsError(try MMapBuffer.checkedRowAndTotalBytes(width: Int.max / 8 + 1, height: 1))
        XCTAssertThrowsError(try MMapBuffer.checkedRowAndTotalBytes(width: 16, height: Int.max))
        XCTAssertThrowsError(try MMapBuffer.checkedRowAndTotalBytes(width: 0, height: 16))
    }

    func testCodexReviewJournalRectAndBlenderOverflowGuardsDoNotTrap() throws {
        let huge = TileJournalRect(x: 0, y: 0, width: Int.max, height: 2)
        XCTAssertEqual(huge.byteCount, 0)
        XCTAssertNil(TileJournalRect.checkedByteCount(width: Int.max, height: 2))
        XCTAssertNil(TileJournalRect.checkedByteCount(width: Int.max / 8 + 1, height: 1))
        XCTAssertNil(TileJournalRect.clipped(
            destX: Int.max,
            destY: 0,
            size: Int.max,
            canvasWidth: 16,
            canvasHeight: 16
        ))

        let directory = try makeScratchDirectory("journal-hostile-rect")
        defer { try? FileManager.default.removeItem(at: directory) }
        let canvas = try MMapBuffer(
            fileURL: directory.appendingPathComponent("canvas.bin"),
            width: 16,
            height: 16,
            createIfMissing: true
        )
        fillConstant(canvas, value: 1)
        let before = snapshot(canvas)
        let journal = TileUndoJournal(workingDirectory: directory)
        XCTAssertThrowsError(try journal.publish(
            jobID: UUID(),
            tileIndex: 0,
            rect: huge,
            from: canvas
        )) { error in
            guard case ScalerError.checkpointCorrupted = error else {
                XCTFail("Expected checkpointCorrupted, got \(error)")
                return
            }
        }

        let tile = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 64)
        defer { tile.deallocate() }
        // Extreme stride/tile geometry: rejected by reporting-overflow guards, no trap.
        CausalTileBlender.writeAndFeatherTile(
            tilePointer: tile,
            tileRowBytes: Int.max,
            tileWidth: Int.max,
            tileHeight: 2,
            destX: Int.max,
            destY: Int.max,
            leftOverlap: Int.max,
            topOverlap: Int.max,
            into: canvas
        )
        // Extreme origin: skipped by checked coordinate arithmetic, no trap.
        CausalTileBlender.writeAndFeatherTile(
            tilePointer: tile,
            tileRowBytes: 8,
            tileWidth: 1,
            tileHeight: 1,
            destX: Int.min,
            destY: Int.min,
            leftOverlap: 0,
            topOverlap: 0,
            into: canvas
        )
        XCTAssertEqual(snapshot(canvas), before, "Hostile blend geometry must be a no-op.")
    }

    // MARK: - Helpers for the review probes

    private struct RestoredMarkerState {
        let directory: URL
        let canvas: MMapBuffer
        let journal: TileUndoJournal
        let jobID: UUID
        let rect: TileJournalRect
        let markerURL: URL
    }

    /// Builds the persistent state left after a rollback completed and its manifest was retired to
    /// the restored marker, with the canvas still holding the original bytes.
    private func makeRestoredMarkerState(_ label: String) throws -> RestoredMarkerState {
        let directory = try makeScratchDirectory(label)
        let canvas = try MMapBuffer(
            fileURL: directory.appendingPathComponent("canvas.bin"),
            width: 16,
            height: 16,
            createIfMissing: true
        )
        fillConstant(canvas, value: 2)
        try canvas.flushToDisk(synchronous: true)
        let journal = TileUndoJournal(workingDirectory: directory)
        let jobID = UUID()
        let rect = TileJournalRect(x: 0, y: 0, width: 8, height: 8)
        try journal.publish(jobID: jobID, tileIndex: 0, rect: rect, from: canvas)
        let manifestURL = try journal.manifestFileURL(jobID: jobID, tileIndex: 0)
        let markerURL = try journal.restoredMarkerFileURL(jobID: jobID, tileIndex: 0)
        try FileManager.default.moveItem(at: manifestURL, to: markerURL)
        try FileManager.default.removeItem(at: try journal.undoFileURL(jobID: jobID, tileIndex: 0))
        return RestoredMarkerState(
            directory: directory,
            canvas: canvas,
            journal: journal,
            jobID: jobID,
            rect: rect,
            markerURL: markerURL
        )
    }

    private func assertMarkerCorrupted(
        _ state: RestoredMarkerState,
        canvasBefore: [Float16],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try state.journal.recover(
            jobID: state.jobID,
            lastCompletedTileIndex: -1,
            totalTiles: 1,
            expectedRects: [0: state.rect],
            into: state.canvas
        ), file: file, line: line) { error in
            guard case ScalerError.checkpointCorrupted = error else {
                XCTFail("Expected checkpointCorrupted, got \(error)", file: file, line: line)
                return
            }
        }
        XCTAssertEqual(snapshot(state.canvas), canvasBefore, file: file, line: line)
    }
}
