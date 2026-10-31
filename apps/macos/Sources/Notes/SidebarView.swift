import AppKit
import NotesCore
import SwiftUI

/// The workspace's roots, each a top-level folder row, with their trees; or the search results.
/// A sidebar row's selection tag. A pinned file is drawn twice, so each place needs its own.
private enum SidebarSelection: Hashable {
    case item(ItemID)
    case pinned(ItemID)
}

struct SidebarView: View {
    @Bindable var workspace: Workspace
    let model: NotesModel
    @State private var hitSelection: WorkspaceHit.ID?
    /// The pinned row the selection came from, if it was chosen there.
    @State private var pinnedSelection: ItemID?
    /// The search field: ⇧⌘F focuses it, Esc clears it (and Return must not rename while it has the keys).
    @FocusState private var searchFocused: Bool
    /// The folder row a drag is over, highlighted.
    @State private var dropTarget: ItemID?

    var body: some View {
        Group {
            if workspace.isSearching {
                List(searchRows, selection: $hitSelection) { row in
                    switch row {
                    case .header(_, let name):
                        Label(name, systemImage: "folder")
                            .appFont()
                            .fontWeight(.semibold)
                            .selectionDisabled()
                    case .hit(let hit):
                        HitRow(hit: hit)
                    }
                }
                .overlay {
                    if searchRows.isEmpty { noResults }
                }
            } else {
                List(selection: listSelection) {
                    let pinned = workspace.pinnedItems
                    if !pinned.isEmpty {
                        Section {
                            ForEach(pinned) { item in row(item, pinned: true) }
                        } header: {
                            Text(loc: "Pinned")
                                .appFont(.caption, weight: .semibold)
                        }
                    }
                    ForEach(workspace.roots) { root in
                        DisclosureGroup(isExpanded: expanded(root)) {
                            tree(root.items)
                        } label: {
                            Label {
                                Text(verbatim: root.name).appFont(weight: .semibold)
                            } icon: {
                                Image(systemName: "folder")
                            }
                                .help(root.url.path)
                                .dropTarget(ItemID(root: root.id, path: ""), in: $dropTarget) { workspace.drop($0, onto: $1) }
                                .contextMenu { rootMenu(for: root) }
                        }
                        .tag(SidebarSelection.item(ItemID(root: root.id, path: "")))
                    }
                    ForEach(workspace.unavailableRoots) { root in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(root.name, systemImage: "folder.badge.questionmark")
                                .appFont()
                            Text(verbatim: root.reason)
                                .appFont(.callout)
                                .lineLimit(3)
                        }
                        .foregroundStyle(.secondary)
                        .help(root.url.path)
                        .contextMenu {
                            if workspace.isMain {
                                Button(loc: "Remove Folder from Workspace") { model.removeRoot(path: root.url.path) }
                            }
                        }
                    }
                }
                .overlay {
                    if workspace.roots.isEmpty && workspace.unavailableRoots.isEmpty && workspace.isMain {
                        ContentUnavailableView {
                            Label(loc: "No Folders", systemImage: "folder")
                        } description: {
                            Text(loc: "Add a folder to the workspace to see its notes here.")
                        } actions: {
                            Button(loc: "Add Folder…", action: model.chooseRoot)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if workspace.activeOperations > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loc: "Copying…")
                    Spacer(minLength: 0)
                }
                .appFont(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .searchable(text: $workspace.query, placement: .sidebar, prompt: Text(loc: "Search"))
        .searchFocus($searchFocused)
        .onKeyPress(phases: .down, action: handleKey)
        .onDeleteCommand { if !isEditingSearchField { confirmTrash() } }
        .onChange(of: workspace.searchFocusRequested, initial: true) {
            guard workspace.searchFocusRequested else { return }
            workspace.searchFocusRequested = false
            focusSearch()
        }
        .onChange(of: hitSelection) {
            if let hit = workspace.hits.first(where: { $0.id == hitSelection }) { workspace.selection = hit.item }
        }
        .onChange(of: workspace.isSearching) { hitSelection = nil }
        .alert(workspace.prompt?.title ?? "", isPresented: $workspace.prompt.isPresent, presenting: workspace.prompt) { prompt in
            TextField(loc: "Name", text: $workspace.promptName)
            Button(prompt.action) { workspace.commitPrompt(prompt) }
            Button(loc: "Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            trashTitle, isPresented: $workspace.trashCandidate.isPresent, titleVisibility: .visible,
            presenting: workspace.trashCandidate
        ) { item in
            Button(loc: "Move to Trash", role: .destructive) { workspace.trash(item) }
            Button(loc: "Cancel", role: .cancel) {}
        }
    }

    /// A file or folder row: draggable, and a folder accepts drops.
    @ViewBuilder private func row(_ item: SidebarItem, pinned: Bool) -> some View {
        let url = workspace.url(for: item.id) ?? URL(fileURLWithPath: "/")
        let content = ItemRow(item: item, url: url, previews: model.previews)
            .contextMenu { menu(for: item) }
            .tag(pinned ? SidebarSelection.pinned(item.id) : SidebarSelection.item(item.id))
        if item.isFolder {
            content
                .dropTarget(item.id, in: $dropTarget) { workspace.drop($0, onto: $1) }
                .draggable(url)
        } else {
            content.draggable(url)
        }
    }

    /// The list's selection: a pinned row has its own tag (the same item also appears in the tree), and both map to
    /// the workspace's selection.
    private var listSelection: Binding<SidebarSelection?> {
        Binding {
            guard let item = workspace.selection else { return nil }
            return pinnedSelection == item ? .pinned(item) : .item(item)
        } set: { selection in
            switch selection {
            case .pinned(let item)?: pinnedSelection = item; workspace.selection = item
            case .item(let item)?: pinnedSelection = nil; workspace.selection = item
            case nil: pinnedSelection = nil; workspace.selection = nil
            }
        }
    }

    private var trashTitle: String {
        L("Move “\(NoteStore.displayName(workspace.trashCandidate?.path ?? ""))” to the Trash?")
    }

    /// The search list: a header with the root's name when there are several roots, so a hit's folder path needn't
    /// repeat it. Roots without hits (or that went away) add nothing.
    private var searchRows: [SearchRow] {
        let groups = workspace.roots.count > 1
        return workspace.roots.flatMap { root -> [SearchRow] in
            let hits = workspace.hits.filter { $0.root == root.id }
            guard !hits.isEmpty else { return [] }
            return (groups ? [.header(id: root.id, name: root.name)] : []) + hits.map(SearchRow.hit)
        }
    }

    private var noResults: some View {
        Text(loc: "No results for “\(workspace.query.trimmingCharacters(in: .whitespacesAndNewlines))”")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Keys

    /// Esc clears the search field, Return renames the selected item, ⌘⌫ moves it to the Trash.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape:
            guard isEditingSearchField, !workspace.query.isEmpty else { return .ignored }
            workspace.query = ""
            return .handled
        case .return:
            guard !isEditingSearchField, let item = workspace.selection, !item.isRoot else { return .ignored }
            workspace.rename(item)
            return .handled
        case .delete:
            guard press.modifiers.contains(.command), !isEditingSearchField else { return .ignored }
            return confirmTrash() ? .handled : .ignored
        default:
            return .ignored
        }
    }

    /// Whether the search field has the keys. `searchFocused` says so on macOS 15; before that the field is the first
    /// responder of the window, with its field editor (`NSTextView`) in between.
    private var isEditingSearchField: Bool {
        if #available(macOS 15.0, *) { return searchFocused }
        guard let window = workspace.window, let textView = window.firstResponder as? NSTextView else { return false }
        return textView.delegate is NSSearchField
    }

    /// Asks before moving the selected item to the Trash, like its context menu does. `false` when there is nothing to
    /// trash: a root, or no selection.
    @discardableResult private func confirmTrash() -> Bool {
        guard let item = workspace.selection, !item.isRoot else { return false }
        workspace.trashCandidate = item
        return true
    }

    /// Puts the cursor in the search field (⇧⌘F, see `Workspace.requestSearchFocus`).
    private func focusSearch() {
        // A field that appears just now (the sidebar was collapsed) takes focus a moment later.
        Task { @MainActor in
            for _ in 0..<20 {
                if focusSearchField() { return }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    /// Puts the cursor in the search field; `false` while the field doesn't exist yet, so the caller tries again.
    private func focusSearchField() -> Bool {
        if #available(macOS 15.0, *) {
            let focused = searchFocused
            searchFocused = true
            return focused
        }
        guard let window = workspace.window, let field = window.sidebarSearchField else { return false }
        return window.makeFirstResponder(field)
    }

    private func expanded(_ root: RootFolder) -> Binding<Bool> {
        let path = root.url.path
        return Binding(get: { !workspace.collapsedRoots.contains(path) },
                       set: { if $0 { workspace.collapsedRoots.remove(path) } else { workspace.collapsedRoots.insert(path) } })
    }

    /// A root's items with a disclosure group per folder, whose state the workspace keeps (and the session saves),
    /// unlike `OutlineGroup`'s.
    private func tree(_ items: [SidebarItem]) -> AnyView {
        AnyView(ForEach(items) { item in
            if let children = item.children {
                DisclosureGroup(isExpanded: expanded(item)) {
                    tree(children)
                } label: {
                    row(item, pinned: false)
                }
                .tag(SidebarSelection.item(item.id))
            } else {
                row(item, pinned: false)
            }
        })
    }

    private func expanded(_ folder: SidebarItem) -> Binding<Bool> {
        let path = workspace.url(for: folder.id)?.path ?? ""
        return Binding(get: { workspace.expandedFolders.contains(path) },
                       set: { if $0 { workspace.expandedFolders.insert(path) } else { workspace.expandedFolders.remove(path) } })
    }

    @ViewBuilder private func menu(for item: SidebarItem) -> some View {
        if item.isFolder {
            if workspace.isMain {
                Button(loc: "New Note") {
                    workspace.selection = item.id
                    workspace.newNote()
                }
            }
            Button(loc: "Create Folder…") {
                workspace.selection = item.id
                workspace.newFolder()
            }
        } else if let url = workspace.url(for: item.id) {
            Button(loc: "Open in New Tab") { workspace.open(url, newTab: true) }
            Button(loc: model.isPinned(url) ? "Unpin" : "Pin") { model.togglePin(url) }
            Button(loc: "Duplicate") { workspace.duplicate(item.id) }
        }
        Divider()
        Button(loc: "Rename Item…") { workspace.rename(item.id) }
        Button(loc: "Show in Finder") { workspace.revealInFinder(item.id) }
        Divider()
        Button(loc: "Move to Trash") { workspace.trashCandidate = item.id }
    }

    @ViewBuilder private func rootMenu(for root: RootFolder) -> some View {
        if workspace.isMain {
            Button(loc: "New Note") {
                workspace.selection = ItemID(root: root.id, path: "")
                workspace.newNote()
            }
        }
        Button(loc: "Create Folder…") {
            workspace.selection = ItemID(root: root.id, path: "")
            workspace.newFolder()
        }
        Divider()
        Button(loc: "Show in Finder") { workspace.revealInFinder(ItemID(root: root.id, path: "")) }
        if workspace.isMain {
            Divider()
            Button(loc: "Remove Folder from Workspace") { model.removeRoot(root) }
        }
    }

    /// One symbol per kind of file: notes, structured data, markup, code, tables, plain text.
    static func icon(for path: String) -> String {
        if NoteStore.isNote(path) { return "doc.text" }
        switch CodeLanguage(path: path) {
        case .json: return "curlybraces"
        case .yaml, .toml: return "list.bullet.indent"
        case .xml: return "chevron.left.slash.chevron.right"
        case .shell: return "terminal"
        case .markdown: return "doc.richtext"
        case .plainText: return (path as NSString).pathExtension.lowercased() == "csv" ? "tablecells" : "doc.plaintext"
        case .swift, .javascript, .python, .css, .cFamily, .sql: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// A row of the search list: a root's header, or a hit.
private enum SearchRow: Identifiable {
    case header(id: UUID, name: String)
    case hit(WorkspaceHit)

    var id: String {
        switch self {
        case .header(let id, _): return "root:\(id.uuidString)"
        case .hit(let hit): return hit.id
        }
    }
}

/// A row of the tree: icon and name, and for files (with "Show preview in sidebar") the modified date and the first line
/// after the title.
private struct ItemRow: View {
    let item: SidebarItem
    let url: URL
    let previews: PreviewCache
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if settings.showSidebarPreview, !item.isFolder {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.name)
                        .appFont()
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let modified = item.modified {
                            Text(verbatim: Self.dateText(modified))
                                .layoutPriority(1)
                        }
                        if let preview = previews.preview(for: url) {
                            Text(verbatim: preview)
                        }
                    }
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            } icon: {
                Image(systemName: SidebarView.icon(for: item.id.path))
            }
            .task(id: item.modified) { await previews.load(url, modified: item.modified) }
        } else {
            Label(item.name, systemImage: item.isFolder ? "folder" : SidebarView.icon(for: item.id.path))
                .appFont()
        }
    }

    /// The time today, else the date, in the app's language.
    static func dateText(_ date: Date) -> String {
        let locale = Locale(identifier: Localization.code)
        if Calendar.current.isDateInToday(date) {
            return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
        }
        return date.formatted(Date.FormatStyle(date: .numeric, time: .omitted, locale: locale))
    }
}

private extension View {
    /// Accepts dropped files and folders on `item`, highlighting it while a drag is over.
    func dropTarget(_ item: ItemID, in target: Binding<ItemID?>,
                    perform: @escaping @MainActor ([URL], ItemID) -> Bool) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            target.wrappedValue = nil
            return perform(urls, item)
        } isTargeted: { isTargeted in
            if isTargeted { target.wrappedValue = item } else if target.wrappedValue == item { target.wrappedValue = nil }
        }
        .background(target.wrappedValue == item ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
}

private struct HitRow: View {
    let hit: WorkspaceHit

    var body: some View {
        let path = hit.hit.path
        VStack(alignment: .leading, spacing: 2) {
            Label(NoteStore.displayName(path), systemImage: SidebarView.icon(for: path))
                .appFont()
            if let line = hit.hit.line, let snippet = hit.hit.snippet {
                Text(verbatim: "\(line): \(snippet)")
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let folder = location(of: path) {
                Text(verbatim: folder)
                    .appFont(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// The hit's folder inside its root; a hit row's group header already names the root.
    private func location(of path: String) -> String? {
        let parent = NoteStore.parent(path)
        return parent.isEmpty ? nil : parent
    }
}

private extension View {
    /// SwiftUI's own `.searchFocused` (macOS 15); macOS 14 focuses the field through AppKit instead.
    @ViewBuilder func searchFocus(_ focused: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15.0, *) {
            searchFocused(focused)
        } else {
            self
        }
    }
}

private extension NSWindow {
    /// The sidebar's search field, wherever AppKit put it: in the sidebar itself or in a toolbar item.
    var sidebarSearchField: NSSearchField? {
        if let item = toolbar?.items.compactMap({ $0 as? NSSearchToolbarItem }).first { return item.searchField }
        return contentView?.firstSearchField
    }
}

private extension NSView {
    var firstSearchField: NSSearchField? {
        if let field = self as? NSSearchField { return field }
        for subview in subviews {
            if let field = subview.firstSearchField { return field }
        }
        return nil
    }
}
