import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A tab dragged inside the tab bar (declared in Info.plist by bundle.sh); text editors don't accept it.
    static let notesTab = UTType(exportedAs: "com.vefa.notes.tab")
}

/// The tabs above the editor: file icon and name, a dot for unsaved edits (or a draft with text), a lock for
/// read-only files, a close button on hover, and a "+" after the last tab for a new one. Scrolls sideways when the
/// tabs don't fit; drag a tab to reorder. Shown even with no tabs, so "+" stays reachable.
struct TabBar: View {
    let workspace: Workspace
    @Environment(AppSettings.self) private var environmentSettings: AppSettings?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The hairline under the bar stops at the active tab: its own background covers it and joins the editor.
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(workspace.tabs) { tab in
                            TabItem(tab: tab, workspace: workspace, editorBackground: editorBackground)
                                .id(tab.id)
                        }
                        NewTabButton(workspace: workspace)
                    }
                }
                .onChange(of: workspace.activeTabID, initial: true) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            }
        }
        .frame(height: 30)
        .background(.bar)
    }

    /// The editor's own background, so the active tab and the editor read as one surface.
    private var editorBackground: Color {
        let settings = environmentSettings ?? .shared
        return Color(nsColor: settings.resolvedTheme(for: colorScheme).colors.background.nsColor)
    }
}

/// "+" at the end of the tabs: a new draft tab, like ⌘T.
private struct NewTabButton: View {
    let workspace: Workspace
    @State private var isHovering = false

    var body: some View {
        Button {
            workspace.newDraftTab()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .background(isHovering ? Color.primary.opacity(0.06) : .clear)
        .onHover { isHovering = $0 }
        .help(loc: "New Tab")
    }
}

private struct TabItem: View {
    let tab: EditorTab
    let workspace: Workspace
    /// The editor's background colour: the active tab uses it so it blends into the editor below.
    let editorBackground: Color
    @State private var isHovering = false

    private var isActive: Bool { workspace.activeTabID == tab.id }

    var body: some View {
        let document = tab.document
        HStack(spacing: 6) {
            Image(systemName: document.isDraft ? "doc" : SidebarView.icon(for: document.url.lastPathComponent))
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(document.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if document.isReadOnly {
                Image(systemName: "lock")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help(document.readOnlyReason ?? "")
            }
            Spacer(minLength: 0)
            ZStack {
                if isHovering {
                    Button {
                        workspace.close(tab)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(loc: "Close Tab")
                } else if document.showsUnsavedDot {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: 16, height: 16)
        }
        .appFont(.callout)
        .foregroundStyle(isActive ? .primary : .secondary)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minWidth: 100, maxWidth: 220, maxHeight: .infinity)
        .background(isActive ? editorBackground : .clear)
        .contentShape(Rectangle())
        .onTapGesture { workspace.activate(tab, focus: true) }
        .onHover { isHovering = $0 }
        .help(document.isDraft ? document.name : document.url.path)
        .contextMenu {
            Button(loc: "Close Tab") { workspace.close(tab) }
            Button(loc: "Close Other Tabs") { workspace.closeOtherTabs(than: tab) }
                .disabled(workspace.tabs.count < 2)
            if !document.isDraft {
                Divider()
                Button(loc: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
            }
        }
        .onDrag {
            let provider = NSItemProvider()
            let id = tab.id.uuidString
            provider.registerDataRepresentation(forTypeIdentifier: UTType.notesTab.identifier, visibility: .ownProcess) { completion in
                completion(Data(id.utf8), nil)
                return nil
            }
            return provider
        }
        .onDrop(of: [.notesTab], delegate: TabDropDelegate(target: tab, workspace: workspace))
    }
}

private struct TabDropDelegate: DropDelegate {
    let target: EditorTab
    let workspace: Workspace

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.notesTab]).first else { return false }
        let target = target
        let workspace = workspace
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.notesTab.identifier) { data, _ in
            guard let data, let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) else { return }
            Task { @MainActor in
                guard let tab = workspace.tabs.first(where: { $0.id == id }) else { return }
                workspace.move(tab, to: target)
            }
        }
        return true
    }
}
