import Foundation

/// Index of the wiki copy the plugin uploads (wiki/index.tw).
public struct WikiManifest: Codable, Sendable {
    public struct Bucket: Codable, Hashable, Sendable {
        public var id: String
        public var hash: String
        public var n: Int
        public var bytes: Int

        public init(id: String, hash: String, n: Int, bytes: Int) {
            self.id = id
            self.hash = hash
            self.n = n
            self.bytes = bytes
        }
    }

    public struct File: Codable, Hashable, Sendable {
        /// Path relative to the wiki folder.
        public var p: String
        /// Bucket id.
        public var b: String
        public var s: Int
        public var m: Double

        public init(p: String, b: String, s: Int, m: Double) {
            self.p = p
            self.b = b
            self.s = s
            self.m = m
        }
    }

    public var v: Int
    public var generatedAt: String
    public var root: String
    public var buckets: [Bucket]
    public var files: [File]

    public init(v: Int, generatedAt: String, root: String, buckets: [Bucket], files: [File]) {
        self.v = v
        self.generatedAt = generatedAt
        self.root = root
        self.buckets = buckets
        self.files = files
    }
}

/// One bucket file (wiki/<id>.tw): the files themselves.
public struct WikiBucket: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public var p: String
        public var m: Double
        /// "text" or "b64".
        public var t: String
        public var d: String

        public var data: Data? { t == "b64" ? Data(base64Encoded: d) : Data(d.utf8) }
    }

    public var v: Int
    public var files: [Item]
}

public enum WikiError: LocalizedError {
    case format

    public var errorDescription: String? { "Die Notizen vom PC ließen sich nicht lesen." }
}

/// Sealed envelope -> base64 -> raw DEFLATE -> JSON, the inverse of the plugin's packWiki.
public enum WikiCodec {
    public static func open<T: Decodable>(_ envelope: Data, passphrase: String, as type: T.Type) throws -> T {
        let opened = try TagwerkCrypto.open(envelope, passphrase: passphrase, kind: .wiki)
        guard let text = String(data: opened, encoding: .utf8), let packed = Data(base64Encoded: text) else { throw WikiError.format }
        return try JSONDecoder().decode(T.self, from: try inflate(packed))
    }

    public static func inflate(_ data: Data) throws -> Data {
        do {
            return try (data as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw WikiError.format
        }
    }
}

public enum WikiText {
    /// Lower case without diacritics: search "groesse" finds "Größe" only via ß; "Grosse" via folding.
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "de_DE"))
            .replacingOccurrences(of: "ß", with: "ss")
    }

    public static func title(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    public static func folder(_ path: String) -> String { (path as NSString).deletingLastPathComponent }

    /// Splits YAML frontmatter from the body.
    public static func split(_ md: String) -> (frontmatter: String?, body: String) {
        let text = md.hasPrefix("\u{FEFF}") ? String(md.dropFirst()) : md
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return (nil, text) }
        let lines = text.components(separatedBy: "\n")
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            let fm = lines[1..<i].joined(separator: "\n")
            let body = lines[(i + 1)...].joined(separator: "\n")
            return (fm, body)
        }
        return (nil, text)
    }

    /// Tags from the frontmatter, list or inline form, without "#".
    public static func tags(_ frontmatter: String?) -> [String] {
        guard let fm = frontmatter else { return [] }
        var out: [String] = []
        let lines = fm.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where line.hasPrefix("tags:") {
            let rest = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if rest.hasPrefix("[") {
                out += rest.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if !rest.isEmpty {
                out.append(rest)
            } else {
                for l in lines[(i + 1)...] {
                    let t = l.trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("- ") else { break }
                    out.append(String(t.dropFirst(2)))
                }
            }
        }
        return out.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' #/")) }.filter { !$0.isEmpty }
    }

    /// Plain text for search and snippets: no frontmatter, comments, callout markers or link syntax.
    public static func plain(_ md: String) -> String {
        var s = split(md).body
        s = s.replacingOccurrences(of: "%%[\\s\\S]*?%%", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "!\\[\\[[^\\]]*\\]\\]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[\\[([^\\]|#]*)(#[^\\]|]*)?\\|([^\\]]*)\\]\\]", with: "$3", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[\\[([^\\]|#]*)(#[^\\]]*)?\\]\\]", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[!([a-zA-Z-]+)\\][+-]?", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?m)^[>#\\s]+", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "[*_`=]{1,3}", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Text around the first hit of the (folded) query.
    public static func snippet(_ plain: String, folded: String, query: String, radius: Int = 70) -> String? {
        let q = fold(query)
        guard !q.isEmpty, let r = folded.range(of: q) else { return nil }
        let start = folded.distance(from: folded.startIndex, to: r.lowerBound)
        guard start <= plain.count else { return nil }
        let from = max(0, start - radius)
        let to = min(plain.count, start + q.count + radius)
        let a = plain.index(plain.startIndex, offsetBy: from)
        let b = plain.index(plain.startIndex, offsetBy: to)
        return (from > 0 ? "…" : "") + plain[a..<b].trimmingCharacters(in: .whitespaces) + (to < plain.count ? "…" : "")
    }
}

/// Resolves wikilinks and embeds the way Obsidian does: path, then file name, nearest to the linking note.
public struct WikiLinkResolver: Sendable {
    private let exact: [String: String]
    private let byName: [String: [String]]

    public init(paths: [String]) {
        var exact: [String: String] = [:]
        var byName: [String: [String]] = [:]
        for p in paths {
            let lower = p.lowercased()
            exact[lower] = p
            let name = (lower as NSString).lastPathComponent
            let key = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
            byName[key, default: []].append(p)
        }
        self.exact = exact
        self.byName = byName
    }

    /// Target without "#heading" or "|alias"; nil if nothing matches.
    public func resolve(_ target: String, from source: String? = nil) -> String? {
        var t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bar = t.firstIndex(of: "|") { t = String(t[..<bar]) }
        if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
        t = t.removingPercentEncoding ?? t
        if t.isEmpty { return source }
        let lower = t.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let p = exact[lower] ?? exact[lower + ".md"] { return p }
        let name = (lower as NSString).lastPathComponent
        let key = name.hasSuffix(".md") ? String(name.dropLast(3)) : name
        guard let candidates = byName[key], !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }
        if lower.contains("/"), let m = candidates.first(where: { $0.lowercased().hasSuffix(lower) || $0.lowercased().hasSuffix(lower + ".md") }) { return m }
        if let source {
            let folder = (source as NSString).deletingLastPathComponent
            if let same = candidates.first(where: { ($0 as NSString).deletingLastPathComponent == folder }) { return same }
        }
        return candidates.min { ($0.count, $0) < ($1.count, $1) }
    }
}
