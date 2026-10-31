import AppKit
import NotesCore

enum WindowRequest: Equatable {
    case main
    case workspace(UUID)
}

/// The app: the main window's workspace (the user's roots), the windows of files opened from outside them, drafts and
/// the saved session.
@Observable @MainActor
final class NotesModel {
    private static let rootsKey = "workspaceRoots"
    /// The single notes folder saved by earlier versions; read once when there is no root list yet.
    private static let legacyRootKey = "notesFolder"

    let main: Workspace
    private(set) var external: [Workspace] = []
    /// Windows the views should open; consumed by `WindowRequestHandler`.
    var windowRequests: [WindowRequest] = []

    /// Pinned files (`pins.json`) and the last opened ones (`recents.json`), absolute paths.
    private(set) var pins = PathList()
    private(set) var recents = PathList()
    static let recentLimit = 10
    let previews = PreviewCache()

    @ObservationIgnored private var draftStore: DraftStore?
    /// Another process owns the draft store, so this one keeps its drafts in a pending store of its own.
    @ObservationIgnored private(set) var draftsArePending = false
    /// This process holds the real draft store's lock (or runs on a throwaway test store): only then it writes or
    /// restores the session, which belongs to the owner of the app state (docs/format.md).
    @ObservationIgnored private(set) var ownsDraftStore = false
    /// A test run's throwaway draft folder, deleted on quit.
    @ObservationIgnored private var temporaryDrafts: URL?
    @ObservationIgnored private var lastDraftOrder: [String]?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var isRestoring = false
    @ObservationIgnored private var hasQuit = false

    /// The roots the user configured, in order, whether or not they could be opened this time: a folder that is missing
    /// now (an unmounted volume) is still in the list and comes back when it reappears.
    private(set) var configuredRoots: [String] = []

    init() {
        main = Workspace(isMain: true, sidebarVisible: true)
        main.model = self
        let initial = Self.initialRoots()
        // Standardized, so `removeRoot` finds a root by the path the workspace reports.
        var seen = Set<String>()
        configuredRoots = initial.paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }.filter { seen.insert($0).inserted }
        for path in configuredRoots {
            openRoot(URL(fileURLWithPath: path, isDirectory: true), createIfMissing: initial.createsDefault)
        }
        if initial.isFirstRun { persistRoots() }
        publishRoots()
        let settings = AppSettings.shared
        settings.addRoot = { [weak self] in self?.chooseRoot() }
        settings.removeRoot = { [weak self] path in self?.removeRoot(path: path) }
        setUpDrafts()
        loadLists()
        restore()
    }

    var workspaces: [Workspace] { [main] + external }

    func workspace(_ id: UUID) -> Workspace? { workspaces.first { $0.id == id } }

    /// The sidebar settings as the store's listing options.
    var listingOptions: ListingOptions {
        let settings = AppSettings.shared
        return ListingOptions(order: settings.sidebarSort == .modified ? .modified : .name,
                              markdownOnly: !settings.showNonMarkdownFiles)
    }

    func refreshAll() {
        retryUnavailableRoots()
        workspaces.forEach { $0.refresh() }
    }

    // MARK: Roots

    /// `-notesFolder <path>` (repeatable) for a test run; else the saved list; else the folder of earlier versions; else
    /// `~/Documents/Notes`, the only root that is created when missing and only on the very first run.
    private static func initialRoots() -> (paths: [String], createsDefault: Bool, isFirstRun: Bool) {
        if !LaunchOptions.testRoots.isEmpty { return (LaunchOptions.testRoots, false, false) }
        let defaults = UserDefaults.standard
        if let roots = defaults.stringArray(forKey: rootsKey) { return (roots, false, false) }
        if let legacy = defaults.string(forKey: legacyRootKey) { return ([legacy], false, true) }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ([documents.appendingPathComponent("Notes").standardizedFileURL.path], true, true)
    }

    /// Opens `url` in the main window. When it can't be, the root stays configured and shows as unavailable.
    @discardableResult
    private func openRoot(_ url: URL, createIfMissing: Bool = false) -> Bool {
        guard let problem = main.addRoot(url, createIfMissing: createIfMissing) else { return true }
        main.markUnavailable(url.standardizedFileURL, reason: problem)
        main.report(problem)
        return false
    }

    /// A configured root that was missing may be back (volume mounted, folder restored).
    private func retryUnavailableRoots() {
        for item in main.unavailableRoots where FilePaths.isFolder(item.url) {
            main.addRoot(item.url)
        }
    }

    private func persistRoots() {
        if LaunchOptions.isPersistent {
            UserDefaults.standard.set(configuredRoots, forKey: Self.rootsKey)
        }
    }

    /// Remembers the root list (never in a test run) and shows it in Settings.
    private func rootsChanged() {
        persistRoots()
        publishRoots()
        main.refresh()
    }

    private func publishRoots() {
        AppSettings.shared.workspaceRoots = configuredRoots
    }

    /// "Add Folder…": asks for a folder and adds it to the main window's workspace.
    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("Add")
        panel.message = L("Choose folders to add to the workspace")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let problem = main.addRoot(url) {
                main.report(problem)
            } else if !configuredRoots.contains(url.standardizedFileURL.path) {
                configuredRoots.append(url.standardizedFileURL.path)
            }
        }
        rootsChanged()
        windowRequests.append(.main)
    }

    func removeRoot(_ root: RootFolder) {
        guard main.removeRoot(root) else {
            windowRequests.append(.main)
            return
        }
        configuredRoots.removeAll { $0 == root.url.path }
        rootsChanged()
    }

    /// Removes a configured root by path, whether it is open or unavailable.
    func removeRoot(path: String) {
        if let root = main.roots.first(where: { $0.url.path == path }) {
            removeRoot(root)
        } else if configuredRoots.contains(path) {
            main.dropUnavailable(path: path)
            configuredRoots.removeAll { $0 == path }
            rootsChanged()
        }
    }

    // MARK: Documents

    /// Hooks a document up to automatic naming and relocation; every workspace calls this for what it opens.
    func configure(_ document: NoteDocument) {
        document.autoRename = { [weak self] in self?.autoRename($0, to: $1) }
        document.relocated = { [weak self] _ in
            self?.itemsChanged(by: nil)
            self?.sessionChanged()
        }
    }

    /// Renames an auto-named note after its first line (docs/format.md) while it stays open. Only notes inside the
    /// main window's roots are named automatically, and only while the setting is on.
    private func autoRename(_ document: NoteDocument, to title: String) {
        guard AppSettings.shared.autoNaming, !document.isDraft, let item = main.locate(document.url), !item.isRoot,
              let root = main.root(item.root)
        else { return }
        let path = item.path
        let folder = NoteStore.parent(path)
        // On failure the text is still saved; the name is retried after the next save.
        guard let newPath = try? root.store.rename(path, to: root.store.uniqueNoteName(title, in: folder, ignoring: path) + ".md"),
              newPath != path, let url = try? root.store.url(for: newPath)
        else { return }
        let oldURL = (try? root.store.url(for: path)) ?? url
        document.moved(to: url)
        main.itemMoved(in: root, from: path, to: newPath)
        itemMoved(from: oldURL, to: url)
        itemsChanged(by: main)
    }

    /// Files moved or vanished: every other workspace re-reads its trees and selects its active file again.
    func itemsChanged(by origin: Workspace?) {
        for workspace in workspaces where workspace !== origin {
            workspace.refresh()
            workspace.syncSelection()
        }
        origin?.refresh()
        sessionChanged()
    }

    /// Closes the tabs of documents whose files went to the Trash, in every window.
    func documentsRemoved(_ documents: [NoteDocument]) {
        let removed = Set(documents.map(ObjectIdentifier.init))
        workspaces.forEach { $0.removeTabs { removed.contains(ObjectIdentifier($0)) } }
    }

    // MARK: Pins and recents

    private func listURL(_ name: String) -> URL? { LaunchOptions.supportFolder?.appendingPathComponent(name) }

    /// Reads both lists; a run without a support folder (a test run) keeps them in memory only.
    private func loadLists() {
        if let url = listURL("pins.json"), let list = PathList.read(url) { pins = list }
        if let url = listURL("recents.json"), let list = PathList.read(url) { recents = list }
    }

    /// Writes a list atomically, only from the process that owns the app state (like `session.json`).
    private func write(_ list: PathList, as name: String) {
        guard ownsDraftStore, !hasQuit, let url = listURL(name) else { return }
        try? list.write(to: url)
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    func isPinned(_ url: URL) -> Bool { pins.contains(Self.key(url)) }

    func togglePin(_ url: URL) {
        if isPinned(url) { pins.remove(Self.key(url)) } else { pins.append(Self.key(url)) }
        write(pins, as: "pins.json")
        workspaces.forEach { $0.updatePinnedItems() }
    }

    /// Notes opened by the user, newest first; files that no longer exist are skipped by the menu.
    func recordRecent(_ url: URL) {
        guard NoteStore.isListed(url.lastPathComponent) else { return }
        recents.push(Self.key(url), limit: Self.recentLimit)
        write(recents, as: "recents.json")
    }

    func clearRecents() {
        recents = PathList()
        write(recents, as: "recents.json")
    }

    /// An item was renamed or moved: pins and recents follow it.
    func itemMoved(from old: URL, to new: URL) {
        let before = (pins, recents)
        pins.moved(from: Self.key(old), to: Self.key(new))
        recents.moved(from: Self.key(old), to: Self.key(new))
        if pins != before.0 {
            write(pins, as: "pins.json")
            workspaces.forEach { $0.updatePinnedItems() }
        }
        if recents != before.1 { write(recents, as: "recents.json") }
    }

    /// An item went to the Trash: its pin goes (recents are skipped by the menu while the file is missing).
    func itemTrashed(_ url: URL) {
        let before = pins
        pins.removeItem(at: Self.key(url))
        if pins != before {
            write(pins, as: "pins.json")
            workspaces.forEach { $0.updatePinnedItems() }
        }
    }

    // MARK: Opening files from Finder

    /// A file inside a root opens in the main window as that root's item. Any other file opens in a window of its
    /// own rooted at its folder (sidebar closed, no automatic names); further files from that folder join it as tabs.
    func open(_ urls: [URL]) {
        for url in urls.map({ $0.standardizedFileURL }) {
            if main.contains(url) {
                main.query = ""
                main.open(url, newTab: true, focus: true)
                windowRequests.append(.main)
                continue
            }
            let workspace = external.first { $0.contains(url) } ?? newExternalWorkspace(for: url)
            workspace.open(url, newTab: true, focus: true)
            windowRequests.append(.workspace(workspace.id))
        }
    }

    private func newExternalWorkspace(for url: URL) -> Workspace {
        let workspace = Workspace(isMain: false, sidebarVisible: false)
        workspace.model = self
        if let problem = workspace.addRoot(url.deletingLastPathComponent()) { workspace.report(problem) }
        external.append(workspace)
        return workspace
    }

    /// An outside file's window closed: its drafts with text move to the main window, the rest goes away.
    func workspaceClosed(_ workspace: Workspace) {
        guard !workspace.isMain, external.contains(where: { $0 === workspace }) else { return }
        workspace.moveUnsavedDocuments(to: main)
        external.removeAll { $0 === workspace }
        sessionChanged()
    }

    // MARK: Drafts

    /// Takes the draft store; when another process owns it (or the lock can't be taken), uses a pending store of its
    /// own (docs/format.md, "Drafts"). A test run without `-supportFolder` keeps throwaway drafts in a temporary folder.
    private func setUpDrafts() {
        guard let support = LaunchOptions.supportFolder else {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotesTestDrafts-\(UUID().uuidString)")
            temporaryDrafts = folder
            draftStore = DraftStore(folder: folder)
            ownsDraftStore = true
            return
        }
        let store = DraftStore(folder: support.appendingPathComponent("Drafts", isDirectory: true))
        let pendingRoot = support.appendingPathComponent("PendingDrafts", isDirectory: true)
        let reason: String
        do {
            if try store.lock() {
                store.adoptPending(in: pendingRoot)
                draftStore = store
                ownsDraftStore = true
                return
            }
            reason = L("Another Notes process is using the drafts folder. New tabs are kept in a separate folder and move there once it quits.")
        } catch {
            reason = L("The drafts folder can't be used (\(error.localizedDescription)). New tabs are kept in a separate folder and move there when it works again.")
        }
        // A fresh name for every try: a pending folder that can't be locked or created is simply skipped.
        for _ in 0..<3 {
            let pending = DraftStore(folder: pendingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true))
            if (try? pending.lock()) == true {
                draftStore = pending
                draftsArePending = true
                main.report(reason)
                return
            }
        }
        main.report(L("Drafts can't be stored right now, so new tabs can't be opened. Check that the Notes folder in Application Support is writable."))
    }

    /// Where a new draft's file goes.
    func newDraftURL() -> URL? {
        guard let draftStore else {
            main.report(L("A new tab couldn't be opened because drafts can't be stored right now."))
            return nil
        }
        do {
            return try draftStore.newDraftURL()
        } catch {
            main.report(L("A new tab couldn't be opened: \(error.localizedDescription)"))
            return nil
        }
    }

    /// Writes the tab order of the drafts when it changed.
    private func writeDraftOrder() {
        guard let draftStore else { return }
        let order = workspaces.flatMap(\.documents).filter(\.isDraft).map(\.url.lastPathComponent)
            .filter(DraftStore.isDraftName)
        guard order != lastDraftOrder else { return }
        if (try? draftStore.writeOrder(order)) != nil { lastDraftOrder = order }
    }

    /// On quit: a test run's drafts are deleted; a pending store moves into the real one if that is free now, and
    /// otherwise stays for the next owner to adopt.
    private func finishDrafts() {
        if let temporaryDrafts {
            try? FileManager.default.removeItem(at: temporaryDrafts)
            return
        }
        guard draftsArePending, let pending = draftStore, let support = LaunchOptions.supportFolder else { return }
        let store = DraftStore(folder: support.appendingPathComponent("Drafts", isDirectory: true))
        guard (try? store.lock()) == true else { return }
        if store.takeDrafts(from: pending.folder) {
            try? FileManager.default.removeItem(at: pending.folder)
        }
        store.unlock()
    }

    // MARK: Session

    private var sessionURL: URL? { LaunchOptions.supportFolder?.appendingPathComponent("session.json") }

    /// Something worth restoring changed; saves a moment later.
    func sessionChanged() {
        guard !isRestoring, !hasQuit else { return }
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveSession()
        }
    }

    func saveSessionSoon() { sessionChanged() }

    /// Writes the draft order and, with "Restore tabs" on, `session.json` (atomically). Cursor and scroll positions
    /// are read from the editors now.
    func saveSession() {
        guard !hasQuit else { return }
        sessionTask?.cancel()
        writeDraftOrder()
        // A second process (pending drafts) must not overwrite the session of the one that owns the app state.
        guard ownsDraftStore, AppSettings.shared.restoreTabs, let sessionURL else { return }
        for workspace in workspaces {
            if let tab = workspace.activeTab { workspace.captureViewState(of: tab) }
        }
        try? Session(windows: workspaces.compactMap(state)).write(to: sessionURL)
    }

    private func state(of workspace: Workspace) -> Session.Window? {
        let root = workspace.roots.first?.url.path
        guard workspace.isMain || root != nil else { return nil }
        let tabs = workspace.tabs.map { tab in
            let document = tab.document
            return Session.Tab(file: document.isDraft ? nil : document.url.path,
                               draft: document.isDraft ? document.url.lastPathComponent : nil,
                               showsSource: tab.showsSource, view: tab.viewState)
        }
        return Session.Window(
            isMain: workspace.isMain, root: workspace.isMain ? nil : root, tabs: tabs,
            activeTab: workspace.activeTab.flatMap { active in workspace.tabs.firstIndex { $0 === active } },
            sidebarVisible: workspace.isSidebarVisible,
            frame: workspace.isMain ? nil : workspace.window.map { NSStringFromRect($0.frame) },
            collapsedRoots: workspace.collapsedRoots.sorted(),
            expandedFolders: workspace.expandedFolders.sorted()
        )
    }

    /// Lets a relaunched instance own the drafts folder right away (the lock would otherwise last until this process exits).
    func releaseDraftsForRelaunch() {
        draftStore?.unlock()
    }

    /// Saves for the last time before the app quits; later changes (windows closing) are not recorded.
    func prepareForQuit() {
        guard !hasQuit else { return }
        saveSession()
        hasQuit = true
        finishDrafts()
    }

    /// Reopens the last session's tabs and outside-file windows (with "Restore tabs" on), skipping files and folders
    /// that are gone, then every other draft as a tab of the main window in its saved order.
    private func restore() {
        isRestoring = true
        defer { isRestoring = false }
        let drafts = ownsDraftStore ? draftStore?.saved() ?? [] : []
        let draftURLs = Dictionary(drafts.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        var restoredDrafts = Set<String>()

        if ownsDraftStore, AppSettings.shared.restoreTabs, let sessionURL, let session = Session.read(sessionURL) {
            for window in session.windows {
                let workspace: Workspace
                if window.isMain {
                    workspace = main
                    main.isSidebarVisible = window.sidebarVisible
                } else {
                    guard let root = window.root, FilePaths.isFolder(URL(fileURLWithPath: root)) else { continue }
                    workspace = Workspace(isMain: false, sidebarVisible: window.sidebarVisible)
                    workspace.model = self
                    guard workspace.addRoot(URL(fileURLWithPath: root, isDirectory: true)) == nil else { continue }
                    workspace.pendingFrame = window.frame.map(NSRectFromString)
                }
                workspace.collapsedRoots = Set(window.collapsedRoots ?? [])
                workspace.expandedFolders = Set(window.expandedFolders ?? [])
                var active: Int?
                for (index, saved) in window.tabs.enumerated() {
                    var document: NoteDocument?
                    if let name = saved.draft {
                        guard let url = draftURLs[name], restoredDrafts.insert(name).inserted else { continue }
                        document = try? NoteDocument.openDraft(url)
                    } else if let path = saved.file {
                        let url = URL(fileURLWithPath: path)
                        guard FileManager.default.fileExists(atPath: path), !FilePaths.isFolder(url) else { continue }
                        document = try? NoteDocument.open(url)
                    }
                    guard let document else { continue }
                    configure(document)
                    let tab = EditorTab(document: document)
                    tab.showsSource = saved.showsSource && document.language == .markdown
                    tab.viewState = saved.view
                    workspace.append(tab)
                    // `append` skips a document that is open already; the active tab is the one that shows it.
                    if index == window.activeTab {
                        active = workspace.tabs.firstIndex { $0.document === document }
                    }
                }
                if let active { workspace.setActiveTab(index: active) }
                guard !window.isMain else { continue }
                guard !workspace.tabs.isEmpty || workspace.isSidebarVisible else { continue }
                external.append(workspace)
                windowRequests.append(.workspace(workspace.id))
            }
        }
        for url in drafts where !restoredDrafts.contains(url.lastPathComponent) {
            guard let document = try? NoteDocument.openDraft(url) else { continue }
            configure(document)
            main.append(EditorTab(document: document))
        }
        main.syncSelection()
    }
}
