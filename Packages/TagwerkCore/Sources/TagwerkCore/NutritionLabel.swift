import Foundation

/// Reads an EU nutrition table (Regulation 1169/2011: Brennwert, Fett, davon gesättigte Fettsäuren,
/// Kohlenhydrate, davon Zucker, Ballaststoffe, Eiweiß, Salz) from text recognised on the device.
/// The first number of a row is the value per 100 g or 100 ml, the column order the regulation prescribes.
public enum NutritionLabelParser {
    public struct Result: Sendable, Hashable {
        public var per100: Nutrients
        public var unit: String
        /// Which values were actually read, e.g. ["kcal", "fat", "protein"].
        public var found: Set<String>
    }

    struct Number {
        var value: Double
        var unit: String?
    }

    static func numbers(in line: String) -> [Number] {
        // "1.555 kJ / 372 kcal", "17 g", "<0,5 g", "0,02g"
        let pattern = #"(\d+(?:[.,]\d+)*)\s*(kj|kcal|mg|g)?"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = line as NSString
        return re.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            var raw = ns.substring(with: m.range(at: 1))
            let unit = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)).lowercased() : nil
            // "1.555" as thousands separator before kJ, decimal comma otherwise
            if raw.contains("."), raw.contains(",") { raw = raw.replacingOccurrences(of: ".", with: "") }
            if raw.filter({ $0 == "." }).count == 1, raw.split(separator: ".").last?.count == 3, unit == "kj" { raw = raw.replacingOccurrences(of: ".", with: "") }
            raw = raw.replacingOccurrences(of: ",", with: ".")
            guard let v = Double(raw) else { return nil }
            return Number(value: v, unit: unit)
        }
    }

    enum Field: String { case kcal, fat, satFat, carbs, sugar, fiber, protein, salt }

    static func field(of folded: String) -> Field? {
        if folded.contains("gesatt") || folded.contains("fettsaur") || folded.contains("saturat") { return .satFat }
        if folded.contains("zucker") || folded.contains("sugar") { return .sugar }
        if folded.contains("ballast") || folded.contains("fibre") || folded.contains("fiber") { return .fiber }
        if folded.contains("kohlenh") || folded.contains("carbohydrat") { return .carbs }
        if folded.contains("eiwei") || folded.contains("protein") { return .protein }
        if folded.contains("salz") || folded.contains("salt") { return .salt }
        if folded.contains("brennw") || folded.contains("energ") { return .kcal }
        if folded.hasPrefix("fett") || folded.contains(" fett") || folded.hasPrefix("fat") || folded.contains(" fat") { return .fat }
        return nil
    }

    public static func parse(lines: [String]) -> Result? {
        var values: [Field: Double] = [:]
        var unit = "g"
        var pendingEnergy = false
        for line in lines {
            let folded = FoodText.fold(line)
            if folded.contains("100 ml") || folded.contains("100ml") { unit = "ml" }
            let nums = numbers(in: line)
            let f = field(of: folded)

            if f == .kcal || pendingEnergy || (values[.kcal] == nil && nums.contains { $0.unit == "kcal" }) {
                if let k = nums.first(where: { $0.unit == "kcal" }) {
                    values[.kcal] = k.value
                    pendingEnergy = false
                } else if values[.kcal] == nil, let kj = nums.first(where: { $0.unit == "kj" }) {
                    values[.kcal] = (kj.value / 4.184).rounded()
                    pendingEnergy = true // the kcal value may follow on the next line
                } else if f == .kcal, nums.isEmpty {
                    pendingEnergy = true
                }
                if f == .kcal || f == nil { continue }
            }
            guard let f, f != .kcal else { continue }
            pendingEnergy = false
            guard values[f] == nil else { continue }
            // First number of the row that is not a reference amount ("100 g") or a percentage of the reference intake.
            let candidates = nums.filter { !($0.value == 100 && $0.unit == "g" && folded.contains("100")) }
            guard var v = candidates.first?.value else { continue }
            if candidates.first?.unit == "mg" { v /= 1000 }
            values[f] = v
        }

        let found = Set(values.keys.map(\.rawValue))
        guard values.count >= 2 else { return nil }
        var n = Nutrients(kcal: values[.kcal] ?? 0, protein: values[.protein] ?? 0, fat: values[.fat] ?? 0, carbs: values[.carbs] ?? 0,
                          fiber: values[.fiber], sugar: values[.sugar], satFat: values[.satFat], salt: values[.salt])
        if values[.kcal] == nil { n.kcal = n.macroKcal.rounded() }
        guard n.isPlausiblePer100 else { return nil }
        return Result(per100: n, unit: unit, found: found)
    }
}
