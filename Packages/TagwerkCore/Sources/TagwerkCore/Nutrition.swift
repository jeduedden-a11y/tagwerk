import Foundation

// Food log, body profile and daily targets. Wire format of food.day and profile.set is
// the Codable form of these types; keep it in sync with bridge/src/protocol.ts.

public struct Nutrients: Codable, Hashable, Sendable {
    public var kcal: Double
    public var protein: Double
    public var fat: Double
    public var carbs: Double
    public var fiber: Double?
    public var sugar: Double?
    public var satFat: Double?
    public var salt: Double?

    public init(kcal: Double, protein: Double, fat: Double, carbs: Double, fiber: Double? = nil, sugar: Double? = nil, satFat: Double? = nil, salt: Double? = nil) {
        self.kcal = kcal
        self.protein = protein
        self.fat = fat
        self.carbs = carbs
        self.fiber = fiber
        self.sugar = sugar
        self.satFat = satFat
        self.salt = salt
    }

    public static let zero = Nutrients(kcal: 0, protein: 0, fat: 0, carbs: 0)

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func num(_ k: CodingKeys) -> Double? {
            if let d = try? c.decodeIfPresent(Double.self, forKey: k) { return d.isFinite ? d : nil }
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Double(s.replacingOccurrences(of: ",", with: ".")) }
            return nil
        }
        kcal = num(.kcal) ?? 0
        protein = num(.protein) ?? 0
        fat = num(.fat) ?? 0
        carbs = num(.carbs) ?? 0
        fiber = num(.fiber)
        sugar = num(.sugar)
        satFat = num(.satFat)
        salt = num(.salt)
    }

    public func scaled(_ f: Double) -> Nutrients {
        Nutrients(kcal: kcal * f, protein: protein * f, fat: fat * f, carbs: carbs * f,
                  fiber: fiber.map { $0 * f }, sugar: sugar.map { $0 * f }, satFat: satFat.map { $0 * f }, salt: salt.map { $0 * f })
    }

    static func add(_ a: Double?, _ b: Double?) -> Double? {
        if a == nil && b == nil { return nil }
        return (a ?? 0) + (b ?? 0)
    }

    public static func + (l: Nutrients, r: Nutrients) -> Nutrients {
        Nutrients(kcal: l.kcal + r.kcal, protein: l.protein + r.protein, fat: l.fat + r.fat, carbs: l.carbs + r.carbs,
                  fiber: add(l.fiber, r.fiber), sugar: add(l.sugar, r.sugar), satFat: add(l.satFat, r.satFat), salt: add(l.salt, r.salt))
    }

    /// Energy from the macronutrients (EU factors: 4 / 9 / 4, fibre 2), for plausibility checks.
    public var macroKcal: Double { protein * 4 + fat * 9 + carbs * 4 + (fiber ?? 0) * 2 }

    /// Values in the ranges a label per 100 g can have.
    public var isPlausiblePer100: Bool {
        kcal >= 0 && kcal <= 950 && protein >= 0 && protein <= 100 && fat >= 0 && fat <= 100 && carbs >= 0 && carbs <= 100
            && protein + fat + carbs <= 102
    }
}

public enum FoodSource: String, Codable, Sendable, CaseIterable {
    case barcode, bls, label, manual, photo, text, custom

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = FoodSource(rawValue: raw) ?? .manual
    }

    public var label: String {
        switch self {
        case .barcode: return "Barcode, Open Food Facts"
        case .bls: return "Bundeslebensmittelschlüssel"
        case .label: return "Nährwerttabelle fotografiert"
        case .manual: return "von Hand"
        case .photo: return "Foto, Vorschlag"
        case .text: return "aus deiner Beschreibung"
        case .custom: return "eigenes Lebensmittel"
        }
    }
}

public enum Meal: String, Codable, Sendable, CaseIterable, Identifiable {
    case breakfast = "fruehstueck"
    case lunch = "mittag"
    case dinner = "abend"
    case snack = "snack"

    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = Meal(rawValue: raw) ?? .snack
    }

    public var label: String {
        switch self {
        case .breakfast: return "Frühstück"
        case .lunch: return "Mittagessen"
        case .dinner: return "Abendessen"
        case .snack: return "Snacks"
        }
    }

    public var symbol: String {
        switch self {
        case .breakfast: return "sunrise.fill"
        case .lunch: return "sun.max.fill"
        case .dinner: return "moon.stars.fill"
        case .snack: return "carrot.fill"
        }
    }

    public static func guess(hour: Int) -> Meal {
        switch hour {
        case 4..<11: return .breakfast
        case 11..<15: return .lunch
        case 17..<22: return .dinner
        default: return .snack
        }
    }
}

/// A food the user can pick: from the BLS table, Open Food Facts, a photographed label or typed in.
public struct FoodItem: Codable, Hashable, Sendable, Identifiable {
    /// "bls:F110100", "off:4000417025005", "custom:<uuid>"
    public var id: String
    public var name: String
    public var brand: String?
    public var barcode: String?
    public var source: FoodSource
    /// Per 100 g, or per 100 ml when unit is "ml".
    public var per100: Nutrients
    public var unit: String
    public var servingGrams: Double?
    public var servingLabel: String?
    /// Weight of one piece ("2 Eier", "1 Scheibe").
    public var pieceGrams: Double?
    /// Typical amount when nothing else is known.
    public var defaultGrams: Double?

    public init(id: String, name: String, brand: String? = nil, barcode: String? = nil, source: FoodSource, per100: Nutrients, unit: String = "g",
                servingGrams: Double? = nil, servingLabel: String? = nil, pieceGrams: Double? = nil, defaultGrams: Double? = nil) {
        self.id = id
        self.name = name
        self.brand = brand
        self.barcode = barcode
        self.source = source
        self.per100 = per100
        self.unit = unit
        self.servingGrams = servingGrams
        self.servingLabel = servingLabel
        self.pieceGrams = pieceGrams
        self.defaultGrams = defaultGrams
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Lebensmittel"
        brand = (try? c.decodeIfPresent(String.self, forKey: .brand)) ?? nil
        barcode = (try? c.decodeIfPresent(String.self, forKey: .barcode)) ?? nil
        source = (try? c.decode(FoodSource.self, forKey: .source)) ?? .manual
        per100 = (try? c.decode(Nutrients.self, forKey: .per100)) ?? .zero
        unit = (try? c.decode(String.self, forKey: .unit)) ?? "g"
        servingGrams = (try? c.decodeIfPresent(Double.self, forKey: .servingGrams)) ?? nil
        servingLabel = (try? c.decodeIfPresent(String.self, forKey: .servingLabel)) ?? nil
        pieceGrams = (try? c.decodeIfPresent(Double.self, forKey: .pieceGrams)) ?? nil
        defaultGrams = (try? c.decodeIfPresent(Double.self, forKey: .defaultGrams)) ?? nil
    }

    /// Amount offered first: a serving if the package states one, else a typical portion, else 100 g.
    public var suggestedGrams: Double { servingGrams ?? defaultGrams ?? pieceGrams ?? 100 }

    public func entry(grams: Double, meal: Meal, time: String, note: String? = nil, id: String = UUID().uuidString.lowercased()) -> FoodEntry {
        FoodEntry(id: id, time: time, meal: meal, name: name, brand: brand, barcode: barcode, itemId: self.id, source: source,
                  grams: grams, unit: unit, per100: per100, note: note)
    }
}

/// One logged amount of a food on one day.
public struct FoodEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// "HH:mm"
    public var time: String
    public var meal: Meal
    public var name: String
    public var brand: String?
    public var barcode: String?
    public var itemId: String?
    public var source: FoodSource
    public var grams: Double
    public var unit: String
    public var per100: Nutrients
    public var note: String?

    public init(id: String, time: String, meal: Meal, name: String, brand: String?, barcode: String?, itemId: String?, source: FoodSource,
                grams: Double, unit: String, per100: Nutrients, note: String?) {
        self.id = id
        self.time = time
        self.meal = meal
        self.name = name
        self.brand = brand
        self.barcode = barcode
        self.itemId = itemId
        self.source = source
        self.grams = grams
        self.unit = unit
        self.per100 = per100
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        time = (try? c.decode(String.self, forKey: .time)) ?? "12:00"
        meal = (try? c.decode(Meal.self, forKey: .meal)) ?? .snack
        name = (try? c.decode(String.self, forKey: .name)) ?? "Lebensmittel"
        brand = (try? c.decodeIfPresent(String.self, forKey: .brand)) ?? nil
        barcode = (try? c.decodeIfPresent(String.self, forKey: .barcode)) ?? nil
        itemId = (try? c.decodeIfPresent(String.self, forKey: .itemId)) ?? nil
        source = (try? c.decode(FoodSource.self, forKey: .source)) ?? .manual
        grams = (try? c.decode(Double.self, forKey: .grams)) ?? 0
        unit = (try? c.decode(String.self, forKey: .unit)) ?? "g"
        per100 = (try? c.decode(Nutrients.self, forKey: .per100)) ?? .zero
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
    }

    public var nutrients: Nutrients { per100.scaled(grams / 100) }

    public var item: FoodItem {
        FoodItem(id: itemId ?? "custom:\(id)", name: name, brand: brand, barcode: barcode, source: source, per100: per100, unit: unit)
    }

    /// "80 g", "250 ml"
    public var amountLabel: String { "\(NutritionFormat.amount(grams)) \(unit)" }
}

public enum NutritionFormat {
    /// 80 -> "80", 12.5 -> "12,5"
    public static func amount(_ g: Double) -> String {
        let r = (g * 10).rounded() / 10
        let s = r == r.rounded() ? String(format: "%.0f", r) : String(format: "%.1f", r)
        return s.replacingOccurrences(of: ".", with: ",")
    }

    /// Grams with one decimal below 10, whole above: "4,6", "152"
    public static func grams(_ g: Double) -> String {
        g < 10 ? String(format: "%.1f", g).replacingOccurrences(of: ".", with: ",") : String(format: "%.0f", g)
    }

    /// "2.650" (German thousands separator)
    public static func kcal(_ k: Double) -> String {
        let v = Int(k.rounded())
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}

// MARK: - Body profile and targets

public enum Sex: String, Codable, Sendable, CaseIterable {
    case male = "m"
    case female = "w"

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = Sex(rawValue: raw) ?? .male
    }

    public var label: String { self == .male ? "männlich" : "weiblich" }
}

/// Activity factor (PAL) for everyday life including gym training. Runs are counted separately.
public enum ActivityLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case sedentary = "sitzend"
    case light = "leicht"
    case moderate = "maessig"
    case high = "hoch"
    case veryHigh = "sehr_hoch"

    public var id: String { rawValue }

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = ActivityLevel(rawValue: raw) ?? .moderate
    }

    public var pal: Double {
        switch self {
        case .sedentary: return 1.2
        case .light: return 1.375
        case .moderate: return 1.55
        case .high: return 1.725
        case .veryHigh: return 1.9
        }
    }

    public var label: String {
        switch self {
        case .sedentary: return "Sitzend"
        case .light: return "Leicht aktiv"
        case .moderate: return "Mäßig aktiv"
        case .high: return "Sehr aktiv"
        case .veryHigh: return "Extrem aktiv"
        }
    }

    public var detail: String {
        switch self {
        case .sedentary: return "Schule oder Schreibtisch, kaum Training"
        case .light: return "Viel zu Fuß, 1 bis 2 Trainingseinheiten pro Woche"
        case .moderate: return "3 bis 4 Trainingseinheiten pro Woche"
        case .high: return "5 bis 6 harte Einheiten pro Woche"
        case .veryHigh: return "Täglich hartes Training oder körperliche Arbeit"
        }
    }
}

public struct BodyProfile: Codable, Hashable, Sendable {
    public var heightCm: Double = 175
    public var birthYear: Int = 2000
    public var sex: Sex = .male
    /// Body fat in percent; with it the basal rate comes from lean mass (Katch-McArdle).
    public var bodyFat: Double?
    public var targetWeight: Double?
    public var activity: ActivityLevel = .moderate
    /// Planned change in kg per week, always positive; the direction comes from the target weight.
    public var weeklyRate: Double = 0.25
    public var proteinPerKg: Double = 1.8
    /// Share of energy from fat, percent.
    public var fatPercent: Double = 27
    /// Tolerance of the daily check, percent.
    public var tolerance: Double = 10
    public var checkProtein = true
    public var checkFat = false
    public var checkCarbs = false
    public var checkFiber = false
    /// Add the energy of the day's runs to the target.
    public var addRuns = true
    /// YYYY-MM-DD of the last change.
    public var updated: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = BodyProfile()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func num(_ k: CodingKeys) -> Double? {
            if let v = try? c.decodeIfPresent(Double.self, forKey: k) { return v.isFinite ? v : nil }
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Double(s.replacingOccurrences(of: ",", with: ".")) }
            return nil
        }
        func flag(_ k: CodingKeys, _ fallback: Bool) -> Bool {
            if let b = try? c.decodeIfPresent(Bool.self, forKey: k) { return b }
            if let s = try? c.decodeIfPresent(String.self, forKey: k) { return s == "true" }
            return fallback
        }
        heightCm = num(.heightCm) ?? d.heightCm
        birthYear = num(.birthYear).map { Int($0) } ?? d.birthYear
        sex = (try? c.decode(Sex.self, forKey: .sex)) ?? d.sex
        bodyFat = num(.bodyFat)
        targetWeight = num(.targetWeight)
        activity = (try? c.decode(ActivityLevel.self, forKey: .activity)) ?? d.activity
        weeklyRate = num(.weeklyRate) ?? d.weeklyRate
        proteinPerKg = num(.proteinPerKg) ?? d.proteinPerKg
        fatPercent = num(.fatPercent) ?? d.fatPercent
        tolerance = num(.tolerance) ?? d.tolerance
        checkProtein = flag(.checkProtein, d.checkProtein)
        checkFat = flag(.checkFat, d.checkFat)
        checkCarbs = flag(.checkCarbs, d.checkCarbs)
        checkFiber = flag(.checkFiber, d.checkFiber)
        addRuns = flag(.addRuns, d.addRuns)
        updated = (try? c.decodeIfPresent(String.self, forKey: .updated)) ?? nil
    }

    public func age(in year: Int) -> Int { max(10, year - birthYear) }
}

public struct NutritionTargets: Codable, Hashable, Sendable {
    public var kcal: Double
    public var protein: Double
    public var fat: Double
    public var carbs: Double
    public var fiber: Double
    public var bmr: Double
    public var tdee: Double
    public var runKcal: Double
    /// Surplus (positive) or deficit (negative) for the target weight.
    public var goalKcal: Double
    public var formula: String
    public var weightKg: Double
    /// True when a safety limit cut the surplus or deficit.
    public var limited: Bool

    public init(kcal: Double, protein: Double, fat: Double, carbs: Double, fiber: Double, bmr: Double, tdee: Double, runKcal: Double,
                goalKcal: Double, formula: String, weightKg: Double, limited: Bool) {
        self.kcal = kcal
        self.protein = protein
        self.fat = fat
        self.carbs = carbs
        self.fiber = fiber
        self.bmr = bmr
        self.tdee = tdee
        self.runKcal = runKcal
        self.goalKcal = goalKcal
        self.formula = formula
        self.weightKg = weightKg
        self.limited = limited
    }
}

public enum NutritionCalculator {
    /// Energy content of body mass change, kcal per kg (mostly fat tissue).
    public static let kcalPerKg = 7700.0

    /// Basal metabolic rate: Katch-McArdle (370 + 21.6 x lean mass) with body fat,
    /// otherwise Mifflin-St Jeor (10 kg + 6.25 cm - 5 years + 5 / -161).
    public static func bmr(profile: BodyProfile, weightKg: Double, year: Int) -> (kcal: Double, formula: String) {
        if let bf = profile.bodyFat, bf > 2, bf < 70 {
            let lean = weightKg * (1 - bf / 100)
            return (370 + 21.6 * lean, "Katch-McArdle")
        }
        let base = 10 * weightKg + 6.25 * profile.heightCm - 5 * Double(profile.age(in: year))
        return (base + (profile.sex == .male ? 5 : -161), "Mifflin-St Jeor")
    }

    public static func targets(profile: BodyProfile, weightKg: Double, year: Int, runs: [(km: Double, seconds: Int)] = []) -> NutritionTargets {
        let w = min(300, max(30, weightKg))
        let (bmr, formula) = bmr(profile: profile, weightKg: w, year: year)
        let pal = profile.activity.pal
        let tdee = bmr * pal
        let runKcal = profile.addRuns ? runs.reduce(0) { $0 + RunEnergy.kcal(distanceKm: $1.km, seconds: $1.seconds, weightKg: w, bmr: bmr, pal: pal) } : 0

        var goal = 0.0
        var limited = false
        if let target = profile.targetWeight, abs(target - w) >= 0.5 {
            let direction: Double = target > w ? 1 : -1
            goal = direction * max(0, profile.weeklyRate) * kcalPerKg / 7
            // Limits: at most 20 % above or 25 % below the daily need, never below the basal rate.
            let upper = tdee * 0.20
            let lower = -tdee * 0.25
            if goal > upper { goal = upper; limited = true }
            if goal < lower { goal = lower; limited = true }
        }
        var kcal = tdee + runKcal + goal
        if kcal < bmr {
            kcal = bmr
            limited = true
        }

        // Protein relative to body weight; with high body fat relative to lean mass / 0.8 instead.
        var reference = w
        if let bf = profile.bodyFat, bf > 2, bf < 70 { reference = min(w, w * (1 - bf / 100) / 0.8) }
        let protein = max(0, profile.proteinPerKg) * reference
        let fat = max(0.8 * w, profile.fatPercent / 100 * kcal / 9)
        let carbs = max(0, (kcal - 4 * protein - 9 * fat) / 4)
        return NutritionTargets(kcal: kcal, protein: protein, fat: fat, carbs: carbs, fiber: 30, bmr: bmr, tdee: tdee,
                                runKcal: runKcal, goalKcal: goal, formula: formula, weightKg: w, limited: limited)
    }
}

public struct NutritionCheck: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable { case kcal, protein, fat, carbs, fiber }
    public enum Status: Sendable { case ok, low, high }

    public var kind: Kind
    public var value: Double
    public var target: Double
    public var lower: Double
    public var upper: Double?
    public var status: Status
    public var id: String { kind.rawValue }

    public var label: String {
        switch kind {
        case .kcal: return "Kalorien"
        case .protein: return "Protein"
        case .fat: return "Fett"
        case .carbs: return "Kohlenhydrate"
        case .fiber: return "Ballaststoffe"
        }
    }

    public var unit: String { kind == .kcal ? "kcal" : "g" }

    /// "im Ziel", "noch 34 g", "320 kcal zu viel"
    public var statusText: String {
        let fmt: (Double) -> String = { kind == .kcal ? NutritionFormat.kcal($0) : NutritionFormat.grams($0) }
        switch status {
        case .ok: return "im Ziel"
        case .low: return "noch \(fmt(max(0, lower - value))) \(unit)"
        case .high: return "\(fmt(max(0, value - (upper ?? value)))) \(unit) zu viel"
        }
    }
}

public enum NutritionEvaluation {
    /// Calories, fat and carbs must lie in target ± tolerance; protein and fibre count as a minimum.
    public static func checks(totals: Nutrients, targets: NutritionTargets, profile: BodyProfile) -> [NutritionCheck] {
        let tol = min(50, max(1, profile.tolerance)) / 100
        func corridor(_ kind: NutritionCheck.Kind, _ value: Double, _ target: Double) -> NutritionCheck {
            let lo = target * (1 - tol), hi = target * (1 + tol)
            let s: NutritionCheck.Status = value < lo ? .low : value > hi ? .high : .ok
            return NutritionCheck(kind: kind, value: value, target: target, lower: lo, upper: hi, status: s)
        }
        func minimum(_ kind: NutritionCheck.Kind, _ value: Double, _ target: Double) -> NutritionCheck {
            let lo = target * (1 - tol)
            return NutritionCheck(kind: kind, value: value, target: target, lower: lo, upper: nil, status: value < lo ? .low : .ok)
        }
        var out = [corridor(.kcal, totals.kcal, targets.kcal)]
        if profile.checkProtein { out.append(minimum(.protein, totals.protein, targets.protein)) }
        if profile.checkFat { out.append(corridor(.fat, totals.fat, targets.fat)) }
        if profile.checkCarbs { out.append(corridor(.carbs, totals.carbs, targets.carbs)) }
        if profile.checkFiber { out.append(minimum(.fiber, totals.fiber ?? 0, targets.fiber)) }
        return out
    }

    public static func met(_ checks: [NutritionCheck]) -> Bool { !checks.isEmpty && checks.allSatisfy { $0.status == .ok } }
}
