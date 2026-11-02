import Foundation
import TagwerkCore

/// Sample content for simulator screenshots (launch argument -TWDemo YES). Never syncs.
enum DemoData {
    static func state(now: Date = Date()) -> AppState {
        var s = AppState()
        let today = DayKey.today(now)
        let ratings: [Double] = [6.3, 6.1, 5.3, 5.1, 7.3, 5.3, 4.3, 5.2, 5.3, 4.8, 6.9, 7.1, 7.6, 8.2, 6.4, 5.9, 7.2, 7.8, 8.7, 6.5,
                                 7.1, 6.2, 5.4, 6.7, 7.9, 8.4, 9.1, 6.9, 7.2, 6.1]
        var rng = SplitMix64(seed: 7)
        for (i, r) in ratings.enumerated() {
            let key = DayKey.adding(-(i + 1), to: today)
            var d = DayEntry(date: key)
            d.rating = RatingScale.format(r)
            d.ratingSource = .manual
            d.habits = [
                "reading": i % 3 == 0,
                "writing": i % 4 == 1,
                "gym": i % 2 == 0 || i % 7 == 3,
                "food": i % 9 != 4,
                "laufen": i % 6 == 2,
            ]
            if i % 2 == 0 { d.weight = String(format: "%.1f", 71.9 - Double(i) * 0.02 + Double(Int.random(in: -3...3, using: &rng)) / 10) }
            s.days[key] = d
        }
        var t = DayEntry(date: today)
        t.habits = ["reading": false, "writing": true, "gym": false, "food": false, "laufen": true]
        t.autoHabits = ["laufen"]
        t.journal = "Morgens 5 km am Fluss gelaufen, danach drei Aufgaben aus dem Übungspaket geschafft. Nachmittags Teamtreffen, etwas zäh, aber der Entwurf steht."
        t.rating = "7.4"
        t.ratingAI = "7.4"
        t.ratingSource = .ai
        t.ratingReason = "Du warst laufen und hast Mathe geschafft; das zähe Treffen drückt etwas, insgesamt über deinem Schnitt von 6,6."
        t.aiProvider = "Claude (claude-haiku-5-5)"
        t.weight = "71.6"
        s.days[today] = t

        func task(_ title: String, _ dateOffset: Int?, _ wichtig: Bool, _ done: Bool = false) -> TaskItem {
            TaskItem(id: UUID().uuidString, taskId: nil, path: "01 Leben/Tasks/\(title).md", title: title, created: DayKey.adding(-10, to: today),
                     date: dateOffset.map { DayKey.adding($0, to: today) }, completed: done, wichtig: wichtig, notes: nil)
        }
        s.tasks = [
            task("Reise bezahlen", 2, true),
            task("Präsentation vorbereiten", 4, true),
            task("Bewerbung nachfassen", 12, true),
            task("Fahrradschloss kaufen", 1, false),
            task("Buch zurückgeben", -2, false),
            task("Leseliste sortieren", nil, false),
            task("Reisepass", -5, true, true),
        ]
        s.suggestions = [
            Suggestion(id: "demo-1", mailbox: "Schule", subject: "Einladung zur Teamsitzung", from: "Teamleitung", receivedAt: now.addingTimeInterval(-3600 * 5),
                       title: "Teamsitzung", date: DayKey.adding(11, to: today), startTime: "13:30", endTime: "15:00", allDay: false,
                       location: "Raum 204", confidence: 0.92, context: "die nächste Teamsitzung findet am Donnerstag von 13:30 bis 15:00 Uhr in Raum 204 statt."),
            Suggestion(id: "demo-2", mailbox: "Gmail", subject: "Kursprogramm: Termine im Wintersemester", from: "Volkshochschule", receivedAt: now.addingTimeInterval(-86_400),
                       title: "Frist: Prüfungsanmeldung", date: DayKey.adding(19, to: today), startTime: nil, endTime: nil, allDay: true,
                       location: nil, confidence: 0.81, context: "Die Anmeldung zu den Prüfungen ist bis zum genannten Datum im Portal möglich."),
        ]
        s.appointments = [
            Appointment(id: "demo-a1", title: "Teamfrühstück", date: DayKey.adding(6, to: today), startTime: "16:00", endTime: "19:00", allDay: false,
                        location: "Kantine", mailbox: "Schule", path: "01 Leben/Termine/Teamfrühstück.md"),
        ]
        // Fitness: synthetic runs, a body profile and today's meals
        let runPlan: [(Int, Double, Int)] = [(-270, 3.0, 1050), (-262, 4.1, 1420), (-250, 3.2, 1100), (-238, 5.0, 1710), (-221, 6.2, 2140),
                                              (-205, 4.0, 1300), (-190, 7.5, 2620), (-170, 5.1, 1690), (-150, 8.4, 2890), (-128, 3.0, 940),
                                              (-110, 10.0, 3420), (-96, 6.0, 1960), (-80, 12.1, 4160), (-65, 5.0, 1560), (-50, 15.0, 5050),
                                              (-36, 7.0, 2240), (-22, 10.5, 3400), (-12, 4.2, 1260), (-5, 8.0, 2510), (0, 5.02, 1633)]
        s.runs = runPlan.map { off, km, sec in
            let key = DayKey.adding(off, to: today)
            return RunRecord(id: "demo-run-\(off)", runId: nil, path: "01 Leben/Fittness/Laufen/Laufzeiten/\(key).md", date: key,
                             distanceKm: km, seconds: sec, source: off == 0 ? "gps" : nil, hasRoute: off == 0)
        }
        var profile = BodyProfile()
        profile.heightCm = 178
        profile.birthYear = 1996
        profile.bodyFat = 18
        profile.targetWeight = 75
        profile.activity = .moderate
        s.profile = profile
        let oats = FoodItem(id: "bls:demo-oats", name: "Hafer Flocken", source: .bls, per100: Nutrients(kcal: 348, protein: 13.5, fat: 6.7, carbs: 55.7, fiber: 10), defaultGrams: 50)
        let skyr = FoodItem(id: "off:demo-skyr", name: "Skyr Natur", brand: "Testmarke", barcode: "4000000000001", source: .barcode,
                            per100: Nutrients(kcal: 63, protein: 11, fat: 0.2, carbs: 4), servingGrams: 150)
        let banana = FoodItem(id: "bls:demo-banana", name: "Banane roh", source: .bls, per100: Nutrients(kcal: 79, protein: 1.3, fat: 0.4, carbs: 15.9, fiber: 2), pieceGrams: 120)
        let chicken = FoodItem(id: "bls:demo-chicken", name: "Hähnchen Brust, ohne Haut, gebraten", source: .bls, per100: Nutrients(kcal: 136, protein: 29.3, fat: 2.1, carbs: 0))
        let rice = FoodItem(id: "bls:demo-rice", name: "Reis gekocht", source: .bls, per100: Nutrients(kcal: 112, protein: 2.5, fat: 0.2, carbs: 24.6, fiber: 0.8))
        let peanut = FoodItem(id: "bls:demo-peanut", name: "Erdnussmus", source: .bls, per100: Nutrients(kcal: 620, protein: 25, fat: 50, carbs: 12, fiber: 7))
        var food = FoodDayState(date: today)
        food.entries = [
            oats.entry(grams: 90, meal: .breakfast, time: "07:20", id: "demo-f1"),
            skyr.entry(grams: 250, meal: .breakfast, time: "07:20", id: "demo-f2"),
            banana.entry(grams: 120, meal: .snack, time: "10:15", id: "demo-f3"),
            chicken.entry(grams: 180, meal: .lunch, time: "13:05", id: "demo-f4"),
            rice.entry(grams: 250, meal: .lunch, time: "13:05", id: "demo-f5"),
            peanut.entry(grams: 30, meal: .snack, time: "16:40", id: "demo-f6"),
        ]
        s.food[today] = food
        s.foodLibrary = [oats, skyr, banana, chicken, rice, peanut].enumerated().map { i, item in
            LibraryItem(item: item, uses: 6 - i, lastUsed: now.addingTimeInterval(Double(-i) * 3600), lastGrams: food.entries[i].grams)
        }
        s.bridgeFeatures = ["runs", "food", "profile", "planner", "wiki"]
        s.pluginVersion = "1.2.0"
        planner(&s, today: today)

        s.settings.github = GitHubConfig(owner: "demo", repo: "tagwerk-daten")
        s.settings.userName = "Alex"
        s.lastPush = now.addingTimeInterval(-240)
        s.lastPull = now.addingTimeInterval(-240)
        s.lastIngestAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-600))
        s.lastMailCheck = now.addingTimeInterval(-1800)
        return s
    }
}

/// Fixed seed so that every screenshot launch shows the same demo weights.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Planner and notes (synthetic)

extension DemoData {
    /// Two weeks of an invented timetable, a weekly lecture, an exam, own marks and messages.
    static func planner(_ s: inout AppState, today: String) {
        let monday = Planner.monday(of: today)
        // (weekday, start, end, short, long, teacher, room)
        let plan: [(Int, String, String, String, String, String, String)] = [
            (1, "07:50", "09:20", "E", "Englisch", "Mül", "A101"), (1, "09:40", "11:10", "M", "Mathematik", "Sch", "B204"),
            (1, "11:30", "13:00", "G", "Geschichte", "Ber", "A112"), (1, "13:45", "15:15", "ETH", "Ethik", "Kra", "C003"),
            (2, "07:50", "09:20", "PH", "Physik", "Lan", "N201"), (2, "09:40", "11:10", "D", "Deutsch", "Wei", "A105"),
            (2, "11:30", "13:00", "M", "Mathematik", "Sch", "B204"),
            (3, "07:50", "09:20", "CH", "Chemie", "Ott", "N104"), (3, "09:40", "11:10", "G", "Geschichte", "Ber", "A112"),
            (3, "11:30", "13:00", "E", "Englisch", "Mül", "A101"), (3, "13:45", "15:15", "SP", "Sport", "Hof", "Halle 2"),
            (4, "07:50", "09:20", "M", "Mathematik", "Sch", "B204"), (4, "09:40", "11:10", "PH", "Physik", "Lan", "N201"),
            (4, "13:45", "15:15", "CH", "Chemie", "Ott", "N104"),
            (5, "07:50", "09:20", "D", "Deutsch", "Wei", "A105"), (5, "09:40", "11:10", "G", "Geschichte", "Ber", "A112"),
        ]
        for week in 0..<2 {
            let base = Planner.adding(7 * week, to: monday)
            var list: [UntisPeriod] = []
            for p in plan {
                let day = Planner.adding(p.0 - 1, to: base)
                var period = UntisPeriod(date: day, start: p.1, end: p.2, subject: p.3, subjectLong: p.4, teacher: p.5, room: p.6)
                if week == 0 && p.0 == 2 && p.3 == "PH" {
                    period.status = .cancelled
                    period.info = "Entfall wegen Exkursion"
                }
                if week == 0 && p.0 == 5 && p.3 == "G" {
                    period.roomOld = "A112"
                    period.room = "A008"
                    period.status = .changed
                }
                if week == 0 && p.0 == 4 && p.3 == "CH" {
                    period.kind = .exam
                    period.info = "Klausur: Elektrochemie"
                }
                list.append(period)
            }
            s.untis.setWeek(base, list, today: today)
        }
        s.untis.school = UntisSchoolData(holidays: [UntisHoliday(name: "Weihnachtsferien", start: "2026-12-21", end: "2027-01-09")],
                                         units: [UntisTimeUnit(number: 1, start: "07:50", end: "08:35"), UntisTimeUnit(number: 2, start: "08:35", end: "09:20"),
                                                 UntisTimeUnit(number: 3, start: "09:40", end: "10:25"), UntisTimeUnit(number: 4, start: "10:25", end: "11:10"),
                                                 UntisTimeUnit(number: 5, start: "11:30", end: "12:15"), UntisTimeUnit(number: 6, start: "12:15", end: "13:00"),
                                                 UntisTimeUnit(number: 7, start: "13:45", end: "14:30"), UntisTimeUnit(number: 8, start: "14:30", end: "15:15")],
                                         userName: "Alex")
        s.untis.lastFetch = Date().addingTimeInterval(-300)
        s.untis.messages = [
            UntisMessage(id: 3, subject: "Exkursion Physik", preview: "Am Dienstag entfällt Physik, wir treffen uns um 8 Uhr am Bahnhof.", sender: "Lan",
                         sent: UntisDates.formatter.string(from: Date().addingTimeInterval(-7200)), read: false, attachments: false),
            UntisMessage(id: 2, subject: "Projektwoche", preview: "Die Anmeldung für die Projektwoche läuft bis Freitag.", sender: "Sekretariat",
                         sent: UntisDates.formatter.string(from: Date().addingTimeInterval(-86_400 * 2)), read: true, attachments: true),
        ]
        var lecture = Appointment(id: "demo-uni", title: "Analysis I", date: monday, startTime: "10:15", endTime: "11:45", allDay: false, location: "Hörsaal 1",
                                  path: "01 Leben/Termine/Analysis I.md")
        lecture.category = "uni"
        lecture.recur = Recurrence(days: [1, 3], until: Planner.adding(100, to: monday))
        var tutorial = Appointment(id: "demo-tut", title: "Übung Analysis", date: Planner.adding(3, to: monday), startTime: "16:00", endTime: "17:30",
                                   allDay: false, location: "Seminarraum 3", path: "01 Leben/Termine/Übung Analysis.md")
        tutorial.category = "uni"
        tutorial.recur = Recurrence(days: [4], until: Planner.adding(100, to: monday))
        var exam = Appointment(id: "demo-kl", title: "Klausur", date: Planner.adding(9, to: monday), startTime: "09:40", endTime: "11:10", allDay: false,
                               location: "B204", path: "01 Leben/Termine/Klausur Mathematik.md")
        exam.category = "klausur"
        exam.subject = "Mathematik"
        exam.notes = "Integralrechnung, Kurvenscharen"
        s.appointments += [lecture, tutorial, exam]
        let englishKey = "u:\(Planner.adding(2, to: monday)):11:30:E"
        s.schoolOverrides[englishKey] = SchoolOverride(key: englishKey, date: Planner.adding(2, to: monday), start: "11:30", end: "13:00", subject: "Englisch",
                                                       title: "Englisch", state: "abwesend", reason: "Arzt")
    }

    /// A few invented notes for screenshots of the notes tab.
    static let wiki: [String: String] = [
        "Mathematik/Analysis/Ableitung.md": """
        ---
        tags:
          - mathematik
          - analysis
        ---
        # Ableitung

        > [!important] Definition
        > Die Ableitung von $f$ an der Stelle $x_0$ ist der Grenzwert des Differenzenquotienten:
        > $$f'(x_0) = \\lim_{h \\to 0} \\frac{f(x_0+h)-f(x_0)}{h}$$

        Geometrisch ist $f'(x_0)$ die Steigung der [[Tangente]] im Punkt $(x_0, f(x_0))$.

        > [!tip] Merksatz
        > Erst ableiten, dann einsetzen. Für Potenzen gilt $\\left(x^n\\right)' = n\\,x^{n-1}$.

        ## Regeln

        | Regel | Formel |
        | --- | --- |
        | Produktregel | $(uv)' = u'v + uv'$ |
        | Kettenregel | $(u \\circ v)' = (u' \\circ v)\\cdot v'$ |

        > [!question]- Typische Fehlerquelle
        > Bei der Kettenregel die innere Ableitung vergessen.

        Siehe auch [[Integral|Integralrechnung]].
        """,
        "Mathematik/Analysis/Integral.md": "# Integral\n\nDas bestimmte Integral misst die orientierte Fläche: $\\int_a^b f(x)\\,dx = F(b) - F(a)$.\n",
        "Mathematik/Analysis/Tangente.md": "# Tangente\n\nGerade durch $(x_0, f(x_0))$ mit Steigung $f'(x_0)$.\n",
        "Physik/Quantenphysik/Photoeffekt.md": "# Photoeffekt\n\n> [!info] Einsteins Gleichung\n> $E_{kin} = h f - W_A$\n",
        "Chemie/Elektrochemie/Redoxreaktionen.md": "# Redoxreaktionen\n\nOxidation ist Elektronenabgabe, Reduktion ist Elektronenaufnahme.\n",
        "Geschichte/Weimarer Republik.md": "# Weimarer Republik\n\n> [!example] Quelle\n> Verfassung vom 11. August 1919.\n",
        "TMUA/Logik und Beweise.md": "# Logik und Beweise\n\n- [x] Kontraposition\n- [ ] Widerspruchsbeweis\n",
    ]
}

