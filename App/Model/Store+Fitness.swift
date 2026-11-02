import Foundation
import SwiftUI
import TagwerkCore

enum FitnessPage: String, CaseIterable, Identifiable {
    case ernaehrung, laufen, gewicht
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ernaehrung: return "Ernährung"
        case .laufen: return "Laufen"
        case .gewicht: return "Gewicht"
        }
    }
}

struct FoodCapture: Identifiable, Hashable {
    enum Mode: Hashable {
        case scan, search, photo, describe, manual
        case item(FoodItem, grams: Double?)
        case entry(FoodEntry)
    }
    var id = UUID()
    var mode: Mode
    var day: String
}

struct RunEntryRequest: Identifiable, Hashable {
    var id = UUID()
    var run: RunRecord?
    var date: String
}

extension Store {
    // MARK: Derived

    /// Latest weight on or before the day, from the daily notes.
    func weight(on key: String) -> Double? {
        state.days.values.filter { $0.date <= key && $0.weightValue != nil }.max { $0.date < $1.date }?.weightValue
    }

    var sortedRuns: [RunRecord] { state.runs.sorted { ($0.date, $0.path ?? $0.id) < ($1.date, $1.path ?? $1.id) } }

    func runs(on key: String) -> [RunRecord] { state.runs.filter { $0.date == key } }

    func targets(for key: String) -> NutritionTargets? {
        guard let p = state.profile, let w = weight(on: key) ?? weight(on: today) else { return nil }
        let year = Int(key.prefix(4)) ?? 2026
        let r = runs(on: key).map { (km: $0.distanceKm, seconds: $0.seconds) }
        return NutritionCalculator.targets(profile: p, weightKg: w, year: year, runs: r)
    }

    func foodDay(_ key: String) -> FoodDayState { state.food[key] ?? FoodDayState(date: key) }

    func checks(for key: String) -> [NutritionCheck] {
        guard let p = state.profile, let t = targets(for: key) else { return [] }
        return NutritionEvaluation.checks(totals: foodDay(key).totals, targets: t, profile: p)
    }

    var recentFoods: [LibraryItem] {
        state.foodLibrary.filter { $0.uses > 0 }.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    func cachedProduct(barcode: String) -> FoodItem? {
        let codes = Set(OpenFoodFacts.normalize(barcode))
        return state.foodLibrary.first { $0.item.barcode.map { codes.contains($0) } ?? false }?.item
    }

    var heldForPlugin: Int {
        let f = Set(state.bridgeFeatures)
        return state.outbox.filter { e in e.requiredFeature.map { !f.contains($0) } ?? false }.count
    }

    // MARK: Food log

    func addFood(_ entries: [FoodEntry], on key: String) {
        guard !entries.isEmpty else { return }
        var d = foodDay(key)
        d.entries.append(contentsOf: entries)
        withAnimation(.smooth) { state.food[key] = d }
        for e in entries { remember(e.item, grams: e.grams) }
        commitFood(on: key)
        flash(entries.count == 1 ? "\(entries[0].name) eingetragen" : "\(entries.count) Lebensmittel eingetragen")
    }

    func updateFood(_ entry: FoodEntry, on key: String) {
        var d = foodDay(key)
        guard let i = d.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        d.entries[i] = entry
        withAnimation(.smooth) { state.food[key] = d }
        commitFood(on: key)
    }

    func removeFood(_ id: String, on key: String) {
        var d = foodDay(key)
        d.entries.removeAll { $0.id == id }
        withAnimation(.smooth) { state.food[key] = d }
        commitFood(on: key)
    }

    /// Sends the whole day (the vault note is rebuilt from it) and re-checks the food habit.
    func commitFood(on key: String) {
        var d = foodDay(key)
        let targets = targets(for: key)
        let checks = self.checks(for: key)
        let met: Bool? = targets == nil || d.entries.isEmpty ? nil : NutritionEvaluation.met(checks)
        d.targets = targets.map { DayTargets($0, tolerance: state.profile?.tolerance ?? 10) }
        d.met = met
        let e = EventFactory.foodDay(date: key, entries: d.entries, targets: d.targets, met: met)
        d.pending = mark(e)
        state.food[key] = d
        enqueue(e)
        evaluateFoodHabit(key)
    }

    /// Targets depend on weight, profile and the day's runs; refresh a day that already has entries.
    func refreshFoodTargets(_ key: String) {
        guard !foodDay(key).entries.isEmpty else { return }
        commitFood(on: key)
    }

    func evaluateFoodHabit(_ key: String) {
        let d = foodDay(key)
        guard !d.entries.isEmpty, state.profile != nil, targets(for: key) != nil else { return }
        setAutoHabit("food", NutritionEvaluation.met(checks(for: key)), on: key)
    }

    /// The user ticked "food" by hand on this day; hand it back to the targets.
    func resumeAutoFood(_ key: String) {
        mutateDay(key) { $0.manualHabits.removeAll { $0 == "food" } }
        evaluateFoodHabit(key)
        scheduleSave()
    }

    /// Set by targets or runs, never against a value the user set by hand that day.
    func setAutoHabit(_ habit: String, _ value: Bool, on key: String) {
        let d = day(key)
        guard !d.manualHabits.contains(habit) else { return }
        if (d.habits[habit] ?? false) != value { setHabit(habit, value, on: key, manual: false) }
        mutateDay(key) { d in
            d.aiHabits.removeAll { $0 == habit }
            d.autoHabits.removeAll { $0 == habit }
            if value { d.autoHabits.append(habit) }
        }
        scheduleSave()
    }

    // MARK: Library

    func remember(_ item: FoodItem, grams: Double) {
        if let i = state.foodLibrary.firstIndex(where: { $0.id == item.id }) {
            state.foodLibrary[i].uses += 1
            state.foodLibrary[i].lastUsed = Date()
            state.foodLibrary[i].lastGrams = grams
        } else {
            state.foodLibrary.append(LibraryItem(item: item, uses: 1, lastUsed: Date(), lastGrams: grams))
        }
        trimLibrary()
        FoodDatabase.shared.index?.setPersonal(state.foodLibrary.map(\.item))
    }

    /// Products from Open Food Facts and own foods are kept, so a second scan works offline.
    func saveFood(_ item: FoodItem) {
        if let i = state.foodLibrary.firstIndex(where: { $0.id == item.id }) {
            state.foodLibrary[i].item = item
        } else {
            state.foodLibrary.append(LibraryItem(item: item))
        }
        trimLibrary()
        FoodDatabase.shared.index?.setPersonal(state.foodLibrary.map(\.item))
        scheduleSave()
    }

    func forget(_ id: String) {
        state.foodLibrary.removeAll { $0.id == id }
        FoodDatabase.shared.index?.setPersonal(state.foodLibrary.map(\.item))
        scheduleSave()
    }

    private func trimLibrary() {
        guard state.foodLibrary.count > 400 else { return }
        state.foodLibrary.sort { ($0.uses, $0.lastUsed ?? .distantPast) > ($1.uses, $1.lastUsed ?? .distantPast) }
        state.foodLibrary = Array(state.foodLibrary.prefix(400))
    }

    func loadFoodDatabase() async {
        guard !foodIndexReady else { return }
        let index = await FoodDatabase.shared.load()
        index?.setPersonal(state.foodLibrary.map(\.item))
        foodIndexReady = index != nil
    }

    // MARK: Profile

    func saveProfile(_ p: BodyProfile, weight: Double?) {
        if let weight, weight != self.weight(on: today) {
            setWeight(String(format: "%.1f", weight), on: today)
        }
        var profile = p
        profile.updated = today
        let summary = targets(for: today, profile: profile).map(profileSummary)
        let e = EventFactory.profileSet(profile, summary: summary)
        state.profile = profile
        state.profilePending = mark(e)
        enqueue(e)
        refreshFoodTargets(today)
        evaluateFoodHabit(today)
    }

    func targets(for key: String, profile: BodyProfile) -> NutritionTargets? {
        guard let w = weight(on: key) ?? weight(on: today) else { return nil }
        let r = runs(on: key).map { (km: $0.distanceKm, seconds: $0.seconds) }
        return NutritionCalculator.targets(profile: profile, weightKg: w, year: Int(key.prefix(4)) ?? 2026, runs: r)
    }

    func profileSummary(_ t: NutritionTargets) -> String {
        var goal = ""
        if t.goalKcal > 0.5 { goal = " (+\(NutritionFormat.kcal(t.goalKcal)) kcal zum Zunehmen)" }
        if t.goalKcal < -0.5 { goal = " (−\(NutritionFormat.kcal(-t.goalKcal)) kcal zum Abnehmen)" }
        return "Grundumsatz \(NutritionFormat.kcal(t.bmr)) kcal (\(t.formula)) · Bedarf \(NutritionFormat.kcal(t.tdee)) kcal · Ziel \(NutritionFormat.kcal(t.kcal - t.runKcal)) kcal\(goal) · Protein \(Int(t.protein.rounded())) g · Fett \(Int(t.fat.rounded())) g · Kohlenhydrate \(Int(t.carbs.rounded())) g · Läufe kommen am jeweiligen Tag dazu"
    }

    // MARK: Runs

    func addRun(date: String, distanceKm: Double, seconds: Int, source: String, route: [RoutePoint] = []) {
        let km = (distanceKm * 100).rounded() / 100
        guard km > 0, seconds > 0 else { return }
        let id = UUID().uuidString.lowercased()
        let gpx = route.count >= 2 ? GPX.make(route, name: "Lauf \(RunChartModel.longDate(date))") : nil
        let e = EventFactory.runAdd(runId: id, date: date, distanceKm: km, seconds: seconds, source: source, gpx: gpx)
        if route.count >= 2 { RouteStore.save(route, id: id) }
        withAnimation(.smooth) {
            state.runs.append(RunRecord(id: id, runId: id, path: nil, date: date, distanceKm: km, seconds: seconds, source: source, hasRoute: gpx != nil))
        }
        state.runPending[id] = mark(e)
        enqueue(e)
        setAutoHabit("laufen", true, on: date)
        refreshFoodTargets(date)
        flash("Lauf eingetragen: \(Format.decimal(RunTime.distance(km))) km")
    }

    func updateRun(_ run: RunRecord, date: String, distanceKm: Double, seconds: Int) {
        let km = (distanceKm * 100).rounded() / 100
        guard let i = state.runs.firstIndex(where: { $0.id == run.id }), km > 0, seconds > 0 else { return }
        if date != run.date {
            // The file name carries the date: a new note, the old one goes to the trash.
            let route = RouteStore.load(run.id)
            deleteRun(run, quiet: true)
            addRun(date: date, distanceKm: km, seconds: seconds, source: run.source ?? "manuell", route: route)
            return
        }
        let e = EventFactory.runPatch(runId: run.runId, path: run.path, distanceKm: km, seconds: seconds)
        state.runs[i].distanceKm = km
        state.runs[i].seconds = seconds
        state.runPending[run.id] = mark(e)
        enqueue(e)
        refreshFoodTargets(run.date)
    }

    func deleteRun(_ run: RunRecord, quiet: Bool = false) {
        let e = EventFactory.runPatch(runId: run.runId, path: run.path, deleted: true)
        withAnimation(.smooth) { state.runs.removeAll { $0.id == run.id } }
        state.runPending[run.id] = nil
        state.deletedRuns[run.id] = mark(e)
        RouteStore.delete(run.id)
        enqueue(e)
        if runs(on: run.date).isEmpty, day(run.date).autoHabits.contains("laufen") { setAutoHabit("laufen", false, on: run.date) }
        refreshFoodTargets(run.date)
        if !quiet { flash("Lauf gelöscht") }
    }

    // MARK: Snapshot merge

    func mergeFitness(_ snap: Snapshot, isPending: (PendingMark?) -> Bool) {
        state.bridgeFeatures = snap.features
        state.pluginVersion = snap.pluginVersion
        guard snap.features.contains("runs") || !snap.runs.isEmpty else { return }

        var merged: [RunRecord] = []
        var seen = Set<String>()
        for r in snap.runs {
            seen.insert(r.id)
            if let m = state.deletedRuns[r.id] {
                if isPending(m) { continue }
                state.deletedRuns[r.id] = nil
            }
            let local = state.runs.first { $0.id == r.id }
            if let local, isPending(state.runPending[r.id]) {
                merged.append(local)
            } else {
                var v = r
                v.source = local?.source ?? r.source
                merged.append(v)
                state.runPending[r.id] = nil
            }
        }
        for r in state.runs where !seen.contains(r.id) && isPending(state.runPending[r.id]) { merged.append(r) }
        for (id, m) in state.deletedRuns where !isPending(m) { state.deletedRuns[id] = nil }
        for (id, m) in state.runPending where !isPending(m) && !seen.contains(id) { state.runPending[id] = nil }
        state.runs = merged

        if snap.features.contains("food") {
            for fd in snap.foodDays {
                var d = state.food[fd.date] ?? FoodDayState(date: fd.date)
                if isPending(d.pending) { continue }
                d.entries = fd.entries
                d.targets = fd.targets
                d.met = fd.met
                d.pending = nil
                state.food[fd.date] = d
            }
            for (k, d) in state.food where d.pending != nil && !isPending(d.pending) { state.food[k]?.pending = nil }
        }
        if snap.features.contains("profile"), !isPending(state.profilePending) {
            if let p = snap.profile { state.profile = p }
            state.profilePending = nil
        }
    }

    var fitnessAwaiting: Set<String> {
        var ids = Set<String>()
        for m in state.runPending.values { ids.insert(m.eventId) }
        for m in state.deletedRuns.values { ids.insert(m.eventId) }
        for d in state.food.values { if let m = d.pending { ids.insert(m.eventId) } }
        if let m = state.profilePending { ids.insert(m.eventId) }
        return ids
    }
}
