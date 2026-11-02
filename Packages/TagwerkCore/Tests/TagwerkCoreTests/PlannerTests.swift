import XCTest
@testable import TagwerkCore

final class PlannerProtocolTests: XCTestCase {
    func snapshot() throws -> Snapshot {
        let plain = try TagwerkCrypto.open(Data(Vectors.snapshotEnvelope.utf8), passphrase: Vectors.passphrase, kind: .snapshot)
        return try JSONDecoder().decode(Snapshot.self, from: plain)
    }

    func testSnapshotCarriesPlannerData() throws {
        let snap = try snapshot()
        XCTAssertTrue(snap.features.contains("planner"))
        XCTAssertTrue(snap.features.contains("wiki"))
        let uni = try XCTUnwrap(snap.appointments.first { $0.apptId == "appt-uni-v" })
        XCTAssertEqual(uni.recur, Recurrence(days: [1, 3], until: "2027-02-12"))
        XCTAssertEqual(uni.category, "uni")
        XCTAssertEqual(uni.location, "H I")
        let exam = try XCTUnwrap(snap.appointments.first { $0.apptId == "appt-kl-v" })
        XCTAssertEqual(exam.subject, "Chemie")
        XCTAssertEqual(exam.notes, "Redox")
        XCTAssertNil(exam.recur)
        let mark = try XCTUnwrap(snap.schoolOverrides.first)
        XCTAssertEqual(mark.key, "u:2026-11-04:07:50:E")
        XCTAssertEqual(mark.state, "abwesend")
        XCTAssertEqual(mark.reason, "Uni")
    }

    func testPlannerEventsAndFeatures() throws {
        let now = Date(timeIntervalSince1970: 1_793_620_000)
        let plain = EventFactory.appointmentAdd(apptId: "a1", title: "Zahnarzt", date: "2026-11-03", startTime: "15:00", endTime: nil, allDay: false,
                                                location: nil, notes: nil, mailbox: nil, from: nil, subject: nil, receivedAt: nil, now: now, id: "e1")
        XCTAssertNil(plain.requiredFeature)
        let lecture = EventFactory.appointmentAdd(apptId: "a2", title: "Analysis I", date: "2026-11-02", startTime: "10:15", endTime: "11:45", allDay: false,
                                                  location: "H I", notes: nil, mailbox: nil, from: nil, subject: nil, receivedAt: nil,
                                                  category: "uni", recur: Recurrence(days: [1, 3], until: "2027-02-12"), now: now, id: "e2")
        XCTAssertEqual(lecture.requiredFeature, "planner")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: lecture.json) as? [String: Any])
        XCTAssertEqual((obj["recur"] as? [String: Any])?["until"] as? String, "2027-02-12")
        XCTAssertEqual(obj["category"] as? String, "uni")

        let patch = EventFactory.appointmentPatch(apptId: "a2", path: nil, startTime: .set("10:30"), location: .clear, recur: .clear, now: now, id: "e3")
        let p = try XCTUnwrap(try JSONSerialization.jsonObject(with: patch.json) as? [String: Any])
        XCTAssertEqual(p["type"] as? String, "appointment.patch")
        XCTAssertEqual(p["startTime"] as? String, "10:30")
        XCTAssertTrue(p["location"] is NSNull)
        XCTAssertTrue(p["recur"] is NSNull)
        XCTAssertNil(p["deleted"])
        XCTAssertEqual(patch.requiredFeature, "planner")

        let mark = EventFactory.schoolOverride(key: "u:2026-11-04:07:50:E", date: "2026-11-04", start: "07:50", end: "09:20", subject: "Englisch",
                                               title: nil, state: "abwesend", reason: "Uni", now: now, id: "e4")
        let m = try XCTUnwrap(try JSONSerialization.jsonObject(with: mark.json) as? [String: Any])
        XCTAssertEqual(m["state"] as? String, "abwesend")
        XCTAssertEqual(m["reason"] as? String, "Uni")
        XCTAssertEqual(mark.requiredFeature, "planner")
    }
}

final class WebUntisTests: XCTestCase {
    func testConfigParsing() {
        XCTAssertEqual(UntisConfig.parse("https://beispiel-schule.webuntis.com/timetable/my-student?date=2026-11-02").server, "beispiel-schule.webuntis.com")
        XCTAssertEqual(UntisConfig.parse("beispiel-schule.webuntis.com").school, "beispiel-schule")
        XCTAssertEqual(UntisConfig.parse("https://mese.webuntis.com/WebUntis/?school=Muster-Gym#/basic/login").school, "Muster-Gym")
        XCTAssertNil(UntisConfig.parse("webuntis.example.org").school)
    }

    let rest = """
    {"format":3,"days":[{"date":"2026-11-09","status":"REGULAR","dayEntries":[],"gridEntries":[
     {"ids":[1,2],"duration":{"start":"2026-11-09T07:50","end":"2026-11-09T09:20"},"type":"NORMAL_TEACHING_PERIOD","status":"REGULAR","name":null,"color":"bfc8cf","notesAll":"","texts":[],"lessonText":"","lessonInfo":null,"substitutionText":"",
      "position1":[{"current":{"type":"TEACHER","status":"REGULAR","shortName":"Mül","longName":"Müller"},"removed":null}],
      "position2":[{"current":{"type":"SUBJECT","status":"REGULAR","shortName":"M","longName":"Mathematik"},"removed":null}],
      "position3":[{"current":{"type":"ROOM","status":"ADDED","shortName":"A101","longName":"Raum A101"},"removed":{"type":"ROOM","status":"REMOVED","shortName":"B202","longName":"Raum B202"}}]},
     {"ids":[3],"duration":{"start":"2026-11-09T09:40","end":"2026-11-09T11:10"},"type":"NORMAL_TEACHING_PERIOD","status":"CANCELLED","name":null,"color":"ffaa00","notesAll":"","texts":[],"lessonText":"","lessonInfo":null,"substitutionText":"Entfall wegen Fortbildung",
      "position2":[{"current":{"type":"SUBJECT","status":"REGULAR","shortName":"PH","longName":"Physik"},"removed":null}]},
     {"ids":[4],"duration":{"start":"2026-11-09T13:45","end":"2026-11-09T15:15"},"type":"EXAM","status":"REGULAR","name":null,"color":null,"notesAll":"","texts":[{"type":"LESSON_INFO","text":"Klausur Q3"}],"lessonText":"","lessonInfo":"","substitutionText":"",
      "position2":[{"current":{"type":"SUBJECT","status":"REGULAR","shortName":"CH","longName":"Chemie"},"removed":null}]}
    ]},{"date":"2026-11-10","status":"REGULAR","dayEntries":[],"gridEntries":[
     {"ids":[5],"duration":{"start":"2026-11-10T00:00","end":"2026-11-10T23:59"},"type":"EVENT","status":"CHANGED","name":"Studienfahrt","color":null,"notesAll":"","texts":[],"lessonText":"","lessonInfo":null,"substitutionText":""}
    ]}]}
    """

    func testRestEntries() throws {
        let periods = try UntisParser.entries(Data(rest.utf8))
        XCTAssertEqual(periods.count, 4)
        let math = periods[0]
        XCTAssertEqual(math.start, "07:50")
        XCTAssertEqual(math.end, "09:20")
        XCTAssertEqual(math.subject, "M")
        XCTAssertEqual(math.subjectLong, "Mathematik")
        XCTAssertEqual(math.teacher, "Mül")
        XCTAssertEqual(math.room, "A101")
        XCTAssertEqual(math.roomOld, "B202")
        XCTAssertTrue(math.isChanged)
        XCTAssertEqual(periods[1].status, .cancelled)
        XCTAssertEqual(periods[1].info, "Entfall wegen Fortbildung")
        XCTAssertEqual(periods[2].kind, .exam)
        XCTAssertEqual(periods[2].info, "Klausur Q3")
        XCTAssertEqual(periods[3].kind, .event)
        XCTAssertEqual(periods[3].title, "Studienfahrt")
    }

    func testRpcTimetableMergesDoubleLessons() {
        let rows: [[String: Any]] = [
            ["date": 20261109, "startTime": 835, "endTime": 920, "su": [["name": "M", "longname": "Mathematik"]], "te": [["name": "Mül"]], "ro": [["name": "A101"]]],
            ["date": 20261109, "startTime": 750, "endTime": 835, "su": [["name": "M", "longname": "Mathematik"]], "te": [["name": "Mül"]], "ro": [["name": "A101"]]],
            ["date": 20261109, "startTime": 940, "endTime": 1025, "code": "cancelled", "su": [["name": "PH"]], "te": [], "ro": []],
            ["date": 20261109, "startTime": 1345, "endTime": 1430, "lstype": "ex", "su": [["name": "CH"]], "te": [["name": "Neu", "orgname": "Alt"]], "ro": []],
        ]
        let p = UntisParser.rpcTimetable(rows)
        XCTAssertEqual(p.count, 3)
        XCTAssertEqual(p[0].start, "07:50")
        XCTAssertEqual(p[0].end, "09:20")
        XCTAssertEqual(p[1].status, .cancelled)
        XCTAssertEqual(p[2].kind, .exam)
        XCTAssertEqual(p[2].teacherOld, "Alt")
    }

    func testAppDataAndMessages() throws {
        let app = """
        {"currentSchoolYear":{"timeGrid":{"units":[{"unitOfDay":2,"startTime":835,"endTime":920},{"unitOfDay":1,"startTime":750,"endTime":835}]}},
         "holidays":[{"id":1,"name":"Weihnachtsferien","start":"2026-12-21T00:00:00","end":"2027-01-09T00:00:00"}],
         "user":{"name":"muster","person":{"displayName":"Muster Max"}}}
        """
        let d = try UntisParser.appData(Data(app.utf8))
        XCTAssertEqual(d.units.map(\.number), [1, 2])
        XCTAssertEqual(d.units[0].start, "07:50")
        XCTAssertEqual(d.holidays, [UntisHoliday(name: "Weihnachtsferien", start: "2026-12-21", end: "2027-01-09")])
        XCTAssertEqual(d.userName, "Muster Max")

        let msgs = """
        {"incomingMessages":[{"id":7,"subject":"Elternabend","contentPreview":"Am 14.1. um 19 Uhr&nbsp;in der Aula","sender":{"displayName":"Sekretariat"},"sentDateTime":"2026-11-02T08:46:00","isMessageRead":false,"hasAttachments":true}],"readConfirmationMessages":[]}
        """
        let m = try UntisParser.messages(Data(msgs.utf8))
        XCTAssertEqual(m.first?.preview, "Am 14.1. um 19 Uhr in der Aula")
        XCTAssertEqual(m.first?.read, false)
        XCTAssertEqual(UntisParser.plainText("<p>Zeile&nbsp;1<br>Zeile 2</p><p>Ende &amp; gut</p>"), "Zeile 1\nZeile 2\nEnde & gut")
    }
}

final class PlannerBuilderTests: XCTestCase {
    let lessons = [
        UntisPeriod(date: "2026-11-04", start: "07:50", end: "09:20", subject: "E", subjectLong: "Englisch", teacher: "Mül", room: "A101"),
        UntisPeriod(date: "2026-11-04", start: "09:40", end: "11:10", subject: "M", subjectLong: "Mathematik", room: "B202"),
        UntisPeriod(date: "2026-11-04", start: "11:30", end: "13:00", status: .cancelled, subject: "PH", subjectLong: "Physik"),
        UntisPeriod(date: "2026-11-04", start: "13:45", end: "15:15", kind: .exam, subject: "CH", subjectLong: "Chemie"),
    ]
    let lecture = PlannerAppointment(id: "uni1", title: "Analysis I", date: "2026-11-02", startTime: "10:15", endTime: "11:45", allDay: false,
                                     location: "H I", category: "uni", recur: Recurrence(days: [1, 3], until: "2027-02-12"))

    func testWeekHelpers() {
        XCTAssertEqual(Planner.weekday("2026-11-02"), 1)
        XCTAssertEqual(Planner.weekday("2026-11-08"), 7)
        XCTAssertEqual(Planner.monday(of: "2026-11-05"), "2026-11-02")
        XCTAssertEqual(Planner.week(of: "2026-11-02").last, "2026-11-08")
        XCTAssertTrue(Planner.occurs(lecture, on: "2026-11-04"))
        XCTAssertFalse(Planner.occurs(lecture, on: "2026-11-05"))
        XCTAssertFalse(Planner.occurs(lecture, on: "2027-02-15"))
        XCTAssertFalse(Planner.occurs(lecture, on: "2026-10-28"))
    }

    func testLectureMarksOverlappingLessonAndOverrides() {
        let suggestion = PlannerSuggestion(id: "s1", title: "Elternabend", date: "2026-11-04", startTime: "19:00", endTime: nil, allDay: false, location: "Aula", mailbox: "WebUntis")
        var e = Planner.entries(on: "2026-11-04", periods: lessons, appointments: [lecture], suggestions: [suggestion], overrides: [:], holidays: [])
        let math = e.first { $0.short == "M" }!
        XCTAssertEqual(math.mark, .uni("Analysis I"))
        XCTAssertTrue(math.isOff)
        XCTAssertEqual(e.first { $0.short == "E" }!.mark, .none)
        XCTAssertEqual(e.first { $0.short == "PH" }!.mark, .cancelledBySchool)
        XCTAssertEqual(e.first { $0.kind == .exam }!.title, "Klausur Chemie")
        XCTAssertEqual(e.first { $0.kind == .uni }!.start, 615)
        XCTAssertEqual(e.last?.kind, .suggestion)
        XCTAssertEqual(e.last?.end, 19 * 60 + 60)

        let overrides = [
            Planner.lessonKey(lessons[1]): SchoolOverride(key: Planner.lessonKey(lessons[1]), date: "2026-11-04", start: "09:40", end: "11:10", subject: "M", title: nil, state: "anwesend", reason: nil),
            Planner.lessonKey(lessons[0]): SchoolOverride(key: Planner.lessonKey(lessons[0]), date: "2026-11-04", start: "07:50", end: "09:20", subject: "E", title: nil, state: "abwesend", reason: "Arzt"),
            Planner.occurrenceKey("uni1", date: "2026-11-04"): SchoolOverride(key: "a:uni1:2026-11-04", date: "2026-11-04", start: "10:15", end: nil, subject: nil, title: nil, state: "entfall", reason: nil),
        ]
        e = Planner.entries(on: "2026-11-04", periods: lessons, appointments: [lecture], suggestions: [], overrides: overrides, holidays: [])
        XCTAssertEqual(e.first { $0.short == "M" }!.mark, .present)
        XCTAssertEqual(e.first { $0.short == "E" }!.mark, .absent("Arzt"))
        XCTAssertEqual(e.first { $0.kind == .uni }!.mark, .cancelledByMe)
    }

    func testHolidaysAndColumns() {
        let e = Planner.entries(on: "2026-12-22", periods: [], appointments: [], suggestions: [], overrides: [:],
                                holidays: [UntisHoliday(name: "Weihnachtsferien", start: "2026-12-21", end: "2027-01-09")])
        XCTAssertEqual(e.map(\.title), ["Weihnachtsferien"])
        XCTAssertTrue(e[0].isAllDay)

        let day = Planner.entries(on: "2026-11-04", periods: lessons, appointments: [lecture], suggestions: [], overrides: [:], holidays: [])
        let cols = Planner.columns(day)
        let math = day.first { $0.short == "M" }!
        let uni = day.first { $0.kind == .uni }!
        XCTAssertEqual(cols[math.id]?.count, 2)
        XCTAssertEqual(cols[uni.id]?.count, 2)
        XCTAssertNotEqual(cols[math.id]?.index, cols[uni.id]?.index)
        XCTAssertEqual(cols[day.first { $0.short == "E" }!.id]?.count, 1)
    }
}

final class WikiTests: XCTestCase {
    func testBucketAndIndexFromPlugin() throws {
        let bucket = try WikiCodec.open(Data(Vectors.wikiBucketEnvelope.utf8), passphrase: Vectors.passphrase, as: WikiBucket.self)
        XCTAssertEqual(bucket.files.map(\.p), ["Mathematik/Ableitung.md", "Physik/_assets/Feld.svg"])
        XCTAssertTrue(bucket.files[0].d.contains("[[Integral|das Integral]]"))
        let index = try WikiCodec.open(Data(Vectors.wikiIndexEnvelope.utf8), passphrase: Vectors.passphrase, as: WikiManifest.self)
        XCTAssertEqual(index.root, "02 Wiki")
        XCTAssertEqual(index.files.count, 2)
        XCTAssertEqual(index.buckets.first?.id, "b07")
        XCTAssertThrowsError(try WikiCodec.open(Data(Vectors.wikiIndexEnvelope.utf8), passphrase: "falsch", as: WikiManifest.self))
    }

    func testLinkResolver() {
        let r = WikiLinkResolver(paths: ["Mathematik/Analysis/Ableitung.md", "Mathematik/Integral.md", "Physik/Integral.md", "Physik/_assets/Feld.svg", "Index.md"])
        XCTAssertEqual(r.resolve("Ableitung"), "Mathematik/Analysis/Ableitung.md")
        XCTAssertEqual(r.resolve("ableitung#Definition|die Ableitung"), "Mathematik/Analysis/Ableitung.md")
        XCTAssertEqual(r.resolve("Integral", from: "Physik/Welle.md"), "Physik/Integral.md")
        XCTAssertEqual(r.resolve("Mathematik/Integral"), "Mathematik/Integral.md")
        XCTAssertEqual(r.resolve("Feld.svg"), "Physik/_assets/Feld.svg")
        XCTAssertEqual(r.resolve("#Abschnitt", from: "Index.md"), "Index.md")
        XCTAssertNil(r.resolve("Gibt es nicht"))
    }

    func testTextHelpers() {
        let md = "---\ntitle: X\ntags:\n  - mathematik\n  - \"#analysis\"\n---\n# Ableitung\n\n> [!tip] Merksatz\n> Die **Steigung** von [[Tangente|Tangenten]].\n%% versteckt %%\n"
        let (fm, body) = WikiText.split(md)
        XCTAssertEqual(WikiText.tags(fm), ["mathematik", "analysis"])
        XCTAssertTrue(body.hasPrefix("# Ableitung"))
        let plain = WikiText.plain(md)
        XCTAssertEqual(plain, "Ableitung Merksatz Die Steigung von Tangenten.")
        XCTAssertEqual(WikiText.fold("Größe Übung"), "grosse ubung")
        XCTAssertEqual(WikiText.snippet(plain, folded: WikiText.fold(plain), query: "steigung", radius: 4), "…Die Steigung von…")
        XCTAssertEqual(WikiText.title("Physik/Welle.md"), "Welle")
    }
}
