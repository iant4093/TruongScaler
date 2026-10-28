import XCTest
import TiledInferenceEngine
@testable import DeepZoomGalleryUI

final class CalmProgressPresentationTests: XCTestCase {
    func testFastTilePhasesKeepTheSameCompactTitleAndCommittedPercentage() {
        for phase in [PipelinePhase.decodingSource, .preparingModels, .extractingTile,
                      .predictingSuperResolution, .verifyingSuperResolution, .reconstructingTile,
                      .blendingTile, .committingTile, .tileCommitted, .finalizing] {
            let progress = JobProgressPresentation(phase: phase, completedTiles: 117, totalTiles: 234)
            XCTAssertEqual(progress.compactTitle, "Upscaling photo")
            XCTAssertEqual(progress.compactPercentText, "50%")
            XCTAssertEqual(progress.compactFraction, 0.5)
        }
    }

    func testCompactProgressHasNoInventedCountsAndShowsStoppingTruthfully() {
        let preparing = JobProgressPresentation()
        XCTAssertEqual(preparing.compactPercentText, "")
        XCTAssertEqual(preparing.compactFraction, 0)
        var stopping = JobProgressPresentation(completedTiles: 40, totalTiles: 100, isStopping: true)
        XCTAssertEqual(stopping.compactTitle, "Stopping…")
        XCTAssertEqual(stopping.compactPercentText, "40%")
        stopping.completedTiles = 400
        XCTAssertEqual(stopping.compactPercentText, "100%")
        stopping.completedTiles = -1
        XCTAssertEqual(stopping.compactFraction, 0)
    }
    func testWaitingBatchDoesNotPresentThePreviousPhotosTileCountOrETA() {
        var progress = JobProgressPresentation(phase: .completed, completedTiles: 234, totalTiles: 234,
            estimatedSecondsRemaining: 0)
        progress.batchPhotoNumber = 2; progress.batchPhotoCount = 5
        progress.isWaitingForForeground = true
        XCTAssertEqual(progress.compactTitle, "Open app to continue")
        XCTAssertEqual(progress.compactSubtitle, "Photo 2 of 5 is queued")
        XCTAssertEqual(progress.processTitle, "Waiting for app")
        XCTAssertEqual(progress.remainingText, "Waiting for app")
        XCTAssertFalse(progress.hasTilePlan)
        XCTAssertEqual(progress.compactFraction, 0)
        XCTAssertEqual(progress.compactPercentText, "")
        progress.isStopping = true
        XCTAssertEqual(progress.compactTitle, "Stopping…")
    }

}
