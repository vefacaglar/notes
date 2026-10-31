import Foundation

/// Markdown to HTML for export and printing. See docs/format.md, "HTML export". Supports headings (ATX and setext),
/// paragraphs, emphasis, strikethrough, code spans and fences, lists (nested, ordered, tasks), blockquotes, links,
/// images, thematic breaks and simple tables. Raw HTML in the source is escaped, never passed through.
public enum MarkdownHTML {
    /// The fonts the exported page uses; `nil` families fall back to the system fonts.
    public struct Style: Sendable, Equatable {
        public var textFontFamily: String?
        public var textFontSize: Double
        public var codeFontFamily: String?
        public var codeFontSize: Double

        public init(textFontFamily: String? = nil, textFontSize: Double = 15, codeFontFamily: String? = nil, codeFontSize: Double = 13) {
            self.textFontFamily = textFontFamily
            self.textFontSize = textFontSize
            self.codeFontFamily = codeFontFamily
            self.codeFontSize = codeFontSize
        }
    }

    /// A complete HTML document for a Markdown note.
    public static func document(markdown: String, title: String, style: Style = Style()) -> String {
        page(title: title, style: style, body: body(markdown: markdown))
    }

    /// A complete HTML document for a code or text file: the file as one `<pre>`.
    public static func document(code: String, title: String, style: Style = Style()) -> String {
        let text = code.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return page(title: title, style: style, body: "<pre class=\"file\"><code>\(escape(text))</code></pre>\n")
    }

    /// The HTML body for Markdown text.
    public static func body(markdown: String) -> String {
        var text = markdown.hasPrefix("\u{FEFF}") ? String(markdown.dropFirst()) : markdown
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(of: "\t", with: "    ")
        return blocks(text.components(separatedBy: "\n"), tight: false)
    }

    /// Escapes `&`, `<`, `>` and `"`.
    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default: result.append(character)
            }
        }
        return result
    }

    // MARK: Page

    private static func page(title: String, style: Style, body: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        \(css(style))
        </style>
        </head>
        <body>
        <main>
        \(body)</main>
        </body>
        </html>

        """
    }

    private static func css(_ style: Style) -> String {
        let text = fontStack(style.textFontFamily, fallback: "-apple-system, BlinkMacSystemFont, \"Segoe UI\", \"Helvetica Neue\", sans-serif")
        let code = fontStack(style.codeFontFamily, fallback: "ui-monospace, \"SF Mono\", Menlo, Consolas, monospace")
        let size = String(format: "%.1f", style.textFontSize)
        let codeSize = String(format: "%.1f", style.codeFontSize)
        return """
        :root { color-scheme: light dark; --fg: #222; --bg: #fff; --muted: #6b6b6b; --line: #d9d9d9; --code-bg: #f3f3f3; }
        @media (prefers-color-scheme: dark) { :root { --fg: #e4e4e4; --bg: #1e1e1e; --muted: #9a9a9a; --line: #3d3d3d; --code-bg: #2a2a2a; } }
        @media print { :root { --fg: #222; --bg: #fff; --muted: #6b6b6b; --line: #d9d9d9; --code-bg: #f3f3f3; } }
        html { background: var(--bg); }
        body { margin: 0; color: var(--fg); background: var(--bg); font: \(size)px/1.6 \(text); }
        main { max-width: 46em; margin: 0 auto; padding: 2em 1.5em; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.5em; }
        h1 { font-size: 1.8em; } h2 { font-size: 1.45em; } h3 { font-size: 1.2em; }
        h4, h5, h6 { font-size: 1em; } h6 { color: var(--muted); }
        main > :first-child { margin-top: 0; }
        p, ul, ol, blockquote, pre, table { margin: 0 0 1em; }
        ul, ol { padding-left: 1.6em; }
        li > ul, li > ol { margin: 0.2em 0; }
        li.task { list-style: none; margin-left: -1.4em; }
        li.task input { margin: 0 0.5em 0 0; vertical-align: middle; }
        a { color: inherit; text-decoration: underline; text-decoration-color: var(--muted); }
        code, pre { font-family: \(code); font-size: \(codeSize)px; }
        code { background: var(--code-bg); padding: 0.1em 0.3em; border-radius: 3px; }
        pre { background: var(--code-bg); padding: 0.8em 1em; border-radius: 6px; overflow-x: auto; white-space: pre-wrap; word-wrap: break-word; }
        pre code { background: none; padding: 0; border-radius: 0; font-size: inherit; }
        blockquote { margin-left: 0; padding: 0 1em; color: var(--muted); border-left: 3px solid var(--line); }
        hr { border: 0; border-top: 1px solid var(--line); margin: 1.5em 0; }
        img { max-width: 100%; }
        table { border-collapse: collapse; }
        th, td { border: 1px solid var(--line); padding: 0.3em 0.7em; }
        th { background: var(--code-bg); }
        @media print { main { max-width: none; padding: 0; } pre, blockquote, img, tr { break-inside: avoid; } h1, h2, h3 { break-after: avoid; } }
        """
    }

    private static func fontStack(_ family: String?, fallback: String) -> String {
        guard let family, !family.trimmingCharacters(in: .whitespaces).isEmpty else { return fallback }
        let cleaned = family.filter { $0 != "\"" && $0 != "\\" && $0 != "<" && $0 != ">" && $0 != "\n" }
        return "\"\(cleaned)\", \(fallback)"
    }

    // MARK: Blocks

    private static let fenceStart = regex(#"^ {0,3}(`{3,}|~{3,})[ ]*([^`\s]*)"#)
    private static let heading = regex(#"^ {0,3}(#{1,6})(?:[ ]+(.*?))?(?:[ ]+#+)?[ ]*$"#)
    private static let rule = regex(#"^ {0,3}([-*_])(?: *\1){2,} *$"#)
    private static let quote = regex(#"^ {0,3}> ?(.*)$"#)
    private static let listMarker = regex(#"^( *)([-*+]|\d{1,9}[.)])( +|$)(.*)$"#)
    private static let setext = regex(#"^ {0,3}(=+|-+) *$"#)
    private static let tableSeparator = regex(#"^ *\|? *:?-+:? *(?:\| *:?-+:? *)*\|? *$"#)
    private static let task = regex(#"^\[([ xX])\](?: +(.*))?$"#)

    private static func blocks(_ lines: [String], tight: Bool) -> String {
        var output = ""
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) {
                i += 1
            } else if let m = fenceStart.firstMatch(in: line) {
                let fence = m[1]
                let language = m[2]
                var code: [String] = []
                i += 1
                while i < lines.count, !closes(lines[i], fence: fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                let cls = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
                output += "<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>\n"
            } else if let m = heading.firstMatch(in: line) {
                let level = m[1].count
                output += "<h\(level)>\(inline(m[2].trimmingCharacters(in: .whitespaces)))</h\(level)>\n"
                i += 1
            } else if rule.firstMatch(in: line) != nil {
                output += "<hr>\n"
                i += 1
            } else if quote.firstMatch(in: line) != nil {
                var inner: [String] = []
                while i < lines.count, let m = quote.firstMatch(in: lines[i]) {
                    inner.append(m[1])
                    i += 1
                }
                output += "<blockquote>\n\(blocks(inner, tight: false))</blockquote>\n"
            } else if listMarker.firstMatch(in: line) != nil {
                let (html, next) = list(lines, from: i)
                output += html
                i = next
            } else if line.contains("|"), i + 1 < lines.count, lines[i + 1].contains("-"),
                      tableSeparator.firstMatch(in: lines[i + 1]) != nil, cells(lines[i + 1]).count == cells(line).count {
                let (html, next) = table(lines, from: i)
                output += html
                i = next
            } else {
                var paragraph = [line]
                i += 1
                var level = 0
                while i < lines.count, !isBlank(lines[i]) {
                    if let m = setext.firstMatch(in: lines[i]) {
                        level = m[1].hasPrefix("=") ? 1 : 2
                        i += 1
                        break
                    }
                    if startsBlock(lines[i]) { break }
                    paragraph.append(lines[i])
                    i += 1
                }
                let text = paragraph.map { String($0.drop { $0 == " " }) }.joined(separator: "\n")
                let html = inline(text.trimmingCharacters(in: .whitespacesAndNewlines))
                if level > 0 {
                    output += "<h\(level)>\(html)</h\(level)>\n"
                } else {
                    output += tight ? "\(html)\n" : "<p>\(html)</p>\n"
                }
            }
        }
        return output
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func closes(_ line: String, fence: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = fence.first, trimmed.count >= fence.count else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    /// Whether `line` interrupts a paragraph.
    private static func startsBlock(_ line: String) -> Bool {
        if fenceStart.firstMatch(in: line) != nil || heading.firstMatch(in: line) != nil
            || rule.firstMatch(in: line) != nil || quote.firstMatch(in: line) != nil { return true }
        if let m = listMarker.firstMatch(in: line), !m[4].isEmpty {
            return !m[2].first!.isNumber || m[2].hasPrefix("1")
        }
        return false
    }

    // MARK: Lists

    private static func list(_ lines: [String], from start: Int) -> (String, Int) {
        let first = listMarker.firstMatch(in: lines[start])!
        let baseIndent = first[1].count
        let ordered = first[2].first!.isNumber
        let startNumber = ordered ? Int(first[2].dropLast()) ?? 1 : 1

        var items: [[String]] = []
        var loose = false
        var i = start
        while i < lines.count, let m = listMarker.firstMatch(in: lines[i]), m[1].count < baseIndent + 2,
              m[2].first!.isNumber == ordered {
            let spaces = m[3].count > 4 || m[4].isEmpty ? 1 : m[3].count
            let contentIndent = m[1].count + m[2].count + spaces
            var item = [m[4]]
            i += 1
            while i < lines.count {
                let line = lines[i]
                if isBlank(line) {
                    var j = i
                    while j < lines.count, isBlank(lines[j]) { j += 1 }
                    guard j < lines.count else { i = j; break }
                    if indent(lines[j]) >= contentIndent {
                        item.append(contentsOf: [String](repeating: "", count: j - i))
                        loose = true
                        i = j
                    } else {
                        if listMarker.firstMatch(in: lines[j]).map({ $0[1].count < baseIndent + 2 && $0[2].first!.isNumber == ordered }) == true {
                            loose = true
                        }
                        i = j
                        break
                    }
                } else if indent(line) >= contentIndent {
                    item.append(String(line.dropFirst(contentIndent)))
                    i += 1
                } else if !startsBlock(line), listMarker.firstMatch(in: line) == nil, !(item.last?.isEmpty ?? true) {
                    item.append(line.trimmingCharacters(in: .whitespaces))
                    i += 1
                } else {
                    break
                }
            }
            items.append(item)
            if i < lines.count, isBlank(lines[i]) { i += 1 }
        }

        var html = ordered ? (startNumber == 1 ? "<ol>\n" : "<ol start=\"\(startNumber)\">\n") : "<ul>\n"
        for item in items {
            var lines = item
            var prefix = ""
            var cls = ""
            if let m = task.firstMatch(in: lines[0]) {
                prefix = "<input type=\"checkbox\" disabled\(m[1] == " " ? "" : " checked")> "
                cls = " class=\"task\""
                lines[0] = m[2]
            }
            html += "<li\(cls)>\(prefix)\(blocks(lines, tight: !loose))</li>\n"
        }
        html += ordered ? "</ol>\n" : "</ul>\n"
        return (html, i)
    }

    private static func indent(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    // MARK: Tables

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var result: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
                current.append(character)
            } else if character == "|" {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    private static func table(_ lines: [String], from start: Int) -> (String, Int) {
        let header = cells(lines[start])
        let aligns = cells(lines[start + 1]).map { cell -> String in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): return " style=\"text-align: center\""
            case (false, true): return " style=\"text-align: right\""
            case (true, false): return " style=\"text-align: left\""
            default: return ""
            }
        }
        func row(_ values: [String], _ tag: String) -> String {
            let tds = header.indices.map { column in
                "<\(tag)\(aligns[column])>\(inline(column < values.count ? values[column] : ""))</\(tag)>"
            }
            return "<tr>\(tds.joined())</tr>\n"
        }
        var html = "<table>\n<thead>\n\(row(header, "th"))</thead>\n<tbody>\n"
        var i = start + 2
        while i < lines.count, !isBlank(lines[i]), lines[i].contains("|") {
            html += row(cells(lines[i]), "td")
            i += 1
        }
        return (html + "</tbody>\n</table>\n", i)
    }

    // MARK: Inline

    private static let holdOpen: Character = "\u{E000}"
    private static let holdClose: Character = "\u{E001}"

    private static let backslashEscape = regex(#"\\([\\`*_{}\[\]()#+\-.!|~<>"&])"#)
    private static let codeSpan = regex(#"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)"#, dotAll: true)
    private static let autolink = regex(#"<((?:https?://|mailto:)[^\s<>]+)>"#)
    private static let image = regex(#"!\[([^\]]*)\]\(\s*([^\s)]+)(?:\s+&quot;(.*?)&quot;)?\s*\)"#)
    private static let link = regex(#"\[([^\]]+)\]\(\s*([^\s)]+)(?:\s+&quot;(.*?)&quot;)?\s*\)"#)
    private static let bareURL = regex(#"(?<![\w"=/])https?://[^\s<\x{E000}]*[^\s<.,;:!?)\]'\x{E000}]"#)
    private static let boldItalic = regex(#"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#, dotAll: true)
    private static let strike = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#, dotAll: true)
    private static let boldStar = regex(#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, dotAll: true)
    private static let boldUnderscore = regex(#"(?<!\w)__(?=\S)(.+?)(?<=\S)__(?!\w)"#, dotAll: true)
    private static let italicStar = regex(#"\*(?=[^\s*])(.+?)(?<=[^\s*])\*"#, dotAll: true)
    private static let italicUnderscore = regex(#"(?<!\w)_(?=[^\s_])(.+?)(?<=[^\s_])_(?!\w)"#, dotAll: true)
    private static let hardBreak = regex(#"(?: {2,}|\\)\n"#)
    private static let placeholder = regex("\u{E000}(\\d+)\u{E001}")

    private static func inline(_ source: String) -> String {
        var held: [String] = []
        func hold(_ html: String) -> String {
            held.append(html)
            return "\(holdOpen)\(held.count - 1)\(holdClose)"
        }
        var s = source.filter { $0 != holdOpen && $0 != holdClose }
        s = backslashEscape.replacing(in: s) { hold(escape($0[1])) }
        s = codeSpan.replacing(in: s) {
            var code = $0[2].replacingOccurrences(of: "\n", with: " ")
            if code.count > 2, code.hasPrefix(" "), code.hasSuffix(" "), !code.allSatisfy({ $0 == " " }) {
                code = String(code.dropFirst().dropLast())
            }
            return hold("<code>\(escape(code))</code>")
        }
        s = autolink.replacing(in: s) { hold("<a href=\"\(escape($0[1]))\">\(escape($0[1]))</a>") }
        s = escape(s)
        s = image.replacing(in: s) {
            let alt = placeholder.replacing(in: $0[1]) { _ in "" }
            let title = $0[3].isEmpty ? "" : " title=\"\($0[3])\""
            return hold("<img src=\"\(safeURL($0[2]))\" alt=\"\(alt)\"\(title)>")
        }
        s = link.replacing(in: s) {
            let title = $0[3].isEmpty ? "" : " title=\"\($0[3])\""
            return hold("<a href=\"\(safeURL($0[2]))\"\(title)>") + $0[1] + hold("</a>")
        }
        s = bareURL.replacing(in: s) { hold("<a href=\"\($0[0])\">\($0[0])</a>") }
        s = boldItalic.replacing(in: s) { "<strong><em>\($0[1])</em></strong>" }
        s = strike.replacing(in: s) { "<del>\($0[1])</del>" }
        s = boldStar.replacing(in: s) { "<strong>\($0[1])</strong>" }
        s = boldUnderscore.replacing(in: s) { "<strong>\($0[1])</strong>" }
        s = italicStar.replacing(in: s) { "<em>\($0[1])</em>" }
        s = italicUnderscore.replacing(in: s) { "<em>\($0[1])</em>" }
        s = hardBreak.replacing(in: s) { _ in "<br>\n" }
        for _ in 0..<4 where s.contains(holdOpen) {
            s = placeholder.replacing(in: s) { held[Int($0[1]) ?? 0] }
        }
        return s
    }

    /// `javascript:`, `vbscript:` and `data:` links become `#`. The URL is already HTML-escaped.
    private static func safeURL(_ url: String) -> String {
        let lowered = url.lowercased().filter { !$0.isWhitespace && !$0.isNewline }
        for scheme in ["javascript:", "vbscript:", "data:"] where lowered.hasPrefix(scheme) { return "#" }
        return url
    }

    // MARK: Regex helpers

    private static func regex(_ pattern: String, dotAll: Bool = false) -> NSRegularExpression {
        // The patterns are literals above.
        try! NSRegularExpression(pattern: pattern, options: dotAll ? [.dotMatchesLineSeparators] : [])
    }
}

private extension NSRegularExpression {
    /// Capture groups as strings, group 0 being the whole match; unmatched groups are empty.
    struct Groups {
        let values: [String]
        subscript(_ index: Int) -> String { values[index] }
    }

    func firstMatch(in text: String) -> Groups? {
        let ns = text as NSString
        guard let match = firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return groups(match, ns)
    }

    func replacing(in text: String, with transform: (Groups) -> String) -> String {
        let ns = text as NSString
        let matches = matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var last = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            result += transform(groups(match, ns))
            last = NSMaxRange(match.range)
        }
        return result + ns.substring(from: last)
    }

    private func groups(_ match: NSTextCheckingResult, _ ns: NSString) -> Groups {
        Groups(values: (0..<match.numberOfRanges).map {
            let range = match.range(at: $0)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        })
    }
}
