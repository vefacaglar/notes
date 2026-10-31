import AppKit
import NotesCore
import SwiftUI

extension NSTextView {
    /// Plain-text setup shared by the editors: no rich text or smart substitutions, undo and the find bar on.
    func configureAsPlainTextEditor() {
        autoresizingMask = [.width]
        isVerticallyResizable = true
        isHorizontallyResizable = false
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
        layoutManager?.allowsNonContiguousLayout = true

        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        smartInsertDeleteEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false

        drawsBackground = true
        backgroundColor = .textBackgroundColor
        insertionPointColor = .controlAccentColor
    }

    /// Applies `edit` as one undoable step, then places the selection if the edit says where it goes.
    func apply(_ edit: TextEdit) {
        guard isEditable, let storage = textStorage, NSMaxRange(edit.range) <= storage.length else { return }
        if edit.range.length == 0, edit.replacement.isEmpty {
            if let selection = edit.selection { setSelectedRange(selection); scrollRangeToVisible(selection) }
            return
        }
        breakUndoCoalescing()
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        if let selection = edit.selection {
            setSelectedRange(selection)
            scrollRangeToVisible(selection)
        }
    }

    func embeddedInScrollView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = self
        return scrollView
    }
}

/// Base class of the editors' text views.
class EditorTextView: NSTextView {
    private var focusWhenInWindow = false

    // MARK: Background bands

    /// The band behind the caret's line while nothing is selected; nil switches it off.
    var currentLineColor: NSColor? {
        didSet { if currentLineColor != oldValue { needsDisplay = true } }
    }
    /// Where the current-line band was last drawn (view coordinates), so a selection change redraws only that and the new one.
    private var drawnCurrentLine: NSRect?

    /// Horizontal extent of full-width bands, in view coordinates.
    func bandExtent() -> ClosedRange<CGFloat> { bounds.minX...bounds.maxX }
    var bandCornerRadius: CGFloat { 0 }

    /// Fills the rectangle with `color` as a band (rounded where the editor asks for it).
    func fillBand(_ rect: NSRect, with color: NSColor, radius: CGFloat) {
        color.setFill()
        if radius > 0 {
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        } else {
            rect.fill()
        }
    }

    /// Rect of `characters`' lines from the top of the first line fragment to the bottom of the last one's text,
    /// excluding the paragraph spacing after it (which holds inline images), in view coordinates.
    func lineBand(forCharacters characters: NSRange) -> NSRect? {
        guard let layout = layoutManager, characters.length > 0 else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let first = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = layout.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        return bandRect(minY: first.minY, maxY: last.maxY)
    }

    private func bandRect(minY: CGFloat, maxY: CGFloat) -> NSRect {
        let extent = bandExtent()
        let top = minY + textContainerOrigin.y
        return NSRect(x: extent.lowerBound, y: top, width: extent.upperBound - extent.lowerBound, height: maxY - minY)
    }

    /// The caret's logical line (all its wrapped fragments), nil when the selection is not empty or the feature is off.
    func currentLineBand() -> NSRect? {
        guard currentLineColor != nil, let layout = layoutManager, let storage = textStorage else { return nil }
        let selection = selectedRange()
        guard selection.length == 0 else { return nil }
        let string = storage.mutableString
        let length = string.length
        let location = min(selection.location, length)
        if length == 0 || (location == length && string.character(at: length - 1) == 0x0A) {
            layout.ensureLayout(forCharacterRange: NSRange(location: max(0, length - 1), length: length == 0 ? 0 : 1))
            let extra = layout.extraLineFragmentRect
            return extra.isEmpty ? nil : bandRect(minY: extra.minY, maxY: extra.maxY)
        }
        return lineBand(forCharacters: string.paragraphRange(for: NSRange(location: location, length: 0)))
    }

    /// Call after the selection or the text changed: redraws the old and the new current-line rects, nothing else.
    func refreshCurrentLine() {
        let new = currentLineBand()
        guard new != drawnCurrentLine else { return }
        if let old = drawnCurrentLine { setNeedsDisplay(old.insetBy(dx: 0, dy: -2)) }
        if let new { setNeedsDisplay(new.insetBy(dx: 0, dy: -2)) }
        drawnCurrentLine = new
    }

    /// Bands go under the text, the selection and the glyph backgrounds.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawBands(in: rect)
    }

    func drawBands(in rect: NSRect) {
        guard let color = currentLineColor, let band = currentLineBand(), band.intersects(rect) else { return }
        fillBand(band, with: color, radius: bandCornerRadius)
    }

    /// Pasted and dropped text enters in the document's normal form (no BOM, LF line breaks), so the text view and
    /// the binding never differ. `insertText` keeps it one undo step.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let text = pboard.string(forType: .string), NoteFile.needsNormalizing(text) else {
            return super.readSelection(from: pboard, type: type)
        }
        insertText(NoteFile.normalized(text), replacementRange: selectedRange())
        return true
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let text = string as? String, NoteFile.needsNormalizing(text) {
            super.insertText(NoteFile.normalized(text), replacementRange: replacementRange)
        } else {
            super.insertText(string, replacementRange: replacementRange)
        }
    }

    /// Find shortcuts (⌘F, ⌥⌘F replace, ⌘G, ⇧⌘G, ⌘E) go straight to the find bar, so they work whether or not the
    /// app's Edit menu lists them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let action: NSTextFinder.Action? = switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], "f"): .showFindInterface
        case ([.command, .option], "f"): .showReplaceInterface
        case ([.command], "g"): .nextMatch
        case ([.command, .shift], "g"): .previousMatch
        case ([.command], "e"): .setSearchString
        default: nil
        }
        guard let action, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
        return true
    }

    /// Becomes first responder once SwiftUI has put the view in a window (New Note).
    func requestFocus() {
        focusWhenInWindow = true
        if window != nil { focusSoon() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if focusWhenInWindow, window != nil { focusSoon() }
    }

    /// Deferred so SwiftUI's own focus handling for the selection change runs first.
    private func focusSoon() {
        focusWhenInWindow = false
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// Keeps a text view and a `String` binding in sync; subclasses style the text in `restyle(_:)`.
@MainActor
class TextEditorCoordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    var text: Binding<String>
    /// The document's own undo stack, so undo never crosses files; its owner clears it when it reloads the file.
    /// Without one the window's undo manager is used and every reload clears it.
    var undoManager: UndoManager?
    /// The text last pushed to or received from the binding; anything else is an outside change.
    var lastText = ""
    /// The last character edit, in post-edit coordinates.
    var pendingEdit: (range: NSRange, delta: Int)?
    /// Set on load and when several edits arrive before a restyle (IME composition).
    var needsFullRestyle = true
    /// Beyond this many UTF-16 units the text stays plain; styling it would stall typing.
    static let maxStyledLength = 2_000_000

    init(text: Binding<String>, undoManager: UndoManager?) {
        self.text = text
        self.undoManager = undoManager
    }

    /// Reloads the text view when the binding changed from outside (the file changed on disk, or another window
    /// edited the same document), keeping the selection and scroll position. Returns whether it did.
    @discardableResult
    func update(_ text: Binding<String>, in textView: NSTextView) -> Bool {
        self.text = text
        guard text.wrappedValue != lastText else { return false }
        let selection = textView.selectedRange()
        let origin = textView.enclosingScrollView?.contentView.bounds.origin
        load(text.wrappedValue, into: textView)
        let length = (textView.string as NSString).length
        let location = min(selection.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        if let origin, let clip = textView.enclosingScrollView?.contentView {
            if let layoutManager = textView.layoutManager, let container = textView.textContainer {
                layoutManager.ensureLayout(forBoundingRect: NSRect(origin: origin, size: clip.bounds.size), in: container)
            }
            textView.scroll(origin)
        }
        return true
    }

    /// Replaces the whole text with the caret at the start, e.g. when the editor is created.
    func load(_ text: String, into textView: NSTextView) {
        lastText = text
        textView.breakUndoCoalescing()
        textView.string = text
        if undoManager == nil { textView.undoManager?.removeAllActions() }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        needsFullRestyle = true
        restyle(textView)
        textView.scrollToBeginningOfDocument(nil)
    }

    /// Called from `dismantleNSView`: drops undo steps that point at this view's text storage, which is going away
    /// while the document (and its undo manager) may live on in another window.
    func dismantle(_ textView: NSTextView) {
        textView.breakUndoCoalescing()
        if let undoManager, let storage = textView.textStorage {
            undoManager.removeAllActions(withTarget: storage)
        }
        textView.delegate = nil
        textView.textStorage?.delegate = nil
    }

    func restyle(_ textView: NSTextView) {}

    /// Selection moved; see `textViewDidChangeSelection(_:)`.
    func selectionDidChange(in textView: NSTextView) {}

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        (textView as? EditorTextView)?.refreshCurrentLine()
        selectionDidChange(in: textView)
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManager ?? view.window?.undoManager
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        if !textView.hasMarkedText() { restyle(textView) }
        (textView as? EditorTextView)?.refreshCurrentLine()
        lastText = textView.string
        text.wrappedValue = lastText
    }

    nonisolated func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            if pendingEdit != nil { needsFullRestyle = true }
            pendingEdit = (editedRange, delta)
        }
    }
}

// MARK: - Commands from the app shell

/// A handle the app shell passes to an editor to change its text through the text view,
/// so the change lands on the undo stack instead of reloading the document. Usage:
///
///     @State private var editor = TextEditorProxy()
///     CodeEditor(text: $text, language: language, proxy: editor)
///         .focusedSceneValue(\.textEditor, language.canFormat ? editor : nil)
///     // In Commands: @FocusedValue(\.textEditor) var editor
///     Button("Format") { editor?.format() }.disabled(editor == nil)
///
/// Writing to the binding instead counts as an outside change: the editor reloads and clears undo.
@MainActor @Observable
final class TextEditorProxy {
    @ObservationIgnored weak var textView: NSTextView?
    /// Language of the open file, set by the editor.
    @ObservationIgnored var language: CodeLanguage = .plainText
    /// Markdown only: whether the outline popover is open.
    var isOutlineShown = false
    /// Markdown only: whether the table size picker of the formatting bar is open.
    var isTablePickerShown = false
    /// Mirrors the document's read-only state, so menus can disable themselves.
    var isReadOnly = false

    var canFormat: Bool { language.canFormat }

    /// Markdown only: the styles at the caret, for the formatting bar.
    private(set) var activeFormat = ActiveFormat()

    func refreshFormat() {
        guard language == .markdown, let textView else { return }
        let format = MarkdownEditing.activeFormat(in: textView.string, selection: textView.selectedRange())
        if format != activeFormat { activeFormat = format }
    }

    /// Runs a Markdown formatting action on the text view as one undo step; beeps when it does not apply.
    private func perform(_ make: (String, NSRange) -> TextEdit?) {
        guard language == .markdown, let textView, textView.isEditable else { return }
        guard let edit = make(textView.string, textView.selectedRange()) else { NSSound.beep(); return }
        textView.apply(edit)
        textView.window?.makeFirstResponder(textView)
        refreshFormat()
    }

    func toggle(_ style: InlineStyle) { perform { MarkdownEditing.toggleInline(style, in: $0, selection: $1) } }
    func apply(_ style: LineStyle) { perform { MarkdownEditing.apply(style, in: $0, selection: $1) } }
    func insertLink() { perform { MarkdownEditing.link(in: $0, selection: $1) } }
    func insertCodeBlock() { perform { MarkdownEditing.codeBlock(in: $0, selection: $1) } }
    func insertRule() { perform { MarkdownEditing.horizontalRule(in: $0, selection: $1) } }
    func insertTable(rows: Int, columns: Int) { perform { MarkdownTable.insert(rows: rows, columns: columns, in: $0, selection: $1) } }
    func convertToTable() { perform { MarkdownTable.convertSelection(in: $0, selection: $1) } }
    func tableCommand(_ command: TableCommand) { perform { MarkdownTable.perform(command, in: $0, selection: $1) } }

    /// Opens or closes the outline of the headings (Markdown only).
    func toggleOutline() {
        guard language == .markdown else { return }
        isOutlineShown.toggle()
    }

    /// Puts the caret at `location` (UTF-16) and scrolls there; used by the outline.
    func reveal(location: Int) {
        (textView as? MarkdownTextView)?.reveal(location: location)
    }

    /// Replaces the whole text as one undoable step named `actionName` in the Edit menu.
    @discardableResult
    func replaceAll(with newText: String, actionName: String) -> Bool {
        guard let textView, let storage = textView.textStorage, textView.string != newText else { return false }
        let full = NSRange(location: 0, length: storage.length)
        let selection = textView.selectedRange()
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: full, replacementString: newText) else { return false }
        storage.replaceCharacters(in: full, with: newText)
        textView.didChangeText()
        textView.undoManager?.setActionName(actionName)
        let caret = NSRange(location: min(selection.location, storage.length), length: 0)
        textView.setSelectedRange(caret)
        textView.scrollRangeToVisible(caret)
        return true
    }

    /// Format: reformats the text as one undoable step. On invalid input it puts the caret
    /// at the error and shows the reason in a sheet.
    func format() {
        guard let textView, textView.isEditable else { return }
        do {
            replaceAll(with: try language.format(textView.string), actionName: L("Format"))
        } catch {
            if let error = error as? JSONFormatError {
                let caret = NSRange(location: min(error.offset, (textView.string as NSString).length), length: 0)
                textView.setSelectedRange(caret)
                textView.scrollRangeToVisible(caret)
                textView.window?.makeFirstResponder(textView)
            }
            let alert = NSAlert()
            alert.messageText = L("Couldn't format")
            alert.informativeText = error.localizedDescription
            if let window = textView.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }
}

extension FocusedValues {
    /// The focused window's editor, published by the shell only when its file can be formatted.
    var textEditor: TextEditorProxy? {
        get { self[TextEditorKey.self] }
        set { self[TextEditorKey.self] = newValue }
    }

    private struct TextEditorKey: FocusedValueKey {
        typealias Value = TextEditorProxy
    }
}
