import Foundation

/// Where and as whom to log in to WebUntis. `school` is the school's login name (often the subdomain).
public struct UntisConfig: Codable, Hashable, Sendable {
    public var server: String
    public var school: String
    public var username: String

    public init(server: String = "", school: String = "", username: String = "") {
        self.server = server
        self.school = school
        self.username = username
    }

    public var isComplete: Bool { !server.isEmpty && !school.isEmpty && !username.isEmpty }

    /// Reads a pasted WebUntis address: "https://name.webuntis.com/timetable/…", "name.webuntis.com" or an old link with ?school=.
    public static func parse(_ input: String) -> (server: String, school: String?) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", nil) }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let comps = URLComponents(string: withScheme), let host = comps.host?.lowercased(), !host.isEmpty else { return (trimmed, nil) }
        if let s = comps.queryItems?.first(where: { $0.name == "school" })?.value, !s.isEmpty { return (host, s) }
        let labels = host.split(separator: ".")
        if host.hasSuffix(".webuntis.com"), labels.count >= 3, let first = labels.first { return (host, String(first)) }
        return (host, nil)
    }
}

public struct UntisPeriod: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case lesson, exam, event, other }
    public enum Status: String, Codable, Sendable { case regular, cancelled, changed, additional }

    public var date: String
    public var start: String
    public var end: String
    public var kind: Kind
    public var status: Status
    public var subject: String?
    public var subjectLong: String?
    public var teacher: String?
    public var teacherOld: String?
    public var room: String?
    public var roomOld: String?
    public var title: String?
    public var info: String?
    /// WebUntis colour, hex without "#".
    public var color: String?

    public var id: String { "\(date)-\(start)-\(subject ?? title ?? "")" }

    public init(date: String, start: String, end: String, kind: Kind = .lesson, status: Status = .regular, subject: String? = nil,
                subjectLong: String? = nil, teacher: String? = nil, teacherOld: String? = nil, room: String? = nil, roomOld: String? = nil,
                title: String? = nil, info: String? = nil, color: String? = nil) {
        self.date = date
        self.start = start
        self.end = end
        self.kind = kind
        self.status = status
        self.subject = subject
        self.subjectLong = subjectLong
        self.teacher = teacher
        self.teacherOld = teacherOld
        self.room = room
        self.roomOld = roomOld
        self.title = title
        self.info = info
        self.color = color
    }

    /// Room or teacher differ from the plan.
    public var isChanged: Bool { status == .changed || status == .additional || roomOld != nil || teacherOld != nil }
}

public struct UntisHoliday: Codable, Hashable, Sendable {
    public var name: String
    public var start: String
    public var end: String

    public init(name: String, start: String, end: String) {
        self.name = name
        self.start = start
        self.end = end
    }
}

public struct UntisTimeUnit: Codable, Hashable, Sendable {
    public var number: Int
    public var start: String
    public var end: String

    public init(number: Int, start: String, end: String) {
        self.number = number
        self.start = start
        self.end = end
    }
}

public struct UntisMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var subject: String
    public var preview: String
    public var sender: String
    /// Local time as WebUntis sends it, "2026-11-02T08:46:00".
    public var sent: String
    public var read: Bool
    public var attachments: Bool

    public init(id: Int, subject: String, preview: String, sender: String, sent: String, read: Bool, attachments: Bool) {
        self.id = id
        self.subject = subject
        self.preview = preview
        self.sender = sender
        self.sent = sent
        self.read = read
        self.attachments = attachments
    }
}

public struct UntisSchoolData: Codable, Hashable, Sendable {
    public var holidays: [UntisHoliday]
    public var units: [UntisTimeUnit]
    public var userName: String?

    public init(holidays: [UntisHoliday], units: [UntisTimeUnit], userName: String?) {
        self.holidays = holidays
        self.units = units
        self.userName = userName
    }
}

public enum UntisError: LocalizedError, Equatable {
    case notConfigured
    case badCredentials
    case refused(String)
    case noSession
    case http(Int)
    case format

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "WebUntis ist noch nicht eingerichtet: Adresse, Benutzername und Passwort in den Einstellungen eintragen."
        case .badCredentials: return "WebUntis hat Benutzername oder Passwort abgelehnt."
        case .refused(let m): return "WebUntis: \(m)"
        case .noSession: return "WebUntis hat die Anmeldung nicht angenommen."
        case .http(let c): return "WebUntis antwortet mit Fehler \(c)."
        case .format: return "WebUntis hat in einem unerwarteten Format geantwortet."
        }
    }
}

public enum UntisParser {
    static func time(_ isoLocal: String) -> String { String(isoLocal.dropFirst(11).prefix(5)) }

    static func clock(_ v: Any?) -> String? {
        guard let n = (v as? Int) ?? (v as? NSNumber)?.intValue else { return nil }
        return String(format: "%02d:%02d", n / 100, n % 100)
    }

    static func day(_ v: Any?) -> String? {
        if let s = v as? String, s.count >= 10 { return String(s.prefix(10)) }
        guard let n = (v as? Int) ?? (v as? NSNumber)?.intValue else { return nil }
        return String(format: "%04d-%02d-%02d", n / 10000, n / 100 % 100, n % 100)
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func joined(_ a: String?, _ b: String?) -> String? {
        guard let b = nonEmpty(b) else { return a }
        guard let a else { return b }
        return a.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(b) ? a : "\(a), \(b)"
    }

    static func kind(_ type: String) -> UntisPeriod.Kind {
        switch type {
        case "NORMAL_TEACHING_PERIOD", "ADDITIONAL_PERIOD": return .lesson
        case "EXAM": return .exam
        case "EVENT": return .event
        default: return .other
        }
    }

    static func status(_ s: String) -> UntisPeriod.Status {
        switch s {
        case "CANCELLED": return .cancelled
        case "CHANGED": return .changed
        case "ADDITIONAL": return .additional
        default: return .regular
        }
    }

    /// REST timetable entries (format 3), as the WebUntis web app loads them.
    public static func entries(_ data: Data) throws -> [UntisPeriod] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let days = root["days"] as? [[String: Any]] else {
            throw UntisError.format
        }
        var out: [UntisPeriod] = []
        for day in days {
            for e in (day["gridEntries"] as? [[String: Any]]) ?? [] {
                guard let dur = e["duration"] as? [String: Any], let s = dur["start"] as? String, let en = dur["end"] as? String,
                      s.count >= 16, en.count >= 16 else { continue }
                var p = UntisPeriod(date: String(s.prefix(10)), start: time(s), end: time(en), kind: kind(e["type"] as? String ?? ""),
                                    status: status(e["status"] as? String ?? ""))
                if (e["type"] as? String) == "ADDITIONAL_PERIOD" && p.status == .regular { p.status = .additional }
                for i in 1...7 {
                    for item in (e["position\(i)"] as? [[String: Any]]) ?? [] {
                        let cur = item["current"] as? [String: Any]
                        let old = item["removed"] as? [String: Any]
                        let type = (cur?["type"] as? String) ?? (old?["type"] as? String) ?? ""
                        let curName = nonEmpty(cur?["shortName"] as? String) ?? nonEmpty(cur?["displayName"] as? String)
                        let oldName = nonEmpty(old?["shortName"] as? String) ?? nonEmpty(old?["displayName"] as? String)
                        switch type {
                        case "SUBJECT":
                            p.subject = p.subject ?? curName ?? oldName
                            p.subjectLong = p.subjectLong ?? nonEmpty((cur?["longName"] as? String) ?? (old?["longName"] as? String))
                        case "TEACHER":
                            p.teacher = joined(p.teacher, curName)
                            if cur == nil || old != nil { p.teacherOld = joined(p.teacherOld, oldName) }
                        case "ROOM":
                            p.room = joined(p.room, curName)
                            if old != nil { p.roomOld = joined(p.roomOld, oldName) }
                        default:
                            break
                        }
                    }
                }
                p.title = nonEmpty(e["name"] as? String)
                var infos: [String] = []
                func add(_ t: String?) {
                    guard let t = nonEmpty(t), !infos.contains(t) else { return }
                    infos.append(t)
                }
                add(e["substitutionText"] as? String)
                add(e["lessonInfo"] as? String)
                add(e["lessonText"] as? String)
                for t in (e["texts"] as? [[String: Any]]) ?? [] {
                    if let text = t["text"] as? String { add(text) }
                    else { add(t.values.compactMap { $0 as? String }.max { $0.count < $1.count }) }
                }
                add(e["notesAll"] as? String)
                p.info = infos.isEmpty ? nil : infos.joined(separator: "\n")
                p.color = nonEmpty(e["color"] as? String)
                out.append(p)
            }
        }
        return out.sorted { ($0.date, $0.start) < ($1.date, $1.start) }
    }

    /// Result of the documented JSON-RPC method getTimetable: single periods, merged into double lessons.
    public static func rpcTimetable(_ rows: [[String: Any]]) -> [UntisPeriod] {
        func names(_ v: Any?, _ key: String) -> String? {
            let list = (v as? [[String: Any]]) ?? []
            let joined = list.compactMap { nonEmpty($0[key] as? String) }.joined(separator: ", ")
            return joined.isEmpty ? nil : joined
        }
        var items: [UntisPeriod] = []
        for r in rows {
            guard let date = day(r["date"]), let start = clock(r["startTime"]), let end = clock(r["endTime"]) else { continue }
            let code = r["code"] as? String
            let lstype = r["lstype"] as? String
            var p = UntisPeriod(date: date, start: start, end: end,
                                kind: lstype == "ex" ? .exam : (lstype == nil || lstype == "ls") ? .lesson : .other,
                                status: code == "cancelled" ? .cancelled : code == "irregular" ? .changed : .regular)
            p.subject = names(r["su"], "name")
            p.subjectLong = names(r["su"], "longname")
            p.teacher = names(r["te"], "name")
            p.teacherOld = names(r["te"], "orgname")
            p.room = names(r["ro"], "name")
            p.roomOld = names(r["ro"], "orgname")
            let infos = [r["substText"], r["info"], r["lstext"]].compactMap { nonEmpty($0 as? String) }
            p.info = infos.isEmpty ? nil : infos.joined(separator: "\n")
            items.append(p)
        }
        items.sort { ($0.date, $0.start) < ($1.date, $1.start) }
        var merged: [UntisPeriod] = []
        for p in items {
            if var last = merged.last, last.date == p.date, last.end == p.start, last.subject == p.subject, last.teacher == p.teacher,
               last.room == p.room, last.status == p.status, last.kind == p.kind, last.info == p.info {
                last.end = p.end
                merged[merged.count - 1] = last
            } else {
                merged.append(p)
            }
        }
        return merged
    }

    public static func appData(_ data: Data) throws -> UntisSchoolData {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UntisError.format }
        let year = root["currentSchoolYear"] as? [String: Any]
        let grid = year?["timeGrid"] as? [String: Any]
        let units: [UntisTimeUnit] = ((grid?["units"] as? [[String: Any]]) ?? []).compactMap { u in
            guard let n = (u["unitOfDay"] as? NSNumber)?.intValue, let s = clock(u["startTime"]), let e = clock(u["endTime"]) else { return nil }
            return UntisTimeUnit(number: n, start: s, end: e)
        }.sorted { $0.number < $1.number }
        let holidays: [UntisHoliday] = ((root["holidays"] as? [[String: Any]]) ?? []).compactMap { h in
            guard let s = day(h["start"]), let e = day(h["end"]) else { return nil }
            let name = nonEmpty(h["name"] as? String) ?? nonEmpty(h["longName"] as? String) ?? "Ferien"
            return UntisHoliday(name: name, start: s, end: e)
        }.sorted { $0.start < $1.start }
        let user = root["user"] as? [String: Any]
        let person = user?["person"] as? [String: Any]
        return UntisSchoolData(holidays: holidays, units: units, userName: nonEmpty(person?["displayName"] as? String) ?? nonEmpty(user?["name"] as? String))
    }

    public static func messages(_ data: Data) throws -> [UntisMessage] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UntisError.format }
        return ((root["incomingMessages"] as? [[String: Any]]) ?? []).compactMap { m in
            guard let id = (m["id"] as? NSNumber)?.intValue else { return nil }
            let sender = (m["sender"] as? [String: Any])?["displayName"] as? String
            return UntisMessage(id: id, subject: nonEmpty(m["subject"] as? String) ?? "(ohne Betreff)", preview: plainText(m["contentPreview"] as? String ?? ""),
                                sender: nonEmpty(sender) ?? "", sent: m["sentDateTime"] as? String ?? "", read: m["isMessageRead"] as? Bool ?? true,
                                attachments: m["hasAttachments"] as? Bool ?? false)
        }
    }

    public static func messageText(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UntisError.format }
        return plainText(root["content"] as? String ?? "")
    }

    /// Message HTML as plain text: line breaks kept, tags removed, common entities decoded.
    public static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</(p|div|li|h[1-6]|tr)>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&auml;": "ä", "&ouml;": "ö", "&uuml;": "ü",
                       "&Auml;": "Ä", "&Ouml;": "Ö", "&Uuml;": "Ü", "&szlig;": "ß"] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        s = s.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rpcError(_ err: [String: Any]) -> UntisError {
        let code = (err["code"] as? NSNumber)?.intValue ?? 0
        let message = err["message"] as? String ?? "Unbekannter Fehler"
        switch code {
        case -8504: return .badCredentials
        case -8520: return .noSession
        default: return .refused(message)
        }
    }
}

/// Session against one WebUntis server: JSON-RPC login, then the REST endpoints of the web app;
/// for the timetable the documented JSON-RPC method is the fallback.
public actor UntisClient {
    public let config: UntisConfig
    private let password: String
    private let session: URLSession
    private let cookies: HTTPCookieStorage
    private var personId: Int?
    private var token: String?
    private var tokenAt: Date?

    public init(config: UntisConfig, password: String) {
        self.config = config
        self.password = password
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.timeoutIntervalForRequest = 25
        let storage = cfg.httpCookieStorage ?? HTTPCookieStorage.shared
        cfg.httpCookieStorage = storage
        cookies = storage
        session = URLSession(configuration: cfg)
    }

    private var base: String { "https://\(config.server)/WebUntis" }

    private func rpc(_ method: String, params: [String: Any]) async throws -> Any {
        guard var comps = URLComponents(string: "\(base)/jsonrpc.do") else { throw UntisError.notConfigured }
        comps.queryItems = [URLQueryItem(name: "school", value: config.school)]
        guard let url = comps.url else { throw UntisError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "method": method, "params": params, "jsonrpc": "2.0"])
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UntisError.http(code) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UntisError.format }
        if let err = obj["error"] as? [String: Any] { throw UntisParser.rpcError(err) }
        return obj["result"] ?? NSNull()
    }

    public func login() async throws {
        guard config.isComplete, !password.isEmpty else { throw UntisError.notConfigured }
        let value = "\"_\(Data(config.school.utf8).base64EncodedString())\""
        if let c = HTTPCookie(properties: [.domain: config.server, .path: "/", .name: "schoolname", .value: value, .secure: "TRUE"]) {
            cookies.setCookie(c)
        }
        let result = try await rpc("authenticate", params: ["user": config.username, "password": password, "client": "Tagwerk"])
        guard let r = result as? [String: Any], let pid = (r["personId"] as? NSNumber)?.intValue else { throw UntisError.format }
        personId = pid
        token = nil
    }

    private func bearer() async throws -> String {
        if let token, let at = tokenAt, Date().timeIntervalSince(at) < 600 { return token }
        guard let url = URL(string: "\(base)/api/token/new") else { throw UntisError.notConfigured }
        let (data, resp) = try await session.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let t = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), t.count > 20, !t.hasPrefix("<") else {
            throw UntisError.noSession
        }
        token = t
        tokenAt = Date()
        return t
    }

    private func rest(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard var comps = URLComponents(string: "\(base)/api/rest/view/v1/\(path)") else { throw UntisError.notConfigured }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw UntisError.notConfigured }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 {
            token = nil
            throw UntisError.noSession
        }
        guard code == 200 else { throw UntisError.http(code) }
        return data
    }

    /// Runs body with a session; logs in again once if the session expired.
    private func withSession<T>(_ body: () async throws -> T) async throws -> T {
        if personId == nil { try await login() }
        do {
            return try await body()
        } catch UntisError.noSession {
            try await login()
            return try await body()
        }
    }

    /// Lessons, exams and events between two days (inclusive, "YYYY-MM-DD").
    public func periods(from start: String, to end: String) async throws -> [UntisPeriod] {
        try await withSession {
            guard let pid = personId else { throw UntisError.noSession }
            do {
                let data = try await rest("timetable/entries", query: [
                    URLQueryItem(name: "start", value: start), URLQueryItem(name: "end", value: end),
                    URLQueryItem(name: "format", value: "3"), URLQueryItem(name: "resourceType", value: "STUDENT"),
                    URLQueryItem(name: "resources", value: String(pid)), URLQueryItem(name: "periodTypes", value: ""),
                    URLQueryItem(name: "timetableType", value: "MY_TIMETABLE"), URLQueryItem(name: "layout", value: "START_TIME"),
                ])
                return try UntisParser.entries(data)
            } catch UntisError.noSession {
                throw UntisError.noSession
            } catch {
                let digits = { (s: String) in Int(s.replacingOccurrences(of: "-", with: "")) ?? 0 }
                let result = try await rpc("getTimetable", params: ["options": [
                    "element": ["id": pid, "type": 5], "startDate": digits(start), "endDate": digits(end),
                    "showInfo": true, "showSubstText": true, "showLsText": true,
                    "roomFields": ["name", "longname"], "subjectFields": ["name", "longname"], "teacherFields": ["name"],
                ] as [String: Any]])
                return UntisParser.rpcTimetable((result as? [[String: Any]]) ?? [])
            }
        }
    }

    public func schoolData() async throws -> UntisSchoolData {
        try await withSession { try UntisParser.appData(try await rest("app/data")) }
    }

    public func messages() async throws -> [UntisMessage] {
        try await withSession { try UntisParser.messages(try await rest("messages")) }
    }

    /// Full text of one message. WebUntis may count it as read afterwards.
    public func messageText(id: Int) async throws -> String {
        try await withSession { try UntisParser.messageText(try await rest("messages/\(id)")) }
    }

    public func logout() async {
        _ = try? await rpc("logout", params: [:])
        personId = nil
        token = nil
    }
}
