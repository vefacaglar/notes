namespace NotesCore.Tests;

public sealed class MarkdownRenderingTests
{
    private static HashSet<string> Shown(string text, int caret, int length = 0, bool reading = false)
    {
        var spans = MarkdownStyler.Spans(text);
        var selection = new MarkdownRange(caret, length);
        var lines = MarkdownRendering.LineRange(selection, text);
        var shown = MarkdownRendering.ShownMarkers(spans, MarkdownRendering.Reach(spans), [selection], lines, text, reading);
        return shown.Select(r => text.Substring(r.Location, r.Length)).ToHashSet();
    }

    [Fact]
    public void LineRangeCoversWholeLinesThroughTheBreak()
    {
        var text = "ab\ncd\nef";
        Assert.Equal(new MarkdownRange(3, 3), MarkdownRendering.LineRange(new MarkdownRange(4, 0), text));
        Assert.Equal(new MarkdownRange(0, 6), MarkdownRendering.LineRange(new MarkdownRange(1, 3), text));
        Assert.Equal(new MarkdownRange(6, 2), MarkdownRendering.LineRange(new MarkdownRange(8, 0), text));
        Assert.Equal(new MarkdownRange(0, 0), MarkdownRendering.LineRange(new MarkdownRange(0, 0), ""));
        // CR is not a line break.
        Assert.Equal(new MarkdownRange(0, 5), MarkdownRendering.LineRange(new MarkdownRange(0, 0), "a\rb\rc"));
    }

    [Fact]
    public void FirstIndexBisectsTheRunningMaximum()
    {
        int[] reach = [3, 3, 8, 8, 10];
        Assert.Equal(0, MarkdownRendering.FirstIndex(reach, 0));
        Assert.Equal(2, MarkdownRendering.FirstIndex(reach, 3));
        Assert.Equal(4, MarkdownRendering.FirstIndex(reach, 8));
        Assert.Equal(5, MarkdownRendering.FirstIndex(reach, 10));
        Assert.Equal(0, MarkdownRendering.FirstIndex([], 5));
        var spans = MarkdownStyler.Spans("# Title **b**");
        var computed = MarkdownRendering.Reach(spans);
        Assert.Equal(spans.Count, computed.Length);
        Assert.True(computed.Zip(computed.Skip(1)).All(p => p.First <= p.Second));
    }

    [Fact]
    public void BulletsAndQuoteMarkersAreRecognized()
    {
        var text = "- a\n* [ ] t\n+ b\n> q\n  > > n\ntext > not\n1. x\n";
        MarkdownRange At(string s, int from = 0) => new(text.IndexOf(s, from, StringComparison.Ordinal), 1);
        Assert.True(MarkdownRendering.IsBullet(new MarkdownRange(0, 1), text));
        Assert.False(MarkdownRendering.IsBullet(At("* [ ]"), text));
        Assert.True(MarkdownRendering.IsBullet(At("+ b"), text));
        Assert.False(MarkdownRendering.IsBullet(new MarkdownRange(0, 2), text));
        Assert.True(MarkdownRendering.IsQuoteMarker(At("> q"), text));
        var nested = text.IndexOf("> > n", StringComparison.Ordinal);
        Assert.True(MarkdownRendering.IsQuoteMarker(new MarkdownRange(nested, 1), text));
        Assert.True(MarkdownRendering.IsQuoteMarker(new MarkdownRange(nested + 2, 1), text));
        Assert.False(MarkdownRendering.IsQuoteMarker(At("> not"), text));
        Assert.False(MarkdownRendering.IsQuoteMarker(new MarkdownRange(0, 1), text));
    }

    [Fact]
    public void DecorationsFollowTheSpanKind()
    {
        var text = "- item\n> quote\n---\n1. one\n";
        var kinds = MarkdownStyler.Spans(text)
            .Select(s => MarkdownRendering.DecorationOf(s, text))
            .Where(d => d is not null).Select(d => d!.Value).ToList();
        Assert.Equal([MarkdownDecoration.Bullet, MarkdownDecoration.QuoteBar, MarkdownDecoration.Rule], kinds);
    }

    [Fact]
    public void EmphasisDelimitersShowTogether()
    {
        // The caret inside the bold text shows both pairs of stars, and only those.
        Assert.Equal(["**"], Shown("a **bold** and *it*", 6));
        Assert.Equal(["*"], Shown("a **bold** and *it*", 17));
        Assert.Empty(Shown("a **bold** and *it*", 1));
        // Either end of the delimiter counts.
        Assert.Equal(["**"], Shown("**x** y", 0));
        Assert.Equal(["**"], Shown("**x** y", 5));
    }

    [Fact]
    public void HeadingMarkerShowsOnlyNextToTheCaret()
    {
        Assert.Equal(["# "], Shown("# Title here", 2));
        Assert.Empty(Shown("# Title here", 8));
        Assert.Equal(["# "], Shown("# Title here", 0));
    }

    [Fact]
    public void LinkBracketsAndDestinationShowTogether()
    {
        var text = "see [the docs](https://example.com/x) now";
        var shown = Shown(text, 8);
        Assert.Contains("[", shown);
        Assert.Contains("](https://example.com/x)", shown);
        Assert.Empty(Shown(text, 1));
    }

    [Fact]
    public void FencesShowWhenTheCaretIsOnTheirLine()
    {
        var text = "```swift\nlet a = 1\n```\n";
        Assert.Equal(["```swift"], Shown(text, 3));
        Assert.Empty(Shown(text, 12));
        Assert.Equal(["```"], Shown(text, 20));
    }

    [Fact]
    public void DrawnMarkersShowAsSourceWhenTouched()
    {
        Assert.Equal(["-"], Shown("- a\n- b", 1));
        Assert.Empty(Shown("- a\n- b", 6));
        Assert.Equal(["---"], Shown("x\n\n---\n", 4));
        Assert.Equal(["> "], Shown("> q\n", 1));
    }

    [Fact]
    public void ReadingModeShowsNothing()
    {
        Assert.Empty(Shown("# Title **b**", 3, 4, reading: true));
    }

    [Fact]
    public void ASelectionTouchesEveryMarkerItReaches()
    {
        var text = "**a** **b** **c**";
        var spans = MarkdownStyler.Spans(text);
        var shown = MarkdownRendering.ShownMarkers(spans, MarkdownRendering.Reach(spans), [new MarkdownRange(2, 8)],
            new MarkdownRange(0, text.Length), text, reading: false);
        Assert.Equal([0, 3, 6, 9], shown.Select(r => r.Location).Order());
    }

    [Fact]
    public void FenceInfoTakesTheFirstWord()
    {
        Assert.Equal("swift", MarkdownRendering.FenceInfo("```swift", false));
        Assert.Equal("swift", MarkdownRendering.FenceInfo("  ~~~ swift {.x}  ", false));
        Assert.Equal("json,ignore", MarkdownRendering.FenceInfo("```json,ignore", false));
        Assert.Equal("json", MarkdownRendering.FenceInfo("```json,ignore", true));
        Assert.Equal("", MarkdownRendering.FenceInfo("```", false));
        Assert.Equal("", MarkdownRendering.FenceInfo("```  ", true));
        Assert.Equal("rust}", MarkdownRendering.FenceInfo("```{rust}", true));
    }

    [Fact]
    public void LanguageForInfoUsesAliases()
    {
        Assert.Equal(CodeLanguage.JavaScript, MarkdownRendering.LanguageForInfo("JavaScript"));
        Assert.Equal(CodeLanguage.Python, MarkdownRendering.LanguageForInfo("python"));
        Assert.Equal(CodeLanguage.CFamily, MarkdownRendering.LanguageForInfo("c#"));
        Assert.Equal(CodeLanguage.CFamily, MarkdownRendering.LanguageForInfo("C++"));
        Assert.Equal(CodeLanguage.Json, MarkdownRendering.LanguageForInfo("jsonc"));
        Assert.Equal(CodeLanguage.PlainText, MarkdownRendering.LanguageForInfo("nonsense"));
        Assert.Equal(CodeLanguage.PlainText, MarkdownRendering.LanguageForInfo(""));
        // The Turkish dotted/dotless i must not break the lookup.
        Assert.Equal(CodeLanguage.PlainText, MarkdownRendering.LanguageForInfo("İ"));
        Assert.Equal(CodeLanguage.Sql, MarkdownRendering.LanguageForInfo("SQL"));
    }

    [Fact]
    public void FencedCodeFindsTheInnerLinesAndLanguage()
    {
        var text = "intro\n```py\nprint(1)\nx = 2\n```\n";
        var block = MarkdownStyler.Spans(text).Single(s => s.Kind.Kind == MarkdownKind.CodeBlock).Range;
        var (inner, language) = MarkdownRendering.FencedCode(text, block)!.Value;
        Assert.Equal(CodeLanguage.Python, language);
        Assert.Equal("print(1)\nx = 2\n```", text.Substring(inner.Location, inner.Length));
        Assert.Null(MarkdownRendering.FencedCode("```", new MarkdownRange(0, 3)));
        Assert.Null(MarkdownRendering.FencedCode("```\n", new MarkdownRange(0, 3)));
    }

    [Fact]
    public void FenceLabelIsTheFirstWord()
    {
        var text = "```swift {x}\ncode\n```";
        var block = MarkdownStyler.Spans(text).Single(s => s.Kind.Kind == MarkdownKind.CodeBlock).Range;
        Assert.Equal("swift", MarkdownRendering.FenceLabel(text, block));
        var bare = "```\ncode\n```";
        Assert.Equal("", MarkdownRendering.FenceLabel(bare, MarkdownStyler.Spans(bare).Single(s => s.Kind.Kind == MarkdownKind.CodeBlock).Range));
    }

    [Fact]
    public void ImagesShrinkToFitButNeverGrow()
    {
        Assert.Equal((100, 50), InlineImageLayout.Size(100, 50, 500));
        Assert.Equal((200, 100), InlineImageLayout.Size(400, 200, 200));
        // At most 420 tall.
        Assert.Equal((210, 420), InlineImageLayout.Size(500, 1000, 800));
        Assert.Equal((0, 0), InlineImageLayout.Size(0, 10, 100));
        Assert.Equal((0, 0), InlineImageLayout.Size(10, 10, 0));
    }

    [Fact]
    public void ReservedHeightCountsOnlyShownImages()
    {
        Assert.Equal(0, InlineImageLayout.ReservedHeight([]));
        Assert.Equal(0, InlineImageLayout.ReservedHeight([0, 0]));
        Assert.Equal(6 + 100 + 6, InlineImageLayout.ReservedHeight([100]));
        Assert.Equal(6 + 100 + 6 + 50 + 6, InlineImageLayout.ReservedHeight([100, 0, 50]));
    }

    [Fact]
    public void DensityOnlyShrinksHighDpiFiles()
    {
        Assert.Equal(1, InlineImageLayout.Density(72));
        Assert.Equal(1, InlineImageLayout.Density(0));
        Assert.Equal(2, InlineImageLayout.Density(144));
        Assert.Equal(4, InlineImageLayout.Density(600));
    }
}
