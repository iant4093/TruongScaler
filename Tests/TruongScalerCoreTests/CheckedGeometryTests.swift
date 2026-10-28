import XCTest
@testable import TruongScalerCore

/// Lead-owned R3 audit coverage for the shared row/byte geometry helpers. These must reject
/// unrepresentable dimensions with an error instead of trapping; the compatibility wrappers must
/// not trap either.
final class CheckedGeometryTests: XCTestCase {
    func testAlignedRowBytesMatchesFormulaForNormalDimensions() throws {
        XCTAssertEqual(try HardwareTelemetry.checkedAlignedRowBytes(width: 1), 64)
        XCTAssertEqual(try HardwareTelemetry.checkedAlignedRowBytes(width: 8), 64)
        XCTAssertEqual(try HardwareTelemetry.checkedAlignedRowBytes(width: 9), 128)
        XCTAssertEqual(try HardwareTelemetry.checkedAlignedRowBytes(width: 100, bytesPerPixel: 3), 320)
        XCTAssertEqual(
            try HardwareTelemetry.checkedRequiredMMapBytes(width: 9, height: 4),
            512
        )
    }

    func testAbsurdGeometryThrowsInsteadOfTrapping() {
        for width in [Int.max, Int.max / 8, Int.max / 8 + 1] {
            XCTAssertThrowsError(try HardwareTelemetry.checkedAlignedRowBytes(width: width)) { error in
                guard case ScalerError.invalidImageDimensions = error else {
                    return XCTFail("Expected invalidImageDimensions for width \(width), got \(error)")
                }
            }
            XCTAssertThrowsError(
                try HardwareTelemetry.checkedRequiredMMapBytes(width: width, height: Int.max)
            )
        }
        XCTAssertThrowsError(try HardwareTelemetry.checkedAlignedRowBytes(width: 0))
        XCTAssertThrowsError(try HardwareTelemetry.checkedRequiredMMapBytes(width: 64, height: 0))
        // Compatibility wrappers must be non-trapping too.
        XCTAssertEqual(HardwareTelemetry.alignedRowBytes(width: Int.max), 0)
        XCTAssertEqual(HardwareTelemetry.requiredMMapBytes(width: Int.max, height: Int.max), Int64.max)
    }
}
