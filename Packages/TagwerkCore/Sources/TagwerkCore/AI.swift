import Foundation

// MARK: - Inputs and outputs

public struct HabitState: Hashable, Sendable {
    public var key: String
    public var label: String
    public var done: Bool
    public var weekCount: Int
    public var perWeek: Double

    public init(key: String, label: String, done: Bool, weekCount: Int, perWeek: Double) {
        self.key = key
        self.label = label
        self.done = done
        self.weekCount = weekCount
        self.perWeek = perWeek
    }
}

public struct CalibrationExample: Hashable, Sendable {
    public var date: String
    public var habitsDone: [String]
    public var rating: String
    public var text: String?
    public var manualOverride: Bool

    public init(date: String, habitsDone: [String], rating: String, text: String?, manualOverride: Bool) {
        self.date = date
        self.habitsDone = habitsDone
        self.rating = rating
        self.text = text
        self.manualOverride = manualOverride
    }
}

public struct DayContext: Sendable {
    public var date: String
    public var userName: String
    public var habits: [HabitState]
    public var journal: String
    public var obsidianNote: String?
    public var weight: String?
    public var previousWeight: String?
    public var tasksCompletedToday: [String]
    public var calibration: [CalibrationExample]
    public var averageRating: Double?

    public init(date: String, userName: String, habits: [HabitState], journal: String, obsidianNote: String?, weight: String?,
                previousWeight: String?, tasksCompletedToday: [String], calibration: [CalibrationExample], averageRating: Double?) {
        self.date = date
        self.userName = userName
        self.habits = habits
        self.journal = journal
        self.obsidianNote = obsidianNote
        self.weight = weight
        self.previousWeight = previousWeight
        self.tasksCompletedToday = tasksCompletedToday
        self.calibration = calibration
        self.averageRating = averageRating
    }
}

public struct DayAssessment: Hashable, Sendable {
    public var rating: Double
    public var reason: String
    /// Habit keys the text clearly reports as done today.
    public var detectedHabits: [String]
    public var weight: Double?
    public var provider: String

    public init(rating: Double, reason: String, detectedHabits: [String], weight: Double?, provider: String) {
        self.rating = rating
        self.reason = reason
        self.detectedHabits = detectedHabits
        self.weight = weight
        self.provider = provider
    }
}

public struct MailForExtraction: Sendable {
    public var mailbox: String
    public var subject: String
    public var from: String
    public var received: Date
    public var text: String
    public var candidates: [DateCandidate]

    public init(mailbox: String, subject: String, from: String, received: Date, text: String, candidates: [DateCandidate]) {
        self.mailbox = mailbox
        self.subject = subject
        self.from = from
        self.received = received
        self.text = text
        self.candidates = candidates
    }
}

public struct ExtractedAppointment: Hashable, Sendable {
    public var title: String
    public var date: String
    public var startTime: String?
    public var endTime: String?
    public var allDay: Bool
    public var location: String?
    public var confidence: Double

    public init(title: String, date: String, startTime: String?, endTime: String?, allDay: Bool, location: String?, confidence: Double) {
        self.title = title
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.allDay = allDay
        self.location = location
        self.confidence = confidence
    }
}

public protocol DayRater: Sendable {
    var name: String { get }
    func assess(_ ctx: DayContext) async throws -> DayAssessment
}

public protocol AppointmentStructurer: Sendable {
    var name: String { get }
    func structure(_ mail: MailForExtraction) async throws -> [ExtractedAppointment]
}

// MARK: - Prompts (shared by every provider)

public enum Prompts {
    public static func ratingInstructions(userName: String) -> String {
        let who = userName.isEmpty ? "den Nutzer" : userName
        return """
        Du bewertest einen Tag für \(who) auf seiner persönlichen Skala von 0.0 bis 10.0 mit einer Nachkommastelle.
        Die Skala gehört ihm. Richte dich nach seinen eigenen früheren Bewertungen in den Beispielen und nach seinem Durchschnitt, nicht nach einer allgemeinen Vorstellung von einem guten Tag.
        Was er über den Tag schreibt, wiegt schwerer als die abgehakten Gewohnheiten. Gewohnheiten erklären seine bisherigen Bewertungen nur zu einem kleinen Teil.
        Erfinde nichts. Gibt der Text wenig her, orientiere dich an Gewohnheiten und Durchschnitt und sag das in der Begründung.
        Begründung: ein bis zwei sachliche Sätze auf Deutsch in der zweiten Person, keine Floskeln, keine Emojis, keine Ratschläge.
        Erkannte Gewohnheiten: nur Schlüssel, deren Erledigung heute der Text eindeutig berichtet. Ein bloßes Vorhaben zählt nicht.
        Gewicht: nur, wenn im Text eine Zahl in Kilogramm genannt wird, sonst null.
        """
    }

    public static func ratingInput(_ c: DayContext) -> String {
        var lines: [String] = []
        if let avg = c.averageRating { lines.append("Sein Durchschnitt bisher: \(String(format: "%.1f", avg))") }
        if !c.calibration.isEmpty {
            lines.append("")
            lines.append("Frühere Tage mit seiner eigenen Bewertung:")
            for e in c.calibration {
                var l = "- \(e.date) (\(DayKey.weekdayShortName(e.date))): Rating \(e.rating)"
                l += e.habitsDone.isEmpty ? "; keine Gewohnheit erledigt" : "; erledigt: \(e.habitsDone.joined(separator: ", "))"
                if e.manualOverride { l += "; von ihm gegen den KI-Vorschlag korrigiert" }
                if let t = e.text, !t.isEmpty { l += "; Text: \"\(String(t.prefix(300)))\"" }
                lines.append(l)
            }
        }
        lines.append("")
        lines.append("Heute: \(c.date) (\(DayKey.weekdayName(c.date)))")
        let done = c.habits.filter(\.done).map(\.label)
        lines.append(done.isEmpty ? "Gewohnheiten erledigt: keine" : "Gewohnheiten erledigt: \(done.joined(separator: ", "))")
        let week = c.habits.map { "\($0.label) \($0.weekCount)/\(Int($0.perWeek.rounded()))" }.joined(separator: ", ")
        lines.append("Wochenstand: \(week)")
        lines.append("Gewohnheiten-Schlüssel: " + c.habits.map { "\($0.key) (\($0.label))" }.joined(separator: ", "))
        if !c.tasksCompletedToday.isEmpty { lines.append("Heute erledigte Aufgaben: \(c.tasksCompletedToday.joined(separator: "; "))") }
        if let w = c.weight {
            lines.append("Gewicht: \(w) kg" + (c.previousWeight.map { " (zuletzt \($0) kg)" } ?? ""))
        }
        lines.append("")
        lines.append("Tagebuch:")
        lines.append(c.journal.isEmpty ? "(leer)" : "\"\"\"\n\(String(c.journal.prefix(6000)))\n\"\"\"")
        if let n = c.obsidianNote, !n.isEmpty {
            lines.append("Notiz in Obsidian: \"\"\"\n\(String(n.prefix(2000)))\n\"\"\"")
        }
        return lines.joined(separator: "\n")
    }

    public static let extractionInstructions = """
    Du liest eine E-Mail und findest konkrete Termine, die für den Empfänger relevant sind: Treffen, Sitzungen, Unterricht, Prüfungen, Abgaben, Fristen, Veranstaltungen.
    Übernimm keine Daten aus zitierten älteren Nachrichten, keine Versanddaten, keine Werbung oder Newsletter-Aktionen, keine Termine vor dem Empfangsdatum.
    Relative Angaben wie morgen oder nächsten Dienstag beziehen sich auf das Empfangsdatum.
    Fristen sind ganztägig, Titel beginnt mit "Frist:". Titel kurz (höchstens sechs Wörter), auf Deutsch, ohne Datum.
    Gibt es keinen Termin, gib eine leere Liste zurück.
    """

    public static func extractionInput(_ m: MailForExtraction) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, d. MMMM yyyy, HH:mm"
        var s = "Postfach: \(m.mailbox)\nVon: \(m.from)\nBetreff: \(m.subject)\nEmpfangen: \(f.string(from: m.received))\n"
        if !m.candidates.isEmpty {
            s += "Vorab gefundene Datumsangaben: " + m.candidates.map { c in
                "\(c.day)\(c.startTime.map { " \($0)" } ?? "")\(c.endTime.map { "-\($0)" } ?? "") (\"\(c.matchedText)\")"
            }.joined(separator: "; ") + "\n"
        }
        s += "\nText:\n\"\"\"\n\(String(m.text.prefix(6000)))\n\"\"\""
        return s
    }
}

// MARK: - Claude (Messages API, forced tool call for structured output)

public enum ClaudeError: LocalizedError {
    case noKey
    case http(Int, String)
    case noStructuredAnswer(String)

    public var errorDescription: String? {
        switch self {
        case .noKey: return "Kein Claude-API-Schlüssel hinterlegt."
        case .http(let c, let m):
            if c == 401 { return "Der Claude-API-Schlüssel wird abgelehnt." }
            if c == 429 { return "Claude-API: zu viele Anfragen oder kein Guthaben." }
            return "Claude-API-Fehler \(c): \(m)"
        case .noStructuredAnswer(let r): return "Die KI hat keine verwertbare Antwort geliefert (\(r))."
        }
    }
}

/// JSON-schema node: {"type": type, ...extra}
func schema(_ type: Any, _ extra: [String: Any] = [:]) -> [String: Any] {
    var d: [String: Any] = ["type": type]
    for (k, v) in extra { d[k] = v }
    return d
}

public struct ClaudeClient: DayRater, AppointmentStructurer {
    public var apiKey: String
    public var model: String
    public var session: URLSession

    public var name: String { "Claude (\(model))" }

    public init(apiKey: String, model: String = "claude-haiku-5-5", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    func call(system: String, user: String, tool: [String: Any], maxTokens: Int) async throws -> [String: Any] {
        guard !apiKey.isEmpty else { throw ClaudeError.noKey }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let toolName = tool["name"] as? String ?? "antwort"
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": toolName],
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? String(data: data, encoding: .utf8) ?? ""
            throw ClaudeError.http(status, String(msg.prefix(200)))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeError.noStructuredAnswer("kein JSON") }
        let content = obj["content"] as? [[String: Any]] ?? []
        if let block = content.first(where: { ($0["type"] as? String) == "tool_use" }), let input = block["input"] as? [String: Any] {
            return input
        }
        throw ClaudeError.noStructuredAnswer(obj["stop_reason"] as? String ?? "unbekannt")
    }

    public func assess(_ ctx: DayContext) async throws -> DayAssessment {
        let keys = ctx.habits.map(\.key)
        let properties: [String: Any] = [
            "rating": schema("number", ["minimum": 0, "maximum": 10, "description": "Bewertung 0.0 bis 10.0, eine Nachkommastelle"]),
            "begruendung": schema("string", ["description": "Ein bis zwei Sätze"]),
            "erkannte_gewohnheiten": schema("array", ["items": schema("string", ["enum": keys])]),
            "gewicht_kg": schema(["number", "null"]),
        ]
        let tool: [String: Any] = [
            "name": "tagesbewertung",
            "description": "Gibt die Tagesbewertung zurück.",
            "input_schema": schema("object", ["properties": properties, "required": ["rating", "begruendung", "erkannte_gewohnheiten"]]),
        ]
        let input = try await call(system: Prompts.ratingInstructions(userName: ctx.userName), user: Prompts.ratingInput(ctx), tool: tool, maxTokens: 400)
        guard let rating = (input["rating"] as? NSNumber)?.doubleValue else { throw ClaudeError.noStructuredAnswer("rating fehlt") }
        let reason = (input["begruendung"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let detected = (input["erkannte_gewohnheiten"] as? [String] ?? []).filter { keys.contains($0) }
        let weight = (input["gewicht_kg"] as? NSNumber)?.doubleValue
        return DayAssessment(rating: min(10, max(0, (rating * 10).rounded() / 10)), reason: reason, detectedHabits: detected,
                             weight: weight.flatMap { (20...400).contains($0) ? $0 : nil }, provider: name)
    }

    public func structure(_ mail: MailForExtraction) async throws -> [ExtractedAppointment] {
        let item: [String: Any] = schema("object", [
            "properties": [
                "titel": schema("string"),
                "datum": schema("string", ["description": "YYYY-MM-DD"]),
                "beginn": schema(["string", "null"], ["description": "HH:MM"]),
                "ende": schema(["string", "null"], ["description": "HH:MM"]),
                "ganztaegig": schema("boolean"),
                "ort": schema(["string", "null"]),
                "sicherheit": schema("number", ["minimum": 0, "maximum": 1]),
            ] as [String: Any],
            "required": ["titel", "datum", "ganztaegig", "sicherheit"],
        ])
        let tool: [String: Any] = [
            "name": "termine",
            "description": "Gibt die gefundenen Termine zurück.",
            "input_schema": schema("object", ["properties": ["termine": schema("array", ["items": item])] as [String: Any], "required": ["termine"]]),
        ]
        let input = try await call(system: Prompts.extractionInstructions, user: Prompts.extractionInput(mail), tool: tool, maxTokens: 700)
        let items = input["termine"] as? [[String: Any]] ?? []
        return items.compactMap { it in
            guard let title = (it["titel"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let date = it["datum"] as? String, DayKey.ordinal(date) != nil else { return nil }
            let valid: (Any?) -> String? = { v in
                guard let s = v as? String, s.count == 5, DateExtractor.hhmm(Int(s.prefix(2)) ?? -1, Int(s.suffix(2)) ?? -1) != nil else { return nil }
                return s
            }
            let start = valid(it["beginn"])
            return ExtractedAppointment(title: title, date: date, startTime: start, endTime: valid(it["ende"]),
                                        allDay: (it["ganztaegig"] as? Bool ?? (start == nil)) || start == nil,
                                        location: (it["ort"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                        confidence: (it["sicherheit"] as? NSNumber)?.doubleValue ?? 0.5)
        }
    }
}

// MARK: - Fallbacks without any model

/// Rating from the user's own history; never reads the text.
public struct FormulaRater: DayRater {
    public var formula: HabitFormula?
    public var average: Double

    public init(formula: HabitFormula?, average: Double) {
        self.formula = formula
        self.average = average
    }

    public var name: String { "Formel" }

    public func assess(_ ctx: DayContext) async throws -> DayAssessment {
        var habits: [String: Bool] = [:]
        for h in ctx.habits { habits[h.key] = h.done }
        let value = formula?.predict(habits) ?? average
        return DayAssessment(rating: (value * 10).rounded() / 10,
                             reason: "Schätzung nur aus deinen Gewohnheiten und deinem bisherigen Schnitt. Den Text kann die Formel nicht lesen.",
                             detectedHabits: [], weight: nil, provider: name)
    }
}

/// Without a model, every date the regexes find becomes a suggestion titled by the subject.
public struct HeuristicStructurer: AppointmentStructurer {
    public init() {}
    public var name: String { "Ohne KI" }

    public func structure(_ mail: MailForExtraction) async throws -> [ExtractedAppointment] {
        mail.candidates.map {
            ExtractedAppointment(title: String(mail.subject.prefix(60)), date: $0.day, startTime: $0.startTime, endTime: $0.endTime,
                                 allDay: $0.startTime == nil, location: nil, confidence: 0.4)
        }
    }
}
