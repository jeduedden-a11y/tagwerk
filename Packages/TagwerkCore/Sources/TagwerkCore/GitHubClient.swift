import Foundation

public struct GitHubConfig: Codable, Hashable, Sendable {
    public var owner: String
    public var repo: String
    public var branch: String

    public init(owner: String, repo: String, branch: String = "main") {
        self.owner = owner
        self.repo = repo
        self.branch = branch
    }

    public var isComplete: Bool { !owner.isEmpty && !repo.isEmpty }
}

public enum GitHubClientError: LocalizedError, Equatable {
    case badToken
    case forbidden
    case notFound
    case publicRepo
    case http(Int, String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .badToken: return "GitHub lehnt das Token ab. Bitte in den Einstellungen erneuern."
        case .forbidden: return "GitHub verweigert den Zugriff. Hat das Token Contents: Lesen und Schreiben für das Daten-Repo?"
        case .notFound: return "Repo nicht gefunden. Stimmen Besitzer und Name, und darf das Token darauf zugreifen?"
        case .publicRepo: return "Das Daten-Repo ist öffentlich. Bitte auf privat stellen, auch wenn der Inhalt verschlüsselt ist."
        case .http(let code, let msg): return "GitHub-Fehler \(code): \(msg)"
        case .invalidResponse: return "Unerwartete Antwort von GitHub."
        }
    }
}

public struct RemoteFile: Sendable {
    public var sha: String
    public var data: Data
    public var etag: String?
}

/// GitHub Contents API, just what the app needs: create inbox files, read the snapshot.
public struct GitHubClient: Sendable {
    public var config: GitHubConfig
    public var token: String
    public var session: URLSession

    public init(config: GitHubConfig, token: String, session: URLSession = .shared) {
        self.config = config
        self.token = token
        self.session = session
    }

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "api.github.com"
        let segments = path.split(separator: "/").map { String($0) }
        c.percentEncodedPath = "/repos/\(enc(config.owner))/\(enc(config.repo))/contents" + (segments.isEmpty ? "" : "/" + segments.map(enc).joined(separator: "/"))
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    private func enc(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func request(_ url: URL, method: String, body: Data? = nil, etag: String? = nil) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        r.setValue("tagwerk-ios", forHTTPHeaderField: "User-Agent")
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send(_ req: URLRequest, ok: Set<Int>, allow404: Bool = false, allow304: Bool = false) async throws -> (Data, HTTPURLResponse)? {
        var lastStatus = 0
        var lastBody = ""
        for attempt in 0..<4 {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw GitHubClientError.invalidResponse }
            if ok.contains(http.statusCode) { return (data, http) }
            if allow404 && http.statusCode == 404 { return nil }
            if allow304 && http.statusCode == 304 { return nil }
            lastStatus = http.statusCode
            lastBody = String(data: data, encoding: .utf8) ?? ""
            switch http.statusCode {
            case 401: throw GitHubClientError.badToken
            case 403 where !lastBody.lowercased().contains("rate limit"): throw GitHubClientError.forbidden
            case 404: throw GitHubClientError.notFound
            case 409, 422, 429, 403, 500...599:
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 700_000_000)
            default:
                throw GitHubClientError.http(http.statusCode, String(lastBody.prefix(200)))
            }
        }
        throw GitHubClientError.http(lastStatus, String(lastBody.prefix(200)))
    }

    /// Creates a new file (never overwrites; inbox names are unique).
    public func createFile(path: String, data: Data, message: String) async throws {
        let body: [String: Any] = ["message": message, "content": data.base64EncodedString(), "branch": config.branch]
        let req = request(url(path), method: "PUT", body: try JSONSerialization.data(withJSONObject: body))
        _ = try await send(req, ok: [200, 201])
    }

    /// nil if the file does not exist, or if etag matches (not modified).
    public func getFile(path: String, etag: String? = nil) async throws -> RemoteFile? {
        let req = request(url(path, query: [URLQueryItem(name: "ref", value: config.branch)]), method: "GET", etag: etag)
        guard let result = try await send(req, ok: [200], allow404: true, allow304: true) else { return nil }
        let (data, http) = result
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = obj["sha"] as? String,
              let content = obj["content"] as? String,
              let bytes = Data(base64Encoded: content.replacingOccurrences(of: "\n", with: "")) else {
            throw GitHubClientError.invalidResponse
        }
        return RemoteFile(sha: sha, data: bytes, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    /// Verifies token and repo; refuses a public data repo.
    public func checkRepo() async throws {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "api.github.com"
        c.percentEncodedPath = "/repos/\(enc(config.owner))/\(enc(config.repo))"
        let req = request(c.url!, method: "GET")
        guard let result = try await send(req, ok: [200]) else { throw GitHubClientError.notFound }
        let data = result.0
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let isPrivate = obj?["private"] as? Bool, !isPrivate { throw GitHubClientError.publicRepo }
    }
}
