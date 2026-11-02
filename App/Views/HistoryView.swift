import Charts
import SwiftUI
import TagwerkCore

struct HistoryView: View {
    @Environment(Store.self) private var store
    @Binding var showSettings: Bool
    @State private var window = 30

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("Zeitraum", selection: $window.animation(.smooth)) {
                        Text("7 Tage").tag(7)
                        Text("30 Tage").tag(30)
                        Text("90 Tage").tag(90)
                    }
                    .pickerStyle(.segmented)
                    RatingChartCard(window: window)
                    HabitStatsCard(window: window)
                    WeightChartCard(window: window)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Verlauf")
            .toolbar {
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

private struct RatingPoint: Identifiable {
    var key: String
    var date: Date
    var rating: Double
    var id: String { key }
}

struct RatingChartCard: View {
    @Environment(Store.self) private var store
    var window: Int

    var body: some View {
        let first = DayKey.adding(-(window - 1), to: store.today)
        let points: [RatingPoint] = store.ratedDays
            .filter { $0.date >= first }
            .compactMap { d in
                guard let r = d.ratingValue, let date = DayKey.date(d.date) else { return nil }
                return RatingPoint(key: d.date, date: date, rating: r)
            }
        let avg = points.isEmpty ? nil : points.map(\.rating).reduce(0, +) / Double(points.count)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(title: "Bewertung", systemImage: "chart.bar.fill")
                Spacer()
                if let avg {
                    Text("Schnitt \(Format.rating(avg))")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if points.isEmpty {
                Text("Noch keine Bewertungen in diesem Zeitraum.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Chart {
                    ForEach(points) { p in
                        BarMark(x: .value("Tag", p.date, unit: .day), y: .value("Bewertung", p.rating))
                            .foregroundStyle(Color.rating(p.rating))
                            .cornerRadius(3)
                            .accessibilityLabel(Format.dayTitle(p.key))
                            .accessibilityValue(Format.rating(p.rating))
                    }
                    if let avg {
                        RuleMark(y: .value("Schnitt", avg))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYScale(domain: 0...10)
                .chartYAxis {
                    AxisMarks(values: [0, 2.5, 5, 7.5, 10]) { v in
                        AxisGridLine()
                        AxisValueLabel {
                            if let d = v.as(Double.self) { Text(Format.rating(d)) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(preset: .aligned, values: .stride(by: .day, count: window <= 7 ? 1 : (window <= 30 ? 7 : 21))) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day().month(.defaultDigits).locale(germanLocale))
                    }
                }
                .frame(height: 190)
            }
            Text("Farben wie im Rating-Diagramm deiner Übersicht: rot bis grün bis 8,75, darüber blau, ab 9,5 lila.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .card()
    }
}

struct HabitStatsCard: View {
    @Environment(Store.self) private var store
    var window: Int

    var body: some View {
        let first = DayKey.adding(-(window - 1), to: store.today)
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(title: "Gewohnheiten", systemImage: "circle.grid.2x2.fill")
            ForEach(store.habits) { h in
                let done = store.doneDates(h.key).filter { $0 >= first && $0 <= store.today }.count
                let expected = h.perWeek * Double(window) / 7
                let ratio = expected > 0 ? Double(done) / expected : 0
                let score = (ratio - 1) * 5
                let streak = store.streak(h, upTo: store.today)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: h.symbol)
                            .foregroundStyle(Color(hex: h.color))
                            .frame(width: 22)
                        Text(h.label).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(done) von \(Int(expected.rounded()))")
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule()
                                .fill(Color.habitScore(score))
                                .frame(width: max(6, geo.size.width * min(ratio, 1.6) / 1.6))
                            Rectangle()
                                .fill(Color.primary.opacity(0.35))
                                .frame(width: 1.5)
                                .offset(x: geo.size.width / 1.6)
                        }
                    }
                    .frame(height: 8)
                    .accessibilityHidden(true)
                    Text("Serie \(streak.current) · längste \(streak.longest)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(h.label)
                .accessibilityValue("\(done) von \(Int(expected.rounded())) im Zeitraum, Serie \(streak.current)")
            }
            Text("Strich = Soll pro Woche wie im Habits-Dashboard; Farbe nach dessen Wertung.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .card()
    }
}

private struct WeightPoint: Identifiable {
    var date: Date
    var kg: Double
    var id: Date { date }
}

struct WeightChartCard: View {
    @Environment(Store.self) private var store
    var window: Int

    var body: some View {
        let first = DayKey.adding(-(window - 1), to: store.today)
        let points: [WeightPoint] = store.state.days.values
            .filter { $0.date >= first }
            .compactMap { d in
                guard let w = d.weightValue, let date = DayKey.date(d.date) else { return nil }
                return WeightPoint(date: date, kg: w)
            }
            .sorted { $0.date < $1.date }
        if points.count >= 2 {
            let lo = (points.map(\.kg).min() ?? 70) - 1
            let hi = (points.map(\.kg).max() ?? 80) + 1
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "Gewicht", systemImage: "scalemass.fill")
                Chart(points) { p in
                    LineMark(x: .value("Tag", p.date, unit: .day), y: .value("kg", p.kg))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Tag", p.date, unit: .day), y: .value("kg", p.kg))
                        .symbolSize(24)
                }
                .chartYScale(domain: lo...hi)
                .chartXAxis {
                    AxisMarks(preset: .aligned, values: .stride(by: .day, count: window <= 7 ? 1 : (window <= 30 ? 7 : 21))) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day().month(.defaultDigits).locale(germanLocale))
                    }
                }
                .frame(height: 150)
            }
            .card()
        }
    }
}
