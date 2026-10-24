import Foundation

/// Small recovery checkpoints only. Never serializes prompts, object names,
/// descriptions, images, model output, or the video's contents. Callers must pass
/// only an app status/error summary in detail, never raw inference text.
@MainActor
enum VideoRecoveryDiagnostics {
    private struct Event: Encodable {
        let videoID: String
        let room: String
        let nextFrameIndex: Int
        let total: Int
        let savedObservationCount: Int
        let failedFrameIndex: Int?
        let stage: String
        let detail: String?
        let updatedAt: Date
    }

    private struct Report: Encodable {
        let schemaVersion = 1
        let processSessionID: UUID
        let videoID: String
        let room: String
        let nextFrameIndex: Int
        let total: Int
        let savedObservationCount: Int
        let failedFrameIndex: Int?
        let stage: String
        let detail: String?
        let updatedAt: Date
        let history: [Event]
    }

    private static let processSessionID = UUID()
    private static var events: [Event] = []
    private static let historyLimit = 128

    /// Best effort by design: diagnostics must never prevent saving or resuming a video.
    static func record(job: VideoIndexJob, observations: [MemoryObservation], stage: String, detail: String? = nil) {
        let event = Event(videoID: job.id, room: job.room,
            nextFrameIndex: job.nextFrameIndex, total: job.sampleTimes.count,
            savedObservationCount: observations.filter { $0.videoID == job.id }.count,
            failedFrameIndex: job.failedFrameIndex, stage: String(stage.prefix(80)),
            detail: detail.map { String($0.prefix(1000)) }, updatedAt: Date())
        events.append(event)
        if events.count > historyLimit { events.removeFirst(events.count - historyLimit) }
        let report = Report(processSessionID: processSessionID, videoID: event.videoID,
            room: event.room, nextFrameIndex: event.nextFrameIndex, total: event.total,
            savedObservationCount: event.savedObservationCount, failedFrameIndex: event.failedFrameIndex,
            stage: event.stage, detail: event.detail, updatedAt: event.updatedAt, history: events)
        do {
            var directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("Diagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: directory.appendingPathComponent("video-recovery-latest.json"), options: .atomic)
        } catch {
            // A subsequent checkpoint may succeed; in-process history is retained.
        }
    }
}
