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
        selectionDidChange(in: textView)
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManager ?? view.window?.undoManager
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        if !textView.hasMarkedText() { restyle(textView) }
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
///     Button("Biçimlendir") { editor?.format() }.disabled(editor == nil)
///
/// Writing to the binding instead counts as an outside change: the editor reloads and clears undo.
@MainActor
final class TextEditorProxy {
    weak var textView: NSTextView?
    /// Language of the open file, set by the editor.
    var language: CodeLanguage = .plainText

    var canFormat: Bool { language.canFormat }

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

    /// "Biçimlendir": reformats the text as one undoable step. On invalid input it puts the caret
    /// at the error and shows the reason in a sheet.
    func format() {
        guard let textView else { return }
        do {
            replaceAll(with: try language.format(textView.string), actionName: "Biçimlendir")
        } catch {
            if let error = error as? JSONFormatError {
                let caret = NSRange(location: min(error.offset, (textView.string as NSString).length), length: 0)
                textView.setSelectedRange(caret)
                textView.scrollRangeToVisible(caret)
                textView.window?.makeFirstResponder(textView)
            }
            let alert = NSAlert()
            alert.messageText = "Biçimlendirilemedi"
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
