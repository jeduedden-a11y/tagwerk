import Foundation
import Observation
import TagwerkCore

struct WikiNote: Identifiable, Hashable {
    let path: String
    let title: String
    let folder: String
    var id: String { path }
}

struct WikiFolder: Identifiable, Hashable {
    let name: String
    let path: String
    let count: Int
    var id: String { path }
}

struct WikiHit: Identifiable, Hashable {
    let note: WikiNote
    let snippet: String?
    var id: String { note.path }
}

/// Offline copy of the vault's wiki: downloaded bucket by bucket, stored as plain files, searched on the device.
@MainActor
@Observable
final class WikiStore {
    private(set) var notes: [WikiNote] = []
    private(set) var fileCount = 0
    private(set) var generatedAt: Date?
    private(set) var root = "02 Wiki"
    var syncing = false
    var progress: Double = 0
    var status: String?
    var lastSync: Date?
    private(set) var searchReady = false

    @ObservationIgnored private var manifest: WikiManifest?
    @ObservationIgnored private var bucketHashes: [String: String] = [:]
    @ObservationIgnored private var etag: String?
    @ObservationIgnored private(set) var resolver = WikiLinkResolver(paths: [])
    @ObservationIgnored private var index: [(path: String, folded: String, plain: String)] = []
    @ObservationIgnored private var demoFiles: [String: String]?
    @ObservationIgnored private var loaded = false

    nonisolated static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Wiki", isDirectory: true)
    }

    nonisolated static var filesDir: URL { dir.appendingPathComponent("files", isDirectory: true) }

    private struct Persisted: Codable {
        var manifest: WikiManifest
        var buckets: [String: String]
        var etag: String?
        var lastSync: Date?
    }

    var isEmpty: Bool { notes.isEmpty }

    // MARK: Loading

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard demoFiles == nil else { return }
        let url = Self.dir.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        manifest = p.manifest
        bucketHashes = p.buckets
        etag = p.etag
        lastSync = p.lastSync
        rebuild()
    }

    func loadDemo(_ files: [String: String]) {
        demoFiles = files
        loaded = true
        let paths = files.keys.sorted()
        manifest = WikiManifest(v: 1, generatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600)), root: "02 Wiki",
                                buckets: [], files: paths.map { WikiManifest.File(p: $0, b: "b00", s: files[$0]?.utf8.count ?? 0, m: 0) })
        rebuild()
    }

    private func persist() {
        guard let manifest else { return }
        let p = Persisted(manifest: manifest, buckets: bucketHashes, etag: etag, lastSync: lastSync)
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(p).write(to: Self.dir.appendingPathComponent("state.json"), options: .atomic)
    }

    private func rebuild() {
        guard let manifest else { return }
        root = manifest.root
        generatedAt = ISO8601DateFormatter.withFraction.date(from: manifest.generatedAt) ?? ISO8601DateFormatter().date(from: manifest.generatedAt)
        fileCount = manifest.files.count
        let paths = manifest.files.map(\.p)
        resolver = WikiLinkResolver(paths: paths)
        notes = paths.filter { $0.lowercased().hasSuffix(".md") }
            .map { WikiNote(path: $0, title: WikiText.title($0), folder: WikiText.folder($0)) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        searchReady = false
        index = []
        let demo = demoFiles
        let list = notes.map(\.path)
        Task.detached(priority: .utility) {
            var built: [(path: String, folded: String, plain: String)] = []
            built.reserveCapacity(list.count)
            for p in list {
                let text = demo?[p] ?? (try? String(contentsOf: WikiStore.filesDir.appendingPathComponent(p), encoding: .utf8)) ?? ""
                let plain = WikiText.plain(text)
                built.append((p, WikiText.fold(plain), plain))
            }
            await MainActor.run { [built] in
                self.index = built
                self.searchReady = true
            }
        }
    }

    // MARK: Content

    func markdown(_ path: String) -> String? {
        if let demoFiles { return demoFiles[path] }
        return try? String(contentsOf: Self.filesDir.appendingPathComponent(path), encoding: .utf8)
    }

    func data(_ path: String) -> Data? {
        if let demoFiles { return demoFiles[path].map { Data($0.utf8) } }
        return try? Data(contentsOf: Self.filesDir.appendingPathComponent(path))
    }

    func note(_ path: String) -> WikiNote? { notes.first { $0.path == path } }

    /// Subfolders (with note counts) and notes directly inside a folder ("" is the root).
    func children(of folder: String) -> (folders: [WikiFolder], notes: [WikiNote]) {
        let prefix = folder.isEmpty ? "" : folder + "/"
        var counts: [String: Int] = [:]
        var direct: [WikiNote] = []
        for n in notes where n.path.hasPrefix(prefix) {
            let rest = n.path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                counts[String(rest[..<slash]), default: 0] += 1
            } else {
                direct.append(n)
            }
        }
        let folders = counts.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { WikiFolder(name: $0, path: prefix + $0, count: counts[$0] ?? 0) }
        return (folders, direct.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }

    func search(_ query: String, limit: Int = 60) -> [WikiHit] {
        let q = WikiText.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard q.count >= 2 else { return [] }
        var titleHits: [WikiHit] = []
        var textHits: [WikiHit] = []
        var seen = Set<String>()
        for n in notes where WikiText.fold(n.title).contains(q) {
            titleHits.append(WikiHit(note: n, snippet: nil))
            seen.insert(n.path)
        }
        for entry in index where !seen.contains(entry.path) && entry.folded.contains(q) {
            guard let n = note(entry.path) else { continue }
            textHits.append(WikiHit(note: n, snippet: WikiText.snippet(entry.plain, folded: entry.folded, query: query)))
            if titleHits.count + textHits.count >= limit { break }
        }
        titleHits.sort { $0.note.title.count < $1.note.title.count }
        return Array((titleHits + textHits).prefix(limit))
    }

    // MARK: Download

    func sync(github gh: GitHubClient, passphrase: String, force: Bool = false) async {
        loadIfNeeded()
        guard !syncing, demoFiles == nil else { return }
        syncing = true
        progress = 0
        defer { syncing = false }
        do {
            guard let file = try await gh.getRaw(path: "wiki/index.tw", etag: force ? nil : etag) else {
                if manifest == nil { status = "Noch keine Notizen vom PC. Dafür braucht Obsidian Tagwerk Bridge 1.2 mit eingeschaltetem Wiki." }
                lastSync = Date()
                return
            }
            let indexData = file.data
            let m = try await Task.detached { try WikiCodec.open(indexData, passphrase: passphrase, as: WikiManifest.self) }.value
            let changed = m.buckets.filter { force || bucketHashes[$0.id] != $0.hash }
            for (i, b) in changed.enumerated() {
                progress = Double(i) / Double(max(1, changed.count))
                guard let bf = try await gh.getRaw(path: "wiki/\(b.id).tw") else { continue }
                let data = bf.data
                try await Task.detached {
                    let bucket = try WikiCodec.open(data, passphrase: passphrase, as: WikiBucket.self)
                    try WikiStore.write(bucket)
                }.value
                bucketHashes[b.id] = b.hash
            }
            let keep = Set(m.files.map(\.p))
            let old = manifest?.files.map(\.p) ?? []
            let stale = old.filter { !keep.contains($0) }
            await Task.detached { WikiStore.remove(stale) }.value
            bucketHashes = bucketHashes.filter { id, _ in m.buckets.contains { $0.id == id } }
            manifest = m
            etag = file.etag
            lastSync = Date()
            status = nil
            progress = 1
            persist()
            rebuild()
        } catch {
            status = error.localizedDescription
        }
    }

    nonisolated private static func safeURL(_ path: String) -> URL? {
        let parts = path.split(separator: "/")
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return filesDir.appendingPathComponent(path)
    }

    nonisolated static func write(_ bucket: WikiBucket) throws {
        let fm = FileManager.default
        for item in bucket.files {
            guard let url = safeURL(item.p), let data = item.data else { continue }
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    nonisolated static func remove(_ paths: [String]) {
        for p in paths {
            guard let url = safeURL(p) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
