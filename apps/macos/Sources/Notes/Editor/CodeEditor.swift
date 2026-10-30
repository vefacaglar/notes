import AppKit
import NotesCore
import SwiftUI

/// Monospaced editor with syntax highlighting for code, data and plain text files.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage
    var focusOnAppear = false
    var proxy: TextEditorProxy?
    var undoManager: UndoManager?

    init(text: Binding<String>, language: CodeLanguage, focusOnAppear: Bool = false, proxy: TextEditorProxy? = nil,
         undoManager: UndoManager? = nil) {
        _text = text
        self.language = language
        self.focusOnAppear = focusOnAppear
        self.proxy = proxy
        self.undoManager = undoManager
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, language: language, undoManager: undoManager)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CodeTextView(usingTextLayoutManager: false)
        textView.configureAsPlainTextEditor()
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.font = CodeTheme.font
        textView.defaultParagraphStyle = CodeTheme.paragraphStyle
        textView.typingAttributes = CodeTheme.base

        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        proxy?.textView = textView
        proxy?.language = language

        let scrollView = textView.embeddedInScrollView()
        context.coordinator.load(text, into: textView)
        if focusOnAppear { textView.requestFocus() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CodeTextView else { return }
        proxy?.textView = textView
        proxy?.language = language
        let coordinator = context.coordinator
        let languageChanged = coordinator.language != language
        coordinator.language = language
        if !coordinator.update($text, in: textView) && languageChanged {
            textView.indentUnit = language.indentUnit(for: textView.string)
            coordinator.needsFullRestyle = true
            coordinator.restyle(textView)
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let textView = scrollView.documentView as? NSTextView { coordinator.dismantle(textView) }
    }

    final class Coordinator: TextEditorCoordinator {
        var language: CodeLanguage
        private var spans: [CodeSpan] = []

        /// Beyond this many UTF-16 units the text stays plain; styling every span would stall typing.
        private static let maxHighlightedLength = 2_000_000

        init(text: Binding<String>, language: CodeLanguage, undoManager: UndoManager?) {
            self.language = language
            super.init(text: text, undoManager: undoManager)
        }

        override func load(_ text: String, into textView: NSTextView) {
            (textView as? CodeTextView)?.indentUnit = language.indentUnit(for: text)
            super.load(text, into: textView)
        }

        /// Tokenizes the whole text, then restyles only where the spans differ from last time.
        override func restyle(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let new = storage.length > Self.maxHighlightedLength
                ? [] : CodeHighlighter.spans(in: storage.string, language: language)
            var target = NSRange(location: 0, length: storage.length)
            if !needsFullRestyle, let edit = pendingEdit {
                target = CodeHighlighter.changedRange(
                    from: spans, to: new, editedRange: edit.range, changeInLength: edit.delta, length: storage.length)
            }
            spans = new
            pendingEdit = nil
            needsFullRestyle = false

            if target.length > 0 {
                storage.beginEditing()
                storage.setAttributes(CodeTheme.base, range: target)
                // Markdown spans nest, so their ends are not sorted.
                var k = language == .markdown ? 0 : Self.firstSpan(in: new, endingAfter: target.location)
                while k < new.count && new[k].range.location < NSMaxRange(target) {
                    let range = NSIntersectionRange(new[k].range, target)
                    if range.length > 0, let style = CodeTheme.styles[new[k].kind] {
                        storage.addAttributes(style, range: range)
                    }
                    k += 1
                }
                storage.endEditing()
            }
            textView.typingAttributes = CodeTheme.base
        }

        private static func firstSpan(in spans: [CodeSpan], endingAfter location: Int) -> Int {
            var lo = 0, hi = spans.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if NSMaxRange(spans[mid].range) <= location { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
    }
}

// MARK: - Theme

@MainActor
enum CodeTheme {
    static let fontSize: CGFloat = 13
    static let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.15
        style.tabStops = []
        style.defaultTabInterval = 4 * (" " as NSString).size(withAttributes: [.font: font]).width
        return style
    }()

    static let base: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.textColor,
        .paragraphStyle: paragraphStyle,
    ]

    /// System colors, so both appearances work.
    static let styles: [CodeSpan.Kind: [NSAttributedString.Key: Any]] = [
        .keyword: [
            .foregroundColor: NSColor.systemPink,
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
        ],
        .literal: [.foregroundColor: NSColor.systemPink],
        .string: [.foregroundColor: NSColor.systemRed],
        .number: [.foregroundColor: NSColor.systemBlue],
        .comment: [.foregroundColor: NSColor.secondaryLabelColor],
        .type: [.foregroundColor: NSColor.systemTeal],
        .property: [.foregroundColor: NSColor.systemPurple],
        .tag: [.foregroundColor: NSColor.systemBlue],
    ]
}

// MARK: - Text view

final class CodeTextView: EditorTextView {
    /// What Tab inserts; set per file from its existing indentation.
    var indentUnit = "    "

    override func insertTab(_ sender: Any?) {
        insertText(indentUnit, replacementRange: selectedRange())
    }

    /// Return keeps the current line's indentation.
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let selection = selectedRange()
        let lineStart = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
        var end = lineStart
        while end < selection.location, [0x20, 0x09].contains(ns.character(at: end)) { end += 1 }
        insertText("\n" + ns.substring(with: NSRange(location: lineStart, length: end - lineStart)),
                   replacementRange: selection)
    }
}
