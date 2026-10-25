import XCTest
@testable import TemporalVideoCore

@MainActor
final class ActivityVideoExtractionTests: XCTestCase {
    private func job(recordedAt: Date? = Date(timeIntervalSince1970: 1000), duration: Double = 12) -> VideoIndexJob {
        let id = UUID().uuidString
        return VideoIndexJob(id: id, room: "Kitchen", createdAt: Date(timeIntervalSince1970: 2000),
            originalFilename: "\(id).mov", duration: duration, sampleTimes: [1], recordedAt: recordedAt)
    }
    private func candidate(kind: String = "placed", entity: String = "keys", location: String = "on the table",
                           summary: String = "A hand places the keys on the table.", start: Double = 2, end: Double = 3,
                           confidence: Double = 0.9, uncertain: Bool = false) -> [String: Any] {
        ["kind": kind, "entity": entity, "location": location, "summary": summary,
         "start": start, "end": end, "confidence": confidence, "uncertain": uncertain]
    }
    private func raw(_ events: [[String: Any]]) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: ["events": events]), encoding: .utf8)!
    }
    private func parse(_ events: [[String: Any]], description: String = "A hand places the keys on the table.",
                       video: VideoIndexJob? = nil, index: Int = 0) throws -> [ActivityEvent] {
        let video = video ?? job()
        return try ActivityVideoIndexer.events(from: raw(events), description: description,
            job: video, window: video.activityWindow(at: index))
    }
    func testGroundedPlacementUsesRecordingDateAndStableSegment() async throws {
        let video = job()
        let summary = "At 3.00 seconds, a hand places the keys on the table."
        let events = try parse([candidate(summary: summary, start: 3, end: 3)], description: summary, video: video)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.kind, .placed)
        XCTAssertEqual(event.occurredAt, Date(timeIntervalSince1970: 1003))
        XCTAssertNotEqual(event.occurredAt, video.createdAt)
        XCTAssertEqual(event.id, "\(video.activitySegmentID(at: 0)):event:0")
        XCTAssertEqual(event.location, "on the table (video labeled Kitchen)")
        XCTAssertEqual(event.summary, summary)
        XCTAssertEqual(event.startSeconds, 3)
        XCTAssertEqual(event.endSeconds, 3)
    }
    func testUntimedDescriptionUsesWholeWindowInsteadOfInventedSecond() async throws {
        let event = try XCTUnwrap(parse([candidate(start: 2, end: 3)]).first)
        XCTAssertEqual(event.startSeconds, 0)
        XCTAssertEqual(event.endSeconds, 6)
        XCTAssertEqual(event.occurredAt, Date(timeIntervalSince1970: 1006))
        let later = try XCTUnwrap(parse([candidate(start: 8, end: 9)], video: job(duration: 10), index: 1).first)
        XCTAssertEqual(later.startSeconds, 6)
        XCTAssertEqual(later.endSeconds, 10)
        XCTAssertEqual(later.occurredAt, Date(timeIntervalSince1970: 1010))
    }
    func testRepeatedUntimedActivityAtGeneratedSecondsCollapses() async throws {
        let summary = "A person waters the flowers in a pot."
        let events = try parse([
            candidate(kind: "other", entity: "flowers", location: "in a pot", summary: summary, start: 1, end: 1),
            candidate(kind: "other", entity: "flowers", location: "in a pot", summary: summary, start: 3, end: 3),
            candidate(kind: "other", entity: "flowers", location: "in a pot", summary: summary, start: 5, end: 5)
        ], description: summary)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.startSeconds, 0)
        XCTAssertEqual(events.first?.endSeconds, 6)
    }
    func testAmbiguousNativeLaundryDirectionCannotBecomePlacementOrPickup() async throws {
        let summary = "The person is handling a piece of light-colored fabric, which is being placed into or taken from the basket."
        for kind in ["placed", "picked_up", "moved", "other"] {
            let event = try XCTUnwrap(parse([
                candidate(kind: kind, entity: "piece of light-colored fabric", location: "the basket", summary: summary,
                          confidence: 0.99)
            ], description: summary).first)
            XCTAssertEqual(event.kind, .other)
            XCTAssertTrue(event.isUncertain)
            XCTAssertFalse(event.hasClearEvidence)
            XCTAssertEqual(event.summary, summary)
        }
    }
    func testAlternativeMotionPreservesSourceUncertaintyEvenWhenSummaryDropsIt() async throws {
        let description = "The hand either places the keys on the table or picks up the keys from the table."
        let event = try XCTUnwrap(parse([
            candidate(summary: "places the keys on the table", confidence: 0.99)
        ], description: description).first)
        XCTAssertEqual(event.kind, .other)
        XCTAssertTrue(event.isUncertain)
        XCTAssertFalse(event.hasClearEvidence)
        let clear = "A hand picks up the keys and then places the keys on the table."
        let sequential = try XCTUnwrap(parse([candidate(summary: clear)], description: clear).first)
        XCTAssertEqual(sequential.kind, .placed)
        XCTAssertTrue(sequential.hasClearEvidence)
    }
    func testMoreThanTwoDistinctCurrentActivitiesRequestsRestructuring() async throws {
        let sentences = ["A person waters the flowers.", "A person folds the clothes.", "A person opens the door."]
        let entities = ["flowers", "clothes", "door"]
        let candidates = zip(sentences, entities).map { summary, entity in
            candidate(kind: "other", entity: entity, location: "", summary: summary)
        }
        XCTAssertThrowsError(try parse(candidates, description: sentences.joined(separator: " ")))
    }
    func testUnknownRecordingTimeStaysUnknown() async throws {
        let event = try XCTUnwrap(parse([candidate()], video: job(recordedAt: nil)).first)
        XCTAssertNil(event.occurredAt)
    }
    func testPickupRequiresActionInSameSummary() async throws {
        XCTAssertThrowsError(try parse([candidate(kind: "picked_up")]))
        let summary = "A hand lifts the keys from the table."
        let event = try XCTUnwrap(parse([candidate(kind: "picked_up", location: "from the table", summary: summary)], description: summary).first)
        XCTAssertEqual(event.kind, .pickedUp)
    }
    func testStationaryKeysRemainSightingWithoutInventedPlacement() async throws {
        let summary = "The keys are visible on the table."
        let event = try XCTUnwrap(parse([candidate(kind: "sighting", summary: summary)], description: summary).first)
        XCTAssertEqual(event.kind, .sighting)
        XCTAssertTrue(event.hasClearEvidence)
        XCTAssertThrowsError(try parse([candidate(kind: "placed", summary: summary)], description: summary))
    }
    func testSyntheticMotionAndStaticShapeAreAcceptedWhenGrounded() async throws {
        let moving = "The red square moves to the right."
        let stationary = "The blue circle stays on the gray line."
        let events = try parse([
            candidate(kind: "moved", entity: "red square", location: "to the right", summary: moving),
            candidate(kind: "sighting", entity: "blue circle", location: "on the gray line", summary: stationary)
        ], description: moving + " " + stationary)
        XCTAssertEqual(events.map(\.kind), [.moved, .sighting])
    }
    func testExplicitAbsenceCannotBecomePositiveSighting() async throws {
        for summary in ["No keys are visible on the table.", "There are no visible keys on the table.",
                        "The keys are not visible on the table.", "The keys are not on the table.",
                        "The keys aren't present on the table.", "The keys are missing from the table.",
                        "I cannot see the keys on the table."] {
            XCTAssertThrowsError(try parse([candidate(kind: "sighting", location: "", summary: summary)], description: summary), summary)
        }
        let summary = "No person is visible, but the keys are visible on the table."
        XCTAssertEqual(try parse([candidate(kind: "sighting", summary: summary)], description: summary).first?.kind, .sighting)
    }
    func testCopiedSubstringCannotDiscardSourceNegation() async throws {
        XCTAssertThrowsError(try parse([
            candidate(kind: "sighting", location: "", summary: "keys are visible.")
        ], description: "No keys are visible."))
        XCTAssertThrowsError(try parse([
            candidate(kind: "medicine", entity: "medicine", location: "", summary: "taking medicine.")
        ], description: "The person is not taking medicine."))
        XCTAssertThrowsError(try parse([
            candidate(kind: "picked_up", location: "", summary: "lift the keys.")
        ], description: "The person did not lift the keys."))
        let summary = "A hand places the keys on the table."
        XCTAssertEqual(try parse([candidate()], description: "There is no medicine in view. " + summary).first?.kind, .placed)
    }
    func testEntityCannotBeBorrowedFromDifferentSentence() async throws {
        let description = "A hand places the keys on the table. A wallet is beside the chair."
        XCTAssertThrowsError(try parse([candidate(entity: "wallet")], description: description))
        XCTAssertThrowsError(try parse([candidate(location: "beside the chair")], description: description))
    }
    func testInventedLocationAndOutsideWindowAreRejected() async throws {
        XCTAssertThrowsError(try parse([candidate(location: "in the bedroom")]))
        XCTAssertThrowsError(try parse([candidate(start: -1)]))
        XCTAssertThrowsError(try parse([candidate(start: 7, end: 8)]))
        XCTAssertThrowsError(try parse([candidate(start: 4, end: 3)]))
    }
    func testEndBoundaryAllowedButContextEventOwnedByPreviousWindowRejected() async throws {
        XCTAssertEqual(try parse([candidate(start: 5, end: 6)]).count, 1)
        XCTAssertThrowsError(try parse([candidate(start: 5, end: 6)], index: 1))
        XCTAssertEqual(try parse([candidate(start: 6, end: 7)], index: 1).count, 1)
    }
    func testNativePrecedingContextDoesNotDiscardCurrentPlacement() async throws {
        let video = job(duration: 10)
        let held = "At 5.38 seconds, a hand holds the keys."
        let earlier = "At 5.96 seconds, the keys are visible on the table."
        let current = "At 9.93 seconds, a hand places the keys on the table."
        let events = try parse([
            candidate(kind: "other", location: "", summary: held, start: 5.38, end: 5.38),
            candidate(kind: "sighting", summary: earlier, start: 5.96, end: 5.96),
            candidate(summary: current, start: 9.93, end: 9.93)
        ], description: held + " " + earlier + " " + current, video: video, index: 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(event.kind, .placed)
        XCTAssertEqual(event.summary, current)
        XCTAssertEqual(event.startSeconds, 9.93)
        XCTAssertEqual(event.endSeconds, 9.93)
        XCTAssertEqual(event.id, video.activitySegmentID(at: 1) + ":event:2")
        XCTAssertEqual(event.occurredAt, Date(timeIntervalSince1970: 1009.93))
    }
    func testOnlyLegitimateWholeContextEventsMayBeSkipped() async throws {
        XCTAssertTrue(try parse([candidate(start: 5.38, end: 5.96)], index: 1).isEmpty)
        for bounds in [(5.0, 5.2), (-1.0, 5.38), (5.96, 5.38), (5.38, 6.0), (5.38, 9.93), (9.93, 10.01), (10.0, 10.0)] {
            XCTAssertThrowsError(try parse([
                candidate(start: bounds.0, end: bounds.1), candidate(start: 9.93, end: 9.93)
            ], video: job(duration: 10), index: 1), "Invalid bounds \(bounds) must not hide inside context filtering")
        }
        XCTAssertThrowsError(try parse([candidate(start: -0.05, end: 0)], index: 0))
        XCTAssertThrowsError(try parse([candidate(entity: "wallet", start: 5.38, end: 5.96)], index: 1))
        XCTAssertThrowsError(try parse([candidate(start: 5.38, end: 5.96, confidence: 1.1)], index: 1))
        let negated = "A hand does not place the keys on the table."
        XCTAssertThrowsError(try parse([candidate(summary: negated, start: 5.38, end: 5.96)], description: negated, index: 1))
    }
    func testNonfiniteContextTimestampCannotBeIgnored() async throws {
        let video = job()
        let malformed = try raw([candidate(start: 5.38, end: 5.96)]).replacingOccurrences(
            of: #""start"\s*:\s*[^,}]+"#, with: "\"start\":1e309", options: .regularExpression)
        XCTAssertTrue(malformed.contains("1e309"))
        XCTAssertThrowsError(try ActivityVideoIndexer.events(from: malformed, description: "A hand places the keys on the table.",
            job: video, window: video.activityWindow(at: 1)))
    }
    func testDuplicateModelEventsCollapseWithoutDoublingLogs() async throws {
        XCTAssertEqual(try parse([candidate(), candidate()]).count, 1)
    }
    func testDescriptionUncertaintyOverridesConfidence() async throws {
        let summary = "A hand possibly places the keys on the table."
        let event = try XCTUnwrap(parse([candidate(summary: summary, confidence: 0.99)], description: summary).first)
        XCTAssertTrue(event.isUncertain)
        XCTAssertFalse(event.hasClearEvidence)
    }
    func testMedicineBottleAloneDoesNotCreateMedicineTakingLog() async throws {
        let summary = "A person holds a medicine bottle."
        XCTAssertThrowsError(try parse([candidate(kind: "medicine", entity: "medicine bottle", location: "", summary: summary)], description: summary))
        let visible = "A person takes a pill toward their mouth."
        let event = try XCTUnwrap(parse([candidate(kind: "medicine", entity: "pill", location: "", summary: visible)], description: visible).first)
        XCTAssertEqual(event.kind, .medicine)
    }
    func testNegativeStatementCannotBecomePositiveAction() async throws {
        let summary = "The person did not pick up the keys on the table."
        XCTAssertThrowsError(try parse([candidate(kind: "picked_up", summary: summary)], description: summary))
    }
    func testBareNegationAndContractionsCannotCreateActivity() async throws {
        for summary in ["The keys are not picked up from the table.", "The keys weren't picked up from the table.",
                        "The hand moves without picking up the keys from the table."] {
            XCTAssertThrowsError(try parse([candidate(kind: "picked_up", location: "from the table", summary: summary)], description: summary))
        }
        for summary in ["The person is not taking medicine.", "The person never takes medicine.", "The person isn't taking medicine."] {
            XCTAssertThrowsError(try parse([candidate(kind: "medicine", entity: "medicine", location: "", summary: summary)], description: summary))
        }
    }
    func testMayOrAppearsPreservesUncertaintyDespiteHighConfidence() async throws {
        for summary in ["A hand may place the keys on the table.", "A hand appears to place the keys on the table."] {
            let event = try XCTUnwrap(parse([candidate(summary: summary, confidence: 0.99)], description: summary).first)
            XCTAssertTrue(event.isUncertain)
        }
    }
    func testEmptyExtractionCannotSilentlyDropClearDescribedAction() async throws {
        XCTAssertThrowsError(try parse([]))
        XCTAssertThrowsError(try parse([], description: "A fireplace and a set of keys are visible."))
    }
    func testBriefEverydayActivityCannotBeSilentlyDroppedButNegationStaysEmpty() async throws {
        for action in ["waters the flowers", "sorts the laundry", "folds the clothes", "handles the basket"] {
            XCTAssertThrowsError(try parse([], description: "A person \(action)."))
            XCTAssertTrue(try parse([], description: "No person \(action).").isEmpty)
        }
    }
    func testNativeWalkingDescriptionCannotBeSilentlyDropped() async throws {
        let description = "At 0.00 seconds, a person is seated at a desk with a laptop. At 3.00 seconds, a person is standing near the window. At 5.93 seconds, the person is walking across the room."
        XCTAssertThrowsError(try parse([], description: description))
        let sentence = "At 5.93 seconds, the person is walking across the room."
        let events = try parse([candidate(kind: "other", entity: "the person", location: "across the room", summary: sentence,
                                          start: 5.93, end: 5.93)], description: description)
        XCTAssertEqual(events.first?.kind, .other)
    }
    func testNegativeOrUnclearSceneDoesNotForceAnActivity() async throws {
        for description in ["No person is walking across the room.", "The person is not standing near the window.",
                            "There are no visible objects.", "The scene is unclear.", "No keys are visible on the table."] {
            XCTAssertTrue(try parse([], description: description).isEmpty, description)
        }
    }
    func testEmptyListIsValidAndIncompleteJSONFails() async throws {
        XCTAssertTrue(try parse([], description: "No clear activity is visible.").isEmpty)
        let video = job()
        XCTAssertThrowsError(try ActivityVideoIndexer.events(from: "{\"events\":[", description: "No activity", job: video, window: video.activityWindow(at: 0)))
    }
    func testTextRepairReusesDescriptionWithoutCallingVision() async throws {
        let video = job(), model = LocalModelService()
        let description = "A hand places the keys on the table."
        model.jsonResults = [.success("{\"events\":[]}"), .success(try raw([candidate()]))]
        var outputs = [String]()
        let events = try await ActivityVideoIndexer.structureDescription(description, job: video,
            window: video.activityWindow(at: 0), model: model, diagnosticTrace: { trace in
                if case .structuredExtraction(let output) = trace { outputs.append(output) }
            })
        XCTAssertEqual(events.first?.kind, .placed)
        XCTAssertEqual(model.jsonPrompts.count, 2)
        XCTAssertTrue(model.jsonPrompts.allSatisfy { $0.contains(description) })
        XCTAssertFalse(model.jsonPrompts[0].contains("REPAIR:"))
        XCTAssertTrue(model.jsonPrompts[1].contains("REPAIR:"))
        XCTAssertEqual(model.visionCalls, 0)
        XCTAssertEqual(outputs.count, 2)
    }
    func testRepeatedInvalidExtractionPreservesUncertainVisualNote() async throws {
        let video = job(), model = LocalModelService()
        let description = "A hand places the keys on the table."
        model.jsonResults = [.success("{\"events\":["), .success("{\"events\":[]}")]
        let events = try await ActivityVideoIndexer.structureDescription(description, job: video,
            window: video.activityWindow(at: 0), model: model)
        let note = try XCTUnwrap(events.first)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(note.id, video.activitySegmentID(at: 0) + ":unstructured")
        XCTAssertEqual(note.kind, .other)
        XCTAssertEqual(note.entity, "Unclassified video segment")
        XCTAssertEqual(note.location, "")
        XCTAssertEqual(note.summary, description)
        XCTAssertEqual(note.confidence, 0)
        XCTAssertTrue(note.isUncertain)
        XCTAssertFalse(note.hasClearEvidence)
        XCTAssertEqual(note.startSeconds, 0)
        XCTAssertEqual(note.endSeconds, 6)
        XCTAssertEqual(model.jsonPrompts.count, 2)
    }
    func testValidEmptySceneDoesNotRepairOrCreateVisualNote() async throws {
        let video = job(), model = LocalModelService()
        model.jsonResults = [.success("{\"events\":[]}")]
        let events = try await ActivityVideoIndexer.structureDescription("No recognizable objects or activities.", job: video,
            window: video.activityWindow(at: 0), model: model)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(model.jsonPrompts.count, 1)
    }
    func testNativeFailureAndCancellationNeverBecomeVisualNotes() async throws {
        for failure: Error in [LocalModelService.NotUsed.controlledValidationOnly, CancellationError()] {
            let video = job(), model = LocalModelService()
            model.jsonResults = [.failure(failure)]
            do {
                _ = try await ActivityVideoIndexer.structureDescription("A hand places the keys on the table.", job: video,
                    window: video.activityWindow(at: 0), model: model)
                XCTFail("A native failure must propagate")
            } catch {
                XCTAssertEqual(error is CancellationError, failure is CancellationError)
            }
            XCTAssertEqual(model.jsonPrompts.count, 1)
        }
        let video = job(), model = LocalModelService()
        model.jsonResults = [.success("{\"events\":[]}"), .failure(LocalModelService.NotUsed.controlledValidationOnly)]
        do {
            _ = try await ActivityVideoIndexer.structureDescription("A hand places the keys on the table.", job: video,
                window: video.activityWindow(at: 0), model: model)
            XCTFail("A repair-call native failure must propagate")
        } catch { XCTAssertTrue(error is LocalModelService.NotUsed) }
        XCTAssertEqual(model.jsonPrompts.count, 2)
    }
    func testVisualNoteRetainsFullDescriptionAndUnknownRecordingDate() async throws {
        let video = job(recordedAt: nil)
        let description = "  The object is unclear. No confirmed medicine-taking action is visible.  "
        let note = try ActivityVideoIndexer.visualNote(description: description, job: video, window: video.activityWindow(at: 0))
        XCTAssertEqual(note.summary, description)
        XCTAssertNil(note.occurredAt)
        XCTAssertThrowsError(try ActivityVideoIndexer.visualNote(description: "   ", job: video, window: video.activityWindow(at: 0)))
    }
    func testLongVisualNoteStopsAtCompleteSentenceAndLabelsOmission() async throws {
        let video = job()
        let first = "A person is visible at 3.25 seconds. "
        let description = first + String(repeating: "The distant object is uncertain. ", count: 150)
        let note = try ActivityVideoIndexer.visualNote(description: description, job: video, window: video.activityWindow(at: 0))
        XCTAssertLessThanOrEqual(note.summary.count, 3000)
        let sections = note.summary.components(separatedBy: "\n[Additional description omitted")
        XCTAssertEqual(sections.count, 2)
        XCTAssertTrue(description.hasPrefix(sections[0]))
        XCTAssertTrue(sections[0].hasSuffix("."))
        XCTAssertTrue(sections[0].hasPrefix(first))
        let oversizedSentence = String(repeating: "uncertain ", count: 400) + "."
        let noneFit = try ActivityVideoIndexer.visualNote(description: oversizedSentence, job: video, window: video.activityWindow(at: 0))
        XCTAssertTrue(noneFit.summary.contains("No complete description sentence fit"))
        XCTAssertLessThanOrEqual(noneFit.summary.count, 3000)
    }
}
