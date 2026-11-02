import Foundation
import SwiftUI
import TagwerkCore

extension Store {
    func mailPassword(_ account: IMAPAccount) -> String? {
        let p = keychain.get(SecretKey.mailPassword(account.id)) ?? ""
        return p.isEmpty ? nil : p
    }

    var configuredMailAccounts: [IMAPAccount] {
        state.settings.mailAccounts.filter { $0.enabled && !$0.username.isEmpty && mailPassword($0) != nil }
    }

    /// Fetch new mails read-only, find dates, let the model turn them into suggestions.
    func checkMail() async {
        guard !mailInFlight else { return }
        if isDemo {
            flash("Demo: keine Postfächer verbunden")
            return
        }
        let accounts = configuredMailAccounts
        guard !accounts.isEmpty else {
            mailStatus = "Noch kein Postfach eingerichtet."
            return
        }
        mailInFlight = true
        defer { mailInFlight = false }
        var found = 0
        var problems: [String] = []
        let since = Date().addingTimeInterval(-Double(state.settings.mailLookbackDays) * 86_400)
        for account in accounts {
            guard let password = mailPassword(account) else { continue }
            let key = account.id.uuidString
            var cursor = state.mailCursors[key] ?? MailCursor()
            mailStatus = "Lese \(account.name) …"
            do {
                let result = try await IMAPClient.fetchRecent(account: account, password: password, since: since,
                                                              excludingUIDs: Set(cursor.seenUIDs), knownUIDValidity: cursor.uidValidity, limit: 40)
                if cursor.uidValidity != result.uidValidity { cursor.seenUIDs = [] }
                cursor.uidValidity = result.uidValidity
                for m in result.messages {
                    let parsed = MIME.parse(m.raw)
                    let received = parsed.date ?? m.internalDate ?? Date()
                    mailStatus = "Suche Termine in „\(parsed.subject.prefix(40))“ …"
                    found += await extract(mailbox: account.name, subject: parsed.subject, from: parsed.from, received: received,
                                           text: parsed.text, sourceID: "\(key)-\(m.uid)")
                    cursor.seenUIDs.append(m.uid)
                }
                cursor.seenUIDs = Array(cursor.seenUIDs.suffix(3000))
                cursor.lastCheck = Date()
                cursor.lastError = nil
            } catch {
                cursor.lastError = error.localizedDescription
                problems.append("\(account.name): \(error.localizedDescription)")
            }
            state.mailCursors[key] = cursor
        }
        state.lastMailCheck = Date()
        // Suggestions for days that have passed are no longer useful.
        state.suggestions.removeAll { $0.status != .open || $0.date < DayKey.adding(-1, to: today) }
        mailStatus = problems.isEmpty ? (found == 0 ? "Keine neuen Termine gefunden." : "\(found) neue Vorschläge.") : problems.joined(separator: "\n")
        saveNow()
    }

    /// Pasted text: same pipeline, without a mailbox.
    func extractFromText(_ text: String) async -> Int {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return 0 }
        mailInFlight = true
        defer { mailInFlight = false }
        let n = await extract(mailbox: "Eingefügt", subject: String(String(t.split(separator: "\n").first ?? "Eingefügter Text").prefix(80)),
                              from: "", received: Date(), text: t, sourceID: "paste-\(UUID().uuidString.prefix(8))")
        saveNow()
        return n
    }

    func extract(mailbox: String, subject: String, from: String, received: Date, text: String, sourceID: String) async -> Int {
        let full = subject + "\n" + text
        let candidates = DateExtractor.candidates(in: full, reference: received)
        guard !candidates.isEmpty else { return 0 }
        let mail = MailForExtraction(mailbox: mailbox, subject: subject, from: from, received: received, text: text, candidates: candidates)
        var results: [ExtractedAppointment]
        do {
            results = try await ai.structurer().structure(mail)
        } catch {
            results = (try? await HeuristicStructurer().structure(mail)) ?? []
        }
        let todayKey = today
        var added = 0
        for r in results where r.date >= todayKey && r.confidence >= 0.3 {
            let id = "\(sourceID)-\(r.date)-\(r.startTime ?? "")"
            guard !state.suggestions.contains(where: { $0.id == id }),
                  !state.appointments.contains(where: { $0.date == r.date && $0.title.lowercased() == r.title.lowercased() }) else { continue }
            let context = candidates.first { $0.day == r.date }?.context ?? ""
            let s = Suggestion(id: id, mailbox: mailbox, subject: subject, from: from, receivedAt: received, title: r.title, date: r.date,
                               startTime: r.startTime, endTime: r.endTime, allDay: r.allDay, location: r.location,
                               confidence: r.confidence, context: String(context.prefix(240)))
            withAnimation(.smooth) { state.suggestions.append(s) }
            added += 1
        }
        return added
    }

    func dismiss(_ s: Suggestion) {
        guard let i = state.suggestions.firstIndex(where: { $0.id == s.id }) else { return }
        withAnimation(.smooth) { state.suggestions[i].status = .dismissed }
        scheduleSave()
    }

    /// Writes the appointment to the vault and, if enabled, to the iPhone calendar.
    func accept(_ s: Suggestion, edited: Suggestion? = nil) async {
        let v = edited ?? s
        let apptId = UUID().uuidString.lowercased()
        let e = EventFactory.appointmentAdd(apptId: apptId, title: v.title, date: v.date, startTime: v.allDay ? nil : v.startTime,
                                            endTime: v.allDay ? nil : v.endTime, allDay: v.allDay || v.startTime == nil,
                                            location: v.location, notes: v.context.isEmpty ? nil : "Textstelle: \(v.context)",
                                            mailbox: v.mailbox, from: v.from.isEmpty ? nil : v.from, subject: v.subject, receivedAt: v.receivedAt)
        var a = Appointment(id: apptId, title: v.title, date: v.date, startTime: v.allDay ? nil : v.startTime, endTime: v.allDay ? nil : v.endTime,
                            allDay: v.allDay || v.startTime == nil, location: v.location, mailbox: v.mailbox, from: v.from, subject: v.subject,
                            receivedAt: v.receivedAt)
        a.pending = PendingMark(eventId: e.id, at: e.createdAt)
        if state.settings.calendarExport && !isDemo {
            a.calendarEventId = await CalendarService.shared.add(a, calendarIdentifier: state.settings.calendarIdentifier)
        }
        withAnimation(.smooth) {
            if let i = state.suggestions.firstIndex(where: { $0.id == s.id }) { state.suggestions[i].status = .accepted }
            state.appointments.append(a)
            state.appointments.sort { ($0.date, $0.startTime ?? "") < ($1.date, $1.startTime ?? "") }
        }
        enqueue(e)
        flash(a.calendarEventId != nil ? "Im Vault und im Kalender eingetragen" : "Wird in den Vault übernommen")
    }
}
