import AppKit
import NotesCore
import SwiftUI

/// Plain-text Markdown editor with live syntax styling.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var focusOnAppear = false
    var proxy: TextEditorProxy?
    var undoManager: UndoManager?

    init(text: Binding<String>, focusOnAppear: Bool = false, proxy: TextEditorProxy? = nil, undoManager: UndoManager? = nil) {
        _text = text
        self.focusOnAppear = focusOnAppear
        self.proxy = proxy
        self.undoManager = undoManager
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, undoManager: undoManager)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView(usingTextLayoutManager: false)
        textView.configureAsPlainTextEditor()
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        textView.font = MarkdownTheme.baseFont
        textView.defaultParagraphStyle = MarkdownTheme.paragraphStyle
        textView.typingAttributes = MarkdownTheme.base

        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        proxy?.textView = textView
        proxy?.language = .markdown

        let scrollView = textView.embeddedInScrollView()
        context.coordinator.load(text, into: textView)
        if focusOnAppear { textView.requestFocus() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        proxy?.textView = textView
        proxy?.language = .markdown
        context.coordinator.update($text, in: textView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let textView = scrollView.documentView as? NSTextView { coordinator.dismantle(textView) }
    }

    final class Coordinator: TextEditorCoordinator {
        private var codeBlocks: [NSRange] = []

        // MARK: Styling

        override func restyle(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let spans = MarkdownStyler.spans(in: storage.string)
            let blocks = spans.filter { $0.kind == .codeBlock }.map(\.range)

            var target = NSRange(location: 0, length: storage.length)
            // Only fenced code spans lines, so unless the fences moved, restyling the edited lines is enough.
            if !needsFullRestyle, let edit = pendingEdit, Self.shift(codeBlocks, by: edit) == blocks {
                target = MarkdownStyler.restyleRange(afterEditing: edit.range, in: storage.string)
            }
            codeBlocks = blocks
            pendingEdit = nil
            needsFullRestyle = false

            storage.beginEditing()
            storage.setAttributes(MarkdownTheme.base, range: target)
            for span in spans {
                if span.range.location >= NSMaxRange(target) { break }
                let range = NSIntersectionRange(span.range, target)
                guard range.length > 0 else { continue }
                MarkdownTheme.apply(span.kind, to: storage, in: range)
            }
            storage.endEditing()
            textView.typingAttributes = MarkdownTheme.base
        }

        /// Maps code block ranges from before an edit to where they would be after it, if the edit left fences alone.
        private static func shift(_ ranges: [NSRange], by edit: (range: NSRange, delta: Int)) -> [NSRange] {
            let oldStart = edit.range.location
            let oldEnd = NSMaxRange(edit.range) - edit.delta
            return ranges.map { r in
                if r.location >= oldEnd && r.location > oldStart { return NSRange(location: r.location + edit.delta, length: r.length) }
                if NSMaxRange(r) >= oldStart { return NSRange(location: r.location, length: r.length + edit.delta) }
                return r
            }
        }
    }
}

// MARK: - Theme

@MainActor
enum MarkdownTheme {
    static let fontSize: CGFloat = 15
    static let baseFont = NSFont.systemFont(ofSize: fontSize)

    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.2
        style.paragraphSpacing = 4
        return style
    }()

    static let base: [NSAttributedString.Key: Any] = [
        .font: baseFont,
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraphStyle,
    ]

    private static let headingScale: [CGFloat] = [1.6, 1.4, 1.25, 1.12, 1.0, 0.93]
    private static let codeBackground = NSColor.quaternarySystemFill

    static func apply(_ kind: MarkdownSpan.Kind, to storage: NSTextStorage, in range: NSRange) {
        switch kind {
        case .marker, .horizontalRule:
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        case .heading(let level):
            let size = (fontSize * headingScale[min(max(level, 1), 6) - 1]).rounded()
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: range)
        case .bold:
            addTraits(.bold, to: storage, in: range)
        case .italic:
            addTraits(.italic, to: storage, in: range)
        case .boldItalic:
            addTraits([.bold, .italic], to: storage, in: range)
        case .strikethrough:
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        case .inlineCode, .codeBlock:
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                let size = (value as? NSFont)?.pointSize ?? fontSize
                storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size * 0.9, weight: .regular), range: sub)
            }
            storage.addAttribute(.backgroundColor, value: codeBackground, range: range)
        case .blockquote, .listMarker:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
        case .taskMarker(let checked):
            storage.addAttribute(.foregroundColor, value: checked ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor, range: range)
        case .task(let checked):
            guard checked else { return }
            storage.addAttributes([
                .foregroundColor: NSColor.tertiaryLabelColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ], range: range)
        case .link(let url):
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
            if let url = linkURL(url) { storage.addAttribute(.link, value: url, range: range) }
        }
    }

    private static func addTraits(_ traits: NSFontDescriptor.SymbolicTraits, to storage: NSTextStorage, in range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let font = value as? NSFont ?? baseFont
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
            storage.addAttribute(.font, value: NSFont(descriptor: descriptor, size: font.pointSize) ?? font, range: sub)
        }
    }

    /// Only absolute URLs are clickable; relative paths have nothing sensible to open.
    private static func linkURL(_ string: String) -> URL? {
        let url = URL(string: string)
            ?? string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
        guard let url, url.scheme != nil else { return nil }
        return url
    }
}

// MARK: - Text view

final class MarkdownTextView: EditorTextView {
    private static let maxLineWidth: CGFloat = 720
    private static let minInset = NSSize(width: 28, height: 24)

    override func setFrameSize(_ newSize: NSSize) {
        let horizontal = max(Self.minInset.width, ((newSize.width - Self.maxLineWidth) / 2).rounded())
        if textContainerInset.width != horizontal {
            textContainerInset = NSSize(width: horizontal, height: Self.minInset.height)
        }
        super.setFrameSize(newSize)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "b": toggleWrap("**"); return true
        case "i": toggleWrap("*"); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    /// Wraps the selection in `marker`, or unwraps it when it is already wrapped.
    private func toggleWrap(_ marker: String) {
        let ns = string as NSString
        let selection = selectedRange()
        let m = (marker as NSString).length
        let outer = NSRange(location: selection.location - m, length: selection.length + 2 * m)
        if outer.location >= 0, NSMaxRange(outer) <= ns.length,
           ns.substring(with: NSRange(location: outer.location, length: m)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(selection), length: m)) == marker {
            replace(outer, with: ns.substring(with: selection), select: NSRange(location: outer.location, length: selection.length))
        } else {
            let inner = ns.substring(with: selection)
            replace(selection, with: marker + inner + marker, select: NSRange(location: selection.location + m, length: selection.length))
        }
    }

    private func replace(_ range: NSRange, with text: String, select: NSRange) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(select)
    }
}
