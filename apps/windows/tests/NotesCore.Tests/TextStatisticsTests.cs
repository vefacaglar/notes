using NotesCore;

namespace NotesCore.Tests;

public class TextStatisticsTests
{
    [Fact]
    public void EmptyTextIsOneLine()
    {
        Assert.Equal(new TextStatistics(0, 0, 1), new TextStatistics(""));
    }

    [Fact]
    public void CountsWordsCharactersAndLines()
    {
        Assert.Equal(new TextStatistics(4, 22, 3), new TextStatistics("hello world\nsecond line\n"));
    }

    [Fact]
    public void CrlfIsOneLineBreak()
    {
        Assert.Equal(new TextStatistics(3, 3, 3), new TextStatistics("a\r\nb\r\nc"));
    }

    [Fact]
    public void TurkishLettersAreOneCharacterEach()
    {
        Assert.Equal(new TextStatistics(3, 20, 1), new TextStatistics("İstanbul şehri ığdır"));
        // Decomposed i + combining dot counts as one character like the precomposed form.
        Assert.Equal(1, new TextStatistics("i̇").Characters);
    }

    [Fact]
    public void EmojiClustersAreOneCharacter()
    {
        Assert.Equal(new TextStatistics(3, 6, 1), new TextStatistics("👍🏽 👨‍👩‍👧 ok"));
        Assert.Equal(new TextStatistics(1, 2, 1), new TextStatistics("🇹🇷🇩🇪"));
    }

    [Fact]
    public void WordsSplitOnAnyWhitespace()
    {
        Assert.Equal(5, new TextStatistics("a\tb  c\u00A0d\n\ne").Words);
    }

    [Fact]
    public void OnlyDocumentedLineBreaksCount()
    {
        Assert.Equal(new TextStatistics(2, 2, 2), new TextStatistics("a\rb"));
        Assert.Equal(new TextStatistics(3, 3, 3), new TextStatistics("a\u2028b\u2029c"));
        // VT, FF and NEL are characters, not line breaks.
        Assert.Equal(new TextStatistics(4, 7, 1), new TextStatistics("a\u000Bb\u000Cc\u0085d"));
    }
}
