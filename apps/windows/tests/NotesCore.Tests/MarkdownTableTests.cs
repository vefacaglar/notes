using NotesCore;

namespace NotesCore.Tests;

public class MarkdownTableTests
{
    private static string? Run(string marked, Func<string, MarkdownRange, TextEdit?> make)
    {
        var (text, sel) = EditMarks.Split(marked, "¦");
        return EditMarks.Apply(make(text, sel), text, "¦");
    }

    private static string? Tab(string marked, bool back) => Run(marked, (t, s) => MarkdownTable.Tab(t, s, back));
    private static string? Enter(string marked) => Run(marked, MarkdownTable.Newline);
    private static string? Go(string marked, TableCommand command) => Run(marked, (t, s) => MarkdownTable.Perform(command, t, s));

    [Fact]
    public void DetectsTables()
    {
        static int? Rows(string text) => MarkdownTable.Rows(text, 0)?.Count;
        Assert.Equal(3, Rows("| a | b |\n| - | - |\n| 1 | 2 |"));
        Assert.Equal(3, Rows("a | b\n:-: | --:\n1 | 2"));
        Assert.Equal(2, Rows("| a | b |\n| - | - |\n\n| 1 | 2 |"));
        Assert.Null(Rows("| a | b |\n| - |\n"));
        Assert.Null(Rows("a | b\n---"));
        Assert.Null(Rows("    | a |\n| - |"));
        Assert.Equal(3, Rows("| a |\r\n| - |\r\n| 1 |"));
    }

    [Fact]
    public void CellsRespectEscapesAndCodeSpans()
    {
        var text = "| a \\| b | `x|y` | z |";
        var row = MarkdownTable.ParseRow(text, 0);
        Assert.Equal(3, row.Cells.Count);
        Assert.Equal(4, row.Pipes.Count);
        var cells = row.Cells.Select(c => text.Substring(c.Location, c.Length)).ToList();
        Assert.Equal(["a \\| b", "`x|y`", "z"], cells);
    }

    [Fact]
    public void TabMovesAndAligns()
    {
        Assert.Equal("| a   | ⟦bb⟧  |\n| --- | --- |\n| 1   | 2   |", Tab("|a¦|bb|\n|-|-|\n|1|2|", false));
        Assert.Equal("| a   | b   |\n| --- | --- |\n| 1   | 2   |\n| ¦    |     |", Tab("| a | b |\n| --- | --- |\n| 1 | 2¦ |", false));
        Assert.Null(Tab("| a¦ | b |\n| --- | --- |", true));
        Assert.Equal("| ⟦a⟧   | b   |\n| --- | --- |\n| 1   | 2   |", Tab("| a | b¦ |\n| --- | --- |\n| 1 | 2 |", true));
        Assert.Null(Tab("plain¦ text", false));
        Assert.Equal("| a   | b   |\n| --- | --- |\n| ⟦1⟧   | 2   |", Tab("| a | b¦ |\n| --- | --- |\n| 1 | 2 |", false));
    }

    [Fact]
    public void TabOnAlignedTableOnlyMovesTheSelection()
    {
        var text = "| a   | b   |\n| --- | --- |\n| 1   | 2   |";
        var edit = MarkdownTable.Tab(text, new MarkdownRange(3, 0), false);
        Assert.Equal("", edit?.Replacement);
        Assert.Equal(0, edit?.Range.Length);
        Assert.Equal(new MarkdownRange(8, 1), edit?.Selection);
    }

    [Fact]
    public void ReturnAddsRowAndExits()
    {
        Assert.Equal("| a   | b   |\n| --- | --- |\n| 1   | 2   |\n| ¦    |     |", Enter("| a | b |\n| --- | --- |\n| 1¦ | 2 |"));
        Assert.Equal("| a   | b   |\n| --- | --- |\n| ¦    |     |\n| 1   | 2   |", Enter("| a¦ | b |\n| --- | --- |\n| 1 | 2 |"));
        Assert.Equal("| a   | b   |\n| --- | --- |\n| 1   | 2   |\n¦", Enter("| a | b |\n| --- | --- |\n| 1 | 2 |\n|  ¦ |  |"));
        Assert.Equal("| a   | b   |\n| --- | --- |\n| 1   | 2   |\n¦\nnext", Enter("| a | b |\n| --- | --- |\n| 1 | 2 |\n|  ¦ |  |\nnext"));
        Assert.Null(Enter("| a | b |\n|¦ --- | --- |"));
        Assert.Null(Enter("no table¦"));
    }

    [Fact]
    public void TurkishEmojiAndWideTextAlign()
    {
        var output = Tab("| İş | Ğ¦ |\n|-|-|\n| 🎉 | 日本 |", false);
        Assert.Equal("| İş  | Ğ    |\n| --- | ---- |\n| ⟦🎉⟧  | 日本 |", output);
    }

    [Fact]
    public void WidthCountsGraphemeClusters()
    {
        Assert.Equal(2, MarkdownTable.DisplayWidth("👨‍👩‍👧"));
        Assert.Equal(2, MarkdownTable.DisplayWidth("❤️"));
        Assert.Equal(2, MarkdownTable.DisplayWidth("éé"));
        Assert.Equal(4, MarkdownTable.DisplayWidth("日本"));
        Assert.Equal(5, MarkdownTable.DisplayWidth("İstan"));
    }

    [Fact]
    public void CrlfIsKept()
    {
        var output = Enter("| a¦ |\r\n| - |\r\n| 1 |\r\nnext");
        Assert.Equal("| a   |\r\n| --- |\r\n| ¦    |\r\n| 1   |\r\nnext", output);
    }

    [Fact]
    public void EscapedPipeAndCodeSpanStayInTheirCell()
    {
        var output = Tab("| a¦ | `x|y` | c \\| d |\n|-|-|-|", false);
        Assert.Equal("| a   | ⟦`x|y`⟧ | c \\| d |\n| --- | ----- | ------ |", output);
    }

    [Fact]
    public void Commands()
    {
        var t = "| a¦ | b |\n| :-- | --: |\n| 1 | 2 |";
        Assert.Equal("| a   |   b |\n| :-- | --: |\n| ¦    |     |\n| 1   |   2 |", Go(t, TableCommand.AddRow(false)));
        Assert.Null(Go(t, TableCommand.AddRow(true)));
        Assert.Equal("| a   | ¦    |   b |\n| :-- | --- | --: |\n| 1   |     |   2 |", Go(t, TableCommand.AddColumn(false)));
        Assert.Equal("| ¦    | a   |   b |\n| --- | :-- | --: |\n|     | 1   |   2 |", Go(t, TableCommand.AddColumn(true)));
        Assert.Equal("|   ¦b |\n| --: |\n|   2 |", Go(t, TableCommand.DeleteColumn));
        Assert.Equal("|  a¦  |   b |\n| :-: | --: |\n|  1  |   2 |", Go(t, TableCommand.Align(TableAlignment.Center)));
        Assert.Equal("| a¦   |   b |\n| --- | --: |\n| 1   |   2 |", Go(t, TableCommand.Align(TableAlignment.None)));
        Assert.Null(Go(t, TableCommand.DeleteRow));
        Assert.Equal("| ¦a   | b   |\n| --- | --- |", Go("| a | b |\n| --- | --- |\n| 1¦ | 2 |", TableCommand.DeleteRow));
        Assert.Equal("| ¦a   |\n| --- |\n| 1   |", Go("| a | b¦ |\n| --- | --- |\n| 1 | 2 |", TableCommand.DeleteColumn));
    }

    [Fact]
    public void InsertsTableWithCaretInFirstHeaderCell()
    {
        Assert.Equal("intro\n\n| ¦    |     |\n| --- | --- |\n|     |     |\n",
            Run("intro¦", (t, s) => MarkdownTable.Insert(2, 2, t, s)));
        Assert.Equal("| ¦    |\n| --- |\n", Run("¦", (t, s) => MarkdownTable.Insert(1, 1, t, s)));
        Assert.Null(Run("```\n¦\n```", (t, s) => MarkdownTable.Insert(2, 2, t, s)));
    }

    [Fact]
    public void ConvertsTabAndCsvLines()
    {
        static string? Convert(string text) => Run(text, MarkdownTable.ConvertSelection);
        Assert.Equal("| ⟦Ad⟧  | Şehir |\n| --- | ----- |\n| Ali | İzmir |", Convert("⟦Ad\tŞehir\nAli\tİzmir⟧"));
        Assert.Equal("| ⟦a⟧   | b,c | d   |\n| --- | --- | --- |\n| 1   | 2   | 3   |", Convert("⟦a,\"b,c\",d\n1,2,3⟧"));
        Assert.Null(Convert("⟦no separator⟧"));
        Assert.Contains("x\\|y", Convert("⟦x|y,z⟧"));
        Assert.StartsWith("text\n\n| ⟦a⟧", Convert("text\n⟦a,b⟧"));
    }
}

public class TableRenderingTests
{
    [Fact]
    public void GridSplitsRowsAndAlignments()
    {
        var text = "x\n| Ad | Şehir |\n| :-- | --: |\n| 🎉 | `a|b` |\n\nson";
        var grid = MarkdownTable.GetGrid(text[2..], 0, 2);
        Assert.NotNull(grid);
        string Sub(MarkdownRange r) => text.Substring(r.Location, r.Length);
        Assert.Equal([TableAlignment.Left, TableAlignment.Right], grid.Alignments);
        Assert.Equal(2, grid.Rows.Count);
        Assert.Equal(["Ad", "Şehir"], grid.Rows[0].Cells.Select(Sub));
        Assert.Equal(["🎉", "`a|b`"], grid.Rows[1].Cells.Select(Sub));
        Assert.Equal("| :-- | --: |", Sub(grid.Delimiter));
        Assert.Equal("| 🎉 | `a|b` |", Sub(grid.Rows[1].Line));
        Assert.Equal(2, grid.Columns);
    }

    [Fact]
    public void NoGridWithoutDelimiterRow()
    {
        Assert.Null(MarkdownTable.GetGrid("a | b\nc | d"));
    }

    [Fact]
    public void ColumnWidthsAndSlack()
    {
        Assert.Equal([10, 12], TableMetrics.ColumnWidths([[10, 4], [6], [8, 12]], 2));
        Assert.Equal((0, 6), TableMetrics.Slack(4, 10, TableAlignment.None));
        Assert.Equal((6, 0), TableMetrics.Slack(4, 10, TableAlignment.Right));
        Assert.Equal((3, 3), TableMetrics.Slack(4, 10, TableAlignment.Center));
        Assert.Equal((0, 0), TableMetrics.Slack(12, 10, TableAlignment.Center));
    }

    [Fact]
    public void CodeBlockText()
    {
        static string Code(string text) => MarkdownCodeBlock.Code(text, new MarkdownRange(0, text.Length));
        Assert.Equal("let a = 1\n\nlet b = 2", Code("```swift\nlet a = 1\n\nlet b = 2\n```"));
        Assert.Equal("```\nx", Code("~~~\n```\nx\n~~~"));
        Assert.Equal("unclosed\nlast", Code("```\nunclosed\nlast\n"));
        Assert.Equal("", Code("```\n```"));
        Assert.Equal("a", Code("```\r\na\r\n```"));
        Assert.Equal("```", Code("````\n```\n````"));
        Assert.Equal("x", Code("\t```\nx\n\t```"));
    }
}
