import SwiftUI

extension FocusedValues {
    /// The focused window's Markdown editor (published for every Markdown file, read-only ones included).
    var markdownEditor: TextEditorProxy? {
        get { self[MarkdownEditorKey.self] }
        set { self[MarkdownEditorKey.self] = newValue }
    }

    private struct MarkdownEditorKey: FocusedValueKey {
        typealias Value = TextEditorProxy
    }
}

/// View menu items of the Markdown editor: the outline and focus mode.
struct EditorCommands: Commands {
    @FocusedValue(\.markdownEditor) private var editor
    @Bindable private var settings = AppSettings.shared

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button(loc: editor?.isOutlineShown == true ? "Hide Outline" : "Show Outline") { editor?.toggleOutline() }
                .keyboardShortcut("o", modifiers: [.command, .control])
                .disabled(editor == nil)
            Toggle(loc: "Focus Mode", isOn: $settings.focusMode)
                .keyboardShortcut("j", modifiers: [.command, .shift])
        }
    }
}
