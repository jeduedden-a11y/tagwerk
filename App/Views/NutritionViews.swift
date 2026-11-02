import SwiftUI
import TagwerkCore

extension Color {
    static let food = Color(hex: "#EF9F27")
    static let nutritionOK = Color(rgb: RGB(22, 163, 74))
    static let nutritionHigh = Color(rgb: RGB(220, 38, 38))

    static func nutrition(_ status: NutritionCheck.Status?) -> Color {
        switch status {
        case .ok: return .nutritionOK
        case .high: return .nutritionHigh
        case .low: return .food
        case nil: return .secondary
        }
    }
}

// MARK: - Page

struct NutritionPage: View {
    @Environment(Store.self) private var store

    var body: some View {
        let key = store.selectedDay
        DaySwitcher()
        if store.state.profile == nil { ProfilePromptCard() }
        NutritionSummaryCard(dayKey: key)
        QuickAddCard(dayKey: key)
        MealsCard(dayKey: key)
        if store.state.profile != nil {
            Button {
                store.showProfile = true
            } label: {
                Label("Körperprofil und Ziele", systemImage: "person.crop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        FoodSourcesNote()
    }
}

struct FoodSourcesNote: View {
    var body: some View {
        Text("Nährwerte von Open Food Facts (ODbL) für Produkte mit Barcode und aus dem Bundeslebensmittelschlüssel 4.0 (Max Rubner-Institut, CC BY 4.0) für alles andere. Es sind Durchschnittswerte; 10 bis 20 Prozent Abweichung sind bei Lebensmitteln normal.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

struct ProfilePromptCard: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Ziele berechnen", systemImage: "person.crop.circle.badge.plus")
            Text("Mit Größe, Gewicht, Körperfett und Zielgewicht rechnet Tagwerk deinen Bedarf an Kalorien, Protein, Fett und Kohlenhydraten. Ernährung wird dann abgehakt, sobald du im Ziel bist.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Körperprofil anlegen") { store.showProfile = true }
                .buttonStyle(.borderedProminent)
                .tint(Color.food)
        }
        .card()
    }
}

// MARK: - Summary

struct NutritionSummaryCard: View {
    @Environment(Store.self) private var store
    var dayKey: String

    var body: some View {
        let day = store.foodDay(dayKey)
        let totals = day.totals
        let targets = store.targets(for: dayKey)
        let checks = store.checks(for: dayKey)
        let has = !day.entries.isEmpty
        let met = has && NutritionEvaluation.met(checks)
        let manual = store.day(dayKey).manualHabits.contains("food")
        let profile = store.state.profile
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(title: "Tagesbilanz", systemImage: "chart.pie.fill")
                Spacer()
                if has, targets != nil {
                    Label(met ? "Im Ziel" : "Noch offen", systemImage: met ? "checkmark.seal.fill" : "circle.dashed")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(met ? Color.nutritionOK : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background((met ? Color.nutritionOK : Color.secondary).opacity(0.14), in: .capsule)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            HStack(alignment: .center, spacing: 18) {
                KcalRing(value: totals.kcal, target: targets?.kcal, status: has ? checks.first?.status : nil)
                    .frame(width: 118, height: 118)
                VStack(alignment: .leading, spacing: 10) {
                    MacroBar(label: "Protein", value: totals.protein, target: targets?.protein, status: status(.protein, checks, has),
                             checked: profile?.checkProtein ?? true)
                    MacroBar(label: "Fett", value: totals.fat, target: targets?.fat, status: status(.fat, checks, has),
                             checked: profile?.checkFat ?? true)
                    MacroBar(label: "Kohlenhydrate", value: totals.carbs, target: targets?.carbs, status: status(.carbs, checks, has),
                             checked: profile?.checkCarbs ?? true)
                    if profile?.checkFiber == true {
                        MacroBar(label: "Ballaststoffe", value: totals.fiber ?? 0, target: targets?.fiber, status: status(.fiber, checks, has))
                    }
                }
            }
            Text(statusLine(has: has, met: met, checks: checks, targets: targets))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let t = targets, let p = profile {
                Text(footnote(t, p))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if manual && has {
                Button("Ernährung wieder nach den Zielen abhaken") { store.resumeAutoFood(dayKey) }
                    .font(.footnote)
                    .buttonStyle(.borderless)
            }
        }
        .card()
        .animation(.smooth, value: totals.kcal)
    }

    private func status(_ kind: NutritionCheck.Kind, _ checks: [NutritionCheck], _ has: Bool) -> NutritionCheck.Status? {
        guard has else { return nil }
        return checks.first { $0.kind == kind }?.status
    }

    private func statusLine(has: Bool, met: Bool, checks: [NutritionCheck], targets: NutritionTargets?) -> String {
        if store.state.profile == nil { return "Ohne Körperprofil gibt es keine Ziele, eingetragen wird trotzdem." }
        if targets == nil { return "Für die Ziele fehlt noch dein Gewicht: unter Gewicht oder im Körperprofil eintragen." }
        if !has { return "Noch nichts eingetragen. Scannen geht am schnellsten." }
        if met { return "Alle Vorgaben erfüllt, Ernährung ist abgehakt." }
        // statusText counts to the tolerance bound, not to the target shown in the ring and bars.
        return "Für den Haken: " + checks.filter { $0.status != .ok }.prefix(3).map { "\($0.label) \($0.statusText)" }.joined(separator: " · ")
    }

    private func footnote(_ t: NutritionTargets, _ p: BodyProfile) -> String {
        let tol = p.tolerance / 100
        var parts = ["Ziel \(NutritionFormat.kcal(t.kcal)) kcal ±\(Int(p.tolerance)) % (\(NutritionFormat.kcal(t.kcal * (1 - tol)))–\(NutritionFormat.kcal(t.kcal * (1 + tol))))"]
        if p.checkProtein { parts.append("Protein ab \(Int((t.protein * (1 - tol)).rounded())) g") }
        if p.checkFat { parts.append("Fett \(Int((t.fat * (1 - tol)).rounded()))–\(Int((t.fat * (1 + tol)).rounded())) g") }
        if p.checkCarbs { parts.append("Kohlenhydrate \(Int((t.carbs * (1 - tol)).rounded()))–\(Int((t.carbs * (1 + tol)).rounded())) g") }
        if p.checkFiber { parts.append("Ballaststoffe ab \(Int((t.fiber * (1 - tol)).rounded())) g") }
        if t.runKcal > 1 { parts.append("inkl. \(NutritionFormat.kcal(t.runKcal)) kcal für den Lauf") }
        return parts.joined(separator: " · ")
    }
}

struct KcalRing: View {
    var value: Double
    var target: Double?
    var status: NutritionCheck.Status?

    var body: some View {
        let fraction = target.map { $0 > 0 ? value / $0 : 0 } ?? 0
        let color = target == nil ? Color.food : Color.nutrition(status ?? .low)
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 12)
            Circle()
                .trim(from: 0, to: min(1, fraction))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if fraction > 1 {
                Circle()
                    .trim(from: 0, to: min(1, fraction - 1))
                    .stroke(Color.nutritionHigh.opacity(0.85), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(14)
            }
            VStack(spacing: 0) {
                Text(NutritionFormat.kcal(value))
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: value))
                Text(target.map { "von \(NutritionFormat.kcal($0))" } ?? "kcal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if target != nil {
                    Text("kcal").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kalorien")
        .accessibilityValue(target.map { "\(NutritionFormat.kcal(value)) von \(NutritionFormat.kcal($0))" } ?? NutritionFormat.kcal(value))
    }
}

struct MacroBar: View {
    var label: String
    var value: Double
    var target: Double?
    var status: NutritionCheck.Status?
    /// false: the target is only a guide value and does not decide the tick, so the bar stays muted.
    var checked = true

    private var fill: Color {
        if target != nil && !checked { return Color.food.opacity(0.4) }
        return Color.nutrition(status ?? (target == nil ? nil : .low))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(checked ? .primary : .secondary)
                Spacer(minLength: 4)
                Text(target.map { "\(NutritionFormat.grams(value)) / \(Int($0.rounded())) g" } ?? "\(NutritionFormat.grams(value)) g")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            GeometryReader { geo in
                let scale = max((target ?? value) * 1.25, value, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(fill.gradient)
                        .frame(width: max(4, geo.size.width * min(1, value / scale)))
                    if let target {
                        Rectangle()
                            .fill(Color.primary.opacity(0.45))
                            .frame(width: 1.5)
                            .offset(x: geo.size.width * target / scale)
                    }
                }
            }
            .frame(height: 7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(target != nil && !checked ? "Richtwert, zählt nicht für den Haken" : "")
    }
}

// MARK: - Adding

struct QuickAddCard: View {
    @Environment(Store.self) private var store
    var dayKey: String

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "Eintragen", systemImage: "plus.circle.fill")
            LazyVGrid(columns: columns, spacing: 10) {
                tile("Scannen", "barcode.viewfinder", .scan)
                tile("Suchen", "magnifyingglass", .search)
                tile("Foto", "camera.fill", .photo)
                tile("Text", "text.bubble.fill", .describe)
            }
            let recent = store.recentFoods.prefix(14)
            if !recent.isEmpty {
                Text("Zuletzt gegessen")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(recent)) { r in
                            Button {
                                store.capture = FoodCapture(mode: .item(r.item, grams: r.lastGrams), day: dayKey)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.item.name).font(.footnote.weight(.semibold)).lineLimit(1)
                                    Text(r.lastGrams.map { "\(NutritionFormat.amount($0)) \(r.item.unit)" } ?? r.item.brand ?? " ")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: 150, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.food.opacity(0.12), in: .rect(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
                .scrollClipDisabled()
            }
            Button {
                store.capture = FoodCapture(mode: .manual, day: dayKey)
            } label: {
                Label("Von Hand eintragen", systemImage: "square.and.pencil")
            }
            .font(.subheadline)
            .buttonStyle(.borderless)
        }
        .card()
    }

    private func tile(_ title: String, _ symbol: String, _ mode: FoodCapture.Mode) -> some View {
        Button {
            store.capture = FoodCapture(mode: mode, day: dayKey)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.food)
                    .frame(height: 24)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(Color.food.opacity(0.12), in: .rect(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(title)
    }
}

// MARK: - Log

struct MealsCard: View {
    @Environment(Store.self) private var store
    var dayKey: String

    var body: some View {
        let day = store.foodDay(dayKey)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(title: "Mahlzeiten", systemImage: "list.bullet.rectangle")
                Spacer()
                if day.pending != nil {
                    Image(systemName: store.heldForPlugin > 0 ? "puzzlepiece.extension" : "arrow.up.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Noch nicht im Vault")
                }
            }
            if day.entries.isEmpty {
                Text("Noch keine Einträge an diesem Tag.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(Meal.allCases) { meal in
                let entries = day.entries.filter { $0.meal == meal }.sorted { $0.time < $1.time }
                if !entries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(meal.label, systemImage: meal.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(NutritionFormat.kcal(entries.reduce(0) { $0 + $1.nutrients.kcal })) kcal")
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        ForEach(entries) { e in
                            Button {
                                store.capture = FoodCapture(mode: .entry(e), day: dayKey)
                            } label: {
                                FoodEntryRow(entry: e)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    store.addFood([e.item.entry(grams: e.grams, meal: Meal.guess(hour: Calendar.current.component(.hour, from: Date())),
                                                                time: Self.now())], on: store.today)
                                } label: {
                                    Label("Heute noch einmal", systemImage: "arrow.counterclockwise")
                                }
                                Button(role: .destructive) {
                                    store.removeFood(e.id, on: dayKey)
                                } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                        }
                    }
                    if meal != Meal.allCases.last { Divider().opacity(0.4) }
                }
            }
        }
        .card()
    }

    static func now() -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return String(format: "%02d:%02d", c.hour ?? 12, c.minute ?? 0)
    }
}

struct FoodEntryRow: View {
    var entry: FoodEntry

    var body: some View {
        let n = entry.nutrients
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.brand.map { "\(entry.name) · \($0)" } ?? entry.name)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text("\(entry.amountLabel) · \(entry.time)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(NutritionFormat.kcal(n.kcal)) kcal")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text("P \(NutritionFormat.grams(n.protein)) · F \(NutritionFormat.grams(n.fat)) · K \(NutritionFormat.grams(n.carbs))")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Doppeltippen zum Bearbeiten")
    }
}

// MARK: - Today

struct NutritionTodayCard: View {
    @Environment(Store.self) private var store
    var dayKey: String

    var body: some View {
        let day = store.foodDay(dayKey)
        let targets = store.targets(for: dayKey)
        let checks = store.checks(for: dayKey)
        let kcalStatus = day.entries.isEmpty ? nil : checks.first?.status
        let protein = checks.first { $0.kind == .protein }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(title: "Ernährung", systemImage: "fork.knife")
                Spacer()
                Text(targets.map { "\(NutritionFormat.kcal(day.totals.kcal)) / \(NutritionFormat.kcal($0.kcal)) kcal" } ?? "\(NutritionFormat.kcal(day.totals.kcal)) kcal")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            if let t = targets {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(Color.nutrition(kcalStatus ?? .low).gradient)
                            .frame(width: max(4, geo.size.width * min(1, day.totals.kcal / max(1, t.kcal))))
                    }
                }
                .frame(height: 8)
                if let protein {
                    let rest: String = protein.status == .ok ? "im Ziel" : "für den Haken \(protein.statusText)"
                    Text("Protein \(NutritionFormat.grams(protein.value)) von \(Int(protein.target.rounded())) g · \(rest)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if store.state.profile == nil {
                Text("Körperprofil anlegen, dann gibt es Ziele und Ernährung hakt sich selbst ab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    store.capture = FoodCapture(mode: .scan, day: dayKey)
                } label: {
                    Label("Scannen", systemImage: "barcode.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.food)
                Menu {
                    Button { store.capture = FoodCapture(mode: .search, day: dayKey) } label: { Label("Suchen", systemImage: "magnifyingglass") }
                    Button { store.capture = FoodCapture(mode: .photo, day: dayKey) } label: { Label("Foto", systemImage: "camera") }
                    Button { store.capture = FoodCapture(mode: .describe, day: dayKey) } label: { Label("Beschreiben", systemImage: "text.bubble") }
                    Button { store.capture = FoodCapture(mode: .manual, day: dayKey) } label: { Label("Von Hand", systemImage: "square.and.pencil") }
                } label: {
                    Label("Eintragen", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    store.selectedDay = dayKey
                    store.fitnessPage = .ernaehrung
                    store.requestedTab = .fitness
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Ernährung öffnen")
            }
            .font(.subheadline.weight(.semibold))
        }
        .card()
    }
}

// MARK: - Profile

struct BodyProfileSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft = BodyProfile()
    @State private var weightText = ""
    @State private var heightText = ""
    @State private var bodyFatText = ""
    @State private var targetText = ""
    @State private var loaded = false

    private static let rates: [Double] = [0.1, 0.25, 0.5, 0.75, 1.0]

    private func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    private var weight: Double? { number(weightText).flatMap { (25...300).contains($0) ? $0 : nil } }

    private var edited: BodyProfile {
        var p = draft
        if let h = number(heightText), (100...250).contains(h) { p.heightCm = h }
        p.bodyFat = number(bodyFatText).flatMap { (3...60).contains($0) ? $0 : nil }
        p.targetWeight = number(targetText).flatMap { (30...300).contains($0) ? $0 : nil }
        return p
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    numberRow("Gewicht", text: $weightText, unit: "kg", prompt: "75,0")
                    numberRow("Größe", text: $heightText, unit: "cm", prompt: "180")
                    Picker("Geburtsjahr", selection: $draft.birthYear) {
                        ForEach((1950...2015).reversed(), id: \.self) { Text(String($0)).tag($0) }
                    }
                    Picker("Geschlecht", selection: $draft.sex) {
                        ForEach(Sex.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    numberRow("Körperfett", text: $bodyFatText, unit: "%", prompt: "optional")
                } header: {
                    Text("Körper")
                } footer: {
                    Text("Das Gewicht landet in der heutigen Daily Note. Mit Körperfett rechnet Tagwerk den Grundumsatz aus der fettfreien Masse (Katch-McArdle), ohne mit Mifflin-St Jeor.")
                }

                Section {
                    numberRow("Zielgewicht", text: $targetText, unit: "kg", prompt: "optional")
                    Picker("Tempo", selection: $draft.weeklyRate) {
                        ForEach(Self.rates, id: \.self) { r in Text("\(Format.decimal(String(format: r == 0.25 || r == 0.75 ? "%.2f" : "%.1f", r))) kg pro Woche").tag(r) }
                    }
                    Picker("Alltag und Training", selection: $draft.activity) {
                        ForEach(ActivityLevel.allCases) { a in
                            VStack(alignment: .leading) {
                                Text(a.label)
                                Text(a.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(a)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Toggle("Läufe zum Tagesbedarf addieren", isOn: $draft.addRuns)
                } header: {
                    Text("Ziel")
                } footer: {
                    Text("Läufe zählen extra: rund 1 kcal je kg Körpergewicht und Kilometer, abzüglich dessen, was der Aktivitätsfaktor für die Zeit schon enthält. Gym und Alltag stecken im Faktor.")
                }

                Section("Makronährstoffe") {
                    Stepper(value: $draft.proteinPerKg, in: 1.0...2.6, step: 0.1) {
                        LabeledContent("Protein", value: "\(Format.decimal(String(format: "%.1f", draft.proteinPerKg))) g je kg")
                    }
                    Stepper(value: $draft.fatPercent, in: 20...40, step: 1) {
                        LabeledContent("Fett", value: "\(Int(draft.fatPercent)) % der Energie")
                    }
                }

                Section {
                    Stepper(value: $draft.tolerance, in: 5...25, step: 1) {
                        LabeledContent("Spielraum", value: "±\(Int(draft.tolerance)) %")
                    }
                    Toggle("Proteinziel erreicht", isOn: $draft.checkProtein)
                    Toggle("Fett im Zielbereich", isOn: $draft.checkFat)
                    Toggle("Kohlenhydrate im Zielbereich", isOn: $draft.checkCarbs)
                    Toggle("Ballaststoffe erreicht", isOn: $draft.checkFiber)
                } header: {
                    Text("Ernährung abhaken, wenn")
                } footer: {
                    Text("Die Kalorien müssen immer im Spielraum liegen. Protein und Ballaststoffe zählen als Untergrenze, Fett und Kohlenhydrate als Bereich. Von Hand gesetzte Häkchen haben Vorrang.")
                }

                if let w = weight ?? store.weight(on: store.today) {
                    let t = NutritionCalculator.targets(profile: edited, weightKg: w, year: Int(store.today.prefix(4)) ?? 2026)
                    Section {
                        LabeledContent("Grundumsatz", value: "\(NutritionFormat.kcal(t.bmr)) kcal")
                        LabeledContent("Gesamtbedarf", value: "\(NutritionFormat.kcal(t.tdee)) kcal")
                        if abs(t.goalKcal) > 0.5 {
                            LabeledContent(t.goalKcal > 0 ? "Überschuss" : "Defizit", value: "\(t.goalKcal > 0 ? "+" : "−")\(NutritionFormat.kcal(abs(t.goalKcal))) kcal")
                        }
                        LabeledContent("Tagesziel", value: "\(NutritionFormat.kcal(t.kcal)) kcal")
                        LabeledContent("Protein", value: "\(Int(t.protein.rounded())) g")
                        LabeledContent("Fett", value: "\(Int(t.fat.rounded())) g")
                        LabeledContent("Kohlenhydrate", value: "\(Int(t.carbs.rounded())) g")
                    } header: {
                        Text("Ergebnis an einem Tag ohne Lauf")
                    } footer: {
                        Text("\(t.formula), Aktivitätsfaktor \(Format.decimal(String(edited.activity.pal))), 7.700 kcal je kg Gewichtsänderung.\(t.limited ? " Begrenzt: höchstens 20 % über oder 25 % unter dem Bedarf, nie unter dem Grundumsatz." : "") Alle Formeln sind Schätzungen mit etwa ±10 % Streuung; der Gewichtsverlauf zeigt nach zwei, drei Wochen, ob die Menge stimmt.")
                    }
                }
            }
            .navigationTitle("Körperprofil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        store.saveProfile(edited, weight: weight)
                        dismiss()
                    }
                    .disabled(weight == nil && store.weight(on: store.today) == nil)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                draft = store.state.profile ?? BodyProfile()
                heightText = String(format: "%.0f", draft.heightCm)
                bodyFatText = draft.bodyFat.map { Format.decimal(String(format: "%.1f", $0)) } ?? ""
                targetText = draft.targetWeight.map { Format.decimal(String(format: "%.1f", $0)) } ?? ""
                weightText = store.weight(on: store.today).map { Format.decimal(String(format: "%.1f", $0)) } ?? ""
                if !Self.rates.contains(draft.weeklyRate) { draft.weeklyRate = 0.25 }
            }
        }
    }

    private func numberRow(_ title: String, text: Binding<String>, unit: String, prompt: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(prompt, text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}
