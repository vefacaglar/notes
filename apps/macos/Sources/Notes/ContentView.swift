import AppKit
import SwiftUI

/// A window: the sidebar with the workspace's roots, the tab bar and the active tab's editor.
struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    let model: NotesModel
    @Environment(AppSettings.self) private var settings

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            SidebarView(workspace: workspace, model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            VStack(spacing: 0) {
                TabBar(workspace: workspace)
                detail
            }
            // On the column, not the editor, so it stays up whatever happens to the editor.
            .errorAlert(documentError)
        }
        .appFont()
        .navigationTitle(title)
        .toolbar {
            if workspace.isMain {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: workspace.newNote) { Label(loc: "New Note", systemImage: "square.and.pencil") }
                    Button(action: workspace.newFolder) { Label(loc: "New Folder", systemImage: "folder.badge.plus") }
                    Button(action: model.chooseRoot) {
                        Label(loc: "Add Folder to Workspace…", systemImage: "plus.rectangle.on.folder")
                    }
                    .help(loc: "Add Folder to Workspace…")
                }
            }
        }
        .errorAlert($workspace.errorMessage)
        .sheet(isPresented: $workspace.isQuickOpenVisible) { QuickOpenView(workspace: workspace, model: model) }
        .focusedSceneValue(\.workspace, workspace)
        .background(WindowBridge(workspace: workspace, representedURL: representedURL))
        .background(TabNumberShortcuts(workspace: workspace))
        .background(SearchShortcut(workspace: workspace))
        .background(ZoomInAlternateShortcut(settings: settings))
        .handlesWindowRequests(model)
        .onChange(of: settings.sidebarSort) { workspace.rescan() }
        .onChange(of: settings.showNonMarkdownFiles) { workspace.rescan() }
        .onDisappear {
            workspace.documents.forEach { $0.flush() }
            model.workspaceClosed(workspace)
        }
    }

    @ViewBuilder private var detail: some View {
        if let tab = workspace.activeTab {
            let document = tab.document
            VStack(spacing: 0) {
                if let reason = document.readOnlyReason {
                    Label(reason, systemImage: "lock")
                        .appFont(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.bar)
                    Divider()
                }
                NoteEditorView(document: document, showsSource: tab.showsSource,
                               onOpenLink: { workspace.openLink($0, from: document) })
                    // Keyed by tab and document, not the URL, so a rename keeps the editor (cursor, undo).
                    .id(EditorKey(tab: tab.id, document: document.id))
                    .onAppear { workspace.editorAppeared(tab) }
                if settings.showStatusBar {
                    StatusBar(document: document).id(document.id)
                }
            }
        } else {
            ContentUnavailableView {
                Label(loc: "No note selected", systemImage: "doc.text")
            } description: {
                Text(loc: "Select a note in the sidebar or press ⌘N to create one.")
            }
            // Fills the column so the tab bar stays at the top instead of centring with the placeholder.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct EditorKey: Hashable {
        let tab: UUID
        let document: UUID
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { workspace.isSidebarVisible ? .all : .detailOnly },
                set: { workspace.isSidebarVisible = $0 != .detailOnly })
    }

    /// The open note's name; with no tab the main window shows no title (the app's name adds nothing there).
    private var title: String {
        if let document = workspace.activeDocument { return document.title }
        return workspace.isMain ? "" : workspace.roots.first?.name ?? ""
    }

    private var representedURL: URL? {
        workspace.activeDocument.flatMap { $0.isDraft ? nil : $0.url }
    }

    private var documentError: Binding<String?> {
        Binding(get: { workspace.documents.first { $0.error != nil }?.error },
                set: { if $0 == nil { workspace.documents.first { $0.error != nil }?.error = nil } })
    }
}

/// ⌘1…⌘9 pick a tab. Invisible buttons: nine menu items would only clutter the Window menu.
private struct TabNumberShortcuts: View {
    let workspace: Workspace

    var body: some View {
        ZStack {
            ForEach(1...9, id: \.self) { number in
                Button("") { workspace.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// ⇧⌘F shows the sidebar and puts the cursor in its search field (⌘F stays the editor's find bar). An invisible
/// button, like the tab number shortcuts: a menu item would only repeat what the search field's own menu does.
private struct SearchShortcut: View {
    let workspace: Workspace

    var body: some View {
        Button("") { workspace.requestSearchFocus() }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

/// ⌘= also zooms in (the menu item's own shortcut is ⌘+, which a US keyboard types with Shift).
private struct ZoomInAlternateShortcut: View {
    let settings: AppSettings

    var body: some View {
        Button("") { settings.zoomIn() }
            .keyboardShortcut("=", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

/// Connects the workspace with its window: remembers the window, keeps AppKit from restoring outside-file windows
/// (the session file does that, without reopening files that are gone), guards closing and sets the proxy icon.
private struct WindowBridge: NSViewRepresentable {
    let workspace: Workspace
    let representedURL: URL?

    final class Marker: NSView {
        weak var workspace: Workspace?
        var representedURL: URL?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let workspace else { return }
            workspace.window = window
            window.isRestorable = workspace.isMain && LaunchOptions.isPersistent
            window.tabbingMode = .disallowed
            if let frame = workspace.pendingFrame {
                workspace.pendingFrame = nil
                window.setFrame(frame, display: true)
            }
            window.representedURL = representedURL
            CloseGuardDelegate.install(on: window) { [weak workspace] window in workspace?.shouldClose(window) ?? true }
        }
    }

    func makeNSView(context: Context) -> Marker {
        let view = Marker()
        view.workspace = workspace
        view.representedURL = representedURL
        return view
    }

    func updateNSView(_ view: Marker, context: Context) {
        view.workspace = workspace
        view.representedURL = representedURL
        if view.window?.representedURL != representedURL { view.window?.representedURL = representedURL }
    }
}

/// Content of a window whose workspace no longer exists (e.g. one AppKit restored from an older version): closes it.
struct StaleWindowCloser: NSViewRepresentable {
    final class Closer: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isRestorable = false
            DispatchQueue.main.async { window.close() }
        }
    }

    func makeNSView(context: Context) -> Closer { Closer() }
    func updateNSView(_ view: Closer, context: Context) {}
}

private struct WindowRequestHandler: ViewModifier {
    let model: NotesModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: model.windowRequests, initial: true) {
            let requests = model.windowRequests
            guard !requests.isEmpty else { return }
            model.windowRequests = []
            for request in requests {
                switch request {
                case .main:
                    if let window = model.main.window, window.isVisible {
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: NotesApp.mainWindowID)
                    }
                case .workspace(let id):
                    guard let workspace = model.workspace(id) else { continue }
                    if let window = workspace.window, window.isVisible {
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: NotesApp.workspaceWindowID, value: id)
                    }
                }
            }
        }
    }
}

/// Answers `windowShouldClose` and forwards every other delegate message to SwiftUI's own window delegate.
@MainActor
private final class CloseGuardDelegate: NSObject, NSWindowDelegate {
    nonisolated(unsafe) private static var associationKey: UInt8 = 0

    // Weak: SwiftUI owns its delegate; the window retains this object (associated object).
    nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?
    private var shouldClose: @MainActor (NSWindow) -> Bool

    private init(original: (any NSWindowDelegate)?, shouldClose: @escaping @MainActor (NSWindow) -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
    }

    /// Makes `window` ask `shouldClose` first. Installing again (a new marker view, or SwiftUI resetting the
    /// delegate) never wraps a guard in another guard.
    static func install(on window: NSWindow, shouldClose: @escaping @MainActor (NSWindow) -> Bool) {
        if let existing = window.delegate as? CloseGuardDelegate {
            existing.shouldClose = shouldClose
            return
        }
        let existing = objc_getAssociatedObject(window, &associationKey) as? CloseGuardDelegate
        let original = window.delegate ?? existing?.original
        let guardDelegate = CloseGuardDelegate(original: original, shouldClose: shouldClose)
        objc_setAssociatedObject(window, &associationKey, guardDelegate, .OBJC_ASSOCIATION_RETAIN)
        window.delegate = guardDelegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose(sender) else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if let original, original.responds(to: selector) { return original }
        return super.forwardingTarget(for: selector)
    }
}

extension View {
    func handlesWindowRequests(_ model: NotesModel) -> some View {
        modifier(WindowRequestHandler(model: model))
    }

    func errorAlert(_ message: Binding<String?>) -> some View {
        alert(Text(loc: "Error"), isPresented: message.isPresent, presenting: message.wrappedValue) { _ in
            Button(loc: "OK") {}
        } message: { Text($0) }
    }
}

extension Optional {
    /// `true` while a value is present; setting `false` clears it. Lets alerts bind to `$model.optional.isPresent`.
    var isPresent: Bool {
        get { self != nil }
        set { if !newValue { self = nil } }
    }
}
