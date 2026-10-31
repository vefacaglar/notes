import Foundation

/// Inline Markdown styles of the formatting bar and the Format menu.
public enum InlineStyle: CaseIterable, Sendable {
    case bold, italic, strikethrough, code

    var marker: [UInt16] {
        switch self {
        case .bold: [0x2A, 0x2A]
        case .italic: [0x2A]
        case .strikethrough: [0x7E, 0x7E]
        case .code: [0x60]
        }
    }
}

/// Line-level styles: each applies to every line of the selection and replaces the other list or heading marker.
public enum LineStyle: Equatable, Sendable {
    case bullet, numbered, task, quote
    /// `#` to `######` (1...6).
    case heading(Int)
    /// Removes a heading marker (list markers stay).
    case body
}

/// What the caret (or the start of the selection) is in; the formatting bar highlights these.
public struct ActiveFormat: Equatable, Sendable {
    public var inline: Set<InlineStyle> = []
    /// 0 when the line is not a heading.
    public var heading = 0
    public var bullet = false, numbered = false, task = false, quote = false

    public init() {}
}

/// Formatting actions of the Markdown editor as pure functions of the text and the selection (UTF-16).
/// See docs/format.md ("Editing helpers").
extension MarkdownEditing {
    private struct Change {
        var at: Int
        var removed: Int
        var inserted: [UInt16]
    }

    static func units(_ ns: NSString, _ range: NSRange) -> [UInt16] {
        guard range.length > 0 else { return [] }
        var buffer = [unichar](repeating: 0, count: range.length)
        ns.getCharacters(&buffer, range: range)
        return buffer
    }

    private static func isBlank(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 || u == 0x0D }

    // MARK: Inline

    /// ⌘B, ⌘I and friends: wraps the selection (or the word at the caret) in the style's marker, or removes the
    /// marker when it is already there. Surrounding whitespace stays outside; every line of a multi-line selection
    /// is wrapped on its own. An empty selection away from a word inserts the pair with the caret inside.
    public static func toggleInline(_ style: InlineStyle, in text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        guard selection.location >= 0, NSMaxRange(selection) <= ns.length else { return nil }
        let marker = style.marker, m = marker.count
        var caret: Int?
        var segments = selection.length == 0 ? [] : inlineSegments(of: selection, in: ns)
        if segments.isEmpty {
            let at = selection.location
            caret = at
            let word = wordRange(at: at, in: ns)
            if word.length > 0 {
                segments = [word]
            } else {
                let (left, right) = markerRuns(around: NSRange(location: at, length: 0), char: marker[0], in: ns)
                if left == m, right == m {
                    return TextEdit(range: NSRange(location: at - m, length: 2 * m), replacement: "",
                                    selection: NSRange(location: at - m, length: 0))
                }
                let pair = String(decoding: marker + marker, as: UTF16.self)
                return TextEdit(range: NSRange(location: at, length: 0), replacement: pair,
                                selection: NSRange(location: at + m, length: 0))
            }
        }

        enum State { case outside(Int), inside(Int), none }
        func state(_ seg: NSRange) -> State {
            let (left, right) = markerRuns(around: seg, char: marker[0], in: ns)
            if let k = removal(style, left: left, right: right) { return .outside(k) }
            let leading = unitRun(from: seg.location, step: 1, limit: NSMaxRange(seg), char: marker[0], in: ns)
            let trailing = unitRun(from: NSMaxRange(seg) - 1, step: -1, limit: seg.location - 1, char: marker[0], in: ns)
            if leading + trailing < seg.length, let k = removal(style, left: leading, right: trailing) { return .inside(k) }
            return .none
        }
        let states = segments.map(state)
        let unwrapAll = states.allSatisfy { if case .none = $0 { false } else { true } }

        var changes: [Change] = []
        var inners: [(start: Int, end: Int, oldStart: Int)] = []
        var delta = 0
        for (seg, state) in zip(segments, states) {
            if unwrapAll {
                switch state {
                case .outside(let k):
                    changes += [Change(at: seg.location - k, removed: k, inserted: []), Change(at: NSMaxRange(seg), removed: k, inserted: [])]
                    inners.append((seg.location - k + delta, seg.location - k + delta + seg.length, seg.location))
                    delta -= 2 * k
                case .inside(let k):
                    changes += [Change(at: seg.location, removed: k, inserted: []), Change(at: NSMaxRange(seg) - k, removed: k, inserted: [])]
                    inners.append((seg.location + delta, seg.location + delta + seg.length - 2 * k, seg.location + k))
                    delta -= 2 * k
                case .none: break
                }
            } else if case .none = state {
                changes += [Change(at: seg.location, removed: 0, inserted: marker), Change(at: NSMaxRange(seg), removed: 0, inserted: marker)]
                inners.append((seg.location + m + delta, seg.location + m + delta + seg.length, seg.location))
                delta += 2 * m
            } else {
                inners.append((seg.location + delta, seg.location + delta + seg.length, seg.location))
            }
        }
        guard let (range, replacement) = compose(changes, in: ns), let first = inners.first, let last = inners.last else { return nil }
        let newSelection: NSRange
        if let caret {
            let place = min(max(caret - first.oldStart, 0), first.end - first.start)
            newSelection = NSRange(location: first.start + place, length: 0)
        } else {
            newSelection = NSRange(location: first.start, length: last.end - first.start)
        }
        return TextEdit(range: range, replacement: replacement, selection: newSelection)
    }

    /// Units of marker removal when the style is present, given the marker-character runs on both sides.
    private static func removal(_ style: InlineStyle, left: Int, right: Int) -> Int? {
        let low = min(left, right)
        switch style {
        case .bold, .strikethrough: return low >= 2 ? 2 : nil
        case .italic: return low % 2 == 1 ? 1 : nil
        case .code: return left == 1 && right == 1 ? 1 : nil
        }
    }

    private static func unitRun(from: Int, step: Int, limit: Int, char: UInt16, in ns: NSString) -> Int {
        var i = from, count = 0
        while i != limit, i >= 0, i < ns.length, ns.character(at: i) == char { count += 1; i += step }
        return count
    }

    private static func markerRuns(around range: NSRange, char: UInt16, in ns: NSString) -> (Int, Int) {
        (unitRun(from: range.location - 1, step: -1, limit: -1, char: char, in: ns),
         unitRun(from: NSMaxRange(range), step: 1, limit: ns.length, char: char, in: ns))
    }

    /// The non-blank part of every line piece of the selection.
    private static func inlineSegments(of selection: NSRange, in ns: NSString) -> [NSRange] {
        var result: [NSRange] = []
        var pos = selection.location
        let end = NSMaxRange(selection)
        while pos <= end {
            var stop = pos
            while stop < end, ns.character(at: stop) != 0x0A { stop += 1 }
            var a = pos, b = stop
            while a < b, isBlank(ns.character(at: a)) { a += 1 }
            while b > a, isBlank(ns.character(at: b - 1)) { b -= 1 }
            if b > a { result.append(NSRange(location: a, length: b - a)) }
            pos = stop + 1
        }
        return result
    }

    /// The run of letters and digits (marks included) around the caret; empty when the caret touches none.
    static func wordRange(at caret: Int, in ns: NSString) -> NSRange {
        func isWord(_ u: UInt16) -> Bool { Unicode.Scalar(u).map(CharacterSet.alphanumerics.contains) ?? false }
        var a = caret, b = caret
        while a > 0, isWord(ns.character(at: a - 1)) { a -= 1 }
        while b < ns.length, isWord(ns.character(at: b)) { b += 1 }
        return NSRange(location: a, length: b - a)
    }

    private static func compose(_ changes: [Change], in ns: NSString) -> (NSRange, String)? {
        guard let first = changes.first else { return nil }
        var out: [UInt16] = []
        var pos = first.at
        for change in changes {
            out += units(ns, NSRange(location: pos, length: change.at - pos))
            out += change.inserted
            pos = change.at + change.removed
        }
        return (NSRange(location: first.at, length: pos - first.at), String(decoding: out, as: UTF16.self))
    }

    // MARK: Lines

    struct ParsedLine {
        let start: Int
        let units: [UInt16]
        let info: LineInfo
        /// 0 or the ATX level.
        let heading: Int
        /// Offset of the text after the markers.
        let contentOffset: Int

        var end: Int { start + units.count }
        var quote: ArraySlice<UInt16> { units[0..<info.quoteEnd] }
        var content: ArraySlice<UInt16> { units[contentOffset..<info.end] }
        var terminator: ArraySlice<UInt16> { units[info.end...] }
        var indent: ArraySlice<UInt16> { heading == 0 ? units[info.quoteEnd..<info.indentEnd] : [] }
        var isBlank: Bool { info.marker == nil && heading == 0 && info.indentEnd >= info.end }

        init(start: Int, units: [UInt16]) {
            self.start = start
            self.units = units
            let info = LineInfo(units)
            self.info = info
            var level = 0
            var offset = min(info.contentStart, info.end)
            if info.marker == nil {
                var i = info.quoteEnd
                while i < info.end, i - info.quoteEnd < 3, units[i] == 0x20 { i += 1 }
                var j = i
                while j < info.end, units[j] == 0x23 { j += 1 }
                if (1...6).contains(j - i), j == info.end || units[j] == 0x20 || units[j] == 0x09 {
                    level = j - i
                    offset = j
                    while offset < info.end, units[offset] == 0x20 || units[offset] == 0x09 { offset += 1 }
                }
            }
            heading = level
            contentOffset = offset
        }
    }

    /// The lines the selection touches (a selection ending right after a line break leaves out the next line).
    static func parsedLines(for selection: NSRange, in ns: NSString) -> [ParsedLine]? {
        guard selection.location >= 0, NSMaxRange(selection) <= ns.length else { return nil }
        var lines: [ParsedLine] = []
        var cursor = lineBounds(at: selection.location, in: ns).start
        var stop = NSMaxRange(selection)
        if selection.length > 0, stop > 0, ns.character(at: stop - 1) == 0x0A { stop -= 1 }
        while true {
            let bounds = lineBounds(at: cursor, in: ns)
            lines.append(ParsedLine(start: bounds.start, units: units(ns, NSRange(location: bounds.start, length: bounds.end - bounds.start))))
            if bounds.end >= stop || bounds.end >= ns.length { break }
            cursor = bounds.end + 1
        }
        return lines
    }

    private static func has(_ style: LineStyle, _ line: ParsedLine) -> Bool {
        switch style {
        case .bullet:
            if case .bullet? = line.info.marker { return line.info.task == nil }
            return false
        case .numbered:
            if case .ordered? = line.info.marker { return true }
            return false
        case .task: return line.info.task != nil
        case .quote: return line.info.hasQuote
        case .heading(let level): return line.heading == level
        case .body: return line.heading == 0
        }
    }

    /// Applies a line style to every line of the selection. When all of them already have it, it is removed
    /// instead (except `.body`); otherwise it replaces any other list or heading marker. Blank lines are skipped
    /// unless nothing else is selected. `nil` when nothing would change or the lines are in a fenced code block.
    public static func apply(_ style: LineStyle, in text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        guard let lines = parsedLines(for: selection, in: ns), !isInsideCodeBlock(lines[0].start, in: text) else { return nil }
        if case .heading(let level) = style, !(1...6).contains(level) { return nil }
        let nonBlank = lines.filter { !$0.isBlank }
        let eligible = nonBlank.isEmpty ? lines : nonBlank
        let eligibleStarts = Set(eligible.map(\.start))
        let remove = style != .body && eligible.allSatisfy { has(style, $0) }

        var number = 0
        var rendered: [[UInt16]] = []
        for line in lines {
            guard eligibleStarts.contains(line.start) else { rendered.append(line.units); continue }
            number += 1
            rendered.append(render(line, style: style, remove: remove, number: number))
        }
        guard rendered != lines.map(\.units) else { return nil }

        let from = lines[0].start, to = lines[lines.count - 1].end
        var out: [UInt16] = []
        var newStarts: [Int] = []
        for (i, units) in rendered.enumerated() {
            if i > 0 { out.append(0x0A) }
            newStarts.append(from + out.count)
            out += units
        }
        let newEnd = from + out.count
        func locate(_ p: Int) -> Int {
            if p > to { return p - to + newEnd }
            let index = lines.lastIndex { $0.start <= p } ?? 0
            let line = lines[index]
            let shift = rendered[index].count - line.units.count
            let rel = p - line.start
            return newStarts[index] + (rel >= line.contentOffset ? rel + shift : line.contentOffset + shift)
        }
        let start = locate(selection.location)
        let end = selection.length == 0 ? start : locate(NSMaxRange(selection))
        return TextEdit(range: NSRange(location: from, length: to - from), replacement: String(decoding: out, as: UTF16.self),
                        selection: NSRange(location: start, length: max(end - start, 0)))
    }

    private static func render(_ line: ParsedLine, style: LineStyle, remove: Bool, number: Int) -> [UInt16] {
        let space: UInt16 = 0x20
        let content = Array(line.content), terminator = Array(line.terminator)
        var quote = Array(line.quote)
        let indent = Array(line.indent)
        let prefix: [UInt16]
        switch style {
        case .quote:
            if remove {
                if let at = quote.firstIndex(of: 0x3E) {
                    var cut = at + 1
                    if cut < quote.count, quote[cut] == space { cut += 1 }
                    quote.removeSubrange(at..<cut)
                }
                return quote + Array(line.units[line.info.quoteEnd..<line.info.end]) + terminator
            }
            if line.info.hasQuote { return line.units }
            return [0x3E, space] + line.units
        case .heading(let level):
            prefix = remove ? [] : Array(repeating: 0x23, count: level) + [space]
        case .body:
            return line.heading == 0 ? line.units : quote + content + terminator
        case .bullet, .task:
            var char: UInt16 = 0x2D
            if case .bullet(let c)? = line.info.marker { char = c }
            prefix = remove ? indent : indent + [char, space] + (style == .task ? [0x5B, space, 0x5D, space] : [])
        case .numbered:
            prefix = remove ? indent : indent + Array("\(number).".utf16) + [space]
        }
        return quote + prefix + content + terminator
    }

    // MARK: Blocks

    /// Wraps the selected lines (or the caret's line) in ``` fences; when the selection already is a whole fenced
    /// block (first and last line are fences) it removes the fences instead.
    public static func codeBlock(in text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        guard let lines = parsedLines(for: selection, in: ns) else { return nil }
        let from = lines[0].start
        var to = lines[lines.count - 1].end
        if to > from, ns.character(at: to - 1) == 0x0D { to -= 1 }
        func isFence(_ line: ParsedLine, closing: Bool) -> Bool {
            let u = Array(line.units[0..<line.info.end])
            var i = 0
            while i < u.count, i < 3, u[i] == 0x20 { i += 1 }
            var j = i
            while j < u.count, u[j] == 0x60 { j += 1 }
            guard j - i >= 3 else { return false }
            let rest = u[j...]
            return closing ? rest.allSatisfy { $0 == 0x20 || $0 == 0x09 } : !rest.contains(0x60)
        }
        let range = NSRange(location: from, length: to - from)
        if lines.count >= 2, isFence(lines[0], closing: false), isFence(lines[lines.count - 1], closing: true) {
            let innerStart = lines[0].end + 1
            let innerEnd = max(lines[lines.count - 1].start - 1, innerStart)
            var inner = innerEnd > innerStart ? ns.substring(with: NSRange(location: innerStart, length: innerEnd - innerStart)) : ""
            if inner.hasSuffix("\r") { inner.removeLast() }
            return TextEdit(range: range, replacement: inner, selection: NSRange(location: from, length: (inner as NSString).length))
        }
        let eol = lines[0].info.end < lines[0].units.count ? "\r\n" : "\n"
        let body = units(ns, range)
        var longest = 0, run = 0
        for u in body { run = u == 0x60 ? run + 1 : 0; longest = max(longest, run) }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let opening = from + fence.utf16.count + eol.utf16.count
        if lines.count == 1, lines[0].isBlank, selection.length == 0 {
            return TextEdit(range: range, replacement: fence + eol + eol + fence, selection: NSRange(location: opening, length: 0))
        }
        return TextEdit(range: range, replacement: fence + eol + String(decoding: body, as: UTF16.self) + eol + fence,
                        selection: NSRange(location: opening, length: body.count))
    }

    /// Inserts `---` on a line of its own after the line the selection ends in, with a blank line before it so the
    /// text above does not turn into a heading. The caret goes to the line after. `nil` inside a fenced code block.
    public static func horizontalRule(in text: String, selection: NSRange) -> TextEdit? {
        insertBlock("---", caretAt: 4, in: text, selection: selection)
    }

    /// Puts a block of lines on lines of its own after the line the selection ends in (replacing that line when it
    /// is blank), set off by a blank line before and after. `caretAt` is the caret's UTF-16 offset in the block.
    static func insertBlock(_ block: String, caretAt: Int, in text: String, selection: NSRange) -> TextEdit? {
        let ns = text as NSString
        guard selection.location >= 0, NSMaxRange(selection) <= ns.length else { return nil }
        let line = lineBounds(at: NSMaxRange(selection), in: ns)
        guard !isInsideCodeBlock(lineBounds(at: selection.location, in: ns).start, in: text) else { return nil }
        func blank(_ bounds: (start: Int, end: Int)) -> Bool {
            ns.substring(with: NSRange(location: bounds.start, length: bounds.end - bounds.start))
                .allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
        }
        let previousBlank = line.start == 0 || blank(lineBounds(at: line.start - 1, in: ns))
        if blank(line) {
            let prefix = previousBlank ? "" : "\n"
            return TextEdit(range: NSRange(location: line.start, length: line.end - line.start), replacement: prefix + block + "\n",
                            selection: NSRange(location: line.start + prefix.utf16.count + caretAt, length: 0))
        }
        return TextEdit(range: NSRange(location: line.end, length: 0), replacement: "\n\n" + block + "\n",
                        selection: NSRange(location: line.end + 2 + caretAt, length: 0))
    }

    // MARK: Active state

    /// The styles at the start of the selection (for the formatting bar). Looks at the caret's line only.
    public static func activeFormat(in text: String, selection: NSRange) -> ActiveFormat {
        let ns = text as NSString
        var result = ActiveFormat()
        guard selection.location >= 0, NSMaxRange(selection) <= ns.length else { return result }
        let bounds = lineBounds(at: selection.location, in: ns)
        let line = ParsedLine(start: bounds.start, units: units(ns, NSRange(location: bounds.start, length: bounds.end - bounds.start)))
        result.heading = line.heading
        result.bullet = has(.bullet, line)
        result.numbered = has(.numbered, line)
        result.task = has(.task, line)
        result.quote = line.info.hasQuote

        var target = selection
        if selection.length == 0 {
            target = wordRange(at: selection.location, in: ns)
            if target.length == 0 { target = NSRange(location: selection.location, length: 0) }
        } else if let first = inlineSegments(of: selection, in: ns).first {
            target = first
        }
        for style in InlineStyle.allCases {
            let (left, right) = markerRuns(around: target, char: style.marker[0], in: ns)
            if removal(style, left: left, right: right) != nil { result.inline.insert(style) }
        }
        return result
    }
}
