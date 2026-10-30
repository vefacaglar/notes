import AppKit
import NotesCore
import SwiftUI

/// Plain-text Markdown editor with live syntax styling. With `showsSource` the same text (and undo stack) is shown
/// unstyled in the code font.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var style: EditorStyle
    var showsSource: Bool
    var focusOnAppear = false
    var proxy: TextEditorProxy?
    var undoManager: UndoManager?
    var isEditable = true

    init(text: Binding<String>, style: EditorStyle = .standard, showsSource: Bool = false, focusOnAppear: Bool = false,
         proxy: TextEditorProxy? = nil, undoManager: UndoManager? = nil, isEditable: Bool = true) {
        _text = text
        self.style = style
        self.showsSource = showsSource
        self.focusOnAppear = focusOnAppear
        self.proxy = proxy
        self.undoManager = undoManager
        self.isEditable = isEditable
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, undoManager: undoManager, style: style, showsSource: showsSource)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView(usingTextLayoutManager: false)
        textView.configureAsPlainTextEditor()
        textView.isEditable = isEditable

        let coordinator = context.coordinator
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        textView.onMouseUp = { [weak coordinator, weak textView] in
            if let coordinator, let textView { coordinator.selectionSettled(in: textView) }
        }
        proxy?.textView = textView
        proxy?.language = .markdown

        let scrollView = textView.embeddedInScrollView()
        coordinator.configure(textView, style: style, showsSource: showsSource, initial: true)
        coordinator.load(text, into: textView)
        if focusOnAppear { textView.requestFocus() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        textView.isEditable = isEditable
        proxy?.textView = textView
        proxy?.language = .markdown
        context.coordinator.configure(textView, style: style, showsSource: showsSource, initial: false)
        context.coordinator.update($text, in: textView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let textView = scrollView.documentView as? NSTextView { coordinator.dismantle(textView) }
    }

    final class Coordinator: TextEditorCoordinator {
        private var palette: EditorPalette
        private var showsSource: Bool
        private var codeBlocks: [NSRange] = []
        private var spans: [MarkdownSpan] = []
        /// The lines (through their line break) whose markers stay visible while markers are hidden elsewhere:
        /// the lines with the cursor or selection. nil when markers are not hidden.
        private var revealed: NSRange?

        init(text: Binding<String>, undoManager: UndoManager?, style: EditorStyle, showsSource: Bool) {
            palette = EditorPalette(style)
            self.showsSource = showsSource
            super.init(text: text, undoManager: undoManager)
        }

        private var hidesMarkers: Bool { palette.style.markerStyle == .hidden && !showsSource }
        private var base: [NSAttributedString.Key: Any] { showsSource ? palette.codeBase : palette.markdownBase }

        /// Applies a new style or source mode by restyling in place: the text, selection and undo stack stay.
        func configure(_ textView: MarkdownTextView, style: EditorStyle, showsSource: Bool, initial: Bool) {
            guard initial || style != palette.style || showsSource != self.showsSource else { return }
            if style != palette.style { palette = EditorPalette(style) }
            self.showsSource = showsSource
            textView.apply(palette, spellCheck: style.spellCheck)
            textView.limitsLineWidth = style.limitLineWidth
            textView.linkTextAttributes = [.foregroundColor: palette.colors.link.nsColor, .cursor: NSCursor.pointingHand]
            textView.defaultParagraphStyle = base[.paragraphStyle] as? NSParagraphStyle
            textView.typingAttributes = base
            if initial {
                textView.font = base[.font] as? NSFont
            } else {
                needsFullRestyle = true
                restyle(textView)
            }
        }

        // MARK: Styling

        override func restyle(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            guard !showsSource, storage.length <= Self.maxStyledLength else {
                // Source mode, or too long to scan on every keystroke: plain text, styled once.
                if needsFullRestyle { storage.setAttributes(base, range: full) }
                codeBlocks = []
                spans = []
                revealed = nil
                pendingEdit = nil
                needsFullRestyle = false
                textView.typingAttributes = base
                return
            }
            let spans = MarkdownStyler.spans(in: storage.string)
            let blocks = spans.filter { $0.kind == .codeBlock }.map(\.range)
            let reveal = hidesMarkers ? revealRange(in: textView) : nil

            var targets = [full]
            // Only fenced code spans lines, so unless the fences moved, restyling the edited lines is enough
            // (plus the lines whose markers were or are now revealed).
            if !needsFullRestyle, let edit = pendingEdit, Self.shift(codeBlocks, by: edit) == blocks {
                targets = [MarkdownStyler.restyleRange(afterEditing: edit.range, in: storage.string)]
                if let old = revealed { targets.append(Self.shift(old, by: edit, length: storage.length, in: storage.string)) }
                if let reveal { targets.append(reveal) }
            }
            codeBlocks = blocks
            self.spans = spans
            pendingEdit = nil
            needsFullRestyle = false
            revealed = reveal

            storage.beginEditing()
            for target in Self.merged(targets) { apply(spans, in: target, to: storage) }
            storage.endEditing()
            textView.typingAttributes = base
        }

        override func selectionDidChange(in textView: NSTextView) {
            // While the mouse is down the reveal waits for mouse-up, so the text doesn't shift under the pointer.
            if (textView as? MarkdownTextView)?.isTrackingMouse == true { return }
            selectionSettled(in: textView)
        }

        /// Re-hides the markers of the lines the cursor left and reveals those of the lines it is on now.
        func selectionSettled(in textView: NSTextView) {
            // During an edit the restyle that follows it takes care of this.
            guard hidesMarkers, pendingEdit == nil, !needsFullRestyle, !textView.hasMarkedText(),
                  let storage = textView.textStorage, storage.length <= Self.maxStyledLength else { return }
            let reveal = revealRange(in: textView)
            guard reveal != revealed else { return }
            var targets = [reveal]
            if let old = revealed, NSMaxRange(old) <= storage.length { targets.append(old) }
            revealed = reveal
            storage.beginEditing()
            for target in Self.merged(targets) { apply(spans, in: target, to: storage) }
            storage.endEditing()
        }

        /// Whole lines covered by the selection, through the line break.
        private func revealRange(in textView: NSTextView) -> NSRange {
            let ranges = textView.selectedRanges.map(\.rangeValue)
            let start = ranges.map(\.location).min() ?? 0
            let end = ranges.map(NSMaxRange).max() ?? start
            return MarkdownStyler.restyleRange(afterEditing: NSRange(location: start, length: end - start), in: textView.string)
        }

        private func apply(_ spans: [MarkdownSpan], in target: NSRange, to storage: NSTextStorage) {
            storage.setAttributes(base, range: target)
            let string = storage.string as NSString
            var block: NSRange?
            for span in spans {
                if span.range.location >= NSMaxRange(target) { break }
                if span.kind == .codeBlock { block = span.range }
                let range = NSIntersectionRange(span.range, target)
                guard range.length > 0 else { continue }
                if span.kind == .marker {
                    let isFence = block.map { NSLocationInRange(span.range.location, $0) } ?? false
                    if hidesMarkers, !isFence, !Self.isQuoteMarker(span.range, in: string),
                       NSIntersectionRange(span.range, revealed ?? NSRange()).length == 0 {
                        storage.addAttributes(palette.hiddenMarker, range: range)
                        continue
                    }
                }
                style(span.kind, in: range, of: storage)
                if span.kind == .codeBlock { highlightCode(in: span.range, within: target, of: storage, string: string) }
            }
        }

        private func style(_ kind: MarkdownSpan.Kind, in range: NSRange, of storage: NSTextStorage) {
            let colors = palette.colors
            switch kind {
            case .marker, .horizontalRule:
                storage.addAttribute(.foregroundColor, value: colors.marker.nsColor, range: range)
            case .heading(let level):
                let size = (palette.textFont.pointSize * Self.headingScale[min(max(level, 1), 6) - 1]).rounded()
                storage.addAttributes([.font: palette.headingFont(size: size), .foregroundColor: colors.heading.nsColor], range: range)
            case .bold:
                addTraits(.boldFontMask, to: storage, in: range)
            case .italic:
                addTraits(.italicFontMask, to: storage, in: range)
            case .boldItalic:
                addTraits([.boldFontMask, .italicFontMask], to: storage, in: range)
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .inlineCode, .codeBlock:
                storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                    let size = (value as? NSFont)?.pointSize ?? palette.textFont.pointSize
                    storage.addAttribute(.font, value: palette.codeFont(relativeTo: size), range: sub)
                }
                if kind == .inlineCode {
                    storage.addAttributes([
                        .foregroundColor: colors.inlineCode.nsColor,
                        .backgroundColor: colors.inlineCodeBackground.nsColor,
                    ], range: range)
                } else {
                    storage.addAttribute(.backgroundColor, value: colors.codeBlockBackground.nsColor, range: range)
                }
            case .blockquote:
                storage.addAttribute(.foregroundColor, value: colors.blockquote.nsColor, range: range)
            case .listMarker:
                storage.addAttribute(.foregroundColor, value: colors.secondaryText.nsColor, range: range)
            case .taskMarker(let checked):
                storage.addAttribute(.foregroundColor, value: (checked ? colors.marker : colors.secondaryText).nsColor, range: range)
            case .task(let checked):
                guard checked else { return }
                storage.addAttributes([
                    .foregroundColor: colors.secondaryText.nsColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                ], range: range)
            case .link(let url):
                storage.addAttribute(.foregroundColor, value: colors.link.nsColor, range: range)
                if let url = Self.linkURL(url) { storage.addAttribute(.link, value: url, range: range) }
            }
        }

        private func addTraits(_ traits: NSFontTraitMask, to storage: NSTextStorage, in range: NSRange) {
            storage.enumerateAttribute(.font, in: range) { value, sub, _ in
                let font = value as? NSFont ?? palette.textFont
                storage.addAttribute(.font, value: EditorPalette.withTraits(traits, font), range: sub)
            }
        }

        /// Syntax colors for a fenced block whose info string names a known language (```swift, ```json…).
        private func highlightCode(in block: NSRange, within target: NSRange, of storage: NSTextStorage, string: NSString) {
            let newline = string.range(of: "\n", options: .literal, range: block)
            guard newline.location != NSNotFound else { return }
            let inner = NSRange(location: NSMaxRange(newline), length: NSMaxRange(block) - NSMaxRange(newline))
            guard inner.length > 0, NSIntersectionRange(inner, target).length > 0 else { return }
            let info = string.substring(with: NSRange(location: block.location, length: newline.location - block.location))
                .trimmingCharacters(in: CharacterSet(charactersIn: "`~").union(.whitespacesAndNewlines))
                .split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first.map(String.init) ?? ""
            let language = Self.language(forInfo: info)
            guard language != .plainText, language != .markdown else { return }
            for span in CodeHighlighter.spans(in: string.substring(with: inner), language: language) {
                let range = NSIntersectionRange(NSRange(location: span.range.location + inner.location, length: span.range.length), target)
                guard range.length > 0, let color = palette.syntax[span.kind]?[.foregroundColor] else { continue }
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
        }

        private static let infoAliases: [String: String] = [
            "javascript": "js", "typescript": "ts", "python": "py", "shell": "sh", "console": "sh", "objc": "m",
            "objective-c": "m", "c++": "cpp", "csharp": "cs", "c#": "cs", "rust": "rs", "golang": "go", "kotlin": "kt",
            "jsonc": "json", "json5": "json",
        ]

        private static func language(forInfo info: String) -> CodeLanguage {
            let key = info.lowercased()
            return CodeLanguage(fileExtension: infoAliases[key] ?? key)
        }

        private static let headingScale: [CGFloat] = [1.6, 1.4, 1.25, 1.12, 1.0, 0.93]

        /// `>` of a blockquote (only spaces and other `>` before it on its line); kept visible so quotes stay recognizable.
        private static func isQuoteMarker(_ range: NSRange, in string: NSString) -> Bool {
            guard range.location < string.length, string.character(at: range.location) == 0x3E else { return false }
            var i = range.location
            while i > 0 {
                let c = string.character(at: i - 1)
                if c == 0x0A { return true }
                guard c == 0x20 || c == 0x09 || c == 0x3E else { return false }
                i -= 1
            }
            return true
        }

        /// Only absolute URLs are clickable; relative paths have nothing sensible to open.
        private static func linkURL(_ string: String) -> URL? {
            let url = URL(string: string)
                ?? string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
            guard let url, url.scheme != nil else { return nil }
            return url
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

        /// A range from before an edit, moved to post-edit coordinates and widened to whole lines.
        private static func shift(_ range: NSRange, by edit: (range: NSRange, delta: Int), length: Int, in text: String) -> NSRange {
            var r = shift([range], by: edit)[0]
            r.location = min(max(r.location, 0), length)
            r.length = min(max(r.length, 0), length - r.location)
            return MarkdownStyler.restyleRange(afterEditing: r, in: text)
        }

        /// Sorted, with overlapping or touching ranges joined.
        private static func merged(_ ranges: [NSRange]) -> [NSRange] {
            var result: [NSRange] = []
            for r in ranges.sorted(by: { $0.location < $1.location }) {
                if let last = result.last, r.location <= NSMaxRange(last) {
                    result[result.count - 1] = NSUnionRange(last, r)
                } else {
                    result.append(r)
                }
            }
            return result
        }
    }
}

// MARK: - Text view

final class MarkdownTextView: EditorTextView {
    private static let maxLineWidth: CGFloat = 720
    private static let minInset = NSSize(width: 28, height: 24)

    /// Centers a column of at most 720pt; off, the text uses the full width.
    var limitsLineWidth = true {
        didSet { if limitsLineWidth != oldValue { updateInsets(for: frame.size) } }
    }
    /// True while a click or drag selection is being tracked.
    private(set) var isTrackingMouse = false
    var onMouseUp: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        updateInsets(for: newSize)
        super.setFrameSize(newSize)
    }

    private func updateInsets(for size: NSSize) {
        let centered = ((size.width - Self.maxLineWidth) / 2).rounded()
        let horizontal = limitsLineWidth ? max(Self.minInset.width, centered) : Self.minInset.width
        if textContainerInset.width != horizontal {
            textContainerInset = NSSize(width: horizontal, height: Self.minInset.height)
        }
    }

    override func mouseDown(with event: NSEvent) {
        isTrackingMouse = true
        super.mouseDown(with: event)
        isTrackingMouse = false
        onMouseUp?()
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
