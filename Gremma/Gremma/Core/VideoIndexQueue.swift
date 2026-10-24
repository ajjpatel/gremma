import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct VideoIndexJob: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public private(set) var room: String
    /// Missing in legacy manifests, whose room was already chosen before import.
    public private(set) var roomConfirmed: Bool?
    public private(set) var proposedRoom: String?
    public let createdAt: Date
    public let originalFilename: String
    public let duration: Double
    public let sampleTimes: [Double]
    public private(set) var nextFrameIndex: Int
    /// Actual decoder timestamps, populated only after the caller saves that frame's observations.
    public private(set) var actualFrameTimes: [Double?]
    /// Optional for legacy queues; a failed frame stays the next frame to process.
    public private(set) var failedFrameIndex: Int?
    public private(set) var failureMessage: String?
    public private(set) var failureDate: Date?

    public var isComplete: Bool { nextFrameIndex >= sampleTimes.count }
    public var progress: Double { sampleTimes.isEmpty ? 0 : Double(nextFrameIndex) / Double(sampleTimes.count) }
    public var remainingFrames: Int { max(0, sampleTimes.count - nextFrameIndex) }
    public var isRoomConfirmed: Bool { roomConfirmed != false }

    public init(id: String = UUID().uuidString, room: String, createdAt: Date = Date(),
                originalFilename: String, duration: Double, sampleTimes: [Double],
                nextFrameIndex: Int = 0, actualFrameTimes: [Double?]? = nil,
                roomConfirmed: Bool? = true, proposedRoom: String? = nil,
                failedFrameIndex: Int? = nil, failureMessage: String? = nil, failureDate: Date? = nil) {
        self.id = id; self.room = room; self.createdAt = createdAt
        self.roomConfirmed = roomConfirmed; self.proposedRoom = proposedRoom
        self.originalFilename = originalFilename; self.duration = duration
        self.sampleTimes = sampleTimes; self.nextFrameIndex = nextFrameIndex
        self.actualFrameTimes = actualFrameTimes ?? Array(repeating: nil, count: sampleTimes.count)
        self.failedFrameIndex = failedFrameIndex; self.failureMessage = failureMessage; self.failureDate = failureDate
    }

    /// Stable even if decoding returns a nearby timestamp on a later retry.
    public func frameKey(at index: Int) -> String { "\(id):frame:\(index)" }

    fileprivate mutating func finishNextFrame(actualTimeSeconds: Double?) {
        actualFrameTimes[nextFrameIndex] = actualTimeSeconds
        nextFrameIndex += 1
        failedFrameIndex = nil
        failureMessage = nil
        failureDate = nil
    }

    fileprivate mutating func recordFailure(_ message: String) {
        failedFrameIndex = nextFrameIndex
        failureMessage = message
        failureDate = Date()
    }

    fileprivate mutating func confirmRoom(_ name: String) {
        room = name
        roomConfirmed = true
        proposedRoom = nil
    }

    fileprivate mutating func proposeRoom(_ name: String?) { proposedRoom = name }
}

public struct VideoIndexFrame: Sendable {
    public let jpegData: Data
    public let requestedTimeSeconds: Double
    public let actualTimeSeconds: Double
    public let index: Int
    public let frameKey: String
}

public enum VideoIndexQueueError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidManifest
    case invalidRoom
    case roomNeedsConfirmation
    case roomAlreadyIndexed
    case invalidSource
    case unsupportedDuration
    case noVideoTrack
    case jobNotFound
    case frameOutOfRange
    case frameOutOfOrder(expected: Int, actual: Int)
    case missingSource
    case imageEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "This video queue uses unsupported version \(version). It was not changed."
        case .invalidManifest: return "The saved video queue is invalid. It has been preserved for recovery."
        case .invalidRoom: return "Give this video a room name before indexing it."
        case .roomNeedsConfirmation: return "Confirm which room this video shows before saving its observations."
        case .roomAlreadyIndexed: return "This video already has saved observations. Its room cannot be changed during indexing."
        case .invalidSource: return "Choose a readable local video file."
        case .unsupportedDuration: return "Choose a video between 0.1 seconds and 10 minutes long."
        case .noVideoTrack: return "This file does not contain a readable video track."
        case .jobNotFound: return "This video is no longer in the indexing queue."
        case .frameOutOfRange: return "That frame is outside the video indexing plan."
        case .frameOutOfOrder(let expected, let actual): return "The next frame changed from \(expected + 1) to \(actual + 1). Reload the saved job before continuing."
        case .missingSource: return "The saved source video is missing. Import the original video again."
        case .imageEncodingFailed: return "This video frame could not be converted into an image."
        }
    }
}

/// A foreground, resumable queue. It schedules no background work and makes no inference calls.
/// Save frame observations before marking a frame complete; use frameKey to make retries idempotent.
public actor VideoIndexQueue {
    private struct Manifest: Codable {
        var version = 1
        var jobs: [VideoIndexJob]
    }

    public static let maximumDurationSeconds: Double = 600
    public static let maximumSamples = 12
    public static let frameToleranceSeconds: Double = 0.1
    public let directory: URL
    private let sourcesDirectory: URL
    private let manifestURL: URL
    private var storedJobs: [VideoIndexJob]

    public init(directory requestedDirectory: URL? = nil) throws {
        let directory: URL
        if let requestedDirectory {
            directory = requestedDirectory
        } else {
            directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
                .appendingPathComponent("AsterVideoQueue", isDirectory: true)
        }
        self.directory = directory
        sourcesDirectory = directory.appendingPathComponent("sources", isDirectory: true)
        manifestURL = directory.appendingPathComponent("queue.json")
        try FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        var privateDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try privateDirectory.setResourceValues(values)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.version == 1 else { throw VideoIndexQueueError.unsupportedVersion(manifest.version) }
            guard Set(manifest.jobs.map(\.id)).count == manifest.jobs.count,
                  manifest.jobs.allSatisfy(Self.isValidJob) else { throw VideoIndexQueueError.invalidManifest }
            storedJobs = manifest.jobs
        } else {
            storedJobs = []
        }
    }

    public func jobs() -> [VideoIndexJob] { storedJobs.sorted { $0.createdAt > $1.createdAt } }
    public func pendingJobs() -> [VideoIndexJob] { storedJobs.filter { !$0.isComplete }.sorted { $0.createdAt < $1.createdAt } }
    public func job(id: String) -> VideoIndexJob? { storedJobs.first { $0.id == id } }
    public func currentPendingJob() -> VideoIndexJob? { pendingJobs().first }

    public func importVideo(from source: URL, room: String, roomConfirmed: Bool = true) async throws -> VideoIndexJob {
        let trimmedRoom = room.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoom.isEmpty else { throw VideoIndexQueueError.invalidRoom }
        guard source.isFileURL else { throw VideoIndexQueueError.invalidSource }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw VideoIndexQueueError.invalidSource }
        try Task.checkCancellation()

        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration >= 0.1, duration <= Self.maximumDurationSeconds else {
            throw VideoIndexQueueError.unsupportedDuration
        }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw VideoIndexQueueError.noVideoTrack }
        try Task.checkCancellation()

        let id = UUID().uuidString
        let providedExtension = source.pathExtension.lowercased()
        let fileExtension = ["mov", "mp4", "m4v"].contains(providedExtension) ? providedExtension : "mov"
        let filename = "\(id).\(fileExtension)"
        let target = sourcesDirectory.appendingPathComponent(filename)
        let staging = sourcesDirectory.appendingPathComponent("\(id).partial")
        do {
            // Preserve the original container and bytes; do not transcode on import.
            try FileManager.default.copyItem(at: source, to: staging)
            try FileManager.default.moveItem(at: staging, to: target)
            try Task.checkCancellation()
            let count = min(Self.maximumSamples, max(1, Int(ceil(duration))))
            // Midpoints avoid an invalid final timestamp and cover the entire clip uniformly.
            let times = (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
            let job = VideoIndexJob(id: id, room: trimmedRoom, originalFilename: filename,
                                    duration: duration, sampleTimes: times, roomConfirmed: roomConfirmed)
            let next = storedJobs + [job]
            try persist(next)
            storedJobs = next
            return job
        } catch {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    /// Confirmation is persisted before any frame observations are indexed.
    @discardableResult
    public func updateRoom(id: String, room: String) throws -> VideoIndexJob {
        guard let index = storedJobs.firstIndex(where: { $0.id == id }) else { throw VideoIndexQueueError.jobNotFound }
        let name = room.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw VideoIndexQueueError.invalidRoom }
        guard storedJobs[index].nextFrameIndex == 0 || storedJobs[index].room == name else {
            throw VideoIndexQueueError.roomAlreadyIndexed
        }
        var next = storedJobs
        next[index].confirmRoom(name)
        try persist(next)
        storedJobs = next
        return next[index]
    }

    /// A model suggestion is never treated as user confirmation.
    @discardableResult
    public func setRoomProposal(id: String, room: String?) throws -> VideoIndexJob {
        guard let index = storedJobs.firstIndex(where: { $0.id == id }) else { throw VideoIndexQueueError.jobNotFound }
        guard !storedJobs[index].isRoomConfirmed, storedJobs[index].nextFrameIndex == 0 else {
            throw VideoIndexQueueError.roomAlreadyIndexed
        }
        let name = room?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.map({ !$0.isEmpty && $0.count <= 100 }) ?? true else {
            throw VideoIndexQueueError.invalidRoom
        }
        var next = storedJobs
        next[index].proposeRoom(name)
        try persist(next)
        storedJobs = next
        return next[index]
    }

    public func sourceURL(for job: VideoIndexJob) -> URL? {
        guard let saved = self.job(id: job.id), Self.isSafeFilename(saved.originalFilename) else { return nil }
        let url = sourcesDirectory.appendingPathComponent(saved.originalFilename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func frameJPEG(for job: VideoIndexJob, index: Int) async throws -> Data {
        try await frame(for: job, index: index).jpegData
    }

    public func frame(for job: VideoIndexJob, index: Int) async throws -> VideoIndexFrame {
        guard let saved = self.job(id: job.id) else { throw VideoIndexQueueError.jobNotFound }
        guard saved.sampleTimes.indices.contains(index) else { throw VideoIndexQueueError.frameOutOfRange }
        guard let url = sourceURL(for: saved) else { throw VideoIndexQueueError.missingSource }
        try Task.checkCancellation()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(seconds: Self.frameToleranceSeconds, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: Self.frameToleranceSeconds, preferredTimescale: 600)
        let requested = saved.sampleTimes[index]
        let extracted = try await generator.image(at: CMTime(seconds: requested, preferredTimescale: 600))
        try Task.checkCancellation()
        guard self.job(id: saved.id) != nil else { throw VideoIndexQueueError.jobNotFound }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw VideoIndexQueueError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, extracted.image,
                                  [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), extracted.actualTime.seconds.isFinite else {
            throw VideoIndexQueueError.imageEncodingFailed
        }
        return VideoIndexFrame(jpegData: data as Data, requestedTimeSeconds: requested,
                               actualTimeSeconds: extracted.actualTime.seconds, index: index,
                               frameKey: saved.frameKey(at: index))
    }

    @discardableResult
    public func markFrameComplete(id: String, expectedIndex: Int? = nil, actualTimeSeconds: Double? = nil) throws -> VideoIndexJob {
        guard let position = storedJobs.firstIndex(where: { $0.id == id }) else { throw VideoIndexQueueError.jobNotFound }
        let current = storedJobs[position]
        guard current.isRoomConfirmed else { throw VideoIndexQueueError.roomNeedsConfirmation }
        if let expectedIndex, expectedIndex != current.nextFrameIndex {
            throw VideoIndexQueueError.frameOutOfOrder(expected: expectedIndex, actual: current.nextFrameIndex)
        }
        guard !current.isComplete else { return current }
        if let actualTimeSeconds {
            guard actualTimeSeconds.isFinite, actualTimeSeconds >= 0,
                  actualTimeSeconds <= current.duration + Self.frameToleranceSeconds else {
                throw VideoIndexQueueError.frameOutOfRange
            }
        }
        var next = storedJobs
        next[position].finishNextFrame(actualTimeSeconds: actualTimeSeconds)
        try persist(next)
        storedJobs = next
        return next[position]
    }

    /// Persists the failure without changing completed frames, timestamps, or the source.
    /// expectedIndex prevents a late error from marking a newer frame as failed.
    @discardableResult
    public func markFailed(id: String, expectedIndex: Int, message: String) throws -> VideoIndexJob {
        guard let position = storedJobs.firstIndex(where: { $0.id == id }) else { throw VideoIndexQueueError.jobNotFound }
        let current = storedJobs[position]
        guard !current.isComplete else { throw VideoIndexQueueError.frameOutOfRange }
        guard expectedIndex == current.nextFrameIndex else {
            throw VideoIndexQueueError.frameOutOfOrder(expected: expectedIndex, actual: current.nextFrameIndex)
        }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = storedJobs
        next[position].recordFailure(text.isEmpty ? "This frame could not be processed. Try again to continue." : String(text.prefix(1000)))
        try persist(next)
        storedJobs = next
        return next[position]
    }

    public func removeJob(id: String, deleteSource: Bool = true) throws {
        guard let deleted = storedJobs.first(where: { $0.id == id }) else { throw VideoIndexQueueError.jobNotFound }
        if deleteSource {
            let url = sourcesDirectory.appendingPathComponent(deleted.originalFilename)
            // Keep the job visible if removing its source fails, so deletion can
            // be retried. If the later manifest write fails, retrying also works:
            // an already-removed source is treated as completed cleanup.
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        let next = storedJobs.filter { $0.id != id }
        try persist(next)
        storedJobs = next
    }

    public func deleteAll() throws {
        try persist([])
        storedJobs = []
        // Also remove orphan copies from interrupted imports or jobs removed with deleteSource false.
        for url in try FileManager.default.contentsOfDirectory(at: sourcesDirectory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func persist(_ jobs: [VideoIndexJob]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Manifest(jobs: jobs)).write(to: manifestURL, options: .atomic)
    }

    private static func isSafeFilename(_ filename: String) -> Bool {
        !filename.isEmpty && filename != "." && filename != ".." && !filename.contains("/") && !filename.contains("\\")
    }

    private static func isValidJob(_ job: VideoIndexJob) -> Bool {
        UUID(uuidString: job.id) != nil && !job.room.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (job.proposedRoom.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 100 } ?? true) &&
        (job.isRoomConfirmed || job.nextFrameIndex == 0) &&
        isSafeFilename(job.originalFilename) && job.originalFilename.hasPrefix(job.id + ".") &&
        job.duration.isFinite && job.duration >= 0.1 && job.duration <= maximumDurationSeconds &&
        !job.sampleTimes.isEmpty && job.sampleTimes.count <= maximumSamples &&
        job.sampleTimes.allSatisfy { $0.isFinite && $0 >= 0 && $0 < job.duration } &&
        zip(job.sampleTimes, job.sampleTimes.dropFirst()).allSatisfy { $0 < $1 } &&
        (0...job.sampleTimes.count).contains(job.nextFrameIndex) &&
        (job.failedFrameIndex.map { $0 == job.nextFrameIndex && job.sampleTimes.indices.contains($0) } ?? true) &&
        (job.failureMessage.map { !$0.isEmpty && $0.count <= 1000 } ?? true) &&
        job.actualFrameTimes.count == job.sampleTimes.count &&
        job.actualFrameTimes.allSatisfy { time in
            guard let time else { return true }
            return time.isFinite && time >= 0 && time <= job.duration + frameToleranceSeconds
        }
    }
}
