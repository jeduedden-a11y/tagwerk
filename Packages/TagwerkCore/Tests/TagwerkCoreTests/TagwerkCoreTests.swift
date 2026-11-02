import XCTest
@testable import TagwerkCore

final class CryptoTests: XCTestCase {
    func testOpensPluginEnvelopes() throws {
        let hello = try TagwerkCrypto.open(Data(Vectors.helloEnvelope.utf8), passphrase: Vectors.passphrase, kind: .inbox)
        XCTAssertEqual(String(data: hello, encoding: .utf8), "hello tagwerk")
        let umlaut = try TagwerkCrypto.open(Data(Vectors.umlautEnvelope.utf8), passphrase: Vectors.passphrase, kind: .inbox)
        XCTAssertEqual(String(data: umlaut, encoding: .utf8), Vectors.umlautPlaintext)
    }

    func testSealMatchesPluginByteForByte() throws {
        let salt = Data(base64Encoded: Vectors.saltBase64)!
        let iv = Data(base64Encoded: Vectors.ivBase64)!
        let mine = try TagwerkCrypto.seal(Data("hello tagwerk".utf8), passphrase: Vectors.passphrase, kind: .inbox,
                                         salt: salt, iterations: Vectors.iterations, iv: iv)
        let a = try JSONDecoder().decode(Envelope.self, from: mine)
        let b = try JSONDecoder().decode(Envelope.self, from: Data(Vectors.helloEnvelope.utf8))
        XCTAssertEqual(a.ct, b.ct)
        XCTAssertEqual(a.iv, b.iv)
        XCTAssertEqual(a.salt, b.salt)
        XCTAssertEqual(a.k, "inbox")
    }

    func testNFDPassphraseDerivesSameKey() throws {
        let nfd = Vectors.passphrase.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(nfd.utf8), Array(Vectors.passphrase.utf8))
        let hello = try TagwerkCrypto.open(Data(Vectors.helloEnvelope.utf8), passphrase: nfd, kind: .inbox)
        XCTAssertEqual(String(data: hello, encoding: .utf8), "hello tagwerk")
    }

    func testWrongPassphraseAndKind() {
        XCTAssertThrowsError(try TagwerkCrypto.open(Data(Vectors.helloEnvelope.utf8), passphrase: "falsch", kind: .inbox)) {
            XCTAssertEqual($0 as? TagwerkCryptoError, .decryptFailed)
        }
        XCTAssertThrowsError(try TagwerkCrypto.open(Data(Vectors.helloEnvelope.utf8), passphrase: Vectors.passphrase, kind: .snapshot))
    }

    func testRoundTripWithDefaultIterations() throws {
        let salt = TagwerkCrypto.randomBytes(16)
        let env = try TagwerkCrypto.seal(Data("x".utf8), passphrase: "p", kind: .snapshot, salt: salt)
        XCTAssertEqual(try TagwerkCrypto.open(env, passphrase: "p", kind: .snapshot), Data("x".utf8))
    }

    func testJournalHashesMatchPlugin() {
        for (text, hash) in Vectors.journalHashes {
            XCTAssertEqual(TagwerkCrypto.journalHash(text), hash, "for \(text.debugDescription)")
        }
    }
}

final class SnapshotTests: XCTestCase {
    func testDecodesPluginSnapshot() throws {
        let plain = try TagwerkCrypto.open(Data(Vectors.snapshotEnvelope.utf8), passphrase: Vectors.passphrase, kind: .snapshot)
        let snap = try JSONDecoder().decode(Snapshot.self, from: plain)
        XCTAssertEqual(snap.schema, 1)
        XCTAssertEqual(snap.habits.map(\.key), ["reading", "writing", "gym", "food", "laufen"])
        XCTAssertEqual(snap.habits.first(where: { $0.key == "gym" })?.toleranceDays, 3)
        XCTAssertEqual(snap.days.map(\.date), ["2026-11-01", "2026-10-30", "2026-08-18"])
        let today = snap.days[0]
        XCTAssertEqual(today.habits["laufen"], true)
        XCTAssertEqual(today.rating, "6.8")
        XCTAssertEqual(today.ratingAI, "7.1")
        XCTAssertEqual(today.ratingSource, .manual)
        XCTAssertEqual(today.journal, "5 km gelaufen.\nDanach Mathe.")
        XCTAssertEqual(today.journalHash, TagwerkCrypto.journalHash("5 km gelaufen.\nDanach Mathe."))
        XCTAssertEqual(snap.days[1].note, "Abends Kino.")
        XCTAssertEqual(snap.days[1].rating, "6.3")
        XCTAssertNil(snap.days[1].weight)
        XCTAssertNil(snap.days[2].note)
        XCTAssertFalse(snap.days[2].hasText)
        XCTAssertTrue(snap.days[1].hasText)
        XCTAssertEqual(snap.tasks.count, 2)
        XCTAssertEqual(snap.tasks.first?.title, "Reisepass")
        XCTAssertEqual(snap.tasks.first?.notes, "Beim Amt nachfragen.")
        XCTAssertEqual(snap.appointments.first?.startTime, "13:30")
        XCTAssertEqual(snap.appointments.first?.location, "Raum 204")
        XCTAssertEqual(snap.applied, ["v-0001-0000", "v-0002-0000"])
        XCTAssertEqual(snap.errors.first?.message, "Aufgabe nicht gefunden")
    }
}

final class EventTests: XCTestCase {
    private func object(_ e: OutgoingEvent) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: e.json) as? [String: Any])
    }

    func testDayPatchEncodesOnlyChangedFieldsAndExplicitNull() throws {
        let e = EventFactory.dayPatch(date: "2026-11-01", habits: ["gym": true], rating: .set("6.8"), ratingSource: .set(.ai), weight: .clear,
                                      now: Date(timeIntervalSince1970: 0), id: "evt-1")
        let o = try object(e)
        XCTAssertEqual(o["type"] as? String, "day.patch")
        XCTAssertEqual(o["id"] as? String, "evt-1")
        XCTAssertEqual((o["habits"] as? [String: Bool])?["gym"], true)
        XCTAssertEqual(o["rating"] as? String, "6.8")
        XCTAssertEqual(o["ratingSource"] as? String, "ai")
        XCTAssertTrue(o["weight"] is NSNull)
        XCTAssertNil(o["ratingAI"])
        XCTAssertTrue(String(data: e.json, encoding: .utf8)!.contains("\"gym\":true"))
    }

    func testBatchWrapsEvents() throws {
        let a = EventFactory.taskCreate(taskId: "t1", title: "Mathe", created: "2026-11-01", date: nil, wichtig: true, notes: nil)
        let b = EventFactory.taskPatch(taskId: nil, path: "01 Leben/Tasks/Reisepass.md", completed: true, date: .clear)
        let data = try EventFactory.batch([a, b], device: "iPhone")
        let o = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(o["schema"] as? Int, 1)
        let events = try XCTUnwrap(o["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events[0]["date"] is NSNull)
        XCTAssertEqual(events[1]["path"] as? String, "01 Leben/Tasks/Reisepass.md")
        XCTAssertTrue(events[1]["date"] is NSNull)
        XCTAssertEqual(events[1]["completed"] as? Bool, true)
    }
}

final class MIMETests: XCTestCase {
    func testQuotedPrintableAndEncodedWords() {
        let raw = """
        From: =?UTF-8?Q?J=C3=BCrgen_M=C3=BCller?= <j@schule.example>\r
        Subject: =?UTF-8?B?RWlubGFkdW5nIHp1ciBUZWFtc2l0enVuZw==?=\r
        Date: Sun, 1 Nov 2026 14:03:00 +0100\r
        Content-Type: text/plain; charset="utf-8"\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Die Sitzung ist am 12.11. um 13:30 Uhr in Raum 2=\r
        04. Gr=C3=BC=C3=9Fe\r
        """
        let m = MIME.parse(Data(raw.utf8))
        XCTAssertEqual(m.from, "Jürgen Müller <j@schule.example>")
        XCTAssertEqual(m.subject, "Einladung zur Teamsitzung")
        XCTAssertNotNil(m.date)
        XCTAssertTrue(m.text.contains("Raum 204."), m.text)
        XCTAssertTrue(m.text.contains("Grüße"), m.text)
    }

    func testMultipartAlternativePrefersPlainAndDecodesLatin1() {
        let raw = """
        Subject: =?ISO-8859-1?Q?Pr=FCfung?= =?ISO-8859-1?Q?_am_Montag?=\r
        Content-Type: multipart/alternative; boundary="b1"\r
        \r
        --b1\r
        Content-Type: text/plain; charset=iso-8859-1\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        Pr=FCfung am 3. Dezember\r
        --b1\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <p>HTML</p>\r
        --b1--\r
        """
        let m = MIME.parse(Data(raw.utf8))
        XCTAssertEqual(m.subject, "Prüfung am Montag")
        XCTAssertEqual(m.text, "Prüfung am 3. Dezember")
    }

    func testHTMLOnlyBase64InMixed() {
        let html = "<html><head><style>p{}</style></head><body><p>Abgabe bis&nbsp;<b>20.11.2026</b></p><br>Gr&uuml;&szlig;e</body></html>"
        let b64 = Data(html.utf8).base64EncodedString()
        let raw = """
        Subject: Abgabe\r
        Content-Type: multipart/mixed; boundary=XYZ\r
        \r
        --XYZ\r
        Content-Type: text/html; charset=utf-8\r
        Content-Transfer-Encoding: base64\r
        \r
        \(b64.prefix(40))\r
        \(b64.dropFirst(40))\r
        --XYZ\r
        Content-Type: application/pdf\r
        Content-Disposition: attachment; filename="a.pdf"\r
        \r
        JVBERi0=\r
        --XYZ--\r
        """
        let m = MIME.parse(Data(raw.utf8))
        XCTAssertTrue(m.text.contains("Abgabe bis 20.11.2026"), m.text)
        XCTAssertTrue(m.text.contains("Grüße"), m.text)
        XCTAssertFalse(m.text.contains("p{}"))
    }
}

final class DateExtractorTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }()

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testGermanFormatsWithTimes() {
        let text = """
        Hallo zusammen,
        die nächste Teamsitzung findet am 12.11.2026 von 13:30 bis 15:00 Uhr statt.
        Abgabe der Anträge bis 20. November.
        Am Fr., 30. Okt. 2026 um 10:00 schrieb Frau B.:
        > Termin war am 28.10.
        """
        let c = DateExtractor.candidates(in: text, reference: date(2026, 11, 1), now: date(2026, 11, 1), calendar: cal)
        XCTAssertEqual(c.map(\.day), ["2026-11-12", "2026-11-20"], c.map { "\($0.day) [\($0.matchedText)] \($0.context)" }.joined(separator: " || "))
        XCTAssertEqual(c.first?.startTime, "13:30")
        XCTAssertEqual(c.first?.endTime, "15:00")
        XCTAssertNil(c.last?.startTime)
    }

    func testYearRolloverAndRelative() {
        let text = "Elternabend am 14.1. um 19 Uhr. Rückmeldung bitte morgen."
        let c = DateExtractor.candidates(in: text, reference: date(2026, 12, 20), now: date(2026, 12, 20), calendar: cal)
        XCTAssertTrue(c.contains { $0.day == "2027-01-14" && $0.startTime == "19:00" }, "\(c)")
        XCTAssertTrue(c.contains { $0.day == "2026-12-21" }, "\(c)")
    }

    func testRejectsImpossibleAndVersionNumbers() {
        let c = DateExtractor.candidates(in: "Version 1.2.3 und der 31.02. gibt es nicht.", reference: date(2026, 1, 10), now: date(2026, 1, 10), calendar: cal)
        XCTAssertFalse(c.contains { $0.day.hasSuffix("-02-31") })
        XCTAssertFalse(c.contains { $0.day == "2026-02-01" })
    }
}

final class AnalyticsTests: XCTestCase {
    func testWeekdayAndWeekStart() {
        XCTAssertEqual(DayKey.isoWeekday("2026-11-01"), 7) // Sunday
        XCTAssertEqual(DayKey.isoWeekday("2026-11-02"), 1)
        XCTAssertEqual(DayKey.weekStart("2026-11-01"), "2026-10-26")
        XCTAssertEqual(DayKey.longGerman("2026-11-01"), "Sonntag, 1. November")
        XCTAssertEqual(DayKey.adding(1, to: "2026-12-31"), "2027-01-01")
    }

    func testStreaksLikeDashboard() {
        // gym: gap <= 3 continues, alive if last <= 2 days ago
        let gym = Streaks.compute(done: ["2026-10-10", "2026-10-12", "2026-10-20", "2026-10-24", "2026-10-27", "2026-10-30"],
                                  today: "2026-11-01", tolerance: 3, alive: 2)
        XCTAssertEqual(gym.current, 3) // 10-24, 10-27, 10-30; the gap of 4 before 10-24 ends the chain
        XCTAssertEqual(gym.longest, 3)
        XCTAssertEqual(Streaks.compute(done: ["2026-10-28"], today: "2026-11-01", tolerance: 3, alive: 2).current, 0)
        // reading: strict daily
        let reading = Streaks.compute(done: ["2026-10-29", "2026-10-30", "2026-10-31"], today: "2026-11-01", tolerance: 1, alive: 1)
        XCTAssertEqual(reading.current, 3)
        let stale = Streaks.compute(done: ["2026-10-29"], today: "2026-11-01", tolerance: 1, alive: 1)
        XCTAssertEqual(stale.current, 0)
        XCTAssertEqual(Streaks.weekCount(done: ["2026-10-26", "2026-11-01", "2026-10-25"], today: "2026-11-01"), 2)
    }

    func testQuadrants() {
        XCTAssertEqual(Quadrant.of(date: "2026-11-04", wichtig: true, completed: false, today: "2026-11-01"), .urgentImportant)
        XCTAssertEqual(Quadrant.of(date: "2026-11-20", wichtig: true, completed: false, today: "2026-11-01"), .important)
        XCTAssertEqual(Quadrant.of(date: "2026-10-20", wichtig: false, completed: false, today: "2026-11-01"), .urgent)
        XCTAssertEqual(Quadrant.of(date: nil, wichtig: true, completed: false, today: "2026-11-01"), .backlog)
        XCTAssertEqual(Quadrant.of(date: nil, wichtig: true, completed: true, today: "2026-11-01"), .done)
    }

    func testRatingColorsMatchVaultChart() {
        XCTAssertEqual(RatingScale.color(for: 0), RGB(220, 38, 38))
        XCTAssertEqual(RatingScale.color(for: 8.75), RGB(22, 163, 74))
        XCTAssertEqual(RatingScale.color(for: 9.0), RGB(55, 138, 221))
        XCTAssertEqual(RatingScale.color(for: 9.8), RGB(127, 63, 191))
        XCTAssertEqual(RatingScale.format(6.849), "6.8")
    }

    func testFormulaFit() throws {
        var days: [(habits: [String: Bool], rating: Double)] = []
        for i in 0..<30 {
            let run = i % 3 == 0
            days.append((["laufen": run, "food": true], run ? 8.0 : 6.0))
        }
        let f = try XCTUnwrap(HabitFormula.fit(days: days, keys: ["laufen", "food"]))
        XCTAssertGreaterThan(f.predict(["laufen": true, "food": true]), f.predict(["laufen": false, "food": true]) + 1.0)
    }
}
