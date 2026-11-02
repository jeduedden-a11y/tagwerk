import Foundation
import SwiftUI
import TagwerkCore

extension Store {
    var github: GitHubClient? {
        guard let token = keychain.get(SecretKey.githubToken), !token.isEmpty, state.settings.github.isComplete else { return nil }
        return GitHubClient(config: state.settings.github, token: token)
    }

    var passphrase: String? { keychain.get(SecretKey.passphrase) }

    func schedulePush(after seconds: Double = 2.5) {
        guard !isDemo else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await self.push()
        }
    }

    /// Full round trip: send pending events, then fetch the vault's state.
    func syncNow() async {
        guard !isDemo else { return }
        commitAllJournals()
        pushTask?.cancel()
        await push()
        await pull()
        // Timetable and notes load after the daily data, without holding up the sync status.
        Task {
            await refreshUntis()
            await syncWiki()
        }
    }

    func push() async {
        guard !isDemo, !state.outbox.isEmpty else { return }
        guard let gh = github, let pass = passphrase, !pass.isEmpty else { return }
        // Events of families the vault's plugin has not announced stay on the phone until it is updated,
        // an older plugin would acknowledge them as failed and they would be lost.
        let features = Set(state.bridgeFeatures)
        let batchEvents = state.outbox.filter { e in e.requiredFeature.map { features.contains($0) } ?? true }
        guard !batchEvents.isEmpty else { return }
        let saltB64 = state.settings.deviceSalt
        syncPhase = .sending
        do {
            let envelope: Data = try await Task.detached(priority: .userInitiated) {
                let plain = try EventFactory.batch(batchEvents, device: "iPhone")
                let salt = Data(base64Encoded: saltB64) ?? TagwerkCrypto.randomBytes(16)
                return try TagwerkCrypto.seal(plain, passphrase: pass, kind: .inbox, salt: salt)
            }.value
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS'Z'"
            let name = "inbox/\(f.string(from: Date()))_\(UUID().uuidString.prefix(8).lowercased()).tw"
            try await gh.createFile(path: name, data: envelope, message: "tagwerk: \(batchEvents.count) Einträge vom iPhone")
            let sent = Set(batchEvents.map(\.id))
            state.outbox.removeAll { sent.contains($0.id) }
            state.lastPush = Date()
            state.lastSyncError = nil
            syncPhase = .idle
            saveNow()
        } catch {
            state.lastSyncError = error.localizedDescription
            syncPhase = .failed(error.localizedDescription)
            scheduleSave()
        }
    }

    func pull() async {
        guard !isDemo, let gh = github, let pass = passphrase, !pass.isEmpty else { return }
        syncPhase = .receiving
        do {
            guard let file = try await gh.getFile(path: "snapshot.tw", etag: state.snapshotEtag) else {
                state.lastPull = Date()
                syncPhase = .idle
                return
            }
            let data = file.data
            let snapshot: Snapshot = try await Task.detached(priority: .userInitiated) {
                let plain = try TagwerkCrypto.open(data, passphrase: pass, kind: .snapshot)
                return try JSONDecoder().decode(Snapshot.self, from: plain)
            }.value
            let hadFeatures = Set(state.bridgeFeatures)
            withAnimation(.smooth) { apply(snapshot) }
            state.snapshotEtag = file.etag
            // The plugin was just updated: send what was held back for it.
            if !Set(state.bridgeFeatures).subtracting(hadFeatures).isEmpty, heldForPlugin < state.outbox.count { schedulePush(after: 0.5) }
            state.lastPull = Date()
            state.lastSyncError = nil
            syncPhase = .idle
            saveNow()
            scheduleNotifications()
        } catch {
            state.lastSyncError = error.localizedDescription
            syncPhase = .failed(error.localizedDescription)
        }
    }

    /// Checks token, repo visibility and passphrase against an existing snapshot.
    func testConnection() async -> String {
        guard let gh = github else { return "Besitzer, Repo und Token fehlen noch." }
        guard let pass = passphrase, !pass.isEmpty else { return "Passphrase fehlt noch." }
        do {
            try await gh.checkRepo()
            if let file = try await gh.getFile(path: "snapshot.tw") {
                let data = file.data
                _ = try await Task.detached { try TagwerkCrypto.open(data, passphrase: pass, kind: .snapshot) }.value
                return "Verbunden. Der Stand aus Obsidian lässt sich entschlüsseln."
            }
            return "Verbunden. Noch kein Stand vom PC vorhanden: Plugin in Obsidian einrichten und einmal synchronisieren."
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Merge

    /// Vault state wins, except for fields with local changes the plugin has not acknowledged yet.
    func apply(_ snap: Snapshot) {
        let applied = Set(snap.applied)
        let unsent = Set(state.outbox.map(\.id))
        let staleCutoff = Date().addingTimeInterval(-14 * 86_400)
        func pending(_ m: PendingMark?) -> Bool {
            guard let m else { return false }
            if applied.contains(m.eventId) { return false }
            if unsent.contains(m.eventId) { return true }
            return m.at > staleCutoff
        }

        if !snap.habits.isEmpty { state.habits = snap.habits }

        for sd in snap.days {
            var d = state.days[sd.date] ?? DayEntry(date: sd.date)
            for h in state.habits {
                let key = "habit.\(h.key)"
                if !pending(d.pending[key]) {
                    d.habits[h.key] = sd.habits[h.key] ?? false
                    d.pending[key] = nil
                }
            }
            if !pending(d.pending["rating"]) { d.rating = sd.rating; d.pending["rating"] = nil }
            if !pending(d.pending["ratingAI"]) { d.ratingAI = sd.ratingAI; d.pending["ratingAI"] = nil }
            if !pending(d.pending["ratingSource"]) { d.ratingSource = sd.ratingSource; d.pending["ratingSource"] = nil }
            if !pending(d.pending["ratingReason"]) { d.ratingReason = sd.ratingReason; d.pending["ratingReason"] = nil }
            if !pending(d.pending["weight"]) { d.weight = sd.weight; d.pending["weight"] = nil }
            if sd.hasText {
                if !pending(d.pending["journal"]) && !d.journalDirty {
                    d.journal = sd.journal ?? ""
                    d.journalBaseHash = sd.journalHash
                    d.pending["journal"] = nil
                }
                d.note = sd.note
            }
            state.days[sd.date] = d
        }

        var merged: [TaskItem] = []
        var matched = Set<String>()
        for st in snap.tasks {
            let local = state.tasks.first { t in
                (t.taskId != nil && t.taskId == st.taskId) || (t.path != nil && t.path == st.path)
            }
            var t = local ?? TaskItem(id: st.taskId ?? "vault:\(st.path)", taskId: st.taskId, path: st.path, title: st.title,
                                      created: st.created ?? DayKey.today(), date: st.date, completed: st.completed, wichtig: st.wichtig, notes: st.notes)
            if let local { matched.insert(local.id) }
            t.path = st.path
            if t.taskId == nil { t.taskId = st.taskId }
            t.pending["create"] = nil
            if !pending(t.pending["title"]) { t.title = st.title; t.pending["title"] = nil }
            if !pending(t.pending["completed"]) {
                if st.completed && !t.completed { t.completedOn = t.completedOn ?? DayKey.today() }
                t.completed = st.completed
                t.pending["completed"] = nil
            }
            if !pending(t.pending["wichtig"]) { t.wichtig = st.wichtig; t.pending["wichtig"] = nil }
            if !pending(t.pending["date"]) { t.date = st.date; t.pending["date"] = nil }
            t.notes = st.notes
            if let c = st.created { t.created = c }
            merged.append(t)
        }
        for t in state.tasks where !matched.contains(t.id) && pending(t.pending["create"]) {
            merged.append(t)
        }
        state.tasks = merged

        var appts: [Appointment] = []
        var seen = Set<String>()
        for (id, m) in state.deletedAppointments where !pending(m) { state.deletedAppointments[id] = nil }
        for sa in snap.appointments {
            var a = state.appointments.first { ($0.id == sa.apptId) || ($0.path != nil && $0.path == sa.path) }
                ?? Appointment(id: sa.apptId ?? "vault:\(sa.path)", title: sa.title, date: sa.date, startTime: sa.startTime,
                               endTime: sa.endTime, allDay: sa.allDay, location: sa.location, path: sa.path)
            if state.deletedAppointments[a.id] != nil { continue }
            seen.insert(a.id)
            a.category = sa.category
            a.schoolSubject = sa.subject
            a.recur = sa.recur
            a.notes = sa.notes
            a.title = sa.title
            a.date = sa.date
            a.startTime = sa.startTime
            a.endTime = sa.endTime
            a.allDay = sa.allDay
            a.location = sa.location
            a.path = sa.path
            a.pending = nil
            appts.append(a)
        }
        for a in state.appointments where !seen.contains(a.id) && pending(a.pending) {
            appts.append(a)
        }
        state.appointments = appts.sorted { ($0.date, $0.startTime ?? "") < ($1.date, $1.startTime ?? "") }

        mergeFitness(snap, isPending: pending)

        var marks: [String: SchoolOverride] = [:]
        for o in snap.schoolOverrides { marks[o.key] = o }
        for (key, m) in state.overridePending {
            if pending(m) { marks[key] = state.schoolOverrides[key] } else { state.overridePending[key] = nil }
        }
        state.schoolOverrides = marks

        state.bridgeErrors = snap.errors
        state.lastSnapshotAt = snap.generatedAt
        state.lastIngestAt = snap.lastIngestAt
    }
}
