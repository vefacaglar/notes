import Foundation

/// One replacement in a text, in UTF-16 coordinates, plus where the selection goes afterwards (`nil`: leave it to the
/// text view, which keeps it consistent with the edit).
public struct TextEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange?

    public init(range: NSRange, replacement: String, selection: NSRange? = nil) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

/// Editing helpers of the Markdown editor as pure functions of the text and the selection: list continuation,
/// list indentation, link insertion and task toggling. See docs/format.md ("Editing helpers").
public enum MarkdownEditing {
    // MARK: Return

    /// Return in a list item or blockquote: continues the list (`- `, `* `, `+ `, `1. ` counting up, `- [ ] ` for
    /// tasks, `> ` for quotes) with the same indentation, or ends it when the item is empty. `nil` means the plain
    /// newline applies (selection not empty, caret not after the marker, not a list line, inside a fenced code block).
    public static func newline(in text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        guard selection.length == 0, selection.location <= ns.length else { return nil }
        let caret = selection.location
        let line = lineBounds(at: caret, in: ns)
        let info = LineInfo(Array(ns.substring(with: NSRange(location: line.start, length: line.end - line.start)).utf16))
        guard info.hasQuote || info.marker != nil else { return nil }
        let rel = caret - line.start
        let quotePart = info.quotePart

        if let marker = info.marker {
            guard info.markerEnd < info.end, rel >= info.markerEnd, rel >= info.contentStart || info.isEmpty else { return nil }
            guard !isInsideCodeBlock(line.start, in: text) else { return nil }
            if info.isEmpty {
                let replacement = info.hasQuote ? quotePart : ""
                return TextEdit(range: NSRange(location: line.start, length: info.end), replacement: replacement,
                                selection: NSRange(location: line.start + (replacement as NSString).length, length: 0))
            }
            let next: String
            switch marker {
            case .bullet(let c): next = String(decoding: [c], as: UTF16.self)
            case .ordered(let number, let delimiter): next = "\(number + 1)" + String(decoding: [delimiter], as: UTF16.self)
            }
            let box = info.task == nil ? "" : "[ ] "
            let insert = "\n" + quotePart + info.indent + next + " " + box
            return TextEdit(range: selection, replacement: insert,
                            selection: NSRange(location: caret + (insert as NSString).length, length: 0))
        }

        guard rel >= info.quoteEnd, !isInsideCodeBlock(line.start, in: text) else { return nil }
        if info.quoteContentIsEmpty {
            return TextEdit(range: NSRange(location: line.start, length: info.end), replacement: "",
                            selection: NSRange(location: line.start, length: 0))
        }
        let insert = "\n" + quotePart
        return TextEdit(range: selection, replacement: insert,
                        selection: NSRange(location: caret + (insert as NSString).length, length: 0))
    }

    // MARK: Tab

    /// Tab / Shift-Tab on list item lines (every line the selection touches must be one): adds or removes one level
    /// of indentation, 2 spaces for bullets and tasks, the marker's width for numbered items (`1. ` = 3). `nil`
    /// when the lines are not all list items or there is nothing to remove, so the editor's normal Tab applies.
    public static func indent(in text: String, selection: NSRange, outdent: Bool) -> TextEdit? {
        let ns = text as NSString
        guard selection.location >= 0, NSMaxRange(selection) <= ns.length else { return nil }
        var lines: [(start: Int, end: Int, info: LineInfo)] = []
        var cursor = lineBounds(at: selection.location, in: ns).start
        var stop = NSMaxRange(selection)
        if selection.length > 0, stop > 0, ns.character(at: stop - 1) == 0x0A { stop -= 1 }
        while true {
            let bounds = lineBounds(at: cursor, in: ns)
            let info = LineInfo(Array(ns.substring(with: NSRange(location: bounds.start, length: bounds.end - bounds.start)).utf16))
            guard info.marker != nil else { return nil }
            lines.append((bounds.start, bounds.end, info))
            if bounds.end >= stop || bounds.end >= ns.length { break }
            cursor = bounds.end + 1
        }
        guard !isInsideCodeBlock(lines[0].start, in: text) else { return nil }

        // Per line: where the change happens, how many units are removed, what is inserted.
        var changes: [(at: Int, removed: Int, inserted: String)] = []
        for line in lines {
            let at = line.start + line.info.quoteEnd
            let width = line.info.indentWidth
            if outdent {
                let indent = Array(line.info.indent.utf16)
                let removed = indent.first == 0x09 ? 1 : min(indent.prefix { $0 == 0x20 }.count, width)
                if removed > 0 { changes.append((at, removed, "")) }
            } else {
                changes.append((at, 0, String(repeating: " ", count: width)))
            }
        }
        guard let first = changes.first else { return nil }

        let from = first.at, to = lines[lines.count - 1].end
        var result = ns.substring(with: NSRange(location: from, length: to - from))
        for change in changes.reversed() {
            let r = NSRange(location: change.at - from, length: change.removed)
            result = (result as NSString).replacingCharacters(in: r, with: change.inserted)
        }

        func map(_ p: Int) -> Int {
            var offset = 0
            for change in changes {
                if p >= change.at + change.removed {
                    offset += (change.inserted as NSString).length - change.removed
                } else if p > change.at {
                    return change.at + offset
                } else {
                    break
                }
            }
            return p + offset
        }
        let newStart = map(selection.location)
        let newEnd = selection.length == 0 ? newStart : map(NSMaxRange(selection))
        return TextEdit(range: NSRange(location: from, length: to - from), replacement: result,
                        selection: NSRange(location: newStart, length: newEnd - newStart))
    }

    // MARK: Links

    /// ⌘K: `[selection](url)` with the caret in the parentheses; an empty selection gives `[](url)` with the caret in
    /// the brackets, and a selected web address becomes the URL of an empty text, caret in the brackets.
    public static func link(in text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        guard selection.location >= 0, NSMaxRange(selection) <= ns.length else { return nil }
        let chosen = ns.substring(with: selection)
        let length = (chosen as NSString).length
        if length == 0 {
            return TextEdit(range: selection, replacement: "[]()", selection: NSRange(location: selection.location + 1, length: 0))
        }
        if case .web(let url)? = NoteLinks.classify(chosen), ["http", "https"].contains(url.scheme?.lowercased()), !chosen.contains(where: \.isWhitespace) {
            return TextEdit(range: selection, replacement: "[](\(chosen))", selection: NSRange(location: selection.location + 1, length: 0))
        }
        return TextEdit(range: selection, replacement: "[\(chosen)]()",
                        selection: NSRange(location: selection.location + length + 3, length: 0))
    }

    // MARK: Tasks

    /// A click at UTF-16 offset `index` on a task item's `[ ]` / `[x]` box: the edit that flips it. `nil` when the
    /// index is not on a box (boxes inside fenced code are not task items).
    public static func toggleTask(in text: String, at index: Int) -> TextEdit? {
        let ns = text as NSString
        guard index >= 0, index < ns.length else { return nil }
        let line = lineBounds(at: index, in: ns)
        let info = LineInfo(Array(ns.substring(with: NSRange(location: line.start, length: line.end - line.start)).utf16))
        guard let checked = info.task else { return nil }
        let box = line.start + info.boxStart
        guard index >= box, index < box + 3, !isInsideCodeBlock(line.start, in: text) else { return nil }
        return TextEdit(range: NSRange(location: box + 1, length: 1), replacement: checked ? " " : "x")
    }

    // MARK: Line parsing

    /// Range of the line holding `location`, without its LF (lines end at LF only, like the scanner).
    private static func lineBounds(at location: Int, in ns: NSString) -> (start: Int, end: Int) {
        var start = min(max(location, 0), ns.length), end = start
        while start > 0 && ns.character(at: start - 1) != 0x0A { start -= 1 }
        while end < ns.length && ns.character(at: end) != 0x0A { end += 1 }
        return (start, end)
    }

    /// Whether the line starting at `location` is part of a fenced code block. Scans only the fence lines before it
    /// (same rules as `MarkdownStyler`), without parsing inline syntax.
    static func isInsideCodeBlock(_ location: Int, in text: String) -> Bool {
        let ns = text as NSString
        let length = ns.length
        func skipSpaces(_ from: Int, _ end: Int) -> Int {
            var i = from
            while i < end, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
            return i
        }
        func fenceRun(_ start: Int, _ end: Int) -> (char: UInt16, count: Int, end: Int)? {
            let i = skipSpaces(start, end)
            guard i - start <= 3, i < end else { return nil }
            let c = ns.character(at: i)
            guard c == 0x60 || c == 0x7E else { return nil }
            var j = i
            while j < end, ns.character(at: j) == c { j += 1 }
            return j - i >= 3 ? (c, j - i, j) : nil
        }
        var open: (char: UInt16, count: Int)?
        var lineStart = 0
        while lineStart <= length {
            var next = lineStart
            while next < length, ns.character(at: next) != 0x0A { next += 1 }
            var end = next
            if end > lineStart, ns.character(at: end - 1) == 0x0D { end -= 1 }
            let run = fenceRun(lineStart, end)
            if lineStart >= location {
                if open != nil { return true }
                guard let run else { return false }
                return run.char == 0x7E || !(run.end..<end).contains { ns.character(at: $0) == 0x60 }
            }
            if let current = open {
                if let run, run.char == current.char, run.count >= current.count, skipSpaces(run.end, end) == end { open = nil }
            } else if let run, run.char == 0x7E || !(run.end..<end).contains(where: { ns.character(at: $0) == 0x60 }) {
                open = (run.char, run.count)
            }
            lineStart = next + 1
        }
        return open != nil
    }

    enum Marker: Equatable {
        case bullet(UInt16)
        case ordered(number: Int, delimiter: UInt16)
    }

    /// A line split into `[quote markers][indent][list marker][task box][content]` (offsets inside the line).
    struct LineInfo {
        let units: [UInt16]
        var hasQuote = false
        /// End of the leading `>` markers (with their spaces); 0 without any.
        var quoteEnd = 0
        var indentEnd = 0
        var marker: Marker?
        /// End of the marker itself (before its space).
        var markerEnd = 0
        var task: Bool?
        /// Start of the `[ ]` / `[x]` box when the line is a task item.
        var boxStart = 0
        var contentStart = 0
        /// Without trailing CR.
        var end = 0

        init(_ units: [UInt16]) {
            self.units = units
            end = units.count
            if end > 0, units[end - 1] == 0x0D { end -= 1 }
            var i = 0
            while true {
                let j = skip(i)
                guard j < end, units[j] == 0x3E else { break }
                i = j + 1
                if i < end, units[i] == 0x20 { i += 1 }
                hasQuote = true
                quoteEnd = i
            }
            indentEnd = skip(quoteEnd)
            contentStart = indentEnd
            guard indentEnd < end else { return }
            let c = units[indentEnd]
            if c == 0x2D || c == 0x2A || c == 0x2B {
                guard indentEnd + 1 == end || isSpace(units[indentEnd + 1]), !isRule(indentEnd) else { return }
                marker = .bullet(c)
                markerEnd = indentEnd + 1
            } else if c >= 0x30 && c <= 0x39 {
                var j = indentEnd
                while j < end, j - indentEnd < 9, units[j] >= 0x30, units[j] <= 0x39 { j += 1 }
                guard j < end, units[j] == 0x2E || units[j] == 0x29, j + 1 == end || isSpace(units[j + 1]) else { return }
                let number = Int(String(decoding: units[indentEnd..<j], as: UTF16.self)) ?? 0
                marker = .ordered(number: number, delimiter: units[j])
                markerEnd = j + 1
            } else {
                return
            }
            contentStart = skip(markerEnd)
            if contentStart + 2 < end, units[contentStart] == 0x5B, units[contentStart + 2] == 0x5D,
               contentStart + 3 == end || isSpace(units[contentStart + 3]) {
                switch units[contentStart + 1] {
                case 0x20: task = false
                case 0x78, 0x58: task = true
                default: break
                }
                if task != nil {
                    boxStart = contentStart
                    contentStart = skip(contentStart + 3)
                }
            }
        }

        private func isSpace(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 }

        private func skip(_ from: Int) -> Int {
            var i = from
            while i < end, isSpace(units[i]) { i += 1 }
            return i
        }

        /// `- - -`, `***` and the like are thematic breaks, not items.
        private func isRule(_ from: Int) -> Bool {
            var count = 0
            for j in from..<end {
                if units[j] == units[from] { count += 1 } else if !isSpace(units[j]) { return false }
            }
            return count >= 3
        }

        /// The quote markers, ending in a space so the new line reads `> text`.
        var quotePart: String {
            guard hasQuote else { return "" }
            let part = String(decoding: units[0..<quoteEnd], as: UTF16.self)
            return part.hasSuffix(" ") ? part : part + " "
        }

        var indent: String { String(decoding: units[quoteEnd..<indentEnd], as: UTF16.self) }

        /// The marker (and box) has no text after it.
        var isEmpty: Bool { marker != nil && contentStart >= end }

        var quoteContentIsEmpty: Bool { skip(quoteEnd) >= end }

        /// One indentation level: 2 for bullets and tasks, the marker plus its space for numbered items.
        var indentWidth: Int {
            if case .ordered = marker { return markerEnd - indentEnd + 1 }
            return 2
        }
    }
}
