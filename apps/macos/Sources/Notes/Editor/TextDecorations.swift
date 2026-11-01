import AppKit

/// A marker character the text view draws itself while Markdown syntax is hidden: the glyph stays in the text (same
/// width, clear colour), so nothing moves when it is revealed.
struct TextDecoration: Equatable {
    enum Kind { case bullet, quoteBar, rule }
    /// The marker's range (a bullet and a quote's `>` start at its first character; a rule is the whole line).
    var range: NSRange
    var kind: Kind
}

extension MarkdownTextView {
    /// "•" over a `-`/`*`/`+`, a thin bar over a quote's `>` (one per level), a full-width line over `---`.
    func drawDecorations(in dirty: NSRect) {
        guard !decorations.isEmpty, let layout = layoutManager, let container = textContainer, let storage = textStorage else { return }
        let origin = textContainerOrigin
        let probe = dirty.insetBy(dx: 0, dy: -20).offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: probe, in: container)
        guard glyphs.length > 0 else { return }
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var lo = 0, hi = decorations.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(decorations[mid].range) <= chars.location { lo = mid + 1 } else { hi = mid }
        }
        let thickness = 1 / (window?.backingScaleFactor ?? 2)
        for item in decorations[lo...] {
            if item.range.location >= NSMaxRange(chars) { break }
            guard NSMaxRange(item.range) <= storage.length else { continue }
            let glyph = layout.glyphIndexForCharacter(at: item.range.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let position = layout.location(forGlyphAt: glyph)
            let x = origin.x + fragment.minX + position.x
            let top = origin.y + fragment.minY
            let dim: CGFloat = focusParagraph.map { NSLocationInRange(item.range.location, $0) ? 1 : 0.3 } ?? 1
            let color = (decorationColor ?? .secondaryLabelColor).withAlphaComponent((decorationColor ?? .secondaryLabelColor).alphaComponent * dim)
            switch item.kind {
            case .bullet:
                guard let font = storage.attribute(.font, at: item.range.location, effectiveRange: nil) as? NSFont else { continue }
                let width = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).width
                let bullet = "•" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: copyButtonColor.withAlphaComponent(copyButtonColor.alphaComponent * dim)]
                let size = bullet.size(withAttributes: attributes)
                guard NSRect(x: x, y: top, width: width, height: fragment.height).intersects(dirty) else { continue }
                bullet.draw(at: NSPoint(x: x + (width - size.width) / 2, y: top + position.y - font.ascender), withAttributes: attributes)
            case .quoteBar:
                let bar = NSRect(x: x + 1, y: top, width: 2, height: fragment.height + 4)
                guard bar.intersects(dirty) else { continue }
                color.setFill()
                backingAlignedRect(bar, options: .alignAllEdgesNearest).fill()
            case .rule:
                let y = top + fragment.height / 2
                let line = NSRect(x: origin.x, y: y, width: container.size.width - 2 * container.lineFragmentPadding, height: thickness * 2)
                guard line.insetBy(dx: 0, dy: -2).intersects(dirty) else { continue }
                color.setFill()
                backingAlignedRect(line, options: .alignAllEdgesNearest).fill()
            }
        }
    }
}
