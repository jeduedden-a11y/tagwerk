import Foundation

/// A decoded mail, reduced to what date extraction needs.
public struct ParsedMail: Hashable, Sendable {
    public var subject: String
    public var from: String
    public var date: Date?
    public var messageID: String?
    public var text: String
}

/// Small, forgiving RFC 5322 / MIME parser. Handles multipart trees, base64,
/// quoted-printable, RFC 2047 encoded words, any IANA charset and HTML-only mails.
public enum MIME {
    struct Part {
        var headers: [String: String]
        var body: [UInt8]
    }

    // MARK: Entry point

    public static func parse(_ data: Data) -> ParsedMail {
        let part = splitPart(Array(data))
        let h = part.headers
        let subject = decodeEncodedWords(h["subject"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let from = decodeEncodedWords(h["from"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let date = h["date"].flatMap(parseDate)
        let messageID = h["message-id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = bestText(part, depth: 0) ?? ""
        return ParsedMail(subject: subject.isEmpty ? "(ohne Betreff)" : subject, from: from, date: date, messageID: messageID,
                          text: String(cleanText(text).prefix(20_000)))
    }

    // MARK: Structure

    static func indexOf(_ needle: [UInt8], in hay: [UInt8], from: Int = 0) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
        var i = from
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == needle[0] {
                var j = 1
                while j < needle.count && hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    static func splitPart(_ bytes: [UInt8]) -> Part {
        var headerEnd = bytes.count
        var bodyStart = bytes.count
        if let i = indexOf([13, 10, 13, 10], in: bytes) {
            headerEnd = i
            bodyStart = i + 4
        }
        if let j = indexOf([10, 10], in: bytes), j < headerEnd {
            headerEnd = j
            bodyStart = j + 2
        }
        if bytes.first == 13 || bytes.first == 10 { // no headers at all
            headerEnd = 0
            bodyStart = bytes.first == 13 && bytes.count > 1 ? 2 : 1
        }
        let headerBytes = Array(bytes[0..<min(headerEnd, bytes.count)])
        let body = bodyStart < bytes.count ? Array(bytes[bodyStart...]) : []
        return Part(headers: parseHeaders(headerBytes), body: body)
    }

    static func parseHeaders(_ bytes: [UInt8]) -> [String: String] {
        let raw = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
        var result: [String: String] = [:]
        var currentName: String?
        var currentValue = ""
        func flush() {
            if let n = currentName, result[n] == nil { result[n] = currentValue.trimmingCharacters(in: .whitespaces) }
        }
        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let f = line.first, f == " " || f == "\t" {
                currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            flush()
            if let colon = line.firstIndex(of: ":") {
                currentName = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                currentValue = String(line[line.index(after: colon)...])
            } else {
                currentName = nil
                currentValue = ""
            }
        }
        flush()
        return result
    }

    /// "text/plain; charset=utf-8" -> ("text/plain", ["charset": "utf-8"])
    static func parseContentType(_ value: String?) -> (String, [String: String]) {
        guard let value, !value.isEmpty else { return ("text/plain", [:]) }
        var parts: [String] = []
        var cur = ""
        var inQuotes = false
        for ch in value {
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes {
                parts.append(cur)
                cur = ""
            } else {
                cur.append(ch)
            }
        }
        parts.append(cur)
        let type = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "text/plain"
        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            guard let eq = p.firstIndex(of: "=") else { continue }
            let k = p[..<eq].trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "*", with: "")
            var v = p[p.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 { v = String(v.dropFirst().dropLast()) }
            if let tick = v.range(of: "''"), k == "charset" || k == "name" || k == "filename" { v = String(v[tick.upperBound...]) }
            params[k] = v
        }
        return (type.isEmpty ? "text/plain" : type, params)
    }

    static func children(of part: Part, boundary: String) -> [Part] {
        let delim = Array(("--" + boundary).utf8)
        let body = part.body
        var starts: [Int] = []
        var i = 0
        while let idx = indexOf(delim, in: body, from: i) {
            let atLineStart = idx == 0 || body[idx - 1] == 10
            if atLineStart { starts.append(idx) }
            i = idx + delim.count
        }
        var result: [Part] = []
        for (n, s) in starts.enumerated() {
            let afterDelim = s + delim.count
            if afterDelim + 1 < body.count, body[afterDelim] == 45, body[afterDelim + 1] == 45 { break } // closing "--"
            var contentStart = afterDelim
            while contentStart < body.count, body[contentStart] != 10 { contentStart += 1 }
            contentStart += 1
            var contentEnd = n + 1 < starts.count ? starts[n + 1] : body.count
            if contentEnd > contentStart, contentEnd <= body.count, contentEnd > 0, body[contentEnd - 1] == 10 { contentEnd -= 1 }
            if contentEnd > contentStart, body[contentEnd - 1] == 13 { contentEnd -= 1 }
            guard contentStart < contentEnd else { continue }
            result.append(splitPart(Array(body[contentStart..<contentEnd])))
        }
        return result
    }

    static func bestText(_ part: Part, depth: Int) -> String? {
        guard depth < 8 else { return nil }
        let (type, params) = parseContentType(part.headers["content-type"])
        let disposition = part.headers["content-disposition"]?.lowercased() ?? ""
        if disposition.hasPrefix("attachment") { return nil }

        if type.hasPrefix("multipart/") {
            guard let boundary = params["boundary"], !boundary.isEmpty else { return nil }
            let kids = children(of: part, boundary: boundary)
            if type == "multipart/alternative" {
                if let plain = kids.first(where: { parseContentType($0.headers["content-type"]).0 == "text/plain" }),
                   let t = bestText(plain, depth: depth + 1), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return t
                }
                for k in kids.reversed() { if let t = bestText(k, depth: depth + 1), !t.isEmpty { return t } }
                return nil
            }
            for k in kids { if let t = bestText(k, depth: depth + 1), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t } }
            return nil
        }
        if type == "message/rfc822" {
            return bestText(splitPart(part.body), depth: depth + 1)
        }
        guard type == "text/plain" || type == "text/html" || type == "text/enriched" else { return nil }
        let decoded = decodeTransfer(part.body, encoding: part.headers["content-transfer-encoding"])
        let text = decodeCharset(decoded, charset: params["charset"])
        return type == "text/html" ? htmlToText(text) : text
    }

    // MARK: Transfer encodings and charsets

    static func decodeTransfer(_ bytes: [UInt8], encoding: String?) -> [UInt8] {
        switch encoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64":
            var s = String(decoding: bytes.filter { b in
                (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 43 || b == 47 || b == 61
            }, as: UTF8.self)
            if let pad = s.firstIndex(of: "=") { s = String(s[..<pad]) }
            let usable = s.count - (s.count % 4 == 1 ? 1 : 0)
            s = String(s.prefix(usable))
            while s.count % 4 != 0 { s += "=" }
            return Data(base64Encoded: s).map { Array($0) } ?? bytes
        case "quoted-printable":
            return decodeQuotedPrintable(bytes)
        default:
            return bytes
        }
    }

    static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 48...57: return b - 48
        case 65...70: return b - 55
        case 97...102: return b - 87
        default: return nil
        }
    }

    static func decodeQuotedPrintable(_ bytes: [UInt8], underscoreIsSpace: Bool = false) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 61 { // "="
                if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
                if i + 2 < bytes.count, let h = hexValue(bytes[i + 1]), let l = hexValue(bytes[i + 2]) {
                    out.append(h << 4 | l)
                    i += 3
                    continue
                }
                out.append(b)
                i += 1
            } else if underscoreIsSpace && b == 95 {
                out.append(32)
                i += 1
            } else {
                out.append(b)
                i += 1
            }
        }
        return out
    }

    static func encoding(forCharset charset: String?) -> String.Encoding? {
        guard let cs = charset?.trimmingCharacters(in: .whitespaces).lowercased(), !cs.isEmpty else { return nil }
        switch cs {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .utf8
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
            if cf == kCFStringEncodingInvalidId { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }

    static func decodeCharset(_ bytes: [UInt8], charset: String?) -> String {
        let data = Data(bytes)
        if let enc = encoding(forCharset: charset), let s = String(data: data, encoding: enc) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Headers

    /// RFC 2047: "=?UTF-8?Q?Einladung_zur_Sitzung?=" -> "Einladung zur Sitzung"
    public static func decodeEncodedWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        let pattern = "=\\?([^?\\s]+)\\?([bBqQ])\\?([^?]*)\\?="
        guard let re = try? NSRegularExpression(pattern: pattern) else { return value }
        // Whitespace between two adjacent encoded words is not part of the text.
        let joined = (try? NSRegularExpression(pattern: "(\\?=)\\s+(?==\\?[^?\\s]+\\?[bBqQ]\\?)"))?
            .stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "$1") ?? value
        let ns = joined as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: joined, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let charset = ns.substring(with: m.range(at: 1))
            let mode = ns.substring(with: m.range(at: 2)).uppercased()
            let text = ns.substring(with: m.range(at: 3))
            var bytes: [UInt8]
            if mode == "B" {
                bytes = decodeTransfer(Array(text.utf8), encoding: "base64")
            } else {
                bytes = decodeQuotedPrintable(Array(text.utf8), underscoreIsSpace: true)
            }
            let cs = charset.split(separator: "*").first.map(String.init)
            result += decodeCharset(bytes, charset: cs)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    static func parseDate(_ value: String) -> Date? {
        var v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let paren = v.range(of: " (") { v = String(v[..<paren.lowerBound]) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "EEE, d MMM yy HH:mm:ss Z", "dd-MMM-yyyy HH:mm:ss Z"] {
            f.dateFormat = format
            if let d = f.date(from: v) { return d }
        }
        return nil
    }

    // MARK: Text

    static let entities: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß",
        "euro": "€", "ndash": "–", "mdash": "—", "hellip": "…", "bdquo": "„", "ldquo": "“", "rdquo": "”",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "middot": "·", "bull": "•", "copy": "©", "reg": "®", "shy": "",
        "eacute": "é", "egrave": "è", "agrave": "à", "ccedil": "ç", "times": "×", "zwnj": "", "zwj": "",
    ]

    static func replace(_ pattern: String, in s: String, with template: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    public static func htmlToText(_ html: String) -> String {
        var s = html
        s = replace("<(script|style|head|title)[^>]*>[\\s\\S]*?</\\1>", in: s, with: " ")
        s = replace("<!--[\\s\\S]*?-->", in: s, with: " ")
        s = replace("<br\\s*/?>", in: s, with: "\n")
        s = replace("</(p|div|tr|li|h[1-6]|table|blockquote|section|article)>", in: s, with: "\n")
        s = replace("<li[^>]*>", in: s, with: "\n- ")
        s = replace("<td[^>]*>", in: s, with: " ")
        s = replace("<[^>]+>", in: s, with: "")
        return decodeEntities(s)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        guard let re = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[A-Za-z]+[0-9]?);") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            if name.hasPrefix("#x") || name.hasPrefix("#X"), let v = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) {
                out.unicodeScalars.append(u)
            } else if name.hasPrefix("#"), let v = UInt32(name.dropFirst()), let u = Unicode.Scalar(v) {
                out.unicodeScalars.append(u)
            } else if let rep = entities[name] {
                out += rep
            } else {
                out += ns.substring(with: m.range)
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func cleanText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        t = t.replacingOccurrences(of: "\u{00A0}", with: " ")
        t = replace("[ \\t]+", in: t, with: " ", options: [])
        t = replace(" *\\n *", in: t, with: "\n", options: [])
        t = replace("\\n{3,}", in: t, with: "\n\n", options: [])
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
