import SwiftUI
import TagwerkCore

struct TodayView: View {
    @Environment(Store.self) private var store
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var showSettings: Bool

    private var title: String {
        let key = store.selectedDay
        if key == store.today { return "Heute" }
        if key == DayKey.adding(-1, to: store.today) { return "Gestern" }
        return DayKey.weekdayName(key)
    }

    var body: some View {
        let key = store.selectedDay
        let day = store.day(key)
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        Text(DayKey.longGerman(key))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                            .accessibilityAddTraits(.isHeader)
                        if !store.isConnected && !store.isDemo {
                            ConnectCard(showSettings: $showSettings)
                        }
                        RatingCard(dayKey: key)
                        HabitGrid(dayKey: key)
                        UpcomingExamsCard()
                        NutritionTodayCard(dayKey: key)
                        JournalCard(dayKey: key)
                        WeightCard(dayKey: key)
                            .id("weight")
                        if !store.state.settings.dismissedReminderPrompt && !store.isDemo {
                            ReminderPromptCard()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                    .readableColumn()
                    .id(key)
                }
                .onAppear {
                    // Screenshot runs only: -TWScroll unten
                    if UserDefaults.standard.string(forKey: "TWScroll") == "unten" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { proxy.scrollTo("weight", anchor: .bottom) }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background { DayBackground(tint: Color.rating(day.ratingValue)) }
            .safeAreaBar(edge: .top) {
                WeekStrip()
            }
            .navigationTitle(title)
            // Inline: a large title would sit under the week bar's scroll edge effect and blur.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sizeClass == .compact {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            store.requestedTab = .verlauf
                        } label: {
                            Label("Verlauf", systemImage: "chart.bar.fill")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Einstellungen", systemImage: "gearshape")
                    }
                }
            }
        }
    }
}

// MARK: - Week strip (functional layer: navigates between days)

struct WeekStrip: View {
    @Environment(Store.self) private var store
    @Namespace private var glass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var weekStart: String { DayKey.weekStart(store.selectedDay) }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                shift(-7)
            } label: {
                Image(systemName: "chevron.left").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Vorige Woche")

            GlassEffectContainer(spacing: 4) {
                HStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { i in
                        dayCell(DayKey.adding(i, to: weekStart))
                    }
                }
            }

            Button {
                shift(7)
            } label: {
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(DayKey.adding(7, to: weekStart) > store.today)
            .accessibilityLabel("Nächste Woche")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func shift(_ days: Int) {
        let target = min(DayKey.adding(days, to: store.selectedDay), store.today)
        select(target)
    }

    private func select(_ key: String) {
        store.commitAllJournals()
        if reduceMotion {
            store.selectedDay = key
        } else {
            withAnimation(.bouncy(duration: 0.35)) { store.selectedDay = key }
        }
    }

    @ViewBuilder
    private func dayCell(_ key: String) -> some View {
        let selected = key == store.selectedDay
        let future = key > store.today
        let day = store.day(key)
        let isToday = key == store.today
        Button {
            select(key)
        } label: {
            VStack(spacing: 3) {
                Text(DayKey.weekdayShortName(key))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("\(Int(key.suffix(2)) ?? 0)")
                    .font(.system(.callout, design: .rounded).weight(isToday ? .bold : .semibold))
                    .foregroundStyle(isToday ? Color.accentColor : Color.primary)
                Circle()
                    .fill(day.ratingValue != nil ? Color.rating(day.ratingValue) : Color.secondary.opacity(day.hasContent ? 0.6 : 0.2))
                    .frame(width: 6, height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(.rect)
            .opacity(future ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(future)
        .modifier(SelectedGlass(selected: selected, id: key, namespace: glass))
        .accessibilityLabel(Format.dayTitle(key))
        .accessibilityValue(day.ratingValue.map { "Bewertung \(Format.rating($0))" } ?? "ohne Bewertung")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Only the selected day carries glass; switching days morphs it to the new position.
private struct SelectedGlass: ViewModifier {
    var selected: Bool
    var id: String
    var namespace: Namespace.ID

    func body(content: Content) -> some View {
        if selected {
            content
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16, style: .continuous))
                .glassEffectID("selected-day", in: namespace)
        } else {
            content
        }
    }
}

// MARK: - Rating

struct RatingCard: View {
    @Environment(Store.self) private var store
    var dayKey: String
    @State private var draft: Double?
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize: CGFloat = 58

    var body: some View {
        let day = store.day(dayKey)
        let shown = draft ?? day.ratingValue
        let inFlight = store.ratingInFlight.contains(dayKey)
        let manual = day.ratingSource == .manual
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.rating(shown))
                    .font(.system(size: numberSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: shown ?? 0))
                    .animation(.snappy, value: shown)
                Text("/ 10")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                sourceBadge(day: day, manual: manual)
            }
            .accessibilityElement(children: .combine)

            // No step: parameter, iOS 26 would draw 100 tick marks. Rounded to 0.1 here instead.
            Slider(value: Binding(get: { draft ?? day.ratingValue ?? store.averageRating ?? 5 },
                                  set: { draft = ($0 * 10).rounded() / 10 }),
                   in: 0...10,
                   onEditingChanged: { editing in
                       if !editing, let v = draft {
                           store.setManualRating(v, on: dayKey)
                           draft = nil
                       }
                   })
                .tint(Color.rating(shown))
                .sensoryFeedback(.selection, trigger: Int((draft ?? 0).rounded()))
                .accessibilityLabel("Tagesbewertung")
                .accessibilityValue("\(Format.rating(shown)) von 10")
                .accessibilityAdjustableAction { direction in
                    let base = day.ratingValue ?? 5
                    let next = direction == .increment ? min(10, base + 0.5) : max(0, base - 0.5)
                    store.setManualRating(next, on: dayKey)
                }

            if inFlight {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Liest deinen Eintrag und vergleicht mit deinen früheren Tagen …")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else if let reason = day.ratingReason {
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else if day.ratingValue == nil {
                Text("Noch keine Bewertung. Schreib zwei Sätze zum Tag, dann schlägt die KI eine vor, oder zieh den Regler selbst.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if manual, let ai = day.aiValue, ai != day.ratingValue {
                Text("Deine Korrektur gilt und dient der KI künftig als Beispiel für deine Skala.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let error = store.ratingError[dayKey] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await store.rate(dayKey) }
                } label: {
                    Label(day.ratingAI == nil ? "Mit KI bewerten" : "Neu bewerten", systemImage: "sparkles")
                        .symbolEffect(.pulse, isActive: inFlight)
                }
                .buttonStyle(.bordered)
                .disabled(inFlight)

                if manual, let ai = day.ratingAI, ai != day.rating {
                    Button("KI-Wert \(Format.decimal(ai)) nehmen") {
                        store.revertToAI(on: dayKey)
                    }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                }
                Spacer(minLength: 0)
            }

            Text(providerLine(day))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .card()
        .animation(.smooth, value: inFlight)
    }

    private func providerLine(_ day: DayEntry) -> String {
        if let p = day.aiProvider { return "Vorschlag von \(p), gemessen an deinen eigenen früheren Bewertungen" }
        return store.ai.statusText
    }

    @ViewBuilder
    private func sourceBadge(day: DayEntry, manual: Bool) -> some View {
        if day.ratingValue != nil {
            Label(manual ? "Von dir" : "KI-Vorschlag", systemImage: manual ? "hand.point.up.left.fill" : "sparkles")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.rating(day.ratingValue).opacity(0.18), in: .capsule)
        }
    }
}

// MARK: - Habits

struct HabitGrid: View {
    @Environment(Store.self) private var store
    var dayKey: String

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(store.habits) { habit in
                HabitTile(habit: habit, dayKey: dayKey)
            }
        }
    }
}

struct HabitTile: View {
    @Environment(Store.self) private var store
    @Environment(\.colorScheme) private var scheme
    var habit: HabitConfig
    var dayKey: String

    var body: some View {
        let day = store.day(dayKey)
        let done = day.habits[habit.key] ?? false
        let fromAI = day.aiHabits.contains(habit.key)
        let auto = day.autoHabits.contains(habit.key)
        let color = Color(hex: habit.color)
        let streak = store.streak(habit, upTo: dayKey).current
        let week = store.weekCount(habit, for: dayKey)
        let target = max(1, Int(habit.perWeek.rounded()))
        Button {
            store.toggleHabit(habit.key, on: dayKey)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: habit.symbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(done ? color : Color.secondary)
                        .symbolEffect(.bounce, value: done)
                        .frame(height: 28)
                    Spacer()
                    if fromAI && done {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else if auto && done {
                        Image(systemName: habit.key == "laufen" ? "location.fill" : "scope")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(done ? color : Color.secondary.opacity(0.45))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(habit.label)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 4) {
                    ForEach(0..<min(target, 7), id: \.self) { i in
                        Capsule()
                            .fill(i < week ? color : Color.secondary.opacity(0.22))
                            .frame(height: 4)
                    }
                    Spacer(minLength: 6)
                    Text(streak > 0 ? "Serie \(streak)" : "\(week)/\(target)")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .contentTransition(.numericText())
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial)
                    if done {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(color.opacity(scheme == .dark ? 0.26 : 0.15))
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(done ? color.opacity(0.55) : Color.primary.opacity(0.06), lineWidth: done ? 1 : 0.5)
            }
            .animation(.smooth(duration: 0.25), value: done)
        }
        .buttonStyle(PressableStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: done)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(habit.label)
        .accessibilityValue([done ? "erledigt" : "offen", fromAI && done ? "von der KI erkannt" : nil,
                             auto && done ? (habit.key == "laufen" ? "aus einem eingetragenen Lauf" : "Ziele erreicht") : nil,
                             "\(week) von \(target) diese Woche", streak > 0 ? "Serie \(streak)" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Doppeltippen zum Umschalten")
    }
}

// MARK: - Journal

struct JournalCard: View {
    @Environment(Store.self) private var store
    var dayKey: String
    @FocusState private var focused: Bool

    var body: some View {
        let day = store.day(dayKey)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(title: "Tagebuch", systemImage: "book.closed.fill")
                Spacer()
                if day.journalDirty || day.pending["journal"] != nil {
                    Image(systemName: "arrow.up.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Noch nicht im Vault")
                }
            }
            ZStack(alignment: .topLeading) {
                if day.journal.isEmpty {
                    Text("Was war heute los? Die KI liest mit und schlägt daraus deine Bewertung vor.")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(get: { store.day(dayKey).journal }, set: { store.updateJournal($0, on: dayKey) }))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .focused($focused)
                    .accessibilityLabel("Tagebuch")
            }
            if let note = day.note {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Label("Aus Obsidian", systemImage: "doc.text")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .card()
        .onChange(of: focused) { _, isFocused in
            if !isFocused { store.commitJournal(on: dayKey) }
        }
        .toolbar {
            if focused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Fertig") { focused = false }
                }
            }
        }
    }
}

// MARK: - Weight

struct WeightCard: View {
    @Environment(Store.self) private var store
    var dayKey: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let day = store.day(dayKey)
        let previous = store.state.days.values.filter { $0.date < dayKey && $0.weightValue != nil }.max { $0.date < $1.date }
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(title: "Gewicht", systemImage: "scalemass.fill")
                if let w = day.weightValue, let prev = previous, let p = prev.weightValue {
                    let delta = w - p
                    let change: String = abs(delta) < 0.05 ? "unverändert"
                        : "\(delta > 0 ? "+" : "−")\(Format.decimal(String(format: "%.1f", abs(delta)))) kg"
                    Text("\(change) seit \(DayKey.shortGerman(prev.date))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if day.weightValue == nil, let p = previous?.weight {
                    Text("Zuletzt \(Format.decimal(p)) kg")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            TextField("–", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .frame(maxWidth: 110)
                .focused($focused)
                .accessibilityLabel("Gewicht in Kilogramm")
            Text("kg")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .card()
        .onAppear { text = Format.decimal(day.weight) }
        .onChange(of: dayKey) { _, _ in text = Format.decimal(store.day(dayKey).weight) }
        .onChange(of: day.weight) { _, w in if !focused { text = Format.decimal(w) } }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { store.setWeight(text, on: dayKey) }
        }
        .toolbar {
            if focused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Fertig") { focused = false }
                }
            }
        }
    }
}

// MARK: - Prompts

struct ConnectCard: View {
    @Binding var showSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Mit dem Vault verbinden", systemImage: "link")
            Text("Bis dahin bleibt alles auf dem iPhone. Nach der Einrichtung schreibt das Obsidian-Plugin jede Änderung in deine Daily Notes und Aufgaben.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Einrichten") { showSettings = true }
                .buttonStyle(.borderedProminent)
        }
        .card()
    }
}

struct ReminderPromptCard: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Abends erinnern?", systemImage: "bell.badge")
            Text("Eine Mitteilung um 21 Uhr, wenn der Tag noch leer ist, und zu fälligen Aufgaben am Morgen.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Erlauben") {
                    Task {
                        _ = await Notifier.requestAuthorization()
                        store.state.settings.dismissedReminderPrompt = true
                        store.scheduleSave()
                        store.scheduleNotifications()
                    }
                }
                .buttonStyle(.bordered)
                Button("Nicht jetzt") {
                    withAnimation(.smooth) { store.state.settings.dismissedReminderPrompt = true }
                    store.scheduleSave()
                }
                .buttonStyle(.borderless)
            }
        }
        .card()
    }
}
