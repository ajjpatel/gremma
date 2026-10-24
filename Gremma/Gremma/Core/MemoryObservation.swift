import Foundation

public enum MemoryCaptureSource: String, Codable, Sendable { case cameraPhoto, importedPhoto, video }

/// An observation of an item, not a claim about its current location.
public struct MemoryObservation: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var itemName: String
    public var aliases: [String]
    public var room: String
    public var locationDescription: String
    public var capturedAt: Date
    public var videoID: String?
    public var videoTimeSeconds: Double?
    public var imageFilename: String?
    public var notes: String?
    public var embedding: [Float]?
    public var captureSource: MemoryCaptureSource?

    public init(id: UUID = UUID(), itemName: String, aliases: [String] = [], room: String,
                locationDescription: String, capturedAt: Date = Date(), videoID: String? = nil,
                videoTimeSeconds: Double? = nil, imageFilename: String? = nil,
                notes: String? = nil, embedding: [Float]? = nil, captureSource: MemoryCaptureSource? = nil) {
        self.id = id
        self.itemName = itemName
        self.aliases = aliases
        self.room = room
        self.locationDescription = locationDescription
        self.capturedAt = capturedAt
        self.videoID = videoID
        self.videoTimeSeconds = videoTimeSeconds
        self.imageFilename = imageFilename
        self.notes = notes
        self.embedding = embedding
        self.captureSource = captureSource
    }

    public var lastSeenDescription: String {
        let time = capturedAt.formatted(date: .abbreviated, time: .shortened)
        let place = [room, locationDescription].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: ", ")
        let provenance: String
        if videoID != nil || captureSource == .video { provenance = "seen in a video added \(time). The recording date may differ" }
        else if captureSource == .importedPhoto { provenance = "seen in a photo added \(time). The photograph's date is unknown" }
        else { provenance = "last seen \(time)" }
        return "\(itemName), \(provenance)\(place.isEmpty ? "" : ", \(place)"). This is a saved observation; it may have moved."
    }
}

public enum MemorySearchResult: Equatable, Sendable {
    case noMatch
    case match(MemoryObservation)
    case ambiguous([MemoryObservation])

    public var observations: [MemoryObservation] {
        switch self {
        case .noMatch: return []
        case .match(let observation): return [observation]
        case .ambiguous(let observations): return observations
        }
    }

    public var spokenText: String {
        switch self {
        case .noMatch:
            return "I don't have a matching observation. Try another name, or record the room first."
        case .match(let observation):
            return observation.lastSeenDescription
        case .ambiguous(let observations):
            let choices = observations.prefix(3).map { "\($0.itemName) in \($0.room)" }.joined(separator: ", or ")
            return "I found more than one possible item: \(choices). Say find, followed by the item name and its room."
        }
    }
}

/// Conservative lexical retrieval for names and user-provided aliases. No nearest match is invented.
public enum MemoryRetrieval {
    public static func search(_ query: String, in observations: [MemoryObservation]) -> MemorySearchResult {
        let terms = tokens(query)
        guard !terms.isEmpty else { return .noMatch }
        let querySet = Set(terms)
        var candidates = observations.filter { observation in
            ([observation.itemName] + observation.aliases).contains { name in
                let nameTerms = Set(tokens(name))
                let contextualTerms = nameTerms.union(tokens(observation.room))
                return !nameTerms.isEmpty && !querySet.isDisjoint(with: nameTerms) && querySet.isSubset(of: contextualTerms)
            }
        }
        guard !candidates.isEmpty else { return .noMatch }
        candidates.sort {
            if $0.capturedAt != $1.capturedAt { return $0.capturedAt > $1.capturedAt }
            if let videoID = $0.videoID, videoID == $1.videoID {
                return ($0.videoTimeSeconds ?? 0) > ($1.videoTimeSeconds ?? 0)
            }
            return $0.id.uuidString < $1.id.uuidString
        }

        // A newer sighting of the same canonical name replaces an older sighting for this answer.
        // Distinct names, such as red mug and blue mug, remain distinct candidates.
        var seenNames = Set<String>()
        candidates = candidates.filter {
            seenNames.insert(tokens($0.itemName).joined(separator: " ") + "|" + tokens($0.room).joined(separator: " ")).inserted
        }
        return candidates.count == 1 ? .match(candidates[0]) : .ambiguous(candidates)
    }

    public static func normalizedName(_ value: String) -> String { tokens(value).joined(separator: " ") }

    private static func tokens(_ value: String) -> [String] {
        let ignored: Set<String> = ["where", "was", "were", "is", "are", "my", "the", "a", "an", "of", "in", "from", "at", "set", "pair", "please", "find", "locate", "last", "seen", "did", "i", "leave", "can", "you", "me", "tell"]
        let words = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return words.filter { !ignored.contains($0) }.map { word in
            if word == "glasses" { return word }
            if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
            if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count > 3 { return String(word.dropLast()) }
            return word
        }
    }
}
