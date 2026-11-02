import Foundation

/// An appointment as the planner needs it (from the vault or created in the app).
public struct PlannerAppointment: Hashable, Sendable {
    public var id: String
    public var title: String
    public var date: String
    public var startTime: String?
    public var endTime: String?
    public var allDay: Bool
    public var location: String?
    public var category: String?
    public var subject: String?
    public var recur: Recurrence?
    public var notes: String?
    public var pending: Bool

    public init(id: String, title: String, date: String, startTime: String?, endTime: String?, allDay: Bool, location: String? = nil,
                category: String? = nil, subject: String? = nil, recur: Recurrence? = nil, notes: String? = nil, pending: Bool = false) {
        self.id = id
        self.title = title
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.allDay = allDay
        self.location = location
        self.category = category
        self.subject = subject
        self.recur = recur
        self.notes = notes
        self.pending = pending
    }
}

/// A date found in a mail or WebUntis message, not yet accepted.
public struct PlannerSuggestion: Hashable, Sendable {
    public var id: String
    public var title: String
    public var date: String
    public var startTime: String?
    public var endTime: String?
    public var allDay: Bool
    public var location: String?
    public var mailbox: String

    public init(id: String, title: String, date: String, startTime: String?, endTime: String?, allDay: Bool, location: String?, mailbox: String) {
        self.id = id
        self.title = title
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.allDay = allDay
        self.location = location
        self.mailbox = mailbox
    }
}

public struct PlannerEntry: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case lesson, exam, event, appointment, uni, klausur, suggestion, holiday
    }

    public enum Mark: Hashable, Sendable {
        case none
        case changed
        case cancelledBySchool
        case cancelledByMe
        case absent(String)
        /// A university appointment overlaps the lesson.
        case uni(String)
        /// Attends although a university appointment overlaps.
        case present
    }

    public var id: String
    public var date: String
    /// Minutes since midnight; nil for all-day entries.
    public var start: Int?
    public var end: Int?
    public var kind: Kind
    public var title: String
    public var short: String?
    public var detail: String?
    public var info: String?
    public var colorHex: String?
    public var mark: Mark
    public var overrideKey: String?
    public var appointmentID: String?
    public var suggestionID: String?
    public var period: UntisPeriod?
    public var appointment: PlannerAppointment?

    public var isAllDay: Bool { start == nil }

    /// The user is not in this lesson (cancelled, absent or at university).
    public var isOff: Bool {
        switch mark {
        case .cancelledBySchool, .cancelledByMe, .absent, .uni: return true
        default: return false
        }
    }

    public var isExam: Bool { kind == .exam || kind == .klausur }
}

public enum Planner {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func date(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }

    static func key(_ d: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func minutes(_ hhmm: String?) -> Int? {
        guard let s = hhmm, s.count >= 4 else { return nil }
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    public static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60 % 24, minutes % 60)
    }

    /// ISO weekday, 1 = Monday ... 7 = Sunday.
    public static func weekday(_ key: String) -> Int {
        guard let d = date(key) else { return 1 }
        let w = calendar.component(.weekday, from: d) // 1 = Sunday
        return w == 1 ? 7 : w - 1
    }

    public static func adding(_ days: Int, to key: String) -> String {
        guard let d = date(key), let r = calendar.date(byAdding: .day, value: days, to: d) else { return key }
        return Self.key(r)
    }

    public static func monday(of key: String) -> String { adding(1 - weekday(key), to: key) }

    public static func week(of key: String) -> [String] {
        let m = monday(of: key)
        return (0..<7).map { adding($0, to: m) }
    }

    public static func lessonKey(_ p: UntisPeriod) -> String { "u:\(p.date):\(p.start):\(p.subject ?? p.title ?? "-")" }

    public static func occurrenceKey(_ appointmentID: String, date: String) -> String { "a:\(appointmentID):\(date)" }

    public static func occurs(_ a: PlannerAppointment, on day: String) -> Bool {
        guard let r = a.recur else { return a.date == day }
        return day >= a.date && day <= r.until && r.days.contains(weekday(day))
    }

    /// Everything for one day: holidays, lessons with the school's and the user's marks, appointments, open suggestions.
    public static func entries(on day: String, periods: [UntisPeriod], appointments: [PlannerAppointment], suggestions: [PlannerSuggestion],
                               overrides: [String: SchoolOverride], holidays: [UntisHoliday]) -> [PlannerEntry] {
        var out: [PlannerEntry] = []
        for h in holidays where h.start <= day && day <= h.end {
            out.append(PlannerEntry(id: "h:\(day):\(h.name)", date: day, start: nil, end: nil, kind: .holiday, title: h.name, mark: .none))
        }

        let todays = appointments.filter { occurs($0, on: day) }
        let uni: [(Int, Int, String)] = todays.compactMap { a in
            guard a.category == "uni", !a.allDay, let s = minutes(a.startTime) else { return nil }
            let e = minutes(a.endTime) ?? s + 90
            return (s, max(e, s + 1), a.title)
        }

        for p in periods where p.date == day {
            var s = minutes(p.start)
            var e = minutes(p.end)
            if p.start == "00:00" && (e ?? 0) >= 23 * 60 + 50 {
                s = nil
                e = nil
            }
            let kind: PlannerEntry.Kind = p.kind == .exam ? .exam : p.kind == .event ? .event : .lesson
            var mark: PlannerEntry.Mark = p.status == .cancelled ? .cancelledBySchool : p.isChanged ? .changed : .none
            let key = lessonKey(p)
            if let o = overrides[key] {
                switch o.state {
                case "entfall": mark = .cancelledByMe
                case "abwesend": mark = .absent(o.reason ?? "nicht da")
                case "anwesend": mark = .present
                default: break
                }
            } else if mark != .cancelledBySchool, kind == .lesson, let s, let e, let u = uni.first(where: { $0.0 < e && s < $0.1 }) {
                mark = .uni(u.2)
            }
            let name = p.subjectLong ?? p.subject ?? p.title ?? "Unterricht"
            let title = kind == .exam ? "Klausur \(name)" : kind == .event ? (p.title ?? p.subjectLong ?? p.subject ?? "Veranstaltung") : name
            var detail: [String] = []
            if let t = p.teacher { detail.append(p.teacherOld.map { "\(t) statt \($0)" } ?? t) }
            else if let old = p.teacherOld { detail.append("ohne \(old)") }
            if let r = p.room { detail.append(p.roomOld.map { "\(r) statt \($0)" } ?? r) }
            out.append(PlannerEntry(id: key, date: day, start: s, end: e, kind: kind, title: title, short: p.subject,
                                    detail: detail.isEmpty ? nil : detail.joined(separator: " · "), info: p.info, colorHex: p.color, mark: mark,
                                    overrideKey: key, period: p))
        }

        for a in todays {
            let kind: PlannerEntry.Kind = a.category == "klausur" ? .klausur : a.category == "uni" ? .uni : .appointment
            let key = occurrenceKey(a.id, date: day)
            var mark: PlannerEntry.Mark = .none
            if let o = overrides[key], o.state == "entfall" || o.state == "abwesend" { mark = o.state == "entfall" ? .cancelledByMe : .absent(o.reason ?? "nicht da") }
            let s = a.allDay ? nil : minutes(a.startTime)
            let e = s.map { start in minutes(a.endTime).map { max($0, start + 5) } ?? start + 60 }
            var title = a.title
            if kind == .klausur, let sub = a.subject, !sub.isEmpty, !title.localizedCaseInsensitiveContains(sub) { title = "\(title) \(sub)" }
            out.append(PlannerEntry(id: key, date: day, start: s, end: e, kind: kind, title: title, short: a.subject, detail: a.location,
                                    info: a.notes, mark: mark, overrideKey: key, appointmentID: a.id, appointment: a))
        }

        for sg in suggestions where sg.date == day {
            let s = sg.allDay ? nil : minutes(sg.startTime)
            let e = s.map { start in minutes(sg.endTime).map { max($0, start + 5) } ?? start + 60 }
            out.append(PlannerEntry(id: "s:\(sg.id)", date: day, start: s, end: e, kind: .suggestion, title: sg.title, detail: sg.location,
                                    info: "Vorschlag aus \(sg.mailbox)", mark: .none, suggestionID: sg.id))
        }

        let order: [PlannerEntry.Kind: Int] = [.holiday: 0, .exam: 1, .klausur: 1, .event: 2, .lesson: 3, .uni: 4, .appointment: 5, .suggestion: 6]
        return out.sorted { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            if (a.start ?? 0) != (b.start ?? 0) { return (a.start ?? 0) < (b.start ?? 0) }
            return (order[a.kind] ?? 9) < (order[b.kind] ?? 9)
        }
    }

    /// Columns for overlapping timed entries: index and count per entry id.
    public static func columns(_ entries: [PlannerEntry]) -> [String: (index: Int, count: Int)] {
        let timed = entries.filter { !$0.isAllDay }.sorted { ($0.start ?? 0, $0.end ?? 0) < ($1.start ?? 0, $1.end ?? 0) }
        var result: [String: (index: Int, count: Int)] = [:]
        var cluster: [PlannerEntry] = []
        var clusterEnd = -1
        var colEnds: [Int] = []
        var assigned: [String: Int] = [:]
        func flush() {
            let count = max(1, colEnds.count)
            for e in cluster { result[e.id] = (assigned[e.id] ?? 0, count) }
            cluster = []
            colEnds = []
            assigned = [:]
        }
        for e in timed {
            let s = e.start ?? 0
            let en = max(e.end ?? s + 30, s + 1)
            if !cluster.isEmpty && s >= clusterEnd { flush() }
            if let free = colEnds.firstIndex(where: { $0 <= s }) {
                colEnds[free] = en
                assigned[e.id] = free
            } else {
                colEnds.append(en)
                assigned[e.id] = colEnds.count - 1
            }
            cluster.append(e)
            clusterEnd = max(clusterEnd, en)
        }
        flush()
        return result
    }
}
