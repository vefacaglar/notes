import AppKit

/// How a rendered pipe table is laid out: what the text view needs to draw its grid behind the text.
struct TableGrid: Equatable {
    /// The table's lines through the last line break.
    var range: NSRange
    /// Width of all columns with their padding; the table is rendered only if the container is at least this wide.
    var naturalWidth: CGFloat
    var rendered: Bool
    /// Header row first, then the body rows: each line without its break.
    var rows: [NSRange]
    var delimiter: NSRange
    /// Column boundaries from the left of the text, `edges[0]` being 0.
    var edges: [CGFloat]

    /// Vertical space between the text of two rows; the lines run through its middle.
    static let rowGap: CGFloat = 6

    /// The same layout after the table moved to `range` (text was inserted or removed above it).
    func moved(to range: NSRange) -> TableGrid {
        let delta = range.location - self.range.location
        func shift(_ r: NSRange) -> NSRange { NSRange(location: r.location + delta, length: r.length) }
        var grid = self
        grid.range = range
        grid.rows = rows.map(shift)
        grid.delimiter = shift(delimiter)
        return grid
    }
}

extension MarkdownTextView {
    /// Draws the grid of every rendered table that intersects `dirty`: a header background, then thin lines between
    /// the rows and columns and around the table. Called under the text, like the code bands.
    func drawTables(in dirty: NSRect) {
        guard !tableGrids.isEmpty, let layout = layoutManager, let container = textContainer else { return }
        let origin = textContainerOrigin
        let probe = dirty.insetBy(dx: 0, dy: -40).offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: probe, in: container)
        guard glyphs.length > 0 else { return }
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var lo = 0, hi = tableGrids.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(tableGrids[mid].range) <= chars.location { lo = mid + 1 } else { hi = mid }
        }
        let length = textStorage?.length ?? 0
        let scale = window?.backingScaleFactor ?? 2
        let thickness = 1 / scale
        for grid in tableGrids[lo...] {
            if grid.range.location >= NSMaxRange(chars) { break }
            guard NSMaxRange(grid.range) <= length, let first = grid.rows.first, let last = grid.rows.last,
                  let head = lineSpan(of: first), let tail = lineSpan(of: last) else { continue }
            let left = origin.x + (grid.edges.first ?? 0)
            let right = origin.x + (grid.edges.last ?? 0)
            let top = head.minY - TableGrid.rowGap / 2, bottom = tail.maxY + TableGrid.rowGap / 2
            let table = NSRect(x: left, y: top, width: right - left, height: bottom - top)
            guard table.insetBy(dx: -2, dy: -2).intersects(dirty) else { continue }
            // Only the row boundaries inside the dirty rect: bisect the rows by position.
            var lo = 0, hi = grid.rows.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if let span = lineSpan(of: grid.rows[mid]), span.maxY + TableGrid.rowGap < dirty.minY { lo = mid + 1 } else { hi = mid }
            }
            var boundaries: [(index: Int, y: CGFloat)] = []
            var previous = lo > 0 ? lineSpan(of: grid.rows[lo - 1]) : nil
            for index in max(lo, 1)..<max(grid.rows.count, 1) {
                guard let span = lineSpan(of: grid.rows[index]) else { break }
                if let previous { boundaries.append((index, (previous.maxY + span.minY) / 2)) }
                previous = span
                if span.minY > dirty.maxY { break }
            }
            guard let line = tableLineColor else { continue }
            let radius: CGFloat = 6
            let outline = NSBezierPath(roundedRect: table.insetBy(dx: thickness / 2, dy: thickness / 2), xRadius: radius, yRadius: radius)
            outline.lineWidth = thickness * 2
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            // Thin lines between the rows, a stronger one under the header.
            for (index, y) in boundaries {
                let strong = index == 1
                (strong ? line : line.withAlphaComponent(line.alphaComponent * 0.5)).setFill()
                backingAligned(NSRect(x: left, y: y, width: right - left, height: strong ? thickness * 2 : thickness)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            line.setStroke()
            outline.stroke()
        }
    }

    /// Vertical extent of a line's text (all its fragments, without the paragraph spacing), in view coordinates.
    private func lineSpan(of line: NSRange) -> (minY: CGFloat, maxY: CGFloat)? {
        guard let layout = layoutManager else { return nil }
        let at = line.length > 0 ? line : NSRange(location: line.location, length: 0)
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: at.location, length: max(at.length, 1)), actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let top = layout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let bottom = layout.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        let y = textContainerOrigin.y
        return (top.minY + y, bottom.maxY + y)
    }

    private func backingAligned(_ rect: NSRect) -> NSRect {
        backingAlignedRect(rect, options: .alignAllEdgesNearest)
    }
}
