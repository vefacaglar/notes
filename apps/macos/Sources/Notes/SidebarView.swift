import AppKit
import NotesCore
import SwiftUI

/// The workspace's roots, each a top-level folder row, with their trees; or the search results.
struct SidebarView: View {
    @Bindable var workspace: Workspace
    let model: NotesModel
    @State private var hitSelection: WorkspaceHit.ID?
    @State private var collapsedRoots: Set<UUID> = []
    /// The search field: ⇧⌘F focuses it, Esc clears it (and Return must not rename while it has the keys).
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if workspace.isSearching {
                List(searchRows, selection: $hitSelection) { row in
                    switch row {
                    case .header(_, let name):
                        Label(name, systemImage: "folder")
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
                List(selection: $workspace.selection) {
                    ForEach(workspace.roots) { root in
                        DisclosureGroup(isExpanded: expanded(root)) {
                            OutlineGroup(root.items, children: \.children) { item in
                                Label(item.name, systemImage: item.isFolder ? "folder" : Self.icon(for: item.id.path))
                                    .contextMenu { menu(for: item) }
                            }
                        } label: {
                            Label(root.name, systemImage: "folder")
                                .fontWeight(.semibold)
                                .help(root.url.path)
                                .contextMenu { rootMenu(for: root) }
                        }
                        .tag(ItemID(root: root.id, path: ""))
                    }
                    ForEach(workspace.unavailableRoots) { root in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(root.name, systemImage: "folder.badge.questionmark")
                            Text(verbatim: root.reason)
                                .font(.callout)
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
        Binding(get: { !collapsedRoots.contains(root.id) },
                set: { if $0 { collapsedRoots.remove(root.id) } else { collapsedRoots.insert(root.id) } })
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

private struct HitRow: View {
    let hit: WorkspaceHit

    var body: some View {
        let path = hit.hit.path
        VStack(alignment: .leading, spacing: 2) {
            Label(NoteStore.displayName(path), systemImage: SidebarView.icon(for: path))
            if let line = hit.hit.line, let snippet = hit.hit.snippet {
                Text(verbatim: "\(line): \(snippet)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let folder = location(of: path) {
                Text(verbatim: folder)
                    .font(.callout)
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
