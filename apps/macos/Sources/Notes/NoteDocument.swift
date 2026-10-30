import AppKit
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
    /// Large files open read-only (see `NoteFile.readOnlySize`); nothing is ever saved for them.
    let isReadOnly: Bool
    /// This file's own undo stack, handed to its editors so undo never reaches another file.
    @ObservationIgnored let undoManager = UndoManager()
    /// Set for files in the notes folder, never for standalone files: renames an auto-named note to the given title
    /// after a save.
    @ObservationIgnored var autoRename: (@MainActor (NoteDocument, String) -> Void)?
    /// Called when the document switched to another file by itself (its edits went to a conflict copy).
    @ObservationIgnored var relocated: (@MainActor (NoteDocument) -> Void)?
    /// Set on a note just made with New Note so its editor takes keyboard focus.
    @ObservationIgnored var focusOnOpen = false

    private var savedText: String
    /// The file as last loaded or saved here; any other stamp means another program wrote it.
    @ObservationIgnored private var savedStamp: NoteFile.Stamp?
    /// Whether the file name follows the first line; decided on load, reload and rename by hand, and kept while
    /// the note is open, so clearing the first line and typing a new one still renames it.
    @ObservationIgnored private var isAutoNamed: Bool
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The editors showing this document, so a reload can close their typing undo group and wait for IME input.
    @ObservationIgnored private let editors = NSHashTable<TextEditorProxy>.weakObjects()

    /// Only `.md` files are notes: automatic names. Other files keep their names.
    var isNote: Bool { NoteStore.isNote(url.lastPathComponent) }
    var language: CodeLanguage { CodeLanguage(path: url.lastPathComponent) }
    /// File name without `.md` for notes; the full file name for other files.
    var name: String { isNote ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent }
    var hasUnsavedChanges: Bool { text != savedText }
    /// Window title: the display name, marked when the file is too large to edit.
    var title: String { isReadOnly ? "\(name) (salt okunur)" : name }

    private init(url: URL) throws {
        let size = NoteFile.size(url) ?? 0
        guard size <= NoteFile.maxOpenSize else { throw NoteFileError.tooLarge(bytes: size) }
        let stamp = NoteFile.stamp(url)
        let content = try NoteFile.read(url)
        self.url = url
        text = content
        savedText = content
        savedStamp = stamp
        isReadOnly = size > NoteFile.readOnlySize
        isAutoNamed = false
        isAutoNamed = isNote && NoteStore.isAutoNamed(name, content: content)
        Self.live.add(self)
    }

    func attach(_ editor: TextEditorProxy) { editors.add(editor) }

    /// Writes pending edits now. Returns `false`, with `error` set, when the user must be told something:
    /// - the save failed: the edits stay in memory;
    /// - the file changed on disk meanwhile: the edits went to a conflict copy next to it and the document shows
    ///   the disk version;
    /// - the file changed on disk and can't be read: the edits went to a conflict copy, which the document now edits.
    /// Never overwrites content another program wrote.
    @discardableResult
    func flush() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard hasUnsavedChanges, !isReadOnly else { return true }
        let snapshot = text
        if let stamp = NoteFile.stamp(url), stamp != savedStamp {
            // Changed on disk since we loaded or saved it; only a touch without a content change is safe to overwrite.
            guard let disk = try? NoteFile.read(url) else { return moveToConflictCopy(snapshot) }
            if disk != savedText { return keepConflictCopy(of: snapshot, disk: disk, stamp: stamp) }
        }
        do {
            try NoteFile.write(snapshot, to: url)
            savedText = snapshot
            savedStamp = NoteFile.stamp(url)
        } catch {
            self.error = "“\(url.lastPathComponent)” kaydedilemedi: \(error.localizedDescription)"
            return false
        }
        if isAutoNamed, let autoRename, let title = NoteStore.autoName(for: name, content: snapshot) {
            autoRename(self, title)
        }
        return true
    }

    /// Writes `text` to a new "<ad> (çakışma)" file next to this one; `nil`, with `error` set, if that fails.
    private func writeConflictCopy(_ text: String, reason: String) -> URL? {
        let copy = NoteStore.conflictCopyURL(for: url)
        do {
            try Data(text.utf8).write(to: copy, options: .withoutOverwriting)
            return copy
        } catch {
            self.error = "\(reason) Değişiklikleriniz ayrı bir dosyaya da kaydedilemedi: \(error.localizedDescription)"
            return nil
        }
    }

    /// Saves `local` as a conflict copy and switches the document to the disk version.
    private func keepConflictCopy(of local: String, disk: String, stamp: NoteFile.Stamp) -> Bool {
        let reason = "“\(url.lastPathComponent)” başka bir uygulamada değiştirildi."
        guard let copy = writeConflictCopy(local, reason: reason) else { return false }
        replace(with: disk, stamp: stamp)
        error = "\(reason) Diskteki sürüm açıldı; sizin değişiklikleriniz “\(copy.lastPathComponent)” olarak kaydedildi."
        return false
    }

    /// The disk version changed and can't be read, so it can't be shown: saves `local` as a conflict copy and keeps
    /// editing that copy, leaving the original untouched.
    private func moveToConflictCopy(_ local: String) -> Bool {
        let reason = "“\(url.lastPathComponent)” başka bir uygulamada değiştirildi ve okunamıyor; üzerine yazılmadı."
        guard let copy = writeConflictCopy(local, reason: reason) else { return false }
        url = copy
        savedText = local
        savedStamp = NoteFile.stamp(copy)
        isAutoNamed = false
        error = "\(reason) Değişiklikleriniz “\(copy.lastPathComponent)” olarak kaydedildi; düzenlemeye orada devam ediyorsunuz."
        relocated?(self)
        return false
    }

    /// Points the document at its file's new location after a rename, keeping the text and edit state.
    /// A rename keeps the file's stamp, so an external change made before it is still detected.
    func moved(to url: URL) {
        self.url = url
    }

    /// After the user renamed the file: points the document at it and decides again whether the name follows the
    /// first line, so a hand-picked name is not replaced by the next save.
    func renamedByHand(to url: URL) {
        self.url = url
        isAutoNamed = isNote && NoteStore.isAutoNamed(name, content: text)
    }

    /// Throws away unsaved edits, e.g. when the user closes a window whose save failed.
    func revert() {
        saveTask?.cancel()
        saveTask = nil
        breakUndoCoalescing()
        undoManager.removeAllActions()
        text = savedText
    }

    /// Reloads the file if it changed on disk and there are no local edits (with local edits, the next save
    /// detects the change and keeps a conflict copy). Waits while an input method is composing text.
    func reloadIfChanged() {
        guard !hasUnsavedChanges,
              !editors.allObjects.contains(where: { $0.textView?.hasMarkedText() == true }),
              let stamp = NoteFile.stamp(url), stamp != savedStamp,
              let content = try? NoteFile.read(url)
        else { return }
        if content == savedText {
            savedStamp = stamp
        } else {
            replace(with: content, stamp: stamp)
        }
    }

    private func replace(with content: String, stamp: NoteFile.Stamp) {
        saveTask?.cancel()
        saveTask = nil
        // The editors' undo steps refer to the old text; close their open typing group first so new typing
        // doesn't extend a removed step.
        breakUndoCoalescing()
        undoManager.removeAllActions()
        savedText = content
        savedStamp = stamp
        text = content
        isAutoNamed = isNote && NoteStore.isAutoNamed(name, content: content)
    }

    private func breakUndoCoalescing() {
        editors.allObjects.forEach { $0.textView?.breakUndoCoalescing() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard hasUnsavedChanges, !isReadOnly else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}
