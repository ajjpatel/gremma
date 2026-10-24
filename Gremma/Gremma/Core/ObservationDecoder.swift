import Foundation

public struct ObservationCandidate: Equatable, Sendable {
    public let name: String
    public let location: String

    public init(name: String, location: String) {
        self.name = name
        self.location = location
    }
}

public enum ObservationGroundingError: Error, LocalizedError, Equatable, Sendable {
    case emptyDescription
    case emptyName(index: Int)
    case emptyLocation(index: Int)
    case nameNotInDescription(index: Int)
    case locationNotInDescription(index: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyDescription: return "There is no visual description to support these observations."
        case .emptyName(let index): return "Observation \(index + 1) has no usable name to check against the visual description."
        case .emptyLocation(let index): return "Observation \(index + 1) has no usable location to check against the visual description."
        case .nameNotInDescription(let index): return "Observation \(index + 1) has a name that was not copied from the visual description."
        case .locationNotInDescription(let index): return "Observation \(index + 1) has a location that was not copied from the visual description."
        }
    }
}

/// Requires each extracted field to be a contiguous span of the original visual description.
/// Allows case, whitespace, and enclosing punctuation differences only; never stems or paraphrases.
/// This establishes textual support, not visual truth, negation, or the correct object/location pairing.
/// Structural validation (field bounds and types) remains ObservationDecoder's responsibility.
public enum ObservationDescriptionGrounding {
    public static func validate(_ candidates: [ObservationCandidate], description: String) throws {
        guard !candidates.isEmpty else { return }
        let evidence = normalize(description)
        guard !evidence.isEmpty else { throw ObservationGroundingError.emptyDescription }
        let outerPunctuation = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
            .union(CharacterSet(charactersIn: "`"))
        for (index, candidate) in candidates.enumerated() {
            let name = normalize(candidate.name.trimmingCharacters(in: outerPunctuation))
            let location = normalize(candidate.location.trimmingCharacters(in: outerPunctuation))
            guard !name.isEmpty else { throw ObservationGroundingError.emptyName(index: index) }
            guard !location.isEmpty else { throw ObservationGroundingError.emptyLocation(index: index) }
            guard containsWholeSpan(name, in: evidence) else { throw ObservationGroundingError.nameNotInDescription(index: index) }
            guard containsWholeSpan(location, in: evidence) else { throw ObservationGroundingError.locationNotInDescription(index: index) }
        }
    }

    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func containsWholeSpan(_ phrase: String, in description: String) -> Bool {
        // Unicode letters, digits, combining marks and underscores belong to words.
        // Escape the phrase so model-produced punctuation cannot become a regex instruction.
        let wordCharacter = #"[\p{L}\p{N}\p{M}_]"#
        let pattern = "(?<!" + wordCharacter + ")" + NSRegularExpression.escapedPattern(for: phrase) + "(?!" + wordCharacter + ")"
        return description.range(of: pattern, options: .regularExpression) != nil
    }
}

public struct ObservationContentSelection: Equatable, Sendable {
    public let items: [ObservationCandidate]
    public let excludedBackgroundItems: [ObservationCandidate]
}

/// Background abstractions are not retrievable physical items. This narrow name rule does not
/// determine whether other model observations are visually true. Parse and validate before filtering.
public enum ObservationContentFilter {
    public static func select(_ candidates: [ObservationCandidate]) -> ObservationContentSelection {
        var items: [ObservationCandidate] = []
        var excluded: [ObservationCandidate] = []
        for candidate in candidates {
            if isBackgroundAbstraction(candidate.name) { excluded.append(candidate) }
            else { items.append(candidate) }
        }
        return ObservationContentSelection(items: items, excludedBackgroundItems: excluded)
    }

    private static func isBackgroundAbstraction(_ name: String) -> Bool {
        let words = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !["the", "a", "an"].contains($0) }
        let abstractions: Set<String> = ["background", "image", "wallpaper"]
        let mediaObjects: Set<String> = ["photo", "photograph", "picture"]
        let blankness: Set<String> = ["plain", "blank", "empty", "uniform", "solid", "featureless"]
        let modifiers: Set<String> = ["plain", "blank", "empty", "uniform", "solid", "featureless",
                                      "white", "black", "gray", "grey", "red", "blue", "green", "yellow",
                                      "orange", "purple", "pink", "brown", "beige", "cream", "light", "dark"]
        guard let noun = words.last else { return false }
        let qualifiers = words.dropLast()
        guard abstractions.contains(noun) || (mediaObjects.contains(noun) && qualifiers.contains(where: blankness.contains)) else { return false }
        // Do not discard concrete objects such as a wallpaper roll, white wall, or picture frame.
        // Likewise, 'photograph of a dog' is not a trivial uniform-image description.
        return qualifiers.allSatisfy { modifiers.contains($0) }
    }
}

public enum ObservationDecodeError: Error, LocalizedError, Equatable, Sendable {
    case emptyResponse
    case responseTooLong
    case noJSON
    case incompleteJSON
    case malformedJSON
    case multipleJSONValues
    case unsupportedShape
    case tooManyItems
    case invalidItem(index: Int, reason: String)
    case conflictingDuplicate

    public var errorDescription: String? {
        switch self {
        case .emptyResponse: return "The model returned no observation text. Please try again."
        case .responseTooLong: return "The model returned an unexpectedly long observation. No items were saved."
        case .noJSON: return "The model described the scene but did not return structured observations. Please try again."
        case .incompleteJSON: return "The model's observation ended before its structured data was complete. No items were saved. Please try again."
        case .malformedJSON: return "The model returned malformed observation data. No missing text was guessed. Please try again."
        case .multipleJSONValues: return "The model returned multiple separate observation answers. No answer was chosen automatically. Please try again."
        case .unsupportedShape: return "The model's observation did not contain an items list with names and locations. Please try again."
        case .tooManyItems: return "The model returned more than five items. Please focus on a smaller part of the scene and try again."
        case .invalidItem(let index, let reason): return "Observation \(index + 1) \(reason). No items from this answer were saved. Please try again."
        case .conflictingDuplicate: return "The model gave different locations for the same item name. No location was chosen automatically. Please try again."
        }
    }
}

/// Accepts one complete JSON value, optionally surrounded by prose or a Markdown fence.
/// Names and locations are copied literally after trimming. This validates structure, not visual truth.
/// Accepted shapes: {"items": [...]}, [...], or one {"name": "...", "location": "..."}.
public enum ObservationDecoder {
    public static let maximumItems = 5
    public static let maximumNameLength = 100
    public static let maximumLocationLength = 400

    /// Opt-in callers receive all validated entries, including repeated names, so every
    /// raw field can be grounded before uncertainty is preserved or identical entries collapse.
    /// The default still rejects different locations for the same canonical name.
    public static func decode(_ response: String, preservingDistinctLocations: Bool = false) throws -> [ObservationCandidate] {
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ObservationDecodeError.emptyResponse
        }
        guard response.utf8.count <= 32_768 else { throw ObservationDecodeError.responseTooLong }

        let blocks = try balancedJSONBlocks(in: response)
        guard !blocks.isEmpty else { throw ObservationDecodeError.noJSON }
        // Never combine blocks or descend into a broken envelope to salvage a nested item.
        let values: [Any] = try blocks.map { block in
            do { return try JSONSerialization.jsonObject(with: Data(block.utf8)) }
            catch { throw ObservationDecodeError.malformedJSON }
        }
        guard values.count == 1 else { throw ObservationDecodeError.multipleJSONValues }

        let rawItems: [Any]
        if let envelope = values[0] as? [String: Any] {
            if let items = envelope["items"] {
                guard let list = items as? [Any] else { throw ObservationDecodeError.unsupportedShape }
                rawItems = list
            } else if envelope["name"] != nil || envelope["location"] != nil {
                rawItems = [envelope]
            } else {
                throw ObservationDecodeError.unsupportedShape
            }
        } else if let list = values[0] as? [Any] {
            rawItems = list
        } else {
            throw ObservationDecodeError.unsupportedShape
        }
        guard rawItems.count <= maximumItems else { throw ObservationDecodeError.tooManyItems }

        var candidates: [ObservationCandidate] = []
        var locationsByName: [String: String] = [:]
        for (index, value) in rawItems.enumerated() {
            guard let item = value as? [String: Any],
                  let rawName = item["name"] as? String,
                  let rawLocation = item["location"] as? String else {
                throw ObservationDecodeError.invalidItem(index: index, reason: "needs text fields named name and location")
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let location = rawLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !location.isEmpty else {
                throw ObservationDecodeError.invalidItem(index: index, reason: "has an empty name or location")
            }
            guard name.count <= maximumNameLength, location.count <= maximumLocationLength else {
                throw ObservationDecodeError.invalidItem(index: index, reason: "has a name or location that is too long")
            }
            let normalizedName = MemoryRetrieval.normalizedName(name)
            guard !normalizedName.isEmpty else {
                throw ObservationDecodeError.invalidItem(index: index, reason: "does not contain a usable item name")
            }
            if preservingDistinctLocations {
                candidates.append(ObservationCandidate(name: name, location: location))
                continue
            }
            let normalizedLocation = location.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if let previousLocation = locationsByName[normalizedName] {
                guard previousLocation == normalizedLocation else { throw ObservationDecodeError.conflictingDuplicate }
                continue
            }
            locationsByName[normalizedName] = normalizedLocation
            candidates.append(ObservationCandidate(name: name, location: location))
        }
        return candidates
    }

    private static func balancedJSONBlocks(in response: String) throws -> [String] {
        var result: [String] = []
        var openingBrackets: [Character] = []
        var start: String.Index?
        var inString = false
        var escaped = false
        var previousNonWhitespace: Character?
        for index in response.indices {
            let character = response[index]
            if start == nil {
                if character == "}" || character == "]" { throw ObservationDecodeError.malformedJSON }
                guard character == "{" || character == "[" else { continue }
                start = index
                openingBrackets = [character]
                inString = false
                escaped = false
                previousNonWhitespace = character
                continue
            }
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true; previousNonWhitespace = character; continue }
            if character == "{" || character == "[" {
                openingBrackets.append(character)
                guard openingBrackets.count <= 64 else { throw ObservationDecodeError.malformedJSON }
            } else if character == "}" || character == "]" {
                // JSONSerialization accepts trailing commas on some OS versions. Keep this decoder strict.
                guard previousNonWhitespace != "," else { throw ObservationDecodeError.malformedJSON }
                guard let opener = openingBrackets.last,
                      (opener == "{" && character == "}") || (opener == "[" && character == "]") else {
                    throw ObservationDecodeError.malformedJSON
                }
                openingBrackets.removeLast()
                if openingBrackets.isEmpty, let blockStart = start {
                    result.append(String(response[blockStart...index]))
                    start = nil
                }
            }
            if !character.isWhitespace { previousNonWhitespace = character }
        }
        guard start == nil else { throw ObservationDecodeError.incompleteJSON }
        return result
    }
}
