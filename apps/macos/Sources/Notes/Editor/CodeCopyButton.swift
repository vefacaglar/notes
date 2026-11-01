import AppKit
import NotesCore

/// The icon button over the top-right corner of a fenced code block: it copies the block's code. A subview of the
/// text view, so it is not part of the text and doesn't move the layout.
final class CopyCodeButton: NSButton {
    var tint: NSColor = .secondaryLabelColor {
        didSet { if tint != oldValue { refresh() } }
    }
    var onCopy: (() -> Void)?
    private var isHovered = false { didSet { refresh() } }
    private var isCopied = false { didSet { refresh() } }
    private var resetToken = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        refusesFirstResponder = true
        wantsLayer = true
        layer?.cornerRadius = 4
        target = self
        action = #selector(clicked)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    private func refresh() {
        let label = isCopied ? L("Copied") : L("Copy Code")
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        image = NSImage(systemSymbolName: isCopied ? "checkmark" : "doc.on.doc", accessibilityDescription: label)?
            .withSymbolConfiguration(configuration)
        contentTintColor = tint
        toolTip = L("Copy Code")
        setAccessibilityLabel(label)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isHovered ? tint.withAlphaComponent(0.15).cgColor : nil
        }
    }

    @objc private func clicked() { onCopy?() }

    /// Shows the check mark for 1.5 seconds.
    func flashCopied() {
        isCopied = true
        resetToken += 1
        let token = resetToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated {
                if let self, self.resetToken == token { self.isCopied = false }
            }
        }
    }
}

extension MarkdownTextView {
    private static let copyButtonSize: CGFloat = 22

    /// Shows the copy button on the code block under the mouse, or hides it. Cheap enough to call on every layout
    /// change, scroll and mouse move.
    func updateCopyButton() {
        guard let window, !codeBlocks.isEmpty, let layout = layoutManager, let container = textContainer,
              layout.numberOfGlyphs > 0 else { return hideCopyButton() }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard visibleRect.contains(point) else { return hideCopyButton() }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let index = layout.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        var lo = 0, hi = codeBlocks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(codeBlocks[mid]) <= index { lo = mid + 1 } else { hi = mid }
        }
        guard lo < codeBlocks.count, NSLocationInRange(index, codeBlocks[lo]) || index == NSMaxRange(codeBlocks[lo]),
              NSMaxRange(codeBlocks[lo]) <= (textStorage?.length ?? 0), let band = lineBand(forCharacters: codeBlocks[lo]),
              band.contains(point) else { return hideCopyButton() }
        let button = copyButton ?? makeCopyButton()
        let size = Self.copyButtonSize
        let frame = NSRect(x: band.maxX - 8 - size, y: band.minY + 3, width: size, height: size)
        if button.frame != frame { button.frame = frame }
        button.tint = copyButtonColor
        hoveredCodeBlock = codeBlocks[lo]
        if button.isHidden { button.isHidden = false }
    }

    func hideCopyButton() {
        hoveredCodeBlock = nil
        if let copyButton, !copyButton.isHidden { copyButton.isHidden = true }
    }

    private func makeCopyButton() -> CopyCodeButton {
        let button = CopyCodeButton(frame: .zero)
        button.onCopy = { [weak self, weak button] in
            guard let self, let block = self.hoveredCodeBlock else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(MarkdownCodeBlock.code(in: self.string, block: block), forType: .string)
            button?.flashCopied()
        }
        addSubview(button)
        copyButton = button
        return button
    }
}
