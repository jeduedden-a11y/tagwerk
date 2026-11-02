import Foundation

public struct DateCandidate: Hashable, Sendable {
    /// yyyy-MM-dd
    public var day: String
    /// HH:mm
    public var startTime: String?
    public var endTime: String?
    public var matchedText: String
    /// The line the date stands in, trimmed.
    public var context: String

    public init(day: String, startTime: String? = nil, endTime: String? = nil, matchedText: String, context: String) {
        self.day = day
        self.startTime = startTime
        self.endTime = endTime
        self.matchedText = matchedText
        self.context = context
    }
}

/// Finds dates in German and English mail text. Deterministic regexes for German
/// formats plus NSDataDetector; filters quoted reply headers and past dates.
public enum DateExtractor {
    static let months: [String: Int] = [
        "januar": 1, "jänner": 1, "jan": 1, "februar": 2, "feb": 2, "märz": 3, "maerz": 3, "mär": 3, "mrz": 3,
        "april": 4, "apr": 4, "mai": 5, "juni": 6, "jun": 6, "juli": 7, "jul": 7, "august": 8, "aug": 8,
        "september": 9, "sep": 9, "sept": 9, "oktober": 10, "okt": 10, "november": 11, "nov": 11, "dezember": 12, "dez": 12,
    ]
    static let weekdays: [String: Int] = ["sonntag": 1, "montag": 2, "dienstag": 3, "mittwoch": 4, "donnerstag": 5, "freitag": 6, "samstag": 7, "sonnabend": 7]

    static let numeric = try! NSRegularExpression(pattern: "(?<![\\d.])(\\d{1,2})\\.\\s?(\\d{1,2})\\.(?:\\s?(\\d{4}|\\d{2}))?(?![\\d])")
    static let named = try! NSRegularExpression(
        pattern: "(?<![\\d])(\\d{1,2})\\.?\\s*(januar|jänner|februar|märz|maerz|april|mai|juni|juli|august|september|oktober|november|dezember|jan|feb|mär|mrz|apr|jun|jul|aug|sept|sep|okt|nov|dez)\\.?(?:\\s+(\\d{4}))?(?![a-zäöü])",
        options: [.caseInsensitive])
    static let relative = try! NSRegularExpression(
        pattern: "(?<![a-zäöü])(übermorgen|morgen|heute|(?:am\\s+|nächsten\\s+|kommenden\\s+|diesen\\s+)(?:montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonnabend|sonntag))(?![a-zäöü])",
        options: [.caseInsensitive])
    static let timeRange = try! NSRegularExpression(
        pattern: "(\\d{1,2})(?:[:.](\\d{2}))?\\s*(?:uhr)?\\s*(?:-|–|—|bis)\\s*(\\d{1,2})(?:[:.](\\d{2}))?\\s*uhr",
        options: [.caseInsensitive])
    static let timeRangeColon = try! NSRegularExpression(pattern: "(\\d{1,2})[:.](\\d{2})\\s*(?:-|–|—|bis)\\s*(\\d{1,2})[:.](\\d{2})", options: [])
    static let timeSingle = try! NSRegularExpression(pattern: "(\\d{1,2})[:.](\\d{2})(?:\\s*uhr)?|(\\d{1,2})\\s*uhr", options: [.caseInsensitive])

    static func dayKey(_ comps: DateComponents, calendar: Calendar) -> String? {
        guard let d = calendar.date(from: comps) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        // Reject overflowed dates like 31.02.
        guard c.day == comps.day, c.month == comps.month else { return nil }
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func hhmm(_ h: Int, _ m: Int) -> String? {
        guard (0...23).contains(h), (0...59).contains(m) else { return nil }
        return String(format: "%02d:%02d", h, m)
    }

    static func group(_ m: NSTextCheckingResult, _ i: Int, in ns: NSString) -> String? {
        guard i < m.numberOfRanges else { return nil }
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }

    /// Time stated right after the date (same line, within 60 characters).
    static func time(after location: Int, in ns: NSString, lineEnd: Int) -> (String?, String?) {
        let end = min(lineEnd, location + 60, ns.length)
        guard end > location else { return (nil, nil) }
        let window = NSRange(location: location, length: end - location)
        for re in [timeRangeColon, timeRange] {
            if let m = re.firstMatch(in: ns as String, range: window) {
                let h1 = Int(group(m, 1, in: ns) ?? "") ?? -1
                let m1 = Int(group(m, 2, in: ns) ?? "0") ?? 0
                let h2 = Int(group(m, 3, in: ns) ?? "") ?? -1
                let m2 = Int(group(m, 4, in: ns) ?? "0") ?? 0
                if let s = hhmm(h1, m1), let e = hhmm(h2, m2) { return (s, e) }
            }
        }
        if let m = timeSingle.firstMatch(in: ns as String, range: window) {
            if let hs = group(m, 1, in: ns), let h = Int(hs), let mm = Int(group(m, 2, in: ns) ?? "0") { return (hhmm(h, mm), nil) }
            if let hs = group(m, 3, in: ns), let h = Int(hs) { return (hhmm(h, 0), nil) }
        }
        return (nil, nil)
    }

    static func lineBounds(_ ns: NSString, _ loc: Int) -> NSRange {
        ns.lineRange(for: NSRange(location: loc, length: 0))
    }

    public static func candidates(in text: String, reference: Date, now: Date = Date(), calendar: Calendar = .current) -> [DateCandidate] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var cal = calendar
        cal.locale = Locale(identifier: "de_DE")
        let refComps = cal.dateComponents([.year, .month, .day, .weekday], from: reference)
        let refYear = refComps.year ?? 2026
        let refStart = cal.startOfDay(for: reference)
        let floorDay = cal.startOfDay(for: now)
        let ceilingDay = refStart.addingTimeInterval(400 * 86_400)

        var found: [DateCandidate] = []

        func isQuotedHeader(line: NSRange, text lineText: String) -> Bool {
            let l = lineText.trimmingCharacters(in: .whitespaces).lowercased()
            if l.hasPrefix(">") || l.contains("schrieb") || l.contains("wrote:") || l.hasPrefix("gesendet:") || l.hasPrefix("sent:") { return true }
            if l.hasPrefix("datum:") || l.hasPrefix("date:") {
                // Only a reply header if sender and subject lines are right next to it.
                let from = max(0, line.location - 250)
                let to = min(ns.length, line.location + line.length + 250)
                let around = ns.substring(with: NSRange(location: from, length: to - from)).lowercased()
                return (around.contains("von:") || around.contains("from:")) && (around.contains("betreff:") || around.contains("subject:"))
            }
            return false
        }

        func add(day: String, at range: NSRange) {
            guard let date = isoDay(day, calendar: cal), date >= floorDay, date <= ceilingDay else { return }
            let line = lineBounds(ns, range.location)
            let lineText = ns.substring(with: line)
            if isQuotedHeader(line: line, text: lineText) { return }
            let (start, end) = time(after: range.location + range.length, in: ns, lineEnd: line.location + line.length)
            let candidate = DateCandidate(day: day, startTime: start, endTime: end, matchedText: ns.substring(with: range),
                                          context: lineText.trimmingCharacters(in: .whitespacesAndNewlines))
            if found.contains(where: { $0.day == day && $0.startTime == start }) { return }
            if start != nil, let i = found.firstIndex(where: { $0.day == day && $0.startTime == nil }) {
                found[i] = candidate
                return
            }
            if start == nil, found.contains(where: { $0.day == day }) { return }
            found.append(candidate)
        }

        func inferYear(day: Int, month: Int, explicit: Int?) -> Int {
            if let y = explicit { return y < 100 ? 2000 + y : y }
            var c = DateComponents()
            c.year = refYear
            c.month = month
            c.day = day
            if let d = cal.date(from: c), d < refStart.addingTimeInterval(-30 * 86_400) { return refYear + 1 }
            return refYear
        }

        for m in numeric.matches(in: text, range: full) {
            guard let d = Int(group(m, 1, in: ns) ?? ""), let mo = Int(group(m, 2, in: ns) ?? ""), (1...31).contains(d), (1...12).contains(mo) else { continue }
            let y = inferYear(day: d, month: mo, explicit: group(m, 3, in: ns).flatMap { Int($0) })
            var c = DateComponents()
            c.year = y
            c.month = mo
            c.day = d
            if let key = dayKey(c, calendar: cal) { add(day: key, at: m.range) }
        }
        for m in named.matches(in: text, range: full) {
            guard let d = Int(group(m, 1, in: ns) ?? ""), (1...31).contains(d),
                  let mo = months[(group(m, 2, in: ns) ?? "").lowercased()] else { continue }
            let y = inferYear(day: d, month: mo, explicit: group(m, 3, in: ns).flatMap { Int($0) })
            var c = DateComponents()
            c.year = y
            c.month = mo
            c.day = d
            if let key = dayKey(c, calendar: cal) { add(day: key, at: m.range) }
        }
        for m in relative.matches(in: text, range: full) {
            let word = (group(m, 1, in: ns) ?? "").lowercased()
            var target: Date?
            if word == "heute" { target = refStart }
            else if word == "morgen" { target = cal.date(byAdding: .day, value: 1, to: refStart) }
            else if word == "übermorgen" { target = cal.date(byAdding: .day, value: 2, to: refStart) }
            else if let name = word.split(separator: " ").last.map(String.init), let wd = weekdays[name] {
                let current = refComps.weekday ?? 1
                var delta = (wd - current + 7) % 7
                if delta == 0 { delta = 7 }
                target = cal.date(byAdding: .day, value: delta, to: refStart)
            }
            if let t = target {
                let c = cal.dateComponents([.year, .month, .day], from: t)
                if let key = dayKey(c, calendar: cal) { add(day: key, at: m.range) }
            }
        }

        // NSDataDetector for English mails ("November 12", "12/11/2026"). Numeric German
        // formats and time-only hits are left to the regexes above: the detector resolves
        // those against today instead of the mail's date.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let english = try? NSRegularExpression(
                pattern: "\\b(jan(uary)?|feb(ruary)?|mar(ch)?|apr(il)?|may|june?|july?|aug(ust)?|sep(t(ember)?)?|oct(ober)?|nov(ember)?|dec(ember)?|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\\b|\\d{1,2}/\\d{1,2}",
                options: [.caseInsensitive])
            for m in detector.matches(in: text, range: full) {
                guard let date = m.date else { continue }
                let matched = ns.substring(with: m.range)
                // A month name alone ("November") is not a date; time-only hits resolve against today.
                guard matched.rangeOfCharacter(from: .decimalDigits) != nil,
                      english?.firstMatch(in: matched, range: NSRange(location: 0, length: (matched as NSString).length)) != nil else { continue }
                let c = cal.dateComponents([.year, .month, .day], from: date)
                // The detector likes to glue a time from one line to a month name on the next
                // ("15:00 … November" -> 1 November). Accept only single-line hits whose
                // day of month is actually written in the matched text.
                let numbers = Set(matched.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) })
                guard !matched.contains("\n"), let dom = c.day, numbers.contains(dom),
                      let key = dayKey(c, calendar: cal) else { continue }
                if found.contains(where: { $0.day == key }) { continue }
                add(day: key, at: m.range)
            }
        }
        return Array(found.sorted { ($0.day, $0.startTime ?? "") < ($1.day, $1.startTime ?? "") }.prefix(12))
    }

    static func isoDay(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]
        c.month = parts[1]
        c.day = parts[2]
        return calendar.date(from: c)
    }

    /// Words that make a mail worth a closer look even without a date match.
    public static func looksLikeAppointment(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["termin", "sitzung", "treffen", "einladung", "frist", "abgabe", "deadline", "klausur", "prüfung", "konferenz", "besprechung", "meeting", "anmeldeschluss"].contains { t.contains($0) }
    }
}
