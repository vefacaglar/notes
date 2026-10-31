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
    /// Called with the destination (as written) of a link that was clicked; see `NoteLinks.classify`.
    var onOpenLink: ((String) -> Void)?

    init(text: Binding<String>, style: EditorStyle = .standard, showsSource: Bool = false, focusOnAppear: Bool = false,
         proxy: TextEditorProxy? = nil, undoManager: UndoManager? = nil, isEditable: Bool = true,
         onOpenLink: ((String) -> Void)? = nil) {
        _text = text
        self.style = style
        self.showsSource = showsSource
        self.focusOnAppear = focusOnAppear
        self.proxy = proxy
        self.undoManager = undoManager
        self.isEditable = isEditable
        self.onOpenLink = onOpenLink
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, undoManager: undoManager, style: style, showsSource: showsSource)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView(usingTextLayoutManager: false)
        textView.configureAsPlainTextEditor()
        textView.isEditable = isEditable
        textView.onOpenLink = onOpenLink

        let coordinator = context.coordinator
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        textView.onMouseUp = { [weak coordinator, weak textView] in
            if let coordinator, let textView { coordinator.selectionSettled(in: textView) }
        }
        proxy?.textView = textView
        proxy?.language = .markdown

        let scrollView = textView.embeddedInScrollView()
        coordinator.observeScrolling(of: scrollView, textView: textView)
        coordinator.configure(textView, style: style, showsSource: showsSource, initial: true)
        coordinator.load(text, into: textView)
        if focusOnAppear { textView.requestFocus() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        textView.isEditable = isEditable
        textView.onOpenLink = onOpenLink
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
        /// Running maximum of the spans' ends, so the first span that can reach a location is found by bisection
        /// (spans are sorted by start, except a heading's closing `###`, which comes before the inline spans).
        private var spanReach: [Int] = []
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
                // An undo can bring back attributes of the styled text: reset what it touched.
                else if let edit = pendingEdit {
                    storage.setAttributes(base, range: MarkdownStyler.restyleRange(afterEditing: edit.range, in: storage.string))
                }
                codeBlocks = []
                spans = []
                spanReach = []
                revealed = nil
                pendingEdit = nil
                needsFullRestyle = false
                textView.typingAttributes = base
                return
            }
            let spans = MarkdownStyler.spans(in: storage.string)
            let blocks = spans.filter { $0.kind == .codeBlock }.map(\.range)
            let reveal = hidesMarkers ? revealRange(in: textView, string: storage.mutableString) : nil

            var targets = [full]
            // Only fenced code spans lines, so unless the fences moved, restyling the edited lines is enough
            // (plus the lines whose markers were or are now revealed).
            if !needsFullRestyle, let edit = pendingEdit, Self.shift(codeBlocks, by: edit) == blocks {
                var target = MarkdownStyler.restyleRange(afterEditing: edit.range, in: storage.string)
                // A fence or a comment/string opener can change the colours of the whole block.
                for block in blocks where block.location < NSMaxRange(target) && NSMaxRange(block) > target.location {
                    target = NSUnionRange(target, block)
                }
                targets = [target]
                if let old = revealed { targets.append(Self.shift(old, by: edit, length: storage.length, in: storage.string)) }
                if let reveal { targets.append(reveal) }
            }
            codeBlocks = blocks
            self.spans = spans
            spanReach = Self.reach(of: spans)
            pendingEdit = nil
            needsFullRestyle = false
            revealed = reveal

            storage.beginEditing()
            for target in Self.merged(targets) { apply(in: target, to: storage) }
            storage.endEditing()
            textView.typingAttributes = base
        }

        override func selectionDidChange(in textView: NSTextView) {
            // While the mouse is down the reveal waits for mouse-up, so the text doesn't shift under the pointer.
            if (textView as? MarkdownTextView)?.isTrackingMouse == true { return }
            selectionSettled(in: textView)
        }

        /// Re-hides the markers of the lines the cursor left and reveals those of the lines it is on now. Only the
        /// lines that entered or left the revealed range and hold a hideable marker are touched.
        func selectionSettled(in textView: NSTextView) {
            // During an edit the restyle that follows it takes care of this.
            guard hidesMarkers, pendingEdit == nil, !needsFullRestyle, !textView.hasMarkedText(),
                  let storage = textView.textStorage, storage.length <= Self.maxStyledLength else { return }
            let string = storage.mutableString
            let reveal = revealRange(in: textView, string: string)
            guard reveal != revealed else { return }
            var changed = [reveal]
            if let old = revealed, NSMaxRange(old) <= storage.length {
                changed = RangeMath.symmetricDifference(reveal, old)
            }
            revealed = reveal
            // Code blocks never hide markers (fences stay visible), and restyling them would redo their highlighting.
            let lines = Self.merged(markerLines(in: RangeMath.subtract(changed, removing: codeBlocks), string: string))
            guard !lines.isEmpty else { return }
            storage.beginEditing()
            for line in Self.coalesced(lines) { apply(in: line, to: storage) }
            storage.endEditing()
        }

        /// A selection longer than this reveals only the lines around the viewport (see `revealRange`).
        private static let largeSelection = 20_000
        private var scrollObserver: NSObjectProtocol?

        /// Large selections reveal markers only near the viewport, so select-all in a huge note stays instant;
        /// scrolling reveals the lines that come into view.
        func observeScrolling(of scrollView: NSScrollView, textView: MarkdownTextView) {
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) {
                [weak self, weak textView] _ in
                MainActor.assumeIsolated {
                    guard let self, let textView, textView.selectedRange().length > Self.largeSelection else { return }
                    self.selectionDidChange(in: textView)
                }
            }
        }

        override func dismantle(_ textView: NSTextView) {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            scrollObserver = nil
            super.dismantle(textView)
        }

        private func revealRange(in textView: NSTextView, string: NSString) -> NSRange {
            let reveal = Self.revealRange(of: textView.selectedRanges, in: string)
            guard reveal.length > Self.largeSelection, let layout = textView.layoutManager, let container = textView.textContainer else { return reveal }
            var rect = textView.visibleRect
            rect = rect.insetBy(dx: 0, dy: -rect.height)
            let glyphs = layout.glyphRange(forBoundingRect: rect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y), in: container)
            let visible = RangeMath.lineRange(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), in: string)
            return NSIntersectionRange(reveal, visible)
        }

        /// Whole lines covered by the selection, through the line break.
        static func revealRange(of selections: [NSValue], in string: NSString) -> NSRange {
            let ranges = selections.map(\.rangeValue)
            let start = ranges.map(\.location).min() ?? 0
            let end = ranges.map(NSMaxRange).max() ?? start
            return RangeMath.lineRange(NSRange(location: start, length: end - start), in: string)
        }

        /// The lines inside `ranges` (line-aligned) that contain a marker which is hidden while not revealed.
        private func markerLines(in ranges: [NSRange], string: NSString) -> [NSRange] {
            var lines: [NSRange] = []
            var coveredEnd = 0
            for range in ranges {
                var k = RangeMath.firstIndex(in: spanReach, endingAfter: range.location)
                while k < spans.count, spans[k].range.location < NSMaxRange(range) {
                    let span = spans[k]
                    k += 1
                    guard span.kind == .marker, span.range.location >= coveredEnd, NSIntersectionRange(span.range, range).length > 0,
                          !Self.isQuoteMarker(span.range, in: string) else { continue }
                    let line = RangeMath.lineRange(span.range, in: string)
                    lines.append(line)
                    coveredEnd = NSMaxRange(line)
                }
            }
            return lines
        }

        private static func reach(of spans: [MarkdownSpan]) -> [Int] {
            var result = [Int](), peak = 0
            result.reserveCapacity(spans.count)
            for span in spans {
                peak = max(peak, NSMaxRange(span.range))
                result.append(peak)
            }
            return result
        }

        private func apply(in target: NSRange, to storage: NSTextStorage) {
            storage.setAttributes(base, range: target)
            let string = storage.mutableString
            var block: NSRange?
            var k = RangeMath.firstIndex(in: spanReach, endingAfter: target.location)
            while k < spans.count {
                let span = spans[k]
                k += 1
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
                storage.addAttributes(palette.headingAttributes(size: size).merging([.foregroundColor: colors.heading.nsColor]) { $1 }, range: range)
            case .bold:
                addTraits(.boldFontMask, to: storage, in: range)
            case .italic:
                addTraits(.italicFontMask, to: storage, in: range)
            case .boldItalic:
                addTraits([.boldFontMask, .italicFontMask], to: storage, in: range)
            case .strikethrough:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            case .inlineCode, .codeBlock:
                storage.enumerateAttribute(.font, in: range, options: .longestEffectiveRangeNotRequired) { value, sub, _ in
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
                if let value = Self.linkValue(url) { storage.addAttribute(.link, value: value, range: range) }
            case .wikiLink(let target):
                storage.addAttributes([.foregroundColor: colors.link.nsColor, .link: "[[\(target)]]"], range: range)
            }
        }

        private func addTraits(_ traits: NSFontTraitMask, to storage: NSTextStorage, in range: NSRange) {
            storage.enumerateAttribute(.font, in: range, options: .longestEffectiveRangeNotRequired) { value, sub, _ in
                let font = value as? NSFont ?? palette.textFont
                let styled = EditorPalette.withTraits(traits, font)
                storage.addAttribute(.font, value: styled, range: sub)
                let missing = EditorPalette.syntheticAttributes(for: traits, in: styled)
                if !missing.isEmpty { storage.addAttributes(missing, range: sub) }
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

        /// The `.link` attribute of a link: the URL for absolute addresses, the destination as written otherwise
        /// (a relative note path). `MarkdownTextView` hands it to `NoteLinks.classify` when it is clicked.
        private static func linkValue(_ string: String) -> Any? {
            guard !string.isEmpty else { return nil }
            if case .web(let url)? = NoteLinks.classify(string) { return url }
            return string
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

        /// Lines close to each other become one range (at most 4000 UTF-16 units apart): one `setAttributes` over it is
        /// far cheaper than many small ones in a storage with a lot of attribute runs.
        private static func coalesced(_ lines: [NSRange]) -> [NSRange] {
            var result: [NSRange] = []
            for line in lines {
                if let last = result.last, line.location - NSMaxRange(last) <= 4000 {
                    result[result.count - 1] = NSUnionRange(last, line)
                } else {
                    result.append(line)
                }
            }
            return result
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
    var onOpenLink: ((String) -> Void)?

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

    /// Clicks without modifiers (or with only ⌘) act on task boxes and links: a click on a box flips it, a click
    /// on a link opens it (⌘-click works too). Caret placement, selection and drags are untouched, so a link's text
    /// can still be edited with the arrow keys or a drag.
    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let plain = modifiers.isEmpty || modifiers == .command
        let hit = plain ? characterIndex(at: convert(event.locationInWindow, from: nil)) : nil
        if let hit, isEditable, let edit = taskToggle(at: hit) {
            window?.makeFirstResponder(self)
            if event.clickCount == 1 { apply(edit) }
            return
        }
        isTrackingMouse = true
        super.mouseDown(with: event)
        isTrackingMouse = false
        onMouseUp?()
        guard let hit, event.clickCount == 1, selectedRange().length == 0, let window,
              characterIndex(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) == hit,
              let value = textStorage?.attribute(.link, at: hit, effectiveRange: nil) else { return }
        onOpenLink?((value as? URL)?.absoluteString ?? "\(value)")
    }

    /// Links are followed by `mouseDown`; AppKit must not open them a second time.
    override func clicked(onLink link: Any, at charIndex: Int) {}

    private func taskToggle(at index: Int) -> TextEdit? {
        let ns = string as NSString
        guard index < ns.length, [0x5B, 0x20, 0x78, 0x58, 0x5D].contains(ns.character(at: index)) else { return nil }
        return MarkdownEditing.toggleTask(in: string, at: index)
    }

    /// The character under `point` (view coordinates), nil when the point is beside the text, not on a glyph.
    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer, layout.numberOfGlyphs > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: local, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        return layout.characterIndexForGlyph(at: glyph)
    }

    /// Return continues lists and quotes; see `MarkdownEditing.newline`.
    override func insertNewline(_ sender: Any?) {
        if !hasMarkedText(), let edit = MarkdownEditing.newline(in: string, selection: selectedRange()) {
            apply(edit)
        } else {
            super.insertNewline(sender)
        }
    }

    /// Tab and Shift-Tab indent and outdent list items; anywhere else they act as before.
    override func insertTab(_ sender: Any?) {
        if !hasMarkedText(), let edit = MarkdownEditing.indent(in: string, selection: selectedRange(), outdent: false) {
            apply(edit)
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        if !hasMarkedText(), let edit = MarkdownEditing.indent(in: string, selection: selectedRange(), outdent: true) {
            apply(edit)
        } else {
            super.insertBacktab(sender)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "b": toggleWrap("**"); return true
        case "i": toggleWrap("*"); return true
        case "k" where isEditable:
            if let edit = MarkdownEditing.link(in: string, selection: selectedRange()) { apply(edit) }
            return true
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


// MARK: - Range helpers

/// UTF-16 range arithmetic for the incremental restyling (pure, so it can be tested on its own).
enum RangeMath {
    /// Whole lines (LF only, like the scanner) touched by `range`, through the line break where it ends.
    static func lineRange(_ range: NSRange, in string: NSString) -> NSRange {
        let length = string.length
        var start = min(range.location, length)
        var end = min(max(NSMaxRange(range), start), length)
        while start > 0 && string.character(at: start - 1) != 0x0A { start -= 1 }
        while end < length && string.character(at: end) != 0x0A { end += 1 }
        if end < length { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The parts of `a` and `b` that are in only one of them, in ascending order.
    static func symmetricDifference(_ a: NSRange, _ b: NSRange) -> [NSRange] {
        (difference(a, b) + difference(b, a)).sorted { $0.location < $1.location }
    }

    /// `a` without `b`: zero, one or two ranges.
    static func difference(_ a: NSRange, _ b: NSRange) -> [NSRange] {
        let overlap = NSIntersectionRange(a, b)
        guard overlap.length > 0 else { return a.length > 0 ? [a] : [] }
        var result: [NSRange] = []
        if overlap.location > a.location { result.append(NSRange(location: a.location, length: overlap.location - a.location)) }
        if NSMaxRange(overlap) < NSMaxRange(a) { result.append(NSRange(location: NSMaxRange(overlap), length: NSMaxRange(a) - NSMaxRange(overlap))) }
        return result
    }

    /// `ranges` (ascending) without `blocks` (ascending, disjoint).
    static func subtract(_ ranges: [NSRange], removing blocks: [NSRange]) -> [NSRange] {
        guard !blocks.isEmpty else { return ranges }
        var result: [NSRange] = []
        for range in ranges {
            var rest = [range]
            var lo = 0, hi = blocks.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if NSMaxRange(blocks[mid]) <= range.location { lo = mid + 1 } else { hi = mid }
            }
            var k = lo
            while k < blocks.count, blocks[k].location < NSMaxRange(range) {
                rest = rest.flatMap { difference($0, blocks[k]) }
                k += 1
            }
            result += rest
        }
        return result
    }

    /// First index whose running maximum (`reach`, non-decreasing) is greater than `location`.
    static func firstIndex(in reach: [Int], endingAfter location: Int) -> Int {
        var lo = 0, hi = reach.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if reach[mid] <= location { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
