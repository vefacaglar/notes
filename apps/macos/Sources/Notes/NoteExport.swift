import AppKit
import NotesCore
import PDFKit
import UniformTypeIdentifiers
import WebKit

/// File > Export as HTML…, Export as PDF… and Print… for the active document. The HTML comes from
/// `MarkdownHTML`; PDF and printing render it in a `WKWebView`.
@MainActor
enum NoteExport {
    /// An error message for the workspace's alert, `nil` on success or cancel.
    static func exportHTML(_ document: NoteDocument, settings: AppSettings, window: NSWindow?) -> String? {
        guard !document.isLocked, confirmUnencryptedCopy(of: document) else { return nil }
        guard let url = askForURL(for: document, type: .html, window: window) else { return nil }
        // A modal step can outlast an automatic lock; the text is gone then.
        guard !document.isLocked else { return Workspace.lockedMeanwhile }
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

    /// With "Protect with password" in the save panel the PDF is rendered into a private temporary folder, protected,
    /// written to the chosen place and the temporary file is deleted again (also on failure): no unprotected PDF stays.
    static func exportPDF(_ document: NoteDocument, settings: AppSettings, window: NSWindow?, failed: @escaping @MainActor (String) -> Void) {
        guard !document.isLocked, let (url, password) = askForPDF(for: document) else { return }
        // A protected PDF is not an unencrypted copy.
        if password == nil, !confirmUnencryptedCopy(of: document) { return }
        guard !document.isLocked else {
            failed(Workspace.lockedMeanwhile)
            return
        }
        PrintJob.start(html: printableHTML(document, settings), window: window, saveTo: url, password: password, failed: failed)
    }

    static func print(_ document: NoteDocument, settings: AppSettings, window: NSWindow?, failed: @escaping @MainActor (String) -> Void) {
        guard !document.isLocked, confirmUnencryptedCopy(of: document) else { return }
        guard !document.isLocked else {
            failed(Workspace.lockedMeanwhile)
            return
        }
        PrintJob.start(html: printableHTML(document, settings), window: window, saveTo: nil, password: nil, failed: failed)
    }

    /// File > Export as Encrypted Note…: an `.mdenc` copy of the text with a password typed here (a new salt). The
    /// open file is never overwritten.
    static func exportEncrypted(_ document: NoteDocument, window: NSWindow?, failed: @escaping @MainActor (String) -> Void) {
        guard document.language == .markdown, !document.isLocked,
              let url = askForURL(for: document, type: .encryptedNote, ext: NoteCrypto.fileExtension, window: window)
        else { return }
        if !document.isDraft, NoteDocument.canonical(url) == NoteDocument.canonical(document.url) {
            failed(L("Couldn't export \"\(url.lastPathComponent)\": it is the open file. Choose another name."))
            return
        }
        guard let password = PasswordPrompt.askNew(
            title: L("Export Encrypted Copy"),
            message: L("Choose a password for the copy. There is no way to recover a forgotten password."),
            button: L("Export"))
        else { return }
        // The panel and the password dialog can outlast an automatic lock, which empties the text.
        guard !document.isLocked else {
            failed(Workspace.lockedMeanwhile)
            return
        }
        let text = document.text
        Task {
            let key = await Task.detached(priority: .userInitiated) { NoteCrypto.newKey(password: password) }.value
            guard !document.isLocked else {
                failed(Workspace.lockedMeanwhile)
                return
            }
            do {
                try NoteFile.write(try NoteCrypto.encrypt(text, with: key), to: url)
            } catch {
                failed(L("Couldn't export \"\(url.lastPathComponent)\": \(error.localizedDescription)"))
            }
        }
    }

    /// Exporting or printing an encrypted note as plain HTML or an unprotected PDF makes an unencrypted copy.
    private static func confirmUnencryptedCopy(of document: NoteDocument) -> Bool {
        guard document.isEncrypted else { return true }
        let alert = NSAlert()
        alert.messageText = L("Make an unencrypted copy of “\(document.name)”?")
        alert.informativeText = L("This makes an unencrypted copy: anyone who can open it can read the note.")
        alert.addButton(withTitle: L("Continue"))
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
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

    private static func askForURL(for document: NoteDocument, type: UTType, ext: String? = nil, window: NSWindow?) -> URL? {
        let panel = savePanel(for: document, type: type, ext: ext)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func savePanel(for document: NoteDocument, type: UTType, ext: String? = nil) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        // Notes and drafts: `document.name` has no extension (dots in it are part of the name). Other files lose
        // their own extension, and the open file's own name is never suggested.
        let ext = ext ?? type.preferredFilenameExtension ?? "html"
        var stem = document.isNote || document.isEncrypted ? document.name : document.url.deletingPathExtension().lastPathComponent
        if !document.isDraft, "\(stem).\(ext)".caseInsensitiveCompare(document.url.lastPathComponent) == .orderedSame {
            stem += "-export"
        }
        panel.nameFieldStringValue = "\(stem).\(ext)"
        if !document.isDraft { panel.directoryURL = document.url.deletingLastPathComponent() }
        return panel
    }

    /// The PDF save panel with its "Protect with password" option. Asks again while the option is on and the two
    /// passwords are empty or differ.
    private static func askForPDF(for document: NoteDocument) -> (URL, String?)? {
        let panel = savePanel(for: document, type: .pdf)
        let accessory = PDFProtectionAccessory()
        panel.accessoryView = accessory.view
        while panel.runModal() == .OK {
            guard let url = panel.url else { return nil }
            switch accessory.result {
            case .unprotected: return (url, nil)
            case .password(let password): return (url, password)
            case .invalid(let message):
                let alert = NSAlert()
                alert.messageText = message
                alert.runModal()
            }
        }
        return nil
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
    /// A protected export: the file the print job writes is a private temporary one (`saveTo`, inside `tempFolder`);
    /// `finalURL` gets the password-protected result.
    private let password: String?
    private let finalURL: URL?
    private var tempFolder: URL?

    static func start(html: String, window: NSWindow?, saveTo: URL?, password: String?,
                      failed: @escaping @MainActor (String) -> Void) {
        var target = saveTo
        var folder: URL?
        if password != nil, let saveTo {
            // The boot volume's temporary folder (the OS cleans it), not one beside the target, which may be a USB stick.
            let fileManager = FileManager.default
            let privateFolder = fileManager.temporaryDirectory.appendingPathComponent("NotesExport-\(UUID().uuidString)", isDirectory: true)
            if (try? fileManager.createDirectory(at: privateFolder, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])) != nil { folder = privateFolder }
            guard let folder else {
                failed(L("Couldn't export \"\(saveTo.lastPathComponent)\"."))
                return
            }
            target = folder.appendingPathComponent("export.pdf")
        }
        let job = PrintJob(window: window, saveTo: target, finalURL: password == nil ? nil : saveTo, password: password,
                           tempFolder: folder, failed: failed)
        running.insert(job)
        job.webView.loadHTMLString(html, baseURL: nil)
    }

    private init(window: NSWindow?, saveTo: URL?, finalURL: URL?, password: String?, tempFolder: URL?,
                 failed: @escaping @MainActor (String) -> Void) {
        self.saveTo = saveTo
        self.finalURL = finalURL
        self.password = password
        self.tempFolder = tempFolder
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

    /// AppKit calls this on the thread that ran the operation, which is a background one when no panel is shown (a PDF
    /// export): hop to the main actor before touching the web view and its window.
    @objc nonisolated private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.printOperationFinished(success: success) } }
    }

    private func printOperationFinished(success: Bool) {
        // Cancelling the print panel also reports no success; a failed PDF is told apart by a target that is missing
        // or not rewritten (an existing file the job could not replace keeps its old date).
        let untouched = saveTo.map { Self.modified($0).map { $0 == targetStamp } ?? true } ?? false
        finish(error: !success && untouched ? L("Couldn't export \"\((finalURL ?? saveTo)?.lastPathComponent ?? "")\".") : nil)
    }

    /// Protects the rendered PDF and writes it to `finalURL`, as bytes in one atomic write, only after checking that the
    /// result needs the password to open. Never writes an unprotected file.
    private func writeProtected() -> String? {
        guard let saveTo, let finalURL, let password else { return nil }
        let name = finalURL.lastPathComponent
        let failure = L("Couldn't export \"\(name)\".")
        guard let pdf = PDFDocument(url: saveTo),
              let data = pdf.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: password, PDFDocumentWriteOption.ownerPasswordOption: password]),
              let check = PDFDocument(data: data), check.isEncrypted, check.isLocked
        else { return failure }
        do {
            try data.write(to: finalURL, options: .atomic)
            return nil
        } catch {
            return L("Couldn't export \"\(name)\": \(error.localizedDescription)")
        }
    }

    private var isFinished = false

    private func finish(error: String?) {
        // Once: a second call would find the temporary PDF deleted and report a bogus error.
        guard !isFinished else { return }
        isFinished = true
        var error = error
        if error == nil { error = writeProtected() }
        // The unprotected PDF: gone on every path.
        if let tempFolder { try? FileManager.default.removeItem(at: tempFolder) }
        tempFolder = nil
        if let error { failed(error) }
        webView.navigationDelegate = nil
        host.contentView = nil
        Self.running.remove(self)
    }
}

/// The save panel's "Protect with password" option: a checkbox and two secure fields.
@MainActor
private final class PDFProtectionAccessory: NSObject {
    enum Result {
        case unprotected
        case password(String)
        case invalid(String)
    }

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 84))
    private let checkbox = NSButton(checkboxWithTitle: L("Protect with password"), target: nil, action: nil)
    private let first = NSSecureTextField(frame: .zero)
    private let second = NSSecureTextField(frame: .zero)

    override init() {
        super.init()
        checkbox.target = self
        checkbox.action = #selector(toggled)
        first.placeholderString = L("Password")
        second.placeholderString = L("Verify")
        checkbox.frame = NSRect(x: 20, y: 58, width: 260, height: 18)
        first.frame = NSRect(x: 20, y: 30, width: 260, height: 22)
        second.frame = NSRect(x: 20, y: 4, width: 260, height: 22)
        [checkbox, first, second].forEach(view.addSubview)
        toggled()
    }

    @objc private func toggled() {
        let on = checkbox.state == .on
        first.isEnabled = on
        second.isEnabled = on
        if !on {
            first.stringValue = ""
            second.stringValue = ""
        }
    }

    var result: Result {
        guard checkbox.state == .on else { return .unprotected }
        if first.stringValue.isEmpty { return .invalid(L("The password can't be empty.")) }
        if first.stringValue != second.stringValue { return .invalid(L("The passwords don't match.")) }
        return .password(first.stringValue)
    }
}
