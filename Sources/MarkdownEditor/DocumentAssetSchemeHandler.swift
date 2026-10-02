import Foundation
import WebKit
import UniformTypeIdentifiers

/// Serves document-relative resources (pasted images, `![](x.png)`
/// references, …) to the editor's WKWebView.
///
/// The editor HTML is loaded via `loadHTMLString` with the base URL
/// `mdasset://doc/`, so a relative `src="notes.assets/paste.png"` in the
/// WYSIWYG DOM resolves to `mdasset://doc/notes.assets/paste.png` and lands
/// here. We map the path back onto the directory that holds the current
/// document (`store.fileURL`) and stream the file. The markdown source
/// itself keeps the plain relative path — nothing is rewritten.
///
/// Because the base is looked up per request, a Save As / rename of the
/// document re-targets every subsequent image load without reloading the
/// web view. An untitled document has no base and every request fails,
/// which is what you'd expect: a relative path needs an anchor.
final class DocumentAssetSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "mdasset"
    static let baseURL = URL(string: "mdasset://doc/")!

    /// Called on main for each request; returns the directory to resolve
    /// relative paths against, or `nil` when there's no saved document.
    private let baseDirectory: () -> URL?

    /// Tasks WebKit hasn't cancelled yet. `WKURLSchemeTask` throws if you
    /// call `didReceive` / `didFinish` after `stop`, so the async file
    /// read checks membership before replying.
    private var liveTasks = Set<ObjectIdentifier>()

    init(baseDirectory: @escaping () -> URL?) {
        self.baseDirectory = baseDirectory
    }

    /// Map an `mdasset://doc/<rel>` URL to a filesystem URL under `base`.
    static func resolve(_ url: URL, base: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        // `URL.path` is already percent-decoded, so `a%20b.png` → `a b.png`.
        let rel = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !rel.isEmpty else { return nil }
        return URL(fileURLWithPath: rel, relativeTo: base).absoluteURL.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        liveTasks.insert(id)

        guard let url = task.request.url,
              let base = baseDirectory(),
              let fileURL = Self.resolve(url, base: base) else {
            fail(task, code: NSURLErrorFileDoesNotExist)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir),
                  !isDir.boolValue,
                  let data = try? Data(contentsOf: fileURL) else {
                DispatchQueue.main.async { self.fail(task, code: NSURLErrorFileDoesNotExist) }
                return
            }
            let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            DispatchQueue.main.async {
                guard self.liveTasks.contains(id) else { return }
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": mime,
                        "Content-Length": String(data.count),
                        // The file on disk may be replaced under the same
                        // name (re-export a screenshot, …); always re-read.
                        "Cache-Control": "no-store",
                    ])!
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
                self.liveTasks.remove(id)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        liveTasks.remove(ObjectIdentifier(task))
    }

    private func fail(_ task: WKURLSchemeTask, code: Int) {
        let id = ObjectIdentifier(task)
        guard liveTasks.contains(id) else { return }
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: code))
        liveTasks.remove(id)
    }
}
