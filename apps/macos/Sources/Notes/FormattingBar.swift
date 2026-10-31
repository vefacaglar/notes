import NotesCore
import SwiftUI

/// The Markdown formatting controls of the window toolbar, for the active tab's editor. Every action is a
/// `TextEditorProxy` method, the same ones the Format menu calls.
struct FormattingToolbar: ToolbarContent {
    let editor: TextEditorProxy
    let isReadOnly: Bool

    var body: some ToolbarContent {
        let format = editor.activeFormat
        ToolbarItem {
            Menu {
                headingItem("Heading 1", level: 1, format: format)
                headingItem("Heading 2", level: 2, format: format)
                headingItem("Heading 3", level: 3, format: format)
                Toggle(loc: "Body", isOn: Binding(get: { format.heading == 0 }, set: { _ in editor.apply(.body) }))
            } label: {
                Label(loc: "Heading", systemImage: "textformat.size")
            }
            .menuIndicator(.hidden)
            .disabled(isReadOnly)
            .help(loc: "Heading")
        }
        ToolbarItem {
            ControlGroup {
                toggle("bold", "Bold (⌘B)", on: format.inline.contains(.bold)) { editor.toggle(.bold) }
                toggle("italic", "Italic (⌘I)", on: format.inline.contains(.italic)) { editor.toggle(.italic) }
                toggle("strikethrough", "Strikethrough (⇧⌘X)", on: format.inline.contains(.strikethrough)) { editor.toggle(.strikethrough) }
                toggle("chevron.left.forwardslash.chevron.right", "Inline Code (⌃⌘C)", on: format.inline.contains(.code)) { editor.toggle(.code) }
            }
            .disabled(isReadOnly)
        }
        ToolbarItem {
            ControlGroup {
                toggle("list.bullet", "Bulleted List (⇧⌘8)", on: format.bullet) { editor.apply(.bullet) }
                toggle("list.number", "Numbered List (⇧⌘7)", on: format.numbered) { editor.apply(.numbered) }
                toggle("checklist", "Checklist (⇧⌘L)", on: format.task) { editor.apply(.task) }
                toggle("text.quote", "Block Quote (⇧⌘')", on: format.quote) { editor.apply(.quote) }
            }
            .disabled(isReadOnly)
        }
        ToolbarItem {
            ControlGroup {
                button("link", "Link (⌘K)") { editor.insertLink() }
                button("curlybraces", "Code Block (⌥⌘K)") { editor.insertCodeBlock() }
                button("tablecells", "Table (⇧⌘T)") { editor.isTablePickerShown.toggle() }
                    .popover(isPresented: Bindable(editor).isTablePickerShown, arrowEdge: .bottom) {
                        TablePicker(editor: editor)
                    }
                button("minus", "Horizontal Rule (⇧⌘H)") { editor.insertRule() }
            }
            .disabled(isReadOnly)
        }
    }

    private func headingItem(_ key: LocalizedStringKey, level: Int, format: ActiveFormat) -> some View {
        Toggle(loc: key, isOn: Binding(get: { format.heading == level }, set: { _ in editor.apply(.heading(level)) }))
    }

    private func toggle(_ symbol: String, _ key: LocalizedStringKey, on: Bool, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { _ in action() })) { Label(loc: key, systemImage: symbol) }
            .toggleStyle(.button)
            .help(loc: key)
    }

    private func button(_ symbol: String, _ key: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(loc: key, systemImage: symbol) }
            .help(loc: key)
    }
}

/// Grid of squares to choose a table size (rows include the header), plus conversion of the selected lines.
struct TablePicker: View {
    let editor: TextEditorProxy
    @State private var hovered = (rows: 3, columns: 3)
    private let size = 8

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 3) {
                ForEach(1...size, id: \.self) { row in
                    HStack(spacing: 3) {
                        ForEach(1...size, id: \.self) { column in
                            let covered = row <= hovered.rows && column <= hovered.columns
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.primary.opacity(covered ? 0.3 : 0.08))
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                                .onHover { inside in if inside { hovered = (row, column) } }
                                .onTapGesture {
                                    editor.isTablePickerShown = false
                                    editor.insertTable(rows: row, columns: column)
                                }
                        }
                    }
                }
            }
            Text(verbatim: "\(hovered.rows) × \(hovered.columns)")
                .appFont(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button(loc: "Convert Selection to Table") {
                editor.isTablePickerShown = false
                editor.convertToTable()
            }
            .buttonStyle(.borderless)
            .appFont(.caption)
        }
        .padding(12)
    }
}
