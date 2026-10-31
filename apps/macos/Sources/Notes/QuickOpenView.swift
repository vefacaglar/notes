import NotesCore
import SwiftUI

/// ⌘P: a search field and a fuzzy-filtered list of every file in the window's roots. ↑ ↓ choose, Return opens in the
/// current tab, ⌘Return in a new tab, Esc closes.
struct QuickOpenView: View {
    @Bindable var workspace: Workspace
    let model: NotesModel

    private struct Entry: Identifiable {
        let id: String
        let url: URL
        let name: String
        let location: String
    }

    @State private var query = ""
    @State private var entries: [Entry] = []
    @State private var candidates: [FuzzyMatch.Candidate] = []
    @State private var selected = 0
    @State private var isLoading = true
    @FocusState private var isFocused: Bool

    private static let limit = 50

    private var results: [Entry] {
        FuzzyMatch.rank(query, in: candidates, limit: Self.limit).map { entries[$0] }
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            TextField(text: $query) { Text(loc: "Open Note…") }
                .textFieldStyle(.plain)
                .appFont(.title3)
                .padding(12)
                .focused($isFocused)
                .onSubmit { open(results, newTab: false) }
                .onKeyPress(.upArrow) { move(-1, in: results.count) }
                .onKeyPress(.downArrow) { move(1, in: results.count) }
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    open(results, newTab: true)
                    return .handled
                }
            Divider()
            if results.isEmpty {
                Text(loc: isLoading ? "Loading…" : "No Matching Notes")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                                row(entry, isSelected: index == selected)
                                    .id(index)
                                    .onTapGesture {
                                        selected = index
                                        open(results, newTab: NSEvent.modifierFlags.contains(.command))
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selected) { proxy.scrollTo(selected) }
                }
            }
        }
        .frame(width: 520, height: 360)
        .appFont()
        .onExitCommand { workspace.isQuickOpenVisible = false }
        .onChange(of: query) { selected = 0 }
        .task {
            isFocused = true
            await load()
        }
    }

    private func row(_ entry: Entry, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: SidebarView.icon(for: entry.url.lastPathComponent))
                .foregroundStyle(.secondary)
            Text(verbatim: entry.name)
                .lineLimit(1)
            Text(verbatim: entry.location)
                .appFont(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int, in count: Int) -> KeyPress.Result {
        guard count > 0 else { return .handled }
        selected = min(max(selected + delta, 0), count - 1)
        return .handled
    }

    private func open(_ results: [Entry], newTab: Bool) {
        guard results.indices.contains(selected) else { return }
        let url = results[selected].url
        workspace.isQuickOpenVisible = false
        workspace.open(url, newTab: newTab, focus: true)
    }

    /// Lists the files of every root: from the sidebar's trees when they are loaded, else scanned in the background.
    /// With an empty query the recently opened files come first.
    private func load() async {
        var found: [(url: URL, name: String, location: String)] = []
        let showsRoot = workspace.roots.count > 1
        for root in workspace.roots {
            var paths = Self.paths(in: root.items)
            if paths.isEmpty {
                let store = root.store, options = workspace.listingOptions(for: root)
                paths = await Task.detached(priority: .userInitiated) { store.notePaths(options) }.value
            }
            for path in paths {
                let url = root.url.appendingPathComponent(path)
                let folder = NoteStore.parent(path)
                let location = [showsRoot ? root.name : nil, folder.isEmpty ? nil : folder].compactMap { $0 }.joined(separator: "/")
                found.append((url, NoteStore.displayName(path), location))
            }
        }
        let recentPaths = model.recents.paths
        let recentRank = Dictionary(recentPaths.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        found = found.enumerated().sorted { a, b in
            let ra = recentRank[a.element.url.standardizedFileURL.path] ?? Int.max
            let rb = recentRank[b.element.url.standardizedFileURL.path] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        entries = found.map { Entry(id: $0.url.path, url: $0.url, name: $0.name, location: $0.location) }
        candidates = found.map { FuzzyMatch.Candidate(name: $0.name, path: ($0.location.isEmpty ? "" : $0.location + "/") + $0.name) }
        isLoading = false
    }

    private static func paths(in items: [SidebarItem]) -> [String] {
        items.flatMap { $0.isFolder ? paths(in: $0.children ?? []) : [$0.id.path] }
    }
}
