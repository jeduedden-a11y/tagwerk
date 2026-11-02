import SwiftUI
import TagwerkCore
import WebKit

enum NotesRoute: Hashable {
    case folder(String)
    case note(String, heading: String?)
}

struct NotesView: View {
    @Environment(Store.self) private var store
    @Binding var showSettings: Bool
    @State private var path: [NotesRoute] = []
    @State private var query = ""

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if query.trimmingCharacters(in: .whitespaces).count >= 2 {
                    NotesSearchResults(query: query)
                } else {
                    NotesHome(showSettings: $showSettings)
                }
            }
            .navigationTitle("Notizen")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "In allen Notizen suchen")
            .navigationDestination(for: NotesRoute.self) { route in
                switch route {
                case .folder(let f): NotesFolderView(folder: f)
                case .note(let p, let h): NoteReader(path: p, heading: h) { path.append($0) }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Einstellungen", systemImage: "gearshape")
                    }
                }
            }
        }
        .task {
            store.wiki.loadIfNeeded()
            if let p = UserDefaults.standard.string(forKey: "TWNote"), path.isEmpty { path = [.note(p, heading: nil)] }
            await store.syncWiki()
        }
    }
}

enum NotesRecents {
    static let key = "TWRecentNotes"
    static func list() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func add(_ path: String) {
        var l = list().filter { $0 != path }
        l.insert(path, at: 0)
        UserDefaults.standard.set(Array(l.prefix(8)), forKey: key)
    }
}

struct NotesFolderIcon {
    static func symbol(_ name: String) -> String {
        let n = WikiText.fold(name)
        let table: [(String, String)] = [
            ("mathe", "function"), ("tmua", "pencil.and.ruler"), ("physik", "atom"), ("chemie", "flask"), ("bio", "leaf"),
            ("geschichte", "building.columns"), ("deutsch", "text.book.closed"), ("philo", "brain"), ("ethik", "scalemass"),
            ("informatik", "cpu"), ("sport", "figure.run"), ("okonom", "chart.line.uptrend.xyaxis"), ("wirtschaft", "chart.line.uptrend.xyaxis"),
            ("youtube", "play.rectangle"), ("kurs", "graduationcap"), ("datalink", "link"), ("meta", "square.grid.2x2"), ("englisch", "globe.europe.africa"),
        ]
        return table.first { n.contains($0.0) }?.1 ?? "folder"
    }
}

struct NotesHome: View {
    @Environment(Store.self) private var store
    @Binding var showSettings: Bool

    var body: some View {
        let wiki = store.wiki
        let top = wiki.children(of: "")
        let recents = NotesRecents.list().compactMap { wiki.note($0) }
        List {
            Section {
                NotesStatusRow()
            }
            if wiki.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Noch keine Notizen", systemImage: "books.vertical")
                    } description: {
                        Text(store.isConnected
                             ? "Sobald Tagwerk Bridge 1.2 in Obsidian läuft, kommt dein Wiki hierher und ist danach auch offline lesbar."
                             : "Verbinde zuerst den Vault in den Einstellungen.")
                    } actions: {
                        if !store.isConnected { Button("Einstellungen") { showSettings = true } }
                    }
                }
            }
            if !recents.isEmpty {
                Section("Zuletzt geöffnet") {
                    ForEach(recents.prefix(5)) { n in
                        NavigationLink(value: NotesRoute.note(n.path, heading: nil)) { NoteRow(note: n, showFolder: true) }
                    }
                }
            }
            if !top.folders.isEmpty {
                Section("Bereiche") {
                    ForEach(top.folders) { f in
                        NavigationLink(value: NotesRoute.folder(f.path)) {
                            Label {
                                LabeledContent(f.name, value: "\(f.count)")
                            } icon: {
                                Image(systemName: NotesFolderIcon.symbol(f.name)).foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            if !top.notes.isEmpty {
                Section("Notizen") {
                    ForEach(top.notes) { n in
                        NavigationLink(value: NotesRoute.note(n.path, heading: nil)) { NoteRow(note: n, showFolder: false) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.syncWiki(force: false) }
    }
}

struct NotesStatusRow: View {
    @Environment(Store.self) private var store

    var body: some View {
        let wiki = store.wiki
        HStack(spacing: 12) {
            Image(systemName: wiki.syncing ? "arrow.triangle.2.circlepath" : "books.vertical.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.rotate, isActive: wiki.syncing)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(wiki.isEmpty ? "Wiki" : "\(wiki.notes.count) Notizen offline")
                    .font(.subheadline.weight(.semibold))
                Group {
                    if wiki.syncing {
                        Text("Lade Notizen vom PC … \(Int(wiki.progress * 100)) %")
                    } else if let s = wiki.status {
                        Text(s)
                    } else if let g = wiki.generatedAt {
                        Text("Stand vom PC: \(Format.relative(g))")
                    } else {
                        Text("Noch kein Stand vom PC")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct NoteRow: View {
    let note: WikiNote
    var showFolder: Bool
    var snippet: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(note.title)
                .font(.body)
                .lineLimit(2)
            if showFolder && !note.folder.isEmpty {
                Text(note.folder.replacingOccurrences(of: "/", with: " › "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let snippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }
}

struct NotesSearchResults: View {
    @Environment(Store.self) private var store
    let query: String

    var body: some View {
        let hits = store.wiki.search(query)
        List {
            if !store.wiki.searchReady {
                Text("Volltext wird vorbereitet, bis dahin nur Titel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(hits) { h in
                NavigationLink(value: NotesRoute.note(h.note.path, heading: nil)) {
                    NoteRow(note: h.note, showFolder: true, snippet: h.snippet)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if hits.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }
}

struct NotesFolderView: View {
    @Environment(Store.self) private var store
    let folder: String

    var body: some View {
        let c = store.wiki.children(of: folder)
        List {
            if !c.folders.isEmpty {
                Section {
                    ForEach(c.folders) { f in
                        NavigationLink(value: NotesRoute.folder(f.path)) {
                            Label {
                                LabeledContent(f.name, value: "\(f.count)")
                            } icon: {
                                Image(systemName: "folder").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            }
            Section {
                ForEach(c.notes) { n in
                    NavigationLink(value: NotesRoute.note(n.path, heading: nil)) { NoteRow(note: n, showFolder: false) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle((folder as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NoteReader: View {
    @Environment(Store.self) private var store
    let path: String
    let heading: String?
    let push: (NotesRoute) -> Void
    @State private var web: WKWebView?
    @State private var shared: SharedFile?
    @State private var exporting = false

    var body: some View {
        let wiki = store.wiki
        let title = WikiText.title(path)
        let raw = wiki.markdown(path)
        let parts = WikiText.split(raw ?? "")
        let payload = NotePayload(md: parts.body, path: path, title: title, folder: WikiText.folder(path).replacingOccurrences(of: "/", with: " › "),
                                  tags: WikiText.tags(parts.frontmatter), heading: heading)
        Group {
            if raw == nil {
                ContentUnavailableView("Notiz nicht gefunden", systemImage: "doc.questionmark",
                                       description: Text("Sie wurde in Obsidian verschoben oder gelöscht."))
            } else {
                NoteWebView(payload: payload, lookup: { target, from in
                    guard let p = wiki.resolver.resolve(target, from: from.isEmpty ? path : from) else { return nil }
                    return wiki.data(p)
                }, onOpen: open, onReady: { w in Task { @MainActor in web = w } })
                .ignoresSafeArea(edges: .bottom)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        exportPDF(title: title)
                    } label: {
                        Label("Als PDF teilen", systemImage: "doc.richtext")
                    }
                    .disabled(web == nil)
                    Button {
                        if let raw, let url = NoteExport.markdown(raw, title: title) { shared = SharedFile(url: url) }
                    } label: {
                        Label("Als Markdown teilen", systemImage: "doc.plaintext")
                    }
                } label: {
                    if exporting { ProgressView() } else { Label("Teilen", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .sheet(item: $shared) { f in
            ShareSheet(items: [f.url])
                .presentationDetents([.medium, .large])
        }
        .onAppear { NotesRecents.add(path) }
    }

    private func open(_ target: String) {
        let heading = target.firstIndex(of: "#").map { String(target[target.index(after: $0)...]) }
        guard let p = store.wiki.resolver.resolve(target, from: path) else {
            store.flash("„\(target)“ ist nicht im Wiki")
            return
        }
        if p.lowercased().hasSuffix(".md") { push(.note(p, heading: heading)) }
    }

    private func exportPDF(title: String) {
        guard let web, !exporting else { return }
        exporting = true
        Task { @MainActor in
            if let url = await NoteExport.pdf(from: web, title: title) { shared = SharedFile(url: url) }
            exporting = false
        }
    }
}
