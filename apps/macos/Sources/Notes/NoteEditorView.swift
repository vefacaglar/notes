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
    /// Follows a clicked link (its destination as written); the workspace window passes `Workspace.openLink`.
    var onOpenLink: ((String) -> Void)?
    /// Lets the "Format" command, the toolbar and the document reach this editor; see `TextEditorProxy`.
    let editor: TextEditorProxy
    @Environment(AppSettings.self) private var environmentSettings: AppSettings?
    @Environment(\.colorScheme) private var colorScheme

    init(document: NoteDocument, editor: TextEditorProxy, showsSource: Bool = false, focusOnAppear: Bool = false,
         onOpenLink: ((String) -> Void)? = nil) {
        self.document = document
        self.editor = editor
        self.onOpenLink = onOpenLink
        self.showsSource = showsSource
        self.focusOnAppear = focusOnAppear
    }

    var body: some View {
        let language = document.language
        let settings = environmentSettings ?? .shared
        let style = EditorStyle(settings: settings, colorScheme: colorScheme)
        VStack(spacing: 0) {
            Group {
                if language == .markdown {
                    MarkdownEditor(text: $document.text, style: style, showsSource: showsSource, focusOnAppear: focusOnAppear,
                                   proxy: editor, undoManager: document.undoManager, isEditable: !document.isReadOnly, onOpenLink: onOpenLink,
                                   noteURL: document.isDraft ? nil : document.url,
                                   allowsImageInsertion: !document.isEncrypted, focusMode: settings.focusMode)
                } else {
                    CodeEditor(text: $document.text, language: language, style: style, focusOnAppear: focusOnAppear, proxy: editor,
                               undoManager: document.undoManager, isEditable: !document.isReadOnly)
                }
            }
            .background(Color(nsColor: style.theme.colors.background.nsColor))
        }
        .focusedSceneValue(\.textEditor, language.canFormat && !document.isReadOnly ? editor : nil)
        .focusedSceneValue(\.markdownEditor, language == .markdown ? editor : nil)
        .onAppear { document.attach(editor) }
        .onChange(of: document.isReadOnly, initial: true) { _, readOnly in editor.isReadOnly = readOnly }
    }
}
