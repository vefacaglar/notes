using NotesCore;

namespace NotesCore.Tests;

public class MarkdownOutlineTests
{
    [Fact]
    public void ListsAtxHeadingsWithOffsets()
    {
        var text = "# Başlık İ\n\ntext\n## Two ##\n### 😀 Three #\n####### seven\n#NoSpace\n";
        var headings = MarkdownOutline.Headings(text);
        Assert.Equal(["Başlık İ", "Two", "😀 Three"], headings.Select(h => h.Title));
        Assert.Equal([1, 2, 3], headings.Select(h => h.Level));
        Assert.All(headings, h => Assert.StartsWith("#", text[h.Location..], StringComparison.Ordinal));
        Assert.Equal("# Başlık İ\n\ntext\n".Length, headings[1].Location);
    }

    [Fact]
    public void SkipsFencedCodeAndEmptyHeadings()
    {
        var text = "```\n# not a heading\n```\n#\n# \n# Real\n";
        Assert.Equal(["Real"], MarkdownOutline.Headings(text).Select(h => h.Title));
    }

    [Fact]
    public void CrlfDoesNotLeakIntoTitles()
    {
        Assert.Equal(["A", "B"], MarkdownOutline.Headings("# A\r\n## B\r\n").Select(h => h.Title));
    }

    [Fact]
    public void OutlineEntriesPointAtTheLineStart()
    {
        var text = "intro\n   ### Çalışma 😀 ###\n# Üst\r\n";
        var headings = MarkdownOutline.Headings(text);
        Assert.Equal(["Çalışma 😀", "Üst"], headings.Select(h => h.Title));
        Assert.Equal(6, headings[0].Location);
        Assert.Equal(text.IndexOf("# Üst", StringComparison.Ordinal), headings[1].Location);
    }
}
