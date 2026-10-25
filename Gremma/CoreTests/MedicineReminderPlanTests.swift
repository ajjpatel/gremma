import XCTest
@testable import ReminderValidation

final class MedicineReminderPlanTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return result
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var eightAM: Date { date("2026-10-24T08:00:00-07:00") }
    private func event(at time: Date?, indexedAt: Date? = nil, uncertain: Bool = false, confidence: Double = 0.9, kind: ActivityKind = .medicine) -> ActivityEvent {
        ActivityEvent(videoID: UUID().uuidString, segmentID: "s1", kind: kind, entity: "medicine",
                      summary: "Medicine-related activity", occurredAt: time,
                      indexedAt: indexedAt ?? eightAM.addingTimeInterval(-1), startSeconds: 0, endSeconds: 4,
                      confidence: confidence, isUncertain: uncertain)
    }

    func testNoLogsSchedulesSevenDatedNineAMAndNinePMChecks() {
        let requests = MedicineReminderPlan.make(events: [], now: eightAM, calendar: calendar)
        XCTAssertEqual(requests.count, 14)
        XCTAssertEqual(Set(requests.map(\.id)).count, 14)
        XCTAssertEqual(requests.first?.fireDate, date("2026-10-24T09:00:00-07:00"))
        XCTAssertEqual(requests.last?.fireDate, date("2026-10-30T21:00:00-07:00"))
        XCTAssertTrue(requests.allSatisfy { [9, 21].contains(calendar.component(.hour, from: $0.fireDate)) })
        XCTAssertTrue(requests.allSatisfy { calendar.component(.minute, from: $0.fireDate) == 0 })
    }

    func testAfterDueNeverSchedulesPastOrImmediateCatchup() {
        let now = date("2026-10-24T10:00:00-07:00")
        let requests = MedicineReminderPlan.make(events: [], now: now, calendar: calendar)
        XCTAssertEqual(requests.count, 13)
        XCTAssertEqual(requests.first?.fireDate, date("2026-10-24T21:00:00-07:00"))
        XCTAssertTrue(requests.allSatisfy { $0.fireDate > now })
    }

    func testExactlyAtDueTimeDoesNotCreateAlreadyDueRequest() {
        let now = date("2026-10-24T09:00:00-07:00")
        let requests = MedicineReminderPlan.make(events: [], now: now, calendar: calendar)
        XCTAssertEqual(requests.first?.window, .evening)
        XCTAssertEqual(requests.count, 13)
    }

    func testClearMorningVideoSuppressesOnlyTodaysMorningCheck() {
        let recorded = event(at: date("2026-10-24T07:30:00-07:00"))
        let requests = MedicineReminderPlan.make(events: [recorded], now: eightAM, calendar: calendar)
        XCTAssertEqual(requests.count, 13)
        XCTAssertEqual(requests.first?.fireDate, date("2026-10-24T21:00:00-07:00"))
        XCTAssertTrue(requests.contains { $0.fireDate == date("2026-10-25T09:00:00-07:00") })
    }

    func testClearEveningLogDoesNotSuppressNextMorning() {
        let now = date("2026-10-24T20:00:00-07:00")
        let recorded = event(at: date("2026-10-24T19:30:00-07:00"))
        let requests = MedicineReminderPlan.make(events: [recorded], now: now, calendar: calendar)
        XCTAssertEqual(requests.count, 12)
        XCTAssertEqual(requests.first?.fireDate, date("2026-10-25T09:00:00-07:00"))
    }

    func testUnknownRecordingDateCannotSuppress() {
        let requests = MedicineReminderPlan.make(events: [event(at: nil)], now: eightAM, calendar: calendar)
        XCTAssertEqual(requests.count, 14)
        XCTAssertTrue(requests.first!.body.contains("No medicine-taking video"))
    }

    func testDatedDemoFootageCannotChangePersonalMorningOrEveningReminders() {
        for now in [eightAM, date("2026-10-24T20:00:00-07:00")] {
            let baseline = MedicineReminderPlan.make(events: [], now: now, calendar: calendar)
            for uncertain in [false, true] {
                var demo = event(at: now.addingTimeInterval(-60), indexedAt: now.addingTimeInterval(-1), uncertain: uncertain)
                demo.isDemo = true
                XCTAssertEqual(MedicineReminderPlan.make(events: [demo], now: now, calendar: calendar), baseline)
                // Older imports identify their source through the preserved prefix.
                demo.isDemo = nil
                demo.summary = "Demo footage (sample video): Medicine-related activity"
                XCTAssertTrue(demo.isDemoFootage)
                XCTAssertEqual(MedicineReminderPlan.make(events: [demo], now: now, calendar: calendar), baseline)
            }
        }
    }

    func testFutureOccurrenceTodayAndTomorrowCannotSuppress() {
        let events = [event(at: date("2026-10-24T08:30:00-07:00")), event(at: date("2026-10-25T07:00:00-07:00"))]
        let requests = MedicineReminderPlan.make(events: events, now: eightAM, calendar: calendar)
        XCTAssertEqual(requests.count, 14)
    }

    func testFutureIndexTimestampCannotSuppress() {
        let recorded = event(at: date("2026-10-24T07:00:00-07:00"), indexedAt: eightAM.addingTimeInterval(60))
        let requests = MedicineReminderPlan.make(events: [recorded], now: eightAM, calendar: calendar)
        XCTAssertEqual(requests.count, 14)
    }

    func testUncertainOrLowConfidenceVideoChangesWordingButNotSchedule() {
        for recorded in [event(at: eightAM.addingTimeInterval(-60), uncertain: true), event(at: eightAM.addingTimeInterval(-60), confidence: 0.4)] {
            let requests = MedicineReminderPlan.make(events: [recorded], now: eightAM, calendar: calendar)
            XCTAssertEqual(requests.count, 14)
            XCTAssertTrue(requests.first!.body.contains("No clear medicine-taking video"))
            XCTAssertTrue(requests[1].body.contains("No medicine-taking video"))
        }
    }

    func testDeletionRestoresOnlyTheRelevantCheck() {
        let recorded = event(at: eightAM.addingTimeInterval(-60))
        let before = MedicineReminderPlan.make(events: [recorded], now: eightAM, calendar: calendar)
        let after = MedicineReminderPlan.make(events: [], now: eightAM, calendar: calendar)
        XCTAssertEqual(Set(after.map(\.id)).subtracting(before.map(\.id)).count, 1)
        XCTAssertEqual(after.first?.window, .morning)
        XCTAssertTrue(Set(before.map(\.id)).isSubset(of: Set(after.map(\.id))))
    }

    func testNoonBoundaryBelongsOnlyToEvening() {
        let now = date("2026-10-24T12:05:00-07:00")
        let noon = event(at: date("2026-10-24T12:00:00-07:00"))
        let requests = MedicineReminderPlan.make(events: [noon], now: now, calendar: calendar)
        XCTAssertEqual(requests.first?.fireDate, date("2026-10-25T09:00:00-07:00"))
    }

    func testFallBackPreservesNineAMAcrossTwentyFiveHourDay() {
        let now = date("2026-10-31T08:00:00-07:00")
        let requests = MedicineReminderPlan.make(events: [], now: now, calendar: calendar)
        let mornings = requests.filter { $0.window == .morning }
        XCTAssertEqual(mornings[1].fireDate, date("2026-11-01T09:00:00-08:00"))
        XCTAssertEqual(mornings[1].fireDate.timeIntervalSince(mornings[0].fireDate), 25 * 3_600)
        XCTAssertTrue(mornings.allSatisfy { calendar.component(.hour, from: $0.fireDate) == 9 })
    }

    func testSpringForwardPreservesNineAMAcrossTwentyThreeHourDay() {
        let now = date("2026-03-07T08:00:00-08:00")
        let requests = MedicineReminderPlan.make(events: [], now: now, calendar: calendar)
        let mornings = requests.filter { $0.window == .morning }
        XCTAssertEqual(mornings[1].fireDate, date("2026-03-08T09:00:00-07:00"))
        XCTAssertEqual(mornings[1].fireDate.timeIntervalSince(mornings[0].fireDate), 23 * 3_600)
    }

    func testProvidedTimezoneDeterminesDatesAndTriggerComponents() {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = date("2026-10-25T08:00:00+09:00")
        let requests = MedicineReminderPlan.make(events: [], now: now, calendar: tokyo)
        XCTAssertEqual(requests.first?.fireDate, date("2026-10-25T09:00:00+09:00"))
        XCTAssertEqual(requests.first?.dateComponents.timeZone, tokyo.timeZone)
        XCTAssertEqual(requests.first?.dateComponents.day, 25)
        XCTAssertEqual(tokyo.date(from: requests.first!.dateComponents), requests.first?.fireDate)
    }

    func testDuplicateVideosDoNotAffectOtherWindows() {
        let recorded = event(at: eightAM.addingTimeInterval(-60))
        let once = MedicineReminderPlan.make(events: [recorded], now: eightAM, calendar: calendar)
        let twice = MedicineReminderPlan.make(events: [recorded, recorded], now: eightAM, calendar: calendar)
        XCTAssertEqual(once, twice)
    }

    func testOtherActivitiesCannotSuppressMedicineCheck() {
        let recorded = event(at: eightAM.addingTimeInterval(-60), kind: .conversation)
        let requests = MedicineReminderPlan.make(events: [recorded], now: eightAM, calendar: calendar)
        XCTAssertEqual(requests.count, 14)
    }

    func testNotificationNeverAssertsMissedOrTakenDose() {
        let requests = MedicineReminderPlan.make(events: [], now: eightAM, calendar: calendar)
        XCTAssertTrue(requests.allSatisfy { $0.body.contains("video") && $0.body.contains("logged") })
        XCTAssertFalse(requests.contains { $0.body.lowercased().contains("missed") || $0.body.lowercased().contains("dose") || $0.body.lowercased().contains("take your") })
    }

    func testHorizonIsBoundedToSevenDays() {
        XCTAssertEqual(MedicineReminderPlan.make(events: [], now: eightAM, calendar: calendar, days: 100).count, 14)
        XCTAssertTrue(MedicineReminderPlan.make(events: [], now: eightAM, calendar: calendar, days: 0).isEmpty)
        XCTAssertTrue(MedicineReminderPlan.make(events: [], now: eightAM, calendar: calendar, days: -1).isEmpty)
    }
}
