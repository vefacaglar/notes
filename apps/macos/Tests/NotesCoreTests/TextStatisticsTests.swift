import Testing
@testable import NotesCore

struct TextStatisticsTests {
    @Test func emptyTextIsOneLine() {
        #expect(TextStatistics("") == TextStatistics(words: 0, characters: 0, lines: 1))
    }

    @Test func countsWordsCharactersAndLines() {
        #expect(TextStatistics("hello world\nsecond line\n") == TextStatistics(words: 4, characters: 22, lines: 3))
    }

    @Test func crlfIsOneLineBreak() {
        #expect(TextStatistics("a\r\nb\r\nc") == TextStatistics(words: 3, characters: 3, lines: 3))
    }

    @Test func turkishLettersAreOneCharacterEach() {
        #expect(TextStatistics("İstanbul şehri ığdır") == TextStatistics(words: 3, characters: 20, lines: 1))
        // Decomposed i + combining dot counts as one character like the precomposed form.
        #expect(TextStatistics("i\u{307}").characters == 1)
    }

    @Test func emojiClustersAreOneCharacter() {
        #expect(TextStatistics("👍🏽 👨‍👩‍👧 ok") == TextStatistics(words: 3, characters: 6, lines: 1))
    }

    @Test func wordsSplitOnAnyWhitespace() {
        #expect(TextStatistics("a\tb  c\u{00A0}d\n\ne").words == 5)
    }
}
