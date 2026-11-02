import EventKit
import Foundation
import TagwerkCore
import UserNotifications

/// Local notifications: the push channel that a Markdown note cannot be.
enum Notifier {
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func isAuthorized() async -> Bool {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        return s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
    }

    private static func components(day: String, minutes: Int) -> DateComponents? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var c = DateComponents()
        c.year = p[0]
        c.month = p[1]
        c.day = p[2]
        c.hour = minutes / 60
        c.minute = minutes % 60
        return c
    }

    static func reschedule(state: AppState, overdue: Int) async {
        let center = UNUserNotificationCenter.current()
        guard await isAuthorized() else { return }
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("tw.") })

        let now = Date()
        let today = DayKey.today(now)
        var requests: [UNNotificationRequest] = []

        if state.settings.dailyReminder {
            for offset in 0..<7 {
                let key = DayKey.adding(offset, to: today)
                if offset == 0, state.days[key]?.hasContent == true { continue }
                guard let comps = components(day: key, minutes: state.settings.dailyReminderMinutes),
                      let fire = Calendar.current.date(from: comps), fire > now else { continue }
                let content = UNMutableNotificationContent()
                content.title = "Wie war dein Tag?"
                content.body = "Gewohnheiten abhaken und zwei Sätze schreiben. Die Bewertung übernimmt die KI, du kannst sie ändern."
                content.sound = .default
                content.threadIdentifier = "tagwerk.daily"
                requests.append(UNNotificationRequest(identifier: "tw.daily.\(key)", content: content,
                                                      trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
        }

        let horizon = DayKey.adding(45, to: today)
        for t in state.tasks where !t.completed {
            guard let due = t.date, due >= today, due <= horizon else { continue }
            if let comps = components(day: due, minutes: state.settings.taskReminderMinutes), let fire = Calendar.current.date(from: comps), fire > now {
                let content = UNMutableNotificationContent()
                content.title = t.wichtig ? "Heute fällig, wichtig" : "Heute fällig"
                content.body = t.title
                content.sound = .default
                content.threadIdentifier = "tagwerk.tasks"
                requests.append(UNNotificationRequest(identifier: "tw.task.\(t.id)", content: content,
                                                      trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
            if t.wichtig, let comps = components(day: DayKey.adding(-1, to: due), minutes: 18 * 60), let fire = Calendar.current.date(from: comps), fire > now {
                let content = UNMutableNotificationContent()
                content.title = "Morgen fällig"
                content.body = t.title
                content.threadIdentifier = "tagwerk.tasks"
                requests.append(UNNotificationRequest(identifier: "tw.task.eve.\(t.id)", content: content,
                                                      trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
            }
        }

        for r in requests.prefix(60) { try? await center.add(r) }
        try? await center.setBadgeCount(overdue)
    }
}

/// Writes accepted appointments into a calendar of the user's choice (e.g. the iCloud calendar "Termine").
@MainActor
final class CalendarService {
    static let shared = CalendarService()
    let store = EKEventStore()

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess() async -> Bool {
        if hasAccess { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    func calendars() -> [EKCalendar] {
        guard hasAccess else { return [] }
        return store.calendars(for: .event).filter { $0.allowsContentModifications }.sorted { $0.title < $1.title }
    }

    func add(_ a: Appointment, calendarIdentifier: String?) async -> String? {
        guard await requestAccess() else { return nil }
        let event = EKEvent(eventStore: store)
        event.title = a.title
        event.location = a.location
        var notes: [String] = []
        if let subject = a.subject { notes.append("Aus E-Mail: \(subject)") }
        if let from = a.from, !from.isEmpty { notes.append("Von: \(from)") }
        event.notes = notes.isEmpty ? nil : notes.joined(separator: "\n")
        event.calendar = calendarIdentifier.flatMap { store.calendar(withIdentifier: $0) } ?? store.defaultCalendarForNewEvents
        guard let dayStart = DayKey.date(a.date) else { return nil }
        if a.allDay || a.startTime == nil {
            event.isAllDay = true
            event.startDate = dayStart
            event.endDate = dayStart.addingTimeInterval(86_400)
        } else {
            func at(_ hhmm: String) -> Date? {
                let p = hhmm.split(separator: ":").compactMap { Int($0) }
                guard p.count == 2 else { return nil }
                return Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: dayStart)
            }
            let start = a.startTime.flatMap(at) ?? dayStart
            event.startDate = start
            event.endDate = a.endTime.flatMap(at).flatMap { $0 > start ? $0 : nil } ?? start.addingTimeInterval(3600)
        }
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier
        } catch {
            return nil
        }
    }
}
