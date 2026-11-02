import Foundation

// Turns a short German description ("2 Eier, 1 Scheibe Vollkornbrot mit Butter") into foods and amounts,
// on the device and without a language model: split into phrases, read quantity and unit, match the
// rest against the food table. Every result is a suggestion the user confirms.

public enum FoodUnit: String, Sendable, CaseIterable {
    case gram, kilogram, milliliter, centiliter, liter, tablespoon, teaspoon, slice, piece, portion, cup, glass, beaker,
         bowl, plate, handful, pinch, can, pack, bar, tablet, scoop, clove, bottle

    /// Household measures with a fixed weight (liquids: 1 ml = 1 g).
    public var fixedGrams: Double? {
        switch self {
        case .gram, .milliliter: return 1
        case .kilogram, .liter: return 1000
        case .centiliter: return 10
        case .tablespoon: return 15
        case .teaspoon: return 5
        case .cup: return 150
        case .glass: return 200
        case .beaker: return 150
        case .bowl: return 250
        case .plate: return 300
        case .handful: return 30
        case .pinch: return 0.5
        case .can: return 400
        case .bottle: return 500
        case .tablet: return 100
        case .scoop: return 60
        case .clove: return 4
        case .slice, .piece, .portion, .pack, .bar: return nil
        }
    }

    public var label: String {
        switch self {
        case .gram: return "g"
        case .kilogram: return "kg"
        case .milliliter: return "ml"
        case .centiliter: return "cl"
        case .liter: return "l"
        case .tablespoon: return "EL"
        case .teaspoon: return "TL"
        case .slice: return "Scheibe"
        case .piece: return "Stück"
        case .portion: return "Portion"
        case .cup: return "Tasse"
        case .glass: return "Glas"
        case .beaker: return "Becher"
        case .bowl: return "Schale"
        case .plate: return "Teller"
        case .handful: return "Handvoll"
        case .pinch: return "Prise"
        case .can: return "Dose"
        case .pack: return "Packung"
        case .bar: return "Riegel"
        case .tablet: return "Tafel"
        case .scoop: return "Kugel"
        case .clove: return "Zehe"
        case .bottle: return "Flasche"
        }
    }

    static let words: [String: FoodUnit] = [
        "g": .gram, "gr": .gram, "gramm": .gram, "kg": .kilogram, "kilo": .kilogram, "kilogramm": .kilogram,
        "ml": .milliliter, "milliliter": .milliliter, "cl": .centiliter, "l": .liter, "liter": .liter,
        "el": .tablespoon, "essloffel": .tablespoon, "tl": .teaspoon, "teeloffel": .teaspoon,
        "scheibe": .slice, "scheiben": .slice, "scheibchen": .slice,
        "stuck": .piece, "stk": .piece, "stck": .piece,
        "portion": .portion, "portionen": .portion, "port": .portion,
        "tasse": .cup, "tassen": .cup, "glas": .glass, "glaser": .glass, "becher": .beaker,
        "schale": .bowl, "schalen": .bowl, "schussel": .bowl, "schusseln": .bowl, "teller": .plate,
        "handvoll": .handful, "prise": .pinch, "prisen": .pinch, "dose": .can, "dosen": .can,
        "packung": .pack, "packungen": .pack, "pck": .pack, "tute": .pack, "beutel": .pack,
        "riegel": .bar, "tafel": .tablet, "tafeln": .tablet, "kugel": .scoop, "kugeln": .scoop, "messloffel": .scoop,
        "zehe": .clove, "zehen": .clove, "flasche": .bottle, "flaschen": .bottle,
    ]
}

public struct FoodPhrase: Hashable, Sendable {
    public var raw: String
    public var quantity: Double?
    public var unit: FoodUnit?
    /// What is left to look up, e.g. "vollkornbrot".
    public var name: String
}

public enum FoodText {
    /// Lowercase, umlauts and ß folded, so that "Äpfel" and "apfel" meet.
    public static func fold(_ s: String) -> String {
        var t = s.lowercased()
        for (a, b) in [("ä", "a"), ("ö", "o"), ("ü", "u"), ("ß", "ss"), ("é", "e"), ("è", "e"), ("à", "a")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t
    }

    public static func tokens(_ s: String) -> [String] {
        fold(s).split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { !$0.isEmpty }
    }

    static let numberWords: [String: Double] = [
        "ein": 1, "eine": 1, "einen": 1, "einem": 1, "einer": 1, "eins": 1, "zwei": 2, "drei": 3, "vier": 4, "funf": 5,
        "sechs": 6, "sieben": 7, "acht": 8, "neun": 9, "zehn": 10, "elf": 11, "zwolf": 12, "halb": 0.5, "halbe": 0.5,
        "halben": 0.5, "halber": 0.5, "halbes": 0.5, "anderthalb": 1.5, "eineinhalb": 1.5, "viertel": 0.25,
        "dreiviertel": 0.75, "paar": 3, "doppelt": 2, "doppelte": 2,
    ]

    static let fillers: Set<String> = ["etwas", "bisschen", "ca", "circa", "ungefahr", "etwa", "so", "der", "die", "das", "den",
                                       "dem", "von", "vom", "aus", "noch", "nochmal", "ne", "nen", "kleine", "kleiner", "kleines",
                                       "grosse", "grosser", "grosses", "x"]

    /// Splits at commas, semicolons, line breaks, "und", "mit", "sowie", "dazu", "plus", "+" and "&".
    public static func phrases(_ text: String) -> [String] {
        var s = " " + text.replacingOccurrences(of: "\n", with: ",") + " "
        for sep in [";", "+", "&", " und ", " mit ", " sowie ", " dazu ", " plus "] {
            s = s.replacingOccurrences(of: sep, with: ",", options: .caseInsensitive)
        }
        return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func number(_ token: String) -> Double? {
        let t = token.replacingOccurrences(of: ",", with: ".")
        if let v = Double(t), v.isFinite { return v }
        switch t {
        case "½": return 0.5
        case "¼": return 0.25
        case "¾": return 0.75
        default: break
        }
        let frac = t.split(separator: "/")
        if frac.count == 2, let a = Double(frac[0]), let b = Double(frac[1]), b != 0 { return a / b }
        return nil
    }

    /// "200g" -> (200, gram), "1,5l" -> (1.5, liter), "2x" -> (2, nil)
    static func numberWithUnit(_ token: String) -> (Double, FoodUnit?)? {
        let chars = Array(token)
        var i = 0
        while i < chars.count, chars[i].isNumber || chars[i] == "," || chars[i] == "." || chars[i] == "/" { i += 1 }
        guard i > 0, i < chars.count else { return nil }
        guard let n = number(String(chars[0..<i])) else { return nil }
        let rest = fold(String(chars[i...]))
        if rest == "x" || rest == "×" { return (n, nil) }
        if let u = FoodUnit.words[rest] { return (n, u) }
        return nil
    }

    public static func parse(_ phrase: String) -> FoodPhrase {
        // Keep decimal commas inside numbers: split on whitespace only, punctuation is stripped per token.
        var words = phrase.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        words = words.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "()[]:.!?\"'")) }.filter { !$0.isEmpty }
        var quantity: Double?
        var unit: FoodUnit?

        func takeAmount(at index: Int) -> Int {
            // Returns how many words the amount at `index` uses.
            guard index < words.count else { return 0 }
            let w = words[index]
            let f = fold(w)
            if let (n, u) = numberWithUnit(w) {
                quantity = n
                unit = u
                if u == nil, index + 1 < words.count, let u2 = FoodUnit.words[fold(words[index + 1])] {
                    unit = u2
                    return 2
                }
                return 1
            }
            if let n = number(w) ?? numberWords[f] {
                quantity = n
                var used = 1
                if index + used < words.count, ["x", "×"].contains(fold(words[index + used])) { used += 1 }
                if index + used < words.count, let u = FoodUnit.words[fold(words[index + used])] {
                    unit = u
                    used += 1
                }
                return used
            }
            if let u = FoodUnit.words[f], u.fixedGrams == nil || f.count > 2 {
                // "Scheibe Brot", "Glas Milch": the unit alone means one of it
                quantity = 1
                unit = u
                return 1
            }
            return 0
        }

        // Leading filler words ("etwa", "ein paar")
        var start = 0
        while start < words.count, fillers.contains(fold(words[start])), fold(words[start]) != "x" { start += 1 }
        let used = takeAmount(at: start)
        var rest = Array(words[(start + used)...])
        // Amount at the end: "Haferflocken 80 g", "Banane (120g)"
        if used == 0, rest.count >= 2 {
            let lastTwo = rest.suffix(2).map(fold)
            if let n = number(lastTwo[0]), let u = FoodUnit.words[lastTwo[1]] {
                quantity = n
                unit = u
                rest.removeLast(2)
            } else if let (n, u) = numberWithUnit(rest.last!), u != nil {
                quantity = n
                unit = u
                rest.removeLast()
            }
        } else if used == 0, rest.count == 1, let (n, u) = numberWithUnit(rest[0]) {
            quantity = n
            unit = u
            rest = []
        }
        let name = rest.map(fold).filter { !fillers.contains($0) && !$0.isEmpty }.joined(separator: " ")
        return FoodPhrase(raw: phrase, quantity: quantity, unit: unit, name: name)
    }

    public static func parseAll(_ text: String) -> [FoodPhrase] {
        phrases(text).map(parse).filter { !$0.name.isEmpty }
    }

    /// Singular candidates for a folded German word: "eier" -> ei, "tomaten" -> tomate, "nusse" -> nuss.
    public static func variants(_ t: String) -> [String] {
        var out = [t]
        func add(_ s: String) { if s.count >= 2 && !out.contains(s) { out.append(s) } }
        if t.hasSuffix("en") { add(String(t.dropLast(2))); add(String(t.dropLast(1))) }
        if t.hasSuffix("er") { add(String(t.dropLast(2))) }
        if t.hasSuffix("n") { add(String(t.dropLast(1))) }
        if t.hasSuffix("e") { add(String(t.dropLast(1))) }
        if t.hasSuffix("s") { add(String(t.dropLast(1))) }
        return out
    }
}

/// Typical amounts and a fixed choice for words that the table names differently ("Eier" -> "Hühnerei gekocht").
public struct FoodAlias: Sendable, Hashable {
    /// Folded phrases, one or more words.
    public var terms: [String]
    /// Exact German name of the entry in the food table.
    public var name: String
    public var piece: Double?
    public var slice: Double?
    public var portion: Double?

    public init(_ terms: [String], _ name: String, piece: Double? = nil, slice: Double? = nil, portion: Double? = nil) {
        self.terms = terms.map(FoodText.fold)
        self.name = name
        self.piece = piece
        self.slice = slice
        self.portion = portion
    }
}

public struct FoodMatch: Sendable, Hashable, Identifiable {
    public var item: FoodItem
    public var score: Double
    public var id: String { item.id }
}

public struct ResolvedFood: Sendable, Hashable, Identifiable {
    public var phrase: FoodPhrase
    public var item: FoodItem
    public var grams: Double
    /// Other candidates for the same phrase, best first.
    public var alternatives: [FoodItem]
    public var id: String { phrase.raw + item.id }
}

/// Search over the bundled table plus the user's own foods.
public final class FoodIndex: @unchecked Sendable {
    struct Entry {
        var item: FoodItem
        var tokens: [String]
        var joined: String
        var english: [String]
        var boost: Double
    }

    private let table: [Entry]
    private let tableByName: [String: FoodItem]
    private let aliasByTerm: [String: FoodAlias]
    private var personal: [Entry] = []
    private let lock = NSLock()

    public init(items: [FoodItem], english: [String: String] = [:], aliases: [FoodAlias] = []) {
        table = items.map { Self.entry($0, english: english[$0.id], boost: 0) }
        var byName: [String: FoodItem] = [:]
        for i in items where byName[i.name] == nil { byName[i.name] = i }
        tableByName = byName
        var terms: [String: FoodAlias] = [:]
        for a in aliases where byName[a.name] != nil {
            for t in a.terms { terms[t] = a }
        }
        aliasByTerm = terms
    }

    static func entry(_ item: FoodItem, english: String?, boost: Double) -> Entry {
        let t = FoodText.tokens(item.name + " " + (item.brand ?? ""))
        return Entry(item: item, tokens: t, joined: t.joined(), english: english.map(FoodText.tokens) ?? [], boost: boost)
    }

    public var count: Int { table.count }

    public func item(named name: String) -> FoodItem? { tableByName[name] }

    /// The user's own and recently used foods rank first.
    public func setPersonal(_ items: [FoodItem]) {
        let e = items.map { Self.entry($0, english: nil, boost: 2) }
        lock.withLock { personal = e }
    }

    public func alias(for name: String) -> (item: FoodItem, alias: FoodAlias)? {
        let key = FoodText.fold(name).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let hit = aliasByTerm[key] ?? FoodText.variants(key).lazy.compactMap { self.aliasByTerm[$0] }.first
        guard let a = hit, let item = tableByName[a.name] else { return nil }
        return (item, a)
    }

    static func tokenScore(_ variants: [String], _ name: [String], _ joined: String) -> Double {
        var best = 0.0
        for v in variants {
            for nt in name {
                if nt == v { best = max(best, 3) }
                else if v.count >= 3 && nt.hasPrefix(v) { best = max(best, 2.2) }
                else if v.count >= 4 && nt.contains(v) { best = max(best, 1.6) }
                else if nt.count >= 4 && v.hasPrefix(nt) { best = max(best, 1.2) }
            }
            if best < 2, v.count >= 5, joined.contains(v) { best = max(best, 2) }
        }
        return best
    }

    public func search(_ query: String, limit: Int = 30, english: Bool = false) -> [FoodMatch] {
        let stop: Set<String> = ["mit", "und", "in", "aus", "vom", "von", "der", "die", "das", "ein", "eine"]
        let q = FoodText.tokens(query).filter { !stop.contains($0) }
        guard !q.isEmpty else { return [] }
        let qv = q.map(FoodText.variants)
        let firstVariants = Set(qv[0])
        let mine: [Entry] = english ? [] : lock.withLock { personal }
        let personalIds = Set(mine.map(\.item.id))
        var out: [FoodMatch] = []
        out.reserveCapacity(64)
        for e in mine + table {
            if e.boost == 0, personalIds.contains(e.item.id) { continue }
            let tokens = english ? e.english : e.tokens
            guard !tokens.isEmpty else { continue }
            let joined = english ? tokens.joined() : e.joined
            var total = 0.0
            var misses = 0
            for v in qv {
                let s = Self.tokenScore(v, tokens, joined)
                if s == 0 { misses += 1 } else { total += s }
            }
            if total == 0 || misses * 2 > q.count { continue }
            total -= Double(misses) * 2
            if let first = tokens.first, firstVariants.contains(first) { total += 1.5 }
            total -= 0.15 * Double(max(0, tokens.count - q.count))
            total += e.boost
            out.append(FoodMatch(item: e.item, score: total))
        }
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.item.name.count < $1.item.name.count }
        return Array(out.prefix(limit))
    }

    /// Grams for a phrase: fixed measures, else piece, slice or portion weights of the alias or item.
    public static func grams(for phrase: FoodPhrase, item: FoodItem, alias: FoodAlias?) -> Double {
        let q = phrase.quantity ?? 1
        if let u = phrase.unit {
            if let g = u.fixedGrams { return q * g }
            switch u {
            case .slice: return q * (alias?.slice ?? item.pieceGrams ?? 40)
            case .portion: return q * (alias?.portion ?? item.defaultGrams ?? item.servingGrams ?? 150)
            case .bar: return q * (item.servingGrams ?? 40)
            case .pack: return q * (item.servingGrams ?? alias?.portion ?? 100)
            default: return q * (alias?.piece ?? item.pieceGrams ?? item.servingGrams ?? 100)
            }
        }
        if phrase.quantity != nil { return q * (alias?.piece ?? item.pieceGrams ?? item.servingGrams ?? alias?.portion ?? 100) }
        return alias?.portion ?? item.defaultGrams ?? item.servingGrams ?? alias?.piece ?? item.pieceGrams ?? 100
    }

    public func resolve(_ phrase: FoodPhrase) -> ResolvedFood? {
        let matches = search(phrase.name, limit: 8)
        if let a = alias(for: phrase.name) {
            let alternatives = matches.map(\.item).filter { $0.id != a.item.id }
            return ResolvedFood(phrase: phrase, item: a.item, grams: Self.grams(for: phrase, item: a.item, alias: a.alias), alternatives: alternatives)
        }
        guard let best = matches.first else { return nil }
        // An alias for the best hit's first word still supplies piece and slice weights ("2 Scheiben Vollkornbrot").
        let measures = alias(for: best.item.name)?.alias
        return ResolvedFood(phrase: phrase, item: best.item, grams: Self.grams(for: phrase, item: best.item, alias: measures),
                            alternatives: matches.dropFirst().map(\.item))
    }

    public func resolveAll(_ text: String) -> (found: [ResolvedFood], unknown: [FoodPhrase]) {
        var found: [ResolvedFood] = []
        var unknown: [FoodPhrase] = []
        for p in FoodText.parseAll(text) {
            if let r = resolve(p) { found.append(r) } else { unknown.append(p) }
        }
        return (found, unknown)
    }
}
