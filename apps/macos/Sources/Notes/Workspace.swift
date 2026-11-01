import AppKit
import NotesCore
import os

/// Where an editor left off: selection (UTF-16) and scroll position. Kept per tab and in the session file.
struct EditorViewState: Codable, Equatable {
    var location: Int
    var length: Int
    var scrollX: Double
    var scrollY: Double

    init(location: Int, length: Int, scrollX: Double, scrollY: Double) {
        (self.location, self.length, self.scrollX, self.scrollY) = (location, length, scrollX, scrollY)
    }

    @MainActor init(_ textView: NSTextView) {
        let range = textView.selectedRange()
        let origin = textView.enclosingScrollView?.contentView.bounds.origin ?? .zero
        self.init(location: range.location, length: range.length, scrollX: origin.x, scrollY: origin.y)
    }

    @MainActor func apply(to textView: NSTextView) {
        let total = (textView.string as NSString).length
        let start = min(max(location, 0), total)
        textView.setSelectedRange(NSRange(location: start, length: min(max(length, 0), total - start)))
        guard let clip = textView.enclosingScrollView?.contentView else { return }
        // Can be negative: the clip view's content insets under a transparent toolbar.
        let origin = NSPoint(x: scrollX, y: scrollY)
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(forBoundingRect: NSRect(origin: origin, size: clip.bounds.size), in: container)
        }
        textView.scroll(origin)
    }
}

/// One tab of a window: an open file or draft.
@Observable @MainActor
final class EditorTab: Identifiable {
    let id = UUID()
    fileprivate(set) var document: NoteDocument
    /// "Show Source": Markdown as plain text.
    var showsSource = false
    /// The tab's editor handle, shared with the window toolbar (formatting, outline, Format).
    let editor = TextEditorProxy()
    /// Saved when the tab stops being shown, applied when its editor appears again.
    @ObservationIgnored var viewState: EditorViewState?
    @ObservationIgnored var focusOnShow = false

    init(document: NoteDocument) {
        self.document = document
    }
}

/// An item in one of a workspace's roots; an empty path is the root itself.
struct ItemID: Hashable, Sendable {
    let root: UUID
    let path: String

    var isRoot: Bool { path.isEmpty }
}

/// A row of the sidebar tree.
struct SidebarItem: Identifiable, Hashable, Sendable {
    let id: ItemID
    let name: String
    let isFolder: Bool
    /// `nil` for files, so `List(children:)` shows no disclosure triangle.
    let children: [SidebarItem]?
    /// The file's modification date; `nil` for folders.
    var modified: Date?

    static func items(_ nodes: [NoteNode], root: UUID) -> [SidebarItem] {
        nodes.map {
            SidebarItem(id: ItemID(root: root, path: $0.path), name: $0.name, isFolder: $0.isFolder,
                        children: $0.children.map { items($0, root: root) }, modified: $0.modified)
        }
    }
}

struct WorkspaceHit: Identifiable, Hashable, Sendable {
    let root: UUID
    let hit: SearchHit

    var item: ItemID { ItemID(root: root, path: hit.path) }
    var id: String { "\(root.uuidString)|\(hit.id)" }
}

/// One root folder of a workspace: its store, sidebar tree and folder watcher.
@Observable @MainActor
final class RootFolder: Identifiable {
    let id = UUID()
    let store: NoteStore
    fileprivate(set) var items: [SidebarItem] = []
    @ObservationIgnored fileprivate var tree: [NoteNode]?
    @ObservationIgnored fileprivate var watcher: FolderWatcher?
    /// Marks the scan in flight as superseded; the detached tree walk checks it between folders.
    @ObservationIgnored fileprivate var scanToken: ScanToken?
    @ObservationIgnored fileprivate var isScanning = false
    /// Something changed while a scan ran: scan once more when it ends, however many events came.
    @ObservationIgnored fileprivate var rescanPending = false

    init(store: NoteStore) {
        self.store = store
    }

    var url: URL { store.root }
    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
}

/// A flag a background scan polls to learn it is no longer wanted.
final class ScanToken: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() { cancelled.withLock { $0 = true } }
}

/// A configured root that couldn't be opened (missing, a file, a duplicate); kept so it isn't lost from the list.
struct UnavailableRoot: Identifiable, Hashable {
    let url: URL
    let reason: String

    var id: String { url.path }
    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
}

enum NamePrompt: Equatable {
    case newFolder(in: ItemID)
    case rename(ItemID)
    case newEncrypted(in: ItemID)
    case encrypt(ItemID)

    var title: String {
        switch self {
        case .newFolder: L("New Folder")
        case .rename: L("Rename")
        case .newEncrypted: L("Create Encrypted Note")
        case .encrypt: L("Encrypt Note")
        }
    }

    var action: String {
        switch self {
        case .rename: L("Rename")
        case .encrypt: L("Continue")
        default: L("Create")
        }
    }
}

enum FilePaths {
    /// `url`'s "/"-separated path inside `folder` ("" for the folder itself), comparing resolved paths per Unicode
    /// scalar; `nil` when it is outside.
    static func relative(_ url: URL, to folder: URL) -> String? {
        let file = NoteDocument.canonical(url).path.unicodeScalars
        var base = Array(NoteDocument.canonical(folder).path.unicodeScalars)
        if base.last == "/" { base.removeLast() }
        if file.elementsEqual(base) { return "" }
        let prefix = base + ["/"]
        guard file.starts(with: prefix) else { return nil }
        return String(file.dropFirst(prefix.count))
    }

    static func isInside(_ url: URL, _ folder: URL) -> Bool { relative(url, to: folder) != nil }

    /// `relative` appended to `folder` component by component.
    static func resolve(_ relative: String, in folder: URL) -> URL {
        NoteStore.components(relative).filter { !$0.isEmpty }.reduce(folder) { $0.appendingPathComponent($1) }
    }

    /// Whether both items live on the same volume (so a move between them is a rename).
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let x = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let y = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        else { return true }
        return x.isEqual(y)
    }

    static func isFolder(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// A folder too large to scan whole: the home folder or one of its parents.
    static func isBroad(_ url: URL) -> Bool {
        isInside(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), url)
    }
}

/// A window's contents: its root folders and their trees, search, the sidebar selection and the open tabs.
/// The main window's workspace holds the user's roots; a file opened from outside them gets a workspace of its own,
/// rooted at its folder.
@Observable @MainActor
final class Workspace: Identifiable {
    let id = UUID()
    /// The main window: the user's roots, New Note and automatic names.
    let isMain: Bool
    @ObservationIgnored weak var model: NotesModel?
    @ObservationIgnored weak var window: NSWindow?
    /// A frame from the session file, applied when the window first appears.
    @ObservationIgnored var pendingFrame: NSRect?

    private(set) var roots: [RootFolder] = []
    /// Configured roots that couldn't be opened; shown greyed in the sidebar with the reason.
    private(set) var unavailableRoots: [UnavailableRoot] = []
    private(set) var tabs: [EditorTab] = [] { didSet { model?.sessionChanged() } }
    private(set) var activeTabID: EditorTab.ID? { didSet { if activeTabID != oldValue { model?.sessionChanged() } } }
    /// The selected sidebar item. Follows the active tab; choosing a file here opens it.
    var selection: ItemID? { didSet { if selection != oldValue && !isSyncingSelection { selectionChanged() } } }
    var isSidebarVisible: Bool {
        didSet {
            guard isSidebarVisible != oldValue else { return }
            if isSidebarVisible { refresh() }
            model?.sessionChanged()
        }
    }

    /// Sidebar folders by absolute path: roots the user collapsed (roots start open) and subfolders the user
    /// expanded (they start closed). Saved with the session.
    var collapsedRoots: Set<String> = [] { didSet { if collapsedRoots != oldValue { model?.sessionChanged() } } }
    var expandedFolders: Set<String> = [] { didSet { if expandedFolders != oldValue { model?.sessionChanged() } } }

    /// Set by ⇧⌘F; the sidebar takes it (once it exists) and puts the cursor in its search field.
    var searchFocusRequested = false

    /// ⇧⌘F: shows the sidebar when it is collapsed and asks it to focus the search field.
    func requestSearchFocus() {
        isSidebarVisible = true
        searchFocusRequested = true
    }

    var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    private(set) var hits: [WorkspaceHit] = []
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var prompt: NamePrompt?
    var promptName = ""
    /// The pinned files that are in this workspace's roots and still exist, in pin order (main window only). Kept up
    /// to date by `updatePinnedItems`, so drawing the sidebar does no file system work.
    private(set) var pinnedItems: [SidebarItem] = []
    /// Long copies and cross-volume moves running in the background (the sidebar shows a progress indicator).
    private(set) var activeOperations = 0
    @ObservationIgnored private var busyPaths: Set<String> = []
    var trashCandidate: ItemID?
    var errorMessage: String?
    /// ⌘P: the Quick Open sheet.
    var isQuickOpenVisible = false

    /// Shows `message` in the error alert after any message already waiting there.
    func report(_ message: String) {
        errorMessage = [errorMessage, message].compactMap { $0 }.joined(separator: "\n")
    }

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// Pending "is it really gone?" checks, per document.
    @ObservationIgnored private var missingChecks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var isSyncingSelection = false
    @ObservationIgnored private var isCloseConfirmed = false

    init(isMain: Bool, sidebarVisible: Bool) {
        self.isMain = isMain
        self.isSidebarVisible = sidebarVisible
    }

    var activeTab: EditorTab? { tabs.first { $0.id == activeTabID } }
    var activeDocument: NoteDocument? { activeTab?.document }
    var documents: [NoteDocument] { tabs.map(\.document) }

    func root(_ id: UUID) -> RootFolder? { roots.first { $0.id == id } }

    // MARK: Roots

    /// Adds `url` as a root; a missing folder is only created with `createIfMissing` (the default notes folder on first
    /// run). Returns why it can't, e.g. when it is missing or inside or around another root (its files would show twice).
    @discardableResult
    func addRoot(_ url: URL, createIfMissing: Bool = false) -> String? {
        let store: NoteStore
        do {
            store = try NoteStore(root: url, createIfMissing: createIfMissing)
        } catch {
            return L("“\(url.lastPathComponent)” couldn't be opened: \(error.localizedDescription)")
        }
        let root = RootFolder(store: store)
        for other in roots {
            if FilePaths.relative(root.url, to: other.url) == "" {
                return L("“\(root.name)” is already in the workspace.")
            }
            if FilePaths.isInside(root.url, other.url) {
                return L("“\(root.name)” is inside “\(other.name)”, which is already in the workspace.")
            }
            if FilePaths.isInside(other.url, root.url) {
                return L("“\(root.name)” contains “\(other.name)”, which is already in the workspace.")
            }
        }
        root.watcher = FolderWatcher(url: store.root) { [weak self, weak root] in
            if let root { self?.rootChanged(root) }
        }
        roots.append(root)
        unavailableRoots.removeAll { $0.url.path == url.standardizedFileURL.path }
        scan(root)
        return nil
    }

    func markUnavailable(_ url: URL, reason: String) {
        unavailableRoots.removeAll { $0.url.path == url.path }
        unavailableRoots.append(UnavailableRoot(url: url, reason: reason))
    }

    func dropUnavailable(path: String) {
        unavailableRoots.removeAll { $0.url.path == path }
    }

    /// "Remove Folder from Workspace": saves and closes the root's tabs and drops it. Nothing on disk changes.
    /// `false`, with the reason shown, when a save needs the user.
    @discardableResult
    func removeRoot(_ root: RootFolder) -> Bool {
        let inside = tabs.filter { !$0.document.isDraft && FilePaths.isInside($0.document.url, root.url) }
        for tab in inside where !tab.document.flush() {
            errorMessage = L("“\(tab.document.name)” couldn't be saved, so “\(root.name)” stays in the workspace. \(tab.document.error ?? "")")
            tab.document.error = nil
            return false
        }
        inside.forEach { remove($0) }
        root.scanToken?.cancel()
        root.scanToken = nil
        root.watcher = nil
        roots.removeAll { $0 === root }
        if selection?.root == root.id { setSelectionQuietly(nil) }
        if trashCandidate?.root == root.id { trashCandidate = nil }
        if isSearching { scheduleSearch() }
        return true
    }

    // MARK: Refreshing

    /// A workspace opened for one file scans its folder only once the sidebar is shown, so a large folder costs nothing
    /// until then.
    private var wantsTree: Bool { isMain || isSidebarVisible }

    /// Re-reads every root's tree off the main thread and reloads open files that changed on disk. Runs on activation
    /// and after our own changes; repeated calls while a scan runs collapse into one more scan.
    func refresh() {
        roots.forEach(scan)
        checkOpenDocuments()
        if isSearching { scheduleSearch() }
    }

    /// A file system event below `root`: only that root is scanned again.
    private func rootChanged(_ root: RootFolder) {
        scan(root)
        checkOpenDocuments()
        if isSearching { scheduleSearch() }
    }

    /// Scans again with the current listing settings even when nothing on disk changed; a scan in flight (with the old
    /// settings) is dropped.
    func rescan() {
        for root in roots {
            root.scanToken?.cancel()
            root.scanToken = nil
            root.isScanning = false
            root.rescanPending = false
            root.tree = nil
        }
        refresh()
    }

    /// The listing settings for `root`; an outside file's window rooted at a huge folder (home) lists only a few levels.
    func listingOptions(for root: RootFolder) -> ListingOptions {
        var options = model?.listingOptions ?? ListingOptions()
        if !isMain, FilePaths.isBroad(root.url) { options.maxDepth = 4 }
        return options
    }

    private func scan(_ root: RootFolder) {
        guard wantsTree else { return }
        guard !root.isScanning else {
            root.rescanPending = true
            return
        }
        root.isScanning = true
        let options = listingOptions(for: root)
        let store = root.store
        let token = ScanToken()
        root.scanToken = token
        Task { [weak self, weak root] in
            let tree = await Task.detached { store.tree(options) { !token.isCancelled } }.value
            guard let root, root.scanToken === token, !token.isCancelled else { return }
            root.isScanning = false
            if tree != root.tree {
                root.tree = tree
                root.items = SidebarItem.items(tree, root: root.id)
            }
            self?.dropStaleSelection(in: root)
            self?.updatePinnedItems()
            if root.rescanPending {
                root.rescanPending = false
                self?.scan(root)
            }
        }
    }

    /// A selected item that is gone from disk is dropped, so the next New Note doesn't aim at it.
    private func dropStaleSelection(in root: RootFolder) {
        guard let selection, selection.root == root.id, !selection.isRoot else { return }
        if let url = url(for: selection), !FileManager.default.fileExists(atPath: url.path) {
            setSelectionQuietly(nil)
            syncSelection()
        }
    }

    private func checkOpenDocuments() {
        var seen = Set<ObjectIdentifier>()
        for document in documents where !document.isDraft && seen.insert(ObjectIdentifier(document)).inserted {
            if FileManager.default.fileExists(atPath: document.url.path) {
                document.reloadIfChanged()
            } else if !document.hasUnsavedChanges {
                closeIfStillMissing(document)
            }
        }
    }

    /// Closes the tabs of `document` when its file is gone for good. Some apps save by deleting and recreating the
    /// file, so this waits a moment first.
    private func closeIfStillMissing(_ document: NoteDocument) {
        guard missingChecks[document.id] == nil else { return }
        missingChecks[document.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.missingChecks[document.id] = nil
            guard !document.hasUnsavedChanges, !FileManager.default.fileExists(atPath: document.url.path) else { return }
            self.removeTabs { $0 === document }
        }
    }

    // MARK: Locating

    /// The root item at `url` when it is a listed file or a folder inside one of the roots.
    func locate(_ url: URL) -> ItemID? {
        for root in roots {
            guard let path = FilePaths.relative(url, to: root.url) else { continue }
            if path.isEmpty { return ItemID(root: root.id, path: "") }
            guard (try? root.store.url(for: path)) != nil else { return nil }
            guard NoteStore.isListed(path) || FilePaths.isFolder(url) else { return nil }
            return ItemID(root: root.id, path: path)
        }
        return nil
    }

    func url(for item: ItemID) -> URL? {
        guard let root = root(item.root) else { return nil }
        return item.isRoot ? root.url : try? root.store.url(for: item.path)
    }

    func contains(_ url: URL) -> Bool { roots.contains { FilePaths.isInside(url, $0.url) } }

    // MARK: Tabs

    private func tab(showing url: URL) -> EditorTab? {
        let key = NoteDocument.canonical(url)
        return tabs.first { NoteDocument.canonical($0.document.url) == key }
    }

    func setSelectionQuietly(_ item: ItemID?) {
        isSyncingSelection = true
        selection = item
        isSyncingSelection = false
    }

    /// Selects the active tab's file in the sidebar; a draft or an outside file leaves the selection as it is.
    func syncSelection() {
        guard let document = activeDocument, !document.isDraft, let item = locate(document.url) else { return }
        setSelectionQuietly(item)
    }

    private func selectionChanged() {
        guard let selection else {
            // A ⌘-click on the selected row clears it; the active tab's file stays the selection.
            syncSelection()
            return
        }
        guard !selection.isRoot, NoteStore.isListed(selection.path), let url = url(for: selection),
              FileManager.default.fileExists(atPath: url.path), !FilePaths.isFolder(url)
        else { return }
        if !open(url, newTab: NSEvent.modifierFlags.contains(.command)) { syncSelection() }
    }

    /// The active tab holds an empty draft: a file opens in it instead of in a new tab.
    private var activeTabIsEmptyDraft: Bool { activeDocument.map { $0.isDraft && $0.text.isEmpty } ?? false }

    /// Shows the file at `url`: focuses its tab if it has one; otherwise opens it in the active tab (after saving that
    /// tab's file; if the save fails nothing changes and its error says why) or, with `newTab`, in a new tab. An
    /// empty draft in the active tab is replaced; a draft with text is never replaced.
    @discardableResult
    func open(_ url: URL, newTab: Bool, focus: Bool = false) -> Bool {
        if let tab = tab(showing: url) {
            model?.recordRecent(url)
            return activate(tab, focus: focus)
        }
        let document: NoteDocument
        do {
            document = try NoteDocument.open(url)
        } catch {
            errorMessage = L("“\(url.lastPathComponent)” couldn't be opened: \(error.localizedDescription)")
            return false
        }
        model?.configure(document)
        if let current = activeTab, activeTabIsEmptyDraft || (!newTab && !current.document.isDraft) {
            let old = current.document
            guard old.flush() else { return false }
            if old.isDraft { old.discardDraft() }
            current.document = document
            current.viewState = nil
            current.showsSource = false
            current.focusOnShow = focus
            syncSelection()
            model?.recordRecent(url)
            model?.sessionChanged()
            return true
        }
        guard insert(EditorTab(document: document), focus: focus) else { return false }
        model?.recordRecent(url)
        return true
    }

    /// Adds `tab` after the active one and shows it; `false` when the active tab's file couldn't be saved.
    @discardableResult
    private func insert(_ tab: EditorTab, focus: Bool) -> Bool {
        if let current = activeTab {
            captureViewState(of: current)
            guard current.document.flush() else { return false }
        }
        let index = activeTab.flatMap { active in tabs.firstIndex { $0 === active } }.map { $0 + 1 } ?? tabs.count
        tab.focusOnShow = focus
        tabs.insert(tab, at: index)
        activeTabID = tab.id
        syncSelection()
        return true
    }

    /// Adds a tab at the end without showing it (restoring a session).
    func append(_ tab: EditorTab) {
        guard !tabs.contains(where: { $0.document === tab.document }) else { return }
        tabs.append(tab)
        if activeTabID == nil { activeTabID = tab.id }
    }

    func setActiveTab(index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabID = tabs[index].id
        syncSelection()
    }

    /// Shows `tab`, saving the one it replaces first; `false` (staying put) when that save needs the user.
    @discardableResult
    func activate(_ tab: EditorTab, focus: Bool = false) -> Bool {
        guard tab.id != activeTabID else {
            if focus { restoreEditor(of: tab, focus: true) }
            return true
        }
        if let current = activeTab {
            captureViewState(of: current)
            guard current.document.flush() else {
                syncSelection()
                return false
            }
        }
        if focus { tab.focusOnShow = true }
        activeTabID = tab.id
        syncSelection()
        return true
    }

    /// ⌘T: a new draft in a tab after the active one; nothing is written to a notes folder.
    func newDraftTab() {
        guard let url = model?.newDraftURL() else { return }
        let document = NoteDocument.newDraft(at: url)
        model?.configure(document)
        insert(EditorTab(document: document), focus: true)
    }

    /// ⌃Tab / ⌃⇧Tab, ⇧⌘] / ⇧⌘[.
    func cycleTab(_ delta: Int) {
        guard tabs.count > 1, let active = activeTab, let index = tabs.firstIndex(where: { $0 === active }) else { return }
        activate(tabs[(index + delta + tabs.count) % tabs.count], focus: true)
    }

    /// ⌘1…⌘8 pick that tab; ⌘9 the last one.
    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        guard tabs.indices.contains(index) else { return }
        activate(tabs[index], focus: true)
    }

    /// Drag and drop in the tab bar: puts `tab` where `target` is.
    func move(_ tab: EditorTab, to target: EditorTab) {
        guard tab !== target, let from = tabs.firstIndex(where: { $0 === tab }),
              let to = tabs.firstIndex(where: { $0 === target })
        else { return }
        tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    func toggleSource() {
        guard let tab = activeTab, tab.document.language == .markdown else { return }
        captureViewState(of: tab)
        tab.showsSource.toggle()
        model?.sessionChanged()
        restoreEditor(of: tab, focus: false)
    }

    func captureViewState(of tab: EditorTab) {
        guard let window, let textView = tab.document.textView(in: window) else { return }
        tab.viewState = EditorViewState(textView)
    }

    /// Called when a tab's editor appears: puts back its selection and scroll position and focuses it when asked.
    func editorAppeared(_ tab: EditorTab) {
        let focus = tab.focusOnShow || tab.document.focusOnOpen
        tab.focusOnShow = false
        tab.document.focusOnOpen = false
        restoreEditor(of: tab, focus: focus)
    }

    /// The editor's text view exists only once SwiftUI has put it in the window, so this retries for a moment.
    private func restoreEditor(of tab: EditorTab, focus: Bool) {
        let state = tab.viewState
        guard state != nil || focus else { return }
        Task { [weak self] in
            for _ in 0..<40 {
                guard let self, self.activeTab === tab else { return }
                if let window = self.window, let textView = tab.document.textView(in: window) {
                    textView.enclosingScrollView?.superview?.layoutSubtreeIfNeeded()
                    state?.apply(to: textView)
                    if focus { window.makeFirstResponder(textView) }
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    // MARK: Closing tabs

    /// ⌘W: closes the active tab; with no tabs left, the window.
    func closeActiveTabOrWindow() {
        if let tab = activeTab {
            close(tab)
        } else if let window {
            model?.closeForLastTab(window, of: self)
        }
    }

    /// Closes `tab` after saving it. A draft with text asks Save / Don't Save / Cancel; an empty one just goes away.
    /// A failed save asks whether to discard the edits.
    func close(_ tab: EditorTab) {
        let document = tab.document
        if document.isDraft {
            if document.text.isEmpty {
                document.discardDraft()
                remove(tab, closingWindowIfEmpty: true)
            } else {
                askAboutDraft(in: tab)
            }
            return
        }
        captureViewState(of: tab)
        guard SaveGuard.flush([document], in: window, discard: L("Close Without Saving"), then: { [weak self] in
            self?.remove(tab, closingWindowIfEmpty: true)
        }) else { return }
        remove(tab, closingWindowIfEmpty: true)
    }

    func closeOtherTabs(than tab: EditorTab) {
        for other in tabs where other !== tab {
            guard activate(tab) else { return }
            close(other)
            // A draft with text or a failed save asks first; stop there instead of stacking dialogs.
            if tabs.contains(where: { $0 === other }) { return }
        }
    }

    private func askAboutDraft(in tab: EditorTab) {
        let document = tab.document
        let alert = NSAlert()
        alert.messageText = L("Save “\(document.name)”?")
        alert.informativeText = L("This note has not been saved to a folder yet.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Don't Save")).hasDestructiveAction = true
        alert.addButton(withTitle: L("Cancel"))
        SaveGuard.present(alert, in: window) { [weak self] response in
            guard let self, self.tabs.contains(where: { $0 === tab }), tab.document === document else { return }
            switch response {
            case .alertFirstButtonReturn:
                if self.saveDraft(document) { self.remove(tab, closingWindowIfEmpty: true) }
            case .alertSecondButtonReturn:
                document.discardDraft()
                self.remove(tab, closingWindowIfEmpty: true)
            default:
                break
            }
        }
    }

    /// Takes `tab` out without saving (the caller saved it, or its file is gone). When the user closed it and it was
    /// the last one, the window closes too (the app stays open).
    func remove(_ tab: EditorTab, closingWindowIfEmpty: Bool = false) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let wasActive = tab.id == activeTabID
        tabs.remove(at: index)
        if wasActive {
            activeTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            syncSelection()
        }
        // On the next turn: from a sheet's completion (a draft's Save / Don't Save) the sheet is still attached and
        // the window would ignore the close. A file that arrived meanwhile keeps the window.
        if closingWindowIfEmpty, tabs.isEmpty, window != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.tabs.isEmpty, let window = self.window, window.isVisible, window.attachedSheet == nil else { return }
                self.model?.closeForLastTab(window, of: self)
            }
        }
    }

    func removeTabs(where shouldRemove: (NoteDocument) -> Bool) {
        tabs.filter { shouldRemove($0.document) }.forEach { remove($0) }
    }

    /// Before the window closes: saves every file (asking when that fails). Drafts are kept by the store, except when
    /// this process could only use a temporary one; then it asks first.
    func shouldClose(_ window: NSWindow) -> Bool {
        // ⌘W reached the window's own Close item: it closes the active tab; only with no tabs left the window.
        if let tab = activeTab, let event = NSApp.currentEvent, event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            close(tab)
            return false
        }
        if let tab = activeTab { captureViewState(of: tab) }
        model?.saveSessionSoon()
        if !isCloseConfirmed, model?.draftsArePending == true,
           documents.contains(where: { $0.isDraft && !$0.text.isEmpty }) {
            let alert = NSAlert()
            alert.messageText = L("Close this window?")
            alert.informativeText = L("Another Notes process owns the drafts folder, so the drafts in this window are kept in a separate folder until it quits.")
            alert.addButton(withTitle: L("Cancel"))
            alert.addButton(withTitle: L("Close"))
            SaveGuard.present(alert, in: window) { [weak self, weak window] response in
                guard response == .alertSecondButtonReturn else { return }
                self?.isCloseConfirmed = true
                window?.performClose(nil)
            }
            return false
        }
        isCloseConfirmed = false
        documents.filter(\.isDraft).forEach { $0.flush() }
        return SaveGuard.flush(documents.filter { !$0.isDraft }, in: window,
                               discard: L("Close Without Saving")) { [weak window] in window?.close() }
    }

    /// Hands the drafts with text and the files with unsaved changes (a failed save) to `other` when an outside file's
    /// window is closing; empty drafts are deleted, saved files simply close.
    func moveUnsavedDocuments(to other: Workspace) {
        for tab in tabs {
            let document = tab.document
            if document.isDraft && document.text.isEmpty {
                document.discardDraft()
            } else if document.isDraft || document.hasUnsavedChanges {
                other.append(EditorTab(document: document))
            }
        }
        tabs.removeAll()
        activeTabID = nil
    }

    // MARK: Drafts

    /// ⌘S: a draft becomes a note in the selected folder; other files are written now.
    func saveActive() {
        if let document = activeDocument, document.isDraft {
            saveDraft(document)
        } else {
            NoteDocument.flushAll()
        }
    }

    /// Saves a draft as a note named by its first line in the selected folder (the selected file's folder, else the
    /// first root). The tab then shows that note like any other. `false` when nothing was saved.
    @discardableResult
    func saveDraft(_ document: NoteDocument) -> Bool {
        guard document.isDraft else { return true }
        guard !document.text.isEmpty else { return false }
        guard let folder = targetFolder, let root = root(folder.root) else {
            errorMessage = L("There is no folder to save the note in. Add a folder to the workspace first.")
            return false
        }
        let parent = folder.isRoot ? nil : folder.path
        let text = document.text
        do {
            let name = root.store.uniqueNoteName(NoteStore.title(from: text) ?? NoteStore.untitledName, in: parent)
            let path = try root.store.createNote(named: name, in: parent)
            let url = try root.store.url(for: path)
            do {
                try NoteFile.write(text, to: url)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            document.becomeFile(url, writtenText: text, stamp: NoteFile.stamp(url))
            model?.configure(document)
            model?.sessionChanged()
            query = ""
            refresh()
            setSelectionQuietly(ItemID(root: root.id, path: path))
            return true
        } catch {
            errorMessage = L("“\(document.name)” couldn't be saved: \(error.localizedDescription)")
            return false
        }
    }

    /// ⇧⌘S: writes the active note's text to a file the user picks, which the tab then shows (a draft is replaced).
    func saveAs() {
        guard let tab = activeTab else { return }
        let document = tab.document
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let isMarkdownNote = document.isDraft || document.isNote
        let isEncrypted = document.isEncrypted
        // A locked note has no text to save.
        guard !document.isLocked else { return }
        panel.nameFieldStringValue = isEncrypted ? document.name + ".mdenc"
            : isMarkdownNote ? document.name + ".md" : document.url.lastPathComponent
        if isEncrypted {
            panel.allowedContentTypes = [.encryptedNote]
        } else if isMarkdownNote {
            panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        }
        panel.directoryURL = document.isDraft ? targetFolder.flatMap(url(for:)) : document.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, var url = panel.url else { return }
        guard !document.isLocked else {
            errorMessage = Self.lockedMeanwhile
            return
        }
        // Plain text is never saved under the name of an encrypted note.
        if !isEncrypted, NoteStore.isEncrypted(url.lastPathComponent) {
            errorMessage = L("A plain note can't be saved with the .mdenc extension. Choose another name.")
            return
        }
        // The copy of an encrypted note is an encrypted note: its name always ends in .mdenc.
        if isEncrypted, !NoteStore.isEncrypted(url.lastPathComponent) { url.appendPathExtension(NoteCrypto.fileExtension) }
        if !document.isDraft, NoteDocument.canonical(url) == NoteDocument.canonical(document.url) {
            document.flush()
            return
        }
        let text = document.text
        do {
            if isEncrypted {
                try NoteFile.write(document.encryptedCopy(), to: url)
                if let key = document.encryptionKey { Keyring.shared.remember(key) }
            } else {
                try NoteFile.write(text, to: url)
            }
        } catch {
            errorMessage = L("“\(url.lastPathComponent)” couldn't be saved: \(error.localizedDescription)")
            return
        }
        refresh()
        if document.isDraft {
            guard let saved = try? NoteDocument.open(url) else { return }
            model?.configure(saved)
            document.discardDraft()
            tab.document = saved
            tab.viewState = nil
            tab.focusOnShow = true
            syncSelection()
            model?.sessionChanged()
        } else {
            open(url, newTab: false, focus: true)
        }
    }

    // MARK: Creating, renaming, trashing

    /// The folder new items go into: the selected folder or root, the selected file's folder, else the first root.
    /// A selection that is gone from disk walks up to the nearest folder that still exists, else its root, so nothing
    /// is ever created inside a deleted folder.
    var targetFolder: ItemID? {
        if let selection, let root = root(selection.root) {
            var path = selection.path
            while !path.isEmpty {
                if let url = try? root.store.url(for: path), FilePaths.isFolder(url) { return ItemID(root: root.id, path: path) }
                path = NoteStore.parent(path)
            }
            return ItemID(root: root.id, path: "")
        }
        return roots.first.map { ItemID(root: $0.id, path: "") }
    }

    /// Creates "Untitled" ("Untitled 2"…, "Adsız" in Turkish) right away in the active tab if it holds an empty draft,
    /// else in a new tab, and focuses the editor; the first line names it later.
    func newNote() {
        guard let folder = targetFolder, let root = root(folder.root) else {
            errorMessage = L("There is no folder to save the note in. Add a folder to the workspace first.")
            return
        }
        // Save first, so a failed save doesn't leave a new empty note behind.
        if let document = activeDocument, !document.flush() { return }
        let parent = folder.isRoot ? nil : folder.path
        do {
            let path = try root.store.createNote(named: root.store.uniqueNoteName(NoteStore.untitledName, in: parent), in: parent)
            query = ""
            refresh()
            open(try root.store.url(for: path), newTab: true, focus: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func newFolder() {
        guard let folder = targetFolder else { return }
        ask(.newFolder(in: folder), name: L("New Folder"))
    }

    func rename(_ item: ItemID) {
        guard !item.isRoot else { return }
        ask(.rename(item), name: NoteStore.displayName(item.path))
    }

    func ask(_ prompt: NamePrompt, name: String) {
        promptName = name
        self.prompt = prompt
    }

    /// Runs the prompt's action; `prompt` is the one the alert showed (passed in, since the alert clears
    /// `self.prompt` before its button action runs).
    func commitPrompt(_ prompt: NamePrompt) {
        // Still set if the alert calls the action before dismissing; then it has followed any automatic rename.
        let prompt = self.prompt ?? prompt
        self.prompt = nil
        do {
            switch prompt {
            case .newEncrypted(let parent):
                let name = promptName
                // After the alert has gone: the password dialogs run modally.
                DispatchQueue.main.async { self.createEncryptedNote(named: name, in: parent) }
            case .encrypt(let item):
                let name = promptName
                DispatchQueue.main.async { self.startEncrypting(item, named: name) }
            case .newFolder(let parent):
                guard let root = root(parent.root) else { return }
                let path = try root.store.createFolder(named: promptName, in: parent.isRoot ? nil : parent.path)
                query = ""
                refresh()
                setSelectionQuietly(ItemID(root: root.id, path: path))
            case .rename(let item):
                guard let root = root(item.root),
                      let path = saveDocuments(in: root, inside: item.path, cancelled: L("The rename was cancelled."))
                else { return }
                let oldURL = try root.store.url(for: path)
                // Before the rename: afterwards the old URL no longer resolves.
                let affected = NoteDocument.all.compactMap { document in
                    document.isDraft ? nil : FilePaths.relative(document.url, to: oldURL).map { (document, $0) }
                }
                let newPath = try root.store.rename(path, to: promptName)
                guard newPath != path else { return }
                let newURL = try root.store.url(for: newPath)
                // Keep the open documents (text, cursor, undo) and point them at the new location.
                for (document, relative) in affected {
                    // Renaming the note itself is a hand-picked name; renaming its folder is not.
                    if relative.isEmpty { document.renamedByHand(to: newURL) } else { document.moved(to: FilePaths.resolve(relative, in: newURL)) }
                }
                itemMoved(in: root, from: path, to: newPath)
                model?.itemMoved(from: oldURL, to: newURL)
                model?.itemsChanged(by: self)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Rewrites the selection and the paths held by open dialogs after `old` became `new` in `root`.
    func itemMoved(in root: RootFolder, from old: String, to new: String) {
        relocate(from: ItemID(root: root.id, path: old), to: ItemID(root: root.id, path: new))
    }

    /// The same for an item that may have changed root.
    private func relocate(from old: ItemID, to new: ItemID) {
        func moved(_ item: ItemID?) -> ItemID? {
            guard let item, item.root == old.root, let path = NoteStore.moved(item.path, from: old.path, to: new.path) else { return nil }
            return ItemID(root: new.root, path: path)
        }
        if let item = moved(selection) { setSelectionQuietly(item) }
        if case .rename(let target)? = prompt, let item = moved(target) { prompt = .rename(item) }
        if case .newFolder(let target)? = prompt, let item = moved(target) { prompt = .newFolder(in: item) }
        if case .encrypt(let target)? = prompt, let item = moved(target) { prompt = .encrypt(item) }
        if case .newEncrypted(let target)? = prompt, let item = moved(target) { prompt = .newEncrypted(in: item) }
        if let item = moved(trashCandidate) { trashCandidate = item }
    }

    func trash(_ item: ItemID) {
        guard !item.isRoot, let root = root(item.root),
              let path = saveDocuments(in: root, inside: item.path, cancelled: L("Moving to the Trash was cancelled."))
        else { return }
        do {
            let url = try root.store.url(for: path)
            let affected = NoteDocument.all.filter { !$0.isDraft && FilePaths.isInside($0.url, url) }
            try root.store.trash(path)
            model?.itemTrashed(url)
            model?.documentsRemoved(affected)
            if let selection, selection.root == root.id, NoteStore.moved(selection.path, from: path, to: path) != nil {
                setSelectionQuietly(nil)
            }
            model?.itemsChanged(by: self)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves the open files at or below `path` before it is renamed or trashed and returns `path`, following it if a
    /// save auto-renamed it. `nil` when a save needs the user and its file is still inside `path`: the operation is
    /// then cancelled (`cancelled` says so after the save's own message).
    func saveDocuments(in root: RootFolder, inside path: String, cancelled: String) -> String? {
        guard let target = try? root.store.url(for: path) else { return path }
        var path = path
        for document in NoteDocument.all where !document.isDraft && FilePaths.isInside(document.url, target) {
            let before = locate(document.url)
            let saved = document.flush()
            if let before, let after = locate(document.url), before.root == root.id, after.root == root.id {
                path = NoteStore.moved(path, from: before.path, to: after.path) ?? path
            }
            guard !saved, let current = try? root.store.url(for: path), FilePaths.isInside(document.url, current) else { continue }
            let message = [document.error, cancelled].compactMap { $0 }.joined(separator: " ")
            if documents.contains(where: { $0 === document }) {
                document.error = message
            } else {
                document.error = nil
                errorMessage = message
            }
            return nil
        }
        return path
    }

    // MARK: Moving, duplicating, dropping

    /// Moves `item` into `folder`, possibly into another root, with the safety of a rename: unsaved edits are saved
    /// first, open documents follow the file, a taken name gets a number and nothing is overwritten. `false` when
    /// nothing moved (same folder, into itself, a save that needs the user, an error shown in the alert).
    @discardableResult
    func move(_ item: ItemID, into folder: ItemID) -> Bool {
        guard !item.isRoot, let source = root(item.root), let target = root(folder.root),
              let sourceURL = url(for: item), let folderURL = url(for: folder)
        else { return false }
        if item.root == folder.root, NoteStore.parent(item.path).unicodeScalars.elementsEqual(folder.path.unicodeScalars) {
            return false
        }
        if FilePaths.isInside(folderURL, sourceURL) {
            report(L("“\(NoteStore.displayName(item.path))” can't be moved into itself."))
            return false
        }
        guard let path = saveDocuments(in: source, inside: item.path, cancelled: L("The move was cancelled.")) else { return false }
        do {
            let oldURL = try source.store.url(for: path)
            guard !busyPaths.contains(oldURL.standardizedFileURL.path) else { return false }
            // Before the move: afterwards the old URL no longer resolves.
            let affected = NoteDocument.all.compactMap { document in
                document.isDraft ? nil : FilePaths.relative(document.url, to: oldURL).map { (document, $0) }
            }
            let destination = folder.isRoot ? nil : folder.path
            func complete(_ newPath: String) throws {
                let newURL = try target.store.url(for: newPath)
                for (document, relative) in affected { document.moved(to: FilePaths.resolve(relative, in: newURL)) }
                relocate(from: ItemID(root: source.id, path: path), to: ItemID(root: target.id, path: newPath))
                model?.itemMoved(from: oldURL, to: newURL)
                model?.itemsChanged(by: self)
            }
            // Within one volume a move is a rename. A copy and delete across volumes can take long, so it runs off
            // the main thread, unless an open document is inside (its saves must not race the copy).
            if affected.isEmpty, !FilePaths.sameVolume(oldURL, folderURL) {
                let key = oldURL.standardizedFileURL.path
                let store = source.store, targetStore = target.store
                runInBackground(key) {
                    Result { try store.move(path, to: destination, in: targetStore) }
                } completion: { [self] result in
                    do { try complete(try result.get()) } catch { report(error.localizedDescription) }
                }
                return true
            }
            try complete(try source.store.move(path, to: destination, in: target.store))
            return true
        } catch {
            report(error.localizedDescription)
            return false
        }
    }

    /// Runs a long file operation off the main thread. `key` (the item's path) is busy meanwhile, so the same item
    /// is not moved or copied twice; the sidebar shows `activeOperations`. `completion` runs on the main actor, then
    /// the trees are refreshed.
    private func runInBackground<T: Sendable>(
        _ key: String, _ work: @escaping @Sendable () -> Result<T, any Error>,
        completion: @escaping (Result<T, any Error>) -> Void
    ) {
        busyPaths.insert(key)
        activeOperations += 1
        Task { [weak self] in
            let result = await Task.detached { work() }.value
            guard let self else { return }
            busyPaths.remove(key)
            activeOperations -= 1
            completion(result)
            refresh()
            model?.itemsChanged(by: self)
        }
    }

    /// Context menu "Duplicate": a copy next to the file ("<name> copy"), with its unsaved edits saved first. Opens nothing.
    func duplicate(_ item: ItemID) {
        guard !item.isRoot, let root = root(item.root), let url = url(for: item), !FilePaths.isFolder(url),
              let path = saveDocuments(in: root, inside: item.path, cancelled: L("Duplicating was cancelled."))
        else { return }
        do {
            try root.store.duplicate(path)
            refresh()
            model?.itemsChanged(by: self)
        } catch {
            report(error.localizedDescription)
        }
    }

    /// Files or folders dropped on `folder` (a folder row or a root): items of this workspace move there, anything
    /// else (from Finder, another window) is copied in. Returns whether anything was done.
    @discardableResult
    func drop(_ urls: [URL], onto folder: ItemID) -> Bool {
        guard let root = root(folder.root) else { return false }
        var done = false
        for url in urls where url.isFileURL {
            if let item = locate(url), !item.isRoot {
                if move(item, into: folder) { done = true }
                continue
            }
            guard FilePaths.isFolder(url) || NoteStore.isListed(url.lastPathComponent) else { continue }
            let key = url.standardizedFileURL.path
            guard !busyPaths.contains(key) else { continue }
            // Another window may hold unsaved edits of the file (or of files in the folder): copy what the user sees.
            var saved = true
            for document in NoteDocument.all where !document.isDraft && FilePaths.isInside(document.url, url) {
                if !document.flush() {
                    report([document.error, L("Copying was cancelled.")].compactMap { $0 }.joined(separator: " "))
                    saved = false
                    break
                }
            }
            guard saved else { continue }
            let store = root.store
            let destination = folder.isRoot ? nil : folder.path
            runInBackground(key) {
                Result { try store.copyIn(url, to: destination) }
            } completion: { [self] result in
                if case .failure(let error) = result { report(error.localizedDescription) }
            }
            done = true
        }
        if done {
            refresh()
            model?.itemsChanged(by: self)
        }
        return done
    }

    /// Recomputes `pinnedItems` from the model's pins; after a scan and whenever the pins change.
    func updatePinnedItems() {
        guard isMain, let model else {
            if !pinnedItems.isEmpty { pinnedItems = [] }
            return
        }
        let items: [SidebarItem] = model.pins.paths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard let item = locate(url), !item.isRoot, !FilePaths.isFolder(url),
                  let root = root(item.root), let modified = root.store.modificationDate(item.path)
            else { return nil }
            return SidebarItem(id: item, name: NoteStore.displayName(item.path), isFolder: false, children: nil, modified: modified)
        }
        if items != pinnedItems { pinnedItems = items }
    }

    func revealInFinder(_ item: ItemID) {
        guard let url = url(for: item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        guard isSearching else {
            hits = []
            return
        }
        let query = query
        let stores = roots.map { ($0.id, $0.store, listingOptions(for: $0)) }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let hits = await Task.detached {
                stores.flatMap { id, store, options in store.search(query, listing: options).map { WorkspaceHit(root: id, hit: $0) } }
            }.value
            guard !Task.isCancelled else { return }
            self?.hits = hits
        }
    }
}

/// Saving before something closes, and the alerts that need.
@MainActor
enum SaveGuard {
    /// Saves `documents`. `true` when nothing needs the user. Otherwise shows why in one alert (a sheet on `window`):
    /// a failed save offers to try again, to discard the edits (`discard` names that button) or to cancel; a conflict
    /// notice just informs. `proceed` runs once the user discarded, retried successfully, or after the notice;
    /// meanwhile this returns `false`.
    static func flush(_ documents: [NoteDocument], in window: NSWindow?, discard: String,
                      then proceed: @escaping @MainActor () -> Void) -> Bool {
        let failed = documents.filter { !$0.flush() }
        guard !failed.isEmpty else { return true }
        let unsaved = failed.contains { $0.hasUnsavedChanges }
        guard unsaved else {
            inform(failed, in: window, then: proceed)
            return false
        }
        askToSave(failed, in: window, discard: discard, then: proceed)
        return false
    }

    /// The "changed elsewhere" notice for documents whose edits went to a conflict copy; `proceed` runs after it.
    private static func inform(_ documents: [NoteDocument], in window: NSWindow?,
                               then proceed: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = L("A file was changed elsewhere")
        alert.informativeText = documents.compactMap(\.error).joined(separator: "\n\n")
        documents.forEach { $0.error = nil }
        alert.addButton(withTitle: L("OK"))
        present(alert, in: window) { _ in
            documents.forEach { $0.revert() }
            proceed()
        }
    }

    /// The save that failed while closing: "Save" tries again, "Don't Save" discards the edits, "Cancel" keeps
    /// things open. A failed retry shows the alert again with the new error.
    private static func askToSave(_ failed: [NoteDocument], in window: NSWindow?, discard: String,
                                  then proceed: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = L("Some changes couldn't be saved")
        alert.informativeText = failed.compactMap(\.error).joined(separator: "\n\n")
        failed.forEach { $0.error = nil }
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: discard).hasDestructiveAction = true
        alert.addButton(withTitle: L("Cancel"))
        present(alert, in: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                let remaining = failed.filter { !$0.flush() }
                // A conflict copy took the edits of some: those are only a notice, not a failed save.
                let unsaved = remaining.filter(\.hasUnsavedChanges)
                let conflicted = remaining.filter { !$0.hasUnsavedChanges }
                // After the sheet has finished closing, not from inside its completion.
                DispatchQueue.main.async {
                    if !unsaved.isEmpty {
                        askToSave(unsaved, in: window, discard: discard) {
                            if conflicted.isEmpty { proceed() } else { inform(conflicted, in: window, then: proceed) }
                        }
                    } else if !conflicted.isEmpty {
                        inform(conflicted, in: window, then: proceed)
                    } else {
                        proceed()
                    }
                }
            case .alertSecondButtonReturn:
                failed.forEach { $0.revert() }
                proceed()
            default:
                break
            }
        }
    }

    static func present(_ alert: NSAlert, in window: NSWindow?,
                        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard let window, window.isVisible, window.attachedSheet == nil else {
            completion(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { completion(response) }
        }
    }
}
