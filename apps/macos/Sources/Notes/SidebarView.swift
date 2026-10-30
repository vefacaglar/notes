import NotesCore
import SwiftUI

/// The workspace's roots, each a top-level folder row, with their trees; or the search results.
struct SidebarView: View {
    @Bindable var workspace: Workspace
    let model: NotesModel
    @State private var hitSelection: WorkspaceHit.ID?
    @State private var collapsedRoots: Set<UUID> = []

    var body: some View {
        Group {
            if workspace.isSearching {
                List(workspace.hits, selection: $hitSelection) { hit in
                    HitRow(hit: hit, rootName: workspace.roots.count > 1 ? workspace.root(hit.root)?.name : nil)
                }
                .overlay {
                    if workspace.hits.isEmpty { ContentUnavailableView.search(text: workspace.query) }
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

    private func expanded(_ root: RootFolder) -> Binding<Bool> {
        Binding(get: { !collapsedRoots.contains(root.id) },
                set: { if $0 { collapsedRoots.remove(root.id) } else { collapsedRoots.insert(root.id) } })
    }

    @ViewBuilder private func menu(for item: SidebarItem) -> some View {
        if !item.isFolder, let url = workspace.url(for: item.id) {
            Button(loc: "Open in New Tab") { workspace.open(url, newTab: true) }
            Divider()
        }
        if item.isFolder {
            Button(loc: "Create Folder…") {
                workspace.selection = item.id
                workspace.newFolder()
            }
        }
        Button(loc: "Rename Item…") { workspace.rename(item.id) }
        Button(loc: "Show in Finder") { workspace.revealInFinder(item.id) }
        Divider()
        Button(loc: "Move to Trash") { workspace.trashCandidate = item.id }
    }

    @ViewBuilder private func rootMenu(for root: RootFolder) -> some View {
        Button(loc: "Create Folder…") {
            workspace.selection = ItemID(root: root.id, path: "")
            workspace.newFolder()
        }
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

private struct HitRow: View {
    let hit: WorkspaceHit
    let rootName: String?

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

    private func location(of path: String) -> String? {
        let parent = NoteStore.parent(path)
        let parts = [rootName, parent.isEmpty ? nil : parent].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }
}
