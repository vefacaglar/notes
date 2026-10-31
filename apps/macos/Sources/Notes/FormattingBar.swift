import NotesCore
import SwiftUI

/// The Markdown formatting controls of the window toolbar, for the active tab's editor. Every action is a
/// `TextEditorProxy` method, the same ones the Format menu calls.
struct FormattingToolbar<Trailing: View>: ToolbarContent {
    let editor: TextEditorProxy
    let isReadOnly: Bool
    /// The outline button, last in the group.
    @ViewBuilder var trailing: Trailing

    var body: some ToolbarContent {
        let format = editor.activeFormat
        // One item in the middle of the toolbar, so the controls share one rounded (capsule) background.
        ToolbarItem(placement: .principal) {
            HStack(spacing: 2) {
                HStack(spacing: 2) { formatting(format) }
                    .disabled(isReadOnly)
                separator
                trailing
                    .buttonStyle(BarButtonStyle(active: editor.isOutlineShown))
                    .labelStyle(.iconOnly)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .modifier(CapsuleBackground())
        }
    }

    /// Everything but the outline button: disabled for read-only files.
    @ViewBuilder private func formatting(_ format: ActiveFormat) -> some View {
        Menu {
            headingItem("Heading 1", level: 1, format: format)
            headingItem("Heading 2", level: 2, format: format)
            headingItem("Heading 3", level: 3, format: format)
            Toggle(loc: "Body", isOn: Binding(get: { format.heading == 0 }, set: { _ in editor.apply(.body) }))
        } label: {
            Image(systemName: "textformat.size")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(format.heading > 0 ? .primary : .secondary)
        .padding(.horizontal, 5)
        .help(loc: "Heading")
        separator
        button("bold", "Bold (⌘B)", active: format.inline.contains(.bold)) { editor.toggle(.bold) }
        button("italic", "Italic (⌘I)", active: format.inline.contains(.italic)) { editor.toggle(.italic) }
        button("strikethrough", "Strikethrough (⇧⌘X)", active: format.inline.contains(.strikethrough)) { editor.toggle(.strikethrough) }
        button("chevron.left.forwardslash.chevron.right", "Inline Code (⌃⌘C)", active: format.inline.contains(.code)) { editor.toggle(.code) }
        separator
        button("list.bullet", "Bulleted List (⇧⌘8)", active: format.bullet) { editor.apply(.bullet) }
        button("list.number", "Numbered List (⇧⌘7)", active: format.numbered) { editor.apply(.numbered) }
        button("checklist", "Checklist (⇧⌘L)", active: format.task) { editor.apply(.task) }
        button("text.quote", "Block Quote (⇧⌘')", active: format.quote) { editor.apply(.quote) }
        separator
        button("link", "Link (⌘K)") { editor.insertLink() }
        button("curlybraces", "Code Block (⌥⌘K)") { editor.insertCodeBlock() }
        button("tablecells", "Table (⇧⌘T)") { editor.isTablePickerShown.toggle() }
            .popover(isPresented: Bindable(editor).isTablePickerShown, arrowEdge: .bottom) {
                TablePicker(editor: editor)
            }
        button("minus", "Horizontal Rule (⇧⌘H)") { editor.insertRule() }
    }

    private var separator: some View {
        Divider().frame(height: 14).padding(.horizontal, 4)
    }

    private func headingItem(_ key: LocalizedStringKey, level: Int, format: ActiveFormat) -> some View {
        Toggle(loc: key, isOn: Binding(get: { format.heading == level }, set: { _ in editor.apply(.heading(level)) }))
    }

    private func button(_ symbol: String, _ key: LocalizedStringKey, active: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(BarButtonStyle(active: active))
            .help(loc: key)
    }
}

/// The group's own capsule: glass from macOS 26 (a custom principal item gets none from the toolbar), a material before.
private struct CapsuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        }
    }
}

private struct BarButtonStyle: ButtonStyle {
    let active: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14))
            .foregroundStyle(active ? .primary : .secondary)
            .frame(width: 30, height: 28)
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : active ? 0.1 : 0), in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
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
