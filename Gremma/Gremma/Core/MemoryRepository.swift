import Foundation
import CryptoKit

public enum MemoryRepositoryError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidObservation
    case unsafeImageFilename
    case invalidVideoFrame

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "This memory file uses unsupported version \(version). It was not changed."
        case .invalidObservation: return "The observation needs an item name and a location."
        case .unsafeImageFilename: return "The saved image name is not valid."
        case .invalidVideoFrame: return "The video frame observations could not be saved together. Previous observations are unchanged."
        }
    }
}

/// Serializes mutations and writes a complete new manifest atomically. Corrupt stores are never silently erased.
public actor MemoryRepository {
    private struct Manifest: Codable {
        var version = 1
        var observations: [MemoryObservation]
        var videoFrames: [String: VideoFrameRecord]?
    }

    private struct VideoFrameRecord: Codable {
        let videoID: String
        var observationIDs: [UUID]
    }

    public let directory: URL
    private let manifestURL: URL
    private let imagesDirectory: URL
    private var observations: [MemoryObservation]
    private var videoFrames: [String: VideoFrameRecord]

    public init(directory: URL) throws {
        self.directory = directory
        manifestURL = directory.appendingPathComponent("observations.json")
        imagesDirectory = directory.appendingPathComponent("evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        var privateDirectory = directory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try privateDirectory.setResourceValues(resourceValues)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.version == 1 else { throw MemoryRepositoryError.unsupportedVersion(manifest.version) }
            observations = manifest.observations
            videoFrames = manifest.videoFrames ?? [:]
        } else {
            observations = []
            videoFrames = [:]
        }
    }

    public static func defaultDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AsterMemory", isDirectory: true)
    }

    public func all() -> [MemoryObservation] { observations.sorted { $0.capturedAt > $1.capturedAt } }

    @discardableResult
    public func save(_ observation: MemoryObservation, imageData: Data? = nil) throws -> MemoryObservation {
        guard !observation.itemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !observation.locationDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !observation.room.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryRepositoryError.invalidObservation
        }
        var updated = observation
        let old = observations.first { $0.id == updated.id }
        var newlyWrittenImage: URL?
        if let imageData {
            // Unique image names leave the old manifest and evidence valid if the manifest write fails.
            let filename = "\(updated.id.uuidString)-\(UUID().uuidString).jpg"
            let imageURL = imagesDirectory.appendingPathComponent(filename)
            try imageData.write(to: imageURL, options: .atomic)
            updated.imageFilename = filename
            newlyWrittenImage = imageURL
        } else if let name = updated.imageFilename {
            guard Self.isSafeFilename(name) else { throw MemoryRepositoryError.unsafeImageFilename }
        }
        var next = observations.filter { $0.id != updated.id }
        next.append(updated)
        do {
            try persist(next)
        } catch {
            if let newlyWrittenImage { try? FileManager.default.removeItem(at: newlyWrittenImage) }
            throw error
        }
        observations = next
        if let oldName = old?.imageFilename, oldName != updated.imageFilename {
            removeImageIfUnreferenced(oldName)
        }
        return updated
    }

    /// Commits a complete video frame in one manifest write. Reprocessing the same
    /// frame replaces its whole previous batch, including objects whose names changed.
    /// The queue checkpoint remains a separate write: if it fails after this commit,
    /// retrying the frame safely replaces this batch before advancing the checkpoint.
    @discardableResult
    public func saveVideoFrameObservations(_ batch: [MemoryObservation], videoID: String,
                                          frameKey: String, imageData: Data) throws -> [MemoryObservation] {
        guard !videoID.isEmpty, !frameKey.isEmpty, frameKey.count <= 300,
              batch.count <= 5, Set(batch.map(\.id)).count == batch.count,
              batch.allSatisfy({ observation in
                  observation.videoID == videoID &&
                  !observation.itemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !observation.locationDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  observation.itemName.count <= 100 && observation.locationDescription.count <= 400 &&
                  (observation.videoTimeSeconds.map { $0.isFinite && $0 >= 0 } ?? false)
              }),
              videoFrames[frameKey].map({ $0.videoID == videoID }) ?? true else {
            throw MemoryRepositoryError.invalidVideoFrame
        }
        try Task.checkCancellation()
        var previousIDs = Set(videoFrames[frameKey]?.observationIDs ?? [])
        // Older builds saved rows one at a time using this deterministic ID. This
        // recognizes their partial frame without guessing from nearby timestamps.
        for observation in observations where observation.videoID == videoID {
            let legacyKey = "\(frameKey)-\(MemoryRetrieval.normalizedName(observation.itemName))"
            if observation.id == Self.legacyObservationID(legacyKey) { previousIDs.insert(observation.id) }
        }
        let replacementIDs = Set(batch.map(\.id))
        guard !observations.contains(where: { replacementIDs.contains($0.id) && !previousIDs.contains($0.id) }) else {
            throw MemoryRepositoryError.invalidVideoFrame
        }
        let oldImages = Set(observations.filter { previousIDs.contains($0.id) }.compactMap(\.imageFilename))
        var saved = batch
        var newImageURL: URL?
        do {
            if !saved.isEmpty {
                let filename = "video-frame-\(UUID().uuidString).jpg"
                let url = imagesDirectory.appendingPathComponent(filename)
                try imageData.write(to: url, options: .atomic)
                newImageURL = url
                for index in saved.indices { saved[index].imageFilename = filename }
            }
            try Task.checkCancellation()
            let next = observations.filter { !previousIDs.contains($0.id) } + saved
            var nextFrames = videoFrames
            nextFrames[frameKey] = VideoFrameRecord(videoID: videoID, observationIDs: saved.map(\.id))
            try persist(next, frames: nextFrames)
            observations = next
            videoFrames = nextFrames
        } catch {
            if let newImageURL { try? FileManager.default.removeItem(at: newImageURL) }
            throw error
        }
        for filename in oldImages { removeImageIfUnreferenced(filename) }
        return saved
    }

    public func search(_ query: String) -> MemorySearchResult { MemoryRetrieval.search(query, in: observations) }

    public func delete(id: UUID) throws {
        let deleted = observations.first { $0.id == id }
        let next = observations.filter { $0.id != id }
        let nextFrames = videoFrames.mapValues { record in
            var updated = record
            updated.observationIDs.removeAll { $0 == id }
            return updated
        }
        try persist(next, frames: nextFrames)
        observations = next
        videoFrames = nextFrames
        if let filename = deleted?.imageFilename { removeImageIfUnreferenced(filename) }
    }

    /// Removes only observations belonging to this video. Evidence still used by
    /// another observation is retained; unrelated photographs and videos are untouched.
    public func deleteVideoObservations(videoID: String) throws {
        let deleted = observations.filter { $0.videoID == videoID }
        let nextFrames = videoFrames.filter { $0.value.videoID != videoID }
        guard !deleted.isEmpty || nextFrames.count != videoFrames.count else { return }
        let next = observations.filter { $0.videoID != videoID }
        try persist(next, frames: nextFrames)
        observations = next
        videoFrames = nextFrames
        for filename in Set(deleted.compactMap(\.imageFilename)) {
            removeImageIfUnreferenced(filename)
        }
    }

    public func deleteAll() throws {
        try persist([], frames: [:])
        observations = []
        videoFrames = [:]
        // Includes orphaned evidence from interrupted writes; deletion failures are surfaced to the UI.
        for url in try FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func imageURL(for observation: MemoryObservation) -> URL? {
        guard let filename = observation.imageFilename, Self.isSafeFilename(filename) else { return nil }
        let url = imagesDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func persist(_ values: [MemoryObservation], frames: [String: VideoFrameRecord]? = nil) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Manifest(observations: values, videoFrames: frames ?? videoFrames)).write(to: manifestURL, options: .atomic)
    }

    private static func legacyObservationID(_ key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func removeImageIfUnreferenced(_ filename: String) {
        guard Self.isSafeFilename(filename), !observations.contains(where: { $0.imageFilename == filename }) else { return }
        try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(filename))
    }

    private static func isSafeFilename(_ filename: String) -> Bool {
        !filename.isEmpty && filename != "." && filename != ".." && !filename.contains("/") && !filename.contains("\\")
    }
}
