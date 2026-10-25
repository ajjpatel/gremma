import Combine
import Foundation
import UserNotifications

/// Notifications check video evidence, not whether a person took or missed a dose.
@MainActor
final class MedicineLogReminders: ObservableObject {
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "Gremma.medicineLogReminders")
    @Published private(set) var status = "Check for a morning video at 9 AM and an evening video at 9 PM."
    @Published private(set) var scheduledThrough: Date?
    private let center = UNUserNotificationCenter.current()
    private let preferenceKey = "Gremma.medicineLogReminders"
    private var revision = UUID()
    private var preferenceRevision = UUID()

    func setEnabled(_ value: Bool, events: [ActivityEvent]) async {
        let selection = UUID()
        preferenceRevision = selection
        if value {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                guard preferenceRevision == selection else { return }
                guard granted else {
                    await disableForPermission(message: "Allow notifications in iPhone Settings to receive video-log reminders.")
                    return
                }
            } catch {
                guard preferenceRevision == selection else { return }
                await disableForPermission(message: "Notification permission could not be checked. Try enabling reminders again.")
                return
            }
        }
        enabled = value
        UserDefaults.standard.set(value, forKey: preferenceKey)
        await reconcile(events: events)
    }

    func reconcile(events: [ActivityEvent], now: Date = Date(), calendar: Calendar = .current) async {
        let operation = UUID()
        revision = operation
        let pending = await center.pendingNotificationRequests()
        guard revision == operation else { return }
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(MedicineReminderPlan.identifierPrefix) })
        scheduledThrough = nil
        guard enabled else { status = "Video-log reminders are off."; return }
        let settings = await center.notificationSettings()
        guard revision == operation else { return }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            enabled = false
            UserDefaults.standard.set(false, forKey: preferenceKey)
            status = "Notifications are blocked in iPhone Settings."
            return
        }
        let plan = MedicineReminderPlan.make(events: events, now: now, calendar: calendar)
        var addedIdentifiers: [String] = []
        do {
            for request in plan {
                guard revision == operation else {
                    center.removePendingNotificationRequests(withIdentifiers: addedIdentifiers)
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = "Medicine video log"
                content.body = request.body
                content.sound = .default
                // Per-operation suffix lets a superseded in-flight add remove its own
                // request without accidentally removing the newer plan's same-time check.
                let identifier = request.id + "." + operation.uuidString
                try await center.add(UNNotificationRequest(identifier: identifier, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: request.dateComponents, repeats: false)))
                addedIdentifiers.append(identifier)
                guard revision == operation else {
                    center.removePendingNotificationRequests(withIdentifiers: addedIdentifiers)
                    return
                }
                scheduledThrough = request.fireDate
            }
            status = "9 AM · morning log check. 9 PM · evening log check. Open Gremma weekly to renew reminders."
        } catch {
            center.removePendingNotificationRequests(withIdentifiers: addedIdentifiers)
            guard revision == operation else { return }
            scheduledThrough = nil
            status = "Reminders could not be scheduled. Open Gremma and try again."
        }
    }

    private func disableForPermission(message: String) async {
        enabled = false
        UserDefaults.standard.set(false, forKey: preferenceKey)
        await reconcile(events: [])
        // A new enable operation may have happened during the permission cleanup.
        if !enabled { status = message }
    }
}
