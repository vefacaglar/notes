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

/// View menu items of the Markdown editor (the outline, focus mode) and the Format menu.
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
        CommandMenu(L("Format")) {
            let disabled = editor == nil || editor?.isReadOnly == true
            Group {
                Button(loc: "Bold") { editor?.toggle(.bold) }.keyboardShortcut("b")
                Button(loc: "Italic") { editor?.toggle(.italic) }.keyboardShortcut("i")
                Button(loc: "Strikethrough") { editor?.toggle(.strikethrough) }.keyboardShortcut("x", modifiers: [.command, .shift])
                Button(loc: "Inline Code") { editor?.toggle(.code) }.keyboardShortcut("c", modifiers: [.command, .control])
                Button(loc: "Link") { editor?.insertLink() }.keyboardShortcut("k")
                Divider()
                Menu {
                    Button(loc: "Heading 1") { editor?.apply(.heading(1)) }.keyboardShortcut("1", modifiers: [.command, .option])
                    Button(loc: "Heading 2") { editor?.apply(.heading(2)) }.keyboardShortcut("2", modifiers: [.command, .option])
                    Button(loc: "Heading 3") { editor?.apply(.heading(3)) }.keyboardShortcut("3", modifiers: [.command, .option])
                    Button(loc: "Body") { editor?.apply(.body) }.keyboardShortcut("0", modifiers: [.command, .option])
                } label: { Text(loc: "Heading") }
                Button(loc: "Bulleted List") { editor?.apply(.bullet) }.keyboardShortcut("8", modifiers: [.command, .shift])
                Button(loc: "Numbered List") { editor?.apply(.numbered) }.keyboardShortcut("7", modifiers: [.command, .shift])
                Button(loc: "Checklist") { editor?.apply(.task) }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button(loc: "Quote") { editor?.apply(.quote) }.keyboardShortcut("'", modifiers: [.command, .shift])
                Divider()
                Button(loc: "Code Block") { editor?.insertCodeBlock() }.keyboardShortcut("k", modifiers: [.command, .option])
                Button(loc: "Horizontal Rule") { editor?.insertRule() }.keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Menu {
                    Button(loc: "Insert Table…", action: insertTable).keyboardShortcut("t", modifiers: [.command, .shift])
                    Button(loc: "Convert Selection to Table") { editor?.convertToTable() }
                    Divider()
                    Button(loc: "Add Row Above") { editor?.tableCommand(.addRow(above: true)) }
                    Button(loc: "Add Row Below") { editor?.tableCommand(.addRow(above: false)) }
                    Button(loc: "Add Column Left") { editor?.tableCommand(.addColumn(before: true)) }
                    Button(loc: "Add Column Right") { editor?.tableCommand(.addColumn(before: false)) }
                    Button(loc: "Delete Row") { editor?.tableCommand(.deleteRow) }
                    Button(loc: "Delete Column") { editor?.tableCommand(.deleteColumn) }
                    Divider()
                    Button(loc: "Align Column Left") { editor?.tableCommand(.align(.left)) }
                    Button(loc: "Align Column Center") { editor?.tableCommand(.align(.center)) }
                    Button(loc: "Align Column Right") { editor?.tableCommand(.align(.right)) }
                } label: { Text(loc: "Table") }
            }
            .disabled(disabled)
        }
    }

    /// Opens the size picker of the formatting bar; without the bar a 3 × 3 table goes in.
    private func insertTable() {
        if settings.showFormattingBar { editor?.isTablePickerShown = true } else { editor?.insertTable(rows: 3, columns: 3) }
    }
}
