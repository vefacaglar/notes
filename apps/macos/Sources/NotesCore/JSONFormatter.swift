import Foundation

public struct JSONFormatError: LocalizedError, Equatable, Sendable {
    /// 1-based line and column (in characters) of the offending token.
    public let line: Int
    public let column: Int
    /// UTF-16 offset of the offending token, for selecting it in a text view.
    public let offset: Int
    public let message: String

    public var errorDescription: String? {
        L("Invalid JSON (\(line):\(column)): \(message)")
    }
}

/// Re-indents JSON without parsing values: keys keep their order, strings and numbers keep their exact spelling.
public enum JSONFormatter {
    /// Deepest nesting of objects and arrays that is formatted.
    public static let maxDepth = 1_000

    public static func format(_ text: String, indent: Int = 2) throws -> String {
        try rewrite(text, indent: max(0, indent))
    }

    public static func minify(_ text: String) throws -> String {
        try rewrite(text, indent: nil)
    }

    private static func rewrite(_ text: String, indent: Int?) throws -> String {
        var writer = Writer(Array(text.utf8), indent: indent)
        try writer.run()
        return String(decoding: writer.out, as: UTF8.self)
    }
}

public extension CodeLanguage {
    /// Whether Format is available for this language.
    var canFormat: Bool { self == .json }

    /// The formatted text; throws when the text is invalid or the language has no formatter.
    func format(_ text: String) throws -> String {
        switch self {
        case .json: try JSONFormatter.format(text)
        default: throw JSONFormatError(line: 1, column: 1, offset: 0, message: L("\(displayName) can't be formatted"))
        }
    }
}

// MARK: - Writer

private typealias Byte = UInt8

private struct Writer {
    let s: [Byte]
    let n: Int
    let indent: Int?
    var out: [Byte] = []
    private var i = 0
    /// Open containers: `true` for objects. `items` counts the values written in each.
    private var stack: [(isObject: Bool, items: Int)] = []
    /// Set after an opening bracket or a comma: the next token must start an entry.
    private var expectsItem = false

    init(_ s: [Byte], indent: Int?) {
        self.s = s
        n = s.count
        self.indent = indent
        out.reserveCapacity(s.count + s.count / 4)
        // A UTF-8 byte order mark is not JSON; drop it.
        if s.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
    }

    mutating func run() throws {
        skipWhitespace()
        guard i < n else { throw error(L("empty document")) }
        try value()
        // A loop rather than recursion, so deep nesting cannot overflow the stack.
        while !stack.isEmpty {
            skipWhitespace()
            guard i < n else { throw error(L("unexpected end of document")) }
            if expectsItem {
                expectsItem = false
                try item()
                continue
            }
            let top = stack[stack.count - 1]
            let close: Byte = top.isObject ? 125 : 93 // } ]
            if s[i] == close {
                closeContainer()
            } else if s[i] == 44 { // ,
                i += 1
                out.append(44)
                skipWhitespace()
                guard i < n else { throw error(L("unexpected end of document")) }
                if s[i] == close { throw error(L("trailing commas are not allowed")) }
                expectsItem = true
            } else {
                throw error(top.isObject ? L("expected a comma or a closing brace") : L("expected a comma or a closing bracket"))
            }
        }
        skipWhitespace()
        guard i == n else { throw error(L("unexpected content after the value")) }
        if indent != nil { out.append(10) }
    }

    private mutating func skipWhitespace() {
        while i < n, s[i] == 32 || s[i] == 10 || s[i] == 13 || s[i] == 9 { i += 1 }
    }

    private mutating func newline() {
        guard let indent else { return }
        out.append(10)
        out.append(contentsOf: repeatElement(32, count: indent * stack.count))
    }

    /// A container entry: `"key": value` in objects, a value in arrays.
    private mutating func item() throws {
        stack[stack.count - 1].items += 1
        newline()
        if stack[stack.count - 1].isObject {
            guard s[i] == 34 else {
                throw error(s[i] == 39 || isLetter(s[i]) ? L("keys must be in double quotes") : L("expected a key"))
            }
            try string()
            skipWhitespace()
            guard i < n else { throw error(L("unexpected end of document")) }
            guard s[i] == 58 else { throw error(L("expected a colon")) } // :
            i += 1
            out.append(58)
            if indent != nil { out.append(32) }
            skipWhitespace()
            guard i < n else { throw error(L("unexpected end of document")) }
        }
        try value()
    }

    private mutating func value() throws {
        switch s[i] {
        case 123, 91: // { [
            let isObject = s[i] == 123
            // Indented output grows with the square of the depth; real files never come close. Minifying is linear.
            guard indent == nil || stack.count < JSONFormatter.maxDepth else {
                throw error(L("nesting is too deep (at most \(JSONFormatter.maxDepth) levels)"))
            }
            out.append(s[i])
            i += 1
            stack.append((isObject, 0))
            skipWhitespace()
            guard i < n else { throw error(L("unexpected end of document")) }
            if s[i] == (isObject ? 125 : 93) { closeContainer() } else { expectsItem = true }
        case 34:
            try string()
        case 45, 48...57: // - 0-9
            try number()
        case 116: try literal("true")
        case 102: try literal("false")
        case 110: try literal("null")
        case 39:
            throw error(L("strings must use double quotes"))
        default:
            throw unexpected()
        }
    }

    private mutating func closeContainer() {
        let closed = stack.removeLast()
        if closed.items > 0 { newline() }
        out.append(closed.isObject ? 125 : 93)
        i += 1
    }

    private mutating func string() throws {
        let start = i
        i += 1
        while i < n {
            let b = s[i]
            if b == 34 {
                i += 1
                out.append(contentsOf: s[start..<i])
                return
            }
            if b < 0x20 { throw error(L("unescaped control character in string")) }
            if b == 92 { // \
                guard i + 1 < n else { break }
                switch s[i + 1] {
                case 34, 92, 47, 98, 102, 110, 114, 116: // " \ / b f n r t
                    i += 2
                case 117: // u
                    guard i + 5 < n, s[(i + 2)...(i + 5)].allSatisfy(isHexDigit) else { throw error(L("invalid \\u escape")) }
                    i += 6
                default:
                    throw error(L("invalid escape sequence"))
                }
                continue
            }
            i += 1
        }
        i = start
        throw error(L("unterminated string"))
    }

    private mutating func number() throws {
        let start = i
        if s[i] == 45 { i += 1 }
        guard i < n, isDigit(s[i]) else { i = start; throw error(L("invalid number")) }
        if s[i] == 48 {
            i += 1
        } else {
            while i < n && isDigit(s[i]) { i += 1 }
        }
        if i < n && s[i] == 46 { // .
            i += 1
            guard i < n, isDigit(s[i]) else { i = start; throw error(L("invalid number")) }
            while i < n && isDigit(s[i]) { i += 1 }
        }
        if i < n && (s[i] == 101 || s[i] == 69) { // e E
            i += 1
            if i < n && (s[i] == 43 || s[i] == 45) { i += 1 }
            guard i < n, isDigit(s[i]) else { i = start; throw error(L("invalid number")) }
            while i < n && isDigit(s[i]) { i += 1 }
        }
        if i < n && (isLetter(s[i]) || isDigit(s[i]) || s[i] == 46) { i = start; throw error(L("invalid number")) }
        out.append(contentsOf: s[start..<i])
    }

    private mutating func literal(_ word: StaticString) throws {
        let bytes = UnsafeBufferPointer(start: word.utf8Start, count: word.utf8CodeUnitCount)
        guard i + bytes.count <= n, s[i..<(i + bytes.count)].elementsEqual(bytes) else { throw unexpected() }
        out.append(contentsOf: bytes)
        i += bytes.count
    }

    private func isDigit(_ b: Byte) -> Bool { b >= 48 && b <= 57 }
    private func isLetter(_ b: Byte) -> Bool { (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 }
    private func isHexDigit(_ b: Byte) -> Bool { isDigit(b) || (b >= 65 && b <= 70) || (b >= 97 && b <= 102) }

    private func unexpected() -> JSONFormatError {
        // Show the whole character, not one byte of it.
        var end = i + 1
        while end < n && s[end] & 0xC0 == 0x80 { end += 1 }
        return error(L("unexpected character \"\(String(decoding: s[i..<end], as: UTF8.self))\""))
    }

    private func error(_ message: String) -> JSONFormatError {
        let at = min(i, n)
        var lineStart = 0
        var line = 1
        for k in 0..<at where s[k] == 10 {
            line += 1
            lineStart = k + 1
        }
        let column = String(decoding: s[lineStart..<at], as: UTF8.self).count + 1
        let offset = String(decoding: s[0..<at], as: UTF8.self).utf16.count
        return JSONFormatError(line: line, column: column, offset: offset, message: message)
    }
}
