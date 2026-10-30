import AppKit
import SwiftUI

@main
struct NotesApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Notes", id: Self.mainWindowID) {
            ContentView(model: appDelegate.model)
        }
        .defaultSize(width: 1000, height: 680)
        .commands { NotesCommands(model: appDelegate.model) }

        WindowGroup(for: URL.self) { $url in
            if let url { ExternalNoteView(url: url, model: appDelegate.model) }
        }
        .defaultSize(width: 720, height: 680)
        // Files from Finder go through AppDelegate.application(_:open:), not SwiftUI's scene routing.
        .handlesExternalEvents(matching: [])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = NotesModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Behave like a regular app when launched as a bare executable (`swift run`).
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.open(urls)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refresh()
        NoteDocument.reloadAll()
    }

    func applicationWillResignActive(_ notification: Notification) {
        NoteDocument.flushAll()
    }

    /// Saves everything first. If a save failed, asks before quitting without it; conflict notices are shown too,
    /// since their windows are about to go away.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !NoteDocument.flushAll() else { return .terminateNow }
        let documents = NoteDocument.all.filter { $0.error != nil }
        let unsaved = documents.contains { $0.hasUnsavedChanges }
        let alert = NSAlert()
        alert.messageText = unsaved ? "Bazı değişiklikler kaydedilemedi" : "Bazı dosyalar başka yerde değişti"
        alert.informativeText = documents.compactMap(\.error).joined(separator: "\n\n")
        documents.forEach { $0.error = nil }
        guard unsaved else {
            alert.runModal()
            return .terminateNow
        }
        alert.addButton(withTitle: "Vazgeç")
        alert.addButton(withTitle: "Kaydetmeden Çık").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        documents.forEach { $0.revert() }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        NoteDocument.flushAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct NotesCommands: Commands {
    let model: NotesModel
    /// The focused window's editor when its file can be formatted (JSON).
    @FocusedValue(\.textEditor) private var editor

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Yeni Not", action: model.newNote)
                .keyboardShortcut("n")
            Button("Yeni Klasör", action: model.newFolder)
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Klasör Seç…", action: model.chooseFolder)
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Kaydet") { NoteDocument.flushAll() }
                .keyboardShortcut("s")
        }
        CommandGroup(after: .textEditing) {
            Divider()
            // Goes through the text view, so ⌘Z undoes it.
            Button("Biçimlendir") { editor?.format() }
                .keyboardShortcut("f", modifiers: [.option, .shift])
                .disabled(editor == nil)
        }
    }
}
