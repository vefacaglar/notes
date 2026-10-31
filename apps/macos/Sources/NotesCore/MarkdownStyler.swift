import Foundation

public struct MarkdownSpan: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Syntax characters (`#`, `**`, `` ` ``, `[`, `](url)`, fences, escapes…) that the editor dims.
        case marker
        /// The whole heading line, marker included.
        case heading(level: Int)
        case bold
        case italic
        case boldItalic
        case strikethrough
        case inlineCode
        /// The whole fenced block, fence lines included.
        case codeBlock
        /// The whole quoted line, `>` included.
        case blockquote
        /// `-`, `*`, `+`, `1.` or `1)`.
        case listMarker
        /// The `[ ]` / `[x]` box of a task item.
        case taskMarker(checked: Bool)
        /// The task text after the box.
        case task(checked: Bool)
        /// Link text, or the URL itself for autolinks and bare URLs.
        case link(url: String)
        /// The text of a `[[Note name]]` wiki link (alias and heading included); `target` is the note name.
        case wikiLink(target: String)
        case horizontalRule
    }

    /// UTF-16 range, directly usable with `NSString` / `NSTextStorage`.
    public let range: NSRange
    public let kind: Kind

    public init(_ range: NSRange, _ kind: Kind) {
        self.range = range
        self.kind = kind
    }
}

/// A single-pass Markdown scanner for syntax highlighting. Not a full CommonMark parser:
/// only fenced code blocks span lines, every other construct is confined to one line.
public enum MarkdownStyler {
    /// Spans sorted by location; a span that contains others comes before them.
    public static func spans(in text: String) -> [MarkdownSpan] {
        var scanner = Scanner(Array(text.utf16))
        scanner.run()
        return scanner.spans
    }

    /// What to restyle after an edit when no fence moved: the whole lines it touches, through the end of the line
    /// where it ends, so text split off by Return (which keeps e.g. a heading's font) is included.
    /// Lines end at LF only, like the scanner; `NSString.paragraphRange` would also split at a lone CR.
    /// `editedRange` is in post-edit UTF-16 coordinates of `text`.
    public static func restyleRange(afterEditing editedRange: NSRange, in text: String) -> NSRange {
        let ns = text as NSString
        var start = min(editedRange.location, ns.length)
        var end = min(max(NSMaxRange(editedRange), start), ns.length)
        while start > 0 && ns.character(at: start - 1) != Unit.newline { start -= 1 }
        while end < ns.length && ns.character(at: end) != Unit.newline { end += 1 }
        if end < ns.length { end += 1 }
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - Scanner

private typealias Unit = UInt16

private extension Unit {
    static let tab: Unit = 9, newline: Unit = 10, cr: Unit = 13, space: Unit = 32
    static let bang: Unit = 33, hash: Unit = 35, lparen: Unit = 40, rparen: Unit = 41, star: Unit = 42
    static let plus: Unit = 43, dash: Unit = 45, dot: Unit = 46, lt: Unit = 60, gt: Unit = 62
    static let lbracket: Unit = 91, backslash: Unit = 92, rbracket: Unit = 93, underscore: Unit = 95
    static let backtick: Unit = 96, tilde: Unit = 126

    var isSpace: Bool { self == .space || self == .tab }
    var isDigit: Bool { self >= 48 && self <= 57 }
    var isASCIIPunctuation: Bool {
        (self >= 33 && self <= 47) || (self >= 58 && self <= 64) || (self >= 91 && self <= 96) || (self >= 123 && self <= 126)
    }
    /// ASCII punctuation, general punctuation/symbol blocks and surrogates (emoji).
    var isPunctuation: Bool {
        isASCIIPunctuation || (self >= 0x2000 && self <= 0x2BFF) || (self >= 0xD800 && self <= 0xDFFF)
    }
}

private struct Delimiter {
    let char: Unit
    var start: Int
    var count: Int
    let canOpen: Bool
    let canClose: Bool
}

private struct Scanner {
    let s: [Unit]
    var spans: [MarkdownSpan] = []
    private var lineSpans: [MarkdownSpan] = []

    init(_ s: [Unit]) {
        self.s = s
        spans.reserveCapacity(s.count / 16)
    }

    private mutating func add(_ start: Int, _ end: Int, _ kind: MarkdownSpan.Kind) {
        guard end > start else { return }
        spans.append(MarkdownSpan(NSRange(location: start, length: end - start), kind))
    }

    private mutating func addInline(_ start: Int, _ end: Int, _ kind: MarkdownSpan.Kind) {
        guard end > start else { return }
        lineSpans.append(MarkdownSpan(NSRange(location: start, length: end - start), kind))
    }

    private func skipSpaces(_ i: Int, _ end: Int) -> Int {
        var i = i
        while i < end && s[i].isSpace { i += 1 }
        return i
    }

    // MARK: Blocks

    mutating func run() {
        var lineStart = 0
        var fence: (char: Unit, count: Int, spanIndex: Int)?
        while lineStart <= s.count {
            var next = lineStart
            while next < s.count && s[next] != .newline { next += 1 }
            var end = next
            if end > lineStart && s[end - 1] == .cr { end -= 1 }

            if let open = fence {
                if let close = fenceRun(lineStart, end), close.char == open.char, close.count >= open.count,
                   skipSpaces(close.end, end) == end {
                    add(lineStart, end, .marker)
                    closeFence(open.spanIndex, end)
                    fence = nil
                }
            } else if let open = fenceRun(lineStart, end),
                      open.char == .tilde || !s[open.end..<end].contains(.backtick) {
                fence = (open.char, open.count, spans.count)
                add(lineStart, end, .codeBlock)
                add(lineStart, end, .marker)
            } else {
                line(lineStart, end)
            }
            lineStart = next + 1
        }
        if let open = fence { closeFence(open.spanIndex, s.count) }
    }

    private mutating func closeFence(_ index: Int, _ end: Int) {
        let start = spans[index].range.location
        spans[index] = MarkdownSpan(NSRange(location: start, length: end - start), .codeBlock)
    }

    /// A run of 3+ backticks or tildes after at most 3 spaces of indentation.
    private func fenceRun(_ start: Int, _ end: Int) -> (char: Unit, count: Int, end: Int)? {
        let i = skipSpaces(start, end)
        guard i - start <= 3, i < end, s[i] == .backtick || s[i] == .tilde else { return nil }
        var j = i
        while j < end && s[j] == s[i] { j += 1 }
        return j - i >= 3 ? (s[i], j - i, j) : nil
    }

    private mutating func line(_ start: Int, _ end: Int) {
        var i = start
        // Blockquote prefixes, possibly nested ("> > text").
        var quoted = false
        while true {
            let j = skipSpaces(i, end)
            guard j - i <= 3, j < end, s[j] == .gt else { break }
            if !quoted { add(start, end, .blockquote); quoted = true }
            let after = j + 1 < end && s[j + 1].isSpace ? j + 2 : j + 1
            add(j, after, .marker)
            i = after
        }

        let indentEnd = skipSpaces(i, end)
        if indentEnd - i <= 3, isHorizontalRule(indentEnd, end) {
            add(indentEnd, end, .horizontalRule)
            return
        }
        if indentEnd - i <= 3, let level = heading(indentEnd, end) {
            add(indentEnd, end, .heading(level: level))
            let markerEnd = skipSpaces(indentEnd + level, end)
            add(indentEnd, markerEnd, .marker)
            // Optional closing sequence: " ###".
            var contentEnd = end
            var k = end
            while k > markerEnd && s[k - 1].isSpace { k -= 1 }
            var h = k
            while h > markerEnd && s[h - 1] == .hash { h -= 1 }
            if h < k, h == markerEnd || s[h - 1].isSpace {
                contentEnd = h
                while contentEnd > markerEnd && s[contentEnd - 1].isSpace { contentEnd -= 1 }
            }
            inline(markerEnd, contentEnd)
            if contentEnd < k { add(h, k, .marker) }
            flushInline()
            return
        }
        if let markerEnd = listMarker(indentEnd, end) {
            add(indentEnd, markerEnd, .listMarker)
            var contentStart = skipSpaces(markerEnd, end)
            if let checked = taskBox(contentStart, end) {
                add(contentStart, contentStart + 3, .taskMarker(checked: checked))
                contentStart = skipSpaces(contentStart + 3, end)
                add(contentStart, end, .task(checked: checked))
            }
            inline(contentStart, end)
            flushInline()
            return
        }
        inline(i, end)
        flushInline()
    }

    private func heading(_ i: Int, _ end: Int) -> Int? {
        var j = i
        while j < end && s[j] == .hash { j += 1 }
        let level = j - i
        guard (1...6).contains(level), j == end || s[j].isSpace else { return nil }
        return level
    }

    private func isHorizontalRule(_ i: Int, _ end: Int) -> Bool {
        guard i < end, s[i] == .dash || s[i] == .star || s[i] == .underscore else { return false }
        var count = 0
        for j in i..<end {
            if s[j] == s[i] { count += 1 } else if !s[j].isSpace { return false }
        }
        return count >= 3
    }

    /// Returns the end of the marker (`-`, `*`, `+`, `12.`, `12)`) when followed by a space or the line end.
    private func listMarker(_ i: Int, _ end: Int) -> Int? {
        guard i < end else { return nil }
        if s[i] == .dash || s[i] == .star || s[i] == .plus {
            return i + 1 == end || s[i + 1].isSpace ? i + 1 : nil
        }
        var j = i
        while j < end && j - i < 9 && s[j].isDigit { j += 1 }
        guard j > i, j < end, s[j] == .dot || s[j] == .rparen else { return nil }
        return j + 1 == end || s[j + 1].isSpace ? j + 1 : nil
    }

    private func taskBox(_ i: Int, _ end: Int) -> Bool? {
        guard i + 2 < end, s[i] == .lbracket, s[i + 2] == .rbracket,
              i + 3 == end || s[i + 3].isSpace else { return nil }
        switch s[i + 1] {
        case .space: return false
        case 120, 88: return true // x, X
        default: return nil
        }
    }

    // MARK: Inlines

    private mutating func flushInline() {
        guard !lineSpans.isEmpty else { return }
        lineSpans.sort { a, b in
            a.range.location != b.range.location ? a.range.location < b.range.location : a.range.length > b.range.length
        }
        spans.append(contentsOf: lineSpans)
        lineSpans.removeAll(keepingCapacity: true)
    }

    private mutating func inline(_ start: Int, _ end: Int) {
        var delimiters: [Delimiter] = []
        var i = start
        while i < end {
            let c = s[i]
            switch c {
            case .backslash where i + 1 < end && s[i + 1].isASCIIPunctuation:
                addInline(i, i + 1, .marker)
                i += 2
            case .backtick:
                i = codeSpan(i, end)
            case .lt:
                i = autolink(i, end) ?? i + 1
            case .lbracket:
                i = wikiLink(i, end) ?? link(i, i, end) ?? i + 1
            case .bang where i + 1 < end && s[i + 1] == .lbracket:
                i = link(i, i + 1, end) ?? i + 1
            case 104 where i == start || !isWordUnit(s[i - 1]): // h
                i = bareURL(i, end) ?? i + 1
            case .star, .underscore, .tilde:
                var j = i
                while j < end && s[j] == c { j += 1 }
                if c != .tilde || j - i == 2 {
                    let before: Unit = i > start ? s[i - 1] : .space
                    let after: Unit = j < end ? s[j] : .space
                    let left = !after.isSpace && (!after.isPunctuation || before.isSpace || before.isPunctuation)
                    let right = !before.isSpace && (!before.isPunctuation || after.isSpace || after.isPunctuation)
                    // Intraword delimiters never count, for `*` too, so `a*b*c` and `snake_case` stay plain.
                    let canOpen = left && (!right || before.isPunctuation)
                    let canClose = right && (!left || after.isPunctuation)
                    if canOpen || canClose {
                        delimiters.append(Delimiter(char: c, start: i, count: j - i, canOpen: canOpen, canClose: canClose))
                    }
                }
                i = j
            default:
                i += 1
            }
        }
        emphasis(&delimiters)
    }

    private func isWordUnit(_ u: Unit) -> Bool {
        !u.isSpace && !u.isPunctuation
    }

    /// Matches closers to the nearest compatible opener (CommonMark's "process emphasis", minus the rule of 3).
    private mutating func emphasis(_ delimiters: inout [Delimiter]) {
        var bottom: [Unit: Int] = [:]
        for c in delimiters.indices where delimiters[c].canClose {
            let char = delimiters[c].char
            while delimiters[c].count > 0 {
                let floor = bottom[char] ?? 0
                var found: Int?
                var o = c - 1
                while o >= floor {
                    if delimiters[o].char == char && delimiters[o].canOpen && delimiters[o].count > 0 { found = o; break }
                    o -= 1
                }
                guard let o = found else { bottom[char] = c; break }

                let use: Int
                let kind: MarkdownSpan.Kind
                if char == .tilde {
                    (use, kind) = (2, .strikethrough)
                } else if delimiters[o].count >= 3 && delimiters[c].count >= 3 {
                    (use, kind) = (3, .boldItalic)
                } else if delimiters[o].count >= 2 && delimiters[c].count >= 2 {
                    (use, kind) = (2, .bold)
                } else {
                    (use, kind) = (1, .italic)
                }
                let contentStart = delimiters[o].start + delimiters[o].count
                let contentEnd = delimiters[c].start
                addInline(contentStart - use, contentStart, .marker)
                addInline(contentStart, contentEnd, kind)
                addInline(contentEnd, contentEnd + use, .marker)
                delimiters[o].count -= use
                delimiters[c].start += use
                delimiters[c].count -= use
                for between in (o + 1)..<c { delimiters[between].count = 0 }
            }
        }
    }

    private mutating func codeSpan(_ i: Int, _ end: Int) -> Int {
        var j = i
        while j < end && s[j] == .backtick { j += 1 }
        let n = j - i
        var k = j
        while k < end {
            guard s[k] == .backtick else { k += 1; continue }
            var m = k
            while m < end && s[m] == .backtick { m += 1 }
            if m - k == n {
                addInline(i, j, .marker)
                addInline(j, k, .inlineCode)
                addInline(k, m, .marker)
                return m
            }
            k = m
        }
        return j
    }

    private func hasURLScheme(_ i: Int, _ end: Int) -> Int? {
        for scheme in Self.schemes where i + scheme.count <= end {
            if s[i..<(i + scheme.count)].elementsEqual(scheme) { return i + scheme.count }
        }
        return nil
    }

    private static let schemes: [[Unit]] = ["https://", "http://"].map { Array($0.utf16) }

    private mutating func autolink(_ i: Int, _ end: Int) -> Int? {
        guard hasURLScheme(i + 1, end) != nil else { return nil }
        var j = i + 1
        while j < end && s[j] != .gt && !s[j].isSpace && s[j] != .lt { j += 1 }
        guard j < end, s[j] == .gt else { return nil }
        addInline(i, i + 1, .marker)
        addInline(i + 1, j, .link(url: string(i + 1, j)))
        addInline(j, j + 1, .marker)
        return j + 1
    }

    private mutating func bareURL(_ i: Int, _ end: Int) -> Int? {
        guard let schemeEnd = hasURLScheme(i, end) else { return nil }
        var j = schemeEnd
        var parens = 0
        while j < end && !s[j].isSpace && s[j] != .lt && s[j] != .gt {
            if s[j] == .lparen { parens += 1 } else if s[j] == .rparen { parens -= 1 }
            j += 1
        }
        // Trailing punctuation belongs to the sentence, not the URL.
        while j > schemeEnd {
            let u = s[j - 1]
            if u == .rparen && parens < 0 { parens += 1; j -= 1; continue }
            guard [46, 44, 58, 59, 33, 63, 39, 34, 42, 95, 126].contains(u) else { break } // . , : ; ! ? ' " * _ ~
            j -= 1
        }
        guard j > schemeEnd else { return nil }
        addInline(i, j, .link(url: string(i, j)))
        return j
    }

    /// `[[Note name]]`: no brackets inside, a non-empty name.
    private mutating func wikiLink(_ i: Int, _ end: Int) -> Int? {
        guard i + 1 < end, s[i + 1] == .lbracket else { return nil }
        var j = i + 2
        while j + 1 < end, s[j] != .lbracket, s[j] != .rbracket { j += 1 }
        guard j + 1 < end, s[j] == .rbracket, s[j + 1] == .rbracket,
              let target = NoteLinks.wikiName(string(i + 2, j)) else { return nil }
        addInline(i, i + 2, .marker)
        addInline(i + 2, j, .wikiLink(target: target))
        addInline(j, j + 2, .marker)
        return j + 2
    }

    /// `[text](url)` starting at `bracket`; `start` is the `!` of an image or the bracket itself.
    private mutating func link(_ start: Int, _ bracket: Int, _ end: Int) -> Int? {
        let limit = min(end, bracket + 2000)
        var depth = 0
        var j = bracket
        var close: Int?
        while j < limit {
            switch s[j] {
            case .backslash: j += 1
            case .lbracket: depth += 1
            case .rbracket:
                depth -= 1
                if depth == 0 { close = j }
            default: break
            }
            if close != nil { break }
            j += 1
        }
        guard let close, close + 1 < end, s[close + 1] == .lparen else { return nil }
        var k = close + 2
        var parens = 1
        while k < end {
            if s[k] == .backslash { k += 2; continue }
            if s[k] == .lparen { parens += 1 }
            if s[k] == .rparen { parens -= 1; if parens == 0 { break } }
            k += 1
        }
        guard k < end else { return nil }

        var urlStart = skipSpaces(close + 2, k)
        var urlEnd = urlStart
        while urlEnd < k && !s[urlEnd].isSpace { urlEnd += 1 }
        if urlEnd > urlStart && s[urlStart] == .lt && s[urlEnd - 1] == .gt { urlStart += 1; urlEnd -= 1 }

        addInline(start, bracket + 1, .marker)
        // Link text is styled as a whole; emphasis inside it is not parsed.
        addInline(bracket + 1, close, .link(url: string(urlStart, urlEnd)))
        addInline(close, k + 1, .marker)
        return k + 1
    }

    private func string(_ start: Int, _ end: Int) -> String {
        String(decoding: s[start..<max(start, end)], as: UTF16.self)
    }
}
