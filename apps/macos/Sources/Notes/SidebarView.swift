import NotesCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: NotesModel
    @State private var hitSelection: SearchHit.ID?

    var body: some View {
        Group {
            if model.isSearching {
                List(model.hits, selection: $hitSelection) { HitRow(hit: $0) }
                    .overlay {
                        if model.hits.isEmpty { ContentUnavailableView.search(text: model.query) }
                    }
            } else {
                List(model.tree, children: \.children, selection: $model.selection) { node in
                    Label(node.name, systemImage: node.isFolder ? "folder" : Self.icon(for: node.path))
                        .contextMenu { menu(for: node) }
                }
            }
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: "Ara")
        .onChange(of: hitSelection) {
            if let hit = model.hits.first(where: { $0.id == hitSelection }) { model.selection = hit.path }
        }
        .onChange(of: model.isSearching) { hitSelection = nil }
        .alert(model.prompt?.title ?? "", isPresented: $model.prompt.isPresent, presenting: model.prompt) { prompt in
            TextField("Ad", text: $model.promptName)
            Button(prompt.action) { model.commitPrompt(prompt) }
            Button("Vazgeç", role: .cancel) {}
        }
        .confirmationDialog(
            "“\(Self.displayName(model.trashCandidate ?? ""))” Çöp Kutusuna taşınsın mı?",
            isPresented: $model.trashCandidate.isPresent, titleVisibility: .visible,
            presenting: model.trashCandidate
        ) { path in
            Button("Çöp Kutusuna Taşı", role: .destructive) { model.trash(path) }
            Button("Vazgeç", role: .cancel) {}
        }
    }

    @ViewBuilder private func menu(for node: NoteNode) -> some View {
        Button("Yeniden Adlandır") { model.rename(node.path) }
        Button("Finder'da Göster") { model.revealInFinder(node.path) }
        Divider()
        Button("Çöp Kutusuna Taşı") { model.trashCandidate = node.path }
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

    static func displayName(_ path: String) -> String { NoteStore.displayName(path) }
}

private struct HitRow: View {
    let hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(SidebarView.displayName(hit.path), systemImage: SidebarView.icon(for: hit.path))
            if let line = hit.line, let snippet = hit.snippet {
                Text("\(line): \(snippet)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if !NoteStore.parent(hit.path).isEmpty {
                Text(NoteStore.parent(hit.path))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
