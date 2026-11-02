import Charts
import SwiftUI
import TagwerkCore

struct FitnessView: View {
    @Environment(Store.self) private var store
    @Binding var showSettings: Bool

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    switch store.fitnessPage {
                    case .ernaehrung: NutritionPage()
                    case .laufen: RunsPage()
                    case .gewicht: WeightPage()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 28)
                .readableColumn()
                .animation(.smooth, value: store.fitnessPage)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Fitness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Bereich", selection: $store.fitnessPage) {
                        ForEach(FitnessPage.allCases) { p in Text(p.title).tag(p) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
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

/// "‹ Heute, 1. November ›" for pages that follow the selected day.
struct DaySwitcher: View {
    @Environment(Store.self) private var store

    var body: some View {
        let key = store.selectedDay
        HStack {
            Button {
                withAnimation(.snappy) { store.selectedDay = DayKey.adding(-1, to: key) }
            } label: {
                Image(systemName: "chevron.left").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Vorheriger Tag")
            Spacer()
            VStack(spacing: 0) {
                Text(key == store.today ? "Heute" : key == DayKey.adding(-1, to: store.today) ? "Gestern" : DayKey.weekdayName(key))
                    .font(.headline)
                Text(DayKey.longGerman(key).split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? key)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentTransition(.numericText())
            Spacer()
            Button {
                withAnimation(.snappy) { store.selectedDay = min(DayKey.adding(1, to: key), store.today) }
            } label: {
                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .disabled(key >= store.today)
            .accessibilityLabel("Nächster Tag")
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Weight

struct WeightPage: View {
    @Environment(Store.self) private var store

    var body: some View {
        WeightCard(dayKey: store.today)
        VaultWeightChartCard()
        TargetWeightCard()
    }
}

/// Gewichtsverlauf.canvas: month or year, median of all entries dashed, lines green up, red down, width by change.
struct VaultWeightChartCard: View {
    @Environment(Store.self) private var store
    @State private var mode: WeightChartModel.Mode = .month
    @State private var offset: Int?

    var body: some View {
        let weights = store.state.days.values.compactMap { d in d.weightValue.map { (date: d.date, kg: $0) } }
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "Gewichtsverlauf", systemImage: "scalemass.fill")
            if let m = WeightChartModel(weights: weights) {
                let maxOff = m.maxOffset(mode)
                let current = min(offset ?? maxOff, maxOff)
                let win = m.window(mode, offset: current)
                let visible = m.visible(mode, offset: current)
                Picker("Ansicht", selection: Binding(get: { mode }, set: { mode = $0; offset = nil })) {
                    Text("Monat").tag(WeightChartModel.Mode.month)
                    Text("Jahr").tag(WeightChartModel.Mode.year)
                }
                .pickerStyle(.segmented)
                HStack {
                    Button {
                        withAnimation(.smooth) { offset = max(0, current - 1) }
                    } label: {
                        Label("Zurück", systemImage: "chevron.left")
                    }
                    .disabled(current <= 0)
                    Spacer()
                    Text(win.label).font(.headline).contentTransition(.numericText())
                    Spacer()
                    Button {
                        withAnimation(.smooth) { offset = min(maxOff, current + 1) }
                    } label: {
                        Label("Weiter", systemImage: "chevron.right").labelStyle(TrailingIconLabelStyle())
                    }
                    .disabled(current >= maxOff)
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
                WeightChart(model: m, mode: mode, window: win, visible: visible)
                    .frame(height: 230)
                Text(WeightChartModel.footer(count: visible.count, median: m.median))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } else {
                Text("Noch kein Gewicht eingetragen. Trag es oben oder unter Heute ein, dann entsteht hier der Verlauf wie im Vault.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

struct WeightChart: View {
    var model: WeightChartModel
    var mode: WeightChartModel.Mode
    var window: (start: String, end: String, label: String)
    var visible: [WeightChartModel.Entry]

    static let up = Color(hex: "#2CC742")
    static let down = Color(hex: "#FE5F58")
    static let dot = Color(hex: "#378ADD")

    private func date(_ key: String) -> Date { DayKey.date(key) ?? Date() }

    static func kg(_ v: Double) -> String { Format.decimal(String(format: "%.1f", v)) }

    struct Piece: Identifiable {
        let id: String
        let series: String
        let date: Date
        let kg: Double
        let color: Color
        let width: CGFloat
    }

    struct Dot: Identifiable {
        let id: String
        let date: Date
        let kg: Double
        let spoken: String
    }

    @ChartContentBuilder
    private func dot(_ d: Dot) -> some ChartContent {
        let x: PlottableValue<Date> = .value("Tag", d.date)
        let y: PlottableValue<Double> = .value("kg", d.kg)
        PointMark(x: x, y: y)
            .foregroundStyle(Color(uiColor: .systemBackground))
            .symbolSize(140)
        PointMark(x: x, y: y)
            .foregroundStyle(Self.dot)
            .symbolSize(70)
            .accessibilityLabel(Text(d.spoken))
    }

    private func line(_ l: Piece) -> some ChartContent {
        let x: PlottableValue<Date> = .value("Tag", l.date)
        let y: PlottableValue<Double> = .value("kg", l.kg)
        let series: PlottableValue<String> = .value("Abschnitt", l.series)
        return LineMark(x: x, y: y, series: series)
            .foregroundStyle(l.color)
            .lineStyle(StrokeStyle(lineWidth: l.width, lineCap: .round))
    }

    static func color(_ diff: Double) -> Color {
        if diff > 0 { return up }
        if diff < 0 { return down }
        return Color.secondary
    }

    private var pieces: [Piece] {
        var out: [Piece] = []
        for s in WeightChartModel.segments(visible) {
            let c = Self.color(s.diff)
            let w = CGFloat(s.width)
            out.append(Piece(id: s.id + "a", series: s.id, date: date(s.from.date), kg: s.from.kg, color: c, width: w))
            out.append(Piece(id: s.id + "b", series: s.id, date: date(s.to.date), kg: s.to.kg, color: c, width: w))
        }
        return out
    }

    private var dots: [Dot] {
        visible.map { e in Dot(id: e.date, date: date(e.date), kg: e.kg, spoken: DayKey.longGerman(e.date) + ", " + Self.kg(e.kg) + " Kilogramm") }
    }

    var body: some View {
        let xValues: [Date] = tickDates()
        let lines: [Piece] = pieces
        let points: [Dot] = dots
        Chart {
            RuleMark(y: .value("Median", model.median))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Color.secondary.opacity(0.6))
            ForEach(lines) { l in
                line(l)
            }
            ForEach(points) { d in
                dot(d)
            }
        }
        .chartXScale(domain: date(window.start)...date(window.end))
        .chartYScale(domain: model.yMin...model.yMax)
        .chartYAxis {
            AxisMarks(position: .leading, values: model.yTicks) { v in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel {
                    if let kg = v.as(Double.self) { Text(Self.kg(kg) + " kg").font(.caption2) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: xValues) { v in
                AxisTick()
                AxisValueLabel {
                    if let d = v.as(Date.self) {
                        Text(mode == .month ? d.formatted(.dateTime.day(.twoDigits).month(.twoDigits).locale(germanLocale))
                                            : d.formatted(.dateTime.month(.abbreviated).locale(germanLocale)))
                            .font(.caption2)
                    }
                }
            }
        }
    }

    private func tickDates() -> [Date] {
        switch mode {
        case .month:
            let days = (DayKey.distance(from: window.start, to: window.end) ?? 29) + 1
            let step = Int((Double(days) / 8).rounded(.up))
            // Labels sit right of their tick; one in the last four days would run past the plot edge.
            return stride(from: 0, to: days, by: max(1, step))
                .filter { days - 1 - $0 >= 4 || $0 == 0 }
                .map { date(DayKey.adding($0, to: window.start)) }
        case .year:
            let y = window.start.prefix(4)
            return (1...12).map { date(String(format: "%@-%02d-01", String(y), $0)) }
        }
    }
}

struct WeightDot: View {
    var body: some View {
        Circle()
            .fill(WeightChart.dot)
            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.5))
            .frame(width: 10, height: 10)
    }
}

struct TargetWeightCard: View {
    @Environment(Store.self) private var store

    var body: some View {
        if let p = store.state.profile, let target = p.targetWeight, let w = store.weight(on: store.today) {
            let diff = target - w
            let weeks = p.weeklyRate > 0 ? abs(diff) / p.weeklyRate : nil
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "Zielgewicht", systemImage: "flag.checkered")
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Format.decimal(String(format: "%.1f", target))) kg")
                        .font(.system(.title, design: .rounded).weight(.bold))
                    Spacer()
                    Text(abs(diff) < 0.5 ? "erreicht" : "noch \(diff > 0 ? "+" : "−")\(Format.decimal(String(format: "%.1f", abs(diff)))) kg")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                if let weeks, abs(diff) >= 0.5 {
                    Text("Bei \(Format.decimal(String(format: "%.2f", p.weeklyRate))) kg pro Woche etwa \(Int(weeks.rounded(.up))) Wochen. Die Kalorienziele unter Ernährung sind darauf abgestimmt.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .card()
        }
    }
}
