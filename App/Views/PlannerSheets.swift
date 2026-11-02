import SwiftUI
import TagwerkCore

struct PlannerEntrySheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let entry: PlannerEntry
    let onNewExam: (PlannerDraft) -> Void
    @State private var reason = ""
    @State private var confirmDelete = false

    private var current: PlannerEntry {
        store.plannerEntries(on: entry.date).first { $0.id == entry.id } ?? entry
    }

    var body: some View {
        let e = current
        NavigationStack {
            List {
                Section {
                    PlannerSheetHeader(entry: e, lessons: store.state.untis.lessonNumbers(start: e.start, end: e.end))
                }
                if let p = e.period {
                    Section("Unterricht") {
                        LabeledContent("Fach", value: p.subjectLong ?? p.subject ?? "–")
                        if let t = p.teacher ?? p.teacherOld {
                            LabeledContent("Lehrkraft", value: p.teacherOld.map { p.teacher == nil ? "\($0) (fehlt)" : "\(t) statt \($0)" } ?? t)
                        }
                        if let r = p.room ?? p.roomOld {
                            LabeledContent("Raum", value: p.roomOld.map { p.room == nil ? "\($0) (entfällt)" : "\(r) statt \($0)" } ?? r)
                        }
                    }
                }
                if let a = e.appointment {
                    Section("Termin") {
                        if let loc = a.location { LabeledContent("Ort", value: loc) }
                        if let r = a.recur { LabeledContent("Wiederholung", value: recurrenceText(r)) }
                        if let s = a.subject { LabeledContent("Fach", value: s) }
                        if a.pending { Label("Noch nicht im Vault", systemImage: "icloud.and.arrow.up").foregroundStyle(.secondary) }
                    }
                }
                if let info = e.info, !info.isEmpty {
                    Section("Hinweis") {
                        Text(info).textSelection(.enabled)
                    }
                }
                actions(e)
            }
            .navigationTitle(kindTitle(e))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .onAppear {
                if case .absent(let r) = e.mark { reason = r } else if case .uni = e.mark { reason = "Uni" }
            }
            .confirmationDialog("Termin löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(e.appointment?.recur != nil ? "Ganze Reihe löschen" : "Löschen", role: .destructive) {
                    if let id = e.appointmentID { store.deleteAppointment(id) }
                    dismiss()
                }
            } message: {
                Text("Die Notiz in 01 Leben/Termine wandert in den Papierkorb von Obsidian.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func actions(_ e: PlannerEntry) -> some View {
        switch e.kind {
        case .lesson, .exam, .event:
            Section {
                if e.mark == .cancelledByMe || e.mark == .present || isAbsent(e.mark) {
                    Button { store.setMark(e, to: nil) } label: { Label("Wie im Stundenplan", systemImage: "arrow.uturn.backward") }
                }
                if e.mark != .cancelledByMe && e.mark != .cancelledBySchool {
                    Button { store.setMark(e, to: "entfall") } label: { Label("Entfall eintragen", systemImage: "xmark.circle") }
                }
                if isUni(e.mark) {
                    Button { store.setMark(e, to: "anwesend") } label: { Label("Ich gehe trotzdem hin", systemImage: "checkmark.circle") }
                }
                HStack {
                    TextField("Grund, z. B. Uni oder Arzt", text: $reason)
                    Button(isAbsent(e.mark) ? "Ändern" : "Nicht da") {
                        store.setMark(e, to: "abwesend", reason: reason.isEmpty ? "nicht da" : reason)
                    }
                    .buttonStyle(.bordered)
                }
            } header: {
                Text("Für mich")
            } footer: {
                Text("Landet in Obsidian in der Notiz Stundenplan-Änderungen. Der Stundenplan in WebUntis bleibt unverändert.")
            }
            if e.kind != .event {
                Section {
                    Button {
                        onNewExam(examDraft(e))
                    } label: {
                        Label("Klausur in \(e.period?.subjectLong ?? e.short ?? "diesem Fach") eintragen", systemImage: "pencil.and.list.clipboard")
                    }
                }
            }
        case .appointment, .uni, .klausur:
            Section {
                if e.appointment?.recur != nil {
                    if e.mark == .cancelledByMe {
                        Button { store.setMark(e, to: nil) } label: { Label("Findet diesmal doch statt", systemImage: "arrow.uturn.backward") }
                    } else {
                        Button { store.setMark(e, to: "entfall") } label: { Label("Fällt diesmal aus", systemImage: "xmark.circle") }
                    }
                }
                if e.appointmentID != nil {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Löschen", systemImage: "trash") }
                }
            }
        case .suggestion:
            if let s = store.state.suggestions.first(where: { $0.id == e.suggestionID }) {
                Section {
                    LabeledContent("Quelle", value: s.mailbox)
                    if !s.subject.isEmpty { LabeledContent("Betreff", value: s.subject) }
                    if !s.context.isEmpty { Text(s.context).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    Button {
                        Task { await store.accept(s) }
                        dismiss()
                    } label: { Label("In den Vault übernehmen", systemImage: "checkmark.circle.fill") }
                    Button(role: .destructive) {
                        store.dismiss(s)
                        dismiss()
                    } label: { Label("Ignorieren", systemImage: "eye.slash") }
                }
            }
        case .holiday:
            EmptyView()
        }
    }

    private func isUni(_ m: PlannerEntry.Mark) -> Bool {
        if case .uni = m { return true }
        return false
    }

    private func isAbsent(_ m: PlannerEntry.Mark) -> Bool {
        if case .absent = m { return true }
        return false
    }

    private func kindTitle(_ e: PlannerEntry) -> String {
        switch e.kind {
        case .lesson: return "Stunde"
        case .exam, .klausur: return "Klausur"
        case .event: return "Veranstaltung"
        case .uni: return "Uni"
        case .appointment: return "Termin"
        case .suggestion: return "Vorschlag"
        case .holiday: return "Ferien"
        }
    }

    private func recurrenceText(_ r: Recurrence) -> String {
        let days = r.days.sorted().map { PlannerStyle.weekdayShort[max(0, min(6, $0 - 1))] }.joined(separator: ", ")
        return "jede Woche \(days), bis \(DayKey.shortGerman(r.until))"
    }

    private func examDraft(_ e: PlannerEntry) -> PlannerDraft {
        var d = PlannerDraft()
        d.kind = .klausur
        d.subject = e.period?.subjectLong ?? e.short ?? ""
        let day = DayKey.date(e.date) ?? Date()
        d.date = day
        let cal = Calendar.current
        let s = e.start ?? 8 * 60
        let en = e.end ?? s + 90
        d.start = cal.date(bySettingHour: s / 60, minute: s % 60, second: 0, of: day) ?? day
        d.end = cal.date(bySettingHour: en / 60, minute: en % 60, second: 0, of: day) ?? day
        d.until = day
        return d
    }
}

struct PlannerSheetHeader: View {
    let entry: PlannerEntry
    let lessons: String?

    var body: some View {
        let tint = PlannerStyle.color(entry)
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title)
                .font(.title2.weight(.bold))
                .strikethrough(entry.isOff)
            Text([PlannerStyle.dayFormat.string(from: DayKey.date(entry.date) ?? Date()), PlannerStyle.time(entry), lessons]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let status = statusText {
                Text(status)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.14), in: .capsule)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String? {
        switch entry.mark {
        case .cancelledBySchool: return "Entfall laut WebUntis"
        case .cancelledByMe: return entry.kind == .lesson ? "Entfall, selbst eingetragen" : "Fällt diesmal aus"
        case .absent(let r): return "Nicht da: \(r)"
        case .uni(let t): return "Überschneidet sich mit \(t)"
        case .present: return "Du gehst hin, trotz Termin"
        case .changed: return "Geändert laut WebUntis"
        case .none: return entry.kind == .suggestion ? "Vorschlag, noch nicht übernommen" : nil
        }
    }
}

struct PlannerEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: PlannerDraft
    @State private var saving = false

    private var canSave: Bool {
        draft.kind == .klausur ? !draft.subject.trimmingCharacters(in: .whitespaces).isEmpty : !draft.title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        let subjects = store.state.untis.subjects
        NavigationStack {
            Form {
                Section {
                    Picker("Art", selection: $draft.kind) {
                        ForEach(PlannerDraft.Kind.allCases) { k in Text(k.label).tag(k) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    if draft.kind == .klausur {
                        if subjects.isEmpty {
                            TextField("Fach, z. B. Chemie", text: $draft.subject)
                        } else {
                            Picker("Fach", selection: $draft.subject) {
                                Text("Bitte wählen").tag("")
                                ForEach(subjects, id: \.self) { s in Text(s).tag(s) }
                            }
                        }
                        TextField("Thema (optional)", text: $draft.title)
                    } else {
                        TextField(draft.kind == .uni ? "Veranstaltung, z. B. Analysis I" : "Titel", text: $draft.title)
                    }
                    TextField(draft.kind == .uni ? "Hörsaal" : "Ort (optional)", text: $draft.location)
                }
                Section {
                    DatePicker("Datum", selection: $draft.date, displayedComponents: .date)
                    Toggle("Ganztägig", isOn: $draft.allDay)
                    if !draft.allDay {
                        DatePicker("Beginn", selection: $draft.start, displayedComponents: .hourAndMinute)
                        DatePicker("Ende", selection: $draft.end, displayedComponents: .hourAndMinute)
                    }
                }
                if draft.kind != .klausur {
                    Section {
                        Toggle("Jede Woche", isOn: $draft.weekly.animation(.smooth))
                        if draft.weekly {
                            WeekdayPicker(selection: $draft.weekdays)
                            DatePicker("Bis", selection: $draft.until, in: draft.date..., displayedComponents: .date)
                        }
                    } footer: {
                        Text(draft.kind == .uni
                             ? "Überschneidet sich die Veranstaltung mit Unterricht, zeigt der Planer die Stunden als „Uni“. Einzelne Stunden kannst du trotzdem als besucht markieren."
                             : "Wiederkehrende Termine landen als eine Notiz im Format von Full Calendar.")
                    }
                }
                Section("Notizen") {
                    TextField("Optional", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            .navigationTitle(draft.kind == .klausur ? "Neue Klausur" : draft.kind == .uni ? "Uni-Veranstaltung" : "Neuer Termin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        saving = true
                        Task {
                            await store.addPlannerEntry(adjusted)
                            dismiss()
                        }
                    }
                    .disabled(!canSave || saving)
                }
            }
            .onChange(of: draft.date) { old, new in
                // Keep the times on the new day.
                let cal = Calendar.current
                for keyPath in [\PlannerDraft.start, \PlannerDraft.end] {
                    let t = cal.dateComponents([.hour, .minute], from: draft[keyPath: keyPath])
                    draft[keyPath: keyPath] = cal.date(bySettingHour: t.hour ?? 8, minute: t.minute ?? 0, second: 0, of: new) ?? new
                }
                if draft.until < new { draft.until = new }
            }
        }
    }

    /// Times always on the chosen day; exams carry the topic in the notes.
    private var adjusted: PlannerDraft {
        var d = draft
        if d.kind == .klausur {
            let topic = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
            d.title = "Klausur"
            d.notes = [topic, d.notes.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: "\n")
            d.weekly = false
        }
        if d.weekly && d.weekdays.isEmpty { d.weekdays = [Planner.weekday(DayKey.key(for: d.date))] }
        return d
    }
}

struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { d in
                let on = selection.contains(d)
                Button {
                    if on { selection.remove(d) } else { selection.insert(d) }
                } label: {
                    Text(PlannerStyle.weekdayShort[d - 1])
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(on ? Color.accentColor : Color.secondary.opacity(0.12), in: .capsule)
                        .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

struct UntisMessagesView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(store.state.untis.messages) { m in
                NavigationLink {
                    UntisMessageDetail(message: m)
                } label: {
                    UntisMessageRow(message: m)
                }
            }
            .listStyle(.plain)
            .overlay {
                if store.state.untis.messages.isEmpty {
                    ContentUnavailableView("Keine Mitteilungen", systemImage: "envelope.open",
                                           description: Text(store.untisReady ? "In WebUntis liegt nichts im Posteingang." : "Richte WebUntis in den Einstellungen ein."))
                }
            }
            .navigationTitle("Mitteilungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
            }
            .refreshable { await store.refreshUntis(force: true) }
        }
    }
}

enum UntisFormat {
    static func sent(_ s: String) -> String {
        guard let d = UntisDates.formatter.date(from: s) else { return s }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = Calendar.current.isDateInToday(d) ? "'heute,' HH:mm" : "dd.MM.yy, HH:mm"
        return f.string(from: d)
    }
}

struct UntisMessageRow: View {
    let message: UntisMessage

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(message.read ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.sender.isEmpty ? "WebUntis" : message.sender)
                        .font(.subheadline.weight(message.read ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(UntisFormat.sent(message.sent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(message.subject)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(message.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

struct UntisMessageDetail: View {
    @Environment(Store.self) private var store
    let message: UntisMessage
    @State private var text: String?
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(message.subject)
                    .font(.title3.weight(.bold))
                Text([message.sender, UntisFormat.sent(message.sent)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if message.attachments {
                    Label("Mit Anhang, nur in WebUntis", systemImage: "paperclip")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Divider()
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                }
                Text(text ?? message.preview)
                    .textSelection(.enabled)
                Text("Termine in Mitteilungen erscheinen als Vorschläge im Planer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            text = await store.untisMessageText(message)
            loading = false
        }
    }
}

struct UpcomingExamsCard: View {
    @Environment(Store.self) private var store

    var body: some View {
        let exams = store.upcomingExams(days: 21)
        if !exams.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "Nächste Klausuren", systemImage: "pencil.and.list.clipboard")
                ForEach(exams.prefix(3)) { e in
                    Button {
                        store.plannerDay = e.date
                        store.requestedTab = .planer
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(.subheadline.weight(.semibold))
                                Text([PlannerStyle.dayFormat.string(from: DayKey.date(e.date) ?? Date()), e.start.map(Planner.clock)]
                                    .compactMap { $0 }.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(countdown(e.date))
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color(hex: "#E5484D"))
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .card()
        }
    }

    private func countdown(_ date: String) -> String {
        let days = DayKey.distance(from: store.today, to: date) ?? 0
        switch days {
        case 0: return "heute"
        case 1: return "morgen"
        default: return "in \(days) Tagen"
        }
    }
}
