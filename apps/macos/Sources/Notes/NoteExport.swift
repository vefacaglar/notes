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
        do {
            try Data(html(document, settings).utf8).write(to: url, options: .atomic)
            return nil
        } catch {
            return L("Couldn't export \"\(url.lastPathComponent)\": \(error.localizedDescription)")
        }
    }

    static func exportPDF(_ document: NoteDocument, settings: AppSettings, window: NSWindow?, failed: @escaping @MainActor (String) -> Void) {
        guard let url = askForURL(for: document, type: .pdf, window: window) else { return }
        PrintJob.start(html: html(document, settings), window: window, saveTo: url, failed: failed)
    }

    static func print(_ document: NoteDocument, settings: AppSettings, window: NSWindow?, failed: @escaping @MainActor (String) -> Void) {
        PrintJob.start(html: html(document, settings), window: window, saveTo: nil, failed: failed)
    }

    static func html(_ document: NoteDocument, _ settings: AppSettings) -> String {
        let style = MarkdownHTML.Style(textFontFamily: settings.baseTextFont.family, textFontSize: settings.baseTextFont.size,
                                        codeFontFamily: settings.baseCodeFont.family, codeFontSize: settings.baseCodeFont.size)
        let text = document.text
        return document.language == .markdown
            ? MarkdownHTML.document(markdown: text, title: document.name, style: style)
            : MarkdownHTML.document(code: text, title: document.name, style: style)
    }

    private static func askForURL(for document: NoteDocument, type: UTType, window: NSWindow?) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ((document.name as NSString).deletingPathExtension as NSString)
            .appendingPathExtension(type.preferredFilenameExtension ?? "html") ?? document.name
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

    static func start(html: String, window: NSWindow?, saveTo: URL?, failed: @escaping @MainActor (String) -> Void) {
        let job = PrintJob(window: window, saveTo: saveTo, failed: failed)
        running.insert(job)
        job.webView.loadHTMLString(html, baseURL: nil)
    }

    private init(window: NSWindow?, saveTo: URL?, failed: @escaping @MainActor (String) -> Void) {
        self.saveTo = saveTo
        self.parent = window
        self.failed = failed
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
        // Cancelling the print panel also reports no success; a failed PDF is told apart by the missing file.
        let missing = saveTo.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        finish(error: !success && missing ? L("Couldn't export \"\(saveTo?.lastPathComponent ?? "")\".") : nil)
    }

    private func finish(error: String?) {
        if let error { failed(error) }
        webView.navigationDelegate = nil
        host.contentView = nil
        Self.running.remove(self)
    }
}
