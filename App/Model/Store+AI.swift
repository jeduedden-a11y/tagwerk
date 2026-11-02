import Foundation
import SwiftUI
import TagwerkCore

extension Store {
    var ai: AIRouter { AIRouter(settings: state.settings, keychain: keychain) }

    /// The examples that teach the model this person's scale: own corrections first, then days with text, then recent days.
    func calibration(before key: String, limit: Int) -> [CalibrationExample] {
        let past = ratedDays.filter { $0.date < key }.reversed()
        func example(_ d: DayEntry) -> CalibrationExample {
            let done = habits.filter { d.habits[$0.key] == true }.map(\.label)
            let text = [d.journal, d.note ?? ""].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " / ")
            return CalibrationExample(date: d.date, habitsDone: done, rating: d.rating ?? "", text: text.isEmpty ? nil : text,
                                      manualOverride: d.ratingSource == .manual && d.ratingAI != nil && d.ratingAI != d.rating)
        }
        var picked: [DayEntry] = []
        let corrected = past.filter { $0.ratingSource == .manual && $0.ratingAI != nil && $0.ratingAI != $0.rating }
        picked += corrected.prefix(limit / 2)
        let withText = past.filter { d in !picked.contains(where: { $0.date == d.date }) && (!d.journal.isEmpty || !(d.note ?? "").isEmpty) }
        picked += withText.prefix(max(0, (limit - picked.count) / 2))
        for d in past where picked.count < limit && !picked.contains(where: { $0.date == d.date }) { picked.append(d) }
        return picked.sorted { $0.date < $1.date }.map(example)
    }

    func context(for key: String, calibrationLimit: Int) -> DayContext {
        let d = day(key)
        let states = habits.map { h in
            HabitState(key: h.key, label: h.label, done: d.habits[h.key] ?? false, weekCount: weekCount(h, for: key), perWeek: h.perWeek)
        }
        let previousWeight = state.days.values.filter { $0.date < key && $0.weight != nil }.max { $0.date < $1.date }?.weight
        let doneTasks = state.tasks.filter { $0.completedOn == key }.map(\.title)
        return DayContext(date: key, userName: state.settings.userName, habits: states, journal: d.journal, obsidianNote: d.note,
                          weight: d.weight, previousWeight: previousWeight, tasksCompletedToday: doneTasks,
                          calibration: calibration(before: key, limit: calibrationLimit), averageRating: averageRating)
    }

    func formula() -> HabitFormula? {
        let samples: [(habits: [String: Bool], rating: Double)] = ratedDays.compactMap { d in
            guard let r = d.ratingValue else { return nil }
            return (habits: d.habits, rating: r)
        }
        return HabitFormula.fit(days: samples, keys: habits.map(\.key))
    }

    func autoRateIfUseful(_ key: String) {
        let d = day(key)
        let text = d.journal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 15, d.lastRatedHash != TagwerkCrypto.journalHash(text), ai.canReadText else { return }
        Task { await rate(key) }
    }

    func rate(_ key: String) async {
        guard !ratingInFlight.contains(key) else { return }
        commitJournal(on: key)
        ratingInFlight.insert(key)
        ratingError[key] = nil
        defer { ratingInFlight.remove(key) }
        let router = ai
        let rater = router.rater(formula: formula(), average: averageRating ?? 6.0)
        let ctx = context(for: key, calibrationLimit: router.prefersShortPrompts ? 8 : 14)
        do {
            let result = try await rater.assess(ctx)
            applyAssessment(result, to: key)
        } catch {
            if isDemo {
                applyAssessment(DayAssessment(rating: 7.4, reason: "Du warst laufen und hast etwas für Mathe getan; das liegt über deinem Schnitt.", detectedHabits: ["laufen"], weight: nil, provider: "Demo"), to: key)
                return
            }
            ratingError[key] = error.localizedDescription
        }
    }

    private func applyAssessment(_ r: DayAssessment, to key: String) {
        let value = RatingScale.format(r.rating)
        var d = day(key)
        let manual = d.ratingSource == .manual
        var habitsChanged: [String: Bool] = [:]
        for h in r.detectedHabits where d.habits[h] != true && !d.manualHabits.contains(h) {
            habitsChanged[h] = true
        }
        var weightUpdate: FieldUpdate<String> = .unchanged
        if d.weight == nil, let w = r.weight { weightUpdate = .set(String(format: "%.1f", w)) }

        let e = EventFactory.dayPatch(date: key, habits: habitsChanged,
                                      rating: manual ? .unchanged : .set(value),
                                      ratingAI: .set(value),
                                      ratingSource: manual ? .unchanged : .set(.ai),
                                      ratingReason: r.reason.isEmpty ? .clear : .set(r.reason),
                                      weight: weightUpdate)
        let m = PendingMark(eventId: e.id, at: e.createdAt)
        withAnimation(.snappy) {
            d.ratingAI = value
            d.ratingReason = r.reason.isEmpty ? nil : r.reason
            d.aiProvider = r.provider
            d.lastRatedHash = TagwerkCrypto.journalHash(d.journal)
            d.pending["ratingAI"] = m
            d.pending["ratingReason"] = m
            if !manual {
                d.rating = value
                d.ratingSource = .ai
                d.pending["rating"] = m
                d.pending["ratingSource"] = m
            }
            for (h, v) in habitsChanged {
                d.habits[h] = v
                d.pending["habit.\(h)"] = m
                if !d.aiHabits.contains(h) { d.aiHabits.append(h) }
            }
            if case .set(let w) = weightUpdate {
                d.weight = w
                d.pending["weight"] = m
            }
            state.days[key] = d
        }
        enqueue(e)
    }
}

/// Picks the best available model: Apple Intelligence on the device, then Claude, then the formula.
struct AIRouter {
    var settings: AppSettings
    var keychain: Keychain

    var claudeKey: String? {
        let k = keychain.get(SecretKey.claudeKey) ?? ""
        return k.isEmpty ? nil : k
    }

    var appleAvailable: Bool { settings.useAppleIntelligence && AppleIntelligence.isAvailable }

    var canReadText: Bool { appleAvailable || claudeKey != nil }

    var prefersShortPrompts: Bool { appleAvailable }

    func rater(formula: HabitFormula?, average: Double) -> DayRater {
        if appleAvailable, let r = AppleIntelligence.rater() { return r }
        if let key = claudeKey { return ClaudeClient(apiKey: key, model: settings.claudeModel) }
        return FormulaRater(formula: formula, average: average)
    }

    func structurer() -> AppointmentStructurer {
        if appleAvailable, let s = AppleIntelligence.structurer() { return s }
        if settings.sendMailsToClaude, let key = claudeKey { return ClaudeClient(apiKey: key, model: settings.claudeModel) }
        return HeuristicStructurer()
    }

    var statusText: String {
        if appleAvailable { return "Apple Intelligence auf diesem iPhone" }
        if claudeKey != nil { return "Claude über deinen API-Schlüssel" }
        return "Ohne KI: Formel aus deinen Gewohnheiten"
    }
}
