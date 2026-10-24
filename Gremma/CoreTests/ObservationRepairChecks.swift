// Controlled model outputs exercise the real service, strict decoder, grounding,
// local persistence and retrieval. These tests do not establish image accuracy.
import Foundation

@main
struct ObservationRepairChecks {
    @MainActor static func main() async throws {
        let imageURL = URL(fileURLWithPath: "/synthetic-image-not-read-by-stub.jpg")
        let description = "A chair is on the left. A chair is on the right."
        let repeatedName = #"{"items":[{"name":"chair","location":"on the left"},{"name":"chair","location":"on the right"}]}"#
        do {
            _ = try ObservationDecoder.decode(repeatedName)
            preconditionFailure("Default decoder must still reject conflicting duplicates")
        } catch ObservationDecodeError.conflictingDuplicate { }

        let raw = try ObservationDecoder.decode(repeatedName, preservingDistinctLocations: true)
        precondition(raw == [ObservationCandidate(name: "chair", location: "on the left"),
                             ObservationCandidate(name: "chair", location: "on the right")])

        // Reproduces the real failure shape: first extraction empty, second names
        // two supported positions with the same generic name. No new qualifier is invented.
        let ambiguousModel = LocalModelService(description: description, replies: [#"{"items":[]}"#, repeatedName])
        let ambiguous = try await ObservationService.identify(imageURL: imageURL, model: ambiguousModel)
        let expectedLocation = "Multiple reported positions: on the left; on the right. I cannot tell whether these are separate objects."
        precondition(ambiguous.attempts == 2 && ambiguous.items == [ObservationCandidate(name: "chair", location: expectedLocation)])
        precondition(ambiguous.ambiguityNames == ["chair"])
        precondition(ambiguousModel.requests[1].contains("EMPTY_ITEMS"))

        let identical = #"{"items":[{"name":"chair","location":"on the left"},{"name":"Chair","location":"ON  THE LEFT"}]}"#
        let identicalModel = LocalModelService(description: description, replies: [identical])
        let collapsed = try await ObservationService.identify(imageURL: imageURL, model: identicalModel)
        precondition(collapsed.items == [ObservationCandidate(name: "chair", location: "on the left")] && collapsed.ambiguityNames.isEmpty)

        let unsupportedLocation = LocalModelService(description: "A chair is on the left.", replies: [repeatedName, repeatedName])
        let unsupportedReason = try await failureReason(unsupportedLocation, imageURL)
        precondition(unsupportedReason.contains("location that was not copied"), "All raw locations must pass grounding before grouping")

        let unsupportedNameRaw = #"{"items":[{"name":"chair","location":"on the left"},{"name":"the chair","location":"on the left"}]}"#
        let unsupportedName = LocalModelService(description: "A chair is on the left.", replies: [unsupportedNameRaw, unsupportedNameRaw])
        let unsupportedNameReason = try await failureReason(unsupportedName, imageURL)
        precondition(unsupportedNameReason.contains("name that was not copied"), "A normalized duplicate must not hide an unsupported raw name")

        let longLeft = "beside " + String(repeating: "left ", count: 36) + "wall"
        let longRight = "beside " + String(repeating: "right ", count: 36) + "wall"
        let longRaw = String(decoding: try JSONSerialization.data(withJSONObject: ["items": [
            ["name": "chair", "location": longLeft], ["name": "chair", "location": longRight]
        ]]), as: UTF8.self)
        let overLimit = LocalModelService(description: "A chair is \(longLeft). A chair is \(longRight).", replies: [longRaw])
        let limitReason = try await failureReason(overLimit, imageURL)
        precondition(limitReason.contains("storage limit") && overLimit.requests.count == 1,
                     "Overlong ambiguity must fail, not truncate, choose a position, or ask the model to omit one")

        let fullLocation = #"{"items":[{"name":"black chair","location":"beside the desk in the left corner"}]}"#
        let oneObject = LocalModelService(description: "A black chair is beside the desk in the left corner.", replies: [fullLocation])
        let oneResult = try await ObservationService.identify(imageURL: imageURL, model: oneObject)
        precondition(oneResult.items == [ObservationCandidate(name: "black chair", location: "beside the desk in the left corner")] && oneResult.ambiguityNames.isEmpty)

        let blank = LocalModelService(description: "The image is blank.", replies: [#"{"items":[]}"#, #"{"items":[]}"#])
        let blankResult = try await ObservationService.identify(imageURL: imageURL, model: blank)
        precondition(blankResult.items.isEmpty && blankResult.ambiguityNames.isEmpty && blankResult.attempts == 2)

        let nativeFailure = LocalModelService(description: description, replies: [repeatedName], nativeInvalidFirst: true)
        let recovered = try await ObservationService.identify(imageURL: imageURL, model: nativeFailure)
        precondition(recovered.items[0].location == expectedLocation && recovered.ambiguityNames == ["chair"])

        let malformed = LocalModelService(description: description, replies: [#"{"items":["#, repeatedName])
        let repaired = try await ObservationService.identify(imageURL: imageURL, model: malformed)
        precondition(repaired.items[0].location == expectedLocation && malformed.requests[1].contains("INVALID_JSON_STRUCTURE"))

        let ungrounded = #"{"items":[{"name":"chair","location":"on the shelf"}]}"#
        let unsupportedThenFixed = LocalModelService(description: description, replies: [ungrounded, repeatedName])
        let grounded = try await ObservationService.identify(imageURL: imageURL, model: unsupportedThenFixed)
        precondition(grounded.items[0].location == expectedLocation && unsupportedThenFixed.requests[1].contains("UNSUPPORTED_PHRASE"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GremmaAmbiguityChecks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryRepository(directory: directory)
        let observation = MemoryObservation(itemName: ambiguous.items[0].name, room: "Test room",
            locationDescription: ambiguous.items[0].location, videoID: "test-video", videoTimeSeconds: 10,
            notes: "Object identity is uncertain; all supported reported positions are retained.", captureSource: .video)
        _ = try await store.saveVideoFrameObservations([observation], videoID: "test-video", frameKey: "test-video-9",
                                                       imageData: Data("synthetic evidence bytes".utf8))
        let reopened = try MemoryRepository(directory: directory)
        let found = await reopened.search("chair")
        guard case .match(let saved) = found else { preconditionFailure("Saved ambiguous observation was not retrieved") }
        precondition(saved.locationDescription == expectedLocation)
        precondition(found.spokenText.contains("on the left") && found.spokenText.contains("on the right")
                     && found.spokenText.contains("cannot tell whether these are separate objects"))
        print("13 observation ambiguity/repair/persistence scenarios passed; inference was stubbed, validation and storage were real.")
    }

    @MainActor private static func failureReason(_ model: LocalModelService, _ imageURL: URL) async throws -> String {
        do {
            _ = try await ObservationService.identify(imageURL: imageURL, model: model)
            preconditionFailure("Expected the unsupported extraction to fail")
        } catch let error as ObservationInferenceError { return error.reason }
    }
}
