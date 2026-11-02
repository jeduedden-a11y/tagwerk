import SwiftUI
import TagwerkCore
import UIKit
import WebKit

/// What the renderer gets: the Markdown without frontmatter plus a few properties.
struct NotePayload: Encodable, Equatable {
    var md: String
    var path: String
    var title: String
    var folder: String
    var tags: [String]
    var heading: String?
}

/// Serves the renderer (twnote://app/...) and the wiki's images and HTML files (twnote://app/embed?t=...&from=...).
/// Embeds share the page's origin so the renderer can read an SVG's source and pick a backdrop it stays legible on.
@MainActor
final class NoteSchemeHandler: NSObject, WKURLSchemeHandler {
    let lookup: @MainActor (_ target: String, _ from: String) -> Data?

    init(lookup: @escaping @MainActor (_ target: String, _ from: String) -> Data?) {
        self.lookup = lookup
    }

    nonisolated static func bundleData(_ name: String) -> Data? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for sub in [nil, "Notes", "fonts", "Notes/fonts"] as [String?] {
            if let url = Bundle.main.url(forResource: base, withExtension: ext, subdirectory: sub), let d = try? Data(contentsOf: url) { return d }
        }
        return nil
    }

    nonisolated static func mime(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js": return "text/javascript"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var data: Data?
        var name = url.lastPathComponent
        let isEmbed = (url.host == "app" && url.path == "/embed") || url.host == "embed"
        if isEmbed {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let target = items.first { $0.name == "t" }?.value ?? ""
            let from = items.first { $0.name == "from" }?.value ?? ""
            name = target
            data = lookup(target, from)
        } else if url.host == "app" {
            data = Self.bundleData(name)
        }
        guard let data else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = Self.mime(name)
        let textual = mime.hasPrefix("text/") || mime.hasSuffix("svg+xml")
        // An HTTP response with status 200, so fetch() in the page sees an ordinary successful load.
        let headers = [
            "Content-Type": textual ? "\(mime); charset=utf-8" : mime,
            "Content-Length": String(data.count),
            "Cache-Control": "no-cache",
        ]
        let response: URLResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: textual ? "utf-8" : nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

struct NoteWebView: UIViewRepresentable {
    let payload: NotePayload
    let lookup: @MainActor (_ target: String, _ from: String) -> Data?
    let onOpen: (String) -> Void
    var onReady: ((WKWebView) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onOpen: onOpen) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(NoteSchemeHandler(lookup: lookup), forURLScheme: "twnote")
        config.dataDetectorTypes = [.link]
        // Figure panels and callout tints belong to the content; the PDF export keeps them.
        config.preferences.shouldPrintBackgrounds = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        web.navigationDelegate = context.coordinator
        web.allowsLinkPreview = false
        context.coordinator.web = web
        if let url = URL(string: "twnote://app/notes.html") { web.load(URLRequest(url: url)) }
        onReady?(web)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.onOpen = onOpen
        context.coordinator.show(payload)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var onOpen: (String) -> Void
        weak var web: WKWebView?
        private var loaded = false
        private var pending: NotePayload?
        private var shown: NotePayload?

        init(onOpen: @escaping (String) -> Void) {
            self.onOpen = onOpen
        }

        func show(_ p: NotePayload) {
            guard p != shown else { return }
            pending = p
            if loaded { flush() }
        }

        private func flush() {
            guard let p = pending, let web, let json = try? JSONEncoder().encode(p), let text = String(data: json, encoding: .utf8) else { return }
            pending = nil
            shown = p
            web.evaluateJavaScript("TW.render(\(text))", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            flush()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .allow }
            if url.scheme == "twnote", url.host == "open" {
                let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "t" }?.value ?? ""
                onOpen(target)
                return .cancel
            }
            if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
                if action.navigationType == .linkActivated { _ = await UIApplication.shared.open(url) }
                return .cancel
            }
            return .allow
        }
    }
}

enum NoteExport {
    /// Paginated A4 PDF of what the web view shows, rendered in light mode.
    @MainActor
    static func pdf(from web: WKWebView, title: String) async -> URL? {
        let previous = web.overrideUserInterfaceStyle
        web.overrideUserInterfaceStyle = .light
        try? await Task.sleep(nanoseconds: 350_000_000)
        defer { web.overrideUserInterfaceStyle = previous }
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(web.viewPrintFormatter(), startingAtPageAt: 0)
        let paper = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: paper.insetBy(dx: 40, dy: 44)), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, [kCGPDFContextTitle as String: title])
        for i in 0..<max(1, renderer.numberOfPages) {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return write(data as Data, name: "\(fileName(title)).pdf")
    }

    static func markdown(_ text: String, title: String) -> URL? {
        write(Data(text.utf8), name: "\(fileName(title)).md")
    }

    private static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: " ")
        return cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? "Notiz" : cleaned
    }

    private static func write(_ data: Data, name: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// UIActivityViewController for a file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}
