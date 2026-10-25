import Foundation

struct MedicineReminderRequest: Identifiable, Equatable, Sendable {
    let id: String
    let fireDate: Date
    let window: MedicineLogWindow
    let body: String
    let dateComponents: DateComponents
}

/// A deterministic schedule based solely on video evidence available when the plan is made.
/// Rebuild after adding/deleting evidence and on app foreground/timezone changes.
enum MedicineReminderPlan {
    static let identifierPrefix = "gremma.medicine-log."

    static func make(events: [ActivityEvent], now: Date = Date(), calendar: Calendar = .current,
                     days: Int = 7) -> [MedicineReminderRequest] {
        guard now.timeIntervalSince1970.isFinite else { return [] }
        let knownMedicineEvents = events.filter { event in
            guard event.kind == .medicine, !event.isDemoFootage, let occurred = event.occurredAt,
                  occurred.timeIntervalSince1970.isFinite, occurred <= now,
                  event.indexedAt.timeIntervalSince1970.isFinite, event.indexedAt <= now else { return false }
            return true
        }
        var requests: [MedicineReminderRequest] = []
        let start = calendar.startOfDay(for: now)
        for offset in 0..<max(0, min(days, 7)) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            for window in MedicineLogWindow.allCases {
                let fireDate = window.reminderDate(on: day, calendar: calendar)
                guard fireDate > now else { continue }
                let interval = window.interval(on: day, calendar: calendar)
                let matching = knownMedicineEvents.filter {
                    guard let date = $0.occurredAt else { return false }
                    return date >= interval.start && date < interval.end
                }
                guard !matching.contains(where: \.hasClearEvidence) else { continue }
                let qualifier = matching.isEmpty ? "" : "clear "
                let body = "No \(qualifier)medicine-taking video has been logged this \(window.rawValue). Open Gremma to add or review a video."
                var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                // Explicit timezone preserves the intended local wall-clock time in this plan.
                // Foreground reconciliation rebuilds the horizon after a timezone change.
                components.timeZone = calendar.timeZone
                components.calendar = calendar
                let identifier = identifierPrefix + String(Int64(fireDate.timeIntervalSince1970))
                requests.append(MedicineReminderRequest(id: identifier, fireDate: fireDate, window: window,
                                                       body: body, dateComponents: components))
            }
        }
        return requests.sorted { $0.fireDate < $1.fireDate }
    }
}
