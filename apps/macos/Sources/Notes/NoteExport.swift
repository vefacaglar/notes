import AppKit
import NotesCore
import UniformTypeIdentifiers
import WebKit

/// File > Export as HTML…, Export as PDF… and Print… for the active document. The HTML comes from
/// `MarkdownHTML`; PDF and printing render it in a `WKWebView`.
@MainActor
enum NoteExport {
    /// An error message for the workspace's alert, `nil` on success or cancel.
    static func exportHTML(_ document: NoteDocument, settings: AppSettings, window: NSWindow?) -> String? {
        guard let url = askForURL(for: document, type: .html, window: window) else { return nil }
        if !document.isDraft, NoteDocument.canonical(url) == NoteDocument.canonical(document.url) {
            return L("Couldn't export \"\(url.lastPathComponent)\": it is the open file. Choose another name.")
        }
        do {
            try Data(html(document, settings).utf8).write(to: url, options: .atomic)
            return nil
        } catch {
            return L("Couldn't export \"\(url.lastPathComponent)\": \(error.localizedDescription)")
        }
    }

    static func exportPDF(_ document: NoteDocument, settings: AppSettings, window: NSWindow?, failed: @escaping @MainActor (String) -> Void) {
        guard let url = askForURL(for: document, type: .pdf, window: window) else { return }
        PrintJob.start(html: printableHTML(document, settings), window: window, saveTo: url, failed: failed)
    }

    static func print(_ document: NoteDocument, settings: AppSettings, window: NSWindow?, failed: @escaping @MainActor (String) -> Void) {
        PrintJob.start(html: printableHTML(document, settings), window: window, saveTo: nil, failed: failed)
    }

    static func html(_ document: NoteDocument, _ settings: AppSettings) -> String {
        let style = MarkdownHTML.Style(textFontFamily: settings.baseTextFont.family, textFontSize: settings.baseTextFont.size,
                                        codeFontFamily: settings.baseCodeFont.family, codeFontSize: settings.baseCodeFont.size)
        let text = document.text
        return document.language == .markdown
            ? MarkdownHTML.document(markdown: text, title: document.name, style: style)
            : MarkdownHTML.document(code: text, title: document.name, style: style)
    }

    /// The HTML for PDF and printing. The offscreen web view has no access to the note's folder, so relative images
    /// are embedded as data URIs (image files only, up to 25 MB each); anything else is left as written.
    private static func printableHTML(_ document: NoteDocument, _ settings: AppSettings) -> String {
        let page = html(document, settings)
        guard !document.isDraft else { return page }
        return inlineImages(in: page, folder: document.url.deletingLastPathComponent())
    }

    private static let imageTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                                      "webp": "image/webp", "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff",
                                      "heic": "image/heic"]
    // The converter always writes `<img src="…" alt="…"`; the value is HTML-escaped, so it holds no quote.
    private static let imageSource = try! NSRegularExpression(pattern: #"<img src="([^"]*)""#)

    static func inlineImages(in page: String, folder: URL) -> String {
        let ns = page as NSString
        var result = ""
        var last = 0
        for match in imageSource.matches(in: page, range: NSRange(location: 0, length: ns.length)) {
            let source = ns.substring(with: match.range(at: 1))
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            last = NSMaxRange(match.range)
            if let uri = dataURI(forSource: source, in: folder) {
                result += "<img src=\"\(uri)\""
            } else {
                result += ns.substring(with: match.range)
            }
        }
        return result + ns.substring(from: last)
    }

    private static func dataURI(forSource source: String, in folder: URL) -> String? {
        let plain = source.replacingOccurrences(of: "&amp;", with: "&")
        guard !plain.hasPrefix("/"), !plain.hasPrefix("#"), !plain.contains(":") else { return nil }
        let bare = plain.prefix { $0 != "#" && $0 != "?" }
        guard let path = String(bare).removingPercentEncoding else { return nil }
        let file = folder.appending(path: path, directoryHint: .notDirectory).standardizedFileURL
        guard let type = imageTypes[file.pathExtension.lowercased()],
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 25_000_000,
              let data = try? Data(contentsOf: file)
        else { return nil }
        return "data:\(type);base64,\(data.base64EncodedString())"
    }

    private static func askForURL(for document: NoteDocument, type: UTType, window: NSWindow?) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        // Notes and drafts: `document.name` has no extension (dots in it are part of the name). Other files lose
        // their own extension, and the open file's own name is never suggested.
        let ext = type.preferredFilenameExtension ?? "html"
        var stem = document.isNote ? document.name : document.url.deletingPathExtension().lastPathComponent
        if !document.isDraft, "\(stem).\(ext)".caseInsensitiveCompare(document.url.lastPathComponent) == .orderedSame {
            stem += "-export"
        }
        panel.nameFieldStringValue = "\(stem).\(ext)"
        if !document.isDraft { panel.directoryURL = document.url.deletingLastPathComponent() }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Renders HTML in an offscreen web view and runs a print operation for it (the print panel, or straight to a PDF).
@MainActor
private final class PrintJob: NSObject, WKNavigationDelegate {
    private static var running: Set<PrintJob> = []

    private let webView: WKWebView
    private let host: NSWindow
    private let saveTo: URL?
    private let parent: NSWindow?
    private let failed: @MainActor (String) -> Void
    /// The PDF target's date before the job, to tell a replaced file from an untouched one.
    private let targetStamp: Date?

    static func start(html: String, window: NSWindow?, saveTo: URL?, failed: @escaping @MainActor (String) -> Void) {
        let job = PrintJob(window: window, saveTo: saveTo, failed: failed)
        running.insert(job)
        job.webView.loadHTMLString(html, baseURL: nil)
    }

    private init(window: NSWindow?, saveTo: URL?, failed: @escaping @MainActor (String) -> Void) {
        self.saveTo = saveTo
        self.parent = window
        self.failed = failed
        targetStamp = saveTo.flatMap(Self.modified)
        let info = Self.printInfo(saveTo: saveTo)
        let size = NSSize(width: info.paperSize.width - info.leftMargin - info.rightMargin,
                          height: info.paperSize.height - info.topMargin - info.bottomMargin)
        webView = WKWebView(frame: NSRect(origin: .zero, size: size))
        // A web view prints blank unless it lives in a window; this one is never shown.
        host = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        host.isReleasedWhenClosed = false
        host.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func printInfo(saveTo: URL?) -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        if let saveTo {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = saveTo
        }
        return info
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { run() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { finish(error: error.localizedDescription) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { finish(error: error.localizedDescription) }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated { finish(error: L("Couldn't print.")) }
    }

    private func run() {
        let operation = webView.printOperation(with: Self.printInfo(saveTo: saveTo))
        operation.showsPrintPanel = saveTo == nil
        operation.showsProgressPanel = saveTo == nil
        operation.view?.frame = webView.frame
        if let parent {
            operation.runModal(for: parent, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        } else {
            finish(error: operation.run() ? nil : L("Couldn't print."))
        }
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        // Cancelling the print panel also reports no success; a failed PDF is told apart by a target that is missing
        // or not rewritten (an existing file the job could not replace keeps its old date).
        let untouched = saveTo.map { Self.modified($0).map { $0 == targetStamp } ?? true } ?? false
        finish(error: !success && untouched ? L("Couldn't export \"\(saveTo?.lastPathComponent ?? "")\".") : nil)
    }

    private func finish(error: String?) {
        if let error { failed(error) }
        webView.navigationDelegate = nil
        host.contentView = nil
        Self.running.remove(self)
    }
}
