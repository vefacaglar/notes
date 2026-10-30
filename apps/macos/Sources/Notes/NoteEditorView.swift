import NotesCore
import SwiftUI

/// The single place that hosts the text editor, shared by the main window and standalone file windows:
/// the Markdown editor for notes (`.md`), the code editor for every other file.
struct NoteEditorView: View {
    @Bindable var document: NoteDocument
    var focusOnAppear = false
    /// Lets the "Biçimlendir" command reach this window's editor; see `TextEditorProxy`.
    @State private var editor = TextEditorProxy()

    var body: some View {
        let language = document.language
        Group {
            if document.isNote {
                MarkdownEditor(text: $document.text, focusOnAppear: focusOnAppear, proxy: editor,
                               undoManager: document.undoManager)
            } else {
                CodeEditor(text: $document.text, language: language, focusOnAppear: focusOnAppear, proxy: editor,
                           undoManager: document.undoManager)
            }
        }
        .focusedSceneValue(\.textEditor, language.canFormat ? editor : nil)
    }
}
