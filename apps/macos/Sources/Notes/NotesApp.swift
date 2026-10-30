import AppKit
import SwiftUI

/// Entry point: the UI language is fixed before any window, bundle lookup or model exists.
@main
enum Launcher {
    static func main() {
        LanguageSetting.configureAtLaunch()
        NotesApp.main()
    }
}

struct NotesApp: App {
    static let mainWindowID = "main"
    static let workspaceWindowID = "workspace"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(Text(loc: "Notes"), id: Self.mainWindowID) {
            WorkspaceView(workspace: appDelegate.model.main, model: appDelegate.model)
                .environment(AppSettings.shared)
        }
        .defaultSize(width: 1000, height: 680)
        .commands { NotesCommands(model: appDelegate.model) }

        // Windows of files opened from outside the roots. They are never restored by AppKit (see `WindowBridge`);
        // the session file brings them back instead.
        WindowGroup(id: Self.workspaceWindowID, for: UUID.self) { $id in
            if let id, let workspace = appDelegate.model.workspace(id), !workspace.isMain {
                WorkspaceView(workspace: workspace, model: appDelegate.model)
                    .environment(AppSettings.shared)
            } else {
                StaleWindowCloser()
            }
        }
        .defaultSize(width: 820, height: 680)
        // Files from Finder go through AppDelegate.application(_:open:), not SwiftUI's scene routing.
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView()
                .environment(AppSettings.shared)
                // With only Settings open, no workspace window exists to handle requests (a file opened from Finder,
                // Add Folder…); this one opens the main window.
                .handlesWindowRequests(appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = NotesModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Behave like a regular app when launched as a bare executable (`swift run`).
        NSApp.setActivationPolicy(.regular)
        // Tabs live inside the window; macOS window tabs would be a second, competing kind.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.shared.applyAppearance()
        NSApp.activate()
        Self.moveCloseWindowShortcut()
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.moveCloseWindowShortcut() }
        }
    }

    /// ⌘W closes a tab here, so the standard "Close" (window) item takes ⇧⌘W. Best effort: when SwiftUI rebuilds the
    /// menu, `Workspace.shouldClose` still turns a ⌘W window close into closing the active tab.
    private static func moveCloseWindowShortcut() {
        guard let fileMenu = NSApp.mainMenu?.items.first(where: { $0.submenu?.items.contains { $0.action == #selector(NSWindow.performClose(_:)) } == true })?.submenu
        else { return }
        for item in fileMenu.items where item.action == #selector(NSWindow.performClose(_:)) {
            item.keyEquivalent = "w"
            item.keyEquivalentModifierMask = [.command, .shift]
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.open(urls)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshAll()
        NoteDocument.reloadAll()
    }

    func applicationWillResignActive(_ notification: Notification) {
        NoteDocument.flushAll()
        model.saveSession()
    }

    /// Saves everything first. If a save failed, asks before quitting without it; conflict notices are shown too,
    /// since their windows are about to go away. Drafts need no question: they stay in the draft store.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = terminationReply()
        if reply == .terminateCancel { LanguageSetting.relaunchPending = false }
        return reply
    }

    private func terminationReply() -> NSApplication.TerminateReply {
        guard !NoteDocument.flushAll() else {
            model.prepareForQuit()
            return .terminateNow
        }
        while true {
            let documents = NoteDocument.all.filter { $0.error != nil }
            let unsaved = documents.contains { $0.hasUnsavedChanges }
            let alert = NSAlert()
            alert.messageText = unsaved ? L("Some changes couldn't be saved") : L("Some files were changed elsewhere")
            alert.informativeText = documents.compactMap(\.error).joined(separator: "\n\n")
            documents.forEach { $0.error = nil }
            guard unsaved else {
                alert.runModal()
                model.prepareForQuit()
                return .terminateNow
            }
            alert.addButton(withTitle: L("Try Again"))
            alert.addButton(withTitle: L("Cancel"))
            alert.addButton(withTitle: L("Quit Without Saving")).hasDestructiveAction = true
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if NoteDocument.flushAll() {
                    model.prepareForQuit()
                    return .terminateNow
                }
            case .alertThirdButtonReturn:
                documents.forEach { $0.revert() }
                model.prepareForQuit()
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NoteDocument.flushAll()
        model.prepareForQuit()
        if LanguageSetting.relaunchPending { LanguageSetting.relaunch(releasing: model) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct NotesCommands: Commands {
    let model: NotesModel
    /// The focused window's editor when its file can be formatted (JSON).
    @FocusedValue(\.textEditor) private var editor
    /// The key window's workspace; `nil` while e.g. Settings is in front.
    @FocusedValue(\.workspace) private var workspace

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(loc: "New Note") {
                model.main.newNote()
                model.windowRequests.append(.main)
            }
            .keyboardShortcut("n")
            Button(loc: "New Tab") {
                (workspace ?? model.main).newDraftTab()
                if workspace == nil { model.windowRequests.append(.main) }
            }
            .keyboardShortcut("t")
            Button(loc: "New Folder") { (workspace ?? model.main).newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button(loc: "Add Folder to Workspace…", action: model.chooseRoot)
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button(loc: "Close Tab") {
                if let workspace { workspace.closeActiveTabOrWindow() } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
            Divider()
            Button(loc: "Save") {
                if let workspace { workspace.saveActive() } else { NoteDocument.flushAll() }
            }
            .keyboardShortcut("s")
            Button(loc: "Save As…") { workspace?.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(workspace?.activeTab == nil)
        }
        CommandGroup(after: .textEditing) {
            Divider()
            // Goes through the text view, so ⌘Z undoes it.
            Button(loc: "Format") { editor?.format() }
                .keyboardShortcut("f", modifiers: [.option, .shift])
                .disabled(editor == nil)
        }
        CommandGroup(before: .sidebar) {
            Button(loc: workspace?.isSidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") {
                workspace?.isSidebarVisible.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(workspace == nil)
            Toggle(loc: "Show Source", isOn: Binding(
                get: { workspace?.activeTab?.showsSource ?? false },
                set: { _ in workspace?.toggleSource() }
            ))
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(workspace?.activeDocument?.language != .markdown)
            Divider()
        }
        CommandGroup(before: .windowList) {
            Button(loc: "Show Next Tab") { workspace?.cycleTab(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button(loc: "Show Previous Tab") { workspace?.cycleTab(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button(loc: "Select Next Tab") { workspace?.cycleTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button(loc: "Select Previous Tab") { workspace?.cycleTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
        }
    }
}

extension FocusedValues {
    /// The workspace of the key window, for the menu commands.
    var workspace: Workspace? {
        get { self[WorkspaceKey.self] }
        set { self[WorkspaceKey.self] = newValue }
    }

    private struct WorkspaceKey: FocusedValueKey {
        typealias Value = Workspace
    }
}
