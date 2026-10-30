import NotesCore
import SwiftUI

/// The single place that hosts the text editor, shared by the main window and standalone file windows:
/// the Markdown editor for Markdown files (`.md`, `.markdown`, `.mdown`, `.mkd`), the code editor for the rest.
struct NoteEditorView: View {
    @Bindable var document: NoteDocument
    var focusOnAppear = false
    /// Lets the "Biçimlendir" command and the document reach this window's editor; see `TextEditorProxy`.
    @State private var editor = TextEditorProxy()

    var body: some View {
        let language = document.language
        Group {
            if language == .markdown {
                MarkdownEditor(text: $document.text, focusOnAppear: focusOnAppear, proxy: editor,
                               undoManager: document.undoManager, isEditable: !document.isReadOnly)
            } else {
                CodeEditor(text: $document.text, language: language, focusOnAppear: focusOnAppear, proxy: editor,
                           undoManager: document.undoManager, isEditable: !document.isReadOnly)
            }
        }
        .focusedSceneValue(\.textEditor, language.canFormat && !document.isReadOnly ? editor : nil)
        .onAppear { document.attach(editor) }
    }
}
