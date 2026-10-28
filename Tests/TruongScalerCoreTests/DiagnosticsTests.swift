import XCTest
import Foundation
@testable import TruongScalerCore

final class DiagnosticsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    final class RecordingSink: DiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DiagnosticEvent] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return events.count }
        var last: DiagnosticEvent? { lock.lock(); defer { lock.unlock() }; return events.last }
        func write(_ event: DiagnosticEvent) {
            lock.lock(); events.append(event); lock.unlock()
        }
    }

    private func makeDiagnostics(
        isEnabled: Bool = true,
        maxEvents: Int = 500,
        maxRetainedBytes: Int = 256 * 1024,
        fileMaxBytes: Int = 512 * 1024,
        sinks: [any DiagnosticSink] = []
    ) -> Diagnostics {
        Diagnostics(
            configuration: DiagnosticsConfiguration(
                isEnabled: isEnabled,
                maxEvents: maxEvents,
                maxRetainedBytes: maxRetainedBytes,
                fileMaxBytes: fileMaxBytes,
                directory: directory,
                sinks: sinks
            )
        )
    }

    func testEventsAreOrderedAndCarryUsefulFields() {
        let diagnostics = makeDiagnostics()
        diagnostics.record(
            category: .pipeline,
            level: .notice,
            code: "pipeline.job.start",
            message: "job started",
            fields: ["correlationID": "ABC", "sourceType": "dng", "scale": "4x", "computeRequested": "all requested"]
        )
        diagnostics.record(
            category: .model,
            level: .info,
            code: "model.load",
            message: "model loaded",
            fields: ["model": "QuickSRNet_Large_x2_256", "seconds": "1.200"]
        )

        let events = diagnostics.recentEvents()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].sequence, 1)
        XCTAssertEqual(events[1].sequence, 2)
        XCTAssertEqual(events[0].fields["correlationID"], "ABC")
        XCTAssertEqual(events[0].fields["sourceType"], "dng")
        XCTAssertEqual(events[1].fields["model"], "QuickSRNet_Large_x2_256")
        XCTAssertTrue(events[1].line.contains("[model]"))
        XCTAssertTrue(events[1].line.contains("seconds=1.200"))
        XCTAssertTrue(events[1].timestamp <= Date())
    }

    func testRingIsBoundedAndKeepsNewestEventsWithMonotonicSequence() {
        let diagnostics = makeDiagnostics(maxEvents: 5)
        for index in 0..<20 {
            diagnostics.record(category: .pipeline, code: "event.\(index)")
        }
        let events = diagnostics.recentEvents()
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events.map(\.code), ["event.15", "event.16", "event.17", "event.18", "event.19"])
        XCTAssertEqual(events.map(\.sequence), Array(16...20))
    }

    func testDisabledDiagnosticsAreACompleteNoOp() {
        let sink = RecordingSink()
        let diagnostics = makeDiagnostics(isEnabled: false, sinks: [sink])
        diagnostics.record(category: .app, code: "app.launch")
        diagnostics.flush()
        XCTAssertTrue(diagnostics.recentEvents().isEmpty)
        XCTAssertEqual(sink.count, 0, "Disabled logging must not call sinks")
        XCTAssertEqual(diagnostics.snapshot(), "TruongScaler diagnostics v1 (bounded)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testLoggingFailureAndSinksAreBestEffortAndNeutral() {
        let sink = RecordingSink()
        // A path under a regular file cannot be a directory: disk writes must fail safely.
        let unwritable = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-not-a-directory-\(UUID().uuidString)")
        try? Data("x".utf8).write(to: unwritable)
        defer { try? FileManager.default.removeItem(at: unwritable) }

        let diagnostics = Diagnostics(
            configuration: DiagnosticsConfiguration(
                directory: unwritable.appendingPathComponent("child"),
                sinks: [sink]
            )
        )
        diagnostics.record(category: .pipeline, code: "pipeline.progress", fields: ["completed": "3"])
        diagnostics.flush()
        XCTAssertEqual(diagnostics.recentEvents().count, 1, "Disk failure must not lose in-memory diagnostics")
        XCTAssertEqual(sink.count, 1)
    }

    func testSanitizationDropsPathsAndSecretsButKeepsTileFractions() {
        let diagnostics = makeDiagnostics()
        diagnostics.record(
            category: .pipeline,
            level: .warning,
            code: "test",
            message: "source /Users/iantruong/Photos/private.dng failed; tile 1/234",
            fields: [
                "path": "/Users/iantruong/Photos/a.dng",
                "filename": "private.dng",
                "bookmark": "secret",
                "note": "1/234",
                "sourceType": "dng"
            ]
        )
        let event = diagnostics.recentEvents().first
        XCTAssertNotNil(event)
        XCTAssertNil(event?.fields["path"])
        XCTAssertNil(event?.fields["filename"])
        XCTAssertNil(event?.fields["bookmark"])
        XCTAssertEqual(event?.fields["note"], "1/234", "A tile count fraction must not be mistaken for a path")
        XCTAssertEqual(event?.fields["sourceType"], "dng")
        XCTAssertFalse(event?.message.contains("/Users/") ?? true)
        XCTAssertTrue(event?.message.contains("<path>") ?? false)
        XCTAssertTrue(event?.message.contains("1/234") ?? false)
    }

    func testURLEscapedAndSpacedPathsAreRedacted() {
        let cases = [
            "file:///Users/iantruong/Private Client/ConfidentialCapture.dng",
            #"\/Users\/iantruong\/Private Client\/ConfidentialCapture.dng"#,
            "/private/var/mobile/Containers/Data/Application/ID/Documents/Client Photos/Capture.dng"
        ]
        for value in cases {
            let redacted = Diagnostics.sanitize(value)
            XCTAssertFalse(redacted.contains("ConfidentialCapture"), redacted)
            XCTAssertFalse(redacted.contains("Capture.dng") && redacted.contains("Client Photos"), redacted)
            XCTAssertTrue(redacted.contains("<path>"), redacted)
        }
        XCTAssertEqual(Diagnostics.sanitize("tile 1/234"), "tile 1/234")
    }

    func testStructuredErrorContextForScalerErrorsDoesNotLeakPaths() {
        let info = Diagnostics.describe(
            ScalerError.modelInferenceFailed(
                modelName: "QuickSRNet_Large_x2_256",
                tileIndex: 7,
                reason: "bad tensor at /Users/iantruong/Photos/secret.tiff"
            )
        )
        XCTAssertEqual(info.domain, "TruongScaler.ScalerError")
        XCTAssertEqual(info.code, "modelInferenceFailed")
        XCTAssertTrue(info.detail.contains("QuickSRNet_Large_x2_256"))
        XCTAssertTrue(info.detail.contains("tile=7"))
        XCTAssertFalse(info.detail.contains("/Users/"))

        let missing = Diagnostics.describe(ScalerError.productionModelUnavailable(
            modelName: "QuickSRNet_Large_x2_192",
            searchDirectories: ["/Users/iantruong/Models", "/private/tmp/models"]
        ))
        XCTAssertEqual(missing.code, "productionModelUnavailable")
        XCTAssertFalse(missing.detail.contains("/Users/"))

        let legacy = Diagnostics.describe(ScalerError.srOnlyResumeOfLegacyDenoiseJob(completedTiles: 3, totalTiles: 10))
        XCTAssertEqual(legacy.code, "srOnlyResumeOfLegacyDenoiseJob")
        XCTAssertTrue(legacy.detail.contains("completed=3"))
    }

    func testDiskRolloverKeepsTwoBoundedFiles() throws {
        let diagnostics = makeDiagnostics(maxEvents: 1000, fileMaxBytes: 1024)
        for index in 0..<200 {
            diagnostics.record(
                category: .pipeline,
                code: "event.\(index)",
                fields: ["payload": String(repeating: "x", count: 20)]
            )
        }
        diagnostics.flush()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("truongscaler.log") }
        XCTAssertEqual(files.count, 2, "At most the current log and one rollover file are retained")
        for file in files {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            XCTAssertLessThanOrEqual(size, 2048, "Rollover files must stay near the configured bound")
        }
    }


    func testConcurrentRecordingIsThreadSafeAndSequenced() {
        let diagnostics = makeDiagnostics(maxEvents: 200)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            diagnostics.record(category: .pipeline, code: "concurrent.\(index)")
        }
        let events = diagnostics.recentEvents(limit: 500)
        XCTAssertEqual(events.count, 100)
        XCTAssertEqual(Set(events.map(\.sequence)).count, 100)
        XCTAssertEqual(events.map(\.sequence), events.map(\.sequence).sorted())
    }

    func testLaunchEventRecordsBuildConfigAndOS() {
        let diagnostics = makeDiagnostics()
        diagnostics.recordLaunch(configuration: "Debug", appVersion: "1.0", buildNumber: "42", osVersion: "Version 27.0")
        let event = diagnostics.recentEvents().first
        XCTAssertEqual(event?.code, "app.launch")
        XCTAssertEqual(event?.level, .notice)
        XCTAssertEqual(event?.fields["configuration"], "Debug")
        XCTAssertEqual(event?.fields["appVersion"], "1.0")
        XCTAssertEqual(event?.fields["buildNumber"], "42")
        XCTAssertEqual(event?.fields["osVersion"], "Version 27.0")
    }


    func testOversizedSingleEventCannotDefeatMemoryBound() {
        let diagnostics = makeDiagnostics(maxEvents: 10, maxRetainedBytes: 1024)
        var fields: [String: String] = [:]
        for index in 0..<10 { fields["field\(index)"] = String(repeating: "x", count: 300) }
        diagnostics.record(category: .pipeline, code: "oversized", fields: fields)
        XCTAssertTrue(diagnostics.recentEvents().isEmpty, "A single event larger than the ring bound must be dropped, not retained unbounded")
        XCTAssertEqual(diagnostics.snapshot(), "TruongScaler diagnostics v1 (bounded)")
    }

    func testMeasuredSpanRecordsDuration() {
        let diagnostics = makeDiagnostics()
        let span = diagnostics.startSpan(category: .model, code: "model.load", fields: ["model": "QuickSRNet_Large_x2_256"])
        span.end(additionalFields: ["bytes": "123"])
        let event = diagnostics.recentEvents().first
        XCTAssertEqual(event?.code, "model.load")
        XCTAssertEqual(event?.fields["model"], "QuickSRNet_Large_x2_256")
        XCTAssertEqual(event?.fields["bytes"], "123")
        XCTAssertNotNil(event?.fields["seconds"])
        XCTAssertGreaterThanOrEqual(Double(event?.fields["seconds"] ?? "-1") ?? -1, 0)
    }
}
