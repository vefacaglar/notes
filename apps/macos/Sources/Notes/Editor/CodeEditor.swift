import AppKit
import NotesCore
import SwiftUI

/// Monospaced editor with syntax highlighting for code, data and plain text files.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage
    var style: EditorStyle
    var focusOnAppear = false
    var proxy: TextEditorProxy?
    var undoManager: UndoManager?
    var isEditable = true

    init(text: Binding<String>, language: CodeLanguage, style: EditorStyle = .standard, focusOnAppear: Bool = false,
         proxy: TextEditorProxy? = nil, undoManager: UndoManager? = nil, isEditable: Bool = true) {
        _text = text
        self.language = language
        self.style = style
        self.focusOnAppear = focusOnAppear
        self.proxy = proxy
        self.undoManager = undoManager
        self.isEditable = isEditable
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, language: language, undoManager: undoManager, style: style)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CodeTextView(usingTextLayoutManager: false)
        textView.configureAsPlainTextEditor()
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isEditable = isEditable

        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        proxy?.textView = textView
        proxy?.language = language
        textView.formatAction = isEditable && language.canFormat ? { [weak proxy] in proxy?.format() } : nil

        let scrollView = textView.embeddedInScrollView()
        context.coordinator.configure(textView, style: style, initial: true)
        context.coordinator.load(text, into: textView)
        if focusOnAppear { textView.requestFocus() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CodeTextView else { return }
        textView.isEditable = isEditable
        proxy?.textView = textView
        proxy?.language = language
        textView.formatAction = isEditable && language.canFormat ? { [weak proxy] in proxy?.format() } : nil
        let coordinator = context.coordinator
        coordinator.configure(textView, style: style, initial: false)
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
        private var palette: EditorPalette
        private var spans: [CodeSpan] = []

        init(text: Binding<String>, language: CodeLanguage, undoManager: UndoManager?, style: EditorStyle) {
            self.language = language
            palette = EditorPalette(style)
            super.init(text: text, undoManager: undoManager)
        }

        /// Applies a new style in place: the text, selection and undo stack stay.
        func configure(_ textView: CodeTextView, style: EditorStyle, initial: Bool) {
            guard initial || style != palette.style else { return }
            palette = EditorPalette(style)
            textView.apply(palette, spellCheck: false)
            textView.defaultParagraphStyle = palette.codeParagraph
            textView.typingAttributes = palette.codeBase
            textView.setWrapsLines(style.codeWrap)
            textView.setShowsLineNumbers(style.codeLineNumbers, palette: palette)
            if initial {
                textView.font = palette.codeFont
            } else {
                needsFullRestyle = true
                restyle(textView)
            }
        }

        override func selectionDidChange(in textView: NSTextView) {
            (textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.selectionDidChange()
        }

        override func load(_ text: String, into textView: NSTextView) {
            (textView as? CodeTextView)?.indentUnit = language.indentUnit(for: text)
            super.load(text, into: textView)
        }

        /// Tokenizes the whole text, then restyles only where the spans differ from last time.
        override func restyle(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let new = storage.length > Self.maxStyledLength
                ? [] : CodeHighlighter.spans(in: storage.string, language: language)
            var target = NSRange(location: 0, length: storage.length)
            if !needsFullRestyle, let edit = pendingEdit {
                target = CodeHighlighter.changedRange(
                    from: spans, to: new, editedRange: edit.range, changeInLength: edit.delta, length: storage.length)
            }
            spans = new
            let edit = needsFullRestyle ? nil : pendingEdit
            pendingEdit = nil
            needsFullRestyle = false

            if target.length > 0 {
                storage.beginEditing()
                storage.setAttributes(palette.codeBase, range: target)
                // Markdown spans nest, so their ends are not sorted.
                var k = language == .markdown ? 0 : Self.firstSpan(in: new, endingAfter: target.location)
                while k < new.count && new[k].range.location < NSMaxRange(target) {
                    let range = NSIntersectionRange(new[k].range, target)
                    if range.length > 0, let style = palette.syntax[new[k].kind] {
                        storage.addAttributes(style, range: range)
                    }
                    k += 1
                }
                storage.endEditing()
            }
            textView.typingAttributes = palette.codeBase
            (textView.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.textDidChange(edit: edit)
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

// MARK: - Text view

final class CodeTextView: EditorTextView {
    /// What Tab inserts; set per file from its existing indentation.
    var indentUnit = "    "
    /// Set when the file can be formatted: adds "Format" to the right-click menu, like the Format command.
    var formatAction: (() -> Void)?

    /// The text view's own menu (cut, copy, paste, spelling…) with "Format" appended.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let menu, formatAction != nil else { return menu }
        let item = NSMenuItem(title: L("Format"), action: #selector(formatFromMenu), keyEquivalent: "")
        item.target = self
        menu.addItem(.separator())
        menu.addItem(item)
        return menu
    }

    @objc private func formatFromMenu() { formatAction?() }

    /// Off: lines run as long as they are and the view scrolls horizontally.
    func setWrapsLines(_ wraps: Bool) {
        guard let container = textContainer else { return }
        let scrollView = enclosingScrollView
        let huge = CGFloat.greatestFiniteMagnitude
        if wraps {
            guard !container.widthTracksTextView else { return }
            isHorizontallyResizable = false
            minSize = .zero
            autoresizingMask = [.width]
            let width = scrollView?.contentSize.width ?? frame.width
            setFrameSize(NSSize(width: width, height: frame.height))
            container.containerSize = NSSize(width: max(width - 2 * textContainerInset.width, 0), height: huge)
            container.widthTracksTextView = true
            scrollView?.hasHorizontalScroller = false
        } else {
            guard container.widthTracksTextView else { return }
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: huge, height: huge)
            isHorizontallyResizable = true
            autoresizingMask = [.width, .height]
            minSize = NSSize(width: scrollView?.contentSize.width ?? 0, height: 0)
            scrollView?.hasHorizontalScroller = true
            scrollView?.autohidesScrollers = true
        }
        if let layoutManager, let container = textContainer {
            layoutManager.textContainerChangedGeometry(container)
        }
        sizeToFit()
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    func setShowsLineNumbers(_ shows: Bool, palette: EditorPalette) {
        guard let scrollView = enclosingScrollView else { return }
        if shows {
            let ruler = scrollView.verticalRulerView as? LineNumberRulerView ?? LineNumberRulerView(textView: self)
            ruler.apply(palette)
            if scrollView.verticalRulerView !== ruler { scrollView.verticalRulerView = ruler }
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
        } else {
            scrollView.rulersVisible = false
            scrollView.hasVerticalRuler = false
        }
    }

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

// MARK: - Line numbers

/// Line numbers beside a code editor: one per logical line (wrapped continuations get none), drawn at the
/// baseline of the line's first fragment, so they follow the font, line spacing and wrapping.
final class LineNumberRulerView: NSRulerView {
    private var numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var numberColor = NSColor.secondaryLabelColor
    /// The caret line's number, undimmed; nil when the current-line highlight is off.
    private var currentNumberColor: NSColor?
    private var background = NSColor.textBackgroundColor
    /// UTF-16 offsets where each line starts (after each LF); patched from each edit, rebuilt lazily when that is not possible.
    private var lineStarts: [Int] = [0]
    private var lineStartsValid = false
    /// Length of the text `lineStarts` describes.
    private var indexedLength = 0
    private var digits = 0
    private static let padding: CGFloat = 8

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        clipsToBounds = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentMoved), name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentMoved), name: NSView.frameDidChangeNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(_ palette: EditorPalette) {
        numberFont = .monospacedDigitSystemFont(ofSize: max(palette.codeFont.pointSize * 0.85, 8), weight: .regular)
        numberColor = palette.colors.secondaryText.nsColor.withAlphaComponent(0.5)
        currentNumberColor = palette.style.highlightCurrentLine ? palette.colors.secondaryText.nsColor : nil
        background = palette.colors.background.nsColor
        updateThickness(force: true)
        needsDisplay = true
    }

    /// `edit` is the single edit since the last call, in post-edit coordinates; nil when unknown.
    func textDidChange(edit: (range: NSRange, delta: Int)?) {
        if let edit, lineStartsValid, let string = textView?.string as NSString?,
           LineIndex.update(&lineStarts, edit: edit, oldLength: indexedLength, in: string) {
            indexedLength = string.length
        } else {
            lineStartsValid = false
        }
        updateThickness()
        needsDisplay = true
    }

    @objc private func contentMoved() { needsDisplay = true }

    /// The caret moved: the emphasised number may change.
    func selectionDidChange() {
        if currentNumberColor != nil { needsDisplay = true }
    }

    /// Index of the line holding the caret, nil unless the selection is empty and the highlight is on.
    private func caretLineIndex() -> Int? {
        guard currentNumberColor != nil, let selection = textView?.selectedRange(), selection.length == 0 else { return nil }
        var lo = 0, hi = lineStarts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= selection.location { lo = mid + 1 } else { hi = mid }
        }
        return max(lo - 1, 0)
    }

    private var textView: NSTextView? { clientView as? NSTextView }

    private func ensureLineStarts() {
        guard !lineStartsValid, let string = textView?.string as NSString? else { return }
        lineStarts = LineIndex.build(string)
        indexedLength = string.length
        lineStartsValid = true
    }

    /// Recomputes the ruler width; only when the number of digits changed, unless `force` (new font).
    private func updateThickness(force: Bool = false) {
        ensureLineStarts()
        let newDigits = max(3, String(lineStarts.count).count)
        guard force || newDigits != digits else { return }
        digits = newDigits
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: numberFont]).width
        let thickness = (CGFloat(newDigits) * digitWidth + 2 * Self.padding).rounded(.up)
        if ruleThickness != thickness { ruleThickness = thickness }
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.intersection(dirtyRect).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        ensureLineStarts()
        let length = (textView.string as NSString).length
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: numberColor]
        let currentAttributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: currentNumberColor ?? numberColor]
        let caretLine = caretLineIndex()
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect

        func draw(_ number: Int, fragment: NSRect, baseline: CGFloat) {
            let y = convert(NSPoint(x: 0, y: fragment.minY + origin.y + baseline), from: textView).y
            let label = String(number) as NSString
            let attributes = number - 1 == caretLine ? currentAttributes : attributes
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - Self.padding - size.width, y: y - numberFont.ascender), withAttributes: attributes)
        }

        let glyphs = layoutManager.glyphRange(forBoundingRect: visible.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let firstChar = layoutManager.characterIndexForGlyph(at: glyphs.location)
        let lastChar = glyphs.length > 0 ? layoutManager.characterIndexForGlyph(at: NSMaxRange(glyphs) - 1) : firstChar
        // Index of the last line starting at or before `firstChar`.
        var lo = 0, hi = lineStarts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= firstChar { lo = mid + 1 } else { hi = mid }
        }
        var line = max(lo - 1, 0)
        var baseline: CGFloat?
        while line < lineStarts.count, lineStarts[line] <= lastChar, lineStarts[line] < length {
            let glyph = layoutManager.glyphIndexForCharacter(at: lineStarts[line])
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            let offset = layoutManager.location(forGlyphAt: glyph).y
            draw(line + 1, fragment: fragment, baseline: offset)
            baseline = offset
            line += 1
        }
        // The empty last line after a final line break (or of an empty file): same baseline offset as the others.
        if lineStarts.last == length {
            let extra = layoutManager.extraLineFragmentRect
            if !extra.isEmpty {
                let font = (textView.typingAttributes[.font] as? NSFont) ?? numberFont
                draw(lineStarts.count, fragment: extra, baseline: baseline ?? min(extra.height, font.ascender + (extra.height - font.ascender + font.descender) / 2))
            }
        }
    }
}

/// Line start offsets of a text (UTF-16, after each LF), patched per edit instead of rescanned.
enum LineIndex {
    static func build(_ string: NSString) -> [Int] {
        var starts = [0]
        let length = string.length
        var buffer = [unichar](repeating: 0, count: 4096)
        var location = 0
        while location < length {
            let count = min(buffer.count, length - location)
            string.getCharacters(&buffer, range: NSRange(location: location, length: count))
            for k in 0..<count where buffer[k] == 0x0A { starts.append(location + k + 1) }
            location += count
        }
        return starts
    }

    /// Patches `starts` for an edit (`range` is the new text, `delta` the change in length). False, leaving
    /// `starts` alone, when the edit does not fit the indexed text.
    static func update(_ starts: inout [Int], edit: (range: NSRange, delta: Int), oldLength: Int, in string: NSString) -> Bool {
        let range = edit.range
        let oldEnd = NSMaxRange(range) - edit.delta
        guard oldLength + edit.delta == string.length, range.location >= 0, oldEnd >= range.location,
              oldEnd <= oldLength, NSMaxRange(range) <= string.length else { return false }
        // Starts at offsets in (location, oldEnd] belonged to line breaks that were replaced.
        let first = firstIndex(in: starts, after: range.location)
        let last = firstIndex(in: starts, after: oldEnd)
        var inserted: [Int] = []
        for i in range.location..<NSMaxRange(range) where string.character(at: i) == 0x0A { inserted.append(i + 1) }
        if edit.delta != 0 { for i in last..<starts.count { starts[i] += edit.delta } }
        starts.replaceSubrange(first..<last, with: inserted)
        return true
    }

    /// Index of the first start greater than `offset`.
    private static func firstIndex(in starts: [Int], after offset: Int) -> Int {
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
