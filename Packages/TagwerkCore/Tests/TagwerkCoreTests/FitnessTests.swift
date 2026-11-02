import XCTest
@testable import TagwerkCore

/// Reference values come from the JavaScript of "Lauf Chart.canvas", run unchanged on the same synthetic runs.
final class RunChartTests: XCTestCase {
    static let runs: [RunRecord] = [
        ("2026-02-03", 3.00, "00:17:10"), ("2026-02-10", 5.10, "00:28:40"), ("2026-03-01", 4.00, "00:21:30"),
        ("2026-03-15", 7.50, "00:41:12"), ("2026-04-02", 10.00, "00:54:30"), ("2026-05-20", 3.20, "00:16:05"),
        ("2026-07-01", 12.00, "01:08:00"), ("2026-08-15", 6.00, "00:31:20"),
    ].reversed().map { RunRecord(id: $0.0, runId: nil, path: "Laufzeiten/\($0.0).md", date: $0.0, distanceKm: $0.1, seconds: RunTime.seconds($0.2)!) }

    func testRunTime() {
        XCTAssertEqual(RunTime.seconds("00:16:29"), 989)
        XCTAssertEqual(RunTime.seconds("16:29"), 989)
        XCTAssertEqual(RunTime.seconds("1:18:51"), 4731)
        XCTAssertNil(RunTime.seconds("16:79"))
        XCTAssertNil(RunTime.seconds("abc"))
        XCTAssertEqual(RunTime.vault(989), "00:16:29")
        XCTAssertEqual(RunTime.vault(4731), "01:18:51")
        XCTAssertEqual(RunTime.display(989), "16:29")
        XCTAssertEqual(RunTime.display(4731), "1:18:51")
        XCTAssertEqual(RunTime.pace(5.27), "5:16")
        XCTAssertEqual(RunTime.distance(15.0249), "15.02")
    }

    func testMatchesCanvasNumbers() throws {
        let m = try XCTUnwrap(RunChartModel(runs: Self.runs))
        let a = 1e-9
        XCTAssertEqual(m.points.map(\.run.date).first, "2026-02-03", "sorted by date")
        XCTAssertEqual(m.xMedian, 5.55, accuracy: a)
        XCTAssertEqual(m.yMedian, 5.471666666666668, accuracy: a)
        XCTAssertEqual(m.xMin, 2.1, accuracy: a)
        XCTAssertEqual(m.xMax, 12.9, accuracy: a)
        XCTAssertEqual(m.yMin, 4.921614583333333, accuracy: a)
        XCTAssertEqual(m.yMax, 5.826649305555556, accuracy: a)
        XCTAssertEqual(m.slope, 0.023222807487027618, accuracy: a)
        XCTAssertEqual(m.intercept, 5.29958531543123, accuracy: a)
        XCTAssertEqual(m.r, 0.3221524446782334, accuracy: a)
        XCTAssertEqual(m.distMean, 6.35, accuracy: a)
        XCTAssertEqual(m.distStd, 3.271522144638049, accuracy: a)
        XCTAssertEqual(m.paceMean, 5.447050142973856, accuracy: a)
        XCTAssertEqual(m.paceStd, 0.23583222852882607, accuracy: a)
        let scores = [-1.0739768199280835, -0.506389248976762, -0.35997800058973606, 0.1597977587968723, 0.7208196974706745,
                      -0.0010343005206351341, 0.7966319674291544, 0.2641289463185076]
        for (p, s) in zip(m.points, scores) { XCTAssertEqual(p.score, s, accuracy: a, p.run.date) }
        let colors: [RGB] = [RGB(220, 38, 38), RGB(234, 177, 8), RGB(175, 175, 26), RGB(22, 163, 76), RGB(37, 152, 141), RGB(22, 163, 74),
                             RGB(41, 149, 159), RGB(23, 162, 80)]
        XCTAssertEqual(m.points.map { RunScale.color(score: $0.score, limit: 1) }, colors)
        XCTAssertEqual(m.correlationLabel, "schwache positive Korrelation")
        XCTAssertEqual(m.rangeLabel, "03.02.2026 – 15.08.2026 · 8 von 8 Läufen")
        XCTAssertEqual(RunTime.pace(m.yMin), "4:55")
    }

    func testDateFilterRecomputesSigma() throws {
        let m = try XCTUnwrap(RunChartModel(runs: Self.runs, range: 2...5))
        let scores = [-0.5114195547046846, 0.01339750785027538, 0.5989513943717067, -0.10092934751729876]
        XCTAssertEqual(m.points.count, 4)
        for (p, s) in zip(m.points, scores) { XCTAssertEqual(p.score, s, accuracy: 1e-9) }
        XCTAssertEqual(m.all.count, 8)
        XCTAssertEqual(RunChartModel(runs: Self.runs, range: 7...30)?.points.count, 1, "range is clamped")
    }

    func testSurfaceMatchesCanvas() throws {
        let m = try XCTUnwrap(RunChartModel(runs: Self.runs))
        let plain = m.surface(swapped: false)
        XCTAssertEqual(plain.count, 256)
        let expect: [(Int, Double, Double, Double)] = [(0, 2.1, 5.636417395839358, -1.1254492174883501), (17, 2.82, 5.716435401030306, -1.1011517336982686),
                                                       (100, 6.42, 5.48776233080339, -0.04651329872089446), (255, 12.9, 5.546004915395338, 1.1545226294894095)]
        for (k, d, p, s) in expect {
            XCTAssertEqual(plain[k].distance, d, accuracy: 1e-9)
            XCTAssertEqual(plain[k].pace, p, accuracy: 1e-9)
            XCTAssertEqual(plain[k].score, s, accuracy: 1e-9)
        }
        let swapped = m.surface(swapped: true)
        let expect2: [(Int, Double, Double, Double)] = [(0, 4.190176149609561, 5.826649305555556, -0.9924883862158522),
                                                        (17, 3.3726480988177454, 5.766313657407408, -1.0653738619725035),
                                                        (100, 7.806294645243051, 5.464635416666667, 0.26324443504010414),
                                                        (255, 5.863555090330083, 4.921614583333333, 0.6831530567949538)]
        for (k, d, p, s) in expect2 {
            XCTAssertEqual(swapped[k].distance, d, accuracy: 1e-9)
            XCTAssertEqual(swapped[k].pace, p, accuracy: 1e-9)
            XCTAssertEqual(swapped[k].score, s, accuracy: 1e-9)
        }
    }

    func testScoreColoursAtTwoWidths() {
        let table: [(Double, RGB, RGB)] = [
            (-2, RGB(220, 38, 38), RGB(226, 94, 26)), (-1, RGB(220, 38, 38), RGB(192, 176, 21)), (-0.6, RGB(231, 151, 14), RGB(124, 171, 42)),
            (-0.5, RGB(234, 179, 8), RGB(107, 169, 48)), (-0.2, RGB(107, 169, 48), RGB(56, 166, 63)), (0, RGB(22, 163, 74), RGB(22, 163, 74)),
            (0.3, RGB(24, 162, 82), RGB(22, 163, 75)), (0.9, RGB(48, 144, 188), RGB(25, 161, 87)), (1, RGB(55, 138, 221), RGB(26, 160, 90)),
            (1.4, RGB(63, 130, 218), RGB(30, 157, 111)), (2.5, RGB(127, 63, 191), RGB(55, 138, 221)),
        ]
        for (s, one, wide) in table {
            XCTAssertEqual(RunScale.color(score: s, limit: 1), one, "score \(s)")
            XCTAssertEqual(RunScale.color(score: s, limit: 2.5), wide, "score \(s), width 2.5")
        }
        XCTAssertEqual(RunScale.legend(limit: 1).count, 41)
    }

    func testSingleRunDoesNotDivideByZero() throws {
        let m = try XCTUnwrap(RunChartModel(runs: [Self.runs[0]]))
        XCTAssertEqual(m.distStd, 1)
        XCTAssertEqual(m.points[0].score, 0, accuracy: 1e-12)
        XCTAssertEqual(m.correlationLabel, "kaum Korrelation")
        XCTAssertNil(RunChartModel(runs: []))
    }

    func testRunEnergy() {
        let net: Double = 750 - 0.55 * 1796.25 * 55 / 1440
        XCTAssertEqual(RunEnergy.kcal(distanceKm: 10, seconds: 3300, weightKg: 75, bmr: 1796.25, pal: 1.55), net, accuracy: 1e-9)
        XCTAssertEqual(RunEnergy.kcal(distanceKm: 0, seconds: 100, weightKg: 75, bmr: 1800, pal: 1.5), 0)
    }
}

final class WeightChartTests: XCTestCase {
    let weights: [(date: String, kg: Double)] = [("2026-08-01", 71.1), ("2026-07-21", 70.0), ("2026-07-22", 70.6), ("2026-08-12", 70.4), ("2026-09-30", 72.0)]

    func testScaleWindowsAndSegmentsLikeCanvas() throws {
        let m = try XCTUnwrap(WeightChartModel(weights: weights))
        XCTAssertEqual(m.median, 70.6, accuracy: 1e-9)
        let pad: Double = 1.4 * 1.2
        XCTAssertEqual(m.yMin, 70.6 - pad, accuracy: 1e-9)
        XCTAssertEqual(m.yMax, 70.6 + pad, accuracy: 1e-9)
        XCTAssertEqual(m.maxOffset(.month), 2)
        XCTAssertEqual(m.maxOffset(.year), 0)
        XCTAssertEqual(m.window(.month, offset: 0).label, "Juli 2026")
        XCTAssertEqual(m.window(.month, offset: 2).end, "2026-09-30")
        XCTAssertEqual(m.window(.year, offset: 0).start, "2026-01-01")
        let july = m.visible(.month, offset: 0)
        XCTAssertEqual(july.map(\.date), ["2026-07-21", "2026-07-22"])
        let seg = WeightChartModel.segments(july)
        XCTAssertEqual(seg.count, 1)
        let width: Double = 1.5 + 0.6 * 3
        XCTAssertEqual(seg[0].width, width, accuracy: 1e-9)
        XCTAssertGreaterThan(seg[0].diff, 0)
        XCTAssertEqual(WeightChartModel.segments(m.visible(.year, offset: 0)).map { $0.diff > 0 }, [true, true, false, true])
        XCTAssertEqual(m.xTicks(.month, offset: 0), ["2026-07-01", "2026-07-05", "2026-07-09", "2026-07-13", "2026-07-17", "2026-07-21", "2026-07-25", "2026-07-29"])
        XCTAssertEqual(m.xTicks(.year, offset: 0).count, 12)
        XCTAssertEqual(m.yTicks.count, 5)
        XCTAssertEqual(WeightChartModel.footer(count: 1, median: 70.6), "1 Eintrag in diesem Zeitraum · Median gesamt: 70,6 kg")
        XCTAssertEqual(WeightChartModel.footer(count: 2, median: 70.6), "2 Einträge in diesem Zeitraum · Median gesamt: 70,6 kg")
    }

    func testMinimumScaleOfOneKilogram() throws {
        let m = try XCTUnwrap(WeightChartModel(weights: [("2026-11-01", 75), ("2026-11-02", 75.2)]))
        let span: Double = 2.4
        XCTAssertEqual(m.yMax - m.yMin, span, accuracy: 1e-9)
        XCTAssertNil(WeightChartModel(weights: []))
    }
}

final class NutritionTests: XCTestCase {
    func profile() -> BodyProfile {
        var p = BodyProfile()
        p.heightCm = 178
        p.birthYear = 1996
        p.sex = .male
        p.activity = .moderate
        return p
    }

    func testBasalRateFormulas() {
        var p = profile()
        let mifflin = NutritionCalculator.bmr(profile: p, weightKg: 75, year: 2026)
        let male: Double = 750 + 1112.5 - 150 + 5
        XCTAssertEqual(mifflin.kcal, male, accuracy: 1e-9)
        XCTAssertEqual(mifflin.formula, "Mifflin-St Jeor")
        p.sex = .female
        let female: Double = 750 + 1112.5 - 150 - 161
        XCTAssertEqual(NutritionCalculator.bmr(profile: p, weightKg: 75, year: 2026).kcal, female, accuracy: 1e-9)
        p.bodyFat = 15
        let katch = NutritionCalculator.bmr(profile: p, weightKg: 75, year: 2026)
        let lean: Double = 370 + 21.6 * 63.75
        XCTAssertEqual(katch.kcal, lean, accuracy: 1e-9)
        XCTAssertEqual(katch.formula, "Katch-McArdle")
    }

    func testTargetsForGainingAndLimits() {
        var p = profile()
        p.targetWeight = 80
        let t = NutritionCalculator.targets(profile: p, weightKg: 75, year: 2026)
        let bmr: Double = 750 + 1112.5 - 150 + 5
        XCTAssertEqual(t.tdee, bmr * 1.55, accuracy: 1e-9)
        let surplus: Double = 0.25 * 7700 / 7
        XCTAssertEqual(t.goalKcal, surplus, accuracy: 1e-9)
        let kcal: Double = bmr * 1.55 + 275
        XCTAssertEqual(t.kcal, kcal, accuracy: 1e-9)
        XCTAssertEqual(t.protein, 135, accuracy: 1e-9)
        let fat: Double = 0.27 * t.kcal / 9
        XCTAssertEqual(t.fat, fat, accuracy: 1e-9)
        let carbs: Double = (t.kcal - 4 * t.protein - 9 * t.fat) / 4
        XCTAssertEqual(t.carbs, carbs, accuracy: 1e-9)
        XCTAssertFalse(t.limited)

        p.targetWeight = 60
        p.weeklyRate = 1.5
        let cut = NutritionCalculator.targets(profile: p, weightKg: 75, year: 2026)
        let cap: Double = -0.25 * cut.tdee
        XCTAssertEqual(cut.goalKcal, cap, accuracy: 1e-9, "deficit capped at 25 %")
        XCTAssertTrue(cut.limited)

        p.targetWeight = nil
        let withRun = NutritionCalculator.targets(profile: p, weightKg: 75, year: 2026, runs: [(km: 10, seconds: 3300)])
        XCTAssertEqual(withRun.runKcal, RunEnergy.kcal(distanceKm: 10, seconds: 3300, weightKg: 75, bmr: bmr, pal: 1.55), accuracy: 1e-9)
        p.addRuns = false
        XCTAssertEqual(NutritionCalculator.targets(profile: p, weightKg: 75, year: 2026, runs: [(km: 10, seconds: 3300)]).runKcal, 0)
    }

    func testDailyCheck() {
        let p = profile()
        let t = NutritionTargets(kcal: 3000, protein: 135, fat: 90, carbs: 400, fiber: 30, bmr: 1800, tdee: 2800, runKcal: 0, goalKcal: 200,
                                 formula: "x", weightKg: 75, limited: false)
        let low = NutritionEvaluation.checks(totals: Nutrients(kcal: 2900, protein: 120, fat: 80, carbs: 380), targets: t, profile: p)
        XCTAssertEqual(low.map(\.kind), [.kcal, .protein])
        XCTAssertEqual(low[1].status, .low)
        XCTAssertEqual(low[1].statusText, "noch 1,5 g")
        XCTAssertFalse(NutritionEvaluation.met(low))
        let ok = NutritionEvaluation.checks(totals: Nutrients(kcal: 3250, protein: 125, fat: 80, carbs: 380), targets: t, profile: p)
        XCTAssertTrue(NutritionEvaluation.met(ok))
        let tooMuch = NutritionEvaluation.checks(totals: Nutrients(kcal: 3400, protein: 160, fat: 80, carbs: 380), targets: t, profile: p)
        XCTAssertEqual(tooMuch[0].status, .high)
        XCTAssertEqual(tooMuch[0].statusText, "100 kcal zu viel")
    }

    func testEntryMath() {
        let oats = FoodItem(id: "bls:C1", name: "Hafer Flocken", source: .bls, per100: Nutrients(kcal: 348, protein: 13.5, fat: 6.7, carbs: 55.7, fiber: 10))
        let e = oats.entry(grams: 80, meal: .breakfast, time: "07:40", id: "e1")
        XCTAssertEqual(e.nutrients.kcal, 278.4, accuracy: 1e-9)
        XCTAssertEqual(e.nutrients.fiber ?? 0, 8, accuracy: 1e-9)
        let sum = e.nutrients + Nutrients(kcal: 100, protein: 1, fat: 1, carbs: 1)
        XCTAssertEqual(sum.fiber ?? 0, 8, accuracy: 1e-9)
        XCTAssertNil((Nutrients.zero + .zero).fiber)
        XCTAssertEqual(e.amountLabel, "80 g")
        XCTAssertEqual(NutritionFormat.kcal(2650.4), "2.650")
        XCTAssertEqual(Meal.guess(hour: 8), .breakfast)
        XCTAssertEqual(Meal.guess(hour: 19), .dinner)
    }
}

final class FoodTextTests: XCTestCase {
    func testParsesAmounts() {
        func p(_ s: String) -> (Double?, FoodUnit?, String) {
            let r = FoodText.parse(s)
            return (r.quantity, r.unit, r.name)
        }
        XCTAssertTrue(p("2 Eier") == (2, nil, "eier"))
        XCTAssertTrue(p("1 Scheibe Vollkornbrot") == (1, .slice, "vollkornbrot"))
        XCTAssertTrue(p("ein Glas Milch") == (1, .glass, "milch"))
        XCTAssertTrue(p("Haferflocken 80g") == (80, .gram, "haferflocken"))
        XCTAssertTrue(p("Banane (120 g)") == (120, .gram, "banane"))
        XCTAssertTrue(p("halbe Avocado") == (0.5, nil, "avocado"))
        XCTAssertTrue(p("200g Hähnchenbrust") == (200, .gram, "hahnchenbrust"))
        XCTAssertTrue(p("2x Toast") == (2, nil, "toast"))
        XCTAssertTrue(p("etwa 0,5 l Apfelschorle") == (0.5, .liter, "apfelschorle"))
        XCTAssertTrue(p("Scheibe Käse") == (1, .slice, "kase"))
        XCTAssertTrue(p("Kaffee") == (nil, nil, "kaffee"))
        XCTAssertEqual(FoodText.phrases("Kaffee mit Milch und 2 Eier, Brot\nApfel"), ["Kaffee", "Milch", "2 Eier", "Brot", "Apfel"])
        XCTAssertEqual(FoodText.variants("eier"), ["eier", "ei"])
        XCTAssertEqual(FoodText.variants("tomaten"), ["tomaten", "tomat", "tomate"])
    }

    func index() -> FoodIndex {
        func f(_ id: String, _ name: String, _ kcal: Double) -> FoodItem {
            FoodItem(id: "bls:\(id)", name: name, source: .bls, per100: Nutrients(kcal: kcal, protein: 1, fat: 1, carbs: 1))
        }
        let items = [f("E1", "Hühnerei gekocht", 144), f("B1", "Vollkornbrot", 210), f("B2", "Roggenvollkornbrot", 193),
                     f("M1", "Vollmilch frisch, 3,5 % Fett, pasteurisiert", 62), f("C1", "Hafer Flocken", 348), f("F1", "Banane roh", 79),
                     f("F2", "Bananenchips frittiert, gesüßt", 490), f("Q1", "Butter mild gesäuert", 747), f("N1", "Kaffee (Getränk)", 1)]
        let aliases = [FoodAlias(["ei", "eier", "hühnerei"], "Hühnerei gekocht", piece: 58), FoodAlias(["milch"], "Vollmilch frisch, 3,5 % Fett, pasteurisiert", portion: 200),
                       FoodAlias(["haferflocken"], "Hafer Flocken", portion: 60), FoodAlias(["vollkornbrot", "brot"], "Vollkornbrot", slice: 50),
                       FoodAlias(["butter"], "Butter mild gesäuert", portion: 10), FoodAlias(["banane"], "Banane roh", piece: 120)]
        return FoodIndex(items: items, english: ["bls:F1": "Banana raw"], aliases: aliases)
    }

    func testResolvesADescription() {
        let r = index().resolveAll("2 Eier, 1 Scheibe Vollkornbrot mit Butter und ein Glas Milch, Zaubertrank")
        XCTAssertEqual(r.found.map(\.item.name), ["Hühnerei gekocht", "Vollkornbrot", "Butter mild gesäuert", "Vollmilch frisch, 3,5 % Fett, pasteurisiert"])
        XCTAssertEqual(r.found.map(\.grams), [116, 50, 10, 200])
        XCTAssertEqual(r.unknown.map(\.name), ["zaubertrank"])
    }

    func testSearchRanking() {
        let i = index()
        XCTAssertEqual(i.search("banane").first?.item.name, "Banane roh")
        XCTAssertEqual(i.search("Vollkornbrot").first?.item.name, "Vollkornbrot")
        XCTAssertEqual(i.search("roggen vollkornbrot").first?.item.name, "Roggenvollkornbrot")
        XCTAssertEqual(i.search("haferflocken").first?.item.name, "Hafer Flocken", "compound against two words")
        XCTAssertEqual(i.search("banana", english: true).first?.item.name, "Banane roh")
        XCTAssertTrue(i.search("xyz").isEmpty)
        i.setPersonal([FoodItem(id: "custom:1", name: "Bananenbrot von Oma", source: .custom, per100: .zero)])
        XCTAssertEqual(i.search("bananenbrot").first?.item.id, "custom:1")
        XCTAssertEqual(i.alias(for: "Eier")?.item.name, "Hühnerei gekocht")
    }
}

final class LabelAndProductTests: XCTestCase {
    func testReadsEUNutritionTable() throws {
        let lines = ["Nährwerte pro 100 g pro Portion (30 g)", "Brennwert 1555 kJ / 372 kcal 467 kJ / 112 kcal", "Fett 7,0 g 2,1 g",
                     "davon gesättigte Fettsäuren 1,2 g 0,4 g", "Kohlenhydrate 58,7 g 17,6 g", "davon Zucker 0,7 g 0,2 g", "Ballaststoffe 10 g 3,0 g",
                     "Eiweiß 13,5 g 4,1 g", "Salz 0,02 g <0,01 g"]
        let r = try XCTUnwrap(NutritionLabelParser.parse(lines: lines))
        XCTAssertEqual(r.per100, Nutrients(kcal: 372, protein: 13.5, fat: 7, carbs: 58.7, fiber: 10, sugar: 0.7, satFat: 1.2, salt: 0.02))
        XCTAssertEqual(r.unit, "g")
        XCTAssertEqual(r.found.count, 8)
    }

    func testEnergyOnTheNextLineAndMillilitres() throws {
        let r = try XCTUnwrap(NutritionLabelParser.parse(lines: ["Durchschnittliche Nährwerte je 100 ml", "Energie 180 kJ", "43 kcal", "Fett 0 g",
                                                               "Kohlenhydrate 10,6 g", "davon Zucker 10,6 g", "Eiweiß 0 g", "Salz 0 g"]))
        XCTAssertEqual(r.per100.kcal, 43)
        XCTAssertEqual(r.per100.carbs, 10.6)
        XCTAssertEqual(r.unit, "ml")
        XCTAssertNil(NutritionLabelParser.parse(lines: ["Zutaten: Wasser, Zucker"]))
        XCTAssertNil(NutritionLabelParser.parse(lines: ["Brennwert 9999 kcal", "Fett 300 g"]), "implausible values are refused")
    }

    func testOpenFoodFactsProduct() throws {
        let json = #"{"code":"4000000000001","status":1,"product":{"code":"4000000000001","product_name":"Skyr natur","product_name_de":"Skyr Natur","brands":"Testmarke, Andere","quantity":"450 g","serving_size":"150 g","serving_quantity":"150","nutriments":{"energy-kcal_100g":64,"proteins_100g":"11","fat_100g":0.2,"carbohydrates_100g":4,"sugars_100g":4,"salt_100g":0.1}}}"#
        let item = try XCTUnwrap(OpenFoodFacts.parseProduct(Data(json.utf8)))
        XCTAssertEqual(item.id, "off:4000000000001")
        XCTAssertEqual(item.name, "Skyr Natur")
        XCTAssertEqual(item.brand, "Testmarke")
        XCTAssertEqual(item.servingGrams, 150)
        XCTAssertEqual(item.unit, "g")
        XCTAssertEqual(item.per100.protein, 11)
        XCTAssertEqual(item.suggestedGrams, 150)

        let drink = #"{"status":1,"product":{"code":"5","product_name":"Apfelschorle","quantity":"1,5 l","nutriments":{"energy_100g":105,"carbohydrates_100g":6}}}"#
        let d = try XCTUnwrap(OpenFoodFacts.parseProduct(Data(drink.utf8)))
        XCTAssertEqual(d.per100.kcal, 25)
        XCTAssertEqual(d.unit, "ml")
        XCTAssertNil(OpenFoodFacts.parseProduct(Data(#"{"status":0,"status_verbose":"product not found"}"#.utf8)))
        XCTAssertNil(OpenFoodFacts.parseProduct(Data(#"{"status":1,"product":{"product_name":"Ohne Werte"}}"#.utf8)))
        let hits = OpenFoodFacts.parseSearch(Data(#"{"hits":[{"code":"1","product_name":"A","nutriments":{"energy-kcal_100g":100}},{"code":"2"}]}"#.utf8))
        XCTAssertEqual(hits.map(\.name), ["A"])
        XCTAssertEqual(OpenFoodFacts.normalize("012345678905"), ["012345678905", "0012345678905"])
        XCTAssertEqual(OpenFoodFacts.normalize(" 0012345678905 "), ["0012345678905", "012345678905"])
        XCTAssertEqual(OpenFoodFacts.normalize("12"), [])
    }
}

final class FitnessProtocolTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-11-01T18:00:00Z")!

    func testRunEventsInVaultNotation() throws {
        let e = EventFactory.runAdd(runId: "run-1", date: "2026-11-01", distanceKm: 5.0234, seconds: 989, source: "gps", now: now, id: "evt-1")
        XCTAssertEqual(String(data: e.json, encoding: .utf8),
                       #"{"date":"2026-11-01","distance":"5.02","id":"evt-1","runId":"run-1","source":"gps","time":"00:16:29","ts":"2026-11-01T18:00:00.000Z","type":"run.add"}"#)
        XCTAssertEqual(e.requiredFeature, "runs")
        let d = EventFactory.runPatch(runId: nil, path: "a.md", deleted: true, now: now, id: "evt-2")
        XCTAssertEqual(String(data: d.json, encoding: .utf8), #"{"deleted":true,"id":"evt-2","path":"a.md","ts":"2026-11-01T18:00:00.000Z","type":"run.patch"}"#)
        XCTAssertNil(EventFactory.dayPatch(date: "2026-11-01", habits: ["gym": true]).requiredFeature)
    }

    func testFoodDayAndProfileRoundTrip() throws {
        let entry = FoodItem(id: "off:1", name: "Skyr", brand: "M", barcode: "1", source: .barcode, per100: Nutrients(kcal: 64, protein: 11, fat: 0.2, carbs: 4))
            .entry(grams: 250, meal: .lunch, time: "12:15", id: "f1")
        let e = EventFactory.foodDay(date: "2026-11-01", entries: [entry], targets: nil, met: true, now: now, id: "evt-3")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: e.json) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "food.day")
        XCTAssertTrue(obj["targets"] is NSNull)
        XCTAssertEqual(obj["met"] as? Bool, true)
        let first = try XCTUnwrap((obj["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["meal"] as? String, "mittag")
        XCTAssertEqual((first["per100"] as? [String: Any])?["kcal"] as? Double, 64)
        XCTAssertNil(first["note"], "nil fields are left out")
        let back = try JSONDecoder().decode(SnapshotFoodDay.self, from: JSONSerialization.data(withJSONObject: ["date": "2026-11-01", "entries": obj["entries"]!]))
        XCTAssertEqual(back.entries, [entry])

        var p = BodyProfile()
        p.bodyFat = 17.5
        let pe = EventFactory.profileSet(p, summary: "Ziel", now: now, id: "evt-4")
        let po = try XCTUnwrap(try JSONSerialization.jsonObject(with: pe.json) as? [String: Any])
        let prof = try XCTUnwrap(po["profile"] as? [String: Any])
        XCTAssertEqual(prof["activity"] as? String, "maessig")
        XCTAssertEqual(prof["sex"] as? String, "m")
        XCTAssertNil(prof["targetWeight"])
        XCTAssertEqual(po["summary"] as? String, "Ziel")
        XCTAssertEqual(pe.requiredFeature, "profile")
    }

    func testDecodesFitnessPartOfPluginSnapshot() throws {
        let plain = try TagwerkCrypto.open(Data(Vectors.snapshotEnvelope.utf8), passphrase: Vectors.passphrase, kind: .snapshot)
        let snap = try JSONDecoder().decode(Snapshot.self, from: plain)
        XCTAssertEqual(snap.features, ["runs", "food", "profile", "planner", "wiki"])
        XCTAssertEqual(snap.runs.map(\.date), ["2026-10-28", "2026-11-01"])
        XCTAssertEqual(snap.runs[0].seconds, 1720)
        XCTAssertEqual(snap.runs[0].distanceKm, 5.1)
        XCTAssertNil(snap.runs[0].runId)
        XCTAssertEqual(snap.runs[1].runId, "run-v1-0000")
        XCTAssertEqual(snap.runs[1].seconds, 989)
        XCTAssertEqual(snap.foodDays.count, 1)
        XCTAssertEqual(snap.foodDays[0].entries.map(\.name), ["Hafer Flocken", "Skyr Natur"])
        XCTAssertEqual(snap.foodDays[0].entries[1].brand, "Testmarke")
        XCTAssertEqual(snap.foodDays[0].targets?.kcal, 2700)
        XCTAssertEqual(snap.foodDays[0].met, false)
        let p = try XCTUnwrap(snap.profile)
        XCTAssertEqual(p.heightCm, 178)
        XCTAssertEqual(p.bodyFat, 17.5)
        XCTAssertEqual(p.activity, .moderate)
        XCTAssertTrue(p.checkFiber)
        XCTAssertEqual(p.updated, "2026-11-01")
    }
}
