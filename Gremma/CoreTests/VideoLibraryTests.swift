import XCTest
import CryptoKit
@testable import GremmaCore

final class VideoLibraryTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("GremmaVideoTests-\(UUID().uuidString)")
    }

    private func job(room: String = "Unconfirmed room", confirmed: Bool? = false) -> VideoIndexJob {
        let id = UUID().uuidString
        return VideoIndexJob(id: id, room: room, originalFilename: "\(id).mov", duration: 2,
                             sampleTimes: [0.5, 1.5], roomConfirmed: confirmed)
    }

    private func write(_ jobs: [VideoIndexJob], to directory: URL, legacy: Bool = false) throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sources"), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var values = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(jobs)) as? [[String: Any]])
        if legacy {
            for index in values.indices {
                values[index].removeValue(forKey: "roomConfirmed")
                values[index].removeValue(forKey: "proposedRoom")
                values[index].removeValue(forKey: "failedFrameIndex")
                values[index].removeValue(forKey: "failureMessage")
                values[index].removeValue(forKey: "failureDate")
            }
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "jobs": values])
            .write(to: directory.appendingPathComponent("queue.json"))
        for job in jobs {
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("sources").appendingPathComponent(job.originalFilename))
        }
    }

    func testLegacyJobRemainsConfirmedAndCanResume() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = job(room: "Kitchen")
        try write([original], to: directory, legacy: true)
        let queue = try VideoIndexQueue(directory: directory)
        let loaded = await queue.job(id: original.id)
        XCTAssertTrue(try XCTUnwrap(loaded).isRoomConfirmed)
        let next = try await queue.markFrameComplete(id: original.id, expectedIndex: 0, actualTimeSeconds: 0.5)
        XCTAssertEqual(next.nextFrameIndex, 1)
    }

    func testSuggestionSurvivesRestartWithoutAuthorizingIndexing() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = job()
        try write([original], to: directory)
        let queue = try VideoIndexQueue(directory: directory)
        _ = try await queue.setRoomProposal(id: original.id, room: "Kitchen")
        let reopened = try VideoIndexQueue(directory: directory)
        let loaded = await reopened.job(id: original.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.proposedRoom, "Kitchen")
        XCTAssertFalse(saved.isRoomConfirmed)
        do {
            _ = try await reopened.markFrameComplete(id: original.id)
            XCTFail("A model proposal must not authorize indexed observations")
        } catch VideoIndexQueueError.roomNeedsConfirmation { }
        let unchanged = await reopened.job(id: original.id)
        XCTAssertEqual(unchanged?.nextFrameIndex, 0)
    }

    func testUserCorrectionPersistsBeforeIndexingAndClearsSuggestion() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = job()
        try write([original], to: directory)
        let queue = try VideoIndexQueue(directory: directory)
        _ = try await queue.setRoomProposal(id: original.id, room: "Kitchen")
        _ = try await queue.updateRoom(id: original.id, room: "  Living room  ")
        let reopened = try VideoIndexQueue(directory: directory)
        let loaded = await reopened.job(id: original.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.room, "Living room")
        XCTAssertTrue(saved.isRoomConfirmed)
        XCTAssertNil(saved.proposedRoom)
        let next = try await reopened.markFrameComplete(id: original.id, expectedIndex: 0)
        XCTAssertEqual(next.nextFrameIndex, 1)
    }

    func testRoomCannotChangeAfterSomeFramesWereSaved() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = job(room: "Kitchen", confirmed: true)
        try write([original], to: directory)
        let queue = try VideoIndexQueue(directory: directory)
        _ = try await queue.markFrameComplete(id: original.id)
        do {
            _ = try await queue.updateRoom(id: original.id, room: "Bedroom")
            XCTFail("Changing the room after saved frames would produce mixed room labels")
        } catch VideoIndexQueueError.roomAlreadyIndexed { }
        let unchanged = await queue.job(id: original.id)
        XCTAssertEqual(unchanged?.room, "Kitchen")
    }

    func testDeletingOneVideoKeepsAnotherSourceAndManifestEntry() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = job(room: "Kitchen", confirmed: true)
        let second = job(room: "Bedroom", confirmed: true)
        try write([first, second], to: directory)
        let queue = try VideoIndexQueue(directory: directory)
        try await queue.removeJob(id: first.id)
        let reopened = try VideoIndexQueue(directory: directory)
        let remaining = await reopened.jobs()
        XCTAssertEqual(remaining.map(\.id), [second.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("sources/\(first.originalFilename)").path))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("sources/\(second.originalFilename)")), Data([1, 2, 3]))
    }

    func testDeletingVideoObservationsPreservesUnrelatedPhotosAndEvidence() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try MemoryRepository(directory: directory)
        let videoID = UUID().uuidString
        let first = try await repository.save(MemoryObservation(itemName: "Mug", room: "Kitchen",
            locationDescription: "On the counter", videoID: videoID), imageData: Data([1]))
        let photo = try await repository.save(MemoryObservation(itemName: "Keys", room: "Bedroom",
            locationDescription: "On the desk"), imageData: Data([2]))
        let otherVideo = try await repository.save(MemoryObservation(itemName: "Book", room: "Office",
            locationDescription: "On the table", videoID: UUID().uuidString), imageData: Data([3]))
        let firstURL = await repository.imageURL(for: first)
        let photoURL = await repository.imageURL(for: photo)
        let otherURL = await repository.imageURL(for: otherVideo)
        try await repository.deleteVideoObservations(videoID: videoID)
        let reopened = try MemoryRepository(directory: directory)
        let remaining = await reopened.all()
        XCTAssertEqual(Set(remaining.map(\.id)), Set([photo.id, otherVideo.id]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(firstURL).path))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(photoURL)), Data([2]))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(otherURL)), Data([3]))
    }

    func testSharedEvidenceSurvivesVideoObservationDeletion() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try MemoryRepository(directory: directory)
        let videoID = UUID().uuidString
        let first = try await repository.save(MemoryObservation(itemName: "Mug", room: "Kitchen",
            locationDescription: "On the counter", videoID: videoID), imageData: Data([1]))
        let retained = try await repository.save(MemoryObservation(itemName: "Counter", room: "Kitchen",
            locationDescription: "Against the wall", imageFilename: first.imageFilename))
        try await repository.deleteVideoObservations(videoID: videoID)
        let url = await repository.imageURL(for: retained)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(url)), Data([1]))
        let remaining = await repository.all()
        XCTAssertEqual(remaining.map(\.id), [retained.id])
    }

    func testFailureAtTenthFrameSurvivesRestartAndResumesExactlyThere() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString
        let times = (0..<12).map { Double($0) + 0.5 }
        let original = VideoIndexJob(id: id, room: "Kitchen", originalFilename: "\(id).mov", duration: 20,
            sampleTimes: times, nextFrameIndex: 9,
            actualFrameTimes: times.enumerated().map { $0.offset < 9 ? $0.element : nil })
        try write([original], to: directory)
        let queue = try VideoIndexQueue(directory: directory)
        _ = try await queue.markFailed(id: id, expectedIndex: 9, message: "Could not finish this frame")
        let reopened = try VideoIndexQueue(directory: directory)
        let loaded = await reopened.currentPendingJob()
        let failed = try XCTUnwrap(loaded)
        XCTAssertEqual(failed.nextFrameIndex, 9)
        XCTAssertEqual(failed.failedFrameIndex, 9)
        XCTAssertEqual(failed.failureMessage, "Could not finish this frame")
        XCTAssertNotNil(failed.failureDate)
        XCTAssertEqual(failed.actualFrameTimes, original.actualFrameTimes)
        XCTAssertEqual(failed.progress, 0.75, accuracy: 0.0001)
        let source = await reopened.sourceURL(for: failed)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(source)), Data([1, 2, 3]))
        let resumed = try await reopened.markFrameComplete(id: id, expectedIndex: 9, actualTimeSeconds: 9.5)
        XCTAssertEqual(resumed.nextFrameIndex, 10)
        XCTAssertNil(resumed.failedFrameIndex)
        XCTAssertNil(resumed.failureMessage)
        XCTAssertNil(resumed.failureDate)
        XCTAssertEqual(Array(resumed.actualFrameTimes.prefix(9)), Array(original.actualFrameTimes.prefix(9)))
    }

    func testLateFailureCannotMarkAlreadyCompletedFrame() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = job(room: "Kitchen", confirmed: true)
        try write([original], to: directory)
        let queue = try VideoIndexQueue(directory: directory)
        _ = try await queue.markFrameComplete(id: original.id, expectedIndex: 0)
        do {
            _ = try await queue.markFailed(id: original.id, expectedIndex: 0, message: "Late failure")
            XCTFail("A stale error must not mark frame 2 as failed")
        } catch VideoIndexQueueError.frameOutOfOrder { }
        let after = await queue.job(id: original.id)
        XCTAssertEqual(after?.nextFrameIndex, 1)
        XCTAssertNil(after?.failedFrameIndex)
    }

    func testFailedCheckpointWriteKeepsCurrentFrameForRetry() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = job(room: "Kitchen", confirmed: true)
        try write([original], to: directory)
        let queue = try VideoIndexQueue(directory: directory)
        _ = try await queue.markFailed(id: original.id, expectedIndex: 0, message: "Retry needed")
        let manifest = directory.appendingPathComponent("queue.json")
        let bytes = try blockManifest(manifest)
        do {
            _ = try await queue.markFrameComplete(id: original.id, expectedIndex: 0)
            XCTFail("Writing a manifest over a nonempty directory should fail")
        } catch { }
        let after = await queue.job(id: original.id)
        XCTAssertEqual(after?.nextFrameIndex, 0)
        XCTAssertEqual(after?.failedFrameIndex, 0)
        try restoreManifest(manifest, bytes: bytes)
        let reopened = try VideoIndexQueue(directory: directory)
        let saved = await reopened.job(id: original.id)
        XCTAssertEqual(saved?.nextFrameIndex, 0)
        XCTAssertEqual(saved?.failedFrameIndex, 0)
    }

    func testFrameRetryReplacesChangedNamesAfterRestartAndKeepsOtherFrames() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try MemoryRepository(directory: directory)
        let videoID = UUID().uuidString
        let previous = try await repository.saveVideoFrameObservations([frameItem("Book", videoID: videoID, time: 8)],
            videoID: videoID, frameKey: "\(videoID)-8", imageData: Data([8]))
        let firstPass = try await repository.saveVideoFrameObservations([
            frameItem("Mug", videoID: videoID, time: 9), frameItem("Bottle", videoID: videoID, time: 9)],
            videoID: videoID, frameKey: "\(videoID)-9", imageData: Data([9]))
        XCTAssertEqual(Set(firstPass.compactMap(\.imageFilename)).count, 1, "One frame shares one evidence image")
        let oldEvidence = await repository.imageURL(for: firstPass[0])
        let reopened = try MemoryRepository(directory: directory)
        let retried = try await reopened.saveVideoFrameObservations([frameItem("Red cup", videoID: videoID, time: 9.05)],
            videoID: videoID, frameKey: "\(videoID)-9", imageData: Data([10]))
        let finalRepository = try MemoryRepository(directory: directory)
        let after = await finalRepository.all()
        XCTAssertEqual(Set(after.map(\.itemName)), Set(["Book", "Red cup"]))
        XCTAssertEqual(after.count, 2)
        let previousURL = await finalRepository.imageURL(for: previous[0])
        let retriedURL = await finalRepository.imageURL(for: retried[0])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(previousURL)), Data([8]))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(retriedURL)), Data([10]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(oldEvidence).path))
    }

    func testInvalidFrameBatchCannotPartiallySaveValidFirstItem() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try MemoryRepository(directory: directory)
        let videoID = UUID().uuidString
        let old = try await repository.saveVideoFrameObservations([frameItem("Book", videoID: videoID)],
            videoID: videoID, frameKey: "\(videoID)-0", imageData: Data([1]))
        var invalid = frameItem("Broken", videoID: videoID)
        invalid.locationDescription = ""
        do {
            _ = try await repository.saveVideoFrameObservations([frameItem("Mug", videoID: videoID), invalid],
                videoID: videoID, frameKey: "\(videoID)-0", imageData: Data([2]))
            XCTFail("An invalid batch must reject every new item")
        } catch MemoryRepositoryError.invalidVideoFrame { }
        let after = await repository.all()
        XCTAssertEqual(after, old)
    }

    func testFrameManifestFailureRollsBackNewImageAndPreservesPreviousBatch() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try MemoryRepository(directory: directory)
        let videoID = UUID().uuidString
        let original = try await repository.saveVideoFrameObservations([frameItem("Book", videoID: videoID)],
            videoID: videoID, frameKey: "\(videoID)-0", imageData: Data([1]))
        let evidenceDirectory = directory.appendingPathComponent("evidence")
        let beforeImages = try FileManager.default.contentsOfDirectory(atPath: evidenceDirectory.path)
        let manifest = directory.appendingPathComponent("observations.json")
        let bytes = try blockManifest(manifest)
        do {
            _ = try await repository.saveVideoFrameObservations([frameItem("Mug", videoID: videoID)],
                videoID: videoID, frameKey: "\(videoID)-0", imageData: Data([2]))
            XCTFail("Writing a manifest over a nonempty directory should fail")
        } catch { }
        let after = await repository.all()
        XCTAssertEqual(after, original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: evidenceDirectory.path), beforeImages)
        try restoreManifest(manifest, bytes: bytes)
        let reopened = try MemoryRepository(directory: directory)
        let saved = await reopened.all()
        XCTAssertEqual(saved, original)
        let evidence = await reopened.imageURL(for: original[0])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(evidence)), Data([1]))
    }

    func testEmptySuccessfulRetryRemovesOldFrameBatchOnly() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try MemoryRepository(directory: directory)
        let videoID = UUID().uuidString
        _ = try await repository.saveVideoFrameObservations([frameItem("Mug", videoID: videoID)],
            videoID: videoID, frameKey: "\(videoID)-0", imageData: Data([1]))
        let retained = try await repository.saveVideoFrameObservations([frameItem("Book", videoID: videoID, time: 1)],
            videoID: videoID, frameKey: "\(videoID)-1", imageData: Data([2]))
        _ = try await repository.saveVideoFrameObservations([], videoID: videoID, frameKey: "\(videoID)-0", imageData: Data([3]))
        let after = await repository.all()
        XCTAssertEqual(after, retained)
    }

    func testLegacyPartialFrameIsReplacedByExactStableIDWithoutTouchingAdjacentFrame() async throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try MemoryRepository(directory: directory)
        let videoID = UUID().uuidString
        var partial = frameItem("Mug", videoID: videoID, time: 9)
        partial.id = legacyID("\(videoID)-9-mug")
        _ = try await repository.save(partial, imageData: Data([9]))
        var adjacent = frameItem("Mug", videoID: videoID, time: 8.95)
        adjacent.id = legacyID("\(videoID)-8-mug")
        let retained = try await repository.save(adjacent, imageData: Data([8]))
        let new = try await repository.saveVideoFrameObservations([frameItem("Cup", videoID: videoID, time: 9.05)],
            videoID: videoID, frameKey: "\(videoID)-9", imageData: Data([10]))
        let after = await repository.all()
        XCTAssertEqual(Set(after.map(\.id)), Set([retained.id, new[0].id]))
    }

    private func frameItem(_ name: String, videoID: String, time: Double = 0.5) -> MemoryObservation {
        MemoryObservation(itemName: name, room: "Kitchen", locationDescription: "On the table",
                          capturedAt: Date(timeIntervalSince1970: 100),
                          videoID: videoID, videoTimeSeconds: time, captureSource: .video)
    }

    /// A nonempty directory deterministically prevents atomic file replacement,
    /// without relying on platform permissions or changing real user data.
    private func blockManifest(_ url: URL) throws -> Data {
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data([0]).write(to: url.appendingPathComponent("write-blocker"))
        return bytes
    }

    private func restoreManifest(_ url: URL, bytes: Data) throws {
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
    }

    private func legacyID(_ key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
