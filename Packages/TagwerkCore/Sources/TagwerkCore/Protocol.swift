import Foundation

// Wire protocol, schema 1. Mirror of bridge/src/protocol.ts.
// Events are encode-only on this side (plain JSON objects built here);
// the snapshot is decoded with Codable.

public enum RatingSource: String, Codable, Sendable, Hashable {
    case ai, manual
}

public struct HabitConfig: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var label: String
    public var color: String
    public var perWeek: Double
    public var weight: Double
    public var toleranceDays: Int
    public var aliveDays: Int
    public var symbol: String

    public var id: String { key }

    public init(key: String, label: String, color: String, perWeek: Double, weight: Double, toleranceDays: Int, aliveDays: Int, symbol: String) {
        self.key = key
        self.label = label
        self.color = color
        self.perWeek = perWeek
        self.weight = weight
        self.toleranceDays = toleranceDays
        self.aliveDays = aliveDays
        self.symbol = symbol
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = (try? c.decode(String.self, forKey: .label)) ?? key
        color = (try? c.decode(String.self, forKey: .color)) ?? "#8E8E93"
        perWeek = (try? c.decode(Double.self, forKey: .perWeek)) ?? 3
        weight = (try? c.decode(Double.self, forKey: .weight)) ?? 1
        let tol = (try? c.decode(Double.self, forKey: .toleranceDays)) ?? 1
        toleranceDays = max(1, Int(tol.rounded()))
        let alive = (try? c.decode(Double.self, forKey: .aliveDays)) ?? 1
        aliveDays = max(1, Int(alive.rounded()))
        symbol = (try? c.decode(String.self, forKey: .symbol)) ?? "checkmark.circle"
    }

    /// Same order and values as the Habits Dashboard in the vault.
    public static let defaults: [HabitConfig] = [
        HabitConfig(key: "reading", label: "Lesen", color: "#7F77DD", perWeek: 3, weight: 1.0, toleranceDays: 1, aliveDays: 1, symbol: "book.fill"),
        HabitConfig(key: "writing", label: "Schreiben", color: "#D85A30", perWeek: 2, weight: 1.0, toleranceDays: 7, aliveDays: 6, symbol: "pencil.line"),
        HabitConfig(key: "gym", label: "Gym", color: "#2CC742", perWeek: 3, weight: 1.5, toleranceDays: 3, aliveDays: 2, symbol: "dumbbell.fill"),
        HabitConfig(key: "food", label: "Ernährung", color: "#EF9F27", perWeek: 7, weight: 0.5, toleranceDays: 1, aliveDays: 1, symbol: "fork.knife"),
        HabitConfig(key: "laufen", label: "Laufen", color: "#378ADD", perWeek: 1, weight: 1.0, toleranceDays: 7, aliveDays: 6, symbol: "figure.run"),
    ]
}

public struct SnapshotDay: Codable, Hashable, Sendable {
    public var date: String
    public var habits: [String: Bool]
    public var rating: String?
    public var ratingAI: String?
    public var ratingSource: RatingSource?
    public var ratingReason: String?
    public var weight: String?
    public var journal: String?
    public var journalHash: String
    public var note: String?
    /// False for days outside the plugin's text window: journal and note are omitted, not empty.
    public var hasText: Bool

    public init(date: String, habits: [String: Bool] = [:], rating: String? = nil, ratingAI: String? = nil, ratingSource: RatingSource? = nil,
                ratingReason: String? = nil, weight: String? = nil, journal: String? = nil, journalHash: String = "", note: String? = nil, hasText: Bool = true) {
        self.date = date
        self.habits = habits
        self.rating = rating
        self.ratingAI = ratingAI
        self.ratingSource = ratingSource
        self.ratingReason = ratingReason
        self.weight = weight
        self.journal = journal
        self.journalHash = journalHash
        self.note = note
        self.hasText = hasText
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        habits = (try? c.decode([String: Bool].self, forKey: .habits)) ?? [:]
        rating = try c.decodeIfPresent(String.self, forKey: .rating)
        ratingAI = try c.decodeIfPresent(String.self, forKey: .ratingAI)
        ratingSource = try? c.decodeIfPresent(RatingSource.self, forKey: .ratingSource)
        ratingReason = try c.decodeIfPresent(String.self, forKey: .ratingReason)
        weight = try c.decodeIfPresent(String.self, forKey: .weight)
        journal = try c.decodeIfPresent(String.self, forKey: .journal)
        journalHash = (try? c.decode(String.self, forKey: .journalHash)) ?? ""
        note = try c.decodeIfPresent(String.self, forKey: .note)
        hasText = (try? c.decode(Bool.self, forKey: .hasText)) ?? (journal != nil || note != nil)
    }
}

public struct SnapshotTask: Codable, Hashable, Sendable {
    public var path: String
    public var taskId: String?
    public var title: String
    public var created: String?
    public var date: String?
    public var completed: Bool
    public var wichtig: Bool
    public var notes: String?
}

/// Weekly on the given ISO weekdays (1 = Monday ... 7 = Sunday) until the given day.
public struct Recurrence: Codable, Hashable, Sendable {
    public var days: [Int]
    public var until: String

    public init(days: [Int], until: String) {
        self.days = days
        self.until = until
    }
}

public struct SnapshotAppointment: Codable, Hashable, Sendable {
    public var path: String
    public var apptId: String?
    public var title: String
    /// First occurrence for recurring notes.
    public var date: String
    public var startTime: String?
    public var endTime: String?
    public var allDay: Bool
    public var location: String?
    /// "klausur", "uni", "schule", "termin" (plugin 1.2), nil before.
    public var category: String?
    public var subject: String?
    public var recur: Recurrence?
    public var notes: String?
}

/// A lesson the user marked himself: "entfall", "abwesend" or "anwesend".
public struct SchoolOverride: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var date: String
    public var start: String
    public var end: String?
    public var subject: String?
    public var title: String?
    public var state: String
    public var reason: String?
    public var updated: String?

    public var id: String { key }

    public init(key: String, date: String, start: String, end: String?, subject: String?, title: String?, state: String, reason: String?, updated: String? = nil) {
        self.key = key
        self.date = date
        self.start = start
        self.end = end
        self.subject = subject
        self.title = title
        self.state = state
        self.reason = reason
        self.updated = updated
    }
}

public struct BridgeError: Codable, Hashable, Sendable {
    public var eventId: String
    public var at: String
    public var message: String
}

/// Targets stored with a food day, so the vault keeps what the day was measured against.
public struct DayTargets: Codable, Hashable, Sendable {
    public var kcal: Double
    public var protein: Double
    public var fat: Double
    public var carbs: Double
    public var fiber: Double?
    public var tolerance: Double?

    public init(kcal: Double, protein: Double, fat: Double, carbs: Double, fiber: Double? = nil, tolerance: Double? = nil) {
        self.kcal = kcal
        self.protein = protein
        self.fat = fat
        self.carbs = carbs
        self.fiber = fiber
        self.tolerance = tolerance
    }

    public init(_ t: NutritionTargets, tolerance: Double) {
        self.init(kcal: t.kcal.rounded(), protein: t.protein.rounded(), fat: t.fat.rounded(), carbs: t.carbs.rounded(), fiber: t.fiber, tolerance: tolerance)
    }
}

public struct SnapshotFoodDay: Codable, Hashable, Sendable {
    public var date: String
    public var path: String?
    public var entries: [FoodEntry]
    public var targets: DayTargets?
    public var met: Bool?

    public init(date: String, path: String? = nil, entries: [FoodEntry], targets: DayTargets? = nil, met: Bool? = nil) {
        self.date = date
        self.path = path
        self.entries = entries
        self.targets = targets
        self.met = met
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(String.self, forKey: .date)
        path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? nil
        entries = (try? c.decode([FoodEntry].self, forKey: .entries)) ?? []
        targets = (try? c.decodeIfPresent(DayTargets.self, forKey: .targets)) ?? nil
        met = (try? c.decodeIfPresent(Bool.self, forKey: .met)) ?? nil
    }
}

public struct Snapshot: Codable, Sendable {
    public var schema: Int
    public var generatedAt: String
    public var pluginVersion: String?
    public var habits: [HabitConfig]
    public var days: [SnapshotDay]
    public var tasks: [SnapshotTask]
    public var appointments: [SnapshotAppointment]
    public var applied: [String]
    public var errors: [BridgeError]
    public var lastIngestAt: String?
    /// Event families the plugin understands ("runs", "food", "profile"); empty for plugin 1.0.
    public var features: [String]
    public var runs: [RunRecord]
    public var foodDays: [SnapshotFoodDay]
    public var profile: BodyProfile?
    public var schoolOverrides: [SchoolOverride]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        generatedAt = (try? c.decode(String.self, forKey: .generatedAt)) ?? ""
        pluginVersion = try? c.decodeIfPresent(String.self, forKey: .pluginVersion)
        habits = (try? c.decode([HabitConfig].self, forKey: .habits)) ?? HabitConfig.defaults
        days = (try? c.decode([SnapshotDay].self, forKey: .days)) ?? []
        tasks = (try? c.decode([SnapshotTask].self, forKey: .tasks)) ?? []
        appointments = (try? c.decode([SnapshotAppointment].self, forKey: .appointments)) ?? []
        applied = (try? c.decode([String].self, forKey: .applied)) ?? []
        errors = (try? c.decode([BridgeError].self, forKey: .errors)) ?? []
        lastIngestAt = try? c.decodeIfPresent(String.self, forKey: .lastIngestAt)
        features = (try? c.decode([String].self, forKey: .features)) ?? []
        runs = (try? c.decode([RunRecord].self, forKey: .runs)) ?? []
        foodDays = (try? c.decode([SnapshotFoodDay].self, forKey: .foodDays)) ?? []
        profile = (try? c.decodeIfPresent(BodyProfile.self, forKey: .profile)) ?? nil
        schoolOverrides = (try? c.decode([SchoolOverride].self, forKey: .schoolOverrides)) ?? []
    }
}

/// A field in a patch: left alone, cleared (JSON null) or set.
public enum FieldUpdate<Value: Sendable>: Sendable {
    case unchanged
    case clear
    case set(Value)
}

/// One event as a JSON-ready dictionary plus its id.
public struct OutgoingEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var createdAt: Date
    /// UTF-8 JSON object, exactly what goes into the inbox batch.
    public var json: Data

    public init(id: String, createdAt: Date, json: Data) {
        self.id = id
        self.createdAt = createdAt
        self.json = json
    }

    private var object: [String: Any] {
        ((try? JSONSerialization.jsonObject(with: json)) as? [String: Any]) ?? [:]
    }

    public var type: String? { object["type"] as? String }

    /// Feature the plugin must announce before this event may be sent; nil for the base protocol.
    public var requiredFeature: String? {
        let o = object
        return Self.feature(for: o["type"] as? String ?? "", fields: o)
    }

    public static func feature(for type: String, fields: [String: Any] = [:]) -> String? {
        switch type {
        case "run.add", "run.patch": return "runs"
        case "food.day": return "food"
        case "profile.set": return "profile"
        case "appointment.patch", "school.override": return "planner"
        case "appointment.add":
            // An older plugin would write a weekly lecture as a single e-mail appointment.
            return fields["recur"] != nil || fields["category"] != nil || fields["subject"] != nil ? "planner" : nil
        default: return nil
        }
    }
}

public enum EventFactory {
    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private static func put<T: Sendable>(_ dict: inout [String: Any], _ key: String, _ update: FieldUpdate<T>) {
        switch update {
        case .unchanged: break
        case .clear: dict[key] = NSNull()
        case .set(let v): dict[key] = v
        }
    }

    private static func make(_ type: String, _ fields: [String: Any], now: Date, id: String = UUID().uuidString.lowercased()) -> OutgoingEvent {
        var dict = fields
        dict["id"] = id
        dict["ts"] = iso(now)
        dict["type"] = type
        // sortedKeys keeps the output deterministic, which the tests rely on.
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data("{}".utf8)
        return OutgoingEvent(id: id, createdAt: now, json: data)
    }

    public static func dayPatch(date: String,
                                habits: [String: Bool] = [:],
                                rating: FieldUpdate<String> = .unchanged,
                                ratingAI: FieldUpdate<String> = .unchanged,
                                ratingSource: FieldUpdate<RatingSource> = .unchanged,
                                ratingReason: FieldUpdate<String> = .unchanged,
                                weight: FieldUpdate<String> = .unchanged,
                                now: Date = Date(),
                                id: String = UUID().uuidString.lowercased()) -> OutgoingEvent {
        var f: [String: Any] = ["date": date]
        if !habits.isEmpty { f["habits"] = habits }
        put(&f, "rating", rating)
        put(&f, "ratingAI", ratingAI)
        switch ratingSource {
        case .unchanged: break
        case .clear: f["ratingSource"] = NSNull()
        case .set(let s): f["ratingSource"] = s.rawValue
        }
        put(&f, "ratingReason", ratingReason)
        put(&f, "weight", weight)
        return make("day.patch", f, now: now, id: id)
    }

    public static func journal(date: String, text: String, baseHash: String?, now: Date = Date(), id: String = UUID().uuidString.lowercased()) -> OutgoingEvent {
        make("day.journal", ["date": date, "text": text, "baseHash": baseHash.map { $0 as Any } ?? NSNull()], now: now, id: id)
    }

    public static func taskCreate(taskId: String, title: String, created: String, date: String?, wichtig: Bool, notes: String?, now: Date = Date(), id: String = UUID().uuidString.lowercased()) -> OutgoingEvent {
        var f: [String: Any] = ["taskId": taskId, "title": title, "created": created, "wichtig": wichtig]
        f["date"] = date.map { $0 as Any } ?? NSNull()
        if let notes, !notes.isEmpty { f["notes"] = notes }
        return make("task.create", f, now: now, id: id)
    }

    public static func taskPatch(taskId: String?, path: String?, completed: Bool? = nil, wichtig: Bool? = nil,
                                 date: FieldUpdate<String> = .unchanged, title: String? = nil,
                                 now: Date = Date(), id: String = UUID().uuidString.lowercased()) -> OutgoingEvent {
        var f: [String: Any] = [:]
        if let taskId { f["taskId"] = taskId }
        if let path { f["path"] = path }
        if let completed { f["completed"] = completed }
        if let wichtig { f["wichtig"] = wichtig }
        put(&f, "date", date)
        if let title { f["title"] = title }
        return make("task.patch", f, now: now, id: id)
    }

    public static func appointmentAdd(apptId: String, title: String, date: String, startTime: String?, endTime: String?, allDay: Bool,
                                      location: String?, notes: String?, mailbox: String?, from: String?, subject: String?, receivedAt: Date?,
                                      category: String? = nil, schoolSubject: String? = nil, recur: Recurrence? = nil,
                                      now: Date = Date(), id: String = UUID().uuidString.lowercased()) -> OutgoingEvent {
        var f: [String: Any] = ["apptId": apptId, "title": title, "date": date, "allDay": allDay]
        if let category { f["category"] = category }
        if let schoolSubject, !schoolSubject.isEmpty { f["subject"] = schoolSubject }
        if let recur { f["recur"] = ["days": recur.days, "until": recur.until] }
        f["startTime"] = startTime.map { $0 as Any } ?? NSNull()
        f["endTime"] = endTime.map { $0 as Any } ?? NSNull()
        if let location, !location.isEmpty { f["location"] = location }
        if let notes, !notes.isEmpty { f["notes"] = notes }
        var src: [String: Any] = [:]
        if let mailbox { src["mailbox"] = mailbox }
        if let from { src["from"] = from }
        if let subject { src["subject"] = subject }
        if let receivedAt { src["receivedAt"] = iso(receivedAt) }
        if !src.isEmpty { f["source"] = src }
        return make("appointment.add", f, now: now, id: id)
    }

    /// Changes or deletes an appointment note (found by tagwerk_id, else by path).
    public static func appointmentPatch(apptId: String?, path: String?, deleted: Bool = false, title: String? = nil, date: String? = nil,
                                        startTime: FieldUpdate<String> = .unchanged, endTime: FieldUpdate<String> = .unchanged,
                                        allDay: Bool? = nil, location: FieldUpdate<String> = .unchanged,
                                        category: FieldUpdate<String> = .unchanged, schoolSubject: FieldUpdate<String> = .unchanged,
                                        recur: FieldUpdate<Recurrence> = .unchanged, notes: FieldUpdate<String> = .unchanged,
                                        now: Date = Date(), id: String = UUID().uuidString.lowercased()) -> OutgoingEvent {
        var f: [String: Any] = [:]
        if let apptId { f["apptId"] = apptId }
        if let path { f["path"] = path }
        if deleted { f["deleted"] = true }
        if let title { f["title"] = title }
        if let date { f["date"] = date }
        if let allDay { f["allDay"] = allDay }
        put(&f, "startTime", startTime)
        put(&f, "endTime", endTime)
        put(&f, "location", location)
        put(&f, "category", category)
        put(&f, "subject", schoolSubject)
        put(&f, "notes", notes)
        switch recur {
        case .unchanged: break
        case .clear: f["recur"] = NSNull()
        case .set(let r): f["recur"] = ["days": r.days, "until": r.until]
        }
        return make("appointment.patch", f, now: now, id: id)
    }

    /// Marks one lesson (or planner entry) for one day; state "clear" removes the mark.
    public static func schoolOverride(key: String, date: String, start: String, end: String?, subject: String?, title: String?,
                                      state: String, reason: String?, now: Date = Date(), id: String = UUID().uuidString.lowercased()) -> OutgoingEvent {
        var f: [String: Any] = ["key": key, "date": date, "start": start, "state": state]
        if let end { f["end"] = end }
        if let subject, !subject.isEmpty { f["subject"] = subject }
        if let title, !title.isEmpty { f["title"] = title }
        if let reason, !reason.isEmpty { f["reason"] = reason }
        return make("school.override", f, now: now, id: id)
    }

    /// A new run note in "Laufzeiten", in the vault's own format: distance "3.02", time 00:16:29.
    public static func runAdd(runId: String, date: String, distanceKm: Double, seconds: Int, source: String, gpx: String? = nil,
                              now: Date = Date(), id: String = UUID().uuidString.lowercased()) -> OutgoingEvent {
        var f: [String: Any] = ["runId": runId, "date": date, "distance": RunTime.distance(distanceKm), "time": RunTime.vault(seconds), "source": source]
        if let gpx, !gpx.isEmpty { f["gpx"] = gpx }
        return make("run.add", f, now: now, id: id)
    }

    public static func runPatch(runId: String?, path: String?, distanceKm: Double? = nil, seconds: Int? = nil, deleted: Bool = false,
                                now: Date = Date(), id: String = UUID().uuidString.lowercased()) -> OutgoingEvent {
        var f: [String: Any] = [:]
        if let runId { f["runId"] = runId }
        if let path { f["path"] = path }
        if let distanceKm { f["distance"] = RunTime.distance(distanceKm) }
        if let seconds { f["time"] = RunTime.vault(seconds) }
        if deleted { f["deleted"] = true }
        return make("run.patch", f, now: now, id: id)
    }

    static func jsonValue<T: Encodable>(_ value: T) -> Any {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(value), let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return NSNull() }
        return obj
    }

    /// Replaces the whole food log of one day (entries are only edited in the app).
    public static func foodDay(date: String, entries: [FoodEntry], targets: DayTargets?, met: Bool?,
                               now: Date = Date(), id: String = UUID().uuidString.lowercased()) -> OutgoingEvent {
        var f: [String: Any] = ["date": date, "entries": jsonValue(entries)]
        f["targets"] = targets.map { jsonValue($0) } ?? NSNull()
        f["met"] = met.map { $0 as Any } ?? NSNull()
        return make("food.day", f, now: now, id: id)
    }

    public static func profileSet(_ profile: BodyProfile, summary: String? = nil, now: Date = Date(), id: String = UUID().uuidString.lowercased()) -> OutgoingEvent {
        var f: [String: Any] = ["profile": jsonValue(profile)]
        if let summary, !summary.isEmpty { f["summary"] = summary }
        return make("profile.set", f, now: now, id: id)
    }

    /// Plaintext of one inbox file.
    public static func batch(_ events: [OutgoingEvent], device: String, now: Date = Date()) throws -> Data {
        let objects = try events.map { try JSONSerialization.jsonObject(with: $0.json) }
        let dict: [String: Any] = ["schema": 1, "device": device, "createdAt": iso(now), "events": objects]
        return try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }
}
