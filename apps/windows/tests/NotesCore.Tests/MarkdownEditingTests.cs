using NotesCore;

namespace NotesCore.Tests;

/// <summary>Text with the caret or selection marked (<c>⟦⟧</c> for selections) and the edited text marked the same way.</summary>
internal static class EditMarks
{
    /// <summary>The text after the edit, with the new caret as <paramref name="caretMark"/> or the new selection in <c>⟦⟧</c>; null when there is no edit.</summary>
    public static string? Apply(TextEdit? edit, string text, string caretMark = "|")
    {
        if (edit is not { } e) return null;
        var result = text[..e.Range.Location] + e.Replacement + text[e.Range.End..];
        if (e.Selection is not { } sel) return result;
        if (sel.Length == 0) return result.Insert(sel.Location, caretMark);
        return result.Insert(sel.End, "⟧").Insert(sel.Location, "⟦");
    }

    public static (string Text, MarkdownRange Selection) Split(string marked, string caretMark = "|")
    {
        var text = marked;
        var open = text.IndexOf('⟦', StringComparison.Ordinal);
        if (open >= 0)
        {
            text = text.Replace("⟦", "", StringComparison.Ordinal);
            var close = text.IndexOf('⟧', StringComparison.Ordinal);
            text = text.Replace("⟧", "", StringComparison.Ordinal);
            return (text, new MarkdownRange(open, close - open));
        }
        var caret = text.IndexOf(caretMark, StringComparison.Ordinal);
        text = text.Replace(caretMark, "", StringComparison.Ordinal);
        return (text, new MarkdownRange(caret, 0));
    }

    public static string ApplyEdit(string text, TextEdit edit) => text[..edit.Range.Location] + edit.Replacement + text[edit.Range.End..];
}

public class MarkdownEditingTests
{
    private static string? Newline(string marked)
    {
        var (text, sel) = EditMarks.Split(marked);
        return EditMarks.Apply(MarkdownEditing.Newline(text, sel), text);
    }

    private static string? Tab(string marked, bool outdent = false)
    {
        var (text, sel) = EditMarks.Split(marked);
        return EditMarks.Apply(MarkdownEditing.Indent(text, sel, outdent), text);
    }

    [Fact]
    public void BulletsContinue()
    {
        Assert.Equal("- bir\n- |", Newline("- bir|"));
        Assert.Equal("* bir\n* |", Newline("* bir|"));
        Assert.Equal("+ bir\n+ |", Newline("+ bir|"));
        Assert.Equal("  - iç\n  - |", Newline("  - iç|"));
        Assert.Equal("\t- sekme\n\t- |", Newline("\t- sekme|"));
        Assert.Equal("önce\n- bir\n- |\nsonra", Newline("önce\n- bir|\nsonra"));
    }

    [Fact]
    public void SplitsTheItemAtTheCaret()
    {
        Assert.Equal("- şeker\n- |pare", Newline("- şeker|pare"));
        Assert.Equal("- 🙂 gül\n- |ümse", Newline("- 🙂 gül|ümse"));
    }

    [Fact]
    public void OrderedItemsCountUp()
    {
        Assert.Equal("1. a\n2. |", Newline("1. a|"));
        Assert.Equal("9) a\n10) |", Newline("9) a|"));
        Assert.Equal("  10. a\n  11. |", Newline("  10. a|"));
    }

    [Fact]
    public void TasksContinueUnchecked()
    {
        Assert.Equal("- [ ] a\n- [ ] |", Newline("- [ ] a|"));
        Assert.Equal("- [x] ğ\n- [ ] |", Newline("- [x] ğ|"));
        Assert.Equal("1. [X] a\n2. [ ] |", Newline("1. [X] a|"));
    }

    [Fact]
    public void QuotesContinue()
    {
        Assert.Equal("> alıntı\n> |", Newline("> alıntı|"));
        Assert.Equal("> > iç\n> > |", Newline("> > iç|"));
        Assert.Equal(">sıkı\n> |", Newline(">sıkı|"));
        Assert.Equal("> - madde\n> - |", Newline("> - madde|"));
    }

    [Fact]
    public void EmptyItemEndsTheList()
    {
        Assert.Equal("- a\n|", Newline("- a\n- |"));
        Assert.Equal("- a\n|", Newline("- a\n  - |"));
        Assert.Equal("1. a\n|", Newline("1. a\n2. |"));
        Assert.Equal("|", Newline("- [ ] |"));
        Assert.Equal("> a\n|", Newline("> a\n> |"));
        Assert.Equal("> |", Newline("> - |"));
        Assert.Equal("- a\n|", Newline("- a\n-   |"));
    }

    [Fact]
    public void PlainReturnWhereNothingContinues()
    {
        Assert.Null(Newline("düz metin|"));
        Assert.Null(Newline("-|"));
        Assert.Null(Newline("2025.|"));
        Assert.Null(Newline("---|"));
        Assert.Null(Newline("- - -|"));
        Assert.Null(Newline("***|"));
        Assert.Null(Newline("-x|"));
        Assert.Null(Newline("|- a"));
        Assert.Null(Newline("-| a"));
        Assert.Null(Newline("⟦- a⟧"));
        Assert.Null(Newline("```\n- a|\n```"));
        Assert.Equal("```\n- a\n```\n- b\n- |", Newline("```\n- a\n```\n- b|"));
    }

    [Fact]
    public void HandlesCrlfLines()
    {
        // A CR before the LF is not content: an item holding only the marker still ends the list.
        var text = "- a\r\n- \r\n";
        var edit = MarkdownEditing.Newline(text, new MarkdownRange(7, 0));
        Assert.Equal(new MarkdownRange(5, 2), edit?.Range);
        Assert.Equal("", edit?.Replacement);
        var item = MarkdownEditing.Newline("- a\r\nx", new MarkdownRange(3, 0));
        Assert.Equal("\n- ", item?.Replacement);
    }

    [Fact]
    public void RangesAreUtf16()
    {
        var text = "😀 - x\n- 😀 y";
        var caret = text.Length;
        var edit = MarkdownEditing.Newline(text, new MarkdownRange(caret, 0));
        Assert.Equal(new MarkdownRange(caret, 0), edit?.Range);
        Assert.Equal(new MarkdownRange(caret + 3, 0), edit?.Selection);
    }

    [Fact]
    public void IndentsBulletsByTwoAndOrderedByMarkerWidth()
    {
        Assert.Equal("  - a|", Tab("- a|"));
        Assert.Equal("  - [ ] a|", Tab("- [ ] a|"));
        Assert.Equal("   |1. a", Tab("|1. a"));
        Assert.Equal("    10. a|", Tab("10. a|"));
        Assert.Equal("  - a|b", Tab("- a|b"));
        Assert.Equal(">   - a|", Tab("> - a|"));
    }

    [Fact]
    public void Outdents()
    {
        Assert.Equal("- a|", Tab("  - a|", outdent: true));
        Assert.Equal("  - a|", Tab("    - a|", outdent: true));
        Assert.Equal("- a|", Tab(" - a|", outdent: true));
        Assert.Equal("- a|", Tab("\t- a|", outdent: true));
        Assert.Equal("1. a|", Tab("   1. a|", outdent: true));
        Assert.Null(Tab("- a|", outdent: true));
    }

    [Fact]
    public void IndentsEverySelectedLine()
    {
        Assert.Equal("  - ⟦a\n  - b\n  - c⟧", Tab("- ⟦a\n- b\n- c⟧"));
        Assert.Equal("  - ⟦a\n  - b\n⟧- c", Tab("- ⟦a\n- b\n⟧- c"));
        Assert.Equal("- ⟦a\n- b⟧", Tab("  - ⟦a\n- b⟧", outdent: true));
        Assert.Equal("  - ığ⟦ü\n  - şö⟧", Tab("- ığ⟦ü\n- şö⟧"));
    }

    [Fact]
    public void NotAListMeansNoIndentOverride()
    {
        Assert.Null(Tab("düz|"));
        Assert.Null(Tab("- a\n⟦düz\n- b⟧"));
        Assert.Null(Tab("```\n- a|\n```"));
    }

    [Fact]
    public void LinkWrapsSelection()
    {
        static string? Link(string marked)
        {
            var (text, sel) = EditMarks.Split(marked);
            return EditMarks.Apply(MarkdownEditing.Link(text, sel), text);
        }
        Assert.Equal("a [şiir](|) b", Link("a ⟦şiir⟧ b"));
        Assert.Equal("a [|]() b", Link("a | b"));
        Assert.Equal("[|](https://x.com/ğ)", Link("⟦https://x.com/ğ⟧"));
        Assert.Equal("[😀](|)", Link("⟦😀⟧"));
    }

    private const string TaskText = "- [ ] bir\n- [x] iki\n```\n- [ ] kod\n```";

    private static string? Toggled(string text, int at) =>
        MarkdownEditing.ToggleTask(text, at) is { } edit ? EditMarks.ApplyEdit(text, edit) : null;

    [Fact]
    public void TogglesTaskBoxes()
    {
        Assert.Equal("- [x] bir\n- [x] iki\n```\n- [ ] kod\n```", Toggled(TaskText, 2));
        Assert.Equal("- [x] bir\n- [x] iki\n```\n- [ ] kod\n```", Toggled(TaskText, 4));
        Assert.Equal("- [ ] bir\n- [ ] iki\n```\n- [ ] kod\n```", Toggled(TaskText, 12));
        Assert.Null(Toggled(TaskText, 6));
        Assert.Null(Toggled(TaskText, 0));
        var inCode = TaskText.IndexOf("[ ] kod", StringComparison.Ordinal);
        Assert.Null(Toggled(TaskText, inCode));
    }

    [Fact]
    public void CodeBlockScanAgreesWithTheStyler()
    {
        var text = "a\n```swift\nb `\n```\n~~~\nc\n```\n~~~\n````\nd\n```\n````\n- [ ] e\n``` x`\n- [ ] f\n```\nlast\n```";
        var blocks = MarkdownStyler.Spans(text).Where(s => s.Kind == MarkdownSpanKind.CodeBlock).Select(s => s.Range).ToList();
        var start = 0;
        while (start <= text.Length)
        {
            var expected = blocks.Any(b => b.Contains(start));
            Assert.True(expected == MarkdownEditing.IsInsideCodeBlock(start, text), $"line at {start}");
            var next = text.IndexOf('\n', start);
            if (next < 0) break;
            start = next + 1;
        }
    }

    [Fact]
    public void TogglesOnlyTheBoxItself()
    {
        var text = "> 1. [x] ünlü 😀 [ ]\n- [ ] b";
        var box = text.IndexOf("[x]", StringComparison.Ordinal);
        Assert.Equal("> 1. [ ] ünlü 😀 [ ]\n- [ ] b", Toggled(text, box + 1));
        Assert.Null(Toggled(text, box + 4));
        var later = text.IndexOf("[ ]\n", StringComparison.Ordinal);
        Assert.Null(Toggled(text, later));
        Assert.Null(Toggled(text, -1));
        Assert.Null(Toggled(text, 1000));
    }

    [Fact]
    public void Utf16BoundsSurvive()
    {
        // Flags, ZWJ sequences and combining marks around the caret do not confuse offsets.
        Assert.Equal("- 🇹🇷 a\n- |", Newline("- 🇹🇷 a|"));
        Assert.Equal("- İ̇ a\n- |", Newline("- İ̇ a|"));
    }
}
