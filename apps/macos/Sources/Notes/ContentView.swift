import AppKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: NotesModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            Group {
                if let document = model.document {
                    NoteEditorView(document: document, focusOnAppear: document.focusOnOpen)
                        // Keyed by the document, not its URL, so a rename keeps the editor (cursor, undo).
                        .id(document.id)
                } else {
                    ContentUnavailableView(
                        "Not seçilmedi", systemImage: "doc.text",
                        description: Text("Kenar çubuğundan bir not seçin ya da ⌘N ile yeni bir not oluşturun.")
                    )
                }
            }
            // On the column, not the editor, so it stays up whatever happens to the editor.
            .errorAlert(documentError)
        }
        .navigationTitle(model.document?.name ?? "Notes")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Yeni Not", systemImage: "square.and.pencil", action: model.newNote)
                Button("Yeni Klasör", systemImage: "folder.badge.plus", action: model.newFolder)
            }
        }
        .errorAlert($model.errorMessage)
        .handlesWindowRequests(model)
        .guardsWindowClose { model.document }
        .onDisappear { model.document?.flush() }
    }

    private var documentError: Binding<String?> {
        Binding(get: { model.document?.error }, set: { model.document?.error = $0 })
    }
}

/// Edits a file outside the notes folder in its own window.
struct ExternalNoteView: View {
    let url: URL
    let model: NotesModel
    @State private var document: NoteDocument?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let document {
                NoteEditorView(document: document)
            } else if let loadError {
                ContentUnavailableView("Dosya açılamadı", systemImage: "exclamationmark.triangle", description: Text(loadError))
            } else {
                Color.clear
            }
        }
        .errorAlert(Binding(get: { document?.error }, set: { document?.error = $0 }))
        .navigationTitle(document?.url.lastPathComponent ?? url.lastPathComponent)
        .background(RepresentedURL(url: document?.url ?? url))
        .task(id: url) {
            do {
                document = try NoteDocument.open(url)
            } catch {
                loadError = error.localizedDescription
            }
        }
        .handlesWindowRequests(model)
        .guardsWindowClose { document }
        .onDisappear { document?.flush() }
    }
}

/// Sets the hosting window's `representedURL` (proxy icon; also lets `WindowRequestHandler` find the window again).
private struct RepresentedURL: NSViewRepresentable {
    let url: URL

    final class Marker: NSView {
        var url: URL?
        override func viewDidMoveToWindow() { window?.representedURL = url }
    }

    func makeNSView(context: Context) -> Marker {
        let view = Marker()
        view.url = url
        return view
    }

    func updateNSView(_ view: Marker, context: Context) {
        view.url = url
        view.window?.representedURL = url
    }
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
                case .main: openWindow(id: NotesApp.mainWindowID)
                case .file(let url):
                    if let window = NSApp.windows.first(where: { $0.representedURL == url }) {
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(value: url)
                    }
                }
            }
        }
    }
}

/// Saves the window's document before the window closes. When that needs the user (the save failed, or a conflict
/// copy was made), the close waits for an alert: a failed save offers to keep the window open or discard the edits.
private struct WindowCloseGuard: NSViewRepresentable {
    let document: @MainActor () -> NoteDocument?

    final class Marker: NSView {
        var document: (@MainActor () -> NoteDocument?)?
        private var delegate: CloseGuardDelegate?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.delegate !== delegate else { return }
            let delegate = CloseGuardDelegate(original: window.delegate) { [weak self] window in
                self?.shouldClose(window) ?? true
            }
            self.delegate = delegate
            window.delegate = delegate
        }

        private func shouldClose(_ window: NSWindow) -> Bool {
            guard let document = document?(), !document.flush() else { return true }
            let alert = NSAlert()
            alert.messageText = document.hasUnsavedChanges ? "Değişiklikler kaydedilemedi" : "Dosya başka yerde değişti"
            alert.informativeText = document.error ?? ""
            document.error = nil
            if document.hasUnsavedChanges {
                alert.addButton(withTitle: "Vazgeç")
                alert.addButton(withTitle: "Kaydetmeden Kapat").hasDestructiveAction = true
            } else {
                alert.addButton(withTitle: "Tamam")
            }
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated {
                    guard !document.hasUnsavedChanges || response == .alertSecondButtonReturn else { return }
                    document.revert()
                    window.close()
                }
            }
            return false
        }
    }

    func makeNSView(context: Context) -> Marker {
        let view = Marker()
        view.document = document
        return view
    }

    func updateNSView(_ view: Marker, context: Context) {
        view.document = document
    }
}

/// Answers `windowShouldClose` and forwards every other delegate message to SwiftUI's own window delegate.
@MainActor
private final class CloseGuardDelegate: NSObject, NSWindowDelegate {
    // Weak: SwiftUI owns its delegate, and the window owns this object through the marker view.
    nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?
    private let shouldClose: @MainActor (NSWindow) -> Bool

    init(original: (any NSWindowDelegate)?, shouldClose: @escaping @MainActor (NSWindow) -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
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

    func guardsWindowClose(_ document: @escaping @MainActor () -> NoteDocument?) -> some View {
        background(WindowCloseGuard(document: document))
    }

    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("Hata", isPresented: message.isPresent, presenting: message.wrappedValue) { _ in
            Button("Tamam") {}
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
