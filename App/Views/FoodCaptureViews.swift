import AVFoundation
import PhotosUI
import SwiftUI
import TagwerkCore
import UIKit
import VisionKit

enum FoodRoute: Hashable {
    case amount(FoodItem, grams: Double?, note: String?)
    case label(barcode: String?)
    case describe(String)
    case search(String)
    case manual(barcode: String?)
}

/// One sheet for every way of adding food; ends with the amount, where the entry is made.
struct FoodCaptureSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let capture: FoodCapture
    @State private var path: [FoodRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: FoodRoute.self) { route in
                    destination(route)
                }
        }
        .task { await store.loadFoodDatabase() }
    }

    @ViewBuilder
    private var root: some View {
        switch capture.mode {
        case .scan:
            BarcodeScanView(path: $path, close: close)
        case .search:
            FoodSearchView(initialQuery: "", pick: pick, close: close)
        case .photo:
            PhotoMealView(path: $path, close: close)
        case .describe:
            DescribeMealView(day: capture.day, initialText: "", path: $path, close: close)
        case .manual:
            ManualFoodView(barcode: nil, pick: pick, close: close)
        case .item(let item, let grams):
            FoodAmountView(item: item, day: capture.day, initialGrams: grams, note: nil, editing: nil, done: close)
        case .entry(let entry):
            FoodAmountView(item: entry.item, day: capture.day, initialGrams: entry.grams, note: entry.note, editing: entry, done: close)
        }
    }

    @ViewBuilder
    private func destination(_ route: FoodRoute) -> some View {
        switch route {
        case .amount(let item, let grams, let note):
            FoodAmountView(item: item, day: capture.day, initialGrams: grams, note: note, editing: nil, done: close)
        case .label(let barcode):
            LabelCaptureView(barcode: barcode, pick: pick)
        case .describe(let text):
            DescribeMealView(day: capture.day, initialText: text, path: $path, close: close)
        case .search(let q):
            FoodSearchView(initialQuery: q, pick: pick, close: nil)
        case .manual(let barcode):
            ManualFoodView(barcode: barcode, pick: pick, close: nil)
        }
    }

    private func pick(_ item: FoodItem, _ grams: Double?) { path.append(.amount(item, grams: grams, note: nil)) }
    private func close() { dismiss() }
}

private struct CloseButton: ToolbarContent {
    var close: (() -> Void)?
    var body: some ToolbarContent {
        if let close {
            ToolbarItem(placement: .cancellationAction) {
                Button("Schließen", action: close)
            }
        }
    }
}

// MARK: - Barcode

struct BarcodeScanView: View {
    @Environment(Store.self) private var store
    @Binding var path: [FoodRoute]
    var close: () -> Void
    @State private var scanning = true
    @State private var looking: String?
    @State private var notFound: String?
    @State private var error: String?
    @State private var typed = ""
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)
    @FocusState private var typing: Bool

    private var scannerUsable: Bool { DataScannerViewController.isSupported && camera == .authorized && DataScannerViewController.isAvailable }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if scannerUsable {
                    BarcodeScanner(isScanning: scanning && looking == nil && notFound == nil) { code in found(code) }
                        .ignoresSafeArea(edges: .horizontal)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.metering.unknown")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(!DataScannerViewController.isSupported ? "Dieses Gerät kann keine Codes live erkennen. Tipp den Code unten ein."
                             : camera == .notDetermined ? "Kamera wird angefragt …"
                             : "Kein Kamerazugriff. In den Einstellungen unter Tagwerk die Kamera erlauben, oder den Code unten eintippen.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemBackground))
                }
                if let looking {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Suche \(looking) bei Open Food Facts …").font(.subheadline)
                    }
                    .padding(20)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                }
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 12) {
                if let notFound {
                    Text("Code \(notFound) ist bei Open Food Facts nicht eingetragen.")
                        .font(.headline)
                    Text("Fotografier die Nährwerttabelle, dann liest Tagwerk die Werte und merkt sich das Produkt für den nächsten Scan.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Tabelle fotografieren") { path.append(.label(barcode: notFound)) }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.food)
                        Button("Suchen") { path.append(.search("")) }
                            .buttonStyle(.bordered)
                        Spacer()
                        Button("Nochmal") {
                            self.notFound = nil
                            scanning = true
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                    Text("Code ins Bild halten. Erkannte Produkte bleiben auf dem iPhone gespeichert.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("Code eintippen", text: $typed)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .focused($typing)
                        Button("Suchen") {
                            typing = false
                            found(typed)
                        }
                        .buttonStyle(.bordered)
                        .disabled(typed.filter(\.isNumber).count < 8)
                    }
                }
            }
            .padding(16)
            .background(.bar)
        }
        .navigationTitle("Barcode")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { CloseButton(close: close) }
        .sensoryFeedback(.success, trigger: looking)
        .task {
            // The live scanner only reports itself available once access is granted, so ask first.
            if camera == .notDetermined, DataScannerViewController.isSupported {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                camera = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    private func found(_ raw: String) {
        let code = raw.filter(\.isNumber)
        guard code.count >= 6, looking == nil else { return }
        error = nil
        if let item = store.cachedProduct(barcode: code) {
            path.append(.amount(item, grams: nil, note: nil))
            return
        }
        looking = code
        Task {
            do {
                if let item = try await OpenFoodFacts.product(code) {
                    store.saveFood(item)
                    looking = nil
                    path.append(.amount(item, grams: nil, note: nil))
                } else {
                    looking = nil
                    notFound = code
                }
            } catch {
                looking = nil
                self.error = error.localizedDescription
            }
        }
    }
}

/// VisionKit's live scanner (A12 and newer). Reports the first code it recognises.
struct BarcodeScanner: UIViewControllerRepresentable {
    var isScanning: Bool
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128, .itf14])],
                                           qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: true,
                                           isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if isScanning, !vc.isScanning {
            DispatchQueue.main.async { try? vc.startScanning() }
        } else if !isScanning, vc.isScanning {
            vc.stopScanning()
        }
    }

    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coordinator) {
        vc.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        private var last: (code: String, at: Date)?

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        private func report(_ items: [RecognizedItem]) {
            for item in items {
                guard case .barcode(let b) = item, let code = b.payloadStringValue, !code.isEmpty else { continue }
                if let last, last.code == code, Date().timeIntervalSince(last.at) < 3 { return }
                last = (code, Date())
                onCode(code)
                return
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            report(addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            last = nil
            report([item])
        }
    }
}

// MARK: - Search

struct FoodSearchView: View {
    @Environment(Store.self) private var store
    var initialQuery: String
    var pick: (FoodItem, Double?) -> Void
    var close: (() -> Void)?
    @State private var query = ""
    @State private var results: [FoodMatch] = []
    @State private var products: [FoodItem] = []
    @State private var searchingOFF = false
    @State private var offError: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                let recent = store.recentFoods.prefix(20)
                if !recent.isEmpty {
                    Section("Zuletzt gegessen") {
                        ForEach(Array(recent)) { r in
                            row(r.item, detail: r.lastGrams.map { "zuletzt \(NutritionFormat.amount($0)) \(r.item.unit)" }) { pick(r.item, r.lastGrams) }
                        }
                    }
                }
                Section {
                    Text("Tippe ein Lebensmittel, zum Beispiel „Haferflocken“, „Skyr“ oder „Döner“. Grundnahrungsmittel kommen aus dem Bundeslebensmittelschlüssel, Markenprodukte aus Open Food Facts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                if !results.isEmpty {
                    Section("Lebensmittel") {
                        ForEach(results) { m in
                            row(m.item, detail: m.item.source == .bls ? nil : m.item.source.label) { pick(m.item, nil) }
                        }
                    }
                }
                Section("Markenprodukte") {
                    if searchingOFF {
                        HStack {
                            ProgressView()
                            Text("Open Food Facts …").foregroundStyle(.secondary)
                        }
                    } else if !products.isEmpty {
                        ForEach(products) { p in
                            row(p, detail: p.brand) {
                                store.saveFood(p)
                                pick(p, nil)
                            }
                        }
                    } else {
                        Button {
                            searchOFF()
                        } label: {
                            Label("In Open Food Facts suchen", systemImage: "globe")
                        }
                        if let offError {
                            Text(offError).font(.footnote).foregroundStyle(.orange)
                        }
                    }
                }
                if results.isEmpty && products.isEmpty && !searchingOFF {
                    Section {
                        Text(store.foodIndexReady ? "Nichts Passendes in der Tabelle. Andere Schreibweise versuchen, Open Food Facts fragen oder von Hand eintragen." : "Lebensmitteltabelle wird geladen …")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Lebensmittel oder Produkt")
        .onSubmit(of: .search) { searchOFF() }
        .onChange(of: query) { _, q in schedule(q) }
        .onChange(of: store.foodIndexReady) { _, _ in schedule(query) }
        .onAppear {
            if query.isEmpty && !initialQuery.isEmpty { query = initialQuery }
        }
        .navigationTitle("Suchen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { CloseButton(close: close) }
    }

    private func schedule(_ q: String) {
        searchTask?.cancel()
        products = []
        offError = nil
        let text = q
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let index = FoodDatabase.shared.index else { return }
            let r = await Task.detached(priority: .userInitiated) { index.search(text, limit: 40) }.value
            guard !Task.isCancelled else { return }
            results = r
        }
    }

    private func searchOFF() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, !searchingOFF else { return }
        searchingOFF = true
        offError = nil
        Task {
            do {
                products = try await OpenFoodFacts.search(q)
                if products.isEmpty { offError = "Keine Produkte gefunden." }
            } catch {
                offError = error.localizedDescription
            }
            searchingOFF = false
        }
    }

    private func row(_ item: FoodItem, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Text("\(NutritionFormat.kcal(item.per100.kcal)) kcal")
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Amount

struct FoodAmountView: View {
    @Environment(Store.self) private var store
    let item: FoodItem
    let day: String
    var initialGrams: Double?
    var note: String?
    var editing: FoodEntry?
    var done: () -> Void

    @State private var gramsText = ""
    @State private var meal: Meal = .snack
    @State private var time = Date()
    @State private var loaded = false
    @FocusState private var focused: Bool

    private var grams: Double? {
        Double(gramsText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 && $0 <= 5000 ? $0 : nil }
    }

    struct Preset: Identifiable {
        var label: String
        var grams: Double
        var id: String { label }
    }

    private var presets: [Preset] {
        var out: [Preset] = []
        if let s = item.servingGrams { out.append(Preset(label: item.servingLabel.map { "Portion (\($0))" } ?? "Portion \(NutritionFormat.amount(s)) \(item.unit)", grams: s)) }
        if let p = item.pieceGrams, p != item.servingGrams { out.append(Preset(label: "1 Stück · \(NutritionFormat.amount(p)) \(item.unit)", grams: p)) }
        if let d = item.defaultGrams, d != item.servingGrams, d != item.pieceGrams { out.append(Preset(label: "üblich · \(NutritionFormat.amount(d)) \(item.unit)", grams: d)) }
        for g in [50.0, 100, 150, 200, 250] where !out.contains(where: { $0.grams == g }) { out.append(Preset(label: "\(Int(g)) \(item.unit)", grams: g)) }
        return out
    }

    var body: some View {
        let n = item.per100.scaled((grams ?? 0) / 100)
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.title3.weight(.semibold))
                    if let b = item.brand { Text(b).font(.subheadline).foregroundStyle(.secondary) }
                    Text("Pro 100 \(item.unit): \(NutritionFormat.kcal(item.per100.kcal)) kcal · Protein \(NutritionFormat.grams(item.per100.protein)) g · Fett \(NutritionFormat.grams(item.per100.fat)) g · Kohlenhydrate \(NutritionFormat.grams(item.per100.carbs)) g")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(item.source.label).font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
            Section("Menge") {
                HStack {
                    TextField("Menge", text: $gramsText)
                        .keyboardType(.decimalPad)
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .focused($focused)
                    Text(item.unit).font(.title3).foregroundStyle(.secondary)
                    Stepper("", onIncrement: { step(10) }, onDecrement: { step(-10) })
                        .labelsHidden()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presets) { p in
                            Button(p.label) {
                                gramsText = NutritionFormat.amount(p.grams)
                                focused = false
                            }
                            .buttonStyle(.bordered)
                            .tint(grams == p.grams ? Color.food : Color.secondary)
                            .font(.footnote)
                        }
                    }
                }
                if let note { Text("Aus deiner Eingabe: \(note)").font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                Picker("Mahlzeit", selection: $meal) {
                    ForEach(Meal.allCases) { m in Label(m.label, systemImage: m.symbol).tag(m) }
                }
                DatePicker("Uhrzeit", selection: $time, displayedComponents: .hourAndMinute)
            }
            Section("Für diese Menge") {
                LabeledContent("Energie", value: "\(NutritionFormat.kcal(n.kcal)) kcal")
                LabeledContent("Protein", value: "\(NutritionFormat.grams(n.protein)) g")
                LabeledContent("Fett", value: "\(NutritionFormat.grams(n.fat)) g")
                LabeledContent("Kohlenhydrate", value: "\(NutritionFormat.grams(n.carbs)) g")
                if let f = n.fiber { LabeledContent("Ballaststoffe", value: "\(NutritionFormat.grams(f)) g") }
            }
            if let editing {
                Section {
                    Button("Eintrag löschen", role: .destructive) {
                        store.removeFood(editing.id, on: day)
                        done()
                    }
                }
            }
        }
        .navigationTitle(editing == nil ? "Menge" : "Eintrag")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(editing == nil ? "Hinzufügen" : "Sichern") { save() }
                    .disabled(grams == nil)
            }
            if editing != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", action: done)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func step(_ d: Double) {
        let v = max(1, (grams ?? 0) + d)
        gramsText = NutritionFormat.amount(v)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let g = initialGrams ?? item.suggestedGrams
        gramsText = NutritionFormat.amount(g)
        if let editing {
            meal = editing.meal
            time = Self.date(day: day, time: editing.time)
        } else {
            let now = Date()
            time = day == store.today ? now : Self.date(day: day, time: "12:00")
            meal = Meal.guess(hour: Calendar.current.component(.hour, from: time))
        }
    }

    static func date(day: String, time: String) -> Date {
        let base = DayKey.date(day) ?? Date()
        let p = time.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(bySettingHour: p.first ?? 12, minute: p.count > 1 ? p[1] : 0, second: 0, of: base) ?? base
    }

    private func save() {
        guard let grams else { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        let hhmm = String(format: "%02d:%02d", c.hour ?? 12, c.minute ?? 0)
        if var e = editing {
            e.grams = grams
            e.meal = meal
            e.time = hhmm
            store.updateFood(e, on: day)
        } else {
            store.addFood([item.entry(grams: grams, meal: meal, time: hhmm, note: note)], on: day)
        }
        done()
    }
}

// MARK: - Description

struct DescribeMealView: View {
    @Environment(Store.self) private var store
    let day: String
    var initialText: String
    @Binding var path: [FoodRoute]
    var close: () -> Void

    struct Row: Identifiable {
        var id = UUID()
        var phrase: FoodPhrase
        var options: [FoodItem]
        var choice: Int
        var gramsText: String
        var include = true
        var item: FoodItem { options[choice] }
        var grams: Double? { Double(gramsText.replacingOccurrences(of: ",", with: ".")).flatMap { $0 > 0 ? $0 : nil } }
    }

    @State private var text = ""
    @State private var rows: [Row] = []
    @State private var unknown: [FoodPhrase] = []
    @State private var evaluated = false
    @State private var meal: Meal = .snack
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Zum Beispiel: 2 Eier, 1 Scheibe Vollkornbrot mit Butter, ein Glas Milch")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .frame(minHeight: 90)
                        .focused($focused)
                }
                Button {
                    evaluate()
                } label: {
                    Label("Auswerten", systemImage: "text.magnifyingglass")
                }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || !store.foodIndexReady)
            } header: {
                Text("Was hast du gegessen?")
            } footer: {
                Text("Wird auf dem iPhone gelesen, ohne KI-Dienst: Mengen wie „2“, „200 g“, „1 Scheibe“ oder „ein Glas“ und Lebensmittel aus dem Bundeslebensmittelschlüssel. Prüf die Grammzahlen, Portionen sind Durchschnittswerte.")
            }
            if evaluated {
                Section("Erkannt") {
                    if rows.isEmpty { Text("Nichts erkannt.").foregroundStyle(.secondary) }
                    ForEach($rows) { $row in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Toggle(isOn: $row.include) {
                                    Text("„\(row.phrase.raw)“").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Menu {
                                ForEach(row.options.indices, id: \.self) { i in
                                    Button(row.options[i].name) {
                                        row.choice = i
                                        if row.phrase.quantity == nil && row.phrase.unit == nil {
                                            row.gramsText = NutritionFormat.amount(FoodIndex.grams(for: row.phrase, item: row.options[i], alias: nil))
                                        }
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(row.item.name).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                TextField("g", text: $row.gramsText)
                                    .keyboardType(.decimalPad)
                                    .frame(width: 70)
                                    .textFieldStyle(.roundedBorder)
                                Text(row.item.unit).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(NutritionFormat.kcal(row.item.per100.kcal * (row.grams ?? 0) / 100)) kcal")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .opacity(row.include ? 1 : 0.45)
                    }
                }
                if !unknown.isEmpty {
                    Section("Nicht gefunden") {
                        ForEach(unknown, id: \.raw) { p in
                            Button {
                                path.append(.search(p.name))
                            } label: {
                                Label("„\(p.raw)“ suchen", systemImage: "magnifyingglass")
                            }
                        }
                    }
                }
                Section {
                    Picker("Mahlzeit", selection: $meal) {
                        ForEach(Meal.allCases) { m in Label(m.label, systemImage: m.symbol).tag(m) }
                    }
                }
            }
        }
        .navigationTitle("Beschreiben")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            CloseButton(close: close)
            ToolbarItem(placement: .confirmationAction) {
                Button("Hinzufügen") { add() }
                    .disabled(!rows.contains { $0.include && $0.grams != nil })
            }
        }
        .onAppear {
            if text.isEmpty && !initialText.isEmpty {
                text = initialText
                if store.foodIndexReady { evaluate() }
            } else if text.isEmpty {
                focused = true
            }
            meal = day == store.today ? Meal.guess(hour: Calendar.current.component(.hour, from: Date())) : .lunch
        }
        .onChange(of: store.foodIndexReady) { _, ready in
            if ready, !initialText.isEmpty, !evaluated { evaluate() }
        }
    }

    private func evaluate() {
        focused = false
        guard let index = FoodDatabase.shared.index else { return }
        let r = index.resolveAll(text)
        rows = r.found.map { f in
            Row(phrase: f.phrase, options: [f.item] + f.alternatives.prefix(7), choice: 0, gramsText: NutritionFormat.amount(f.grams))
        }
        unknown = r.unknown
        withAnimation(.smooth) { evaluated = true }
    }

    private func add() {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let time = day == store.today ? String(format: "%02d:%02d", c.hour ?? 12, c.minute ?? 0) : "12:00"
        let entries = rows.filter(\.include).compactMap { r in r.grams.map { r.item.entry(grams: $0, meal: meal, time: time, note: r.phrase.raw) } }
        store.addFood(entries.map { e in var x = e; x.source = .text; return x }, on: day)
        close()
    }
}

// MARK: - Photo

struct PhotoMealView: View {
    @Environment(Store.self) private var store
    @Binding var path: [FoodRoute]
    var close: () -> Void
    @State private var pickerItem: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var candidates: [FoodRecognition.Candidate] = []
    @State private var analysing = false
    @State private var showCamera = false
    @State private var note = ""

    var body: some View {
        Form {
            Section {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: 220)
                        .clipShape(.rect(cornerRadius: 16))
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
                HStack {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            showCamera = true
                        } label: {
                            Label("Foto aufnehmen", systemImage: "camera")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.food)
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Aus Fotos", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                }
            } footer: {
                Text("Die Bilderkennung läuft auf dem iPhone und schlägt nur vor, was zu sehen ist. Wie viel auf dem Teller liegt, kann sie nicht messen: die Menge legst du im nächsten Schritt fest.")
            }

            if analysing {
                Section { HStack { ProgressView(); Text("Wird erkannt …").foregroundStyle(.secondary) } }
            } else if image != nil {
                Section("Vorschläge") {
                    if candidates.isEmpty {
                        Text("Kein Lebensmittel sicher erkannt. Beschreib kurz, was es ist.").foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { c in
                        DisclosureGroup {
                            ForEach(c.items) { item in
                                Button {
                                    path.append(.amount(item, grams: nil, note: nil))
                                } label: {
                                    HStack {
                                        Text(item.name).foregroundStyle(.primary)
                                        Spacer()
                                        Text("\(NutritionFormat.kcal(item.per100.kcal)) kcal/100 g").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(c.label)
                                Spacer()
                                Text("\(Int((c.confidence * 100).rounded())) %").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section {
                TextField("Kurz beschreiben, z. B. „Teller Nudeln mit Tomatensoße“", text: $note, axis: .vertical)
                Button {
                    path.append(.describe(note))
                } label: {
                    Label("Beschreibung auswerten", systemImage: "text.magnifyingglass")
                }
                .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Beschreibung")
            }
        }
        .navigationTitle("Foto")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { CloseButton(close: close) }
        .sheet(isPresented: $showCamera) {
            CameraPicker { img in
                showCamera = false
                if let img { analyse(img) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { analyse(img) }
            }
        }
    }

    private func analyse(_ img: UIImage) {
        image = img
        analysing = true
        candidates = []
        Task {
            _ = await store.loadFoodDatabase()
            let c = await FoodRecognition.classify(img, index: FoodDatabase.shared.index)
            candidates = c
            analysing = false
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}

// MARK: - Nutrition label

struct LabelCaptureView: View {
    @Environment(Store.self) private var store
    var barcode: String?
    var pick: (FoodItem, Double?) -> Void
    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var reading = false
    @State private var lines: [String] = []
    @State private var failed = false
    @State private var form = NutritionForm()

    var body: some View {
        Form {
            Section {
                HStack {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            showCamera = true
                        } label: {
                            Label("Tabelle fotografieren", systemImage: "camera.viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.food)
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Aus Fotos", systemImage: "photo")
                    }
                    .buttonStyle(.bordered)
                }
                if reading { HStack { ProgressView(); Text("Texterkennung …").foregroundStyle(.secondary) } }
                if failed {
                    Text("Keine Nährwerttabelle erkannt. Gerade und nah fotografieren, ohne Spiegelungen, oder die Werte unten eintippen.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Die Texterkennung läuft auf dem iPhone. Gelesen wird die Spalte pro 100 g; bitte die Werte kurz gegenprüfen.")
            }
            NutritionFormSections(form: $form)
            if !lines.isEmpty {
                Section {
                    DisclosureGroup("Erkannter Text") {
                        ForEach(lines.indices, id: \.self) { i in Text(lines[i]).font(.caption.monospaced()) }
                    }
                }
            }
        }
        .navigationTitle("Nährwerttabelle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Weiter") {
                    guard let item = form.item(barcode: barcode, source: .label) else { return }
                    store.saveFood(item)
                    pick(item, nil)
                }
                .disabled(form.item(barcode: barcode, source: .label) == nil)
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { img in
                showCamera = false
                if let img { read(img) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { read(img) }
            }
        }
    }

    private func read(_ img: UIImage) {
        reading = true
        failed = false
        Task {
            let l = await FoodRecognition.textLines(in: img)
            lines = l
            reading = false
            if let r = NutritionLabelParser.parse(lines: l) {
                form.apply(r)
            } else {
                failed = true
            }
        }
    }
}

/// Values typed or read from a label, per 100 g or 100 ml.
struct NutritionForm {
    var name = ""
    var brand = ""
    var unit = "g"
    var kcal = ""
    var protein = ""
    var fat = ""
    var carbs = ""
    var fiber = ""
    var sugar = ""
    var salt = ""
    var serving = ""

    static func num(_ s: String) -> Double? { Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
    static func text(_ v: Double?) -> String { v.map { NutritionFormat.amount($0) } ?? "" }

    mutating func apply(_ r: NutritionLabelParser.Result) {
        unit = r.unit
        kcal = Self.text(r.per100.kcal)
        protein = Self.text(r.per100.protein)
        fat = Self.text(r.per100.fat)
        carbs = Self.text(r.per100.carbs)
        fiber = Self.text(r.per100.fiber)
        sugar = Self.text(r.per100.sugar)
        salt = Self.text(r.per100.salt)
    }

    func item(barcode: String?, source: FoodSource) -> FoodItem? {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let k = Self.num(kcal) else { return nil }
        let per100 = Nutrients(kcal: k, protein: Self.num(protein) ?? 0, fat: Self.num(fat) ?? 0, carbs: Self.num(carbs) ?? 0,
                               fiber: Self.num(fiber), sugar: Self.num(sugar), salt: Self.num(salt))
        guard per100.isPlausiblePer100 else { return nil }
        let b = brand.trimmingCharacters(in: .whitespaces)
        return FoodItem(id: barcode.map { "off:\($0)" } ?? "custom:\(UUID().uuidString.lowercased())", name: n, brand: b.isEmpty ? nil : b,
                        barcode: barcode, source: barcode == nil ? .custom : source, per100: per100, unit: unit,
                        servingGrams: Self.num(serving).flatMap { $0 > 0 ? $0 : nil })
    }
}

struct NutritionFormSections: View {
    @Binding var form: NutritionForm

    var body: some View {
        Section("Produkt") {
            TextField("Name", text: $form.name)
            TextField("Marke (optional)", text: $form.brand)
            Picker("Bezugsgröße", selection: $form.unit) {
                Text("pro 100 g").tag("g")
                Text("pro 100 ml").tag("ml")
            }
            .pickerStyle(.segmented)
            field("Portion (optional)", $form.serving, form.unit)
        }
        Section("Nährwerte pro 100 \(form.unit)") {
            field("Energie", $form.kcal, "kcal")
            field("Eiweiß", $form.protein, "g")
            field("Fett", $form.fat, "g")
            field("Kohlenhydrate", $form.carbs, "g")
            field("davon Zucker", $form.sugar, "g")
            field("Ballaststoffe", $form.fiber, "g")
            field("Salz", $form.salt, "g")
        }
    }

    private func field(_ title: String, _ text: Binding<String>, _ unit: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("0", text: text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Text(unit).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            }
        }
    }
}

// MARK: - Manual

struct ManualFoodView: View {
    @Environment(Store.self) private var store
    var barcode: String?
    var pick: (FoodItem, Double?) -> Void
    var close: (() -> Void)?
    @State private var form = NutritionForm()
    @State private var keep = true

    var body: some View {
        Form {
            NutritionFormSections(form: $form)
            Section {
                Toggle("Als eigenes Lebensmittel merken", isOn: $keep)
            } footer: {
                Text("Gemerkte Lebensmittel erscheinen in der Suche ganz oben.")
            }
        }
        .navigationTitle("Von Hand")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            CloseButton(close: close)
            ToolbarItem(placement: .confirmationAction) {
                Button("Weiter") {
                    guard let item = form.item(barcode: barcode, source: .manual) else { return }
                    if keep { store.saveFood(item) }
                    pick(item, Double(form.serving.replacingOccurrences(of: ",", with: ".")))
                }
                .disabled(form.item(barcode: barcode, source: .manual) == nil)
            }
        }
    }
}
