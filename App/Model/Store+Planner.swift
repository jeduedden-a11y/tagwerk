import Foundation
import SwiftUI
import TagwerkCore

extension Store {
    // MARK: WebUntis access

    var untisPassword: String? {
        let p = keychain.get(SecretKey.untisPassword) ?? ""
        return p.isEmpty ? nil : p
    }

    var untisReady: Bool { state.settings.untis.isComplete && untisPassword != nil }

    private func untisClient() -> UntisClient? {
        guard untisReady, let pass = untisPassword else { return nil }
        let cfg = state.settings.untis
        let key = "\(cfg.server)|\(cfg.school)|\(cfg.username)|\(pass.hashValue)"
        if let c = untisClientCache, untisClientKey == key { return c }
        let c = UntisClient(config: cfg, password: pass)
        untisClientCache = c
        untisClientKey = key
        return c
    }

    func resetUntisSession() {
        untisClientCache = nil
        untisClientKey = ""
    }

    /// Loads the selected week, this week and the next two, the school year data once a day, and the messages.
    func refreshUntis(around day: String? = nil, force: Bool = false) async {
        guard !isDemo, !untisInFlight, let client = untisClient() else { return }
        let thisWeek = Planner.monday(of: today)
        var weeks = Set([Planner.monday(of: day ?? plannerDay), thisWeek, Planner.adding(7, to: thisWeek), Planner.adding(14, to: thisWeek)])
        if !force {
            weeks = weeks.filter { w in state.untis.weeksFetched[w].map { Date().timeIntervalSince($0) > 15 * 60 } ?? true }
            if weeks.isEmpty { return }
        }
        untisInFlight = true
        defer { untisInFlight = false }
        do {
            if force || state.untis.schoolFetched.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true {
                state.untis.school = try await client.schoolData()
                state.untis.schoolFetched = Date()
            }
            for w in weeks.sorted() {
                let list = try await client.periods(from: w, to: Planner.adding(6, to: w))
                withAnimation(.smooth) { state.untis.setWeek(w, list, today: today) }
            }
            let messages = try await client.messages()
            await ingest(messages)
            state.untis.lastError = nil
            state.untis.lastFetch = Date()
        } catch {
            state.untis.lastError = error.localizedDescription
        }
        scheduleSave()
    }

    /// New messages are searched for dates like mails; the first run looks back three weeks only.
    private func ingest(_ messages: [UntisMessage]) async {
        let firstRun = state.untis.scanned.isEmpty
        state.untis.messages = Array(messages.prefix(80))
        let cutoff = Date().addingTimeInterval(-21 * 86_400)
        for m in messages.prefix(40) where !state.untis.scanned.contains(m.id) {
            state.untis.scanned.append(m.id)
            let sent = UntisDates.formatter.date(from: m.sent) ?? Date()
            if firstRun && sent < cutoff { continue }
            _ = await extract(mailbox: "WebUntis", subject: m.subject, from: m.sender, received: sent, text: m.preview, sourceID: "untis-\(m.id)")
        }
        if state.untis.scanned.count > 400 { state.untis.scanned.removeFirst(state.untis.scanned.count - 400) }
    }

    /// Full text of a message; dates in it become suggestions.
    func untisMessageText(_ m: UntisMessage) async -> String? {
        guard let client = untisClient() else { return nil }
        do {
            let text = try await client.messageText(id: m.id)
            if let i = state.untis.messages.firstIndex(where: { $0.id == m.id }) { state.untis.messages[i].read = true }
            let sent = UntisDates.formatter.date(from: m.sent) ?? Date()
            let found = await extract(mailbox: "WebUntis", subject: m.subject, from: m.sender, received: sent, text: text, sourceID: "untis-\(m.id)-text")
            if found > 0 { flash(found == 1 ? "Ein Termin als Vorschlag im Planer" : "\(found) Termine als Vorschläge im Planer") }
            scheduleSave()
            return text
        } catch {
            flash(error.localizedDescription)
            return nil
        }
    }

    func testUntis() async -> String {
        guard state.settings.untis.isComplete else { return "Adresse, Schule und Benutzername fehlen noch." }
        guard untisPassword != nil else { return "Das Passwort fehlt noch." }
        resetUntisSession()
        guard let client = untisClient() else { return "Nicht eingerichtet." }
        do {
            try await client.login()
            let data = try await client.schoolData()
            state.untis.school = data
            state.untis.schoolFetched = Date()
            scheduleSave()
            return "Verbunden" + (data.userName.map { " als \($0)" } ?? "") + "."
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Planner data

    var plannerAppointments: [PlannerAppointment] {
        state.appointments.map { a in
            PlannerAppointment(id: a.id, title: a.title, date: a.date, startTime: a.startTime, endTime: a.endTime, allDay: a.allDay,
                               location: a.location, category: a.category, subject: a.schoolSubject, recur: a.recur, notes: a.notes,
                               pending: a.pending != nil)
        }
    }

    var plannerSuggestions: [PlannerSuggestion] {
        openSuggestions.map { s in
            PlannerSuggestion(id: s.id, title: s.title, date: s.date, startTime: s.startTime, endTime: s.endTime, allDay: s.allDay,
                              location: s.location, mailbox: s.mailbox)
        }
    }

    func plannerEntries(on day: String) -> [PlannerEntry] {
        Planner.entries(on: day, periods: state.untis.periods[day] ?? [], appointments: plannerAppointments, suggestions: plannerSuggestions,
                        overrides: state.schoolOverrides, holidays: state.untis.school?.holidays ?? [])
    }

    /// Exams in the next weeks, from WebUntis and from the vault.
    func upcomingExams(days: Int = 28) -> [PlannerEntry] {
        let appts = plannerAppointments
        let suggestions: [PlannerSuggestion] = []
        return (0...days).flatMap { i -> [PlannerEntry] in
            let d = DayKey.adding(i, to: today)
            return Planner.entries(on: d, periods: state.untis.periods[d] ?? [], appointments: appts, suggestions: suggestions,
                                   overrides: state.schoolOverrides, holidays: [])
                .filter { $0.isExam && !$0.isOff }
        }
    }

    /// Marks one lesson or occurrence for the user; nil clears the mark.
    func setMark(_ entry: PlannerEntry, to newState: String?, reason: String? = nil) {
        guard let key = entry.overrideKey else { return }
        let start = entry.start.map(Planner.clock) ?? "00:00"
        let end = entry.end.map(Planner.clock)
        let subject = entry.period?.subjectLong ?? entry.period?.subject ?? entry.appointment?.subject
        let cleanReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = EventFactory.schoolOverride(key: key, date: entry.date, start: start, end: end, subject: subject, title: entry.title,
                                            state: newState ?? "clear", reason: cleanReason)
        withAnimation(.smooth) {
            if let newState {
                state.schoolOverrides[key] = SchoolOverride(key: key, date: entry.date, start: start, end: end, subject: subject, title: entry.title,
                                                            state: newState, reason: cleanReason?.isEmpty == false ? cleanReason : nil)
            } else {
                state.schoolOverrides[key] = nil
            }
        }
        state.overridePending[key] = mark(e)
        enqueue(e)
    }

    private static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// A new appointment, lecture or exam; written to the vault as a note in 01 Leben/Termine.
    func addPlannerEntry(_ d: PlannerDraft) async {
        let apptId = UUID().uuidString.lowercased()
        let date = DayKey.key(for: d.date)
        var title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = d.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = d.kind == .klausur ? "Klausur" : d.kind == .uni ? "Vorlesung" : "Termin" }
        let start = d.allDay ? nil : Self.hhmm.string(from: d.start)
        let end = d.allDay ? nil : Self.hhmm.string(from: max(d.end, d.start.addingTimeInterval(5 * 60)))
        let recur = d.weekly && !d.weekdays.isEmpty ? Recurrence(days: d.weekdays.sorted(), until: max(DayKey.key(for: d.until), date)) : nil
        let location = d.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = d.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = EventFactory.appointmentAdd(apptId: apptId, title: title, date: date, startTime: start, endTime: end, allDay: d.allDay,
                                            location: location.isEmpty ? nil : location, notes: notes.isEmpty ? nil : notes,
                                            mailbox: nil, from: nil, subject: nil, receivedAt: nil,
                                            category: d.kind.rawValue, schoolSubject: subject.isEmpty ? nil : subject, recur: recur)
        var a = Appointment(id: apptId, title: title, date: date, startTime: start, endTime: end, allDay: d.allDay,
                            location: location.isEmpty ? nil : location)
        a.category = d.kind.rawValue
        a.schoolSubject = subject.isEmpty ? nil : subject
        a.recur = recur
        a.notes = notes.isEmpty ? nil : notes
        a.pending = mark(e)
        if state.settings.calendarExport && !isDemo && recur == nil {
            a.calendarEventId = await CalendarService.shared.add(a, calendarIdentifier: state.settings.calendarIdentifier)
        }
        withAnimation(.smooth) {
            state.appointments.append(a)
            state.appointments.sort { ($0.date, $0.startTime ?? "") < ($1.date, $1.startTime ?? "") }
        }
        enqueue(e)
        flash(state.bridgeFeatures.contains("planner") ? "Wird in den Vault übernommen" : "Wartet auf Tagwerk Bridge 1.2 in Obsidian")
    }

    func deleteAppointment(_ id: String) {
        guard let a = state.appointments.first(where: { $0.id == id }) else { return }
        let e = EventFactory.appointmentPatch(apptId: id.hasPrefix("vault:") ? nil : id, path: a.path, deleted: true)
        withAnimation(.smooth) { state.appointments.removeAll { $0.id == id } }
        state.deletedAppointments[id] = mark(e)
        enqueue(e)
        flash("Termin gelöscht")
    }

    // MARK: Notes

    func syncWiki(force: Bool = false) async {
        guard !isDemo, let gh = github, let pass = passphrase, !pass.isEmpty else { return }
        await wiki.sync(github: gh, passphrase: pass, force: force)
    }
}
