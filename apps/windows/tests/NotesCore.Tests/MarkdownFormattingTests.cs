using NotesCore;

namespace NotesCore.Tests;

public class MarkdownFormattingTests
{
    private static string? Inline(InlineStyle style, string marked)
    {
        var (text, sel) = EditMarks.Split(marked);
        return EditMarks.Apply(MarkdownEditing.ToggleInline(style, text, sel), text);
    }

    private static string? Line(LineStyle style, string marked)
    {
        var (text, sel) = EditMarks.Split(marked);
        return EditMarks.Apply(MarkdownEditing.Apply(style, text, sel), text);
    }

    // Inline

    [Fact]
    public void WrapsSelection()
    {
        Assert.Equal("a **⟦word⟧** b", Inline(InlineStyle.Bold, "a ⟦word⟧ b"));
        Assert.Equal("*⟦şğı İ⟧*", Inline(InlineStyle.Italic, "⟦şğı İ⟧"));
        Assert.Equal("~~⟦x⟧~~", Inline(InlineStyle.Strikethrough, "⟦x⟧"));
        Assert.Equal("`⟦x⟧`", Inline(InlineStyle.Code, "⟦x⟧"));
    }

    [Fact]
    public void UnwrapsOutsideAndInside()
    {
        Assert.Equal("⟦word⟧", Inline(InlineStyle.Bold, "**⟦word⟧**"));
        Assert.Equal("⟦word⟧", Inline(InlineStyle.Bold, "⟦**word**⟧"));
        Assert.Equal("⟦x⟧", Inline(InlineStyle.Code, "`⟦x⟧`"));
    }

    [Fact]
    public void BoldAndItalicCombine()
    {
        Assert.Equal("***⟦a⟧***", Inline(InlineStyle.Italic, "**⟦a⟧**"));
        Assert.Equal("***⟦a⟧***", Inline(InlineStyle.Bold, "*⟦a⟧*"));
        Assert.Equal("**⟦a⟧**", Inline(InlineStyle.Italic, "***⟦a⟧***"));
        Assert.Equal("*⟦a⟧*", Inline(InlineStyle.Bold, "***⟦a⟧***"));
    }

    [Fact]
    public void CaretInWordWrapsTheWord()
    {
        Assert.Equal("say **İstanbu|l** now", Inline(InlineStyle.Bold, "say İstanbu|l now"));
        Assert.Equal("say İstanbu|l now", Inline(InlineStyle.Bold, "say **İstanbu|l** now"));
        Assert.Equal("*|word*", Inline(InlineStyle.Italic, "|word"));
    }

    [Fact]
    public void EmptyCaretInsertsPairAndRemovesIt()
    {
        Assert.Equal("a **|** b", Inline(InlineStyle.Bold, "a | b"));
        Assert.Equal("a | b", Inline(InlineStyle.Bold, "a **|** b"));
        Assert.Equal("a *|* b", Inline(InlineStyle.Italic, "a | b"));
    }

    [Fact]
    public void SurroundingWhitespaceStaysOutside()
    {
        Assert.Equal(" **⟦a b⟧** ", Inline(InlineStyle.Bold, "⟦ a b ⟧"));
    }

    [Fact]
    public void EachLineIsWrappedAlone()
    {
        Assert.Equal("**⟦one**\n**two⟧**", Inline(InlineStyle.Bold, "⟦one\ntwo⟧"));
        Assert.Equal("⟦one\ntwo⟧", Inline(InlineStyle.Bold, "⟦**one**\n**two**⟧"));
    }

    [Fact]
    public void EmojiAndCrlf()
    {
        Assert.Equal("👨‍👩‍👧 **⟦ok⟧** 🎉", Inline(InlineStyle.Bold, "👨‍👩‍👧 ⟦ok⟧ 🎉"));
        Assert.Equal("**⟦a⟧**\r\nb", Inline(InlineStyle.Bold, "⟦a⟧\r\nb"));
        Assert.Equal("**⟦a b**\r\n**c⟧**", Inline(InlineStyle.Bold, "⟦a b\r\nc⟧"));
    }

    // Lines

    [Fact]
    public void BulletsToggleAndReplace()
    {
        Assert.Equal("- |one", Line(LineStyle.Bullet, "|one"));
        Assert.Equal("|one", Line(LineStyle.Bullet, "- |one"));
        Assert.Equal("- ⟦one\n- two⟧", Line(LineStyle.Bullet, "⟦one\ntwo⟧"));
        Assert.Equal("⟦one\ntwo⟧", Line(LineStyle.Bullet, "⟦- one\n- two⟧"));
        Assert.Equal("- ⟦one\n- two⟧", Line(LineStyle.Bullet, "⟦- one\ntwo⟧"));
    }

    [Fact]
    public void NumberedRenumbersAndReplacesOtherMarkers()
    {
        Assert.Equal("1. ⟦a\n2. b\n3. c⟧", Line(LineStyle.Numbered, "⟦- a\n- b\n- c⟧"));
        Assert.Equal("1. ⟦a\n2. b⟧", Line(LineStyle.Numbered, "⟦1. a\n- b⟧"));
        Assert.Equal("⟦a\nb⟧", Line(LineStyle.Numbered, "⟦5. a\n7. b⟧"));
        Assert.Equal("- ⟦a\n- b⟧", Line(LineStyle.Bullet, "⟦1. a\n2. b⟧"));
    }

    [Fact]
    public void BlankLinesAreSkipped()
    {
        Assert.Equal("- ⟦a\n\n- b⟧", Line(LineStyle.Bullet, "⟦a\n\nb⟧"));
        Assert.Equal("1. ⟦a\n\n2. b⟧", Line(LineStyle.Numbered, "⟦a\n\nb⟧"));
    }

    [Fact]
    public void TasksAndQuotes()
    {
        Assert.Equal("- [ ] |a", Line(LineStyle.Task, "|a"));
        Assert.Equal("|a", Line(LineStyle.Task, "- [x] |a"));
        Assert.Equal("- [ ] |a", Line(LineStyle.Task, "- |a"));
        Assert.Equal("- |a", Line(LineStyle.Bullet, "- [ ] |a"));
        Assert.Equal("> ⟦a\n> b⟧", Line(LineStyle.Quote, "⟦a\nb⟧"));
        Assert.Equal("⟦a\nb⟧", Line(LineStyle.Quote, "⟦> a\n> b⟧"));
        Assert.Equal("- |a", Line(LineStyle.Quote, "> - |a"));
    }

    [Fact]
    public void HeadingsReplaceAndToggle()
    {
        Assert.Equal("# |Başlık", Line(LineStyle.Heading(1), "|Başlık"));
        Assert.Equal("## |Başlık", Line(LineStyle.Heading(2), "# |Başlık"));
        Assert.Equal("|Başlık", Line(LineStyle.Heading(2), "## |Başlık"));
        Assert.Equal("|Başlık", Line(LineStyle.Body, "### |Başlık"));
        Assert.Null(Line(LineStyle.Body, "|plain"));
        Assert.Equal("# |item", Line(LineStyle.Heading(1), "- |item"));
        Assert.Equal("> ### |q", Line(LineStyle.Heading(3), "> |q"));
    }

    [Fact]
    public void LineStylesKeepIndentCrlfAndEmoji()
    {
        Assert.Equal("  - |🎉 a", Line(LineStyle.Bullet, "  |🎉 a"));
        Assert.Equal("- ⟦a\r\n- b⟧", Line(LineStyle.Bullet, "⟦a\r\nb⟧"));
        Assert.Equal("1. ⟦a\r\n2. b\r\n⟧", Line(LineStyle.Numbered, "⟦a\r\nb\r\n⟧"));
    }

    [Fact]
    public void NoLineStylesInsideCodeBlocks()
    {
        Assert.Null(Line(LineStyle.Bullet, "```\n|a\n```"));
    }

    // Blocks

    private static string? CodeBlock(string text, int location, int length) =>
        EditMarks.Apply(MarkdownEditing.CodeBlock(text, new MarkdownRange(location, length)), text);

    [Fact]
    public void CodeBlockWrapsAndUnwraps()
    {
        Assert.Equal("```\n⟦a\nb⟧\n```", CodeBlock("a\nb", 0, 3));
        Assert.Equal("```\n⟦a⟧\n```", CodeBlock("a", 0, 0));
        var fenced = "```swift\nlet a = 1\n```";
        Assert.Equal("⟦let a = 1⟧", CodeBlock(fenced, 0, fenced.Length));
        Assert.Equal("```\n|\n```", CodeBlock("", 0, 0));
        Assert.Equal("```\r\n⟦a\r\nb⟧\r\n```", CodeBlock("a\r\nb", 0, 4));
        Assert.NotNull(CodeBlock("```\nx\n```", 4, 1));
    }

    [Fact]
    public void HorizontalRule()
    {
        static string? Rule(string marked)
        {
            var (text, sel) = EditMarks.Split(marked);
            return EditMarks.Apply(MarkdownEditing.HorizontalRule(text, sel), text);
        }
        Assert.Equal("a\n\n---\n|", Rule("a|"));
        Assert.Equal("a\n\n---\n|\nb", Rule("a|\nb"));
        Assert.Equal("a\n\n---\n|", Rule("a\n|"));
        Assert.Equal("---\n|", Rule("|"));
        Assert.Equal("a\n\n---\n|", Rule("a\n\n|"));
        Assert.Null(Rule("```\n|a\n```"));
    }

    [Fact]
    public void ActiveFormatReportsTheCaretStyles()
    {
        static ActiveFormat Active(string marked)
        {
            var (text, sel) = EditMarks.Split(marked);
            return MarkdownEditing.GetActiveFormat(text, sel);
        }
        Assert.Equal(2, Active("## ti|tle").Heading);
        Assert.True(Active("**bo|ld**").Inline.SetEquals([InlineStyle.Bold]));
        Assert.True(Active("***bo|ld***").Inline.SetEquals([InlineStyle.Bold, InlineStyle.Italic]));
        Assert.True(Active("- [ ] a|").Task);
        Assert.True(Active("1. a|").Numbered);
        Assert.True(Active("> a|").Quote);
        Assert.Equal(new ActiveFormat(), Active("plain|"));
    }

    [Fact]
    public void UnicodeWordsAroundTheCaret()
    {
        // Turkish letters, combining marks and digits are word characters; emoji are not.
        Assert.Equal("**ığdır1|** 🎉", Inline(InlineStyle.Bold, "ığdır1| 🎉"));
        Assert.Equal("**i̇ş|** x", Inline(InlineStyle.Bold, "i̇ş| x"));
        Assert.Equal("🎉**|**", Inline(InlineStyle.Bold, "🎉|"));
    }
}
