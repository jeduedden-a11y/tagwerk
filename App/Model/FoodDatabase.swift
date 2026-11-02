import Foundation
import TagwerkCore

/// The bundled food table: Bundeslebensmittelschlüssel 4.0 (Max Rubner-Institut, CC BY 4.0), 7,133 foods,
/// values per 100 g of the edible part. Loaded once in the background, searched on the device.
final class FoodDatabase: @unchecked Sendable {
    static let shared = FoodDatabase()

    static let attribution = "Max Rubner-Institut (2025): Bundeslebensmittelschlüssel (BLS), Version 4.0 – Deutsche Nährstoffdatenbank. Karlsruhe. DOI 10.25826/Data20251217-134202-0, Lizenz CC BY 4.0. Auszug: zehn Komponenten, gerundet, Errata 08/2026 angewandt."

    private let lock = NSLock()
    private var _index: FoodIndex?
    private var loading: Task<FoodIndex?, Never>?

    var index: FoodIndex? { lock.withLock { _index } }

    /// Starts loading if needed and returns the index once it is ready.
    func load() async -> FoodIndex? {
        let task: Task<FoodIndex?, Never> = lock.withLock {
            if let loading { return loading }
            let t = Task.detached(priority: .utility) { () -> FoodIndex? in
                guard let url = Bundle.main.url(forResource: "BLS", withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
                return FoodDatabase.build(from: data)
            }
            loading = t
            return t
        }
        let result = await task.value
        lock.withLock { _index = result }
        return result
    }

    static func build(from data: Data) -> FoodIndex? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = obj["foods"] as? [[Any]] else { return nil }
        func num(_ v: Any) -> Double? { (v as? NSNumber)?.doubleValue }
        var items: [FoodItem] = []
        var english: [String: String] = [:]
        items.reserveCapacity(rows.count)
        let measures = Dictionary(FoodAliases.all.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for r in rows where r.count >= 11 {
            guard let code = r[0] as? String, let name = r[1] as? String, let kcal = num(r[3]) else { continue }
            let id = "bls:\(code)"
            let liquid = code.hasPrefix("N") || code.hasPrefix("P") || code.hasPrefix("M1")
            let a = measures[name]
            let n = Nutrients(kcal: kcal, protein: num(r[4]) ?? 0, fat: num(r[5]) ?? 0, carbs: num(r[6]) ?? 0,
                              fiber: num(r[7]), sugar: num(r[8]), satFat: num(r[9]), salt: num(r[10]))
            items.append(FoodItem(id: id, name: name, source: .bls, per100: n, unit: liquid ? "ml" : "g",
                                  pieceGrams: a?.piece ?? a?.slice, defaultGrams: a?.portion))
            if let en = r[2] as? String { english[id] = en }
        }
        return FoodIndex(items: items, english: english, aliases: FoodAliases.all)
    }
}

/// Everyday words that the table names differently, with typical amounts (household measures).
enum FoodAliases {
    static let all: [FoodAlias] = [
        // Eggs
        FoodAlias(["ei", "eier", "hühnerei", "gekochtes ei", "gekochte eier", "frühstücksei"], "Hühnerei gekocht", piece: 58, portion: 58),
        FoodAlias(["rohes ei"], "Hühnerei roh", piece: 58),
        FoodAlias(["rührei", "rühreier"], "Rührei gebraten", portion: 120),
        FoodAlias(["spiegelei", "spiegeleier"], "Spiegelei gebraten", piece: 60, portion: 60),
        // Bread and cereals
        FoodAlias(["brot", "graubrot", "mischbrot"], "Roggenmischbrot", slice: 45, portion: 90),
        FoodAlias(["vollkornbrot"], "Vollkornbrot", slice: 45, portion: 90),
        FoodAlias(["toast", "toastbrot", "toastscheibe"], "Weizenmischtoastbrot", slice: 25, portion: 50),
        FoodAlias(["vollkorntoast"], "Weizenvollkorntoastbrot", slice: 25, portion: 50),
        FoodAlias(["brötchen", "semmel", "weizenbrötchen", "schrippe"], "Weizenbrötchen", piece: 60, portion: 60),
        FoodAlias(["weißbrot", "baguette"], "Weizenbrot/Weißbrot", slice: 30, portion: 60),
        FoodAlias(["brezel", "breze", "laugenbrezel"], "Laugengebäck mit Hagelsalz", piece: 80, portion: 80),
        FoodAlias(["croissant"], "Croissant (Hefeblätterteig/Plunderteig)", piece: 60, portion: 60),
        FoodAlias(["haferflocken", "hafer", "oats"], "Hafer Flocken", portion: 50),
        FoodAlias(["porridge", "haferbrei"], "Hafer Flocken, gekocht", portion: 250),
        FoodAlias(["müsli", "muesli"], "Müsli Basismischung (ohne Trockenfrüchte) ungesüßt", portion: 60),
        FoodAlias(["cornflakes"], "Cornflakes gesüßt", portion: 40),
        // Pasta, rice, potatoes
        FoodAlias(["nudeln", "pasta", "spaghetti", "penne", "teigwaren", "fusilli"], "Teigwaren eifrei, gekocht", portion: 250),
        FoodAlias(["rohe nudeln", "nudeln roh", "nudeln trocken"], "Teigwaren eifrei, roh", portion: 100),
        FoodAlias(["reis", "basmati", "basmatireis"], "Reis gekocht", portion: 200),
        FoodAlias(["kartoffeln", "kartoffel", "salzkartoffeln"], "Kartoffel geschält, gekocht", piece: 80, portion: 250),
        FoodAlias(["pellkartoffeln"], "Kartoffeln mit Schale gekocht", piece: 80, portion: 250),
        FoodAlias(["pommes", "pommes frites", "fritten"], "Pommes frites", portion: 150),
        FoodAlias(["bratkartoffeln"], "Bratkartoffeln aus rohen Kartoffeln, mit Zwiebeln", portion: 250),
        // Dairy
        FoodAlias(["milch", "vollmilch", "kuhmilch"], "Vollmilch frisch, 3,5 % Fett, pasteurisiert", portion: 200),
        FoodAlias(["fettarme milch", "milch fettarm"], "Milch fettarm, frisch, 1,5 % Fett, pasteurisiert", portion: 200),
        FoodAlias(["joghurt", "naturjoghurt"], "Joghurt mild, mind. 3,5 % Fett", portion: 150),
        FoodAlias(["magerquark", "quark"], "Speisequark Magerstufe, Magerquark < 10 % Fett i. Tr.", portion: 250),
        FoodAlias(["skyr"], "Skyr, Frischkäse < 10 % Fett i. Tr.", portion: 150),
        FoodAlias(["hüttenkäse", "körniger frischkäse", "cottage cheese"], "Körniger Frischkäse < 10 % Fett i. Tr.", portion: 200),
        FoodAlias(["käse", "gouda", "käsescheibe"], "Gouda 48 % Fett i. Tr.", slice: 25, portion: 30),
        FoodAlias(["mozzarella"], "Mozzarella mind. 45 % Fett i. Tr.", piece: 125, portion: 125),
        FoodAlias(["feta", "schafskäse"], "Feta mind. 45 % Fett i. Tr.", portion: 50),
        FoodAlias(["butter"], "Butter mild gesäuert", portion: 10),
        // Meat, fish, dishes
        FoodAlias(["hähnchen", "hähnchenbrust", "hühnchen", "hühnerbrust", "chicken", "hähnchenbrustfilet"], "Hähnchen Brust, ohne Haut, gebraten ohne Fett (Pfanne)", portion: 150),
        FoodAlias(["hackfleisch", "hack", "rinderhack"], "Rind Hackfleisch, gebraten ohne Fett (Pfanne)", portion: 125),
        FoodAlias(["lachs", "lachsfilet"], "Lachs gegrillt", portion: 125),
        FoodAlias(["thunfisch"], "Thunfisch im eigenen Saft, Konserve, abgetropft", portion: 130),
        FoodAlias(["salami"], "Salami", slice: 10, portion: 30),
        FoodAlias(["schinken", "kochschinken"], "Schwein Kochschinken, Kochpökelware", slice: 20, portion: 40),
        FoodAlias(["wiener", "würstchen", "wiener würstchen"], "Wiener Würstchen", piece: 50, portion: 100),
        FoodAlias(["bratwurst"], "Bratwurst gebraten", piece: 100, portion: 100),
        FoodAlias(["schnitzel", "wiener schnitzel"], "Wiener Schnitzel gebraten", piece: 150, portion: 150),
        FoodAlias(["leberkäse", "fleischkäse"], "Leberkäse", slice: 100, portion: 100),
        FoodAlias(["döner", "döner kebab", "doner"], "Döner Kebab, Fladenbrot gefüllt mit Grillfleisch (Kalb/Rind), Rohkost und Sauce", piece: 400, portion: 400),
        FoodAlias(["currywurst"], "Currywurst mit Curryketchup", portion: 200),
        FoodAlias(["gyros"], "Gyros (Schweinefleisch) gebraten", portion: 200),
        FoodAlias(["pizza", "pizza margherita"], "Pizza Margherita (mit Tomatensauce, Mozzarella)", piece: 350, slice: 90, portion: 350),
        FoodAlias(["burger", "hamburger"], "Hamburger", piece: 200, portion: 200),
        FoodAlias(["cheeseburger"], "Cheeseburger", piece: 120, portion: 120),
        FoodAlias(["lasagne"], "Lasagne al forno, Teigwaren geschichtet mit Bechamel- und Bologneser Sauce, mit Käse überbacken", portion: 350),
        FoodAlias(["sushi"], "Sushi mit Lachs", piece: 30, portion: 250),
        FoodAlias(["tofu"], "Tofu", portion: 125),
        // Fruit and vegetables
        FoodAlias(["apfel", "äpfel"], "Apfel roh", piece: 150, portion: 150),
        FoodAlias(["banane", "bananen"], "Banane roh", piece: 120, portion: 120),
        FoodAlias(["orange", "apfelsine", "orangen"], "Orange roh", piece: 150, portion: 150),
        FoodAlias(["erdbeeren", "erdbeere"], "Erdbeere roh", piece: 15, portion: 150),
        FoodAlias(["heidelbeeren", "blaubeeren"], "Heidelbeere roh", portion: 125),
        FoodAlias(["weintrauben", "trauben"], "Weintraube roh", portion: 125),
        FoodAlias(["kiwi"], "Kiwi roh", piece: 75, portion: 75),
        FoodAlias(["mango"], "Mango roh", piece: 250, portion: 200),
        FoodAlias(["ananas"], "Ananas roh", portion: 150),
        FoodAlias(["avocado"], "Avocado roh", piece: 140, portion: 70),
        FoodAlias(["tomate", "tomaten"], "Tomate roh", piece: 80, portion: 160),
        FoodAlias(["gurke", "gurken"], "Gurke roh", piece: 300, portion: 100),
        FoodAlias(["paprika"], "Gemüsepaprika rot, roh", piece: 150, portion: 150),
        FoodAlias(["karotte", "karotten", "möhre", "möhren"], "Karotte/Möhre, roh", piece: 70, portion: 100),
        FoodAlias(["brokkoli", "broccoli"], "Broccoli gekocht", portion: 200),
        FoodAlias(["spinat"], "Spinat gekocht", portion: 200),
        FoodAlias(["salat", "gemischter salat", "beilagensalat"], "Gemischter Salat ohne Salatmarinade", portion: 150),
        FoodAlias(["kichererbsen"], "Kichererbse reif, gekocht", portion: 150),
        FoodAlias(["hummus"], "Hummus/Kichererbsenmus", portion: 50),
        // Spreads, nuts, oils
        FoodAlias(["erdnussbutter", "erdnussmus"], "Erdnussmus", portion: 15),
        FoodAlias(["mandeln"], "Mandel süß", portion: 30),
        FoodAlias(["walnüsse"], "Walnuss", portion: 30),
        FoodAlias(["haselnüsse"], "Haselnuss", portion: 30),
        FoodAlias(["nutella", "nuss nougat creme", "nougatcreme"], "Nuss-Nougat-Creme", portion: 15),
        FoodAlias(["honig"], "Honig", portion: 10),
        FoodAlias(["marmelade", "konfitüre"], "Konfitüre extra", portion: 20),
        FoodAlias(["olivenöl"], "Olivenöl", portion: 10),
        FoodAlias(["rapsöl", "öl"], "Rapsöl/Rüböl", portion: 10),
        FoodAlias(["ketchup"], "Tomatenketchup", portion: 20),
        // Drinks
        FoodAlias(["kaffee"], "Kaffee (Getränk)", portion: 200),
        FoodAlias(["tee", "schwarztee"], "Schwarztee (Getränk)", portion: 250),
        FoodAlias(["grüntee", "grüner tee"], "Grüntee (Getränk)", portion: 250),
        FoodAlias(["wasser", "leitungswasser"], "Trinkwasser", portion: 250),
        FoodAlias(["mineralwasser", "sprudel"], "Natürliches Mineralwasser mit Kohlensäure", portion: 250),
        FoodAlias(["cola"], "Colagetränk koffeinhaltig", portion: 330),
        FoodAlias(["apfelsaft"], "Apfelsaft", portion: 200),
        FoodAlias(["orangensaft", "o-saft"], "Orangensaft", portion: 200),
        FoodAlias(["bier", "pils"], "Pilsner Bier", portion: 500),
        FoodAlias(["wein", "rotwein"], "Rotwein trocken", portion: 200),
        FoodAlias(["hafermilch", "haferdrink"], "Haferdrink ungesüßt", portion: 200),
        FoodAlias(["sojamilch", "sojadrink"], "Sojadrink ungesüßt", portion: 200),
        // Sweets and snacks
        FoodAlias(["schokolade", "milchschokolade"], "Milchschokolade", portion: 25),
        FoodAlias(["zartbitterschokolade", "bitterschokolade"], "Bitterschokolade", portion: 25),
        FoodAlias(["gummibärchen", "fruchtgummi", "gummibären"], "Fruchtgummi (Gummibonbon)", portion: 50),
        FoodAlias(["chips", "kartoffelchips"], "Kartoffelchips/Stapelchips, diverse Sorten", portion: 50),
        FoodAlias(["popcorn"], "Popcorn gesalzen", portion: 50),
        FoodAlias(["eis", "speiseeis", "vanilleeis"], "Vanilleeis", portion: 120),
        FoodAlias(["kuchen", "rührkuchen"], "Kuchen aus Rührmasse/Rührkuchen", piece: 80, portion: 80),
        FoodAlias(["kekse", "keks", "butterkekse"], "Buttergebäck (Mürbeteig)", piece: 10, portion: 30),
        FoodAlias(["waffel", "waffeln"], "Waffeln, einfache (Rührmasse)", piece: 60, portion: 60),
        FoodAlias(["pfannkuchen", "eierkuchen", "pancakes"], "Pfannkuchen/Eierkuchen, ungesüßt, mit Milch 3,5 % Fett, gebraten", piece: 120, portion: 240),
    ]
}

/// Labels of the on-device image classifier (Vision) mapped to German words the table understands.
/// The classifier only names what it sees; amounts always come from the user.
enum FoodVision {
    static let generic: Set<String> = ["food", "dish", "meal", "produce", "fruit", "vegetable", "dessert", "snack", "beverage", "drink",
                                       "baked_goods", "cuisine", "plate", "bowl", "tableware", "dinner", "lunch", "breakfast", "ingredient"]

    static let terms: [String: String] = [
        "apple": "apfel", "banana": "banane", "orange": "orange", "citrus_fruit": "orange", "strawberry": "erdbeere",
        "blueberry": "heidelbeeren", "berry": "erdbeere", "grape": "weintrauben", "kiwi": "kiwi", "mango": "mango", "pineapple": "ananas",
        "avocado": "avocado", "tomato": "tomate", "cucumber": "gurke", "carrot": "karotte", "broccoli": "brokkoli", "spinach": "spinat",
        "salad": "salat", "lettuce": "salat", "potato": "kartoffeln", "french_fries": "pommes", "fries": "pommes", "rice": "reis",
        "pasta": "nudeln", "spaghetti": "nudeln", "noodles": "nudeln", "bread": "brot", "toast": "toast", "croissant": "croissant",
        "pretzel": "brezel", "sandwich": "sandwich", "burger": "burger", "hamburger": "burger", "cheeseburger": "cheeseburger",
        "pizza": "pizza", "sushi": "sushi", "steak": "rindersteak", "chicken": "hähnchen", "fried_chicken": "hähnchen",
        "fish": "fisch", "salmon": "lachs", "egg": "ei", "fried_egg": "spiegelei", "omelet": "rührei", "scrambled_eggs": "rührei",
        "cheese": "käse", "yogurt": "joghurt", "milk": "milch", "coffee": "kaffee", "cappuccino": "kaffee", "espresso": "kaffee",
        "tea": "tee", "juice": "orangensaft", "orange_juice": "orangensaft", "beer": "bier", "wine": "wein", "red_wine": "wein",
        "soup": "suppe", "cake": "kuchen", "cupcake": "muffin", "muffin": "muffin", "cookie": "kekse", "chocolate": "schokolade",
        "ice_cream": "eis", "donut": "berliner", "doughnut": "berliner", "waffle": "waffeln", "pancake": "pfannkuchen", "crepe": "pfannkuchen",
        "cereal": "müsli", "granola": "müsli", "oatmeal": "porridge", "porridge": "porridge", "nut": "mandeln", "almond": "mandeln",
        "peanut": "erdnuss", "sausage": "würstchen", "hot_dog": "würstchen", "bacon": "speck", "ham": "schinken", "tofu": "tofu",
        "curry": "curry", "taco": "taco", "burrito": "burrito", "kebab": "döner", "gyro": "gyros", "lasagna": "lasagne",
        "dumpling": "knödel", "smoothie": "smoothie", "water": "wasser", "soda": "cola", "cola": "cola", "chips": "chips",
        "popcorn": "popcorn", "candy": "fruchtgummi", "gummy": "fruchtgummi", "honey": "honig", "jam": "marmelade", "butter": "butter",
        "schnitzel": "schnitzel", "meatball": "frikadelle", "shrimp": "garnelen", "risotto": "risotto", "paella": "paella",
        "bagel": "bagel", "wrap": "wrap", "quiche": "quiche", "pie": "kuchen", "brownie": "brownie", "tart": "kuchen",
    ]

    static func german(for identifier: String) -> String? {
        let key = identifier.lowercased().replacingOccurrences(of: " ", with: "_")
        if let t = terms[key] { return t }
        // "red_apple", "green_salad": last word decides
        if let last = key.split(separator: "_").last.map(String.init), let t = terms[last] { return t }
        return nil
    }
}
