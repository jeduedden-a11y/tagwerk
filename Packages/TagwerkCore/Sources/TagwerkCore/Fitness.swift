import Foundation

// Runs and weight, computed exactly like the vault's own charts:
// "01 Leben/Fittness/Laufen/Lauf Chart.canvas" and "01 Leben/Fittness/Gewichtsverlauf.canvas".

// MARK: - Run notes

/// One run note in "Laufzeiten": file name YYYY-MM-DD, frontmatter distance "3.02" and time 00:16:29.
public struct RunRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// tagwerk_id, set for runs created by the app.
    public var runId: String?
    public var path: String?
    public var date: String
    public var distanceKm: Double
    public var seconds: Int
    /// "gps" or "manuell" for runs from the app, nil for runs typed in Obsidian.
    public var source: String?
    public var hasRoute: Bool

    public init(id: String, runId: String?, path: String?, date: String, distanceKm: Double, seconds: Int, source: String? = nil, hasRoute: Bool = false) {
        self.id = id
        self.runId = runId
        self.path = path
        self.date = date
        self.distanceKm = distanceKm
        self.seconds = seconds
        self.source = source
        self.hasRoute = hasRoute
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        runId = (try? c.decodeIfPresent(String.self, forKey: .runId)) ?? nil
        path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? nil
        date = try c.decode(String.self, forKey: .date)
        distanceKm = (try? c.decode(Double.self, forKey: .distanceKm)) ?? 0
        seconds = (try? c.decode(Int.self, forKey: .seconds)) ?? 0
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? nil
        hasRoute = (try? c.decode(Bool.self, forKey: .hasRoute)) ?? false
    }

    public var minutes: Double { Double(seconds) / 60 }
    /// Minutes per kilometre.
    public var pace: Double { distanceKm > 0 ? minutes / distanceKm : .infinity }
    public var isValid: Bool { distanceKm > 0 && seconds > 0 && pace.isFinite && DayKey.ordinal(date) != nil }
}

public enum RunTime {
    /// "00:16:29", "16:29" or "1:18:51" in seconds.
    public static func seconds(_ s: String) -> Int? {
        let raw = s.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        let parts = raw.map { Int($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        let p = parts.compactMap { $0 }
        guard p.allSatisfy({ $0 >= 0 }) else { return nil }
        switch p.count {
        case 3:
            guard p[1] < 60, p[2] < 60 else { return nil }
            return p[0] * 3600 + p[1] * 60 + p[2]
        case 2:
            guard p[1] < 60 else { return nil }
            return p[0] * 60 + p[1]
        default:
            return nil
        }
    }

    /// The vault's notation: always hours, minutes, seconds with two digits.
    public static func vault(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// "16:29" or "1:18:51" (minutesToHMS in the chart).
    public static func display(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Pace in minutes per km as "5:16" (minutesToMMSS in the chart).
    public static func pace(_ minutes: Double) -> String {
        guard minutes.isFinite, minutes >= 0 else { return "–" }
        let total = Int((minutes * 60).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "3.02", the vault's distance notation.
    public static func distance(_ km: Double) -> String { String(format: "%.2f", km) }
}

// MARK: - Score colours of the run chart

public enum RunScale {
    /// Weights of the performance score, as in the canvas: distance counts more than pace.
    public static let wDist = 0.65
    public static let wPace = 0.35
    static let upperEase = 2.4

    static func ease(_ t: Double) -> Double { pow(min(1, max(0, t)), upperEase) }

    /// scoreToColor(): red at -limit, yellow at -limit/2, green at 0, blue at +limit, purple at +2 limit.
    /// Above 0 the change starts later and catches up faster (t to the power of 2.4).
    public static func color(score: Double, limit: Double) -> RGB {
        let half = limit / 2
        if score <= -half { return RGB.mix(RatingScale.red, RatingScale.yellow, (max(score, -limit) + limit) / half) }
        if score <= 0 { return RGB.mix(RatingScale.yellow, RatingScale.green, (score + half) / half) }
        if score <= limit { return RGB.mix(RatingScale.green, RatingScale.blue, ease(score / limit)) }
        return RGB.mix(RatingScale.blue, RatingScale.purple, ease(min((score - limit) / limit, 1)))
    }

    /// Legend: 41 stops from -limit to +2 limit.
    public static func legend(limit: Double, count: Int = 40) -> [(location: Double, color: RGB)] {
        (0...count).map { i in
            let s = -limit + Double(i) / Double(count) * (2 * limit * 1.5)
            return (Double(i) / Double(count), color(score: s, limit: limit))
        }
    }
}

// MARK: - Run chart

public struct RunChartModel: Sendable {
    public struct Point: Sendable, Identifiable, Hashable {
        public var id: String { run.id }
        public var run: RunRecord
        /// Milliseconds of the run's day (UTC midnight), the chart's z axis.
        public var ts: Double
        public var distance: Double
        public var pace: Double
        public var score: Double
        public var zDist: Double
        public var zPace: Double
    }

    /// Node of the interpolated surface in the 3D view; x, y, z normalised to 0...1.
    public struct SurfaceNode: Sendable, Hashable {
        public var x: Double
        public var y: Double
        public var z: Double
        public var distance: Double
        public var pace: Double
        public var score: Double
    }

    /// All valid runs, sorted by date; the date filter indexes into this list.
    public let all: [RunRecord]
    public let range: ClosedRange<Int>
    public let points: [Point]
    public let xMin: Double, xMax: Double, xSpan: Double
    public let yMin: Double, yMax: Double
    public let zMin: Double, zMax: Double, zSpan: Double
    public let xMedian: Double, yMedian: Double
    public let slope: Double, intercept: Double, r: Double
    public let distMean: Double, distStd: Double, paceMean: Double, paceStd: Double

    public static func sorted(_ runs: [RunRecord]) -> [RunRecord] {
        runs.filter(\.isValid).sorted { ($0.date, $0.path ?? $0.id) < ($1.date, $1.path ?? $1.id) }
    }

    static func ts(_ key: String) -> Double { Double(DayKey.ordinal(key) ?? 0) * 86_400_000 }

    static func median(_ a: [Double]) -> Double {
        let s = a.sorted()
        let m = s.count / 2
        return s.count % 2 != 0 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    static func mean(_ a: [Double]) -> Double { a.reduce(0, +) / Double(a.count) }

    static func std(_ a: [Double], _ m: Double) -> Double {
        guard a.count >= 2 else { return 0 }
        return sqrt(a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(a.count - 1))
    }

    /// nil without a single valid run. `range` are indices into the sorted list (the canvas' two sliders).
    public init?(runs: [RunRecord], range: ClosedRange<Int>? = nil) {
        let all = Self.sorted(runs)
        guard !all.isEmpty else { return nil }
        let maxIdx = all.count - 1
        let lo = min(max(range?.lowerBound ?? 0, 0), maxIdx)
        let hi = min(max(range?.upperBound ?? maxIdx, lo), maxIdx)
        self.all = all
        self.range = lo...hi
        let dp = Array(all[lo...hi])

        let xs = dp.map(\.distanceKm)
        let ys = dp.map(\.pace)
        let zs = dp.map { Self.ts($0.date) }
        xMedian = Self.median(xs)
        yMedian = Self.median(ys)

        // Axis range from the real minimum and maximum, not from mean or median.
        let xRawMin = xs.min()!, xRawMax = xs.max()!
        let xRange = (xRawMax - xRawMin) == 0 ? 1 : xRawMax - xRawMin
        let x0 = max(0, xRawMin - xRange * 0.1)
        let x1 = xRawMax + xRange * 0.1
        xMin = x0
        xMax = x1

        let yRawMin = ys.min()!, yRawMax = ys.max()!
        let yRange = (yRawMax - yRawMin) == 0 ? 0.3 : yRawMax - yRawMin
        let yPad = max(yRange * 0.15, 0.1)
        yMin = yRawMin - yPad
        yMax = yRawMax + yPad

        // Linear regression pace ~ distance
        let n = Double(xs.count)
        let xm = xs.reduce(0, +) / n, ym = ys.reduce(0, +) / n
        var num = 0.0, dx2 = 0.0, dy2 = 0.0
        for i in xs.indices {
            let dx = xs[i] - xm, dy = ys[i] - ym
            num += dx * dy
            dx2 += dx * dx
            dy2 += dy * dy
        }
        slope = dx2 != 0 ? num / dx2 : 0
        intercept = ym - slope * xm
        r = (dx2 > 0 && dy2 > 0) ? num / sqrt(dx2 * dy2) : 0

        let zRawMin = zs.min()!, zRawMax = zs.max()!
        let zRange = (zRawMax - zRawMin) == 0 ? 86_400_000 : zRawMax - zRawMin
        let z0 = zRawMin - zRange * 0.08
        let z1 = zRawMax + zRange * 0.08
        zMin = z0
        zMax = z1
        xSpan = (x1 - x0) == 0 ? 1 : x1 - x0
        zSpan = (z1 - z0) == 0 ? 1 : z1 - z0

        // Mean and sigma refer to the filtered runs only: colours show performance relative to the period.
        let dMean = Self.mean(xs), pMean = Self.mean(ys)
        let dStd = Self.std(xs, dMean), pStd = Self.std(ys, pMean)
        let dS = dStd == 0 ? 1 : dStd
        let pS = pStd == 0 ? 1 : pStd
        distMean = dMean
        paceMean = pMean
        distStd = dS
        paceStd = pS
        points = dp.map { run in
            let zD = (run.distanceKm - dMean) / dS
            let zP = (pMean - run.pace) / pS
            return Point(run: run, ts: Self.ts(run.date), distance: run.distanceKm, pace: run.pace,
                         score: RunScale.wDist * zD + RunScale.wPace * zP, zDist: zD, zPace: zP)
        }
    }

    /// z-score: distance more is better, pace less is better.
    public func score(distance: Double, pace: Double) -> Double {
        RunScale.wDist * (distance - distMean) / distStd + RunScale.wPace * (paceMean - pace) / paceStd
    }

    public func normX(_ distance: Double) -> Double { min(1, max(0, (distance - xMin) / xSpan)) }
    public func normY(_ pace: Double) -> Double { min(1, max(0, (yMax - pace) / (yMax - yMin))) }
    public func normZ(_ ts: Double) -> Double { min(1, max(0, (ts - zMin) / zSpan)) }

    public var correlationLabel: String {
        let a = abs(r)
        if a < 0.2 { return "kaum Korrelation" }
        let strength = a < 0.5 ? "schwache" : a < 0.7 ? "moderate" : "starke"
        return "\(strength) \(r > 0 ? "positive" : "negative") Korrelation"
    }

    /// "03.02.26 – 15.08.26 · 8 von 8 Läufen" in the canvas' long date form.
    public var rangeLabel: String {
        "\(Self.longDate(all[range.lowerBound].date)) – \(Self.longDate(all[range.upperBound].date)) · \(range.count) von \(all.count) Läufen"
    }

    public static func longDate(_ key: String) -> String {
        let p = key.split(separator: "-")
        guard p.count == 3 else { return key }
        return "\(p[2]).\(p[1]).\(p[0])"
    }

    public static func tickDate(ms: Double) -> String {
        let key = DayKey.fromOrdinal(Int((ms / 86_400_000).rounded(.down)))
        let p = key.split(separator: "-")
        guard p.count == 3 else { return key }
        return "\(p[2]).\(p[1]).\(p[0].suffix(2))"
    }

    /// Screen position of a run in the 3D octant, 0...1 per axis (before scaling to the axis length).
    public func position(distance: Double, pace: Double, swapped: Bool) -> (x: Double, y: Double) {
        swapped ? (normY(pace), normX(distance)) : (normX(distance), normY(pace))
    }

    /// The interpolated surface of the 3D view (inverse distance weighting). Without swap the grid
    /// runs over distance and date and pace is interpolated; swapped it runs over pace and date.
    public func surface(swapped: Bool, resolution: Int = 16) -> [SurfaceNode] {
        let norm = points.map { (distN: normX($0.distance), paceN: normY($0.pace), zn: normZ($0.ts), distance: $0.distance, pace: $0.pace) }
        func idw(_ xn: Double, _ zn: Double) -> Double {
            var num = 0.0, den = 0.0
            for p in norm {
                let dx = xn - (swapped ? p.paceN : p.distN)
                let dz = zn - p.zn
                let d2 = dx * dx + dz * dz
                let field = swapped ? p.distance : p.pace
                if d2 < 1e-9 { return field }
                let w = 1 / d2
                num += w * field
                den += w
            }
            return den > 0 ? num / den : (swapped ? xMedian : yMedian)
        }
        var nodes: [SurfaceNode] = []
        nodes.reserveCapacity(resolution * resolution)
        let g = Double(max(2, resolution) - 1)
        for i in 0..<resolution {
            let fx = Double(i) / g
            for j in 0..<resolution {
                let fz = Double(j) / g
                let distance: Double, pace: Double
                if swapped {
                    pace = yMax - fx * (yMax - yMin)
                    distance = idw(fx, fz)
                } else {
                    distance = xMin + fx * xSpan
                    pace = idw(fx, fz)
                }
                let pos = position(distance: distance, pace: pace, swapped: swapped)
                nodes.append(SurfaceNode(x: pos.x, y: pos.y, z: fz, distance: distance, pace: pace, score: score(distance: distance, pace: pace)))
            }
        }
        return nodes
    }
}

// MARK: - Run energy

public enum RunEnergy {
    /// Extra energy of a run on top of the activity level already in the daily need.
    /// Net cost of running about 1 kcal per kg and km (ACSM running equation: 0.2 ml O2 per kg and metre,
    /// 5 kcal per litre O2), minus what the activity factor already counts for that time.
    public static func kcal(distanceKm: Double, seconds: Int, weightKg: Double, bmr: Double, pal: Double) -> Double {
        guard distanceKm > 0, weightKg > 0 else { return 0 }
        let net = 1.0 * weightKg * distanceKm
        let already = max(0, pal - 1) * bmr * (Double(seconds) / 60) / 1440
        return max(0, net - already)
    }
}

// MARK: - Weight chart

public struct WeightChartModel: Sendable {
    public enum Mode: String, Sendable, CaseIterable { case month, year }

    public struct Entry: Sendable, Hashable, Identifiable {
        public var date: String
        public var kg: Double
        public var id: String { date }
    }

    public struct Segment: Sendable, Hashable, Identifiable {
        public var from: Entry
        public var to: Entry
        public var diff: Double
        /// Stroke width as in the canvas: 1.5 + |diff| * 3, at most 10.
        public var width: Double
        public var id: String { from.date + to.date }
    }

    public let entries: [Entry]
    public let median: Double
    public let yMin: Double
    public let yMax: Double

    /// Entries sorted by date; nil without any weight.
    public init?(weights: [(date: String, kg: Double)]) {
        let e = weights.filter { DayKey.ordinal($0.date) != nil && $0.kg.isFinite }
            .map { Entry(date: $0.date, kg: $0.kg) }
            .sorted { $0.date < $1.date }
        guard !e.isEmpty else { return nil }
        entries = e
        let kg = e.map(\.kg)
        let m = RunChartModel.median(kg)
        median = m
        // Scale symmetric around the median of all entries, padded by 20 %.
        let maxDev = max(kg.map { abs($0 - m) }.max() ?? 0, 1)
        yMin = m - maxDev * 1.2
        yMax = m + maxDev * 1.2
    }

    static func parts(_ key: String) -> (y: Int, m: Int, d: Int) {
        let p = key.split(separator: "-").compactMap { Int($0) }
        return p.count == 3 ? (p[0], p[1], p[2]) : (1970, 1, 1)
    }

    static func key(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%04d-%02d-%02d", y, m, d) }

    static func daysIn(_ y: Int, _ m: Int) -> Int {
        let next = m == 12 ? key(y + 1, 1, 1) : key(y, m + 1, 1)
        return DayKey.distance(from: key(y, m, 1), to: next) ?? 30
    }

    /// Number of periods after the first one; offsets run 0...maxOffset from the first entry's month or year.
    public func maxOffset(_ mode: Mode) -> Int {
        let a = Self.parts(entries.first!.date), b = Self.parts(entries.last!.date)
        return mode == .month ? (b.y - a.y) * 12 + (b.m - a.m) : b.y - a.y
    }

    /// First and last day of the window, inclusive, and its label ("November 2026", "2026").
    public func window(_ mode: Mode, offset: Int) -> (start: String, end: String, label: String) {
        let a = Self.parts(entries.first!.date)
        switch mode {
        case .month:
            let total = a.y * 12 + (a.m - 1) + offset
            let y = total / 12, m = total % 12 + 1
            return (Self.key(y, m, 1), Self.key(y, m, Self.daysIn(y, m)), "\(DayKey.monthNames[m - 1]) \(y)")
        case .year:
            let y = a.y + offset
            return (Self.key(y, 1, 1), Self.key(y, 12, 31), "\(y)")
        }
    }

    public func visible(_ mode: Mode, offset: Int) -> [Entry] {
        let w = window(mode, offset: offset)
        return entries.filter { $0.date >= w.start && $0.date <= w.end }
    }

    /// Connecting lines: green when the weight went up, red when it went down (colours of the canvas).
    public static func segments(_ visible: [Entry]) -> [Segment] {
        guard visible.count >= 2 else { return [] }
        return (1..<visible.count).map { i in
            let d = visible[i].kg - visible[i - 1].kg
            return Segment(from: visible[i - 1], to: visible[i], diff: d, width: min(1.5 + abs(d) * 3, 10))
        }
    }

    public var yTicks: [Double] { (0...4).map { yMin + Double($0) / 4 * (yMax - yMin) } }

    /// Ticks of the x axis: every ceil(days/8) days in a month, the twelve months in a year.
    public func xTicks(_ mode: Mode, offset: Int) -> [String] {
        let w = window(mode, offset: offset)
        switch mode {
        case .month:
            let days = (DayKey.distance(from: w.start, to: w.end) ?? 29) + 1
            let step = Int((Double(days) / 8).rounded(.up))
            return stride(from: 0, to: days, by: max(1, step)).map { DayKey.adding($0, to: w.start) }
        case .year:
            let y = Self.parts(w.start).y
            return (1...12).map { Self.key(y, $0, 1) }
        }
    }

    public static func footer(count: Int, median: Double) -> String {
        "\(count) Eintr\(count == 1 ? "ag" : "äge") in diesem Zeitraum · Median gesamt: \(String(format: "%.1f", median).replacingOccurrences(of: ".", with: ",")) kg"
    }
}
