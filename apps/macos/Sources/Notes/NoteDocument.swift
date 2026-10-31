import AppKit
import NotesCore

/// One open file or draft: holds the editor text, autosaves it with a debounce and reloads external changes.
/// There is at most one document per file, shared by every window and tab that shows it.
@Observable @MainActor
final class NoteDocument {
    private static let live = NSHashTable<NoteDocument>.weakObjects()
    /// Up to this size the disk text is compared with the last saved text even when the file's stamp is unchanged:
    /// file systems with coarse modification times (HFS+, FAT) can hide a same-size edit made within a second or two.
    /// Bigger files are read on the main thread only on such volumes (see `needsContentCheck`).
    private static let verifySize = 1_048_576

    /// The open document for `url`, or a new one loaded from disk.
    static func open(_ url: URL) throws -> NoteDocument {
        if let document = existing(url) { return document }
        return try NoteDocument(url: url, isDraft: false)
    }

    /// A draft stored at `url` in the draft store; a missing file is an empty draft.
    static func openDraft(_ url: URL) throws -> NoteDocument {
        if let document = existing(url) { return document }
        return try NoteDocument(url: url, isDraft: true)
    }

    private static func existing(_ url: URL) -> NoteDocument? {
        let key = canonical(url)
        return live.allObjects.first { canonical($0.url) == key }
    }

    /// Flushes every open document; `false` if any of them needs the user's attention (see `flush()`).
    @discardableResult
    static func flushAll() -> Bool {
        live.allObjects.map { $0.flush() }.allSatisfy { $0 }
    }

    static func reloadAll() { live.allObjects.forEach { $0.reloadIfChanged() } }

    static var all: [NoteDocument] { live.allObjects }

    nonisolated static func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }

    /// Stable across renames, unlike `url`.
    let id = UUID()
    private(set) var url: URL
    /// A note that was never saved into a folder: its text lives in the draft store (docs/format.md, "Drafts").
    private(set) var isDraft: Bool
    /// Always in the on-disk form (no BOM, LF line ends; `NoteFile.normalized`): pasted CRLF text is converted here, so
    /// what is saved equals what the document holds and a save is never mistaken for an outside change.
    var text: String {
        didSet {
            if NoteFile.needsNormalizing(text) { text = NoteFile.normalized(text) }
            if text != oldValue {
                revision &+= 1
                scheduleSave()
            }
        }
    }
    /// Counts changes of `text`: a cheap change token for views that would otherwise compare the whole text.
    private(set) var revision = 0
    /// A failed save or a resolved conflict, shown in the window that shows the document.
    var error: String?
    /// Nothing is ever saved for a read-only file; `readOnlyReason` says why it is one.
    private(set) var isReadOnly = false
    private(set) var readOnlyReason: String?
    /// This file's own undo stack, handed to its editors so undo never reaches another file.
    @ObservationIgnored let undoManager = UndoManager()
    /// Renames an auto-named note to the given title after a save; set by the app model, which decides whether the
    /// file is inside a root and automatic naming is on.
    @ObservationIgnored var autoRename: (@MainActor (NoteDocument, String) -> Void)?
    /// Called when the document switched to another file by itself: its edits went to a conflict copy, or a draft moved
    /// to a new draft file.
    @ObservationIgnored var relocated: (@MainActor (NoteDocument) -> Void)?
    /// Set on a note just made with New Note (or a new draft) so its editor takes keyboard focus.
    @ObservationIgnored var focusOnOpen = false

    private var savedText: String
    /// The file as last loaded or saved here; any other stamp means another program wrote it.
    @ObservationIgnored private var savedStamp: NoteFile.Stamp?
    /// Whether the file name follows the first line; decided on load, reload and rename by hand, and kept while
    /// the note is open, so clearing the first line and typing a new one still renames it.
    @ObservationIgnored private var isAutoNamed = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The editors showing this document, so a reload can close their typing undo group and wait for IME input.
    @ObservationIgnored private let editors = NSHashTable<TextEditorProxy>.weakObjects()

    /// Only `.md` files (and drafts) are notes: automatic names. Other files keep their names.
    var isNote: Bool { isDraft || NoteStore.isNote(url.lastPathComponent) }
    var language: CodeLanguage { isDraft ? .markdown : CodeLanguage(path: url.lastPathComponent) }
    /// File name without `.md` for notes; the full file name for other files; a draft's first-line title.
    var name: String {
        if isDraft { return NoteStore.title(from: String(text.prefix(2048))) ?? NoteStore.untitledName }
        return isNote ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }
    var hasUnsavedChanges: Bool { text != savedText }
    /// The tab's dot: unsaved edits, or a draft that has text (it is not in a notes folder yet).
    var showsUnsavedDot: Bool { isDraft ? !text.isEmpty : hasUnsavedChanges }
    /// Window and tab title: the display name, marked when the file can't be edited.
    var title: String { isReadOnly ? L("\(name) (read-only)") : name }

    private convenience init(url: URL, isDraft: Bool) throws {
        if isDraft && !FileManager.default.fileExists(atPath: url.path) {
            self.init(url: url, isDraft: true, text: "", stamp: nil)
            return
        }
        let size = NoteFile.size(url) ?? 0
        guard size <= NoteFile.maxOpenSize else { throw NoteFileError.tooLarge(bytes: size) }
        let stamp = NoteFile.stamp(url)
        self.init(url: url, isDraft: isDraft, text: try NoteFile.read(url), stamp: stamp)
    }

    private init(url: URL, isDraft: Bool, text: String, stamp: NoteFile.Stamp?) {
        self.url = url
        self.isDraft = isDraft
        self.text = text
        savedText = text
        savedStamp = stamp
        if !isDraft {
            updateReadOnly()
            isAutoNamed = isNote && NoteStore.isAutoNamed(name, content: text)
        }
        Self.live.add(self)
    }

    /// A new, empty draft whose file is created at `url` once it has text.
    static func newDraft(at url: URL) -> NoteDocument {
        NoteDocument(url: url, isDraft: true, text: "", stamp: nil)
    }

    func attach(_ editor: TextEditorProxy) { editors.add(editor) }

    /// This document's text view in `window`, if an editor there shows it.
    func textView(in window: NSWindow) -> NSTextView? {
        editors.allObjects.compactMap(\.textView).first { $0.window === window }
    }

    /// Large files and files the user may not write open read-only; decided on open and on reload.
    private func updateReadOnly() {
        guard !isDraft else { return }
        let size = NoteFile.size(url) ?? 0
        if size > NoteFile.readOnlySize {
            readOnlyReason = L("This file is larger than 20 MB, so it opens read-only.")
        } else if FileManager.default.fileExists(atPath: url.path), !NoteFile.isWritable(url) {
            readOnlyReason = L("You don't have permission to change this file, so it opens read-only.")
        } else {
            readOnlyReason = nil
        }
        isReadOnly = readOnlyReason != nil
    }

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
        let snapshot = NoteFile.normalized(text)
        if isDraft { return flushDraft(snapshot) }
        if let stamp = NoteFile.stamp(url) {
            if stamp != savedStamp {
                // Changed on disk since we loaded or saved it; only a touch without a content change is safe to overwrite.
                guard let disk = try? NoteFile.read(url) else { return moveToConflictCopy(snapshot) }
                if disk != savedText { return keepConflictCopy(of: snapshot, disk: disk, stamp: stamp) }
            } else if needsContentCheck(stamp), let disk = try? NoteFile.read(url), disk != savedText {
                return keepConflictCopy(of: snapshot, disk: disk, stamp: stamp)
            }
        }
        do {
            try NoteFile.write(snapshot, to: url)
            savedText = snapshot
            savedStamp = NoteFile.stamp(url)
        } catch {
            self.error = Self.saveFailure(url.lastPathComponent, error)
            return false
        }
        if isAutoNamed, let autoRename, let title = NoteStore.autoName(for: name, content: snapshot) {
            autoRename(self, title)
        }
        return true
    }

    /// An unchanged stamp can still hide an edit on coarse-timestamp volumes. Small files are always compared by
    /// content; a big file only when its timestamp is coarse and recent, so typing in a 15 MB file on APFS never reads
    /// it back on the main thread.
    private func needsContentCheck(_ stamp: NoteFile.Stamp) -> Bool {
        if let size = stamp.size, size <= Self.verifySize { return true }
        guard stamp.hasCoarseTimestamp, let modified = stamp.modificationDate else { return stamp.hasCoarseTimestamp }
        return abs(modified.timeIntervalSinceNow) < 2
    }

    /// Drafts belong to one process; a changed draft file means another writer, so this text goes to a new draft file
    /// next to it (the old one stays and is restored later) and the document follows it.
    private func flushDraft(_ snapshot: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let stamp = NoteFile.stamp(url), stamp != savedStamp {
                let other = url.deletingLastPathComponent().appendingPathComponent(DraftStore.newDraftName())
                try NoteFile.write(snapshot, to: other)
                url = other
                savedText = snapshot
                savedStamp = NoteFile.stamp(other)
                relocated?(self)
                return true
            }
            try NoteFile.write(snapshot, to: url)
            savedText = snapshot
            savedStamp = NoteFile.stamp(url)
            return true
        } catch {
            self.error = Self.saveFailure(name, error)
            return false
        }
    }

    private static func saveFailure(_ name: String, _ error: any Error) -> String {
        if let error = error as? NoteFileError {
            return L("\(error.localizedDescription) Your changes are kept in this window.")
        }
        let nsError = error as NSError
        let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
            ?? (nsError.domain == NSPOSIXErrorDomain ? nsError.code : nil)
        let denied = nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileWriteNoPermission.rawValue
            || posix == Int(EACCES) || posix == Int(EPERM)
        if denied {
            return L("You don't have permission to save “\(name)”. Your changes are kept in this window.")
        }
        return L("“\(name)” couldn't be saved: \(error.localizedDescription)")
    }

    /// Writes `text` to a new "<name> (conflict)" file next to this one; `nil`, with `error` set, if that fails.
    private func writeConflictCopy(_ text: String, reason: String) -> URL? {
        let copy = NoteStore.conflictCopyURL(for: url)
        do {
            try Data(text.utf8).write(to: copy, options: .withoutOverwriting)
            return copy
        } catch {
            self.error = L("\(reason) Your changes couldn't be saved to a separate file either: \(error.localizedDescription)")
            return nil
        }
    }

    /// Saves `local` as a conflict copy and switches the document to the disk version.
    private func keepConflictCopy(of local: String, disk: String, stamp: NoteFile.Stamp) -> Bool {
        let reason = L("“\(url.lastPathComponent)” was changed in another app.")
        guard let copy = writeConflictCopy(local, reason: reason) else { return false }
        replace(with: disk, stamp: stamp)
        error = L("\(reason) The version on disk is open now; your changes were saved as “\(copy.lastPathComponent)”.")
        return false
    }

    /// The disk version changed and can't be read, so it can't be shown: saves `local` as a conflict copy and keeps
    /// editing that copy, leaving the original untouched.
    private func moveToConflictCopy(_ local: String) -> Bool {
        let reason = L("“\(url.lastPathComponent)” was changed in another app and can't be read, so it wasn't overwritten.")
        guard let copy = writeConflictCopy(local, reason: reason) else { return false }
        url = copy
        savedText = local
        savedStamp = NoteFile.stamp(copy)
        isAutoNamed = false
        updateReadOnly()
        error = L("\(reason) Your changes were saved as “\(copy.lastPathComponent)”; you're editing that file now.")
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

    /// A draft whose text was just written to `url` in a notes folder: from now on it is that file's note, named
    /// automatically. Its draft file is deleted.
    func becomeFile(_ url: URL, writtenText: String, stamp: NoteFile.Stamp?) {
        guard isDraft else { return }
        let draftURL = self.url
        isDraft = false
        error = nil
        self.url = url
        savedText = writtenText
        savedStamp = stamp
        isAutoNamed = isNote && NoteStore.isAutoNamed(name, content: writtenText)
        updateReadOnly()
        try? FileManager.default.removeItem(at: draftURL)
        if hasUnsavedChanges { scheduleSave() }
    }

    /// Deletes a draft's file and drops its text, when the user closed its tab without saving.
    func discardDraft() {
        guard isDraft else { return }
        saveTask?.cancel()
        saveTask = nil
        savedText = text
        try? FileManager.default.removeItem(at: url)
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
    /// detects the change and keeps a conflict copy). Waits while an input method is composing text. A file that grew
    /// beyond what can be opened keeps the text shown and becomes read-only.
    func reloadIfChanged() {
        guard !isDraft, !hasUnsavedChanges,
              !editors.allObjects.contains(where: { $0.textView?.hasMarkedText() == true })
        else { return }
        updateReadOnly()
        guard let stamp = NoteFile.stamp(url), stamp != savedStamp else { return }
        if let size = stamp.size, size > NoteFile.maxOpenSize {
            readOnlyReason = L("This file changed on disk and is now too large to open; the last version read is shown.")
            isReadOnly = true
            return
        }
        guard let content = try? NoteFile.read(url) else { return }
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
