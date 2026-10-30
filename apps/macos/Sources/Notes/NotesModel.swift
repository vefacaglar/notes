import AppKit
import NotesCore

enum NamePrompt: Equatable {
    case newFolder(in: String?)
    case rename(String)

    var title: String {
        switch self {
        case .newFolder: "Yeni Klasör"
        case .rename: "Yeniden Adlandır"
        }
    }

    var action: String {
        if case .rename = self { "Yeniden Adlandır" } else { "Oluştur" }
    }
}

enum WindowRequest: Equatable {
    case main
    case file(URL)
}

@Observable @MainActor
final class NotesModel {
    private static let folderKey = "notesFolder"

    private(set) var store: NoteStore?
    private(set) var tree: [NoteNode] = []
    /// Path of the selected file or folder in the sidebar.
    var selection: String? { didSet { if selection != oldValue && !isRevertingSelection { selectionChanged(from: oldValue) } } }
    /// The note shown in the main window's editor.
    private(set) var document: NoteDocument?

    var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    private(set) var hits: [SearchHit] = []
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var prompt: NamePrompt?
    var promptName = ""
    var trashCandidate: String?
    var errorMessage: String?
    /// Windows the views should open; consumed by `WindowRequestHandler`.
    var windowRequests: [WindowRequest] = []

    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var missingCheck: Task<Void, Never>?
    @ObservationIgnored private var isRevertingSelection = false

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.folderKey).map { URL(fileURLWithPath: $0) }
        let fallback = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notes")
        setRoot(saved ?? fallback)
    }

    // MARK: Folder

    func setRoot(_ url: URL) {
        // A failed save keeps the current folder and note open; the document's alert says why.
        if let document, !document.flush() { return }
        document = nil
        selection = nil
        query = ""
        do {
            let store = try NoteStore(root: url)
            self.store = store
            UserDefaults.standard.set(store.root.path, forKey: Self.folderKey)
            watcher = FolderWatcher(url: store.root) { [weak self] in self?.refresh() }
        } catch {
            store = nil
            watcher = nil
            errorMessage = error.localizedDescription
        }
        tree = []
        refresh()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Seç"
        panel.message = "Notların bulunduğu klasörü seçin"
        panel.directoryURL = store?.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setRoot(url)
    }

    /// Re-reads the tree off the main thread and reloads the open note if it changed on disk.
    /// Runs on every file system event below the root, including our own autosaves.
    func refresh() {
        guard let store else { return }
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            let tree = await Task.detached { store.tree() }.value
            guard let self, !Task.isCancelled, self.store?.root == store.root, tree != self.tree else { return }
            self.tree = tree
        }
        if let document {
            if FileManager.default.fileExists(atPath: document.url.path) {
                document.reloadIfChanged()
            } else if !document.hasUnsavedChanges {
                closeIfStillMissing(document)
            }
        }
        if isSearching { scheduleSearch() }
    }

    /// Closes `document` when its file is gone for good. Some apps save by deleting and recreating the file,
    /// so this waits a moment first.
    private func closeIfStillMissing(_ document: NoteDocument) {
        guard missingCheck == nil else { return }
        missingCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.missingCheck = nil
            guard self.document === document, !document.hasUnsavedChanges,
                  !FileManager.default.fileExists(atPath: document.url.path)
            else { return }
            self.document = nil
            self.selection = nil
        }
    }

    private func selectionChanged(from old: String?) {
        guard let store else { return }
        if let document, let selection, let url = try? store.url(for: selection),
           NoteDocument.canonical(url) == NoteDocument.canonical(document.url) { return }
        if let document, !document.flush() {
            // Keep the note open with its edits; its alert explains what happened.
            revertSelection(to: old)
            return
        }
        document = nil
        guard let selection, NoteStore.isListed(selection) else { return }
        do {
            let url = try store.url(for: selection)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { return }
            let document = try NoteDocument.open(url)
            if document.isNote { document.autoRename = { [weak self] in self?.autoRename($0, to: $1) } }
            self.document = document
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revertSelection(to old: String?) {
        isRevertingSelection = true
        selection = old
        isRevertingSelection = false
    }

    /// Renames an auto-named note after its first line (docs/format.md) while it stays open in the editor.
    private func autoRename(_ document: NoteDocument, to title: String) {
        guard let store, let path = notePath(for: document.url) else { return }
        let folder = NoteStore.parent(path)
        // On failure the text is still saved; the name is retried after the next save.
        guard let newPath = try? store.rename(path, to: store.uniqueNoteName(title, in: folder, ignoring: path) + ".md"),
              newPath != path, let url = try? store.url(for: newPath)
        else { return }
        // Move the document first so the selection change below finds it already open at the new path.
        document.moved(to: url)
        if let selection, let moved = NoteStore.moved(selection, from: path, to: newPath) { self.selection = moved }
        if case .rename(let target)? = prompt, let moved = NoteStore.moved(target, from: path, to: newPath) {
            prompt = .rename(moved)
        }
        if let trashCandidate, let moved = NoteStore.moved(trashCandidate, from: path, to: newPath) {
            self.trashCandidate = moved
        }
        refresh()
    }

    /// Saves the open note before `path` is renamed or trashed and returns `path`, following it if that save
    /// auto-renamed the note. `nil` when the save needs the user and the operation would touch the open note.
    private func saveDocument(following path: String) -> String? {
        guard let document, let before = notePath(for: document.url) else { return path }
        let saved = document.flush()
        let after = notePath(for: document.url) ?? before
        let path = NoteStore.moved(path, from: before, to: after) ?? path
        if !saved && NoteStore.moved(after, from: path, to: path) != nil { return nil }
        return path
    }

    // MARK: Opening files from Finder

    func open(_ urls: [URL]) {
        for url in urls {
            if let path = notePath(for: url) {
                query = ""
                refresh()
                selection = path
                windowRequests.append(.main)
            } else {
                windowRequests.append(.file(url.resolvingSymlinksInPath().standardizedFileURL))
            }
        }
    }

    /// The store path of `url` when it is a listed file inside the current root.
    private func notePath(for url: URL) -> String? {
        guard let store else { return nil }
        let root = (store.root.resolvingSymlinksInPath().path + "/").unicodeScalars
        let file = url.resolvingSymlinksInPath().standardizedFileURL.path.unicodeScalars
        guard file.starts(with: root) else { return nil }
        let path = String(file.dropFirst(root.count))
        guard NoteStore.isListed(path), (try? store.url(for: path)) != nil else { return nil }
        return path
    }

    // MARK: Creating, renaming, trashing

    /// The folder new items go into: the selected folder, the selected note's folder, or the root.
    private var targetFolder: String? {
        guard let selection else { return nil }
        // Asks the disk, not `tree`, which is refreshed in the background.
        var isFolder: ObjCBool = false
        if let url = try? store?.url(for: selection),
           FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            return selection
        }
        let parent = NoteStore.parent(selection)
        return parent.isEmpty ? nil : parent
    }

    /// Creates "Adsız" (or "Adsız 2"…) right away and focuses the editor; the first line names it later.
    func newNote() {
        guard let store else { return }
        // Save the open note first, so a failed save doesn't leave a new empty note behind.
        if let document, !document.flush() { return }
        let folder = targetFolder
        do {
            let path = try store.createNote(named: store.uniqueNoteName(NoteStore.untitledName, in: folder), in: folder)
            query = ""
            refresh()
            selection = path
            document?.focusOnOpen = true
            windowRequests.append(.main)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func newFolder() { ask(.newFolder(in: targetFolder), name: "Yeni Klasör") }

    func rename(_ path: String) {
        ask(.rename(path), name: NoteStore.displayName(path))
    }

    private func ask(_ prompt: NamePrompt, name: String) {
        guard store != nil else { return }
        promptName = name
        self.prompt = prompt
        windowRequests.append(.main)
    }

    /// Runs the prompt's action; `prompt` is the one the alert showed (passed in, since the alert clears
    /// `self.prompt` before its button action runs).
    func commitPrompt(_ prompt: NamePrompt) {
        guard let store else { return }
        // Still set if the alert calls the action before dismissing; then it has followed any automatic rename.
        let prompt = self.prompt ?? prompt
        self.prompt = nil
        do {
            switch prompt {
            case .newFolder(let parent):
                let path = try store.createFolder(named: promptName, in: parent)
                query = ""
                refresh()
                selection = path
            case .rename(let path):
                guard let path = saveDocument(following: path) else { return }
                let newPath = try store.rename(path, to: promptName)
                guard newPath != path else { return }
                // Keep the open document (text, cursor, undo) and point it at the new location.
                if let document, let docPath = notePath(for: document.url),
                   let moved = NoteStore.moved(docPath, from: path, to: newPath) {
                    document.moved(to: try store.url(for: moved))
                }
                if let selection, let moved = NoteStore.moved(selection, from: path, to: newPath) { self.selection = moved }
                refresh()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func trash(_ path: String) {
        guard let store, let path = saveDocument(following: path) else { return }
        do {
            try store.trash(path)
            if let selection, NoteStore.moved(selection, from: path, to: path) != nil {
                document = nil
                self.selection = nil
            }
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealInFinder(_ path: String) {
        guard let url = try? store?.url(for: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        guard let store, isSearching else {
            hits = []
            return
        }
        let query = query
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let hits = await Task.detached { store.search(query) }.value
            guard !Task.isCancelled else { return }
            self?.hits = hits
        }
    }
}
