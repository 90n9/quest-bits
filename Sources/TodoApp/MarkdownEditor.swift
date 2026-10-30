import SwiftUI
import WebKit

/// The task Detail editor: a Notion-style block editor (Milkdown, bundled in
/// Resources/Editor by Scripts/build-app.sh) in a web view. The text stays markdown:
/// `markdown` is shown when the editor loads or `docId` (the task) changes, and written back
/// only when the user edits it (Editor/src/main.js documents the messages). One web view
/// serves each task in turn, so every change carries its task: one for the shown task
/// updates `markdown`, one that arrives after the user moved on goes to `onOtherDoc`, and
/// edits not sent yet when the view closes are flushed there too. Images pasted, dropped or
/// uploaded are saved by `Store.saveAttachment` and linked as `attachments/<name>`; the web
/// view loads them through the qb-attachment: scheme. ⌘-click opens a web link or an
/// attachment.
struct MarkdownEditor: NSViewRepresentable {
    let docId: Int64
    @Binding var markdown: String
    @Binding var height: CGFloat
    let store: Store
    /// Save `markdown` as the detail of task `docId`, which is no longer the one shown.
    var onOtherDoc: (Int64, String) -> Void
    var onError: (String) -> Void = { _ in }

    static let scheme = "qb-attachment"

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "qb")
        config.setURLSchemeHandler(AttachmentSchemeHandler(store: store), forURLScheme: Self.scheme)
        let view = PassthroughScrollWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = view
        context.coordinator.docId = docId
        context.coordinator.known = markdown
        if let page = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Editor") {
            context.coordinator.page = page
            // Read access to all of Resources: the page loads the app's fonts from ../Fonts.
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent().deletingLastPathComponent())
        } else {
            onError("The Detail editor is missing from this build")
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let c = context.coordinator
        c.parent = self
        // Another task, or a change from outside the editor (an agent's write), is pushed
        // in; the editor's own change comes back equal to `known`.
        if docId != c.docId || markdown != c.known {
            c.docId = docId
            c.known = markdown
            c.push()
        }
    }

    /// Save what the user typed in the last moments before the view goes (another view in
    /// the detail column, several tasks selected): it is not sent yet.
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "qb")
        guard coordinator.ready else { return }
        view.evaluateJavaScript("qb.flush()") { result, _ in
            _ = view   // keep the page alive until it answers
            guard let d = result as? [String: Any], let id = (d["docId"] as? NSNumber)?.int64Value,
                  let md = d["markdown"] as? String else { return }
            coordinator.parent.onOtherDoc(id, md)
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MarkdownEditor
        weak var webView: WKWebView?
        var page: URL?
        /// The task shown, and the markdown the editor and the binding agree on for it.
        var docId: Int64 = 0
        var known = ""
        fileprivate(set) var ready = false

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func push() {
            guard ready, let view = webView, let arg = Self.jsString(known) else { return }
            view.evaluateJavaScript("qb.setMarkdown(\(arg), \(docId))")
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                push()
            case "change":
                guard let md = body["markdown"] as? String,
                      let id = (body["docId"] as? NSNumber)?.int64Value else { return }
                if id == docId {
                    guard md != known else { return }
                    known = md
                    parent.markdown = md
                } else {
                    parent.onOtherDoc(id, md)
                }
            case "height":
                if let h = body["height"] as? Double, abs(CGFloat(h) - parent.height) >= 1 { parent.height = CGFloat(h) }
            case "upload":
                upload(body)
            case "open":
                if let href = body["href"] as? String { open(href) }
            default:
                break
            }
        }

        /// Decode and save off the main thread (a pasted screenshot can be tens of MB),
        /// then answer the page on it.
        private func upload(_ body: [String: Any]) {
            guard let id = body["id"] as? Int else { return }
            let b64 = body["data"] as? String
            // image/png → png, image/svg+xml → svg; else the file name's extension.
            let ext = (body["mime"] as? String).flatMap { $0.split(separator: "/").last?.split(separator: "+").first.map(String.init) }
                ?? ((body["name"] as? String).map { ($0 as NSString).pathExtension } ?? "png")
            let store = parent.store
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result<String, Error> {
                    guard let b64, let data = Data(base64Encoded: b64) else {
                        throw StoreError.invalid("the image could not be read")
                    }
                    return try store.saveAttachment(data, fileExtension: ext == "jpeg" ? "jpg" : ext)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let path):
                        if let arg = Self.jsString(path) { self.webView?.evaluateJavaScript("qb.uploadDone(\(id), \(arg))") }
                    case .failure(let error):
                        self.parent.onError("Couldn't attach the image: \(error)")
                        self.webView?.evaluateJavaScript("qb.uploadFailed(\(id))")
                    }
                }
            }
        }

        /// A link as written in the markdown: an attachment opens from the attachments
        /// folder; web and mail links open in their app. Anything else (file:, app or
        /// custom schemes, perhaps from text an agent wrote) is not opened.
        private func open(_ href: String) {
            if let file = parent.store.attachmentFile(href) {
                if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.open(file) }
                return
            }
            guard let url = URL(string: href), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else { return }
            NSWorkspace.shared.open(url)
        }

        /// Only the editor page itself loads in the view. A followed web link opens outside;
        /// anything else (a dropped file, say) is refused.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if let page, url.isFileURL, url.standardizedFileURL.path == page.standardizedFileURL.path {
                return decisionHandler(.allow)
            }
            if action.navigationType == .linkActivated { open(url.absoluteString) }
            decisionHandler(.cancel)
        }

        /// The page's process died (memory, a WebKit crash): load it again; on `ready` it
        /// gets the task's text back.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            webView.reload()
        }

        /// A Swift string as a JavaScript string literal.
        static func jsString(_ s: String) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: [s]),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return String(json.dropFirst().dropLast())
        }
    }
}

/// Serves attachments (qb-attachment:///<name>) from the store's attachments folder.
private final class AttachmentSchemeHandler: NSObject, WKURLSchemeHandler {
    let store: Store
    init(store: Store) { self.store = store }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let name = task.request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        guard let file = store.attachmentFile(Store.attachmentPrefix + name), let data = try? Data(contentsOf: file),
              let url = task.request.url else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let ext = file.pathExtension.lowercased()
        let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                    "webp": "image/webp", "heic": "image/heic", "svg": "image/svg+xml"][ext] ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// WKUserContentController keeps its handlers strongly: this breaks the cycle with the
/// coordinator (which holds the web view).
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(c, didReceive: message)
    }
}

/// The editor is sized to its content inside the detail ScrollView, so wheel events go to
/// that ScrollView instead of being swallowed by the web view.
private final class PassthroughScrollWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}
