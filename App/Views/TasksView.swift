import SwiftUI
import TagwerkCore

struct TasksView: View {
    @Environment(Store.self) private var store
    @Binding var showSettings: Bool
    @State private var showNew = false
    @State private var editing: TaskItem?
    @State private var showDone = false

    private let order: [Quadrant] = [.urgentImportant, .important, .urgent, .neither, .backlog]

    var body: some View {
        let today = store.today
        let open = store.state.tasks.filter { !$0.completed }
        let done = store.state.tasks.filter(\.completed).sorted { ($0.completedOn ?? $0.date ?? "") > ($1.completedOn ?? $1.date ?? "") }
        NavigationStack {
            List {
                ForEach(order) { q in
                    let items = open.filter { $0.quadrant(today: today) == q }.sorted { ($0.date ?? "9999", $0.title) < ($1.date ?? "9999", $1.title) }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { task in
                                row(task)
                            }
                        } header: {
                            QuadrantHeader(quadrant: q, count: items.count)
                        }
                    }
                }
                if !done.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showDone) {
                            ForEach(done.prefix(40)) { task in
                                row(task)
                            }
                        } label: {
                            Text("Erledigt (\(done.count))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if store.state.tasks.isEmpty {
                    ContentUnavailableView {
                        Label("Keine Aufgaben", systemImage: "checklist")
                    } description: {
                        Text("Mit + legst du eine an. Sie landet als Notiz in 01 Leben/Tasks und erscheint auf deinem Board.")
                    }
                }
            }
            .navigationTitle("Aufgaben")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Einstellungen", systemImage: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNew = true
                    } label: {
                        Label("Neue Aufgabe", systemImage: "plus")
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .sheet(isPresented: $showNew) {
                TaskEditor(task: nil)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $editing) { task in
                TaskEditor(task: task)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private func row(_ task: TaskItem) -> some View {
        TaskRow(task: task, today: store.today)
            .contentShape(.rect)
            .onTapGesture { editing = task }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    store.toggleCompleted(task)
                } label: {
                    Label(task.completed ? "Offen" : "Erledigt", systemImage: task.completed ? "arrow.uturn.backward" : "checkmark")
                }
                .tint(.green)
            }
            .swipeActions(edge: .trailing) {
                Button {
                    store.toggleWichtig(task)
                } label: {
                    Label(task.wichtig ? "Nicht wichtig" : "Wichtig", systemImage: task.wichtig ? "star.slash" : "star.fill")
                }
                .tint(.orange)
                Button {
                    editing = task
                } label: {
                    Label("Bearbeiten", systemImage: "pencil")
                }
                .tint(.gray)
            }
    }
}

struct QuadrantHeader: View {
    var quadrant: Quadrant
    var count: Int

    private var color: Color {
        switch quadrant {
        case .urgentImportant: return .red
        case .important: return .orange
        case .urgent: return .blue
        case .neither: return .gray
        case .backlog: return .secondary
        case .done: return .green
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(quadrant.title)
            Spacer()
            Text("\(count)").monospacedDigit()
        }
        .font(.footnote.weight(.semibold))
        .accessibilityElement(children: .combine)
    }
}

struct TaskRow: View {
    @Environment(Store.self) private var store
    var task: TaskItem
    var today: String

    var body: some View {
        let overdue = !task.completed && (task.date.map { $0 < today } ?? false)
        HStack(alignment: .top, spacing: 12) {
            Button {
                store.toggleCompleted(task)
            } label: {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(task.completed ? Color.green : (overdue ? Color.red : Color.secondary))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: task.completed) { _, new in new }
            .accessibilityLabel(task.completed ? "Als offen markieren" : "Als erledigt markieren")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.body)
                    .strikethrough(task.completed)
                    .foregroundStyle(task.completed ? .secondary : .primary)
                HStack(spacing: 8) {
                    if let date = task.date {
                        Label(Format.due(date, today: today), systemImage: "calendar")
                            .foregroundStyle(overdue ? Color.red : Color.secondary)
                    } else if !task.completed {
                        Label("ohne Datum", systemImage: "tray")
                            .foregroundStyle(.secondary)
                    }
                    if task.isPending {
                        Label("unterwegs", systemImage: "arrow.up.circle")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .labelStyle(.titleAndIcon)
                if let notes = task.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if task.wichtig {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("wichtig")
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 2)
    }
}

struct TaskEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    var task: TaskItem?

    @State private var title = ""
    @State private var wichtig = false
    @State private var hasDate = false
    @State private var date = Date()
    @State private var notes = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titel", text: $title, axis: .vertical)
                        .font(.body.weight(.medium))
                        .focused($titleFocused)
                    Toggle(isOn: $wichtig) {
                        Label("Wichtig", systemImage: "star.fill")
                    }
                }
                Section {
                    Toggle(isOn: $hasDate.animation(.smooth)) {
                        Label("Fällig am", systemImage: "calendar")
                    }
                    if hasDate {
                        DatePicker("Datum", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .environment(\.locale, germanLocale)
                    }
                } footer: {
                    Text(hasDate
                         ? "Erinnerung am Fälligkeitstag um \(minutes(store.state.settings.taskReminderMinutes)), bei wichtigen Aufgaben zusätzlich am Vorabend."
                         : "Ohne Datum landet die Aufgabe im Backlog, wie auf deinem Board.")
                }
                if task == nil {
                    Section("Notiz") {
                        TextField("Optional", text: $notes, axis: .vertical)
                    }
                } else if let path = task?.path {
                    Section {
                        LabeledContent("Notiz im Vault", value: path.replacingOccurrences(of: "01 Leben/Tasks/", with: ""))
                    }
                }
            }
            .navigationTitle(task == nil ? "Neue Aufgabe" : "Aufgabe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(task == nil ? "Hinzufügen" : "Sichern") {
                        save()
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func minutes(_ m: Int) -> String { String(format: "%d:%02d Uhr", m / 60, m % 60) }

    private func load() {
        if let task {
            title = task.title
            wichtig = task.wichtig
            if let d = task.date.flatMap({ DayKey.date($0) }) {
                hasDate = true
                date = d
            }
        } else {
            titleFocused = true
        }
    }

    private func save() {
        let key = hasDate ? DayKey.key(for: date) : nil
        if let task {
            store.updateTask(task, title: title, date: key, wichtig: wichtig)
        } else {
            store.addTask(title: title, date: key, wichtig: wichtig, notes: notes.isEmpty ? nil : notes)
        }
        if key != nil {
            Task {
                if !(await Notifier.isAuthorized()) { _ = await Notifier.requestAuthorization() }
                store.scheduleNotifications()
            }
        }
    }
}
