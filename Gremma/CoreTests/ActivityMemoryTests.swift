import XCTest
@testable import ActivityValidation

final class ActivityMemoryTests: XCTestCase {
    func testGenerationEvidenceKeepsResolvedPickupInsteadOfOlderPlacement() {
        let pickup = event(.pickedUp, entity: "keys")
        let request = ActivityRecallRequest(
            resolved: ActivityAnswer(text: "The keys were picked up. No later location is known.", event: pickup),
            fallback: ActivityRecallEvidence(text: "Keys were previously on the table.", event: nil, includesSamples: false),
            objectQuestion: true)
        XCTAssertTrue(request.evidence.contains("picked up"))
        XCTAssertFalse(request.evidence.contains("on the table"))
        XCTAssertEqual(request.event?.id, pickup.id)
    }

    func testGenerationEvidenceKeepsMedicineWindowAndUserConfirmation() {
        var medicine = event(.medicine, entity: "medicine")
        medicine.source = .userConfirmed
        let confirmed = ActivityRecallRequest(
            resolved: ActivityAnswer(text: "A medicine-taking video is logged this evening.", event: medicine),
            fallback: ActivityRecallEvidence(text: "", event: nil, includesSamples: false), objectQuestion: false)
        XCTAssertTrue(confirmed.evidence.contains("confirmed by the user"))
        let missing = ActivityRecallRequest(resolved: ActivityAnswer(text: "No medicine-taking video is logged this morning."),
            fallback: ActivityRecallEvidence(text: "Yesterday a medicine video was logged.", event: medicine, includesSamples: false),
            objectQuestion: false)
        XCTAssertTrue(missing.evidence.contains("No medicine-taking video"))
        XCTAssertFalse(missing.evidence.contains("Yesterday"))
        XCTAssertNil(missing.event)
    }

    func testGenerationEvidenceUsesFocusedSampleWhenPersonalObjectNotFound() {
        let request = ActivityRecallRequest(resolved: ActivityAnswer(text: "No matching object activity."),
            fallback: ActivityRecallEvidence(text: "Hands hold a wallet in a sample video.", event: nil, includesSamples: true),
            objectQuestion: true)
        XCTAssertTrue(request.evidence.contains("hold a wallet"))
        XCTAssertTrue(request.includesSamples)
        XCTAssertFalse(request.evidence.contains("No matching object"))
    }

    func testGenerationEvidenceExplicitlyRepresentsNoMatch() {
        let request = ActivityRecallRequest(resolved: nil,
            fallback: ActivityRecallEvidence(text: "", event: nil, includesSamples: false), objectQuestion: true)
        XCTAssertEqual(request.evidence, "No matching activity is saved.")
        XCTAssertNil(request.event)
    }

    func testGeneratedAnswerCannotDropUncertainEvidenceLabel() {
        let evidence = "VIDEO EVENT [v1, 0.0s; recording date unknown; uncertain]: A person may be drinking."
        let answer = ActivityAnswer.qualifyingGeneratedAnswer("A person is drinking.", evidence: evidence)
        XCTAssertTrue(answer.hasPrefix("Some of the saved video analysis is uncertain."))
    }

    func testObservedEvidenceWithUnknownDateDoesNotBecomeVisuallyUncertain() {
        let evidence = "VIDEO EVENT [v1, 0.0s; recording date unknown; observed]: A person is holding a cup."
        XCTAssertEqual(ActivityAnswer.qualifyingGeneratedAnswer("A person is holding a cup.", evidence: evidence),
                       "A person is holding a cup.")
    }

    func testMixedEvidenceKeepsTheUncertaintyWarning() {
        let evidence = "VIDEO EVENT [v1, 0.0s; today; observed]: A cup.\nVIDEO EVENT [v2, 1.0s; today; uncertain]: A possible drinking action."
        XCTAssertTrue(ActivityAnswer.qualifyingGeneratedAnswer("A person is drinking.", evidence: evidence)
            .hasPrefix("Some of the saved video analysis is uncertain."))
    }

    func testFocusedSamplesAnswerNaturalObjectQuestionsWithoutChangingPersonalRecords() async throws {
        let repository = try ActivityRepository(directory: directory())
        var sample = event(.other, at: nil, video: "wallet-sample", entity: "Unclassified video segment", uncertain: true)
        sample.id = "wallet:unstructured"; sample.isDemo = true
        sample.summary = "Hands are holding and handling a black wallet containing cards."
        try await save(sample, in: repository)
        let excluded = try await repository.relevantContext(for: "Where is my wallet?")
        XCTAssertTrue(excluded.isEmpty)
        let selected = try await repository.recallEvidence(for: "Where is my wallet?", naturalSampleVideoIDs: ["wallet-sample"])
        XCTAssertTrue(selected.text.contains("black wallet"))
        XCTAssertTrue(selected.includesSamples)
        XCTAssertEqual(selected.event?.videoID, "wallet-sample")
        let daily = try await repository.relevantContext(for: "Where was my wallet this morning?", naturalSampleVideoIDs: ["wallet-sample"])
        XCTAssertTrue(daily.isEmpty)
        let unrelated = try await repository.relevantContext(for: "Where is my wallet?", naturalSampleVideoIDs: ["other-sample"])
        XCTAssertTrue(unrelated.isEmpty)
    }

    func testPersonalMatchingEvidenceOutranksFocusedSamples() async throws {
        let repository = try ActivityRepository(directory: directory())
        var sample = event(.other, at: nil, video: "sample", entity: "wallet")
        sample.isDemo = true; sample.summary = "Wallet held in hands."
        try await save(sample, in: repository)
        let personal = event(.placed, video: "personal", entity: "wallet", location: "in the drawer")
        try await save(personal, in: repository)
        let result = try await repository.recallEvidence(for: "Where is my wallet?", naturalSampleVideoIDs: ["sample"])
        XCTAssertEqual(result.event?.videoID, "personal")
        XCTAssertFalse(result.includesSamples)
        XCTAssertFalse(result.text.contains("held in hands"))
    }

    func testMealQuestionRetrievesEatingButCannotClaimTodayFromSample() async throws {
        let repository = try ActivityRepository(directory: directory())
        var sample = event(.other, at: nil, video: "meal", entity: "person")
        sample.isDemo = true; sample.summary = "The person is eating food from a plate."
        try await save(sample, in: repository)
        let matching = try await repository.relevantContext(for: "Have I eaten?", naturalSampleVideoIDs: ["meal"])
        XCTAssertTrue(matching.contains("eating food"))
        let today = try await repository.relevantContext(for: "Did I eat today?", naturalSampleVideoIDs: ["meal"])
        XCTAssertTrue(today.isEmpty)
    }

    func testPerformanceUsesNativeTokensAndIncludesRoutingTime() {
        let inference = InferenceMetrics(elapsedSeconds: 3, firstTextSeconds: 0.5, characterCount: 90,
            cancelled: false, startedUptime: 11, lastTextSeconds: 2.8, outputTokenCount: 20, decodeTokensPerSecond: 8)
        let performance = QueryPerformance(start: 10, end: 14, inference: inference)
        XCTAssertEqual(performance.answerSeconds, 4)
        XCTAssertEqual(performance.firstTokenSeconds, 1.5)
        XCTAssertEqual(performance.lastTokenSeconds!, 3.8, accuracy: 0.0001)
        XCTAssertEqual(performance.tokensPerSecond, 8)
        XCTAssertEqual(performance.outputTokens, 20)
        XCTAssertEqual(performance.timePerOutputTokenSeconds!, 2.3 / 19, accuracy: 0.0001)
    }

    func testTPOTUnavailableForOneTokenOrInvalidTiming() {
        for inference in [
            InferenceMetrics(elapsedSeconds: 1, firstTextSeconds: 0.5, characterCount: 5, cancelled: false,
                startedUptime: 10, lastTextSeconds: 0.5, outputTokenCount: 1),
            InferenceMetrics(elapsedSeconds: 1, firstTextSeconds: 0.8, characterCount: 20, cancelled: false,
                startedUptime: 10, lastTextSeconds: 0.5, outputTokenCount: 5),
            InferenceMetrics(elapsedSeconds: 1, firstTextSeconds: nil, characterCount: 20, cancelled: false,
                startedUptime: 10, lastTextSeconds: 0.5, outputTokenCount: 5)
        ] {
            XCTAssertNil(QueryPerformance(start: 10, end: 11, inference: inference).timePerOutputTokenSeconds)
        }
    }

    func testSavedAnswersRejectStaleModelMetrics() {
        let old = InferenceMetrics(elapsedSeconds: 3, firstTextSeconds: 1, characterCount: 200,
            cancelled: false, startedUptime: 2, lastTextSeconds: 3, outputTokenCount: 50, decodeTokensPerSecond: 20)
        let performance = QueryPerformance(start: 10, end: 10.02, inference: old)
        XCTAssertNil(performance.firstTokenSeconds)
        XCTAssertNil(performance.lastTokenSeconds)
        XCTAssertNil(performance.tokensPerSecond)
        XCTAssertNil(performance.timePerOutputTokenSeconds)
        XCTAssertEqual(performance.source, "Saved answer")
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return value
    }
    private var today: Date { date("2026-10-24T12:00:00-07:00") }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gremma-activity-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func event(_ kind: ActivityKind, at time: String? = "2026-10-24T08:00:00-07:00", video: String = "v1", segment: String = "s1", entity: String = "keys", location: String = "on the kitchen table", uncertain: Bool = false) -> ActivityEvent {
        ActivityEvent(videoID: video, segmentID: segment, kind: kind, entity: entity, location: location,
                      summary: "\(entity) \(kind.rawValue) \(location)", occurredAt: time.map(date),
                      startSeconds: 1, endSeconds: 3, confidence: 0.9, isUncertain: uncertain)
    }
    private func save(_ event: ActivityEvent, in repository: ActivityRepository) async throws {
        try await repository.replaceSegment(videoID: event.videoID, segmentID: event.segmentID, events: [event])
    }

    func testPlacementAndPickupInvalidatesOldLocation() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.placed), in: repository)
        let before = try await repository.answer(query: "Where are my keys?", now: today, calendar: calendar)
        XCTAssertTrue(before!.text.contains("kitchen table"))
        try await save(event(.pickedUp, at: "2026-10-24T09:20:00-07:00", video: "v2"), in: repository)
        let after = try await repository.answer(query: "Where are my keys?", now: today, calendar: calendar)
        XCTAssertTrue(after!.text.contains("picked up"))
        XCTAssertTrue(after!.text.contains("haven't seen where"))
        XCTAssertFalse(after!.text.contains("kitchen table"))
    }

    func testNewPlacementAfterPickupUpdatesState() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.pickedUp), in: repository)
        try await save(event(.placed, at: "2026-10-24T09:25:00-07:00", video: "v2", location: "beside the bed"), in: repository)
        let answer = try await repository.answer(query: "Where did I put my keys?", now: today, calendar: calendar)
        XCTAssertTrue(answer!.text.contains("beside the bed"))
        XCTAssertFalse(answer!.text.contains("picked up"))
    }

    func testOutOfOrderImportDoesNotOverwriteLaterOccurrence() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.pickedUp, at: "2026-10-24T10:00:00-07:00", video: "newer"), in: repository)
        var earlier = event(.placed, video: "older")
        earlier.indexedAt = today.addingTimeInterval(1_000)
        try await save(earlier, in: repository)
        let answer = try await repository.answer(query: "Where are my keys?", now: today, calendar: calendar)
        XCTAssertEqual(answer?.event?.videoID, "newer")
    }

    func testUnknownDatesAreExcludedFromTodayAndMedicineLog() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.medicine, at: nil, entity: "medicine"), in: repository)
        let daily = try await repository.events(on: today, calendar: calendar)
        let status = try await repository.medicineLogStatus(for: .morning, on: today, calendar: calendar)
        XCTAssertTrue(daily.isEmpty)
        XCTAssertFalse(status.hasLog)
        let all = try await repository.events()
        XCTAssertEqual(all.count, 1)
    }

    func testUnknownDateLocationDoesNotInventOrdering() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.placed, at: nil), in: repository)
        let answer = try await repository.answer(query: "Where are my keys?", now: today, calendar: calendar)
        XCTAssertTrue(answer!.text.contains("recording date is unknown"))
        XCTAssertFalse(answer!.text.contains("kitchen table"))
    }

    func testUndatedEvidenceQualifiesLatestDatedAnswer() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.placed), in: repository)
        try await save(event(.pickedUp, at: nil, video: "unknown"), in: repository)
        let answer = try await repository.answer(query: "Where are my keys?", now: today, calendar: calendar)
        XCTAssertTrue(answer!.text.contains("can't confirm this was the most recent"))
    }

    func testRetryReplacesEntireSegmentWithoutDuplicates() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.placed), in: repository)
        try await save(event(.pickedUp), in: repository)
        let events = try await repository.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .pickedUp)
    }

    func testEmptyReplacementRemovesPreviouslyMisidentifiedEvent() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.medicine, entity: "medicine"), in: repository)
        try await repository.replaceSegment(videoID: "v1", segmentID: "s1", events: [])
        let events = try await repository.events()
        XCTAssertTrue(events.isEmpty)
    }

    func testInvalidReplacementPreservesCommittedSegment() async throws {
        let repository = try ActivityRepository(directory: directory())
        let original = event(.placed)
        try await save(original, in: repository)
        var invalid = event(.pickedUp); invalid.startSeconds = -.infinity
        do { try await save(invalid, in: repository); XCTFail("Expected validation failure") }
        catch { XCTAssertTrue(error is ActivityStoreError) }
        let events = try await repository.events()
        XCTAssertEqual(events, [original])
    }

    func testDatabaseFailureRollsBackDeletion() async throws {
        let repository = try ActivityRepository(directory: directory())
        let existing = event(.placed)
        try await save(existing, in: repository)
        var conflict = event(.pickedUp, video: "v2")
        conflict.id = existing.id
        do { try await save(conflict, in: repository); XCTFail("Expected primary key failure") } catch {}
        let events = try await repository.events()
        XCTAssertEqual(events, [existing])
    }

    func testMedicineLogsAreNotDoseCountsOrDoseProof() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.medicine, entity: "medicine"), in: repository)
        try await save(event(.medicine, video: "v2", entity: "medicine"), in: repository)
        let status = try await repository.medicineLogStatus(for: .morning, on: today, calendar: calendar)
        XCTAssertTrue(status.hasLog)
        XCTAssertTrue(status.message.contains("not confirmation of a dose"))
        XCTAssertFalse(status.message.contains("two"))
        XCTAssertFalse(status.message.contains("2 doses"))
    }

    func testAmbiguousMedicineVideoDoesNotSuppressMissingClearLog() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.medicine, entity: "medicine", uncertain: true), in: repository)
        let status = try await repository.medicineLogStatus(for: .morning, on: today, calendar: calendar)
        XCTAssertFalse(status.hasLog)
        XCTAssertTrue(status.hasUncertainVideo)
        XCTAssertTrue(status.message.contains("unclear"))
    }

    func testMorningAndEveningAreIndependent() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.medicine, entity: "medicine"), in: repository)
        let morning = try await repository.medicineLogStatus(for: .morning, on: today, calendar: calendar)
        let evening = try await repository.medicineLogStatus(for: .evening, on: today, calendar: calendar)
        XCTAssertTrue(morning.hasLog)
        XCTAssertFalse(evening.hasLog)
        XCTAssertEqual(MedicineLogWindow.morning.reminderHour, 9)
        XCTAssertEqual(MedicineLogWindow.evening.reminderHour, 21)
    }

    func testDSTDayWindowsUseCalendarNot86400Seconds() {
        let fallBack = date("2026-11-01T12:00:00-08:00")
        let morning = MedicineLogWindow.morning.interval(on: fallBack, calendar: calendar)
        let evening = MedicineLogWindow.evening.interval(on: fallBack, calendar: calendar)
        XCTAssertEqual(morning.duration + evening.duration, 25 * 3_600)
        XCTAssertEqual(morning.end, evening.start)
    }

    func testTranscriptReplacementAndSourceDeletion() async throws {
        let repository = try ActivityRepository(directory: directory())
        let first = ActivityTranscript(videoID: "v1", chunkID: "c1", text: "Our appointment is Tuesday.", occurredAt: today, startSeconds: 0, endSeconds: 20)
        try await repository.saveTranscript(first)
        let revised = ActivityTranscript(videoID: "v1", chunkID: "c1", text: "Our appointment is Wednesday.", occurredAt: today, startSeconds: 0, endSeconds: 20)
        try await repository.saveTranscript(revised)
        try await save(event(.conversation, entity: "conversation"), in: repository)
        let rows = try await repository.transcripts()
        XCTAssertEqual(rows, [revised])
        try await repository.deleteVideo(id: "v1")
        let events = try await repository.events()
        let transcripts = try await repository.transcripts()
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(transcripts.isEmpty)
    }

    func testTranscriptSearchIncludesSourceAndUncertainty() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await repository.saveTranscript(ActivityTranscript(videoID: "v1", chunkID: "c1", text: "Our appointment is Tuesday at two.", occurredAt: today, startSeconds: 0, endSeconds: 20))
        let answer = try await repository.answer(query: "What did we discuss about the appointment?", now: today, calendar: calendar)
        XCTAssertTrue(answer!.text.contains("Tuesday"))
        XCTAssertTrue(answer!.text.contains("Transcription may contain mistakes"))
        XCTAssertEqual(answer?.transcript?.videoID, "v1")
    }

    func testDeletionNeverPresentsRemainingOldSightingAsLiveState() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.placed), in: repository)
        try await save(event(.pickedUp, at: "2026-10-24T10:00:00-07:00", video: "v2"), in: repository)
        try await repository.deleteVideo(id: "v2")
        let answer = try await repository.answer(query: "Where are my keys?", now: today, calendar: calendar)
        XCTAssertTrue(answer!.text.lowercased().contains("last seen"))
        XCTAssertTrue(answer!.text.contains("in the saved videos"))
        XCTAssertFalse(answer!.text.contains("are on"))
    }

    func testDatabaseReopenKeepsEventsAndTranscript() async throws {
        let dir = try directory()
        let first = try ActivityRepository(directory: dir)
        let saved = event(.placed)
        try await save(saved, in: first)
        let transcript = ActivityTranscript(videoID: "v1", chunkID: "c1", text: "Bring the blue bag.", occurredAt: today, startSeconds: 0, endSeconds: 3)
        try await first.saveTranscript(transcript)
        let reopened = try ActivityRepository(directory: dir)
        let events = try await reopened.events()
        let transcripts = try await reopened.transcripts()
        XCTAssertEqual(events, [saved])
        XCTAssertEqual(transcripts, [transcript])
    }

    func testAmbiguousGenericEntityAsksWhichItem() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.placed, entity: "car keys"), in: repository)
        try await save(event(.placed, video: "v2", entity: "house keys"), in: repository)
        let answer = try await repository.answer(query: "Where are my keys?", now: today, calendar: calendar)
        XCTAssertTrue(answer!.text.contains("Which one"))
        let specific = try await repository.answer(query: "Where are my car keys?", now: today, calendar: calendar)
        XCTAssertEqual(specific?.event?.entity, "car keys")
    }

    func testConflictingSameTimeCannotInventOrder() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.placed), in: repository)
        try await save(event(.pickedUp, video: "v2"), in: repository)
        let answer = try await repository.answer(query: "Where are my keys?", now: today, calendar: calendar)
        XCTAssertTrue(answer!.text.contains("conflicting activities"))
    }

    func testUncertainNewerEventDoesNotFallBackToOldLocation() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.placed), in: repository)
        try await save(event(.pickedUp, at: "2026-10-24T10:00:00-07:00", video: "v2", uncertain: true), in: repository)
        let answer = try await repository.answer(query: "Where are my keys?", now: today, calendar: calendar)
        XCTAssertTrue(answer!.text.contains("unclear"))
        XCTAssertFalse(answer!.text.contains("kitchen table"))
    }

    func testGeneralQuestionsAndNegatedRequestsRemainForGemma() async throws {
        let repository = try ActivityRepository(directory: directory())
        for query in ["Hello", "Where is Paris?", "What is medicine?", "Don't find my keys, tell me a story", "Delete this conversation"] {
            let answer = try await repository.answer(query: query, now: today, calendar: calendar)
            XCTAssertNil(answer, query)
        }
    }

    func testYesterdayUsesOccurrenceDateAndReturnsHistory() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.placed, at: "2026-10-23T08:00:00-07:00"), in: repository)
        try await save(event(.pickedUp, video: "v2"), in: repository)
        let answer = try await repository.answer(query: "Where were my keys yesterday?", now: today, calendar: calendar)
        XCTAssertEqual(answer?.event?.kind, .placed)
        let day = try await repository.answer(query: "What did I do today?", now: today, calendar: calendar)
        XCTAssertTrue(day!.text.contains("picked_up"))
        XCTAssertFalse(day!.text.contains("placed"))
    }

    func testDeleteAllClearsBothStores() async throws {
        let repository = try ActivityRepository(directory: directory())
        try await save(event(.placed), in: repository)
        try await repository.saveTranscript(ActivityTranscript(videoID: "v1", chunkID: "c1", text: "hello", occurredAt: today, startSeconds: 0, endSeconds: 1))
        try await repository.deleteAll()
        let events = try await repository.events()
        let transcripts = try await repository.transcripts()
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(transcripts.isEmpty)
    }

    func testMedicineVideoQuestionUsesVideoLogStatus() async throws {
        let repository = try ActivityRepository(directory: directory())
        let answer = try await repository.answer(query: "Is there a medicine video this morning?", now: today, calendar: calendar)
        XCTAssertEqual(answer?.text, "No medicine-taking video has been logged this morning.")
    }

    func testMedicineCaptureAndUploadRemainActionRequests() async throws {
        let repository = try ActivityRepository(directory: directory())
        for query in ["Record a medicine video", "I want to record medicine taking", "Please upload my medicine video", "Start recording my medicine video", "Can you import a medicine video"] {
            let answer = try await repository.answer(query: query, now: today, calendar: calendar)
            XCTAssertNil(answer, query)
        }
    }

    func testCommonDayQuestionsUseTimelineFastPath() async throws {
        let repository = try ActivityRepository(directory: directory())
        for query in ["What have I done today?", "Show today's activities", "How was my day?", "Daily summary", "Yesterday"] {
            let answer = try await repository.answer(query: query, now: today, calendar: calendar)
            XCTAssertNotNil(answer, query)
            XCTAssertTrue(answer!.text.contains("No activities"), query)
        }
    }

    func testFutureMedicineRecordingDoesNotProduceCurrentLogStatus() async throws {
        let repository = try ActivityRepository(directory: directory())
        var future = event(.medicine, at: "2026-10-24T08:30:00-07:00", entity: "medicine")
        future.indexedAt = date("2026-10-24T07:30:00-07:00")
        try await save(future, in: repository)
        let status = try await repository.medicineLogStatus(for: .morning, on: today, calendar: calendar,
                                                          asOf: date("2026-10-24T08:00:00-07:00"))
        XCTAssertFalse(status.hasLog)
        XCTAssertTrue(status.events.isEmpty)
    }

    func testDemoQuestionsBypassDailyShortcutAndSelectTheirVideoEvidence() async throws {
        let repository = try ActivityRepository(directory: directory())
        var first = event(.other, at: nil, video: "demo-one", entity: "book")
        first.summary = "Demo footage (Demo clip 1): A person opens a book."
        var second = event(.other, at: nil, video: "demo-two", entity: "cup")
        second.summary = "Demo footage (Demo clip 2): A person lifts a cup."
        second.isDemo = true
        var personal = event(.other, video: "personal", entity: "book")
        personal.summary = "A person closes a book."
        for value in [first, second, personal] { try await save(value, in: repository) }

        for query in ["What happened in a demo video?", "What happened in demo clip one?", "What activity happened in the saved videos?"] {
            let immediate = try await repository.answer(query: query, now: today, calendar: calendar)
            XCTAssertNil(immediate, "The query should use evidence synthesis rather than today's log: \(query)")
        }
        let allDemos = try await repository.relevantContext(query: "What happened in a demo video?")
        XCTAssertTrue(allDemos.contains("opens a book"))
        XCTAssertTrue(allDemos.contains("lifts a cup"))
        XCTAssertFalse(allDemos.contains("closes a book"))
        for query in ["What happened in demo clip 1?", "What did they do in demo video one?"] {
            let firstOnly = try await repository.relevantContext(query: query)
            XCTAssertTrue(firstOnly.contains("opens a book"), query)
            XCTAssertFalse(firstOnly.contains("lifts a cup"), query)
            XCTAssertFalse(firstOnly.contains("closes a book"), query)
        }
        let missing = try await repository.relevantContext(query: "What happened in demo clip three?")
        XCTAssertTrue(missing.isEmpty)
    }

    func testDemoObjectsNeverPollutePersonalLocationOrPersonalEvidence() async throws {
        let repository = try ActivityRepository(directory: directory())
        let personal = event(.placed)
        var demo = event(.pickedUp, at: nil, video: "demo", entity: "house keys")
        demo.summary = "Demo footage (Demo clip 1): House keys were picked up."
        try await save(personal, in: repository)
        try await save(demo, in: repository)
        let answer = try await repository.answer(query: "Where are my keys?", now: today, calendar: calendar)
        XCTAssertEqual(answer?.event?.videoID, personal.videoID)
        XCTAssertTrue(answer!.text.contains("kitchen table"))
        XCTAssertFalse(answer!.text.contains("Which one"))
        XCTAssertFalse(answer!.text.contains("unknown recording dates"))

        let personalContext = try await repository.relevantContext(query: "Did I pick up the keys?")
        XCTAssertTrue(personalContext.contains("kitchen table"))
        XCTAssertFalse(personalContext.contains("Demo footage"))
        try await repository.deleteVideo(id: personal.videoID)
        let demoOnly = try await repository.answer(query: "Where are my keys?", now: today, calendar: calendar)
        XCTAssertNil(demoOnly?.event)
        XCTAssertTrue(demoOnly!.text.contains("don't have a matching object activity"))
    }

    func testPhoneQueriesFindSmartphoneInSummaryWhenEntityIsHand() async throws {
        let repository = try ActivityRepository(directory: directory())
        var phone = event(.other, at: nil, video: "demo-six", entity: "hand")
        phone.isDemo = true
        phone.summary = "Demo footage (Demo clip 6): The hand is visible near the smartphone, which is still on the table."
        try await save(phone, in: repository)
        for query in ["What happened to the phone in the demo?", "Where is the phone in demo clip 6?",
                      "What happened to the smartphone in the demo?"] {
            let context = try await repository.relevantContext(query: query)
            XCTAssertTrue(context.contains(phone.summary), query)
        }
        let personal = try await repository.relevantContext(query: "Where is my phone?")
        XCTAssertTrue(personal.isEmpty)
    }

    func testVisualNoteRetainsFinalOutcomeSentenceInAnswerContext() async throws {
        let repository = try ActivityRepository(directory: directory())
        var note = event(.other, at: nil, video: "demo-five", entity: "Unclassified video segment", uncertain: true)
        note.id += ":unstructured"
        note.isDemo = true
        note.confidence = 0
        note.summary = "Demo footage (Demo clip 5): In the first few seconds, the individual is shown with their eyes closed. Around the 1.14 to 3.46 second marks, the individual is handling a pair of eyeglasses, bringing them toward their face. By the final frames, the eyeglasses are positioned on the individual's face."
        XCTAssertGreaterThan(note.summary.count, 250)
        try await save(note, in: repository)
        for query in ["Describe demo clip 5", "Where are the glasses in the demo?"] {
            let context = try await repository.relevantContext(query: query)
            XCTAssertTrue(context.contains(note.summary), query)
            XCTAssertTrue(context.contains("uncertain"))
        }
    }

    func testContextBudgetIncludesWholeNotesWithoutClippingTheirOutcome() async throws {
        let repository = try ActivityRepository(directory: directory())
        var notes: [ActivityEvent] = []
        for index in 1...5 {
            var note = event(.other, at: nil, video: "long-demo-\(index)", entity: "Unclassified video segment", uncertain: true)
            note.id += ":unstructured"
            note.isDemo = true
            note.summary = "Demo footage (Demo clip \(index)): " + String(repeating: "A person handles an object in the room. ", count: 70)
                + "The final outcome for clip \(index) is visible."
            XCTAssertLessThanOrEqual(note.summary.count, 3_000)
            try await save(note, in: repository)
            notes.append(note)
        }
        let context = try await repository.relevantContext(query: "Describe the demo footage", limit: 10)
        XCTAssertLessThanOrEqual(context.count, 6_000)
        XCTAssertFalse(context.isEmpty)
        var included = 0
        for note in notes where context.contains("VIDEO EVENT [\(note.videoID),") {
            XCTAssertTrue(context.contains(note.summary))
            included += 1
        }
        XCTAssertGreaterThan(included, 0)
        XCTAssertLessThan(included, notes.count)
    }

    func testDemoClassificationSurvivesReloadAndNeverEntersDailyOrMedicineLogs() async throws {
        let dir = try directory()
        let repository = try ActivityRepository(directory: dir)
        // Even an incorrectly dated caller must not make sample footage a personal medicine log.
        var demo = event(.medicine, video: "demo", entity: "medicine")
        demo.isDemo = true
        demo.summary = "A person handles a medicine container."
        try await save(demo, in: repository)
        let reopened = try ActivityRepository(directory: dir)
        let events = try await reopened.events()
        XCTAssertEqual(events.first?.isDemo, true)
        let daily = try await reopened.events(on: today, calendar: calendar)
        let medicine = try await reopened.medicineLogStatus(for: .morning, on: today, calendar: calendar)
        XCTAssertTrue(daily.isEmpty)
        XCTAssertFalse(medicine.hasLog)
        let all = try await reopened.answer(query: "Show all history", now: today, calendar: calendar)
        XCTAssertTrue(all!.text.contains("Demo footage:"))
        let demoContext = try await reopened.relevantContext(query: "Describe the demo footage")
        XCTAssertTrue(demoContext.contains("Demo footage:"))
    }

    func testLegacyEventsDecodeWithoutDemoFlag() throws {
        let original = event(.placed)
        let data = try JSONEncoder().encode(original)
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        value.removeValue(forKey: "isDemo")
        value.removeValue(forKey: "source")
        let legacy = try JSONDecoder().decode(ActivityEvent.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertNil(legacy.isDemo)
        XCTAssertFalse(legacy.isDemoFootage)
        XCTAssertNil(legacy.source)
        XCTAssertFalse(legacy.isUserConfirmed)
    }

    func testConfirmedObjectSurvivesModelReanalysisAndCreditsItsSource() async throws {
        let dir = try directory()
        let repository = try ActivityRepository(directory: dir)
        var confirmed = event(.placed, location: "on the windowsill")
        confirmed.source = .userConfirmed
        confirmed.summary = "Keys were placed on the windowsill."
        try await save(confirmed, in: repository)

        var collision = confirmed
        collision.source = .model
        collision.entity = "small object"
        collision.location = "beside a chair"
        collision.summary = "A small object was beside a chair."
        let model = event(.other, entity: "person", location: "near the window")
        try await repository.replaceSegment(videoID: confirmed.videoID, segmentID: confirmed.segmentID, events: [collision, model])
        var rows = try await repository.events()
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.id == confirmed.id }), confirmed)
        XCTAssertTrue(rows.contains(where: { $0.id == model.id }))

        // An empty model extraction removes model observations, not the user's correction.
        try await repository.replaceSegment(videoID: confirmed.videoID, segmentID: confirmed.segmentID, events: [])
        let reopened = try ActivityRepository(directory: dir)
        rows = try await reopened.events()
        XCTAssertEqual(rows, [confirmed])
        let answer = try await reopened.answer(query: "Where are my keys?", now: today, calendar: calendar)
        XCTAssertEqual(answer?.event?.source, .userConfirmed)
        XCTAssertTrue(answer!.text.contains("on the windowsill"))
        XCTAssertTrue(answer!.text.contains("You confirmed the object label and activity"))
        XCTAssertTrue(answer!.text.contains("location was observed in the video"))
        let context = try await reopened.relevantContext(query: "What do the saved videos show about keys?")
        XCTAssertTrue(context.contains("User-confirmed object and activity:"))

        // Explicit source deletion still removes every kind of annotation.
        try await reopened.deleteVideo(id: confirmed.videoID)
        let afterDelete = try await reopened.events()
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testExplicitConfirmationCanReviseConfirmedRowWithoutDuplicate() async throws {
        let repository = try ActivityRepository(directory: directory())
        var confirmed = event(.placed)
        confirmed.source = .userConfirmed
        try await save(confirmed, in: repository)
        var correction = confirmed
        correction.location = "on the windowsill"
        correction.summary = "Keys were placed on the windowsill."
        try await save(correction, in: repository)
        let rows = try await repository.events()
        XCTAssertEqual(rows, [correction])
    }

    func testLaterModelPickupStillUpdatesUserConfirmedObjectState() async throws {
        let repository = try ActivityRepository(directory: directory())
        var confirmed = event(.placed, location: "on the windowsill")
        confirmed.source = .userConfirmed
        try await save(confirmed, in: repository)
        var pickup = event(.pickedUp, at: "2026-10-24T09:20:00-07:00", video: "later")
        pickup.source = .model
        try await save(pickup, in: repository)
        let answer = try await repository.answer(query: "Where are my keys?", now: today, calendar: calendar)
        XCTAssertEqual(answer?.event?.id, pickup.id)
        XCTAssertTrue(answer!.text.contains("picked up"))
        XCTAssertTrue(answer!.text.contains("haven't seen where"))
        XCTAssertFalse(answer!.text.contains("windowsill"))
        XCTAssertFalse(answer!.text.contains("You confirmed"))
    }
}
