import Foundation

public enum TableAlignment: Equatable, Sendable { case none, left, center, right }

/// Structure edits of the table the caret is in (Format menu).
public enum TableCommand: Equatable, Sendable {
    case addRow(above: Bool)
    case addColumn(before: Bool)
    case deleteRow
    case deleteColumn
    case align(TableAlignment)
}

/// GFM pipe tables: detection (shared with the styler) and the editing helpers of the Markdown editor, as pure
/// functions of the text and the selection. See docs/format.md ("Editing helpers").
public enum MarkdownTable {
    /// One line of a table. Offsets are in the scanned unit array.
    struct Row {
        var start: Int
        /// First non-blank unit (after the indentation).
        var first: Int
        /// End of the line without CR / LF.
        var end: Int
        /// Start of the next line (one past the LF).
        var next: Int
        /// Trimmed content of each cell.
        var cells: [NSRange]
        /// Structural pipes (not escaped, not inside a code span).
        var pipes: [Int]
        var leading: Bool
    }

    private static func lineBounds(at location: Int, in ns: NSString) -> (start: Int, end: Int) { MarkdownEditing.lineBounds(at: location, in: ns) }
    private static func units(_ ns: NSString, _ range: NSRange) -> [UInt16] { MarkdownEditing.units(ns, range) }
    private static func isInsideCodeBlock(_ location: Int, in text: String) -> Bool { MarkdownEditing.isInsideCodeBlock(location, in: text) }
    private static func insertBlock(_ block: String, caretAt: Int, in text: String, selection: NSRange) -> TextEdit? {
        MarkdownEditing.insertBlock(block, caretAt: caretAt, in: text, selection: selection)
    }

    private static func isBlankText(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" } }

    // MARK: Parsing

    static func row(_ s: [UInt16], from start: Int) -> Row {
        var nl = start
        while nl < s.count, s[nl] != 0x0A { nl += 1 }
        let end = nl > start && s[nl - 1] == 0x0D ? nl - 1 : nl
        var i = start
        while i < end, s[i] == 0x20 || s[i] == 0x09 { i += 1 }
        let first = i
        var pipes: [Int] = []
        while i < end {
            switch s[i] {
            case 0x5C:
                i += 2
            case 0x60:
                var j = i
                while j < end, s[j] == 0x60 { j += 1 }
                var k = j, close = -1
                while k < end {
                    guard s[k] == 0x60 else { k += 1; continue }
                    var l = k
                    while l < end, s[l] == 0x60 { l += 1 }
                    if l - k == j - i { close = l; break }
                    k = l
                }
                i = close >= 0 ? close : j
            case 0x7C:
                pipes.append(i)
                i += 1
            default:
                i += 1
            }
        }
        var cuts: [(Int, Int)] = []
        var from = first
        for p in pipes { cuts.append((from, p)); from = p + 1 }
        cuts.append((from, end))
        let leading = pipes.first == first
        if leading { cuts.removeFirst() }
        func blank(_ cut: (Int, Int)) -> Bool { (cut.0..<cut.1).allSatisfy { s[$0] == 0x20 || s[$0] == 0x09 } }
        if !pipes.isEmpty, let last = cuts.last, blank(last) { cuts.removeLast() }
        let cells = cuts.map { cut -> NSRange in
            var a = cut.0, b = cut.1
            while a < b, s[a] == 0x20 || s[a] == 0x09 { a += 1 }
            while b > a, s[b - 1] == 0x20 || s[b - 1] == 0x09 { b -= 1 }
            return NSRange(location: a, length: b - a)
        }
        return Row(start: start, first: first, end: end, next: nl + 1, cells: cells, pipes: pipes, leading: leading)
    }

    private static func alignment(_ s: [UInt16], _ cell: NSRange) -> TableAlignment? {
        guard cell.length > 0 else { return nil }
        let a = cell.location, b = NSMaxRange(cell)
        let left = s[a] == 0x3A, right = s[b - 1] == 0x3A && b - a > (left ? 1 : 0)
        let dashes = s[(a + (left ? 1 : 0))..<(b - (right ? 1 : 0))]
        guard !dashes.isEmpty, dashes.allSatisfy({ $0 == 0x2D }) else { return nil }
        return left && right ? .center : left ? .left : right ? .right : TableAlignment.none
    }

    private static func isDelimiter(_ row: Row, _ s: [UInt16]) -> Bool {
        !row.pipes.isEmpty && !row.cells.isEmpty && row.cells.allSatisfy { alignment(s, $0) != nil }
    }

    /// The rows of the table whose header line starts at `start` (header, delimiter row, body rows), or `nil`.
    /// The header needs a pipe and as many cells as the delimiter row below it; body rows are the following lines
    /// with a pipe, up to the first blank line or line without one.
    static func rows(in s: [UInt16], at start: Int) -> [Row]? {
        guard start < s.count else { return nil }
        let header = row(s, from: start)
        guard !header.pipes.isEmpty, header.first - start <= 3, s[start..<header.first].allSatisfy({ $0 == 0x20 }),
              header.next <= s.count else { return nil }
        let delimiter = row(s, from: header.next)
        guard delimiter.cells.count == header.cells.count, isDelimiter(delimiter, s) else { return nil }
        var result = [header, delimiter]
        var pos = delimiter.next
        while pos < s.count {
            let body = row(s, from: pos)
            guard !body.pipes.isEmpty else { break }
            result.append(body)
            pos = body.next
        }
        return result
    }

    // MARK: Layout

    /// Columns taken by a cell's text: wide East Asian characters and emoji count 2, everything else 1.
    static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { total, ch in
            let scalars = ch.unicodeScalars
            guard let v = scalars.first?.value else { return total }
            if scalars.count > 1, scalars.contains(where: { $0.value == 0xFE0F || $0.value == 0x200D }) { return total + 2 }
            switch v {
            case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
                 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
                 0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
                return total + 2
            default:
                return total + 1
            }
        }
    }

    private struct Model {
        var header: [String]
        var aligns: [TableAlignment]
        var body: [[String]]
        var columns: Int { header.count }

        mutating func normalize() {
            let n = max(header.count, aligns.count, body.map(\.count).max() ?? 0, 1)
            header += Array(repeating: "", count: n - header.count)
            aligns += Array(repeating: .none, count: n - aligns.count)
            body = body.map { $0 + Array(repeating: "", count: n - $0.count) }
        }

        func text(row: Int, col: Int) -> String { row == 0 ? header[col] : body[row - 2][col] }
    }

    /// The table as aligned source lines, plus where each cell's text starts (UTF-16 offset in `text`);
    /// indexed by rendered row (0 header, 1 delimiter, 2... body) and column.
    private static func render(_ m: Model, eol: String) -> (text: String, starts: [[Int]]) {
        let widths = (0..<m.columns).map { c in
            max(3, displayWidth(m.header[c]), m.body.map { displayWidth($0[c]) }.max() ?? 0)
        }
        var lines: [String] = []
        var starts: [[Int]] = []
        var offset = 0
        func add(_ cells: [String], delimiter: Bool) {
            var line = "|"
            var rowStarts: [Int] = []
            for c in 0..<m.columns {
                line += " "
                let w = widths[c]
                let content: String
                var left = 0
                if delimiter {
                    let dashes = { (n: Int) in String(repeating: "-", count: n) }
                    switch m.aligns[c] {
                    case .none: content = dashes(w)
                    case .left: content = ":" + dashes(w - 1)
                    case .right: content = dashes(w - 1) + ":"
                    case .center: content = ":" + dashes(w - 2) + ":"
                    }
                } else {
                    let pad = w - displayWidth(cells[c])
                    switch m.aligns[c] {
                    case .right: left = pad
                    case .center: left = pad / 2
                    default: left = 0
                    }
                    content = String(repeating: " ", count: left) + cells[c] + String(repeating: " ", count: pad - left)
                }
                rowStarts.append(offset + line.utf16.count + left)
                line += content + " |"
            }
            lines.append(line)
            starts.append(rowStarts)
            offset += line.utf16.count + eol.utf16.count
        }
        add(m.header, delimiter: false)
        add([], delimiter: true)
        for row in m.body { add(row, delimiter: false) }
        return (lines.joined(separator: eol), starts)
    }

    // MARK: Locating

    private struct Located {
        let base: Int
        let units: [UInt16]
        let rows: [Row]
        let eol: String
        let rowIndex: Int
        let col: Int
        let offset: Int

        var range: NSRange { NSRange(location: base + rows[0].start, length: rows[rows.count - 1].end - rows[0].start) }
        var currentText: String { String(decoding: units[rows[0].start..<rows[rows.count - 1].end], as: UTF16.self) }

        func text(_ cell: NSRange) -> String { String(decoding: units[cell.location..<NSMaxRange(cell)], as: UTF16.self) }

        var model: Model {
            var m = Model(header: rows[0].cells.map(text),
                          aligns: rows[1].cells.map { MarkdownTable.alignment(units, $0) ?? .none },
                          body: rows.dropFirst(2).map { $0.cells.map(text) })
            m.normalize()
            return m
        }
    }

    private static func locate(in text: String, at caret: Int) -> Located? {
        let ns = text as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        func hasPipe(_ b: (start: Int, end: Int)) -> Bool {
            b.end > b.start && ns.range(of: "|", options: [], range: NSRange(location: b.start, length: b.end - b.start)).location != NSNotFound
        }
        var top = lineBounds(at: caret, in: ns), bottom = top
        guard hasPipe(top) else { return nil }
        while top.start > 0 {
            let previous = lineBounds(at: top.start - 1, in: ns)
            guard hasPipe(previous) else { break }
            top = previous
        }
        while bottom.end < ns.length {
            let following = lineBounds(at: bottom.end + 1, in: ns)
            guard hasPipe(following) else { break }
            bottom = following
        }
        let base = top.start
        let w = units(ns, NSRange(location: base, length: bottom.end - base))
        let rel = caret - base
        var pos = 0
        while pos < w.count {
            if let rows = rows(in: w, at: pos) {
                if rel >= rows[0].start, rel <= rows[rows.count - 1].end {
                    guard !isInsideCodeBlock(base + rows[0].start, in: text) else { return nil }
                    let index = rows.firstIndex { rel <= $0.end } ?? rows.count - 1
                    let row = rows[index]
                    let col = max(0, min(row.pipes.filter { $0 < rel }.count - (row.leading ? 1 : 0), row.cells.count - 1))
                    var offset = 0
                    if col < row.cells.count { offset = min(max(rel - row.cells[col].location, 0), row.cells[col].length) }
                    let crlf = rows[0].end < w.count && w[rows[0].end] == 0x0D
                    return Located(base: base, units: w, rows: rows, eol: crlf ? "\r\n" : "\n", rowIndex: index, col: col, offset: offset)
                }
                pos = rows[rows.count - 1].next
            } else {
                while pos < w.count, w[pos] != 0x0A { pos += 1 }
                pos += 1
            }
        }
        return nil
    }

    /// Where the selection goes after an edit: inside a cell (`offset` into its text) or over its whole text.
    private enum Place { case caret(Int), content }

    private static func edit(_ l: Located, _ m: Model, row: Int, col: Int, place: Place) -> TextEdit {
        let (replacement, starts) = render(m, eol: l.eol)
        let cell = m.text(row: row, col: col)
        let length = cell.utf16.count
        let selection: NSRange
        switch place {
        case .caret(let offset): selection = NSRange(location: l.range.location + starts[row][col] + min(offset, length), length: 0)
        case .content: selection = NSRange(location: l.range.location + starts[row][col], length: length)
        }
        if replacement == l.currentText {
            return TextEdit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
        }
        return TextEdit(range: l.range, replacement: replacement, selection: selection)
    }

    private static func inOneLine(_ selection: NSRange, _ text: String) -> Bool {
        let ns = text as NSString
        guard selection.length > 0 else { return true }
        return ns.range(of: "\n", options: [], range: selection).location == NSNotFound
    }

    // MARK: Editing

    /// Tab / Shift-Tab: moves to the next / previous cell (selecting its text) and re-aligns the table; Tab in the
    /// last cell adds a row. `nil` outside a table, in the delimiter row, or on Shift-Tab in the first cell.
    public static func tab(in text: String, selection: NSRange, backward: Bool) -> TextEdit? {
        guard inOneLine(selection, text), let l = locate(in: text, at: selection.location), l.rowIndex != 1 else { return nil }
        var m = l.model
        let columns = m.columns
        let current = (l.rowIndex == 0 ? 0 : l.rowIndex - 1) * columns + min(l.col, columns - 1)
        let target = current + (backward ? -1 : 1)
        guard target >= 0 else { return nil }
        if target >= (m.body.count + 1) * columns { m.body.append(Array(repeating: "", count: columns)) }
        let row = target / columns
        return edit(l, m, row: row == 0 ? 0 : row + 1, col: target % columns, place: .content)
    }

    /// Return inside a row adds an empty row below it (below the header for the header row) and puts the caret in
    /// its first cell; Return in an empty last row removes it and leaves the table for a new line.
    public static func newline(in text: String, selection: NSRange) -> TextEdit? {
        guard selection.length == 0, let l = locate(in: text, at: selection.location), l.rowIndex != 1 else { return nil }
        var m = l.model
        let empty = Array(repeating: "", count: m.columns)
        if l.rowIndex >= 2, l.rowIndex == l.rows.count - 1, m.body[l.rowIndex - 2].allSatisfy(\.isEmpty) {
            m.body.removeLast()
            let table = render(m, eol: l.eol).text
            let at = l.range.location + table.utf16.count + l.eol.utf16.count
            return TextEdit(range: l.range, replacement: table + l.eol, selection: NSRange(location: at, length: 0))
        }
        let index = l.rowIndex == 0 ? 0 : l.rowIndex - 1
        m.body.insert(empty, at: index)
        return edit(l, m, row: index + 2, col: 0, place: .caret(0))
    }

    /// Format menu: rows, columns and column alignment of the table the caret is in. `nil` when that does not
    /// apply (outside a table, a row command on the header, the last column).
    public static func perform(_ command: TableCommand, in text: String, selection: NSRange) -> TextEdit? {
        guard inOneLine(selection, text), let l = locate(in: text, at: selection.location) else { return nil }
        var m = l.model
        let col = min(l.col, m.columns - 1)
        let row = l.rowIndex
        switch command {
        case .addRow(let above):
            if above && row <= 1 { return nil }
            let index = above ? row - 2 : (row <= 1 ? 0 : row - 1)
            m.body.insert(Array(repeating: "", count: m.columns), at: index)
            return edit(l, m, row: index + 2, col: col, place: .caret(0))
        case .addColumn(let before):
            let index = before ? col : col + 1
            m.header.insert("", at: index)
            m.aligns.insert(.none, at: index)
            m.body = m.body.map { var r = $0; r.insert("", at: index); return r }
            return edit(l, m, row: row == 1 ? 0 : row, col: index, place: .caret(0))
        case .deleteRow:
            guard row >= 2 else { return nil }
            m.body.remove(at: row - 2)
            let target = min(row - 2, m.body.count - 1)
            return edit(l, m, row: target < 0 ? 0 : target + 2, col: col, place: .caret(0))
        case .deleteColumn:
            guard m.columns > 1 else { return nil }
            m.header.remove(at: col)
            m.aligns.remove(at: col)
            m.body = m.body.map { var r = $0; r.remove(at: col); return r }
            return edit(l, m, row: row == 1 ? 0 : row, col: min(col, m.columns - 1), place: .caret(0))
        case .align(let alignment):
            m.aligns[col] = alignment
            return edit(l, m, row: row == 1 ? 0 : row, col: col, place: .caret(row == l.rowIndex ? l.offset : 0))
        }
    }

    // MARK: Creating

    /// A table with `rows` rows including the header and `columns` empty columns, on lines of its own after the
    /// line the selection ends in; the caret goes into the first header cell.
    public static func insert(rows: Int, columns: Int, in text: String, selection: NSRange) -> TextEdit? {
        let n = min(max(columns, 1), 20), r = min(max(rows, 1), 200)
        let m = Model(header: Array(repeating: "", count: n), aligns: Array(repeating: .none, count: n),
                      body: Array(repeating: Array(repeating: "", count: n), count: r - 1))
        let (table, starts) = render(m, eol: "\n")
        return insertBlock(table, caretAt: starts[0][0], in: text, selection: selection)
    }

    /// Turns the selected lines (tab-separated, else comma-separated with optional quotes) into a table whose first
    /// line is the header. `nil` when there is no separator, fewer than two columns, or the lines are in code.
    public static func convertSelection(in text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        guard let lines = MarkdownEditing.parsedLines(for: selection, in: ns),
              !isInsideCodeBlock(lines[0].start, in: text) else { return nil }
        let texts: [String] = lines.map { String(decoding: $0.units[0..<$0.info.end], as: UTF16.self) }
        let raw: [String] = texts.filter { !isBlankText($0) }
        guard !raw.isEmpty else { return nil }
        let tabs = raw.contains { $0.contains("\t") }
        guard tabs || raw.contains(where: { $0.contains(",") }) else { return nil }
        func split(_ line: String) -> [String] {
            let fields = tabs ? line.components(separatedBy: "\t") : csvFields(line)
            return fields.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "\\|") }
        }
        let cells = raw.map(split)
        guard (cells.map(\.count).max() ?? 0) >= 2 else { return nil }
        var m = Model(header: cells[0], aligns: [], body: Array(cells.dropFirst()))
        m.normalize()
        let crlf = lines[0].info.end < lines[0].units.count
        let eol = crlf ? "\r\n" : "\n"
        var (table, starts) = render(m, eol: eol)
        let from = lines[0].start
        var to = lines[lines.count - 1].end
        if to > from, ns.character(at: to - 1) == 0x0D { to -= 1 }
        var lead = ""
        if from > 0 {
            let previous = lineBounds(at: from - 1, in: ns)
            let before = ns.substring(with: NSRange(location: previous.start, length: previous.end - previous.start))
            if !isBlankText(before) { lead = eol }
        }
        if to < ns.length {
            let following = lineBounds(at: to + 1, in: ns)
            let after = ns.substring(with: NSRange(location: following.start, length: following.end - following.start))
            if !isBlankText(after) { table += eol }
        }
        let caret = from + lead.utf16.count + starts[0][0]
        return TextEdit(range: NSRange(location: from, length: to - from), replacement: lead + table,
                        selection: NSRange(location: caret, length: m.header[0].utf16.count))
    }

    private static func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var chars = Array(line)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { current.append("\""); chars.removeFirst() } else { quoted = false }
                } else {
                    current.append(c)
                }
            } else if c == "\"" && current.trimmingCharacters(in: .whitespaces).isEmpty {
                quoted = true
                current = ""
            } else if c == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        fields.append(current)
        return fields
    }
}
