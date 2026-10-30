import Foundation
import NotesCore

/// One open file: holds the editor text, autosaves it with a debounce and reloads external changes.
/// There is at most one document per file, shared by every window that shows it.
@Observable @MainActor
final class NoteDocument {
    private static let live = NSHashTable<NoteDocument>.weakObjects()

    /// The open document for `url`, or a new one loaded from disk.
    static func open(_ url: URL) throws -> NoteDocument {
        let key = canonical(url)
        if let document = live.allObjects.first(where: { canonical($0.url) == key }) { return document }
        return try NoteDocument(url: url)
    }

    /// Flushes every open document; `false` if any of them needs the user's attention (see `flush()`).
    @discardableResult
    static func flushAll() -> Bool {
        live.allObjects.map { $0.flush() }.allSatisfy { $0 }
    }

    static func reloadAll() { live.allObjects.forEach { $0.reloadIfChanged() } }

    static var all: [NoteDocument] { live.allObjects }

    static func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }

    /// Stable across renames, unlike `url`.
    let id = UUID()
    private(set) var url: URL
    var text: String { didSet { if text != oldValue { scheduleSave() } } }
    /// A failed save or a resolved conflict, shown in the window that shows the document.
    var error: String?
    /// This file's own undo stack, handed to its editors so undo never reaches another file.
    @ObservationIgnored let undoManager = UndoManager()
    /// Set for notes in the notes folder, never for standalone files: renames the file to the given title after a save.
    @ObservationIgnored var autoRename: (@MainActor (NoteDocument, String) -> Void)?
    /// Set on a note just made with New Note so its editor takes keyboard focus.
    @ObservationIgnored var focusOnOpen = false

    private var savedText: String
    /// Modification date of the file as last loaded or saved here; any other date means another program wrote it.
    @ObservationIgnored private var savedDate: Date?
    /// Whether the file name follows the first line; decided on load and kept while the note is open,
    /// so clearing the first line and typing a new one still renames it.
    @ObservationIgnored private var isAutoNamed: Bool
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Only `.md` files are notes: Markdown editor and automatic names. Other files open in the code editor.
    var isNote: Bool { NoteStore.isNote(url.lastPathComponent) }
    var language: CodeLanguage { CodeLanguage(path: url.lastPathComponent) }
    /// File name without `.md` for notes; the full file name for other files.
    var name: String { isNote ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent }
    var hasUnsavedChanges: Bool { text != savedText }

    private init(url: URL) throws {
        let content = try Self.load(url)
        self.url = url
        text = content
        savedText = content
        savedDate = Self.modificationDate(url)
        isAutoNamed = false
        isAutoNamed = isNote && NoteStore.isAutoNamed(name, content: content)
        Self.live.add(self)
    }

    /// Writes pending edits now. Returns `false`, with `error` set, when the user must be told something:
    /// the save failed (the edits stay in memory), or the file changed on disk meanwhile, in which case the edits
    /// went to a conflict copy next to it and the document now shows the disk version. Never overwrites
    /// content another program wrote.
    @discardableResult
    func flush() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard hasUnsavedChanges else { return true }
        let snapshot = text
        let date = Self.modificationDate(url)
        if let date, date != savedDate {
            // Changed on disk since we loaded or saved it; only a touch without a content change is safe to overwrite.
            guard let disk = try? Self.load(url) else {
                error = "“\(url.lastPathComponent)” başka bir uygulamada değiştirildi ve okunamadı; üzerine yazılmadı."
                return false
            }
            if disk != savedText { return keepConflictCopy(of: snapshot, disk: disk, date: date) }
        }
        do {
            try Data(snapshot.utf8).write(to: url, options: .atomic)
            savedText = snapshot
            savedDate = Self.modificationDate(url)
        } catch {
            self.error = "“\(url.lastPathComponent)” kaydedilemedi: \(error.localizedDescription)"
            return false
        }
        if isAutoNamed, let autoRename, let title = NoteStore.autoName(for: name, content: snapshot) {
            autoRename(self, title)
        }
        return true
    }

    /// Saves `local` as "<ad> (çakışma).md" next to the file and switches the document to the disk version.
    private func keepConflictCopy(of local: String, disk: String, date: Date) -> Bool {
        let copy = NoteStore.conflictCopyURL(for: url)
        do {
            try Data(local.utf8).write(to: copy, options: .withoutOverwriting)
        } catch {
            self.error = "“\(url.lastPathComponent)” başka bir uygulamada değiştirildi; değişiklikleriniz ayrı bir dosyaya da "
                + "kaydedilemedi: \(error.localizedDescription)"
            return false
        }
        replace(with: disk, date: date)
        self.error = "“\(url.lastPathComponent)” başka bir uygulamada değiştirildi. Diskteki sürüm açıldı; "
            + "sizin değişiklikleriniz “\(copy.lastPathComponent)” olarak kaydedildi."
        return false
    }

    /// Points the document at its file's new location after a rename, keeping the text and edit state.
    /// A rename keeps the modification date, so an external change made before it is still detected.
    func moved(to url: URL) {
        self.url = url
    }

    /// Throws away unsaved edits, e.g. when the user closes a window whose save failed.
    func revert() {
        saveTask?.cancel()
        saveTask = nil
        undoManager.removeAllActions()
        text = savedText
    }

    /// Reloads the file if it changed on disk and there are no local edits (with local edits, the next save
    /// detects the change and keeps a conflict copy).
    func reloadIfChanged() {
        guard !hasUnsavedChanges,
              let date = Self.modificationDate(url), date != savedDate,
              let content = try? Self.load(url)
        else { return }
        if content == savedText {
            savedDate = date
        } else {
            replace(with: content, date: date)
        }
    }

    private func replace(with content: String, date: Date) {
        saveTask?.cancel()
        saveTask = nil
        // The editors' undo steps refer to the old text.
        undoManager.removeAllActions()
        savedText = content
        savedDate = date
        text = content
        isAutoNamed = isNote && NoteStore.isAutoNamed(name, content: content)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard hasUnsavedChanges else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// UTF-8; a BOM is dropped and CRLF becomes LF (see docs/format.md).
    private static func load(_ url: URL) throws -> String {
        var text = try String(contentsOf: url, encoding: .utf8)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
