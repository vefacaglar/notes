import NotesCore
import SwiftUI

/// The single place that hosts the text editor, shared by the main window and standalone file windows:
/// the Markdown editor for Markdown files (`.md`, `.markdown`, `.mdown`, `.mkd`), the code editor for the rest.
/// Theme and editor settings come from `AppSettings` (the environment's, else `.shared`) and apply live.
struct NoteEditorView: View {
    @Bindable var document: NoteDocument
    /// Markdown only: show the file as unstyled source in the code font (same text view and undo stack).
    var showsSource = false
    var focusOnAppear = false
    /// Lets the "Format" command and the document reach this window's editor; see `TextEditorProxy`.
    @State private var editor = TextEditorProxy()
    @Environment(AppSettings.self) private var environmentSettings: AppSettings?
    @Environment(\.colorScheme) private var colorScheme

    init(document: NoteDocument, showsSource: Bool = false, focusOnAppear: Bool = false) {
        self.document = document
        self.showsSource = showsSource
        self.focusOnAppear = focusOnAppear
    }

    var body: some View {
        let language = document.language
        let style = EditorStyle(settings: environmentSettings ?? .shared, colorScheme: colorScheme)
        Group {
            if language == .markdown {
                MarkdownEditor(text: $document.text, style: style, showsSource: showsSource, focusOnAppear: focusOnAppear,
                               proxy: editor, undoManager: document.undoManager, isEditable: !document.isReadOnly)
            } else {
                CodeEditor(text: $document.text, language: language, style: style, focusOnAppear: focusOnAppear, proxy: editor,
                           undoManager: document.undoManager, isEditable: !document.isReadOnly)
            }
        }
        .background(Color(nsColor: style.theme.colors.background.nsColor))
        .focusedSceneValue(\.textEditor, language.canFormat && !document.isReadOnly ? editor : nil)
        .onAppear { document.attach(editor) }
    }
}
