import Foundation

/// yyyy-MM-dd keys in the user's local calendar; arithmetic via a fixed Gregorian UTC calendar.
public enum DayKey {
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func today(_ now: Date = Date()) -> String { key(for: now) }

    /// Local midnight of the key's day.
    public static func date(_ key: String, calendar: Calendar = .current) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var c = DateComponents()
        c.year = p[0]
        c.month = p[1]
        c.day = p[2]
        return calendar.date(from: c)
    }

    /// Days since 1970-01-01 for the key, independent of time zone and DST.
    public static func ordinal(_ key: String) -> Int? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var c = DateComponents()
        c.year = p[0]
        c.month = p[1]
        c.day = p[2]
        guard let d = utc.date(from: c) else { return nil }
        return Int((d.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    public static func fromOrdinal(_ n: Int) -> String {
        let d = Date(timeIntervalSince1970: Double(n) * 86_400)
        let c = utc.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func adding(_ days: Int, to key: String) -> String {
        guard let o = ordinal(key) else { return key }
        return fromOrdinal(o + days)
    }

    public static func distance(from a: String, to b: String) -> Int? {
        guard let x = ordinal(a), let y = ordinal(b) else { return nil }
        return y - x
    }

    /// 1 = Monday ... 7 = Sunday
    public static func isoWeekday(_ key: String) -> Int {
        guard let o = ordinal(key) else { return 1 }
        // 1970-01-01 was a Thursday (4)
        return ((o % 7) + 7 + 3) % 7 + 1
    }

    /// Monday of the ISO week containing key.
    public static func weekStart(_ key: String) -> String { adding(-(isoWeekday(key) - 1), to: key) }

    static let weekdayNames = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
    static let weekdayShort = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
    static let monthNames = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"]

    public static func weekdayName(_ key: String) -> String { weekdayNames[isoWeekday(key) - 1] }
    public static func weekdayShortName(_ key: String) -> String { weekdayShort[isoWeekday(key) - 1] }

    /// "Sonntag, 1. November"
    public static func longGerman(_ key: String) -> String {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]) else { return key }
        return "\(weekdayName(key)), \(p[2]). \(monthNames[p[1] - 1])"
    }

    /// "1.11."
    public static func shortGerman(_ key: String) -> String {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return key }
        return "\(p[2]).\(p[1])."
    }
}

public struct StreakInfo: Hashable, Sendable {
    public var current: Int
    public var longest: Int
    public var total: Int
    public var lastDone: String?
}

public enum Streaks {
    /// Mirrors the Habits Dashboard: a streak continues while the gap between two
    /// completions is at most `tolerance` days, and is alive while the last completion
    /// is at most `alive` days ago. Streak length counts completions.
    public static func compute(done: [String], today: String, tolerance: Int, alive: Int) -> StreakInfo {
        let ords = Array(Set(done.compactMap(DayKey.ordinal))).sorted()
        guard let last = ords.last, let t = DayKey.ordinal(today) else {
            return StreakInfo(current: 0, longest: 0, total: 0, lastDone: nil)
        }
        var longest = 1
        var run = 1
        for i in 1..<max(1, ords.count) where ords.count > 1 {
            if ords[i] - ords[i - 1] <= tolerance { run += 1 } else { run = 1 }
            longest = max(longest, run)
        }
        var current = 0
        if t - last <= alive && t >= last {
            current = 1
            var i = ords.count - 1
            while i > 0, ords[i] - ords[i - 1] <= tolerance {
                current += 1
                i -= 1
            }
        }
        return StreakInfo(current: current, longest: longest, total: ords.count, lastDone: DayKey.fromOrdinal(last))
    }

    /// Completions in the ISO week (Mon–Sun) containing today.
    public static func weekCount(done: Set<String>, today: String) -> Int {
        let start = DayKey.weekStart(today)
        return (0..<7).map { DayKey.adding($0, to: start) }.filter { done.contains($0) }.count
    }
}

/// The Eisenhower board of the vault, computed instead of filed.
public enum Quadrant: String, CaseIterable, Sendable, Identifiable {
    case urgentImportant, important, urgent, neither, backlog, done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .urgentImportant: return "Dringend und wichtig"
        case .important: return "Wichtig"
        case .urgent: return "Dringend"
        case .neither: return "Weder noch"
        case .backlog: return "Ohne Datum"
        case .done: return "Erledigt"
        }
    }

    public static let urgencyDays = 7

    public static func of(date: String?, wichtig: Bool, completed: Bool, today: String) -> Quadrant {
        if completed { return .done }
        guard let date, let d = DayKey.distance(from: today, to: date) else { return .backlog }
        let urgent = d <= urgencyDays
        switch (wichtig, urgent) {
        case (true, true): return .urgentImportant
        case (true, false): return .important
        case (false, true): return .urgent
        case (false, false): return .neither
        }
    }
}

public struct RGB: Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
    }

    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let t = min(1, max(0, t))
        return RGB((a.r + (b.r - a.r) * t).rounded(), (a.g + (b.g - a.g) * t).rounded(), (a.b + (b.b - a.b) * t).rounded())
    }
}

/// Colour scales copied from the vault's own charts.
public enum RatingScale {
    static let red = RGB(220, 38, 38)
    static let yellow = RGB(234, 179, 8)
    static let green = RGB(22, 163, 74)
    static let blue = RGB(55, 138, 221)
    static let purple = RGB(127, 63, 191)

    /// Rating chart in "Übersicht generell": red–yellow–green over 0–8.75, blue above 8.75, purple above 9.5.
    public static func color(for rating: Double) -> RGB {
        let c = min(10, max(0, rating))
        if c > 9.5 { return purple }
        if c > 8.75 { return blue }
        let mid = 8.75 / 2
        if c <= mid { return RGB.mix(red, yellow, c / mid) }
        return RGB.mix(yellow, green, (c - mid) / mid)
    }

    /// Habits Dashboard: score = (ratio - 1) * 5, -5 red ... 0 green ... +5 blue ... +10 purple.
    public static func color(forScore s: Double) -> RGB {
        if s <= -2.5 { return RGB.mix(red, yellow, (max(s, -5) + 5) / 2.5) }
        if s <= 0 { return RGB.mix(yellow, green, (s + 2.5) / 2.5) }
        if s <= 5 { return RGB.mix(green, blue, s / 5) }
        return RGB.mix(blue, purple, min((s - 5) / 5, 1))
    }

    public static func format(_ value: Double) -> String {
        String(format: "%.1f", min(10, max(0, (value * 10).rounded() / 10)))
    }

    public static func parse(_ s: String?) -> Double? {
        guard let s, let v = Double(s.replacingOccurrences(of: ",", with: ".")), v >= 0, v <= 10 else { return nil }
        return v
    }
}

/// Ridge regression rating ~ habits, fitted on the user's own history. Only a fallback:
/// on the existing data habits explain little of the variance, text matters more.
public struct HabitFormula: Sendable {
    public var intercept: Double
    public var coefficients: [String: Double]
    public var sampleCount: Int

    public static func fit(days: [(habits: [String: Bool], rating: Double)], keys: [String], lambda: Double = 1.0) -> HabitFormula? {
        guard days.count >= 10 else { return nil }
        let k = keys.count + 1
        var a = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        var b = [Double](repeating: 0, count: k)
        for d in days {
            let x = [1.0] + keys.map { (d.habits[$0] ?? false) ? 1.0 : 0.0 }
            for i in 0..<k {
                b[i] += x[i] * d.rating
                for j in 0..<k { a[i][j] += x[i] * x[j] }
            }
        }
        for i in 1..<k { a[i][i] += lambda }
        // Gauss-Jordan with partial pivoting
        var m = a
        var v = b
        for c in 0..<k {
            var p = c
            for r in c..<k where abs(m[r][c]) > abs(m[p][c]) { p = r }
            guard abs(m[p][c]) > 1e-9 else { return nil }
            m.swapAt(c, p)
            v.swapAt(c, p)
            for r in 0..<k where r != c {
                let f = m[r][c] / m[c][c]
                if f == 0 { continue }
                for cc in c..<k { m[r][cc] -= f * m[c][cc] }
                v[r] -= f * v[c]
            }
        }
        let w = (0..<k).map { v[$0] / m[$0][$0] }
        var coef: [String: Double] = [:]
        for (i, key) in keys.enumerated() { coef[key] = w[i + 1] }
        return HabitFormula(intercept: w[0], coefficients: coef, sampleCount: days.count)
    }

    public func predict(_ habits: [String: Bool]) -> Double {
        let v = intercept + coefficients.reduce(0) { $0 + ((habits[$1.key] ?? false) ? $1.value : 0) }
        return min(10, max(0, v))
    }
}
