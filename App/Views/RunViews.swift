import Charts
import CoreLocation
import MapKit
import SwiftUI
import TagwerkCore

extension Color {
    static let run = Color(hex: "#378ADD")
    static let trend = Color(hex: "#7F77DD")
}

enum RunFormat {
    static func km(_ v: Double) -> String { Format.decimal(RunTime.distance(v)) }
    static func sigma(_ v: Double) -> String { Format.decimal(String(format: "%.2f", v)) }
    static func signed(_ v: Double) -> String { (v > 0 ? "+" : "") + sigma(v) }
}

// MARK: - Page

struct RunsPage: View {
    @Environment(Store.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            Button {
                store.showRecorder = true
            } label: {
                Label("Aufzeichnen", systemImage: "figure.run")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.run)
            .accessibilityLabel("Lauf aufzeichnen")
            Button {
                store.runEntry = RunEntryRequest(run: nil, date: store.today)
            } label: {
                Label("Eintragen", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        RunChartCard()
        RunStatsCard()
        RunListCard()
    }
}

// MARK: - Chart (Lauf Chart.canvas)

struct RunChartCard: View {
    @Environment(Store.self) private var store
    @State private var mode3D = false
    @State private var limit = 1.0
    @State private var startIdx = 0
    @State private var endIdx: Int?
    @State private var swapped = false
    @State private var selected: String?

    var body: some View {
        let all = RunChartModel.sorted(store.state.runs)
        VStack(alignment: .leading, spacing: 12) {
            Text("Laufen — Distanz vs. Pace")
                .font(.headline)
            if all.isEmpty {
                Text("Noch keine Läufe. Zeichne einen auf oder trag ihn ein; die Notizen aus deinem Ordner Laufzeiten erscheinen hier nach dem nächsten Abgleich.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                let maxIdx = all.count - 1
                let lo = min(startIdx, maxIdx)
                let hi = min(endIdx ?? maxIdx, maxIdx)
                if let model = RunChartModel(runs: all, range: min(lo, hi)...max(lo, hi)) {
                    Picker("Ansicht", selection: $mode3D) {
                        Text("2D").tag(false)
                        Text("3D").tag(true)
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 8) {
                        Text("Farbskala-Breite").font(.caption).foregroundStyle(.secondary)
                        // No step: iOS 26 would draw tick marks; rounded to 0.05 like the canvas slider.
                        Slider(value: Binding(get: { limit }, set: { limit = max(0.25, ($0 * 20).rounded() / 20) }), in: 0.25...5)
                        Text("±\(RunFormat.sigma(limit))σ")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .frame(minWidth: 54, alignment: .trailing)
                    }

                    if all.count >= 2 {
                        VStack(spacing: 2) {
                            HStack(spacing: 8) {
                                Text("Zeitraum").font(.caption).foregroundStyle(.secondary)
                                Slider(value: Binding(get: { Double(lo) }, set: { startIdx = Int($0.rounded()); selected = nil }), in: 0...Double(maxIdx))
                                Slider(value: Binding(get: { Double(hi) }, set: { endIdx = Int($0.rounded()); selected = nil }), in: 0...Double(maxIdx))
                                Button("Alle") {
                                    startIdx = 0
                                    endIdx = nil
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .tint(lo == 0 && hi == maxIdx ? Color.secondary : Color.accentColor)
                            }
                            Text(model.rangeLabel)
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                    }

                    if mode3D {
                        Run3DView(model: model, limit: limit, swapped: $swapped, selected: $selected)
                    } else {
                        Run2DChart(model: model, limit: limit, selected: $selected)
                            .frame(height: 300)
                        HStack(spacing: 14) {
                            HStack(spacing: 4) {
                                Capsule().fill(Color.trend).frame(width: 16, height: 2)
                                Text("Trendlinie")
                            }
                            Text("r = \(RunFormat.sigma(model.r)) (\(model.correlationLabel))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    }

                    if let id = selected, let p = model.points.first(where: { $0.id == id }) {
                        RunTooltip(point: p)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    ScoreLegend(limit: limit)
                    Text("Score = 0,65 × Distanz-σ + 0,35 × Pace-σ (jeweils Abweichung vom Mittel in Standardabweichungen) · Ø Distanz \(RunFormat.km(model.distMean)) km (σ \(RunFormat.sigma(model.distStd))) · Ø Pace \(RunTime.pace(model.paceMean)) (σ \(RunTime.pace(model.paceStd)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .card()
        .animation(.smooth, value: selected)
    }
}

struct ScoreLegend: View {
    var limit: Double

    var body: some View {
        HStack(spacing: 8) {
            Text("−\(RunFormat.sigma(limit))σ")
            LinearGradient(stops: RunScale.legend(limit: limit).map { Gradient.Stop(color: Color(rgb: $0.color), location: $0.location) },
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 150, height: 8)
                .clipShape(.capsule)
            Text("+\(RunFormat.sigma(limit))σ und mehr")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Farbskala von rot unter dem Schnitt über grün bis blau und lila über dem Schnitt")
    }
}

struct RunTooltip: View {
    var point: RunChartModel.Point

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(RunChartModel.longDate(point.run.date)).font(.subheadline.weight(.semibold))
            Text("Zeit: \(RunTime.vault(point.run.seconds))")
            Text("Distanz: \(RunFormat.km(point.distance)) km (\(RunFormat.signed(point.zDist)) σ)")
            Text("Pace: \(RunTime.pace(point.pace)) min/km (\(RunFormat.signed(point.zPace)) σ)")
            Text("Score: \(RunFormat.sigma(point.score))")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.10), in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The 2D view of the canvas: distance on x, pace on y (shorter pace at the top), medians dashed, linear trend.
struct Run2DChart: View {
    var model: RunChartModel
    var limit: Double
    @Binding var selected: String?

    struct Dot: Identifiable {
        let id: String
        let x: Double
        let y: Double
        let rgb: RGB
        let selected: Bool
        let spoken: String
    }

    struct TrendPoint: Identifiable {
        let id: Int
        let x: Double
        let y: Double
    }

    private var dots: [Dot] {
        model.points.map { p in
            Dot(id: p.id, x: p.distance, y: -p.pace, rgb: RunScale.color(score: p.score, limit: limit), selected: p.id == selected,
                spoken: RunChartModel.longDate(p.run.date) + ", " + Self.spoken(p))
        }
    }

    private var trend: [TrendPoint] {
        let a: Double = -(model.slope * model.xMin + model.intercept)
        let b: Double = -(model.slope * model.xMax + model.intercept)
        return [TrendPoint(id: 0, x: model.xMin, y: a), TrendPoint(id: 1, x: model.xMax, y: b)]
    }

    @ChartContentBuilder
    private var medians: some ChartContent {
        RuleMark(x: .value("Median Distanz", model.xMedian))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .foregroundStyle(Color.secondary.opacity(0.5))
        RuleMark(y: .value("Median Pace", -model.yMedian))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .foregroundStyle(Color.secondary.opacity(0.5))
    }

    /// A ring in the background colour under the coloured dot, like the stroke in the canvas.
    @ChartContentBuilder
    private func mark(_ d: Dot) -> some ChartContent {
        let x: PlottableValue<Double> = .value("Distanz", d.x)
        let y: PlottableValue<Double> = .value("Pace", d.y)
        let size: CGFloat = d.selected ? 200 : 100
        PointMark(x: x, y: y)
            .foregroundStyle(d.selected ? Color.primary : Color(uiColor: .systemBackground))
            .symbolSize(size * 1.7)
        PointMark(x: x, y: y)
            .foregroundStyle(Color(rgb: d.rgb))
            .symbolSize(size)
            .accessibilityLabel(Text(d.spoken))
    }

    @ChartContentBuilder
    private var trendLine: some ChartContent {
        ForEach(trend) { t in
            LineMark(x: .value("Distanz", t.x), y: .value("Pace", t.y), series: .value("Linie", "Trend"))
                .foregroundStyle(Color.trend)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
    }

    var body: some View {
        let xTicks: [Double] = (0...5).map { model.xMin + Double($0) / 5 * model.xSpan }
        let yTicks: [Double] = (0...5).map { -(model.yMin + Double($0) / 5 * (model.yMax - model.yMin)) }
        let points: [Dot] = dots
        Chart {
            medians
            trendLine
            ForEach(points) { d in
                mark(d)
            }
        }
        .chartXScale(domain: model.xMin...model.xMax)
        .chartYScale(domain: (-model.yMax)...(-model.yMin))
        .chartXAxis {
            AxisMarks(values: xTicks) { v in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                AxisTick()
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text("\(RunFormat.km(d)) km").font(.caption2) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: yTicks) { v in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                AxisTick()
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(RunTime.pace(-d)).font(.caption2) }
                }
            }
        }
        .chartXAxisLabel(position: .bottom, alignment: .center) { Text("Distanz (km)").font(.caption.weight(.semibold)) }
        .chartYAxisLabel(position: .leading, alignment: .center) { Text("Pace (kürzer = oben)").font(.caption.weight(.semibold)) }
        .chartPlotStyle { $0.clipped() }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    .onTapGesture { location in
                        guard let frame = proxy.plotFrame else { return }
                        let origin = geo[frame].origin
                        var best: (id: String, d: CGFloat)?
                        for p in model.points {
                            guard let pos = proxy.position(for: (p.distance, -p.pace)) else { continue }
                            let d = hypot(pos.x + origin.x - location.x, pos.y + origin.y - location.y)
                            if d < (best?.d ?? 34) { best = (p.id, d) }
                        }
                        selected = best?.id == selected ? nil : best?.id
                    }
            }
        }
    }
}

extension Run2DChart {
    static func spoken(_ p: RunChartModel.Point) -> String {
        let km = RunFormat.km(p.distance)
        let pace = RunTime.pace(p.pace)
        let score = RunFormat.sigma(p.score)
        return km + " Kilometer, Pace " + pace + ", Score " + score
    }
}

struct RunDot: View {
    var rgb: RGB
    var selected: Bool

    var body: some View {
        let size: CGFloat = selected ? 18 : 12
        Circle()
            .fill(Color(rgb: rgb))
            .overlay(Circle().stroke(selected ? Color.primary : Color(uiColor: .systemBackground), lineWidth: selected ? 2 : 1.5))
            .frame(width: size, height: size)
    }
}

/// The 3D view of the canvas: one octant (distance, pace, date), interpolated surface, same projection.
struct Run3DView: View {
    var model: RunChartModel
    var limit: Double
    @Binding var swapped: Bool
    @Binding var selected: String?
    @State private var rotY = -35.0
    @State private var rotX = 22.0
    @State private var zoom = 1.0
    @State private var lastDrag: CGSize = .zero
    @State private var zoomStart: Double?
    @Environment(\.colorScheme) private var scheme

    static let axisLen = 120.0
    static let focal = 520.0
    static let center = CGPoint(x: 380, y: 300)
    /// Part of the canvas' 760 x 560 drawing that is shown: the octant fills the phone's width.
    static let window = CGRect(x: 225, y: 145, width: 310, height: 310)

    struct Projected {
        var p: CGPoint
        var depth: Double
        var scale: Double
    }

    func project(_ xw: Double, _ yw: Double, _ zw: Double) -> Projected {
        let half = Self.axisLen / 2
        let ry = rotY * .pi / 180, rx = rotX * .pi / 180
        let xc = xw - half, yc = yw - half, zc = zw - half
        let x1 = xc * cos(ry) - zc * sin(ry)
        let z1 = xc * sin(ry) + zc * cos(ry)
        let y2 = yc * cos(rx) - z1 * sin(rx)
        let z2 = yc * sin(rx) + z1 * cos(rx)
        let scale = (Self.focal / (Self.focal + z2)) * zoom
        return Projected(p: CGPoint(x: Self.center.x + CGFloat(x1 * scale), y: Self.center.y - CGFloat(y2 * scale)), depth: z2, scale: scale)
    }

    private func world(_ x: Double, _ y: Double, _ z: Double) -> Projected { project(x * Self.axisLen, y * Self.axisLen, z * Self.axisLen) }

    var body: some View {
        VStack(spacing: 8) {
            Text("Ziehen zum Drehen · zwei Finger zum Zoomen · Punkt antippen")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Ansicht zurücksetzen") {
                    withAnimation(.smooth) {
                        rotY = -35
                        rotX = 22
                        zoom = 1
                    }
                }
                Button(swapped ? "Distanz auf X-Achse" : "Pace auf X-Achse") { swapped.toggle() }
            }
            .buttonStyle(.bordered)
            .font(.caption)
            GeometryReader { geo in
                let size = geo.size
                let s = min(size.width / Self.window.width, size.height / Self.window.height)
                let ox = (size.width - Self.window.width * s) / 2 - Self.window.minX * s
                let oy = (size.height - Self.window.height * s) / 2 - Self.window.minY * s
                Canvas { ctx, _ in
                    draw(ctx, s: s, ox: ox, oy: oy)
                }
                .contentShape(.rect)
                .onTapGesture { location in
                    var best: (id: String, d: CGFloat)?
                    for p in model.points {
                        let pos = model.position(distance: p.distance, pace: p.pace, swapped: swapped)
                        let q = world(pos.x, pos.y, model.normZ(p.ts))
                        let c = CGPoint(x: ox + q.p.x * s, y: oy + q.p.y * s)
                        let d = hypot(c.x - location.x, c.y - location.y)
                        if d < (best?.d ?? 30) { best = (p.id, d) }
                    }
                    selected = best?.id == selected ? nil : best?.id
                }
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { v in
                            let dx = v.translation.width - lastDrag.width
                            let dy = v.translation.height - lastDrag.height
                            lastDrag = v.translation
                            rotY += Double(dx) * 0.4
                            rotX = min(80, max(-80, rotX - Double(dy) * 0.4))
                        }
                        .onEnded { _ in lastDrag = .zero }
                )
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { v in
                            if zoomStart == nil { zoomStart = zoom }
                            zoom = min(4, max(0.4, (zoomStart ?? 1) * Double(v.magnification)))
                        }
                        .onEnded { _ in zoomStart = nil }
                )
            }
            .aspectRatio(1, contentMode: .fit)
            .accessibilityElement()
            .accessibilityLabel("Dreidimensionale Ansicht der Läufe nach Distanz, Pace und Datum")
        }
    }

    private func draw(_ ctx: GraphicsContext, s: CGFloat, ox: CGFloat, oy: CGFloat) {
        let L = Self.axisLen
        func pt(_ q: Projected) -> CGPoint { CGPoint(x: ox + q.p.x * s, y: oy + q.p.y * s) }
        func line(_ a: (Double, Double, Double), _ b: (Double, Double, Double), opacity: Double = 0.7, dash: [CGFloat] = []) {
            var path = Path()
            path.move(to: pt(project(a.0, a.1, a.2)))
            path.addLine(to: pt(project(b.0, b.1, b.2)))
            ctx.stroke(path, with: .color(Color.secondary.opacity(opacity)), style: StrokeStyle(lineWidth: 1.5 * s, dash: dash.map { $0 * s }))
        }
        // Axes of the octant and hinted cube edges
        line((0, 0, 0), (L, 0, 0))
        line((0, 0, 0), (0, L, 0))
        line((0, 0, 0), (0, 0, L))
        line((L, 0, 0), (L, 0, L), opacity: 0.3, dash: [3, 4])
        line((0, 0, L), (L, 0, L), opacity: 0.3, dash: [3, 4])
        line((L, 0, 0), (L, L, 0), opacity: 0.2, dash: [3, 4])
        line((0, 0, L), (0, L, L), opacity: 0.2, dash: [3, 4])
        line((0, L, 0), (L, L, 0), opacity: 0.2, dash: [3, 4])
        line((0, L, 0), (0, L, L), opacity: 0.2, dash: [3, 4])

        // Surface, painted back to front
        let nodes = model.surface(swapped: swapped)
        let g = 16
        var quads: [(path: Path, color: Color, depth: Double)] = []
        quads.reserveCapacity((g - 1) * (g - 1))
        for i in 0..<(g - 1) {
            for j in 0..<(g - 1) {
                let n = [nodes[i * g + j], nodes[(i + 1) * g + j], nodes[(i + 1) * g + j + 1], nodes[i * g + j + 1]]
                let q = n.map { world($0.x, $0.y, $0.z) }
                var path = Path()
                path.move(to: pt(q[0]))
                for k in 1..<4 { path.addLine(to: pt(q[k])) }
                path.closeSubpath()
                let score = n.reduce(0) { $0 + $1.score } / 4
                quads.append((path, Color(rgb: RunScale.color(score: score, limit: limit)), q.reduce(0) { $0 + $1.depth } / 4))
            }
        }
        for q in quads.sorted(by: { $0.depth > $1.depth }) {
            ctx.fill(q.path, with: .color(q.color.opacity(0.8)))
            ctx.stroke(q.path, with: .color(q.color), lineWidth: 0.4 * s)
        }

        // Ticks
        func label(_ text: String, at q: Projected, dy: CGFloat = 0, anchor: UnitPoint = .center, size: CGFloat = 10, bold: Bool = false) {
            var p = pt(q)
            p.y += dy * s
            ctx.draw(Text(text).font(.system(size: size * s, weight: bold ? .semibold : .regular)).foregroundStyle(bold ? Color.primary : Color.secondary), at: p, anchor: anchor)
        }
        for f in [0.0, 0.5, 1.0] {
            let dist = "\(RunFormat.km(model.xMin + f * model.xSpan)) km"
            let pace = RunTime.pace(model.yMax - f * (model.yMax - model.yMin))
            label(swapped ? pace : dist, at: project(f * L, 0, 0), dy: 14)
            label(swapped ? dist : pace, at: project(-8, f * L, 0), anchor: .trailing)
            label(RunChartModel.tickDate(ms: model.zMin + f * model.zSpan), at: project(0, 0, f * L), dy: 14)
        }
        label(swapped ? "Pace (kürzer = rechts)" : "Distanz (km)", at: project(L + 16, 0, 0), size: 12, bold: true)
        label(swapped ? "Distanz (km)" : "Pace (kürzer = oben)", at: project(0, L + 16, 0), size: 12, bold: true)
        label("Datum", at: project(0, 0, L + 16), size: 12, bold: true)

        // Runs, back to front
        let bg = Color(uiColor: .systemBackground)
        let pts = model.points.map { p -> (Projected, RunChartModel.Point) in
            let pos = model.position(distance: p.distance, pace: p.pace, swapped: swapped)
            return (world(pos.x, pos.y, model.normZ(p.ts)), p)
        }.sorted { $0.0.depth > $1.0.depth }
        for (q, p) in pts {
            let r = CGFloat(max(3, min(9, 6 * q.scale))) * s * (p.id == selected ? 1.5 : 1)
            let c = pt(q)
            let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            ctx.fill(Path(ellipseIn: rect), with: .color(Color(rgb: RunScale.color(score: p.score, limit: limit)).opacity(max(0.6, min(1, q.scale)))))
            ctx.stroke(Path(ellipseIn: rect), with: .color(p.id == selected ? Color.primary : bg), lineWidth: 1.2 * s)
        }
    }
}

// MARK: - Statistics and list

struct RunStatsCard: View {
    @Environment(Store.self) private var store

    var body: some View {
        let runs = store.state.runs.filter(\.isValid)
        if !runs.isEmpty {
            let today = store.today
            let weekStart = DayKey.weekStart(today)
            let monthStart = String(today.prefix(7)) + "-01"
            let week = runs.filter { $0.date >= weekStart && $0.date <= today }.reduce(0) { $0 + $1.distanceKm }
            let month = runs.filter { $0.date >= monthStart && $0.date <= today }.reduce(0) { $0 + $1.distanceKm }
            let total = runs.reduce(0) { $0 + $1.distanceKm }
            let longest = runs.map(\.distanceKm).max() ?? 0
            let best = runs.filter { $0.distanceKm >= 1 }.map(\.pace).min()
            let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(title: "Statistik", systemImage: "chart.bar.xaxis")
                LazyVGrid(columns: columns, spacing: 10) {
                    stat("Diese Woche", "\(RunFormat.km(week)) km")
                    stat("Dieser Monat", "\(RunFormat.km(month)) km")
                    stat("Gesamt", "\(RunFormat.km(total)) km · \(runs.count) Läufe")
                    stat("Längster Lauf", "\(RunFormat.km(longest)) km")
                    if let best { stat("Schnellste Pace", "\(RunTime.pace(best)) min/km") }
                    stat("Serie", "\(store.streak(store.habits.first { $0.key == "laufen" } ?? HabitConfig.defaults[4], upTo: today).current)")
                }
            }
            .card()
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.run.opacity(0.10), in: .rect(cornerRadius: 14, style: .continuous))
    }
}

struct RunListCard: View {
    @Environment(Store.self) private var store
    @State private var showAll = false
    @State private var detail: RunRecord?

    var body: some View {
        let runs = store.sortedRuns.reversed().map { $0 }
        let model = RunChartModel(runs: store.state.runs)
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "Läufe", systemImage: "list.bullet")
                ForEach(showAll ? runs : Array(runs.prefix(8))) { r in
                    Button {
                        detail = r
                    } label: {
                        RunRow(run: r, score: model?.points.first { $0.id == r.id }?.score, pending: store.state.runPending[r.id] != nil)
                    }
                    .buttonStyle(.plain)
                    if r.id != (showAll ? runs.last?.id : runs.prefix(8).last?.id) { Divider().opacity(0.4) }
                }
                if runs.count > 8 {
                    Button(showAll ? "Weniger anzeigen" : "Alle \(runs.count) anzeigen") { withAnimation(.smooth) { showAll.toggle() } }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                }
            }
            .card()
            .sheet(item: $detail) { r in
                RunDetailSheet(run: r)
            }
        }
    }
}

struct RunRow: View {
    var run: RunRecord
    var score: Double?
    var pending: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(score.map { Color(rgb: RunScale.color(score: $0, limit: 1)) } ?? Color.secondary)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.dayTitle(run.date)).font(.subheadline.weight(.semibold))
                Text("\(RunTime.display(run.seconds)) · \(RunTime.pace(run.pace)) min/km")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if run.hasRoute { Image(systemName: "map").font(.caption).foregroundStyle(.secondary) }
            if pending { Image(systemName: "arrow.up.circle").font(.caption).foregroundStyle(.secondary) }
            Text("\(RunFormat.km(run.distanceKm)) km")
                .font(.headline)
                .monospacedDigit()
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

struct RunDetailSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    var run: RunRecord
    @State private var confirmDelete = false

    var body: some View {
        let route = RouteStore.load(run.id)
        let model = RunChartModel(runs: store.state.runs)
        let point = model?.points.first { $0.id == run.id }
        NavigationStack {
            List {
                if route.count >= 2 {
                    Section {
                        RouteMap(points: route)
                            .frame(height: 240)
                            .listRowInsets(EdgeInsets())
                    }
                }
                Section {
                    LabeledContent("Distanz", value: "\(RunFormat.km(run.distanceKm)) km")
                    LabeledContent("Zeit", value: RunTime.display(run.seconds))
                    LabeledContent("Pace", value: "\(RunTime.pace(run.pace)) min/km")
                    if let point {
                        LabeledContent("Score", value: RunFormat.sigma(point.score))
                        LabeledContent("Distanz im Vergleich", value: "\(RunFormat.signed(point.zDist)) σ")
                        LabeledContent("Pace im Vergleich", value: "\(RunFormat.signed(point.zPace)) σ")
                    }
                } footer: {
                    Text(run.path.map { "Notiz: \($0)" } ?? "Wird beim nächsten Abgleich als Notiz in Laufzeiten angelegt.")
                }
                Section {
                    Button("Bearbeiten") {
                        dismiss()
                        store.runEntry = RunEntryRequest(run: run, date: run.date)
                    }
                    Button("Lauf löschen", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(Format.dayTitle(run.date))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .confirmationDialog("Lauf löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Löschen", role: .destructive) {
                    store.deleteRun(run)
                    dismiss()
                }
            } message: {
                Text("Die Notiz wandert in Obsidian in den Papierkorb.")
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct RouteMap: View {
    var points: [RoutePoint]

    var body: some View {
        let coords = points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
            MapPolyline(coordinates: coords)
                .stroke(Color.run, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            if let first = coords.first { Marker("Start", systemImage: "flag", coordinate: first).tint(.green) }
            if let last = coords.last { Marker("Ziel", systemImage: "flag.checkered", coordinate: last).tint(Color.run) }
        }
    }
}

// MARK: - Manual entry

struct RunEntrySheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let request: RunEntryRequest
    @State private var date = Date()
    @State private var distanceText = ""
    @State private var timeText = ""
    @State private var loaded = false
    @FocusState private var field: Int?

    private var km: Double? {
        Double(distanceText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 && $0 < 400 ? $0 : nil }
    }

    private var seconds: Int? { RunTime.seconds(timeText).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Datum", selection: $date, in: ...Date(), displayedComponents: .date)
                    LabeledContent("Distanz") {
                        HStack(spacing: 4) {
                            TextField("5,02", text: $distanceText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .focused($field, equals: 0)
                            Text("km").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Zeit") {
                        TextField("27:13 oder 1:18:51", text: $timeText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .focused($field, equals: 1)
                    }
                    if let km, let seconds {
                        LabeledContent("Pace", value: "\(RunTime.pace(Double(seconds) / 60 / km)) min/km")
                    }
                } footer: {
                    Text("Landet als Notiz JJJJ-MM-TT.md in Laufzeiten, mit distance und time wie deine bisherigen Läufe. Laufen wird an dem Tag abgehakt.")
                }
                if let run = request.run {
                    Section {
                        Button("Lauf löschen", role: .destructive) {
                            store.deleteRun(run)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(request.run == nil ? "Lauf eintragen" : "Lauf bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") { save() }
                        .disabled(km == nil || seconds == nil)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                date = DayKey.date(request.date) ?? Date()
                if let r = request.run {
                    distanceText = RunFormat.km(r.distanceKm)
                    timeText = RunTime.display(r.seconds)
                } else {
                    field = 0
                }
            }
        }
    }

    private func save() {
        guard let km, let seconds else { return }
        let key = DayKey.key(for: date)
        if let run = request.run {
            store.updateRun(run, date: key, distanceKm: km, seconds: seconds)
        } else {
            store.addRun(date: key, distanceKm: km, seconds: seconds, source: "manuell")
        }
        dismiss()
    }
}

// MARK: - GPS recording

struct RunRecorderView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var confirmStop = false
    @State private var result: RunResult?

    struct RunResult: Identifiable {
        var id = UUID()
        var date: String
        var km: Double
        var seconds: Int
        var points: [RoutePoint]
    }

    var body: some View {
        let r = store.recorder
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                UserAnnotation()
                if r.points.count >= 2 {
                    MapPolyline(coordinates: r.points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) })
                        .stroke(Color.run, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .ignoresSafeArea()

            VStack(spacing: 14) {
                if let result {
                    summary(result)
                } else {
                    panel(r)
                    controls(r)
                }
            }
            .padding(16)
        }
        .onAppear {
            if r.phase == .idle { r.prepare() }
        }
        .confirmationDialog("Lauf beenden?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Beenden und prüfen") {
                if let f = r.finish() { result = RunResult(date: f.date, km: f.km, seconds: f.seconds, points: f.points) }
            }
            Button("Verwerfen", role: .destructive) {
                r.discard()
                dismiss()
            }
        }
    }

    private func panel(_ r: RunRecorder) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 10) {
                Text(RunTime.display(Int(r.elapsed(at: ctx.date))))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                HStack(spacing: 0) {
                    metric("Distanz", "\(RunFormat.km(r.distance / 1000)) km")
                    metric("Pace aktuell", r.currentPace.map { RunTime.pace($0) } ?? "–")
                    metric("Pace Schnitt", r.averagePace.map { RunTime.pace($0) } ?? "–")
                }
                HStack(spacing: 6) {
                    Image(systemName: gpsSymbol(r.accuracy))
                    Text(gpsText(r))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let e = r.lastError {
                    Text(e).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func gpsSymbol(_ a: Double?) -> String {
        guard let a, a >= 0 else { return "location.slash" }
        return a <= 10 ? "location.fill" : a <= 25 ? "location" : "location.slash"
    }

    private func gpsText(_ r: RunRecorder) -> String {
        guard let a = r.accuracy, a >= 0 else { return r.phase == .locating ? "Suche GPS …" : "Kein GPS" }
        let q = a <= 10 ? "gut" : a <= 25 ? "brauchbar" : "zu ungenau, wird nicht gezählt"
        return "GPS ±\(Int(a.rounded())) m, \(q)"
    }

    @ViewBuilder
    private func controls(_ r: RunRecorder) -> some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                switch r.phase {
                case .idle, .locating:
                    Button("Abbrechen") {
                        r.discard()
                        dismiss()
                    }
                    .buttonStyle(.glass)
                    Button {
                        r.begin()
                    } label: {
                        Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Color.run)
                case .running:
                    Button {
                        r.pause()
                    } label: {
                        Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    Button {
                        confirmStop = true
                    } label: {
                        Label("Beenden", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                case .paused:
                    Button {
                        r.resumeFromPause()
                    } label: {
                        Label("Weiter", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Color.run)
                    Button {
                        confirmStop = true
                    } label: {
                        Label("Beenden", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
            .controlSize(.large)
            .font(.headline)
        }
    }

    private func summary(_ res: RunResult) -> some View {
        VStack(spacing: 14) {
            Text("Lauf vom \(Format.dayTitle(res.date))").font(.headline)
            HStack(spacing: 0) {
                metric("Distanz", "\(RunFormat.km(res.km)) km")
                metric("Zeit", RunTime.display(res.seconds))
                metric("Pace", res.km > 0 ? RunTime.pace(Double(res.seconds) / 60 / res.km) : "–")
            }
            if res.km < 0.05 {
                Text("Es wurde kaum Strecke gemessen. Ohne gutes GPS (draußen, freie Sicht) bleibt die Distanz bei null.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Verwerfen", role: .destructive) { dismiss() }
                    .buttonStyle(.glass)
                Button {
                    store.addRun(date: res.date, distanceKm: res.km, seconds: res.seconds, source: "gps", route: res.points)
                    dismiss()
                } label: {
                    Text("Speichern").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Color.run)
                .disabled(res.km < 0.05)
            }
            .controlSize(.large)
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }
}
