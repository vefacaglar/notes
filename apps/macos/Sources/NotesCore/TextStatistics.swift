import Foundation

/// Word, character and line counts for the status bar. See docs/format.md, "Status bar counts".
public struct TextStatistics: Equatable, Sendable {
    /// Runs of non-whitespace characters.
    public var words: Int
    /// Characters as the user sees them (grapheme clusters), line breaks excluded.
    public var characters: Int
    /// Line breaks (LF, CRLF, CR, U+2028, U+2029) plus one: empty text and "a" are one line, "a\n" is two.
    public var lines: Int

    public init(words: Int, characters: Int, lines: Int) {
        self.words = words
        self.characters = characters
        self.lines = lines
    }

    public init(_ text: String) {
        var words = 0
        var characters = 0
        var breaks = 0
        var inWord = false
        for character in text {
            if Self.isLineBreak(character) {
                breaks += 1
                inWord = false
            } else {
                characters += 1
                if character.isWhitespace {
                    inWord = false
                } else if !inWord {
                    inWord = true
                    words += 1
                }
            }
        }
        self.init(words: words, characters: characters, lines: breaks + 1)
    }

    /// Exactly the breaks docs/format.md lists; VT, FF and NEL are ordinary characters.
    private static func isLineBreak(_ character: Character) -> Bool {
        switch character {
        case "\n", "\r", "\r\n", "\u{2028}", "\u{2029}": true
        default: false
        }
    }
}
