import Foundation
import Observation
import SwiftUI
import TagwerkCore

enum SyncPhase: Equatable {
    case idle
    case sending
    case receiving
    case failed(String)
}

@MainActor
@Observable
final class Store {
    var state: AppState
    var selectedDay: String = DayKey.today()
    var syncPhase: SyncPhase = .idle
    var ratingInFlight: Set<String> = []
    var ratingError: [String: String] = [:]
    var mailInFlight = false
    var mailStatus: String?
    var toast: String?

    // Fitness: presentation state shared by Heute and Fitness
    var capture: FoodCapture?
    var showProfile = false
    var showRecorder = false
    var runEntry: RunEntryRequest?
    var requestedTab: AppTab?
    var fitnessPage: FitnessPage = .ernaehrung
    var foodIndexReady = false
    let recorder = RunRecorder()

    let isDemo: Bool
    let keychain = Keychain()

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored var pushTask: Task<Void, Never>?
    @ObservationIgnored private var journalTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var notifyTask: Task<Void, Never>?

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tagwerk-state.json")
    }

    init(demo: Bool = false) {
        isDemo = demo
        if demo {
            state = DemoData.state()
        } else if let data = try? Data(contentsOf: Store.fileURL), let s = try? JSONDecoder().decode(AppState.self, from: data) {
            state = s
        } else {
            state = AppState()
        }
        selectedDay = DayKey.today()
        if let page = UserDefaults.standard.string(forKey: "TWFitness").flatMap(FitnessPage.init(rawValue:)) { fitnessPage = page }
    }

    // MARK: Persistence

    func scheduleSave() {
        guard !isDemo else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        guard !isDemo else { return }
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(state) {
            try? data.write(to: Store.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    // MARK: Derived

    var today: String { DayKey.today() }
    var habits: [HabitConfig] { state.habits }

    func day(_ key: String) -> DayEntry { state.days[key] ?? DayEntry(date: key) }

    func doneDates(_ habit: String) -> [String] {
        state.days.values.filter { $0.habits[habit] == true }.map(\.date)
    }

    func streak(_ h: HabitConfig, upTo key: String) -> StreakInfo {
        Streaks.compute(done: doneDates(h.key).filter { $0 <= key }, today: key, tolerance: h.toleranceDays, alive: h.aliveDays)
    }

    func weekCount(_ h: HabitConfig, for key: String) -> Int {
        Streaks.weekCount(done: Set(doneDates(h.key)), today: key)
    }

    var ratedDays: [DayEntry] {
        state.days.values.filter { $0.ratingValue != nil }.sorted { $0.date < $1.date }
    }

    var averageRating: Double? {
        let r = ratedDays.compactMap(\.ratingValue)
        return r.isEmpty ? nil : r.reduce(0, +) / Double(r.count)
    }

    var openTasks: [TaskItem] { state.tasks.filter { !$0.completed } }

    var overdueCount: Int {
        openTasks.filter { t in t.date.map { $0 < today } ?? false }.count
    }

    var openSuggestions: [Suggestion] {
        state.suggestions.filter { $0.status == .open && $0.date >= today }.sorted { ($0.date, $0.startTime ?? "") < ($1.date, $1.startTime ?? "") }
    }

    var isConnected: Bool {
        state.settings.github.isComplete && keychain.has(SecretKey.githubToken) && keychain.has(SecretKey.passphrase)
    }

    /// Events sent but not yet confirmed by the plugin.
    var awaitingVault: Int {
        var ids = Set<String>()
        for d in state.days.values { for m in d.pending.values { ids.insert(m.eventId) } }
        for t in state.tasks { for m in t.pending.values { ids.insert(m.eventId) } }
        for a in state.appointments { if let m = a.pending { ids.insert(m.eventId) } }
        ids.formUnion(fitnessAwaiting)
        let unsent = Set(state.outbox.map(\.id))
        return ids.subtracting(unsent).count
    }

    // MARK: Events

    func enqueue(_ e: OutgoingEvent) {
        state.outbox.append(e)
        scheduleSave()
        schedulePush()
        scheduleNotifications()
    }

    func mark(_ e: OutgoingEvent) -> PendingMark { PendingMark(eventId: e.id, at: e.createdAt) }

    func mutateDay(_ key: String, _ body: (inout DayEntry) -> Void) {
        var d = day(key)
        body(&d)
        state.days[key] = d
    }

    // MARK: Day

    func toggleHabit(_ habit: String, on key: String) {
        let newValue = !(day(key).habits[habit] ?? false)
        setHabit(habit, newValue, on: key, manual: true)
    }

    func setHabit(_ habit: String, _ value: Bool, on key: String, manual: Bool) {
        let e = EventFactory.dayPatch(date: key, habits: [habit: value])
        mutateDay(key) { d in
            d.habits[habit] = value
            d.pending["habit.\(habit)"] = mark(e)
            if manual {
                d.aiHabits.removeAll { $0 == habit }
                if !d.manualHabits.contains(habit) { d.manualHabits.append(habit) }
            }
        }
        enqueue(e)
    }

    /// Slider: the user's value always wins over the AI.
    func setManualRating(_ value: Double, on key: String) {
        let s = RatingScale.format(value)
        let e = EventFactory.dayPatch(date: key, rating: .set(s), ratingSource: .set(.manual))
        mutateDay(key) { d in
            d.rating = s
            d.ratingSource = .manual
            d.pending["rating"] = mark(e)
            d.pending["ratingSource"] = mark(e)
        }
        enqueue(e)
    }

    func revertToAI(on key: String) {
        guard let ai = day(key).ratingAI else { return }
        let e = EventFactory.dayPatch(date: key, rating: .set(ai), ratingSource: .set(.ai))
        mutateDay(key) { d in
            d.rating = ai
            d.ratingSource = .ai
            d.pending["rating"] = mark(e)
            d.pending["ratingSource"] = mark(e)
        }
        enqueue(e)
    }

    func setWeight(_ raw: String, on key: String) {
        let cleaned = raw.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        let value: String? = Double(cleaned).flatMap { (20...400).contains($0) ? String(format: "%.1f", $0) : nil }
        guard value != day(key).weight else { return }
        let e = EventFactory.dayPatch(date: key, weight: value.map { .set($0) } ?? .clear)
        mutateDay(key) { d in
            d.weight = value
            d.pending["weight"] = mark(e)
        }
        enqueue(e)
    }

    /// Typing only updates local state; the vault gets the text after a pause.
    func updateJournal(_ text: String, on key: String) {
        guard text != day(key).journal else { return }
        mutateDay(key) { d in
            d.journal = text
            d.journalDirty = true
        }
        scheduleSave()
        journalTasks[key]?.cancel()
        journalTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.commitJournal(on: key)
        }
    }

    func commitJournal(on key: String) {
        journalTasks[key]?.cancel()
        journalTasks[key] = nil
        let d = day(key)
        guard d.journalDirty else { return }
        let e = EventFactory.journal(date: key, text: d.journal, baseHash: d.journalBaseHash)
        mutateDay(key) { d in
            d.journalDirty = false
            d.journalBaseHash = TagwerkCrypto.journalHash(d.journal)
            d.pending["journal"] = mark(e)
        }
        enqueue(e)
        if state.settings.autoRate { autoRateIfUseful(key) }
    }

    func commitAllJournals() {
        for (key, d) in state.days where d.journalDirty { commitJournal(on: key) }
    }

    // MARK: Tasks

    func addTask(title: String, date: String?, wichtig: Bool, notes: String?) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let id = UUID().uuidString.lowercased()
        let e = EventFactory.taskCreate(taskId: id, title: t, created: today, date: date, wichtig: wichtig, notes: notes)
        var item = TaskItem(id: id, taskId: id, path: nil, title: t, created: today, date: date, completed: false, wichtig: wichtig, notes: notes)
        item.pending["create"] = mark(e)
        withAnimation(.smooth) { state.tasks.append(item) }
        enqueue(e)
    }

    private func patchTask(_ id: String, fields: [String], completed: Bool? = nil, wichtig: Bool? = nil,
                           date: FieldUpdate<String> = .unchanged, title: String? = nil, apply: (inout TaskItem) -> Void) {
        guard let i = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        let t = state.tasks[i]
        let e = EventFactory.taskPatch(taskId: t.taskId, path: t.path, completed: completed, wichtig: wichtig, date: date, title: title)
        var copy = t
        apply(&copy)
        for f in fields { copy.pending[f] = mark(e) }
        state.tasks[i] = copy
        enqueue(e)
    }

    func toggleCompleted(_ task: TaskItem) {
        let value = !task.completed
        withAnimation(.smooth) {
            patchTask(task.id, fields: ["completed"], completed: value) { t in
                t.completed = value
                t.completedOn = value ? today : nil
            }
        }
    }

    func toggleWichtig(_ task: TaskItem) {
        let value = !task.wichtig
        withAnimation(.smooth) {
            patchTask(task.id, fields: ["wichtig"], wichtig: value) { $0.wichtig = value }
        }
    }

    func updateTask(_ task: TaskItem, title: String, date: String?, wichtig: Bool) {
        var fields: [String] = []
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleChange: String? = (newTitle.isEmpty || newTitle == task.title) ? nil : newTitle
        if titleChange != nil { fields.append("title") }
        let dateChange: FieldUpdate<String> = date == task.date ? .unchanged : (date.map { .set($0) } ?? .clear)
        if date != task.date { fields.append("date") }
        let wichtigChange: Bool? = wichtig == task.wichtig ? nil : wichtig
        if wichtigChange != nil { fields.append("wichtig") }
        guard !fields.isEmpty else { return }
        withAnimation(.smooth) {
            patchTask(task.id, fields: fields, wichtig: wichtigChange, date: dateChange, title: titleChange) { t in
                if let titleChange { t.title = titleChange }
                t.date = date
                t.wichtig = wichtig
            }
        }
    }

    // MARK: Notifications

    func scheduleNotifications() {
        guard !isDemo else { return }
        notifyTask?.cancel()
        notifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            await Notifier.reschedule(state: self.state, overdue: self.overdueCount)
        }
    }

    func flash(_ message: String) {
        withAnimation(.snappy) { toast = message }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard let self, self.toast == message else { return }
            withAnimation(.snappy) { self.toast = nil }
        }
    }
}
