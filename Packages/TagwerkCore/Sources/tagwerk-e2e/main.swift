// End-to-end check against the real GitHub API, run in CI only:
//   push   – the "app" seals a batch with TagwerkCore and creates an inbox file
//   verify – after the plugin ran, the "app" reads and decodes the plugin's snapshot
import Foundation
import TagwerkCore

struct E2EError: Error, CustomStringConvertible {
    var description: String
}

func check(_ ok: Bool, _ what: String) throws {
    if !ok { throw E2EError(description: "Prüfung fehlgeschlagen: \(what)") }
    print("ok  \(what)")
}

let env = ProcessInfo.processInfo.environment
guard let token = env["E2E_TOKEN"], let repoFull = env["E2E_REPO"], let branch = env["E2E_BRANCH"], let date = env["E2E_DATE"] else {
    print("E2E_TOKEN, E2E_REPO, E2E_BRANCH und E2E_DATE setzen")
    exit(2)
}
let parts = repoFull.split(separator: "/").map(String.init)
let gh = GitHubClient(config: GitHubConfig(owner: parts[0], repo: parts[1], branch: branch), token: token)
let passphrase = "E2E – Passphrase äöü"
let journal = "Ende-zu-Ende: geschrieben mit TagwerkCore, übernommen vom Plugin."
let e2eFood = [
    FoodItem(id: "bls:C133000", name: "Hafer Flocken", source: .bls, per100: Nutrients(kcal: 348, protein: 13.5, fat: 6.7, carbs: 55.7, fiber: 10))
        .entry(grams: 80, meal: .breakfast, time: "07:40", id: "swift-e2e-food-1"),
    FoodItem(id: "off:4000000000001", name: "Skyr | Natur", brand: "Testmarke", barcode: "4000000000001", source: .barcode,
             per100: Nutrients(kcal: 64, protein: 11, fat: 0.2, carbs: 4), unit: "g", servingGrams: 150)
        .entry(grams: 250, meal: .lunch, time: "12:15", note: "Ein Becher", id: "swift-e2e-food-2"),
]
let e2eProfile: BodyProfile = {
    var p = BodyProfile()
    p.heightCm = 178
    p.birthYear = 1996
    p.bodyFat = 17.5
    p.targetWeight = 80
    p.checkFiber = true
    return p
}()

do {
    switch CommandLine.arguments.dropFirst().first ?? "" {
    case "push":
        let events = [
            EventFactory.dayPatch(date: date, habits: ["laufen": true], rating: .set("7.1"), ratingAI: .set("7.1"),
                                  ratingSource: .set(.ai), ratingReason: .set("E2E aus Swift."), weight: .set("71.4"), id: "swift-e2e-1"),
            EventFactory.journal(date: date, text: journal, baseHash: nil, id: "swift-e2e-2"),
            EventFactory.taskCreate(taskId: "swift-e2e-task", title: "E2E: Aufgabe aus Swift", created: date,
                                    date: DayKey.adding(2, to: date), wichtig: true, notes: "Notiz", id: "swift-e2e-3"),
            EventFactory.runAdd(runId: "swift-e2e-run", date: date, distanceKm: 5.034, seconds: 1633, source: "gps",
                                gpx: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Tagwerk\"></gpx>\n", id: "swift-e2e-4"),
            EventFactory.foodDay(date: date, entries: e2eFood, targets: DayTargets(kcal: 2700, protein: 140, fat: 80, carbs: 340, fiber: 30, tolerance: 10),
                                 met: false, id: "swift-e2e-5"),
            EventFactory.profileSet(e2eProfile, summary: "Ziel 2.700 kcal", id: "swift-e2e-6"),
        ]
        let plain = try EventFactory.batch(events, device: "CI")
        let sealed = try TagwerkCrypto.seal(plain, passphrase: passphrase, kind: .inbox, salt: TagwerkCrypto.randomBytes(16))
        try await gh.createFile(path: "inbox/\(date)T00-00-00-000Z_swift.tw", data: sealed, message: "e2e: Eingang aus Swift")
        print("ok  Inbox-Datei angelegt")
    case "verify":
        guard let file = try await gh.getFile(path: "snapshot.tw") else { throw E2EError(description: "snapshot.tw fehlt") }
        let plain = try TagwerkCrypto.open(file.data, passphrase: passphrase, kind: .snapshot)
        let snap = try JSONDecoder().decode(Snapshot.self, from: plain)
        try check(["swift-e2e-1", "swift-e2e-2", "swift-e2e-3"].allSatisfy(snap.applied.contains), "Plugin hat die drei Grund-Ereignisse quittiert")
        try check(snap.errors.isEmpty, "keine Fehler im Plugin")
        let day = snap.days.first { $0.date == date }
        try check(day?.rating == "7.1" && day?.ratingSource == .ai, "Rating und Quelle im Stand")
        try check(day?.habits["laufen"] == true, "Gewohnheit im Stand")
        try check(day?.weight == "71.4", "Gewicht im Stand")
        try check(day?.journal == journal, "Tagebuch im Stand")
        try check(day?.journalHash == TagwerkCrypto.journalHash(journal), "Tagebuch-Hash identisch in TypeScript und Swift")
        try check(snap.tasks.contains { $0.taskId == "swift-e2e-task" && $0.date == DayKey.adding(2, to: date) && $0.wichtig }, "Aufgabe im Stand")
        try check(["runs", "food", "profile"].allSatisfy(snap.features.contains), "Plugin meldet Läufe, Ernährung und Profil")
        try check(["swift-e2e-4", "swift-e2e-5", "swift-e2e-6"].allSatisfy(snap.applied.contains), "Lauf, Ernährung und Profil quittiert")
        let run = snap.runs.first { $0.runId == "swift-e2e-run" }
        try check(run?.date == date && run?.distanceKm == 5.03 && run?.seconds == 1633 && run?.hasRoute == true, "Lauf mit Route im Stand")
        let food = snap.foodDays.first { $0.date == date }
        try check(food?.entries == e2eFood, "Mahlzeiten unverändert zurück: \(String(describing: food?.entries))")
        try check(food?.targets?.kcal == 2700 && food?.met == false, "Ziele und Ergebnis im Stand")
        try check(snap.profile?.heightCm == 178 && snap.profile?.bodyFat == 17.5 && snap.profile?.checkFiber == true && snap.profile?.activity == .moderate,
                  "Körperprofil im Stand")
        print("ok  Ende-zu-Ende bestanden")
    default:
        print("Aufruf: tagwerk-e2e push|verify")
        exit(2)
    }
} catch {
    print("FEHLER: \(error)")
    exit(1)
}
