import SwiftUI
import TagwerkCore

struct AppointmentsView: View {
    @Environment(Store.self) private var store
    @Binding var showSettings: Bool
    @State private var showPaste = false
    @State private var editing: Suggestion?

    var body: some View {
        let suggestions = store.openSuggestions
        let upcoming = store.state.appointments.filter { $0.date >= store.today }
        NavigationStack {
            List {
                if store.mailInFlight || store.mailStatus != nil {
                    Section {
                        HStack(spacing: 10) {
                            if store.mailInFlight { ProgressView().controlSize(.small) }
                            Text(store.mailStatus ?? "Prüfe Postfächer …")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions) { s in
                            SuggestionRow(suggestion: s, edit: { editing = s })
                                .swipeActions(edge: .trailing) {
                                    Button {
                                        store.dismiss(s)
                                    } label: {
                                        Label("Ignorieren", systemImage: "eye.slash")
                                    }
                                    .tint(.gray)
                                }
                        }
                    } header: {
                        Text("Neu aus deinen Mails")
                    } footer: {
                        Text("Übernommene Termine landen als Notiz in 01 Leben/Termine und, wenn eingestellt, in deinem Kalender.")
                    }
                }
                if !upcoming.isEmpty {
                    Section("Übernommen") {
                        ForEach(upcoming) { a in
                            AppointmentRow(appointment: a)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if suggestions.isEmpty && upcoming.isEmpty && !store.mailInFlight {
                    ContentUnavailableView {
                        Label("Keine Termine", systemImage: "calendar.badge.checkmark")
                    } description: {
                        Text(store.configuredMailAccounts.isEmpty
                             ? "Richte Gmail und die Schul-Mail in den Einstellungen ein. Die App liest nur und markiert nichts als gelesen."
                             : "In den letzten \(store.state.settings.mailLookbackDays) Tagen stand in deinen Mails kein neuer Termin.")
                    } actions: {
                        if store.configuredMailAccounts.isEmpty {
                            Button("Postfächer einrichten") { showSettings = true }
                                .buttonStyle(.bordered)
                        } else {
                            Button("Jetzt prüfen") { Task { await store.checkMail() } }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .refreshable { await store.checkMail() }
            .navigationTitle("Termine")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Einstellungen", systemImage: "gearshape")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showPaste = true
                    } label: {
                        Label("Text einfügen", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        Task { await store.checkMail() }
                    } label: {
                        Label("Postfächer prüfen", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.mailInFlight)
                }
            }
            .sheet(isPresented: $showPaste) {
                PasteSheet()
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $editing) { s in
                SuggestionEditor(original: s)
            }
        }
    }
}

struct DateBadge: View {
    var date: String

    var body: some View {
        let d = DayKey.date(date)
        VStack(spacing: 0) {
            Text(d?.formatted(.dateTime.month(.abbreviated).locale(germanLocale)).uppercased() ?? "")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.red)
            Text("\(Int(date.suffix(2)) ?? 0)")
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .frame(width: 48, height: 52)
        .background(.thinMaterial, in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct SuggestionRow: View {
    @Environment(Store.self) private var store
    var suggestion: Suggestion
    var edit: () -> Void
    @State private var accepting = false

    var body: some View {
        let s = suggestion
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                DateBadge(date: s.date)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.headline)
                    Text(Format.when(date: s.date, start: s.startTime, end: s.endTime, allDay: s.allDay))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let loc = s.location {
                        Label(loc, systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if s.confidence < 0.6 {
                    Text("unsicher")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.18), in: .capsule)
                }
            }
            if !s.context.isEmpty {
                Text("„\(s.context)“")
                    .font(.footnote)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Label([s.mailbox, s.from, s.subject].filter { !$0.isEmpty }.joined(separator: " · "), systemImage: "envelope")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            HStack(spacing: 12) {
                Button {
                    accepting = true
                    Task {
                        await store.accept(s)
                        accepting = false
                    }
                } label: {
                    if accepting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Übernehmen", systemImage: "checkmark")
                    }
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
                .disabled(accepting)
                Button("Bearbeiten", action: edit)
                    .buttonStyle(.borderless)
                Spacer()
            }
            .font(.subheadline.weight(.medium))
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}

struct AppointmentRow: View {
    var appointment: Appointment

    var body: some View {
        let a = appointment
        HStack(spacing: 12) {
            DateBadge(date: a.date)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.title).font(.headline)
                Text(Format.when(date: a.date, start: a.startTime, end: a.endTime, allDay: a.allDay))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if let loc = a.location {
                        Label(loc, systemImage: "mappin.and.ellipse")
                    }
                    if a.calendarEventId != nil {
                        Label("im Kalender", systemImage: "calendar.badge.checkmark")
                    }
                    if a.pending != nil {
                        Label("unterwegs", systemImage: "arrow.up.circle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct PasteSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                    PasteButton(payloadType: String.self) { strings in
                        text = strings.joined(separator: "\n")
                    }
                } footer: {
                    Text("Zum Beispiel eine Nachricht aus dem Schulportal oder einem Messenger. Gefundene Termine erscheinen als Vorschläge.")
                }
                if let result {
                    Section { Text(result) }
                }
            }
            .navigationTitle("Text einfügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Termine suchen") {
                        Task {
                            let n = await store.extractFromText(text)
                            if n > 0 {
                                dismiss()
                            } else {
                                result = "Kein Termin gefunden. Steht ein Datum wie 12.11. oder 12. November im Text?"
                            }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.mailInFlight)
                }
            }
        }
    }
}

struct SuggestionEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    var original: Suggestion

    @State private var title = ""
    @State private var day = Date()
    @State private var allDay = true
    @State private var start = Date()
    @State private var end = Date()
    @State private var location = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titel", text: $title)
                    TextField("Ort", text: $location)
                }
                Section {
                    DatePicker("Datum", selection: $day, displayedComponents: .date)
                    Toggle("Ganztägig", isOn: $allDay.animation(.smooth))
                    if !allDay {
                        DatePicker("Beginn", selection: $start, displayedComponents: .hourAndMinute)
                        DatePicker("Ende", selection: $end, displayedComponents: .hourAndMinute)
                    }
                }
                .environment(\.locale, germanLocale)
                if !original.context.isEmpty {
                    Section("Textstelle") {
                        Text(original.context).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Termin prüfen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Übernehmen") {
                        var v = original
                        v.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? original.title : title
                        v.date = DayKey.key(for: day)
                        v.allDay = allDay
                        v.startTime = allDay ? nil : hhmm(start)
                        v.endTime = allDay ? nil : hhmm(end)
                        v.location = location.isEmpty ? nil : location
                        let edited = v
                        Task {
                            await store.accept(original, edited: edited)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func hhmm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private func at(_ s: String?, on base: Date) -> Date? {
        guard let s else { return nil }
        let p = s.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: base)
    }

    private func load() {
        title = original.title
        location = original.location ?? ""
        day = DayKey.date(original.date) ?? Date()
        allDay = original.allDay || original.startTime == nil
        start = at(original.startTime, on: day) ?? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        end = at(original.endTime, on: day) ?? start.addingTimeInterval(3600)
    }
}
