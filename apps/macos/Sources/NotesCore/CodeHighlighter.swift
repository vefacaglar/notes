import Foundation

public enum CodeLanguage: String, CaseIterable, Sendable {
    case json, swift, javascript, python, shell, yaml, xml, css, cFamily, sql, toml, markdown, plainText

    private static let byExtension: [String: CodeLanguage] = {
        var table: [String: CodeLanguage] = [:]
        let groups: [(CodeLanguage, [String])] = [
            (.json, ["json"]),
            (.swift, ["swift"]),
            (.javascript, ["js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "cts"]),
            (.python, ["py"]),
            (.shell, ["sh", "bash", "zsh"]),
            (.yaml, ["yaml", "yml"]),
            (.xml, ["xml", "html", "htm", "plist", "svg"]),
            (.css, ["css"]),
            (.cFamily, ["c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "kts", "cs", "go", "rs"]),
            (.sql, ["sql"]),
            (.toml, ["toml", "ini"]),
            (.markdown, ["md", "markdown", "mdown", "mkd", "mdenc"]),
        ]
        for (language, extensions) in groups {
            for ext in extensions { table[ext] = language }
        }
        return table
    }()

    /// Lowercased file extensions with a language of their own; anything else is `.plainText`.
    public static var fileExtensions: Set<String> { Set(byExtension.keys) }

    public init(fileExtension: String) {
        self = Self.byExtension[fileExtension.lowercased()] ?? .plainText
    }

    public init(path: String) {
        self.init(fileExtension: (path as NSString).pathExtension)
    }

    public var displayName: String {
        switch self {
        case .json: "JSON"
        case .swift: "Swift"
        case .javascript: "JavaScript"
        case .python: "Python"
        case .shell: "Shell"
        case .yaml: "YAML"
        case .xml: "XML"
        case .css: "CSS"
        case .cFamily: "C"
        case .sql: "SQL"
        case .toml: "TOML"
        case .markdown: "Markdown"
        case .plainText: L("Plain Text")
        }
    }

    /// What Tab inserts: a tab when the file already indents with tabs, otherwise its most common indent step.
    public func indentUnit(for text: String) -> String {
        var tabLines = 0, spaceLines = 0, previous = 0, lines = 0
        var steps = [Int](repeating: 0, count: 9)
        var indent = 0, atLineStart = true, firstIsTab = false
        for byte in text.utf8 {
            if byte == 10 {
                atLineStart = true; indent = 0
                lines += 1
                if lines == 2_000 { break }
                continue
            }
            guard atLineStart else { continue }
            if byte == 32 || byte == 9 {
                if indent == 0 { firstIsTab = byte == 9 }
                indent += 1
                continue
            }
            atLineStart = false
            if indent > 0 && firstIsTab { tabLines += 1; continue }
            if indent > 1 { spaceLines += 1 }
            let step = abs(indent - previous)
            if step >= 2 && step <= 8 { steps[step] += 1 }
            previous = indent
        }
        if tabLines > spaceLines && self != .yaml { return "\t" }
        let best = steps.indices.max { a, b in steps[a] != steps[b] ? steps[a] < steps[b] : a > b } ?? 0
        if steps[best] > 0 { return String(repeating: " ", count: best) }
        switch self {
        case .json, .yaml, .javascript, .xml, .css, .toml, .markdown, .shell: return "  "
        default: return "    "
        }
    }
}

public struct CodeSpan: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case keyword
        case string
        case number
        case comment
        /// `true`, `false`, `null`, `nil`, `None`…, and entities like `&amp;` in markup.
        case literal
        /// Capitalized identifiers, CSS id/class selectors.
        case type
        /// JSON/YAML/TOML keys, XML attribute names, CSS properties, shell variables.
        case property
        /// Markup tags with their brackets, TOML/INI section headers.
        case tag
    }

    /// UTF-16 range, directly usable with `NSString` / `NSTextStorage`.
    public let range: NSRange
    public let kind: Kind

    public init(_ range: NSRange, _ kind: Kind) {
        self.range = range
        self.kind = kind
    }
}

/// A single-pass tokenizer for syntax highlighting, configured per language. Not a parser:
/// it knows comments, strings, numbers, words and a few per-language rules (keys, tags, selectors).
public enum CodeHighlighter {
    /// Non-overlapping spans sorted by location. Markdown is the exception: its spans may nest.
    public static func spans(in text: String, language: CodeLanguage) -> [CodeSpan] {
        switch language {
        case .plainText:
            return []
        case .markdown:
            return markdownSpans(text)
        case .xml:
            var tokenizer = MarkupTokenizer(Array(text.utf16))
            tokenizer.run()
            return tokenizer.spans
        default:
            var tokenizer = Tokenizer(Array(text.utf16), Syntax.of(language))
            tokenizer.run()
            return tokenizer.spans
        }
    }

    /// What an editor must restyle after one edit: the edited range plus every span that appeared,
    /// vanished or changed. Identical spans before the edit and identical shifted spans after it are skipped,
    /// so a plain keystroke restyles its word and a typed `/*` restyles up to where the new comment ends.
    /// `editedRange` is in post-edit coordinates, as `NSTextStorage` reports it.
    public static func changedRange(
        from old: [CodeSpan], to new: [CodeSpan], editedRange: NSRange, changeInLength delta: Int, length: Int
    ) -> NSRange {
        let editStart = editedRange.location
        let editEnd = NSMaxRange(editedRange)
        let oldEditEnd = editEnd - delta

        var head = 0
        while head < old.count, head < new.count, old[head] == new[head],
              NSMaxRange(old[head].range) <= editStart { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head {
            let o = old[old.count - 1 - tail], m = new[new.count - 1 - tail]
            guard o.kind == m.kind, o.range.location >= oldEditEnd, o.range.length == m.range.length,
                  o.range.location + delta == m.range.location else { break }
            tail += 1
        }

        func mapped(_ x: Int) -> Int {
            x <= editStart ? x : x >= oldEditEnd ? x + delta : editEnd
        }
        var lo = editStart, hi = editEnd
        for span in new[head..<(new.count - tail)] {
            lo = min(lo, span.range.location)
            hi = max(hi, NSMaxRange(span.range))
        }
        for span in old[head..<(old.count - tail)] {
            lo = min(lo, mapped(span.range.location))
            hi = max(hi, mapped(NSMaxRange(span.range)))
        }
        hi = min(hi, length)
        lo = min(lo, hi)
        return NSRange(location: lo, length: hi - lo)
    }

    private static func markdownSpans(_ text: String) -> [CodeSpan] {
        MarkdownStyler.spans(in: text).compactMap { span in
            switch span.kind {
            case .heading: CodeSpan(span.range, .keyword)
            case .inlineCode, .codeBlock: CodeSpan(span.range, .string)
            case .link: CodeSpan(span.range, .property)
            case .blockquote: CodeSpan(span.range, .comment)
            case .listMarker, .taskMarker: CodeSpan(span.range, .tag)
            default: nil
            }
        }
    }
}

// MARK: - Language rules

private typealias Unit = UInt16

private extension Unit {
    static let tab: Unit = 9, newline: Unit = 10, cr: Unit = 13, space: Unit = 32
    static let quote: Unit = 34, hash: Unit = 35, dollar: Unit = 36, amp: Unit = 38, apostrophe: Unit = 39
    static let plus: Unit = 43, dash: Unit = 45, dot: Unit = 46, slash: Unit = 47, colon: Unit = 58
    static let lt: Unit = 60, equals: Unit = 61, gt: Unit = 62, question: Unit = 63, at: Unit = 64
    static let lbracket: Unit = 91, backslash: Unit = 92, rbracket: Unit = 93, underscore: Unit = 95
    static let backtick: Unit = 96, lbrace: Unit = 123, rbrace: Unit = 125, bang: Unit = 33, semicolon: Unit = 59

    var isSpace: Bool { self == .space || self == .tab }
    var isWhitespace: Bool { self == .space || self == .tab || self == .newline || self == .cr }
    var isDigit: Bool { self >= 48 && self <= 57 }
    var isUpper: Bool { self >= 65 && self <= 90 }
    var isLower: Bool { self >= 97 && self <= 122 }
    var isLetter: Bool { isUpper || isLower }
    var isAlphanumeric: Bool { isLetter || isDigit }
    var isHighSurrogate: Bool { self >= 0xD800 && self <= 0xDBFF }
}

/// An ASCII word of up to 18 characters packed into 7 bits per character, so keyword lookups never allocate.
private struct Word: Hashable {
    var a: UInt64 = 0
    var b: UInt64 = 0

    init?(_ s: [Unit], _ start: Int, _ end: Int, foldCase: Bool) {
        guard end - start <= 18 else { return nil }
        for i in start..<end {
            var u = s[i]
            guard u < 128 else { return nil }
            if foldCase && u.isUpper { u += 32 }
            if i - start < 9 { a = a << 7 | UInt64(u) } else { b = b << 7 | UInt64(u) }
        }
    }

    static func set(_ words: String, foldCase: Bool = false) -> Set<Word> {
        Set(words.split(separator: " ").compactMap { word in
            let units = Array(word.utf16)
            return Word(units, 0, units.count, foldCase: foldCase)
        })
    }
}

private struct StringRule {
    let open: [Unit]
    let close: [Unit]
    let escapes: Bool
    let multiline: Bool

    init(_ open: String, _ close: String? = nil, escapes: Bool = true, multiline: Bool = false) {
        self.open = Array(open.utf16)
        self.close = Array((close ?? open).utf16)
        self.escapes = escapes
        self.multiline = multiline
    }
}

private struct Syntax {
    var keywords: Set<Word> = []
    var literals: Set<Word> = []
    var foldCase = false
    var lineComments: [[Unit]] = []
    /// `#` starts a comment only at line start or after whitespace (shell, YAML, INI).
    var commentNeedsSpace = false
    var blockComment: (open: [Unit], close: [Unit], nests: Bool)?
    var strings: [StringRule] = []
    /// Quotes open a string only at a value boundary, so `it's` in a plain YAML value stays plain.
    var stringsNeedBoundary = false
    /// `'a'`, `'\n'`: single quotes as character literals only, so Rust lifetimes stay plain.
    var charLiterals = false
    var types = false
    var identifierDash = false
    var identifierDollar = false
    /// `@attribute`, `#directive`.
    var directivePrefixes: [Unit] = []
    /// `$name`, `${name}`, `$1`.
    var variables = false
    /// A string followed by this character is a key.
    var keySeparator: Unit?
    /// Bare keys at line start followed by this character.
    var lineKeySeparator: Unit?
    var signedNumbers = false
    var sections = false
    var yamlBlockScalars = false
    var css = false

    private static let slashComments: (open: [Unit], close: [Unit], nests: Bool) = (Array("/*".utf16), Array("*/".utf16), false)

    static func of(_ language: CodeLanguage) -> Syntax {
        var x = Syntax()
        switch language {
        case .json:
            x.literals = Word.set("true false null")
            x.strings = [StringRule("\"")]
            x.keySeparator = .colon
            x.signedNumbers = true
            // JSONC (settings files) comments come free.
            x.lineComments = [Array("//".utf16)]
            x.blockComment = slashComments
        case .swift:
            x.keywords = Word.set("""
                associatedtype class deinit enum extension fileprivate func import init inout internal let open operator \
                private precedencegroup protocol public rethrows static struct subscript typealias var break case catch \
                continue default defer do else fallthrough for guard if in repeat return throw switch where while as is \
                try await async throws actor any some Self self super get set willSet didSet lazy weak unowned mutating \
                nonmutating override final required convenience dynamic indirect nonisolated isolated consuming borrowing \
                macro
                """)
            x.literals = Word.set("true false nil")
            x.lineComments = [Array("//".utf16)]
            x.blockComment = (Array("/*".utf16), Array("*/".utf16), true)
            x.strings = [StringRule("\"\"\"", multiline: true), StringRule("\"")]
            x.types = true
            x.directivePrefixes = [.at, .hash]
        case .javascript:
            x.keywords = Word.set("""
                break case catch class const continue debugger default delete do else export extends finally for function \
                if import in instanceof new return super switch this throw try typeof var void while with yield let static \
                async await enum implements interface package private protected public namespace declare abstract \
                readonly as from keyof satisfies override
                """)
            x.literals = Word.set("true false null undefined NaN Infinity")
            x.lineComments = [Array("//".utf16)]
            x.blockComment = slashComments
            x.strings = [StringRule("`", multiline: true), StringRule("\""), StringRule("'")]
            x.types = true
            x.identifierDollar = true
            x.directivePrefixes = [.at]
        case .python:
            x.keywords = Word.set("""
                and as assert async await break class continue def del elif else except finally for from global if \
                import in is lambda nonlocal not or pass raise return try while with yield self
                """)
            x.literals = Word.set("True False None")
            x.lineComments = [Array("#".utf16)]
            x.strings = [
                StringRule("\"\"\"", multiline: true), StringRule("'''", multiline: true),
                StringRule("\""), StringRule("'"),
            ]
            x.types = true
            x.directivePrefixes = [.at]
        case .shell:
            x.keywords = Word.set("""
                if then else elif fi for while until do done case esac in function select return local export readonly \
                declare typeset unset shift break continue exit source alias trap eval exec
                """)
            x.literals = Word.set("true false")
            x.lineComments = [Array("#".utf16)]
            x.commentNeedsSpace = true
            x.strings = [
                StringRule("\"", multiline: true), StringRule("'", escapes: false, multiline: true),
                StringRule("`", multiline: true),
            ]
            x.identifierDash = true
            x.variables = true
        case .yaml:
            x.literals = Word.set("true false null yes no", foldCase: true)
            x.foldCase = true
            x.lineComments = [Array("#".utf16)]
            x.commentNeedsSpace = true
            x.strings = [StringRule("\""), StringRule("'", escapes: false)]
            x.stringsNeedBoundary = true
            x.keySeparator = .colon
            x.lineKeySeparator = .colon
            x.identifierDash = true
            x.signedNumbers = true
            x.yamlBlockScalars = true
        case .css:
            x.keywords = Word.set("important")
            x.literals = Word.set("none auto inherit initial unset transparent")
            x.blockComment = slashComments
            x.strings = [StringRule("\""), StringRule("'")]
            x.identifierDash = true
            x.directivePrefixes = [.at]
            x.css = true
        case .cFamily:
            x.keywords = Word.set("""
                auto break case char const continue default do double else enum extern float for goto if inline int long \
                register restrict return short signed sizeof static struct switch typedef union unsigned void volatile \
                while bool class namespace template typename public private protected virtual override final new delete \
                this throw throws try catch using operator friend explicit constexpr noexcept decltype mutable \
                static_cast dynamic_cast reinterpret_cast const_cast concept requires self super instancetype \
                abstract assert boolean byte extends finally implements import instanceof interface native package \
                synchronized transient var sealed permits yield fun val when companion is in lateinit internal suspend \
                reified typealias readonly ref string decimal async await foreach partial unsafe where func go defer \
                chan fallthrough as crate dyn fn impl let loop match mod mut pub trait use Self
                """)
            x.literals = Word.set("true false null nullptr nil NULL YES NO")
            x.lineComments = [Array("//".utf16)]
            x.blockComment = slashComments
            x.strings = [
                StringRule("\"\"\"", multiline: true), StringRule("\""),
                StringRule("`", escapes: false, multiline: true),
            ]
            x.charLiterals = true
            x.types = true
            x.directivePrefixes = [.at, .hash]
        case .sql:
            x.keywords = Word.set("""
                select from where insert into values update set delete create table drop alter add column index primary \
                key foreign references join inner left right outer full cross on as and or not in is like between exists \
                group by order having limit offset union all distinct case when then else end begin commit rollback \
                transaction view trigger default unique check constraint if with returning desc asc cascade database \
                schema replace
                """, foldCase: true)
            x.literals = Word.set("null true false", foldCase: true)
            x.foldCase = true
            x.lineComments = [Array("--".utf16)]
            x.blockComment = slashComments
            x.strings = [StringRule("'", escapes: false, multiline: true), StringRule("\"")]
        case .toml:
            x.literals = Word.set("true false")
            x.lineComments = [Array("#".utf16), Array(";".utf16)]
            x.commentNeedsSpace = true
            x.strings = [
                StringRule("\"\"\"", multiline: true), StringRule("'''", escapes: false, multiline: true),
                StringRule("\""), StringRule("'", escapes: false),
            ]
            x.keySeparator = .equals
            x.lineKeySeparator = .equals
            x.signedNumbers = true
            x.sections = true
        case .xml, .markdown, .plainText:
            break
        }
        return x
    }
}

// MARK: - Tokenizer

private struct Tokenizer {
    let s: [Unit]
    let n: Int
    let x: Syntax
    var spans: [CodeSpan] = []
    /// Inside a CSS declaration value, between `prop:` and `;` / `}`.
    private var cssInValue = false
    /// Column of the YAML key whose `|` / `>` block scalar is open.
    private var blockScalarColumn: Int?

    init(_ s: [Unit], _ syntax: Syntax) {
        self.s = s
        n = s.count
        x = syntax
        spans.reserveCapacity(s.count / 8)
    }

    private mutating func add(_ start: Int, _ end: Int, _ kind: CodeSpan.Kind) {
        let end = min(end, n)
        guard end > start else { return }
        spans.append(CodeSpan(NSRange(location: start, length: end - start), kind))
    }

    private func matches(_ token: [Unit], at i: Int) -> Bool {
        guard i + token.count <= n else { return false }
        for k in token.indices where s[i + k] != token[k] { return false }
        return true
    }

    private func lineEnd(_ i: Int) -> Int {
        var j = i
        while j < n && s[j] != .newline { j += 1 }
        return j
    }

    private func skipSpaces(_ i: Int) -> Int {
        var j = i
        while j < n && s[j].isSpace { j += 1 }
        return j
    }

    private func isIdentifierStart(_ u: Unit) -> Bool {
        u.isLetter || u == .underscore || u >= 0x80 || (x.identifierDollar && u == .dollar)
    }

    private func isIdentifierPart(_ u: Unit) -> Bool {
        u.isAlphanumeric || u == .underscore || u >= 0x80
            || (x.identifierDollar && u == .dollar) || (x.identifierDash && u == .dash)
    }

    mutating func run() {
        var i = 0
        var lineStart = 0
        var atLineStart = true
        while i < n {
            let c = s[i]
            if c == .newline {
                i += 1
                lineStart = i
                atLineStart = true
                continue
            }
            if atLineStart {
                if c.isSpace || c == .cr { i += 1; continue }
                atLineStart = false
                if let next = lineStartRules(i, column: i - lineStart) { i = next; continue }
            }
            i = token(i)
        }
    }

    /// YAML block scalars, line keys and section headers. Returns where to continue, or nil to tokenize normally.
    private mutating func lineStartRules(_ i: Int, column: Int) -> Int? {
        if let open = blockScalarColumn {
            if column > open {
                let end = lineEnd(i)
                add(i, end, .string)
                return end
            }
            blockScalarColumn = nil
        }
        if x.sections && s[i] == .lbracket {
            let end = lineEnd(i)
            var close = end
            while close > i && s[close - 1] != .rbracket { close -= 1 }
            guard close > i else { return nil }
            add(i, close, .tag)
            return close
        }
        guard let separator = x.lineKeySeparator else { return nil }
        var k = i
        if separator == .colon {
            while k < n && s[k] == .dash && (k + 1 == n || s[k + 1].isWhitespace) { k = skipSpaces(k + 1) }
        }
        guard k < n, ![.hash, .semicolon, .quote, .apostrophe, .lbracket, .lbrace, .newline, .cr, .amp, 42, .bang, 124, .gt]
            .contains(s[k]) else { return nil }
        var j = k
        while j < n && s[j] != .newline {
            if s[j] == separator && (separator != .colon || j + 1 == n || s[j + 1].isWhitespace) { break }
            if s[j] == .hash && j > k && s[j - 1].isSpace { return nil }
            if separator == .equals && (s[j] == .quote || s[j] == .apostrophe) { return nil }
            j += 1
        }
        guard j < n, s[j] == separator else { return nil }
        var keyEnd = j
        while keyEnd > k && s[keyEnd - 1].isSpace { keyEnd -= 1 }
        add(k, keyEnd, .property)
        if x.yamlBlockScalars { checkBlockScalar(after: j + 1, column: k - (i - column)) }
        return j + 1
    }

    /// `key: |` or `key: >-` opens a block scalar: following lines indented deeper than the key are text.
    private mutating func checkBlockScalar(after i: Int, column: Int) {
        var j = skipSpaces(i)
        guard j < n, s[j] == 124 || s[j] == .gt else { return } // | or >
        j += 1
        while j < n && (s[j] == .dash || s[j] == .plus || s[j].isDigit) { j += 1 }
        j = skipSpaces(j)
        if j == n || s[j] == .newline || s[j] == .cr || s[j] == .hash { blockScalarColumn = column }
    }

    private mutating func token(_ i: Int) -> Int {
        let c = s[i]
        if let block = x.blockComment, matches(block.open, at: i) {
            return blockComment(i, block)
        }
        for prefix in x.lineComments where matches(prefix, at: i) {
            if x.commentNeedsSpace && i > 0 && !s[i - 1].isWhitespace { continue }
            let end = lineEnd(i)
            add(i, end, .comment)
            return end
        }
        if c == .quote || c == .apostrophe || c == .backtick {
            for rule in x.strings where matches(rule.open, at: i) {
                if x.stringsNeedBoundary && i > 0 && !isValueBoundary(s[i - 1]) { break }
                return string(i, rule)
            }
            if x.charLiterals && c == .apostrophe, let end = charLiteral(i) {
                add(i, end, .string)
                return end
            }
            return i + 1
        }
        let previousIsWord = i > 0 && isIdentifierPart(s[i - 1])
        if !previousIsWord {
            if c.isDigit
                || (c == .dot && i + 1 < n && s[i + 1].isDigit && (i == 0 || s[i - 1] != .dot))
                || (x.signedNumbers && c == .dash && i + 1 < n && s[i + 1].isDigit) {
                return number(i)
            }
        }
        if isIdentifierStart(c) || (x.css && c == .dash && i + 1 < n && (s[i + 1].isLetter || s[i + 1] == .dash)) {
            return word(i)
        }
        if x.directivePrefixes.contains(c), i + 1 < n, isIdentifierStart(s[i + 1]) {
            let end = identifierEnd(i + 1)
            add(i, end, .keyword)
            return end
        }
        if x.variables && c == .dollar { return variable(i) }
        if x.css { return cssPunctuation(i) }
        return i + 1
    }

    private func isValueBoundary(_ u: Unit) -> Bool {
        u.isWhitespace || [.colon, .lbracket, .lbrace, 44, .dash, .question].contains(u) // ,
    }

    private func identifierEnd(_ i: Int) -> Int {
        var j = i
        while j < n && isIdentifierPart(s[j]) { j += 1 }
        return j
    }

    private mutating func blockComment(_ i: Int, _ block: (open: [Unit], close: [Unit], nests: Bool)) -> Int {
        var depth = 1
        var j = i + block.open.count
        while j < n {
            if matches(block.close, at: j) {
                j += block.close.count
                depth -= 1
                if depth == 0 { break }
            } else if block.nests && matches(block.open, at: j) {
                j += block.open.count
                depth += 1
            } else {
                j += 1
            }
        }
        add(i, j, .comment)
        return min(j, n)
    }

    /// Unterminated strings end at the line end, or at the end of the text when they may span lines.
    private mutating func string(_ i: Int, _ rule: StringRule) -> Int {
        var j = i + rule.open.count
        var closed = false
        while j < n {
            let u = s[j]
            if rule.escapes && u == .backslash { j += 2; continue }
            if u == .newline && !rule.multiline { break }
            if u == rule.close[0] && matches(rule.close, at: j) { j += rule.close.count; closed = true; break }
            j += 1
        }
        j = min(j, n)
        if closed, let separator = x.keySeparator {
            let k = skipSpaces(j)
            if k < n && s[k] == separator {
                add(i, j, .property)
                return j
            }
        }
        add(i, j, .string)
        return j
    }

    private func charLiteral(_ i: Int) -> Int? {
        guard i + 2 < n else { return nil }
        if s[i + 1] == .backslash {
            var j = i + 2
            while j < n && j < i + 12 && s[j] != .newline {
                if s[j] == .apostrophe && j > i + 2 { return j + 1 }
                j += 1
            }
            return nil
        }
        let close = i + 1 + (s[i + 1].isHighSurrogate ? 2 : 1)
        return close < n && s[close] == .apostrophe && s[i + 1] != .newline ? close + 1 : nil
    }

    private mutating func number(_ i: Int) -> Int {
        var j = i + 1
        let hex = s[i] == 48 && j < n && (s[j] == 120 || s[j] == 88) // 0x
        while j < n {
            let u = s[j]
            if u.isAlphanumeric || u == .underscore {
                j += 1
            } else if u == .dot && j + 1 < n && s[j + 1].isDigit {
                j += 1
            } else if (u == .plus || u == .dash) && !hex && (s[j - 1] == 101 || s[j - 1] == 69) { // e E
                j += 1
            } else {
                break
            }
        }
        add(i, j, .number)
        return j
    }

    private mutating func word(_ i: Int) -> Int {
        let end = identifierEnd(i + 1)
        if let word = Word(s, i, end, foldCase: x.foldCase) {
            if x.keywords.contains(word) { add(i, end, .keyword); return end }
            if x.literals.contains(word) { add(i, end, .literal); return end }
        }
        if x.css {
            if !cssInValue && isDeclaration(end) {
                add(i, end, .property)
                cssInValue = true
            }
        } else if x.types && s[i].isUpper && s[(i + 1)..<end].contains(where: \.isLower) {
            add(i, end, .type)
        }
        return end
    }

    private mutating func variable(_ i: Int) -> Int {
        guard i + 1 < n else { return i + 1 }
        let u = s[i + 1]
        if u == .lbrace {
            var j = i + 2
            while j < n && s[j] != .rbrace && s[j] != .newline { j += 1 }
            let end = j < n && s[j] == .rbrace ? j + 1 : j
            add(i, end, .property)
            return end
        }
        if u.isAlphanumeric || u == .underscore {
            var j = i + 2
            while j < n && (s[j].isAlphanumeric || s[j] == .underscore) { j += 1 }
            add(i, j, .property)
            return j
        }
        if [.at, 42, .hash, .question, .dollar, .bang, .dash].contains(u) { // @ * # ? $ ! -
            add(i, i + 2, .property)
            return i + 2
        }
        return i + 1
    }

    /// `name:` followed by `;` or `}` before any `{`, so `a:hover {` stays a selector.
    private func isDeclaration(_ end: Int) -> Bool {
        var k = skipSpaces(end)
        guard k < n && s[k] == .colon else { return false }
        while k < n {
            switch s[k] {
            case .lbrace: return false
            case .semicolon, .rbrace: return true
            default: k += 1
            }
        }
        return true
    }

    /// `#id` / `.class` are selectors, `#fff` in a value is a color.
    private mutating func cssPunctuation(_ i: Int) -> Int {
        switch s[i] {
        case .lbrace, .rbrace, .semicolon:
            cssInValue = false
        case .hash where i + 1 < n && isIdentifierPart(s[i + 1]):
            let end = identifierEnd(i + 1)
            add(i, end, cssInValue ? .number : .type)
            return end
        case .dot where !cssInValue && i + 1 < n && isIdentifierStart(s[i + 1]):
            let end = identifierEnd(i + 1)
            add(i, end, .type)
            return end
        default:
            break
        }
        return i + 1
    }
}

// MARK: - Markup

private struct MarkupTokenizer {
    let s: [Unit]
    let n: Int
    var spans: [CodeSpan] = []

    private static let commentOpen = Array("<!--".utf16), commentClose = Array("-->".utf16)
    private static let cdataOpen = Array("<![CDATA[".utf16), cdataClose = Array("]]>".utf16)
    private static let rawTextElements = ["script", "style"]

    init(_ s: [Unit]) {
        self.s = s
        n = s.count
        spans.reserveCapacity(s.count / 8)
    }

    private mutating func add(_ start: Int, _ end: Int, _ kind: CodeSpan.Kind) {
        let end = min(end, n)
        guard end > start else { return }
        spans.append(CodeSpan(NSRange(location: start, length: end - start), kind))
    }

    private func matches(_ token: [Unit], at i: Int) -> Bool {
        guard i + token.count <= n else { return false }
        for k in token.indices where s[i + k] != token[k] { return false }
        return true
    }

    private func isNameStart(_ u: Unit) -> Bool {
        u.isLetter || u == .underscore || u == .colon || u >= 0x80
    }

    private func isNamePart(_ u: Unit) -> Bool {
        isNameStart(u) || u.isDigit || u == .dash || u == .dot
    }

    /// Index just past `close`, or the end of the text when it never comes.
    private func find(_ close: [Unit], from i: Int) -> Int {
        var j = i
        while j < n {
            if s[j] == close[0] && matches(close, at: j) { return j + close.count }
            j += 1
        }
        return n
    }

    mutating func run() {
        var i = 0
        while i < n {
            switch s[i] {
            case .lt:
                if matches(Self.commentOpen, at: i) {
                    let end = find(Self.commentClose, from: i + 4)
                    add(i, end, .comment)
                    i = end
                } else if matches(Self.cdataOpen, at: i) {
                    let end = find(Self.cdataClose, from: i + 9)
                    add(i, end, .string)
                    i = end
                } else if i + 1 < n && s[i + 1] == .bang {
                    let end = find([.gt], from: i + 2)
                    add(i, end, .keyword)
                    i = end
                } else if i + 1 < n && (s[i + 1] == .slash || s[i + 1] == .question || isNameStart(s[i + 1])) {
                    i = tag(i)
                } else {
                    i += 1
                }
            case .amp:
                i = entity(i)
            default:
                i += 1
            }
        }
    }

    private mutating func tag(_ i: Int) -> Int {
        let closing = s[i + 1] == .slash
        var j = i + 1
        if closing || s[j] == .question { j += 1 }
        let nameStart = j
        while j < n && isNamePart(s[j]) { j += 1 }
        add(i, j, .tag)
        let name = (5...6).contains(j - nameStart) ? String(decoding: s[nameStart..<j], as: UTF16.self).lowercased() : ""

        var afterEquals = false
        while j < n {
            let u = s[j]
            if u.isWhitespace { j += 1; continue }
            if u == .gt {
                add(j, j + 1, .tag)
                return !closing && Self.rawTextElements.contains(name) ? rawText(j + 1, name) : j + 1
            }
            if (u == .slash || u == .question) && j + 1 < n && s[j + 1] == .gt {
                add(j, j + 2, .tag)
                return j + 2
            }
            if u == .lt { return j }
            if u == .equals { afterEquals = true; j += 1; continue }
            var k = j
            if u == .quote || u == .apostrophe {
                k = j + 1
                while k < n && s[k] != u { k += 1 }
                k = min(k + 1, n)
                add(j, k, .string)
            } else {
                while k < n && !s[k].isWhitespace && ![.equals, .gt, .lt, .quote, .apostrophe].contains(s[k])
                        && !((s[k] == .slash || s[k] == .question) && k + 1 < n && s[k + 1] == .gt) { k += 1 }
                if k == j { k += 1 } else { add(j, k, afterEquals ? .string : .property) }
            }
            afterEquals = false
            j = k
        }
        return j
    }

    /// `<script>` and `<style>` content is not markup; skip to the closing tag.
    private func rawText(_ i: Int, _ name: String) -> Int {
        let close = Array(("</" + name).utf16)
        var j = i
        while j < n {
            if s[j] == .lt && j + close.count <= n
                && (0..<close.count).allSatisfy({ k in s[j + k] == close[k] || (s[j + k].isUpper && s[j + k] + 32 == close[k]) }) {
                return j
            }
            j += 1
        }
        return n
    }

    private mutating func entity(_ i: Int) -> Int {
        var j = i + 1
        if j < n && s[j] == .hash { j += 1 }
        while j < n && j < i + 32 && s[j].isAlphanumeric { j += 1 }
        guard j < n, s[j] == .semicolon, j > i + 1 else { return i + 1 }
        add(i, j + 1, .literal)
        return j + 1
    }
}
