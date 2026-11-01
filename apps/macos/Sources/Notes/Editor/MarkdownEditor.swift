import AppKit
import NotesCore
import SwiftUI
import UniformTypeIdentifiers

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
    /// The note's file, which relative image paths and pasted images are relative to; nil for a draft.
    var noteURL: URL?
    /// False for an encrypted note: an image file in `assets` would be stored in plain.
    var allowsImageInsertion = true
    /// Dims all but the caret's paragraph and keeps the caret line centred.
    var focusMode = false

    init(text: Binding<String>, style: EditorStyle = .standard, showsSource: Bool = false, focusOnAppear: Bool = false,
         proxy: TextEditorProxy? = nil, undoManager: UndoManager? = nil, isEditable: Bool = true,
         onOpenLink: ((String) -> Void)? = nil, noteURL: URL? = nil, allowsImageInsertion: Bool = true,
         focusMode: Bool = false) {
        self.noteURL = noteURL
        self.allowsImageInsertion = allowsImageInsertion
        self.focusMode = focusMode
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
        textView.noteURL = noteURL
        textView.allowsImageInsertion = allowsImageInsertion
        textView.registerImageDragTypes()

        let coordinator = context.coordinator
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        textView.onLayoutWidthChange = { [weak coordinator, weak textView] in
            if let coordinator, let textView { coordinator.layoutWidthChanged(in: textView) }
        }
        textView.onWindowBecameKey = { [weak coordinator, weak textView] in
            if let coordinator, let textView { coordinator.windowBecameKey(in: textView) }
        }
        textView.onMouseUp = { [weak coordinator, weak textView] in
            if let coordinator, let textView { coordinator.selectionSettled(in: textView) }
        }
        proxy?.textView = textView
        proxy?.language = .markdown
        textView.onSelectionChange = { [weak proxy] in proxy?.refreshFormat() }

        let scrollView = textView.embeddedInScrollView()
        coordinator.observeScrolling(of: scrollView, textView: textView)
        coordinator.configure(textView, style: style, showsSource: showsSource, initial: true)
        coordinator.load(text, into: textView)
        coordinator.setFocusMode(focusMode, in: textView)
        if focusOnAppear { textView.requestFocus() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        textView.isEditable = isEditable
        textView.onOpenLink = onOpenLink
        textView.allowsImageInsertion = allowsImageInsertion
        proxy?.textView = textView
        proxy?.language = .markdown
        context.coordinator.configure(textView, style: style, showsSource: showsSource, initial: false)
        context.coordinator.update($text, in: textView)
        if textView.noteURL != noteURL {
            textView.noteURL = noteURL
            context.coordinator.applyImageSpacing(in: textView)
        }
        context.coordinator.setFocusMode(focusMode, in: textView)
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
        /// The lines (through their line break) with the cursor or selection, where markers can be shown while they
        /// are hidden elsewhere (see `shownMarkers`). nil when markers are not hidden.
        private var revealed: NSRange?
        /// The hidden-elsewhere markers that are shown, all inside `revealed`; see `markers(shownBy:within:string:)`.
        private var shownMarkers: Set<NSRange> = []
        /// The image lines of the current text (empty in source mode and for plain-text fallbacks).
        private var imageSlots: [InlineImageSlot] = []
        /// The pipe tables of the current text (whole lines) and how each is laid out, by start; see `layoutTable`.
        private var tables: [NSRange] = []
        private var grids: [Int: TableGrid] = [:]
        /// The tables the selection touches: shown as source so they can be edited.
        private var shownTables: Set<NSRange> = []
        /// Width the tables may use, as of the last restyle.
        private var containerWidth: CGFloat = 0
        private var focusMode = false
        /// The paragraph range and text length the focus dimming was last computed for.
        private var dimmedFor: (paragraph: NSRange, length: Int)?
        private var isImageSyncScheduled = false
        private var isCenterScheduled = false

        init(text: Binding<String>, undoManager: UndoManager?, style: EditorStyle, showsSource: Bool) {
            palette = EditorPalette(style)
            self.showsSource = showsSource
            super.init(text: text, undoManager: undoManager)
        }

        /// Reading mode hides the markers whatever the marker style, and never shows them at the cursor.
        private var hidesMarkers: Bool { (palette.style.markerStyle == .hidden || palette.style.reading) && !showsSource }
        private var base: [NSAttributedString.Key: Any] { showsSource ? palette.codeBase : palette.markdownBase }

        /// Applies a new style or source mode by restyling in place: the text, selection and undo stack stay.
        func configure(_ textView: MarkdownTextView, style: EditorStyle, showsSource: Bool, initial: Bool) {
            guard initial || style != palette.style || showsSource != self.showsSource else { return }
            if style != palette.style { palette = EditorPalette(style); dimmedFor = nil }
            self.showsSource = showsSource
            textView.apply(palette, spellCheck: style.spellCheck)
            textView.limitsLineWidth = style.limitLineWidth
            textView.codeBlockColor = palette.colors.codeBlockBackground.nsColor
            textView.tableHeaderColor = palette.colors.codeBlockBackground.nsColor
            textView.tableLineColor = palette.colors.marker.nsColor.withAlphaComponent(0.7)
            textView.copyButtonColor = palette.colors.secondaryText.nsColor
            textView.decorationColor = palette.colors.marker.nsColor
            textView.linkTextAttributes = [.foregroundColor: palette.colors.link.nsColor, .cursor: NSCursor.pointingHand]
            textView.defaultParagraphStyle = base[.paragraphStyle] as? NSParagraphStyle
            textView.typingAttributes = base
            if initial {
                textView.font = base[.font] as? NSFont
            } else {
                needsFullRestyle = true
                restyle(textView)
                updateFocus(in: textView)
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
                (textView as? MarkdownTextView)?.codeBlocks = []
                spans = []
                spanReach = []
                revealed = nil
                shownMarkers = []
                tables = []
                grids = [:]
                shownTables = []
                (textView as? MarkdownTextView)?.tableGrids = []
                (textView as? MarkdownTextView)?.decorations = []
                pendingEdit = nil
                needsFullRestyle = false
                textView.typingAttributes = base
                imageSlots = []
                (textView as? MarkdownTextView)?.imageSlots = []
                textView.needsDisplay = true
                if focusMode, !textView.hasMarkedText() {
                    updateFocus(in: textView)
                    scheduleCentering(textView)
                }
                return
            }
            if needsFullRestyle { dimmedFor = nil }
            let spans = MarkdownStyler.spans(in: storage.string)
            let blocks = spans.filter { $0.kind == .codeBlock }.map(\.range)
            let reveal = hidesMarkers ? revealRange(in: textView, string: storage.mutableString) : nil
            let oldGrids = grids
            let oldTables = tables
            containerWidth = Self.availableWidth(of: textView)
            tables = spans.filter { $0.kind == .table }.map(\.range)
            grids = [:]
            shownTables = tablesShown(by: reveal)

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
                // An edit in one row can change every column: tables it touches, before or after it, are restyled whole.
                for old in oldTables where oldGrids[old.location]?.rendered == true {
                    let moved = Self.shift(old, by: edit, length: storage.length, in: storage.string)
                    if NSIntersectionRange(moved, target).length > 0 { targets.append(moved) }
                }
                targets = Self.expanded(targets, over: renderedTables)
                for table in tables where !targets.contains(where: { NSIntersectionRange($0, table).length > 0 }) {
                    let old = table.location >= NSMaxRange(edit.range) ? table.location - edit.delta : table.location
                    grids[table.location] = oldGrids[old].map { $0.moved(to: table) }
                }
            }
            codeBlocks = blocks
            (textView as? MarkdownTextView)?.codeBlocks = blocks
            self.spans = spans
            spanReach = Self.reach(of: spans)
            pendingEdit = nil
            needsFullRestyle = false
            revealed = reveal
            shownMarkers = reveal.map { markers(shownBy: textView.selectedRanges.map(\.rangeValue), within: $0, string: storage.mutableString) } ?? []

            storage.beginEditing()
            for target in Self.merged(targets) { apply(in: target, to: storage) }
            storage.endEditing()
            syncGrids(textView)
            syncDecorations(textView, string: storage.mutableString)
            textView.typingAttributes = base
            updateImageSlots(in: textView, storage: storage, spans: spans)
            if focusMode, !textView.hasMarkedText() {
                updateFocus(in: textView)
                scheduleCentering(textView)
            }
        }

        override func selectionDidChange(in textView: NSTextView) {
            (textView as? MarkdownTextView)?.onSelectionChange?()
            // An edit is followed by a restyle, which takes care of focus mode.
            if focusMode, pendingEdit == nil, !needsFullRestyle {
                updateFocus(in: textView)
                if (textView as? MarkdownTextView)?.isTrackingMouse != true { scheduleCentering(textView) }
            }
            // While the mouse is down the reveal waits for mouse-up, so the text doesn't shift under the pointer.
            if (textView as? MarkdownTextView)?.isTrackingMouse == true { return }
            selectionSettled(in: textView)
        }

        /// Re-hides the markers the cursor left and shows those it touches now. Only the lines of the markers that
        /// changed are restyled.
        func selectionSettled(in textView: NSTextView) {
            // During an edit the restyle that follows it takes care of this.
            guard hidesMarkers, pendingEdit == nil, !needsFullRestyle, !textView.hasMarkedText(),
                  let storage = textView.textStorage, storage.length <= Self.maxStyledLength else { return }
            let string = storage.mutableString
            let reveal = revealRange(in: textView, string: string)
            let shown = markers(shownBy: textView.selectedRanges.map(\.rangeValue), within: reveal, string: string)
            let shownTablesNow = tablesShown(by: reveal)
            revealed = reveal
            guard shown != shownMarkers || shownTablesNow != shownTables else { return }
            let changed = shown.symmetricDifference(shownMarkers).filter { NSMaxRange($0) <= storage.length }
            let changedTables = shownTablesNow.symmetricDifference(shownTables).filter { NSMaxRange($0) <= storage.length }
            shownMarkers = shown
            shownTables = shownTablesNow
            containerWidth = Self.availableWidth(of: textView)
            let lines = Self.merged(changed.map { RangeMath.lineRange($0, in: string) } + changedTables)
            guard !lines.isEmpty else { return }
            storage.beginEditing()
            for line in Self.coalesced(Self.merged(Self.expanded(lines, over: renderedTables))) { apply(in: line, to: storage) }
            storage.endEditing()
            syncGrids(textView)
            syncDecorations(textView, string: string)
            // Restyling a line resets its paragraph style, which holds the room reserved for its images.
            if !imageSlots.isEmpty { applyImageSpacing(in: textView) }
        }

        // MARK: Images

        /// Finds the `![](…)` lines of the text (after a restyle) and reserves room under them.
        private func updateImageSlots(in textView: NSTextView, storage: NSTextStorage, spans: [MarkdownSpan]) {
            let references = MarkdownImages.references(in: storage.string, excluding: MarkdownImages.codeRanges(in: spans))
            var slots: [InlineImageSlot] = []
            let string = storage.mutableString
            for reference in references {
                let line = RangeMath.lineRange(reference.range, in: string)
                if slots.last?.paragraph == line {
                    slots[slots.count - 1].destinations.append(reference.destination)
                } else {
                    let end = NSMaxRange(line)
                    let endsWithBreak = end > line.location && string.character(at: end - 1) == 0x0A
                    slots.append(InlineImageSlot(paragraph: line, anchor: max(line.location, end - (endsWithBreak ? 2 : 1)),
                                                 destinations: [reference.destination]))
                }
            }
            guard !slots.isEmpty || !imageSlots.isEmpty else { return }
            imageSlots = slots
            applyImageSpacing(in: textView)
        }

        /// Resolves the images (decoding them in the background), reserves their height as paragraph spacing under
        /// their lines and hands the slots to the text view for drawing. Only paragraph attributes change; the text
        /// and undo stack are untouched.
        func applyImageSpacing(in textView: NSTextView) {
            guard let view = textView as? MarkdownTextView, let storage = textView.textStorage,
                  let container = textView.textContainer else { return }
            let width = container.size.width - 2 * container.lineFragmentPadding
            let folder = view.noteURL?.deletingLastPathComponent()
            let cache = InlineImageCache.shared
            cache.beginPass()
            let reload: @MainActor () -> Void = { [weak self, weak view] in
                if let self, let view { self.applyImageSpacing(in: view) }
            }
            let baseStyle = base[.paragraphStyle] as? NSParagraphStyle
            var changes: [(range: NSRange, spacing: CGFloat)] = []
            var trailing: CGFloat = 0
            for index in imageSlots.indices {
                let urls = imageSlots[index].destinations.map { MarkdownImages.fileURL(for: $0, noteFolder: folder) }
                imageSlots[index].urls = urls
                let sizes = urls.map { url -> NSSize in
                    guard let url, let natural = cache.size(for: url, owner: view, onUpdate: reload) else { return .zero }
                    return InlineImageLayout.size(of: natural, fitting: width)
                }
                let paragraph = imageSlots[index].paragraph
                guard NSMaxRange(paragraph) <= storage.length else { continue }
                if NSMaxRange(paragraph) == storage.length, storage.mutableString.character(at: storage.length - 1) != 0x0A {
                    trailing = InlineImageLayout.reservedHeight(sizes)
                }
                let spacing = (baseStyle?.paragraphSpacing ?? 0) + InlineImageLayout.reservedHeight(sizes)
                let current = (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing
                if current != spacing { changes.append((paragraph, spacing)) }
            }
            view.imageSlots = imageSlots
            view.needsDisplay = true
            if view.trailingImageHeight != trailing {
                view.trailingImageHeight = trailing
                view.sizeToFit()
            }
            guard !changes.isEmpty, !textView.hasMarkedText() else { return }
            storage.beginEditing()
            for change in changes {
                let current = storage.attribute(.paragraphStyle, at: change.range.location, effectiveRange: nil) as? NSParagraphStyle
                let style = (current ?? baseStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.paragraphSpacing = change.spacing
                storage.addAttribute(.paragraphStyle, value: style, range: change.range)
            }
            storage.endEditing()
        }

        func layoutWidthChanged(in textView: NSTextView) {
            guard !imageSlots.isEmpty || !grids.isEmpty, !isImageSyncScheduled else { return }
            isImageSyncScheduled = true
            DispatchQueue.main.async { [weak self, weak textView] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isImageSyncScheduled = false
                    guard let textView else { return }
                    self.refitTables(in: textView)
                    if !self.imageSlots.isEmpty { self.applyImageSpacing(in: textView) }
                }
            }
        }

        /// Images that changed on disk while another app was in front are decoded again.
        func windowBecameKey(in textView: NSTextView) {
            guard !imageSlots.isEmpty else { return }
            InlineImageCache.shared.expireChecks()
            applyImageSpacing(in: textView)
        }

        // MARK: Focus mode

        func setFocusMode(_ on: Bool, in textView: NSTextView) {
            guard on != focusMode, let view = textView as? MarkdownTextView else { return }
            focusMode = on
            view.centersCaret = on
            dimmedFor = nil
            if on {
                updateFocus(in: textView)
                scheduleCentering(textView)
            } else {
                let full = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
                textView.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
                view.focusParagraph = nil
            }
        }

        /// The dim of focus mode would show the glyphs of drawn markers (`-`, `>`, `---`) over their drawings:
        /// keep them clear. The drawings are dimmed by the text view.
        private func clearDecorationGlyphs(in textView: NSTextView, outside paragraph: NSRange) {
            guard let layout = textView.layoutManager, let view = textView as? MarkdownTextView else { return }
            for item in view.decorations where !NSLocationInRange(item.range.location, paragraph) && NSMaxRange(item.range) <= (textView.textStorage?.length ?? 0) {
                layout.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: item.range)
            }
        }

        /// Dims everything except the paragraphs the selection touches, with temporary attributes (the text storage
        /// is not touched). Skipped while the paragraph and length are unchanged.
        private func updateFocus(in textView: NSTextView) {
            guard focusMode, let layout = textView.layoutManager, let storage = textView.textStorage else { return }
            let length = storage.length
            let paragraph = Self.revealRange(of: textView.selectedRanges, in: storage.mutableString)
            if let dimmedFor, dimmedFor.paragraph == paragraph, dimmedFor.length == length { return }
            // Typing inside the same paragraph only moves the dimmed tail: the part before it stays as it is.
            let keepsHead = dimmedFor?.paragraph.location == paragraph.location
            dimmedFor = (paragraph, length)
            let cleared = keepsHead ? NSRange(location: paragraph.location, length: length - paragraph.location)
                                    : NSRange(location: 0, length: length)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: cleared)
            (textView as? MarkdownTextView)?.focusParagraph = paragraph
            let dim = palette.colors.text.nsColor.withAlphaComponent(0.3)
            defer { clearDecorationGlyphs(in: textView, outside: paragraph) }
            if paragraph.location > 0, !keepsHead {
                layout.addTemporaryAttribute(.foregroundColor, value: dim, forCharacterRange: NSRange(location: 0, length: paragraph.location))
            }
            if NSMaxRange(paragraph) < length {
                layout.addTemporaryAttribute(.foregroundColor, value: dim,
                                             forCharacterRange: NSRange(location: NSMaxRange(paragraph), length: length - NSMaxRange(paragraph)))
            }
        }

        /// After AppKit's own scrolling for the edit or selection change, so the caret line has the last word.
        private func scheduleCentering(_ textView: NSTextView) {
            guard !isCenterScheduled else { return }
            isCenterScheduled = true
            DispatchQueue.main.async { [weak self, weak textView] in
                MainActor.assumeIsolated {
                    self?.isCenterScheduled = false
                    guard let self, self.focusMode, let view = textView as? MarkdownTextView else { return }
                    view.centerCaret()
                }
            }
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

        /// The hideable markers inside `lines` that stay visible: those a selection touches (either end counts), and
        /// both delimiters of an emphasis, code span or link whose text or delimiters a selection touches, so a pair
        /// shows together. A heading's `#`s show when the cursor is next to them, not anywhere on the line; fences
        /// when it is on the fence line. None in reading mode.
        private func markers(shownBy selections: [NSRange], within lines: NSRange, string: NSString) -> Set<NSRange> {
            guard !palette.style.reading else { return [] }
            func touched(_ r: NSRange) -> Bool {
                selections.contains { r.location <= NSMaxRange($0) && $0.location <= NSMaxRange(r) }
            }
            var markers: [NSRange] = [], elements: [NSRange] = [], decorated: [NSRange] = []
            var k = RangeMath.firstIndex(in: spanReach, endingAfter: lines.location)
            while k < spans.count, spans[k].range.location < NSMaxRange(lines) {
                let span = spans[k]
                k += 1
                guard span.range.location >= lines.location, NSMaxRange(span.range) <= NSMaxRange(lines) else { continue }
                switch span.kind {
                case .marker where !Self.isQuoteMarker(span.range, in: string): markers.append(span.range)
                case .marker, .horizontalRule: decorated.append(span.range)
                case .listMarker where Self.isBullet(span.range, in: string): decorated.append(span.range)
                case .bold, .italic, .boldItalic, .strikethrough, .inlineCode, .link, .wikiLink: elements.append(span.range)
                default: break
                }
            }
            var shown = Set(markers.filter(touched))
            shown.formUnion(decorated.filter(touched))
            guard !elements.isEmpty else { return shown }
            var byEnd: [Int: NSRange] = [:], byStart: [Int: NSRange] = [:]
            for marker in markers {
                byEnd[NSMaxRange(marker)] = marker
                byStart[marker.location] = marker
            }
            for element in elements {
                // Both or none: a bare URL has no delimiters of its own, and a heading's `#` before it is not one.
                guard let open = byEnd[element.location], let close = byStart[NSMaxRange(element)],
                      touched(NSUnionRange(open, close)) else { continue }
                shown.insert(open)
                shown.insert(close)
            }
            return shown
        }

        // MARK: Tables

        /// Horizontal room a cell keeps on each side of its text.
        private static let tableCellPadding: CGFloat = 12

        private static func availableWidth(of textView: NSTextView) -> CGFloat {
            textView.textContainer.map { $0.size.width - 2 * $0.lineFragmentPadding } ?? 0
        }

        /// `ranges` with every table they touch added whole, so a table is always restyled as a unit.
        private static func expanded(_ ranges: [NSRange], over tables: [NSRange]) -> [NSRange] {
            var result = ranges
            for table in tables where ranges.contains(where: { NSIntersectionRange($0, table).length > 0 }) { result.append(table) }
            return result
        }

        /// Tables that are laid out as tables now: only those must be restyled as a unit.
        private var renderedTables: [NSRange] {
            hidesMarkers ? tables.filter { !shownTables.contains($0) } : []
        }

        /// Tables the selection touches stay source (none in reading mode, which renders them always).
        private func tablesShown(by reveal: NSRange?) -> Set<NSRange> {
            guard let reveal, !palette.style.reading else { return [] }
            return Set(tables.filter { NSIntersectionRange($0, reveal).length > 0 })
        }

        private func syncGrids(_ textView: NSTextView) {
            (textView as? MarkdownTextView)?.tableGrids = tables.compactMap { grids[$0.location] }.filter(\.rendered)
        }

        /// A narrower or wider container can flip a table between rendered and source: restyle those tables.
        private func refitTables(in textView: NSTextView) {
            guard hidesMarkers, pendingEdit == nil, !needsFullRestyle, !textView.hasMarkedText(),
                  let storage = textView.textStorage, storage.length <= Self.maxStyledLength else { return }
            containerWidth = Self.availableWidth(of: textView)
            let stale = tables.filter { table in
                grids[table.location].map { ($0.naturalWidth <= containerWidth) != $0.rendered } ?? false
            }
            guard !stale.isEmpty else { return }
            storage.beginEditing()
            for table in stale where NSMaxRange(table) <= storage.length { apply(in: table, to: storage) }
            storage.endEditing()
            syncGrids(textView)
        }

        /// Renders a table inside `storage`: the pipes, the delimiter row and the spaces around the cells are hidden
        /// (still real text), and every cell is placed in its column with `.kern` after (and before) the cell's
        /// text, or a head indent for the first column. The text view draws the grid behind it from the returned
        /// `TableGrid`. A table the selection touches, or wider than the container, keeps its source styling.
        private func layoutTable(_ range: NSRange, in storage: NSTextStorage) {
            grids[range.location] = nil
            guard hidesMarkers, !shownTables.contains(range), NSMaxRange(range) <= storage.length,
                  let grid = MarkdownTable.grid(in: storage.mutableString.substring(with: range), offsetBy: range.location) else { return }
            let pad = Self.tableCellPadding
            let widths = grid.rows.map { row in row.cells.map { cell in cell.length > 0 ? storage.attributedSubstring(from: cell).size().width : 0 } }
            let columnWidths = TableMetrics.columnWidths(widths, columns: grid.columns)
            var edges: [CGFloat] = [0]
            for width in columnWidths { edges.append(edges[edges.count - 1] + width + 2 * pad) }
            let natural = edges[edges.count - 1]
            let rows = grid.rows.map(\.line)
            let result = TableGrid(range: range, naturalWidth: natural, rendered: natural <= containerWidth, rows: rows,
                                   delimiter: grid.delimiter, edges: edges)
            defer { grids[range.location] = result }
            guard result.rendered else { return }

            let string = storage.mutableString
            let baseStyle = base[.paragraphStyle] as? NSParagraphStyle
            func paragraph(_ line: NSRange, indent: CGFloat, before: CGFloat, after: CGFloat, collapsed: Bool = false) {
                let style = (baseStyle?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                style.firstLineHeadIndent = indent
                style.headIndent = indent
                style.paragraphSpacingBefore = before
                style.paragraphSpacing = after
                style.lineBreakMode = .byClipping
                style.lineHeightMultiple = 1
                if collapsed { style.maximumLineHeight = 1 }
                storage.addAttribute(.paragraphStyle, value: style, range: RangeMath.lineRange(line, in: string))
            }
            var kerns: [Int: CGFloat] = [:]
            for (r, row) in grid.rows.enumerated() {
                var cursor = row.line.location
                var indent: CGFloat = 0
                for (c, cell) in row.cells.enumerated() {
                    if cell.length > 0 {
                        if cell.location > cursor { storage.addAttributes(palette.hiddenMarker, range: NSRange(location: cursor, length: cell.location - cursor)) }
                        cursor = NSMaxRange(cell)
                    }
                    let alignment = c < grid.alignments.count ? grid.alignments[c] : TableAlignment.none
                    let slack = TableMetrics.slack(cell: widths[r][c], column: columnWidths[c], alignment: alignment)
                    if c == 0 { indent = pad + slack.before } else if cell.location > row.line.location { kerns[cell.location - 1, default: 0] += pad + slack.before }
                    if NSMaxRange(cell) < NSMaxRange(row.line) { kerns[NSMaxRange(cell), default: 0] += slack.after + pad }
                }
                let end = NSMaxRange(row.line)
                if end > cursor { storage.addAttributes(palette.hiddenMarker, range: NSRange(location: cursor, length: end - cursor)) }
                let last = r == grid.rows.count - 1
                paragraph(row.line, indent: indent, before: r == 0 ? 8 : 0, after: last ? 14 : TableGrid.rowGap)
            }
            for (index, kern) in kerns where index < storage.length {
                storage.addAttribute(.kern, value: kern, range: NSRange(location: index, length: 1))
            }
            let delimiter = RangeMath.lineRange(grid.delimiter, in: string)
            storage.addAttributes(palette.hiddenMarker, range: delimiter)
            paragraph(grid.delimiter, indent: 0, before: 0, after: 0, collapsed: true)
        }

        // MARK: Bullets, quote bars and rules

        /// `-`, `*` or `+` of a list item that is not a task (those keep their text).
        private static func isBullet(_ range: NSRange, in string: NSString) -> Bool {
            guard range.length == 1, range.location < string.length, [0x2D, 0x2A, 0x2B].contains(string.character(at: range.location)) else { return false }
            let box = range.location + 2
            return !(box + 2 < string.length && string.character(at: box) == 0x5B && string.character(at: box + 2) == 0x5D)
        }

        /// Whether `span` is drawn instead of written while markers are hidden: a bullet, a quote's `>`, a thematic break.
        private func isDecorated(_ span: MarkdownSpan, in string: NSString) -> TextDecoration.Kind? {
            switch span.kind {
            case .listMarker where Self.isBullet(span.range, in: string): return .bullet
            case .marker where Self.isQuoteMarker(span.range, in: string): return .quoteBar
            case .horizontalRule: return .rule
            default: return nil
            }
        }

        private func syncDecorations(_ textView: NSTextView, string: NSString) {
            var result: [TextDecoration] = []
            if hidesMarkers {
                for span in spans {
                    guard let kind = isDecorated(span, in: string), !shownMarkers.contains(span.range) else { continue }
                    result.append(TextDecoration(range: span.range, kind: kind))
                }
                result.sort { $0.range.location < $1.range.location }
            }
            (textView as? MarkdownTextView)?.decorations = result
            if focusMode, let paragraph = dimmedFor?.paragraph { clearDecorationGlyphs(in: textView, outside: paragraph) }
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
            var k = RangeMath.firstIndex(in: spanReach, endingAfter: target.location)
            var tablesToLayout: [NSRange] = []
            while k < spans.count {
                let span = spans[k]
                k += 1
                if span.range.location >= NSMaxRange(target) { break }
                let range = NSIntersectionRange(span.range, target)
                guard range.length > 0 else { continue }
                if span.kind == .table {
                    if range == span.range { tablesToLayout.append(range) }
                    continue
                }
                let decorated = hidesMarkers && !shownMarkers.contains(span.range) && isDecorated(span, in: string) != nil
                if span.kind == .marker, hidesMarkers, !shownMarkers.contains(span.range), !Self.isQuoteMarker(span.range, in: string) {
                    storage.addAttributes(palette.hiddenMarker, range: range)
                    continue
                }
                style(span.kind, in: range, of: storage)
                // Drawn by the text view instead: same width, invisible glyph.
                if decorated { storage.addAttribute(.foregroundColor, value: NSColor.clear, range: range) }
                if span.kind == .codeBlock { highlightCode(in: span.range, within: target, of: storage, string: string) }
            }
            for table in tablesToLayout { layoutTable(table, in: storage) }
        }

        private func style(_ kind: MarkdownSpan.Kind, in range: NSRange, of storage: NSTextStorage) {
            let colors = palette.colors
            switch kind {
            case .table:
                break
            case .tableHeader:
                addTraits(.boldFontMask, to: storage, in: range)
            case .marker, .horizontalRule, .tableMarker:
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
                // Fenced blocks get a full-width band from the text view instead of a background behind the glyphs.
                if kind == .inlineCode {
                    storage.addAttributes([
                        .foregroundColor: colors.inlineCode.nsColor,
                        .backgroundColor: colors.inlineCodeBackground.nsColor,
                    ], range: range)
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
            // A range that ends where the edit starts is before it (unlike a code block, which an edit at its end extends).
            var r = NSMaxRange(range) <= edit.range.location ? range : shift([range], by: edit)[0]
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
    var onSelectionChange: (() -> Void)?
    var onOpenLink: ((String) -> Void)?
    /// The note's file (nil for a draft): where relative images are found and pasted images are saved.
    var noteURL: URL?
    var allowsImageInsertion = true
    /// The lines with images under them, in document order; set by the coordinator.
    var imageSlots: [InlineImageSlot] = []
    var onLayoutWidthChange: (() -> Void)?
    var onWindowBecameKey: (() -> Void)?
    private var keyObserver: NSObjectProtocol?
    /// Focus mode: room above and below the text (half the viewport) lets the first and last lines reach the centre.
    var centersCaret = false {
        didSet { if centersCaret != oldValue { updateInsets(for: frame.size) } }
    }

    /// Fenced code blocks (fence lines included) of the styled text, sorted; drawn as full-width bands under the text.
    /// Empty in source mode and for text too long to style.
    var codeBlocks: [NSRange] = [] {
        didSet {
            guard codeBlocks != oldValue else { return }
            setNeedsDisplay(visibleRect)
            updateCopyButton()
        }
    }
    /// Rendered pipe tables, sorted; their grids are drawn under the text.
    var tableGrids: [TableGrid] = [] {
        didSet { if tableGrids != oldValue { setNeedsDisplay(visibleRect) } }
    }
    /// Bullets, quote bars and thematic breaks drawn in place of their (invisible) marker characters.
    var decorations: [TextDecoration] = [] {
        didSet { if decorations != oldValue { setNeedsDisplay(visibleRect) } }
    }
    var decorationColor: NSColor?
    /// Focus mode: the paragraph that is not dimmed; decorations elsewhere are drawn dimmed too.
    var focusParagraph: NSRange? {
        didSet { if focusParagraph != oldValue { setNeedsDisplay(visibleRect) } }
    }
    var tableLineColor: NSColor?
    var tableHeaderColor: NSColor?
    var copyButtonColor: NSColor = .secondaryLabelColor
    var copyButton: CopyCodeButton?
    /// The code block the copy button is shown on.
    var hoveredCodeBlock: NSRange?
    private var hoverArea: NSTrackingArea?
    private var scrollObserver: NSObjectProtocol?
    var codeBlockColor: NSColor? {
        didSet { if codeBlockColor != oldValue { needsDisplay = true } }
    }

    override func bandExtent() -> ClosedRange<CGFloat> {
        guard let container = textContainer else { return super.bandExtent() }
        let origin = textContainerOrigin.x
        // Mid-layout (a tab being rebuilt) the container can lie outside the bounds; keep the range valid.
        let low = min(max(bounds.minX, origin - 6), bounds.maxX)
        return low...max(low, min(bounds.maxX, origin + container.size.width + 6))
    }

    override var bandCornerRadius: CGFloat { 4 }

    override func drawBands(in rect: NSRect) {
        drawCodeBlocks(in: rect)
        drawTables(in: rect)
        drawDecorations(in: rect)
        super.drawBands(in: rect)
    }

    private func drawCodeBlocks(in dirty: NSRect) {
        guard let color = codeBlockColor, !codeBlocks.isEmpty, let layout = layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        // Widened past the paragraph spacing between two lines, so a dirty strip inside a block still finds it.
        let probe = dirty.insetBy(dx: 0, dy: -16).offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: probe, in: container)
        guard glyphs.length > 0 else { return }
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var lo = 0, hi = codeBlocks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(codeBlocks[mid]) <= chars.location { lo = mid + 1 } else { hi = mid }
        }
        let length = textStorage?.length ?? 0
        for block in codeBlocks[lo...] {
            if block.location >= NSMaxRange(chars) { break }
            guard NSMaxRange(block) <= length, let band = lineBand(forCharacters: block), band.intersects(dirty) else { continue }
            fillBand(band, with: color, radius: bandCornerRadius)
            drawLanguageLabel(of: block)
        }
    }

    /// The fence's language at the top-left of the block, where the hidden opening fence leaves an empty line.
    private func drawLanguageLabel(of block: NSRange) {
        guard let storage = textStorage, let layout = layoutManager, block.length > 0,
              (storage.attribute(.font, at: block.location, effectiveRange: nil) as? NSFont)?.pointSize ?? 1 < 1 else { return }
        let ns = storage.mutableString
        let first = RangeMath.lineRange(NSRange(location: block.location, length: 0), in: ns)
        let line = ns.substring(with: NSIntersectionRange(first, block))
        let info = line.trimmingCharacters(in: CharacterSet(charactersIn: "`~").union(.whitespacesAndNewlines))
            .split(whereSeparator: { $0 == " " || $0 == "{" }).first.map(String.init) ?? ""
        guard !info.isEmpty else { return }
        let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: block.location), effectiveRange: nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: copyButtonColor]
        let size = (info as NSString).size(withAttributes: attributes)
        let origin = textContainerOrigin
        (info as NSString).draw(at: NSPoint(x: origin.x + 4, y: origin.y + rect.midY - size.height / 2 + 2), withAttributes: attributes)
    }

    /// Room for the images under a last line that has no line break (paragraph spacing needs one to take effect).
    var trailingImageHeight: CGFloat = 0

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        updateInsets(for: newSize)
        super.setFrameSize(NSSize(width: newSize.width, height: newSize.height + trailingImageHeight))
        if widthChanged { onLayoutWidthChange?() }
        if copyButton?.isHidden == false { updateCopyButton() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateCopyButton()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateCopyButton()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateCopyButton()
    }

    private func updateInsets(for size: NSSize) {
        let centered = ((size.width - Self.maxLineWidth) / 2).rounded()
        let horizontal = limitsLineWidth ? max(Self.minInset.width, centered) : Self.minInset.width
        let vertical = centersCaret ? max(Self.minInset.height, ((enclosingScrollView?.contentView.bounds.height ?? 0) / 2).rounded()) : Self.minInset.height
        if textContainerInset.width != horizontal || textContainerInset.height != vertical {
            textContainerInset = NSSize(width: horizontal, height: vertical)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        hideCopyButton()
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.updateCopyButton() }
            }
        }
        guard let window else { return }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.onWindowBecameKey?() }
        }
    }

    // MARK: Images and caret position

    /// Draws the images under their lines, in the room the coordinator reserved as paragraph spacing.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The text may have moved under a still mouse (an edit above, a changed image).
        if copyButton?.isHidden == false { updateCopyButton() }
        guard !imageSlots.isEmpty, let layout = layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        let width = container.size.width - 2 * container.lineFragmentPadding
        let cache = InlineImageCache.shared
        let length = textStorage?.length ?? 0
        // Slots whose line is above the dirty rect can still reach into it: look back by the tallest stack.
        let probe = dirtyRect.insetBy(dx: 0, dy: -InlineImageLayout.maxHeight * 3).offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: probe, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var lo = 0, hi = imageSlots.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(imageSlots[mid].paragraph) <= chars.location { lo = mid + 1 } else { hi = mid }
        }
        for slot in imageSlots[lo...] {
            if slot.paragraph.location >= NSMaxRange(chars) { break }
            guard slot.anchor < length, slot.urls.count == slot.destinations.count else { continue }
            let glyph = layout.glyphIndexForCharacter(at: slot.anchor)
            var y = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxY + origin.y + InlineImageLayout.gap
            for url in slot.urls {
                guard let url, let image = cache.cachedImage(for: url) else { continue }
                let size = InlineImageLayout.size(of: image.size, fitting: width)
                guard size.height > 0 else { continue }
                let rect = NSRect(x: origin.x, y: y, width: size.width, height: size.height)
                y += size.height + InlineImageLayout.gap
                guard rect.intersects(dirtyRect) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    /// The rectangle of the line with the caret, in the text container's coordinates.
    private func caretLineRect() -> NSRect? {
        guard let layout = layoutManager, let storage = textStorage else { return nil }
        let length = storage.length
        let location = min(selectedRange().location, length)
        layout.ensureLayout(forCharacterRange: NSRange(location: max(0, min(location, length - 1)), length: length == 0 ? 0 : 1))
        if length == 0 || (location == length && storage.string.hasSuffix("\n")) {
            let extra = layout.extraLineFragmentRect
            return extra.isEmpty ? nil : extra
        }
        let glyph = layout.glyphIndexForCharacter(at: min(location, length - 1))
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    /// Scrolls so the line with the caret is in the vertical middle of the viewport (typewriter scrolling).
    func centerCaret() {
        guard let rect = caretLineRect(), let clip = enclosingScrollView?.contentView else { return }
        scrollClip(toY: rect.midY + textContainerOrigin.y - clip.bounds.height / 2)
    }

    private func scrollClip(toY y: CGFloat) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let target = min(max(0, y), max(0, frame.height - clip.bounds.height)).rounded()
        guard abs(target - clip.bounds.origin.y) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Puts the caret at `location` (UTF-16) and brings that line into view: centred in focus mode, else near the top.
    func reveal(location: Int) {
        let length = (string as NSString).length
        setSelectedRange(NSRange(location: min(max(location, 0), length), length: 0))
        window?.makeFirstResponder(self)
        if centersCaret {
            centerCaret()
        } else if let rect = caretLineRect() {
            scrollClip(toY: rect.minY + textContainerOrigin.y - 60)
        }
    }

    // MARK: Pasting and dropping images

    private enum ImageSource {
        case file(URL)
        /// Image data on the pasteboard (a screenshot, a copied picture).
        case data(NSPasteboard)
    }

    func registerImageDragTypes() {
        registerForDraggedTypes(registeredDraggedTypes + [.fileURL, .png, .tiff])
    }

    /// What the pasteboard offers as images to add to the note, or nil when it should be handled as text/files as
    /// before: image files from Finder (only when all items are images), or image data without any text.
    private func imageSources(in pasteboard: NSPasteboard) -> [ImageSource]? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            return images.count == urls.count ? images.map(ImageSource.file) : nil
        }
        guard pasteboard.string(forType: .string) == nil,
              pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) else { return nil }
        return [.data(pasteboard)]
    }

    /// PNG data and the file extension to store it under. PNG, JPEG and GIF files keep their bytes; everything else
    /// (TIFF, HEIC, screenshots on the pasteboard…) becomes PNG.
    private func imageFile(for source: ImageSource) -> (data: Data, fileExtension: String)? {
        switch source {
        case .file(let url):
            let ext = url.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif"].contains(ext), let data = try? Data(contentsOf: url) {
                return (data, ext == "jpeg" ? "jpg" : ext)
            }
            guard let image = NSImage(contentsOf: url) else { return nil }
            return Self.pngData(image).map { ($0, "png") }
        case .data(let pasteboard):
            if let png = pasteboard.data(forType: .png) { return (png, "png") }
            guard let image = (pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first else { return nil }
            return Self.pngData(image).map { ($0, "png") }
        }
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Saves each image into the note's `assets` folder and inserts `![](assets/…)` for them at `range`, one per
    /// line, as a single undo step. A draft has no folder yet: nothing is saved and a neutral message says so.
    private func insertImages(_ sources: [ImageSource], at range: NSRange) {
        guard allowsImageInsertion else {
            showImageMessage(L("Images can't be added to an encrypted note, because the image files would not be encrypted."))
            return
        }
        guard let noteURL else {
            showImageMessage(L("Save the note first to add images."))
            return
        }
        var lines: [String] = []
        var failure: String?
        for source in sources {
            guard let file = imageFile(for: source) else {
                failure = L("The image couldn't be read.")
                continue
            }
            do {
                lines.append("![](\(try NoteAssets.save(file.data, forNoteAt: noteURL, fileExtension: file.fileExtension)))")
            } catch {
                failure = error.localizedDescription
            }
        }
        if !lines.isEmpty {
            var text = lines.joined(separator: "\n")
            // At the very end the last image line would have no break to hold the room reserved under it.
            if NSMaxRange(range) == (string as NSString).length { text += "\n" }
            let end = range.location + (text as NSString).length
            apply(TextEdit(range: range, replacement: text, selection: NSRange(location: end, length: 0)))
        }
        if let failure { showImageMessage(failure) }
    }

    private func showImageMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L("Couldn't add the image")
        alert.informativeText = message
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    override func paste(_ sender: Any?) {
        guard isEditable, let sources = imageSources(in: .general) else { return super.paste(sender) }
        insertImages(sources, at: selectedRange())
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isEditable && imageSources(in: sender.draggingPasteboard) != nil ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isEditable && imageSources(in: sender.draggingPasteboard) != nil ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isEditable && imageSources(in: sender.draggingPasteboard) != nil ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isEditable, let sources = imageSources(in: sender.draggingPasteboard) else { return super.performDragOperation(sender) }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        insertImages(sources, at: NSRange(location: min(index, (string as NSString).length), length: 0))
        return true
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
              Self.stayedInPlace(from: event.locationInWindow, to: window.mouseLocationOutsideOfEventStream),
              let value = textStorage?.attribute(.link, at: hit, effectiveRange: nil) else { return }
        onOpenLink?((value as? URL)?.absoluteString ?? "\(value)")
    }

    /// The pointer is where the click began (revealing markers may have shifted the text meanwhile, so the character
    /// under it can't be compared again).
    private static func stayedInPlace(from start: NSPoint, to end: NSPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) <= 4
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
        if !hasMarkedText(), let edit = MarkdownTable.newline(in: string, selection: selectedRange())
            ?? MarkdownEditing.newline(in: string, selection: selectedRange()) {
            apply(edit)
        } else {
            super.insertNewline(sender)
        }
    }

    /// Tab and Shift-Tab indent and outdent list items; anywhere else they act as before.
    override func insertTab(_ sender: Any?) {
        if !hasMarkedText(), let edit = MarkdownTable.tab(in: string, selection: selectedRange(), backward: false)
            ?? MarkdownEditing.indent(in: string, selection: selectedRange(), outdent: false) {
            apply(edit)
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        if !hasMarkedText(), let edit = MarkdownTable.tab(in: string, selection: selectedRange(), backward: true)
            ?? MarkdownEditing.indent(in: string, selection: selectedRange(), outdent: true) {
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
        case "b" where isEditable: if let edit = MarkdownEditing.toggleInline(.bold, in: string, selection: selectedRange()) { apply(edit) }; return true
        case "i" where isEditable: if let edit = MarkdownEditing.toggleInline(.italic, in: string, selection: selectedRange()) { apply(edit) }; return true
        case "k" where isEditable:
            if let edit = MarkdownEditing.link(in: string, selection: selectedRange()) { apply(edit) }
            return true
        default: return super.performKeyEquivalent(with: event)
        }
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
