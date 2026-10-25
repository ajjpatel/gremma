import XCTest
@testable import TemporalVideoCore

final class TemporalVideoTests: XCTestCase {
    private func job(duration: Double = 14, recordedAt: Date? = nil, completed: Int? = nil) -> VideoIndexJob {
        let id = UUID().uuidString
        return VideoIndexJob(id: id, room: "Kitchen", originalFilename: "\(id).mov", duration: duration,
            sampleTimes: [0.05], recordedAt: recordedAt,
            recordingDateSource: recordedAt == nil ? nil : .appRecording,
            activityCompletedWindowCount: completed)
    }
    private func write(_ job: VideoIndexJob, directory: URL, legacy: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sources"), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(job)) as? [String: Any])
        if legacy {
            for key in ["recordedAt", "recordingDateSource", "activityCompletedWindowCount", "audioCompletedChunkCount", "audioUnavailable", "isDemo", "demoImportKey"] {
                value.removeValue(forKey: key)
            }
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "jobs": [value]])
            .write(to: directory.appendingPathComponent("queue.json"))
        try Data([1, 2]).write(to: directory.appendingPathComponent("sources/\(job.originalFilename)"))
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("TemporalVideo-\(UUID().uuidString)") }

    func testWindowsOwnEverySecondAndKeepEarlierContext() throws {
        let video = job()
        XCTAssertEqual(video.activityWindowCount, 3)
        let first = try video.activityWindow(at: 0)
        let second = try video.activityWindow(at: 1)
        let third = try video.activityWindow(at: 2)
        XCTAssertEqual(first.startSeconds, 0); XCTAssertEqual(first.endSeconds, 6)
        XCTAssertEqual(second.startSeconds, 6); XCTAssertEqual(second.endSeconds, 12)
        XCTAssertEqual(third.startSeconds, 12); XCTAssertEqual(third.endSeconds, 14)
        XCTAssertLessThan(try XCTUnwrap(second.frameTimes.first), second.startSeconds)
        XCTAssertEqual(second.frameTimes, second.frameTimes.sorted())
        XCTAssertLessThan(try XCTUnwrap(third.frameTimes.last), 14)
        XCTAssertEqual(video.activitySegmentID(at: 1), video.activitySegmentID(at: 1))
        XCTAssertEqual(first.frameTimes.count, 6)
        XCTAssertGreaterThan(first.frameTimes[1] - first.frameTimes[0], 1)
        XCTAssertEqual(second.frameTimes.count, 6)
    }
    func testShortClipHasFiniteOrderedSamples() throws {
        let video = job(duration: 0.1)
        let window = try video.activityWindow(at: 0)
        XCTAssertTrue(window.frameTimes.allSatisfy { $0 >= 0 && $0 < 0.1 })
        XCTAssertEqual(Set(window.frameTimes).count, window.frameTimes.count)
        XCTAssertEqual(video.activityWindowCount, 1)
    }
    func testMaximumClipSplitsAudioAndVideoWithoutLongRangeSparseSampling() throws {
        let video = job(duration: 600)
        XCTAssertEqual(video.activityWindowCount, 100)
        XCTAssertEqual(video.audioChunkCount, 20)
        XCTAssertEqual(try video.audioChunk(at: 19).endSeconds, 600)
        XCTAssertThrowsError(try video.activityWindow(at: 100))
        XCTAssertThrowsError(try video.audioChunk(at: 20))
    }
    func testLegacyImportRemainsUndatedAndGetsSeparateCursors() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let video = job(recordedAt: Date(timeIntervalSince1970: 1000))
        try write(video, directory: folder, legacy: true)
        let queue = try VideoIndexQueue(directory: folder)
        let loaded = await queue.job(id: video.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertNil(saved.recordedAt); XCTAssertNil(saved.recordingDateSource)
        XCTAssertEqual(saved.nextActivityWindowIndex, 0); XCTAssertEqual(saved.nextAudioChunkIndex, 0)
        XCTAssertFalse(saved.isMemoryComplete)
        XCTAssertFalse(saved.isDemoVideo)
        XCTAssertNil(saved.isDemo)
        XCTAssertNil(saved.demoImportKey)
    }
    func testSeparateCheckpointsSurviveRestartAndKeepOldProgress() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let video = job(recordedAt: Date(timeIntervalSince1970: 1000))
        try write(video, directory: folder)
        let queue = try VideoIndexQueue(directory: folder)
        _ = try await queue.markActivityWindowComplete(id: video.id, expectedIndex: 0)
        _ = try await queue.markAudioChunkComplete(id: video.id, expectedIndex: 0)
        let reopened = try VideoIndexQueue(directory: folder)
        let loaded = await reopened.job(id: video.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.nextActivityWindowIndex, 1); XCTAssertEqual(saved.nextAudioChunkIndex, 1)
        XCTAssertEqual(saved.nextFrameIndex, 0)
        XCTAssertEqual(saved.recordedAt, video.recordedAt)
        XCTAssertEqual(saved.recordingDateSource, .appRecording)
    }
    func testFailureDoesNotAdvanceAndRetryClearsOnlyAfterCommitCheckpoint() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let video = job(); try write(video, directory: folder)
        let queue = try VideoIndexQueue(directory: folder)
        _ = try await queue.markActivityWindowComplete(id: video.id, expectedIndex: 0)
        _ = try await queue.markMemoryFailed(id: video.id, stage: .activity, expectedIndex: 1, message: "Model failed")
        let reopened = try VideoIndexQueue(directory: folder)
        let loaded = await reopened.job(id: video.id)
        XCTAssertEqual(loaded?.nextActivityWindowIndex, 1)
        XCTAssertEqual(loaded?.memoryFailureStage, .activity)
        let next = try await reopened.markActivityWindowComplete(id: video.id, expectedIndex: 1)
        XCTAssertEqual(next.nextActivityWindowIndex, 2); XCTAssertNil(next.memoryFailureMessage)
        do {
            _ = try await reopened.markActivityWindowComplete(id: video.id, expectedIndex: 1)
            XCTFail("Stale completion must not advance another window")
        } catch VideoIndexQueueError.frameOutOfOrder { }
    }
    func testNoAudioCompletesOnlyAudioAndPersists() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let video = job(); try write(video, directory: folder)
        let queue = try VideoIndexQueue(directory: folder)
        let saved = try await queue.markAudioUnavailable(id: video.id)
        XCTAssertTrue(saved.isAudioComplete); XCTAssertFalse(saved.isActivityComplete)
        XCTAssertFalse(saved.isMemoryComplete)
        let reopened = try VideoIndexQueue(directory: folder)
        let loaded = await reopened.job(id: video.id)
        XCTAssertEqual(loaded?.audioUnavailable, true)
    }
    func testRecordingDateNeedsExplicitUpdateBeforeProcessing() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let video = job(); try write(video, directory: folder)
        let queue = try VideoIndexQueue(directory: folder)
        let date = Date(timeIntervalSince1970: 2000)
        let dated = try await queue.updateRecordingDate(id: video.id, recordedAt: date)
        XCTAssertEqual(dated.recordedAt, date); XCTAssertEqual(dated.recordingDateSource, .userConfirmed)
        _ = try await queue.markAudioChunkComplete(id: video.id, expectedIndex: 0)
        do {
            _ = try await queue.updateRecordingDate(id: video.id, recordedAt: date.addingTimeInterval(10))
            XCTFail("Already committed transcript dates must not silently drift")
        } catch VideoIndexQueueError.recordingDateLocked { }
    }
    func testMalformedActivityCursorIsRejected() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        try write(job(completed: 1000), directory: folder)
        XCTAssertThrowsError(try VideoIndexQueue(directory: folder))
    }

    func testSilentVideoCompletesWithoutAudioAndPreservesLegacyAudioFailure() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let video = job(duration: 10.93); try write(video, directory: folder)
        let queue = try VideoIndexQueue(directory: folder)
        let halfway = try await queue.markActivityWindowComplete(id: video.id, expectedIndex: 0)
        XCTAssertEqual(halfway.memoryProgress, 0.5)
        _ = try await queue.markActivityWindowComplete(id: video.id, expectedIndex: 1)
        _ = try await queue.markMemoryFailed(id: video.id, stage: .audio, expectedIndex: 0, message: "No speech detected")
        let reopened = try VideoIndexQueue(directory: folder)
        let reopenedJob = await reopened.job(id: video.id)
        let saved = try XCTUnwrap(reopenedJob)
        XCTAssertTrue(saved.isMemoryComplete)
        XCTAssertEqual(saved.memoryProgress, 1)
        XCTAssertEqual(saved.nextAudioChunkIndex, 0)
        XCTAssertEqual(saved.memoryFailureStage, .audio)
        let pending = await reopened.pendingMemoryJobs()
        XCTAssertTrue(pending.isEmpty)
    }

    func testReanalysisKeepsOriginalAndStableSegmentIDs() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let video = job(duration: 6, recordedAt: Date(timeIntervalSince1970: 1000))
        try write(video, directory: folder)
        let queue = try VideoIndexQueue(directory: folder)
        _ = try await queue.markActivityWindowComplete(id: video.id, expectedIndex: 0)
        let restarted = try await queue.restartActivityAnalysis(id: video.id)
        XCTAssertFalse(restarted.isMemoryComplete)
        XCTAssertEqual(restarted.activitySegmentID(at: 0), video.activitySegmentID(at: 0))
        XCTAssertEqual(restarted.recordedAt, video.recordedAt)
        XCTAssertTrue(restarted.hasStartedActivityAnalysis)
        do {
            _ = try await queue.updateRecordingDate(id: video.id, recordedAt: Date())
            XCTFail("Reanalysis must not unlock dates of existing events")
        } catch VideoIndexQueueError.recordingDateLocked { }
        let source = await queue.sourceURL(for: restarted)
        XCTAssertNotNil(source)
        let reopened = try VideoIndexQueue(directory: folder)
        let saved = await reopened.job(id: video.id)
        XCTAssertEqual(saved?.nextActivityWindowIndex, 0)
    }

    func testBeginningAnalysisLocksDateBeforeFirstCheckpoint() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let video = job(); try write(video, directory: folder)
        let queue = try VideoIndexQueue(directory: folder)
        _ = try await queue.beginActivityAnalysis(id: video.id)
        let reopened = try VideoIndexQueue(directory: folder)
        do {
            _ = try await reopened.updateRecordingDate(id: video.id, recordedAt: Date())
            XCTFail("The first DB commit can precede its checkpoint; its date must already be locked")
        } catch VideoIndexQueueError.recordingDateLocked { }
        let saved = await reopened.job(id: video.id)
        XCTAssertEqual(saved?.nextActivityWindowIndex, 0)
    }

    func testDemoFootageDiscardsProvidedPersonalDateAndCannotBeDatedAfterReload() async throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let id = UUID().uuidString
        let importKey = "sha256:" + String(repeating: "a", count: 64)
        let video = VideoIndexJob(id: id, room: "Demo kitchen", originalFilename: "\(id).mov",
            duration: 6, sampleTimes: [0.05], recordedAt: Date(timeIntervalSince1970: 2000),
            recordingDateSource: .containerMetadata, isDemo: true, demoImportKey: importKey)
        XCTAssertTrue(video.isDemoVideo)
        XCTAssertEqual(video.demoImportKey, importKey)
        XCTAssertNil(video.recordedAt)
        XCTAssertNil(video.recordingDateSource)
        try write(video, directory: folder)
        let queue = try VideoIndexQueue(directory: folder)
        do {
            _ = try await queue.updateRecordingDate(id: id, recordedAt: Date())
            XCTFail("A demo must not be relabeled as today's personal activity")
        } catch VideoIndexQueueError.demoRecordingDateLocked { }
        _ = try await queue.beginActivityAnalysis(id: id)
        _ = try await queue.markActivityWindowComplete(id: id, expectedIndex: 0)
        _ = try await queue.restartActivityAnalysis(id: id)
        let reopened = try VideoIndexQueue(directory: folder)
        let loaded = await reopened.job(id: id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertTrue(saved.isDemoVideo)
        XCTAssertEqual(saved.demoImportKey, importKey)
        XCTAssertNil(saved.recordedAt)
        XCTAssertNil(saved.recordingDateSource)
        XCTAssertTrue(saved.hasStartedActivityAnalysis)
        XCTAssertEqual(saved.nextActivityWindowIndex, 0)
    }

    func testMalformedDatedDemoManifestIsRejectedWithoutRewriting() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let video = job(recordedAt: Date(timeIntervalSince1970: 2000))
        try write(video, directory: folder)
        let manifestURL = folder.appendingPathComponent("queue.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var jobs = try XCTUnwrap(manifest["jobs"] as? [[String: Any]])
        jobs[0]["isDemo"] = true
        manifest["jobs"] = jobs
        let originalBytes = try JSONSerialization.data(withJSONObject: manifest)
        try originalBytes.write(to: manifestURL)
        XCTAssertThrowsError(try VideoIndexQueue(directory: folder)) { error in
            guard case VideoIndexQueueError.invalidManifest = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: manifestURL), originalBytes)
    }
}
