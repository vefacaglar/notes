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
    /// Lets the "Format" command and the document reach this window's editor; see `TextEditorProxy`.
    @State private var editor = TextEditorProxy()
    @Environment(AppSettings.self) private var environmentSettings: AppSettings?
    @Environment(\.colorScheme) private var colorScheme

    init(document: NoteDocument, showsSource: Bool = false, focusOnAppear: Bool = false,
         onOpenLink: ((String) -> Void)? = nil) {
        self.document = document
        self.onOpenLink = onOpenLink
        self.showsSource = showsSource
        self.focusOnAppear = focusOnAppear
    }

    var body: some View {
        let language = document.language
        let settings = environmentSettings ?? .shared
        let style = EditorStyle(settings: settings, colorScheme: colorScheme)
        VStack(spacing: 0) {
            if language.canFormat {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Button(loc: "Format") { editor.format() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(document.isReadOnly)
                        .help(loc: "Format (⇧⌥F)")
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            if language == .markdown, settings.showFormattingBar {
                FormattingBar(editor: editor, isReadOnly: document.isReadOnly) { outlineButton }
            }
            Group {
                if language == .markdown {
                    MarkdownEditor(text: $document.text, style: style, showsSource: showsSource, focusOnAppear: focusOnAppear,
                                   proxy: editor, undoManager: document.undoManager, isEditable: !document.isReadOnly, onOpenLink: onOpenLink,
                                   noteURL: document.isDraft ? nil : document.url, focusMode: settings.focusMode)
                        .overlay(alignment: .topTrailing) {
                            if !settings.showFormattingBar { outlineButton.padding(.top, 6).padding(.trailing, 16) }
                        }
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

    /// Markdown only: opens the list of headings (⌃⌘O), small and out of the text's way in the top-right corner.
    private var outlineButton: some View {
        Button { editor.toggleOutline() } label: { Image(systemName: "list.bullet.indent") }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .help(loc: "Outline (⌃⌘O)")
            .popover(isPresented: Bindable(editor).isOutlineShown, arrowEdge: .bottom) {
                OutlineView(text: document.text) { heading in
                    editor.isOutlineShown = false
                    editor.reveal(location: heading.location)
                }
            }
    }
}
