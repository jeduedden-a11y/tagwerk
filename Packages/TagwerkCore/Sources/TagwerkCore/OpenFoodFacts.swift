import Foundation

/// Open Food Facts, the open product database (ODbL). Reading needs no key, only a User-Agent
/// naming the app. Limits: 15 product reads and 10 searches per minute and IP, so results are cached.
public enum OpenFoodFacts {
    public static let userAgent = "Tagwerk/1.1 (iPhone; github.com/jeduedden-a11y/tagwerk)"
    static let fields = "code,product_name,product_name_de,generic_name_de,brands,quantity,serving_size,serving_quantity,nutriments"

    public enum Failure: LocalizedError {
        case http(Int)
        case offline

        public var errorDescription: String? {
            switch self {
            case .http(503), .http(429): return "Open Food Facts ist gerade überlastet. Bitte in einer Minute noch einmal."
            case .http(let c): return "Open Food Facts antwortet mit Fehler \(c)."
            case .offline: return "Keine Verbindung zu Open Food Facts."
            }
        }
    }

    /// Digits only; UPC-A gets the leading zero EAN-13 uses.
    public static func normalize(_ code: String) -> [String] {
        let d = code.filter(\.isNumber)
        guard d.count >= 6 else { return [] }
        var out = [d]
        if d.count == 12 { out.append("0" + d) }
        if d.count == 13, d.hasPrefix("0") { out.append(String(d.dropFirst())) }
        return out
    }

    public static func productURL(_ code: String) -> URL {
        URL(string: "https://world.openfoodfacts.org/api/v2/product/\(code).json?fields=\(fields)")!
    }

    public static func searchURL(_ query: String) -> URL {
        var c = URLComponents(string: "https://search.openfoodfacts.org/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "langs", value: "de"),
                        URLQueryItem(name: "page_size", value: "25"), URLQueryItem(name: "fields", value: fields)]
        return c.url!
    }

    static func legacySearchURL(_ query: String) -> URL {
        var c = URLComponents(string: "https://world.openfoodfacts.org/cgi/search.pl")!
        c.queryItems = [URLQueryItem(name: "search_terms", value: query), URLQueryItem(name: "search_simple", value: "1"),
                        URLQueryItem(name: "action", value: "process"), URLQueryItem(name: "json", value: "1"),
                        URLQueryItem(name: "page_size", value: "25"), URLQueryItem(name: "fields", value: fields)]
        return c.url!
    }

    static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d.isFinite ? d : nil }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func string(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// One product object of the API as a food, nil without name or energy.
    public static func item(from p: [String: Any]) -> FoodItem? {
        guard let n = p["nutriments"] as? [String: Any] else { return nil }
        var kcal = double(n["energy-kcal_100g"])
        if kcal == nil, let kj = double(n["energy-kj_100g"]) ?? double(n["energy_100g"]) { kcal = (kj / 4.184).rounded() }
        guard let energy = kcal else { return nil }
        let per100 = Nutrients(kcal: energy, protein: double(n["proteins_100g"]) ?? 0, fat: double(n["fat_100g"]) ?? 0,
                               carbs: double(n["carbohydrates_100g"]) ?? 0, fiber: double(n["fiber_100g"]), sugar: double(n["sugars_100g"]),
                               satFat: double(n["saturated-fat_100g"]), salt: double(n["salt_100g"]))
        guard per100.isPlausiblePer100 else { return nil }
        let code = string(p["code"]) ?? (p["code"] as? NSNumber)?.stringValue
        guard let name = string(p["product_name_de"]) ?? string(p["product_name"]) ?? string(p["generic_name_de"]) else { return nil }
        let brand = string(p["brands"])?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        let quantity = string(p["quantity"]) ?? ""
        let liquid = quantity.range(of: #"\d\s*(ml|cl|l)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        var serving = double(p["serving_quantity"])
        if let s = serving, s <= 0 || s > 2000 { serving = nil }
        return FoodItem(id: "off:\(code ?? UUID().uuidString)", name: name, brand: brand, barcode: code, source: .barcode,
                        per100: per100, unit: liquid ? "ml" : "g", servingGrams: serving, servingLabel: string(p["serving_size"]))
    }

    public static func parseProduct(_ data: Data) -> FoodItem? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = obj["product"] as? [String: Any] else { return nil }
        if let status = obj["status"] as? Int, status == 0 { return nil }
        if let status = obj["status"] as? String, status == "failure" { return nil }
        return item(from: p)
    }

    public static func parseSearch(_ data: Data) -> [FoodItem] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let list = (obj["hits"] as? [[String: Any]]) ?? (obj["products"] as? [[String: Any]]) ?? []
        return list.compactMap(item(from:))
    }

    static func get(_ url: URL, session: URLSession) async throws -> (Data, Int) {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await session.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw Failure.offline
        }
    }

    /// nil when the product is not in the database (or has no usable nutrition table).
    public static func product(_ code: String, session: URLSession = .shared) async throws -> FoodItem? {
        for c in normalize(code) {
            let (data, status) = try await get(productURL(c), session: session)
            if status == 404 { continue }
            guard status == 200 else { throw Failure.http(status) }
            if var item = parseProduct(data) {
                item.barcode = item.barcode ?? c
                return item
            }
        }
        return nil
    }

    public static func search(_ query: String, session: URLSession = .shared) async throws -> [FoodItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        if let (data, status) = try? await get(searchURL(q), session: session), status == 200 {
            let items = parseSearch(data)
            if !items.isEmpty { return items }
        }
        let (data, status) = try await get(legacySearchURL(q), session: session)
        guard status == 200 else { throw Failure.http(status) }
        return parseSearch(data)
    }
}
