import Foundation
import Network

public struct IMAPAccount: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Shown in the app and written to the vault as "postfach".
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var mailbox: String
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, host: String, port: Int = 993, username: String, mailbox: String = "INBOX", enabled: Bool = true) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.mailbox = mailbox
        self.enabled = enabled
    }

    public static func gmail(_ address: String = "") -> IMAPAccount {
        IMAPAccount(name: "Gmail", host: "imap.gmail.com", username: address)
    }

    public static func ionos(_ address: String = "") -> IMAPAccount {
        IMAPAccount(name: "Schule", host: "imap.ionos.de", username: address)
    }
}

public enum IMAPError: LocalizedError, Equatable {
    case connectionFailed(String)
    case timeout
    case authFailed(String)
    case protocolError(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let m): return "Verbindung zum Mailserver fehlgeschlagen: \(m)"
        case .timeout: return "Der Mailserver antwortet nicht (Zeitüberschreitung)."
        case .authFailed(let m):
            let hint = m.lowercased().contains("application-specific") || m.lowercased().contains("app password") || m.contains("AUTHENTICATIONFAILED")
                ? " Bei Gmail funktioniert nur ein App-Passwort (Google-Konto, Sicherheit, App-Passwörter)." : ""
            return "Anmeldung abgelehnt: \(m).\(hint)"
        case .protocolError(let m): return "Unerwartete Antwort des Mailservers: \(m)"
        case .closed: return "Der Mailserver hat die Verbindung geschlossen."
        }
    }
}

public struct FetchedMail: Sendable, Hashable {
    public var uid: UInt32
    public var internalDate: Date?
    public var raw: Data
}

public struct IMAPFetchResult: Sendable {
    public var uidValidity: UInt32
    public var messages: [FetchedMail]
}

private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// One IMAP session over TLS (port 993). Used sequentially from a single task.
final class IMAPConnection: @unchecked Sendable {
    struct Response {
        var text: String
        var literals: [[UInt8]]
    }

    private let conn: NWConnection
    private let queue = DispatchQueue(label: "de.tagwerk.imap")
    private var buffer: [UInt8] = []
    private var tagCounter = 0
    private var watchdog: DispatchWorkItem?
    private(set) var timedOut = false

    init(host: String, port: Int) {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 15
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 993, using: params)
    }

    func open() async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [conn = self.conn] state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume() }
                case .failed(let e):
                    if once.claim() { cont.resume(throwing: IMAPError.connectionFailed(e.localizedDescription)) }
                case .waiting(let e):
                    if once.claim() {
                        cont.resume(throwing: IMAPError.connectionFailed(e.localizedDescription))
                        conn.cancel()
                    }
                case .cancelled:
                    if once.claim() { cont.resume(throwing: IMAPError.closed) }
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    func armTimeout(seconds: Double) {
        watchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.timedOut = true
            self?.conn.cancel()
        }
        watchdog = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func close() {
        watchdog?.cancel()
        conn.cancel()
    }

    private func receiveMore() async throws {
        let data: Data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] content, _, isComplete, error in
                if let error {
                    cont.resume(throwing: (self?.timedOut ?? false) ? IMAPError.timeout : IMAPError.connectionFailed(error.localizedDescription))
                    return
                }
                if let content, !content.isEmpty {
                    cont.resume(returning: content)
                    return
                }
                if isComplete {
                    cont.resume(throwing: (self?.timedOut ?? false) ? IMAPError.timeout : IMAPError.closed)
                    return
                }
                cont.resume(returning: Data())
            }
        }
        buffer.append(contentsOf: data)
    }

    func readLine() async throws -> [UInt8] {
        while true {
            if let i = buffer.firstIndex(of: 10) {
                var line = Array(buffer[..<i])
                buffer.removeSubrange(...i)
                if line.last == 13 { line.removeLast() }
                return line
            }
            if buffer.count > 2_000_000 { throw IMAPError.protocolError("Zeile zu lang") }
            try await receiveMore()
        }
    }

    func readBytes(_ n: Int) async throws -> [UInt8] {
        while buffer.count < n { try await receiveMore() }
        let out = Array(buffer[..<n])
        buffer.removeSubrange(..<n)
        return out
    }

    func send(_ string: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(string.utf8), completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    static func literalLength(_ line: String) -> Int? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else { return nil }
        let digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        return Int(digits.replacingOccurrences(of: "+", with: ""))
    }

    func readResponse() async throws -> Response {
        var text = ""
        var literals: [[UInt8]] = []
        while true {
            let lineBytes = try await readLine()
            let line = String(decoding: lineBytes, as: UTF8.self)
            text += line
            if let n = IMAPConnection.literalLength(line), n >= 0, n < 5_000_000 {
                let literal = try await readBytes(n)
                literals.append(literal)
                continue
            }
            return Response(text: text, literals: literals)
        }
    }

    private func nextTag() -> String {
        tagCounter += 1
        return "t\(tagCounter)"
    }

    @discardableResult
    func command(_ cmd: String) async throws -> [Response] {
        let tag = nextTag()
        try await send("\(tag) \(cmd)\r\n")
        var untagged: [Response] = []
        while true {
            let r = try await readResponse()
            if r.text.hasPrefix("\(tag) ") {
                let rest = String(r.text.dropFirst(tag.count + 1))
                if rest.uppercased().hasPrefix("OK") { return untagged }
                throw IMAPError.protocolError(rest)
            }
            untagged.append(r)
        }
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func login(user: String, password: String) async throws {
        let asciiSafe = (user + password).unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 }
        if asciiSafe {
            let tag = nextTag()
            try await send("\(tag) LOGIN \(IMAPConnection.quote(user)) \(IMAPConnection.quote(password))\r\n")
            while true {
                let r = try await readResponse()
                if r.text.hasPrefix("\(tag) ") {
                    let rest = String(r.text.dropFirst(tag.count + 1))
                    if rest.uppercased().hasPrefix("OK") { return }
                    throw IMAPError.authFailed(rest)
                }
            }
        }
        // Non-ASCII credentials: SASL PLAIN avoids literals in LOGIN.
        let tag = nextTag()
        try await send("\(tag) AUTHENTICATE PLAIN\r\n")
        let first = try await readResponse()
        guard first.text.hasPrefix("+") else { throw IMAPError.authFailed(first.text) }
        var raw: [UInt8] = [0]
        raw += Array(user.utf8)
        raw.append(0)
        raw += Array(password.utf8)
        try await send(Data(raw).base64EncodedString() + "\r\n")
        while true {
            let r = try await readResponse()
            if r.text.hasPrefix("\(tag) ") {
                let rest = String(r.text.dropFirst(tag.count + 1))
                if rest.uppercased().hasPrefix("OK") { return }
                throw IMAPError.authFailed(rest)
            }
        }
    }
}

public enum IMAPClient {
    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    static func imapDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "d-MMM-yyyy"
        return f.string(from: date)
    }

    static func parseInternalDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d-MMM-yyyy HH:mm:ss Z"
        return f.date(from: s.trimmingCharacters(in: .whitespaces))
    }

    static func searchUIDs(_ responses: [IMAPConnection.Response]) -> [UInt32] {
        var out: [UInt32] = []
        for r in responses where r.text.uppercased().hasPrefix("* SEARCH") {
            out += r.text.dropFirst(8).split(separator: " ").compactMap { UInt32($0) }
        }
        return out
    }

    /// Checks login and mailbox, nothing else.
    public static func test(account: IMAPAccount, password: String) async throws {
        _ = try await fetchRecent(account: account, password: password, since: Date(), excludingUIDs: [], knownUIDValidity: nil, limit: 0)
    }

    /// Fetches up to `limit` newest messages received since `since` that are not in `excludingUIDs`.
    /// Read-only (EXAMINE, BODY.PEEK): nothing is marked as read.
    public static func fetchRecent(account: IMAPAccount, password: String, since: Date, excludingUIDs: Set<UInt32>,
                                   knownUIDValidity: UInt32?, limit: Int = 40) async throws -> IMAPFetchResult {
        let c = IMAPConnection(host: account.host, port: account.port)
        defer { c.close() }
        c.armTimeout(seconds: 90)
        try await c.open()
        let greeting = try await c.readResponse()
        let g = greeting.text.uppercased()
        guard g.hasPrefix("* OK") || g.hasPrefix("* PREAUTH") else { throw IMAPError.protocolError(greeting.text) }
        if !g.hasPrefix("* PREAUTH") { try await c.login(user: account.username, password: password) }

        let examine = try await c.command("EXAMINE \(IMAPConnection.quote(account.mailbox.isEmpty ? "INBOX" : account.mailbox))")
        let uidValidity = examine.compactMap { firstMatch("UIDVALIDITY (\\d+)", in: $0.text).flatMap { UInt32($0) } }.first ?? 0
        var exclude = excludingUIDs
        if let known = knownUIDValidity, known != uidValidity { exclude = [] }

        var messages: [FetchedMail] = []
        if limit > 0 {
            let search = try await c.command("UID SEARCH SINCE \(imapDate(since))")
            let uids = Array(searchUIDs(search).filter { !exclude.contains($0) }.sorted().suffix(limit))
            if !uids.isEmpty {
                let set = uids.map(String.init).joined(separator: ",")
                let fetch = try await c.command("UID FETCH \(set) (UID INTERNALDATE BODY.PEEK[]<0.65536>)")
                for r in fetch where r.text.uppercased().contains("FETCH") {
                    guard let uidString = firstMatch("UID (\\d+)", in: r.text), let uid = UInt32(uidString), let body = r.literals.last else { continue }
                    let date = firstMatch("INTERNALDATE \"([^\"]+)\"", in: r.text).flatMap(parseInternalDate)
                    messages.append(FetchedMail(uid: uid, internalDate: date, raw: Data(body)))
                }
            }
        }
        _ = try? await c.command("LOGOUT")
        return IMAPFetchResult(uidValidity: uidValidity, messages: messages.sorted { $0.uid < $1.uid })
    }
}
