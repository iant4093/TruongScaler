import XCTest
@testable import TruongScalerCore

final class ActivityProgressPresentationTests: XCTestCase {
    private func state(completed: Int = 0, total: Int = 234, eta: Int? = nil) -> UpscaleActivityAttributes.ContentState {
        .init(stageTitle: "Upscaling", completedTiles: completed, totalTiles: total,
              progressFraction: 0.1, estimatedSecondsRemaining: eta)
    }

    func testCompactProgressCountsSavedTilesRatherThanPreparationBudget() {
        XCTAssertEqual(state().compactProgressText, "0%")
        XCTAssertEqual(state(completed: 117).compactProgressText, "50%")
        XCTAssertEqual(state(completed: 999).compactProgressText, "100%")
        XCTAssertEqual(state(completed: -1).savedTileFraction, 0)
        XCTAssertEqual(state(total: 0).compactProgressText, "…")
    }

    func testLongETAIsBoundedAndUsesMinutesAndHours() {
        XCTAssertEqual(state(eta: 3360).remainingTimeText, "~56m left")
        XCTAssertEqual(state(eta: 7260).remainingTimeText, "~2h 1m left")
        XCTAssertNil(state(eta: 0).remainingTimeText)
        var paused = state(eta: 3360)
        paused.phase = .paused
        XCTAssertNil(paused.remainingTimeText)
    }

    func testOlderActivityPayloadDecodesWithoutElapsedClock() throws {
        let json = #"{"stageTitle":"Upscaling","completedTiles":1,"totalTiles":234,"progressFraction":0.1,"isPaused":false,"phase":"running"}"#
        let decoded = try JSONDecoder().decode(UpscaleActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertNil(decoded.startedAt)
        XCTAssertEqual(decoded.completedTiles, 1)
    }
}
