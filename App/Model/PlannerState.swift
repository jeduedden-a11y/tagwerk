import Foundation
import TagwerkCore

/// What the app last loaded from WebUntis; kept so the planner works offline.
struct UntisCache: Codable, Hashable {
    /// Lessons, exams and events by day.
    var periods: [String: [UntisPeriod]] = [:]
    /// Monday of each loaded week -> time of loading.
    var weeksFetched: [String: Date] = [:]
    var school: UntisSchoolData?
    var schoolFetched: Date?
    var messages: [UntisMessage] = []
    /// Messages already searched for dates.
    var scanned: [Int] = []
    var lastFetch: Date?
    var lastError: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        periods = c.value(.periods, [:])
        weeksFetched = c.value(.weeksFetched, [:])
        school = c.optional(.school)
        schoolFetched = c.optional(.schoolFetched)
        messages = c.value(.messages, [])
        scanned = c.value(.scanned, [])
        lastFetch = c.optional(.lastFetch)
        lastError = c.optional(.lastError)
    }

    /// Replaces one week (Monday to Sunday) and drops weeks older than two months.
    mutating func setWeek(_ monday: String, _ list: [UntisPeriod], today: String) {
        let days = Set(Planner.week(of: monday))
        for d in days { periods[d] = nil }
        for (d, items) in Dictionary(grouping: list, by: \.date) where days.contains(d) { periods[d] = items }
        weeksFetched[monday] = Date()
        let cutoff = Planner.adding(-63, to: today)
        periods = periods.filter { $0.key >= cutoff }
        weeksFetched = weeksFetched.filter { $0.key >= cutoff }
    }

    var unreadMessages: Int { messages.filter { !$0.read }.count }

    /// Subjects of the timetable, long name first, for the exam form.
    var subjects: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for p in periods.values.joined() where p.kind == .lesson {
            guard let name = p.subjectLong ?? p.subject, !seen.contains(name) else { continue }
            seen.insert(name)
            out.append(name)
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Lesson numbers ("3.–4. Stunde") for a time span, from the school's time grid.
    func lessonNumbers(start: Int?, end: Int?) -> String? {
        guard let start, let end, let units = school?.units, !units.isEmpty else { return nil }
        let hit = units.filter { u in
            guard let s = Planner.minutes(u.start), let e = Planner.minutes(u.end) else { return false }
            return s >= start && e <= end
        }.map(\.number)
        guard let first = hit.min(), let last = hit.max() else { return nil }
        return first == last ? "\(first). Stunde" : "\(first).–\(last). Stunde"
    }
}

/// WebUntis sends local times without zone: "2026-11-02T08:46:00".
enum UntisDates {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
}

/// A new planner entry while it is being edited.
struct PlannerDraft: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Identifiable {
        case termin, uni, klausur
        var id: String { rawValue }
        var label: String {
            switch self {
            case .termin: return "Termin"
            case .uni: return "Uni"
            case .klausur: return "Klausur"
            }
        }
    }

    var id = UUID()
    var kind: Kind = .termin
    var title = ""
    var subject = ""
    var date = Date()
    var start = Date()
    var end = Date()
    var allDay = false
    var location = ""
    var notes = ""
    var weekly = false
    var weekdays: Set<Int> = []
    var until = Date()
}
