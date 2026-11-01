using System.Globalization;
using System.Text;

namespace NotesCore;

public enum TableAlignment { None, Left, Center, Right }

/// <summary>Structure edits of the table the caret is in (Format menu).</summary>
public readonly record struct TableCommand(TableCommandKind Kind, bool Flag = false, TableAlignment Alignment = TableAlignment.None)
{
    /// <summary>Adds an empty row below the caret's row (or above it).</summary>
    public static TableCommand AddRow(bool above) => new(TableCommandKind.AddRow, above);
    /// <summary>Adds an empty column after the caret's column (or before it).</summary>
    public static TableCommand AddColumn(bool before) => new(TableCommandKind.AddColumn, before);
    public static TableCommand DeleteRow => new(TableCommandKind.DeleteRow);
    public static TableCommand DeleteColumn => new(TableCommandKind.DeleteColumn);
    public static TableCommand Align(TableAlignment alignment) => new(TableCommandKind.Align, false, alignment);
}

public enum TableCommandKind { AddRow, AddColumn, DeleteRow, DeleteColumn, Align }

/// <summary>
/// GFM pipe tables: detection (shared with the styler) and the editing helpers of the Markdown editor, as pure
/// functions of the text and the selection. See docs/format.md ("Editing helpers"). Lines end at LF only (a CR before
/// the LF is kept as the table's line break); callers whose editor uses CR convert before and after.
/// </summary>
public static class MarkdownTable
{
    /// <summary>One line of a table. Offsets are in the scanned text.</summary>
    internal sealed class TableRow
    {
        public int Start;
        /// <summary>First non-blank unit (after the indentation).</summary>
        public int First;
        /// <summary>End of the line without CR / LF.</summary>
        public int End;
        /// <summary>Start of the next line (one past the LF).</summary>
        public int Next;
        /// <summary>Trimmed content of each cell.</summary>
        public List<MarkdownRange> Cells = [];
        /// <summary>Structural pipes (not escaped, not inside a code span).</summary>
        public List<int> Pipes = [];
        public bool Leading;
    }

    private static (int Start, int End) LineBounds(int location, string text) => MarkdownEditing.LineBounds(location, text);

    // Parsing

    internal static TableRow ParseRow(string s, int start)
    {
        var nl = start;
        while (nl < s.Length && s[nl] != '\n') nl++;
        var end = nl > start && s[nl - 1] == '\r' ? nl - 1 : nl;
        var i = start;
        while (i < end && (s[i] == ' ' || s[i] == '\t')) i++;
        var first = i;
        var pipes = new List<int>();
        while (i < end)
        {
            switch (s[i])
            {
                case '\\':
                    i += 2;
                    break;
                case '`':
                {
                    var j = i;
                    while (j < end && s[j] == '`') j++;
                    int k = j, close = -1;
                    while (k < end)
                    {
                        if (s[k] != '`') { k++; continue; }
                        var l = k;
                        while (l < end && s[l] == '`') l++;
                        if (l - k == j - i) { close = l; break; }
                        k = l;
                    }
                    i = close >= 0 ? close : j;
                    break;
                }
                case '|':
                    pipes.Add(i);
                    i++;
                    break;
                default:
                    i++;
                    break;
            }
        }
        var cuts = new List<(int A, int B)>();
        var from = first;
        foreach (var p in pipes) { cuts.Add((from, p)); from = p + 1; }
        cuts.Add((from, end));
        var leading = pipes.Count > 0 && pipes[0] == first;
        if (leading) cuts.RemoveAt(0);
        if (pipes.Count > 0 && cuts.Count > 0)
        {
            var last = cuts[^1];
            var blank = true;
            for (var x = last.A; x < last.B; x++)
                if (s[x] != ' ' && s[x] != '\t') { blank = false; break; }
            if (blank) cuts.RemoveAt(cuts.Count - 1);
        }
        var cells = cuts.Select(cut =>
        {
            int a = cut.A, b = cut.B;
            while (a < b && (s[a] == ' ' || s[a] == '\t')) a++;
            while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t')) b--;
            return new MarkdownRange(a, b - a);
        }).ToList();
        return new TableRow { Start = start, First = first, End = end, Next = nl + 1, Cells = cells, Pipes = pipes, Leading = leading };
    }

    private static TableAlignment? AlignmentOf(string s, MarkdownRange cell)
    {
        if (cell.Length <= 0) return null;
        int a = cell.Location, b = cell.End;
        var left = s[a] == ':';
        var right = s[b - 1] == ':' && b - a > (left ? 1 : 0);
        var from = a + (left ? 1 : 0);
        var to = b - (right ? 1 : 0);
        if (to <= from) return null;
        for (var i = from; i < to; i++)
            if (s[i] != '-') return null;
        return left && right ? TableAlignment.Center : left ? TableAlignment.Left : right ? TableAlignment.Right : TableAlignment.None;
    }

    private static bool IsDelimiter(TableRow row, string s) =>
        row.Pipes.Count > 0 && row.Cells.Count > 0 && row.Cells.All(c => AlignmentOf(s, c) is not null);

    /// <summary>
    /// The rows of the table whose header line starts at <c>start</c> (header, delimiter row, body rows), or
    /// <c>null</c>. The header needs a pipe and as many cells as the delimiter row below it; body rows are the
    /// following lines with a pipe, up to the first blank line or line without one.
    /// </summary>
    internal static List<TableRow>? Rows(string s, int start)
    {
        if (start >= s.Length) return null;
        var header = ParseRow(s, start);
        if (header.Pipes.Count == 0 || header.First - start > 3 || header.Next > s.Length) return null;
        for (var i = start; i < header.First; i++)
            if (s[i] != ' ') return null;
        var delimiter = ParseRow(s, header.Next);
        if (delimiter.Cells.Count != header.Cells.Count || !IsDelimiter(delimiter, s)) return null;
        var result = new List<TableRow> { header, delimiter };
        var pos = delimiter.Next;
        while (pos < s.Length)
        {
            var body = ParseRow(s, pos);
            if (body.Pipes.Count == 0) break;
            result.Add(body);
            pos = body.Next;
        }
        return result;
    }

    // Rendering

    /// <summary>A table as the live editor renders it: header and body rows with their cells, the delimiter row, alignments.</summary>
    public sealed record Grid(List<Grid.GridRow> Rows, MarkdownRange Delimiter, List<TableAlignment> Alignments)
    {
        /// <summary>One row: its line and its cells.</summary>
        /// <param name="Line">The line without its break (indentation included).</param>
        /// <param name="Cells">Trimmed cell texts; an empty cell is an empty range at the pipe that follows it.</param>
        public sealed record GridRow(MarkdownRange Line, List<MarkdownRange> Cells);

        public int Columns => Rows.Count == 0 ? 0 : Rows.Max(r => r.Cells.Count);
    }

    /// <summary>The table whose header line starts at <c>location</c> of <c>text</c> (offsets are shifted by <c>offsetBy</c>), or <c>null</c>.</summary>
    public static Grid? GetGrid(string text, int location = 0, int offsetBy = 0)
    {
        if (Rows(text, location) is not { Count: >= 2 } rows) return null;
        MarkdownRange Line(TableRow r) => new(r.Start + offsetBy, r.End - r.Start);
        MarkdownRange Shifted(MarkdownRange c) => new(c.Location + offsetBy, c.Length);
        return new Grid(
            new[] { rows[0] }.Concat(rows.Skip(2)).Select(r => new Grid.GridRow(Line(r), r.Cells.Select(Shifted).ToList())).ToList(),
            Line(rows[1]),
            rows[1].Cells.Select(c => AlignmentOf(text, c) ?? TableAlignment.None).ToList());
    }

    // Layout

    /// <summary>Columns taken by a cell's text: wide East Asian characters and emoji count 2, everything else 1.</summary>
    internal static int DisplayWidth(string text)
    {
        var total = 0;
        var e = StringInfo.GetTextElementEnumerator(text);
        while (e.MoveNext())
        {
            var element = (string)e.Current;
            var runes = element.EnumerateRunes().ToList();
            if (runes.Count == 0) continue;
            if (runes.Count > 1 && runes.Any(r => r.Value is 0xFE0F or 0x200D)) { total += 2; continue; }
            var v = runes[0].Value;
            var wide = v is (>= 0x1100 and <= 0x115F) or (>= 0x2E80 and <= 0x303E) or (>= 0x3041 and <= 0x33FF)
                or (>= 0x3400 and <= 0x4DBF) or (>= 0x4E00 and <= 0x9FFF) or (>= 0xA000 and <= 0xA4CF)
                or (>= 0xAC00 and <= 0xD7A3) or (>= 0xF900 and <= 0xFAFF) or (>= 0xFE30 and <= 0xFE6F)
                or (>= 0xFF00 and <= 0xFF60) or (>= 0xFFE0 and <= 0xFFE6) or (>= 0x1F300 and <= 0x1F64F)
                or (>= 0x1F680 and <= 0x1F6FF) or (>= 0x1F900 and <= 0x1F9FF) or (>= 0x20000 and <= 0x3FFFD);
            total += wide ? 2 : 1;
        }
        return total;
    }

    private sealed class Model
    {
        public List<string> Header = [];
        public List<TableAlignment> Aligns = [];
        public List<List<string>> Body = [];
        public int Columns => Header.Count;

        public void Normalize()
        {
            var n = Math.Max(Math.Max(Header.Count, Aligns.Count), Math.Max(Body.Count == 0 ? 0 : Body.Max(r => r.Count), 1));
            while (Header.Count < n) Header.Add("");
            while (Aligns.Count < n) Aligns.Add(TableAlignment.None);
            foreach (var row in Body)
                while (row.Count < n) row.Add("");
        }

        public string Text(int row, int col) => row == 0 ? Header[col] : Body[row - 2][col];
    }

    /// <summary>
    /// The table as aligned source lines, plus where each cell's text starts (UTF-16 offset in the text); indexed by
    /// rendered row (0 header, 1 delimiter, 2... body) and column.
    /// </summary>
    private static (string Text, List<List<int>> Starts) Render(Model m, string eol)
    {
        var widths = Enumerable.Range(0, m.Columns)
            .Select(c => Math.Max(3, Math.Max(DisplayWidth(m.Header[c]), m.Body.Count == 0 ? 0 : m.Body.Max(r => DisplayWidth(r[c])))))
            .ToList();
        var lines = new List<string>();
        var starts = new List<List<int>>();
        var offset = 0;
        void Add(List<string> cells, bool delimiter)
        {
            var line = new StringBuilder("|");
            var rowStarts = new List<int>();
            for (var c = 0; c < m.Columns; c++)
            {
                line.Append(' ');
                var w = widths[c];
                string content;
                var left = 0;
                if (delimiter)
                {
                    static string Dashes(int n) => new('-', n);
                    content = m.Aligns[c] switch
                    {
                        TableAlignment.Left => ":" + Dashes(w - 1),
                        TableAlignment.Right => Dashes(w - 1) + ":",
                        TableAlignment.Center => ":" + Dashes(w - 2) + ":",
                        _ => Dashes(w),
                    };
                }
                else
                {
                    var pad = w - DisplayWidth(cells[c]);
                    left = m.Aligns[c] switch
                    {
                        TableAlignment.Right => pad,
                        TableAlignment.Center => pad / 2,
                        _ => 0,
                    };
                    content = new string(' ', left) + cells[c] + new string(' ', pad - left);
                }
                rowStarts.Add(offset + line.Length + left);
                line.Append(content).Append(" |");
            }
            lines.Add(line.ToString());
            starts.Add(rowStarts);
            offset += line.Length + eol.Length;
        }
        Add(m.Header, false);
        Add([], true);
        foreach (var row in m.Body) Add(row, false);
        return (string.Join(eol, lines), starts);
    }

    // Locating

    private sealed class Located
    {
        public int Base;
        public string Units = "";
        public List<TableRow> Rows = [];
        public string Eol = "\n";
        public int RowIndex;
        public int Col;
        public int Offset;

        public MarkdownRange Range => new(Base + Rows[0].Start, Rows[^1].End - Rows[0].Start);
        public string CurrentText => Units[Rows[0].Start..Rows[^1].End];

        public string Text(MarkdownRange cell) => Units.Substring(cell.Location, cell.Length);

        public Model Model
        {
            get
            {
                var m = new Model
                {
                    Header = Rows[0].Cells.Select(Text).ToList(),
                    Aligns = Rows[1].Cells.Select(c => AlignmentOf(Units, c) ?? TableAlignment.None).ToList(),
                    Body = Rows.Skip(2).Select(r => r.Cells.Select(Text).ToList()).ToList(),
                };
                m.Normalize();
                return m;
            }
        }
    }

    private static Located? Locate(string text, int caret)
    {
        if (caret < 0 || caret > text.Length) return null;
        bool HasPipe((int Start, int End) b) => b.End > b.Start && text.IndexOf('|', b.Start, b.End - b.Start) >= 0;
        var top = LineBounds(caret, text);
        var bottom = top;
        if (!HasPipe(top)) return null;
        while (top.Start > 0)
        {
            var previous = LineBounds(top.Start - 1, text);
            if (!HasPipe(previous)) break;
            top = previous;
        }
        while (bottom.End < text.Length)
        {
            var following = LineBounds(bottom.End + 1, text);
            if (!HasPipe(following)) break;
            bottom = following;
        }
        var baseOffset = top.Start;
        var w = text.Substring(baseOffset, bottom.End - baseOffset);
        var rel = caret - baseOffset;
        var pos = 0;
        while (pos < w.Length)
        {
            if (Rows(w, pos) is { } rows)
            {
                if (rel >= rows[0].Start && rel <= rows[^1].End)
                {
                    if (MarkdownEditing.IsInsideCodeBlock(baseOffset + rows[0].Start, text)) return null;
                    var index = rows.FindIndex(r => rel <= r.End);
                    if (index < 0) index = rows.Count - 1;
                    var row = rows[index];
                    var col = Math.Max(0, Math.Min(row.Pipes.Count(p => p < rel) - (row.Leading ? 1 : 0), row.Cells.Count - 1));
                    var offset = 0;
                    if (col < row.Cells.Count) offset = Math.Min(Math.Max(rel - row.Cells[col].Location, 0), row.Cells[col].Length);
                    var crlf = rows[0].End < w.Length && w[rows[0].End] == '\r';
                    return new Located { Base = baseOffset, Units = w, Rows = rows, Eol = crlf ? "\r\n" : "\n", RowIndex = index, Col = col, Offset = offset };
                }
                pos = rows[^1].Next;
            }
            else
            {
                while (pos < w.Length && w[pos] != '\n') pos++;
                pos++;
            }
        }
        return null;
    }

    /// <summary>Where the selection goes after an edit: inside a cell (<c>offset</c> into its text) or over its whole text.</summary>
    private readonly record struct Place(int Offset, bool Content)
    {
        public static Place Caret(int offset) => new(offset, false);
        public static Place WholeContent => new(0, true);
    }

    private static TextEdit Edit(Located l, Model m, int row, int col, Place place)
    {
        var (replacement, starts) = Render(m, l.Eol);
        var cell = m.Text(row, col);
        var length = cell.Length;
        var selection = place.Content
            ? new MarkdownRange(l.Range.Location + starts[row][col], length)
            : new MarkdownRange(l.Range.Location + starts[row][col] + Math.Min(place.Offset, length), 0);
        if (replacement == l.CurrentText)
            return new TextEdit(new(selection.Location, 0), "", selection);
        return new TextEdit(l.Range, replacement, selection);
    }

    private static bool InOneLine(MarkdownRange selection, string text) =>
        selection.Length <= 0 || text.IndexOf('\n', selection.Location, selection.Length) < 0;

    // Editing

    /// <summary>
    /// Tab / Shift-Tab: moves to the next / previous cell (selecting its text) and re-aligns the table; Tab in the last
    /// cell adds a row. <c>null</c> outside a table, in the delimiter row, or on Shift-Tab in the first cell.
    /// </summary>
    public static TextEdit? Tab(string text, MarkdownRange selection, bool backward)
    {
        if (!InOneLine(selection, text) || Locate(text, selection.Location) is not { } l || l.RowIndex == 1) return null;
        var m = l.Model;
        var columns = m.Columns;
        var current = (l.RowIndex == 0 ? 0 : l.RowIndex - 1) * columns + Math.Min(l.Col, columns - 1);
        var target = current + (backward ? -1 : 1);
        if (target < 0) return null;
        if (target >= (m.Body.Count + 1) * columns) m.Body.Add(Enumerable.Repeat("", columns).ToList());
        var row = target / columns;
        return Edit(l, m, row == 0 ? 0 : row + 1, target % columns, Place.WholeContent);
    }

    /// <summary>
    /// Return inside a row adds an empty row below it (below the header for the header row) and puts the caret in its
    /// first cell; Return in an empty last row removes it and leaves the table for a new line.
    /// </summary>
    public static TextEdit? Newline(string text, MarkdownRange selection)
    {
        if (selection.Length != 0 || Locate(text, selection.Location) is not { } l || l.RowIndex == 1) return null;
        var m = l.Model;
        if (l.RowIndex >= 2 && l.RowIndex == l.Rows.Count - 1 && m.Body[l.RowIndex - 2].All(c => c.Length == 0))
        {
            m.Body.RemoveAt(m.Body.Count - 1);
            var table = Render(m, l.Eol).Text;
            var at = l.Range.Location + table.Length + l.Eol.Length;
            return new TextEdit(l.Range, table + l.Eol, new(at, 0));
        }
        var index = l.RowIndex == 0 ? 0 : l.RowIndex - 1;
        m.Body.Insert(index, Enumerable.Repeat("", m.Columns).ToList());
        return Edit(l, m, index + 2, 0, Place.Caret(0));
    }

    /// <summary>
    /// Format menu: rows, columns and column alignment of the table the caret is in. <c>null</c> when that does not
    /// apply (outside a table, a row command on the header, the last column).
    /// </summary>
    public static TextEdit? Perform(TableCommand command, string text, MarkdownRange selection)
    {
        if (!InOneLine(selection, text) || Locate(text, selection.Location) is not { } l) return null;
        var m = l.Model;
        var col = Math.Min(l.Col, m.Columns - 1);
        var row = l.RowIndex;
        switch (command.Kind)
        {
            case TableCommandKind.AddRow:
            {
                var above = command.Flag;
                if (above && row <= 1) return null;
                var index = above ? row - 2 : (row <= 1 ? 0 : row - 1);
                m.Body.Insert(index, Enumerable.Repeat("", m.Columns).ToList());
                return Edit(l, m, index + 2, col, Place.Caret(0));
            }
            case TableCommandKind.AddColumn:
            {
                var index = command.Flag ? col : col + 1;
                m.Header.Insert(index, "");
                m.Aligns.Insert(index, TableAlignment.None);
                foreach (var r in m.Body) r.Insert(index, "");
                return Edit(l, m, row == 1 ? 0 : row, index, Place.Caret(0));
            }
            case TableCommandKind.DeleteRow:
            {
                if (row < 2) return null;
                m.Body.RemoveAt(row - 2);
                var target = Math.Min(row - 2, m.Body.Count - 1);
                return Edit(l, m, target < 0 ? 0 : target + 2, col, Place.Caret(0));
            }
            case TableCommandKind.DeleteColumn:
            {
                if (m.Columns <= 1) return null;
                m.Header.RemoveAt(col);
                m.Aligns.RemoveAt(col);
                foreach (var r in m.Body) r.RemoveAt(col);
                return Edit(l, m, row == 1 ? 0 : row, Math.Min(col, m.Columns - 1), Place.Caret(0));
            }
            default:
                m.Aligns[col] = command.Alignment;
                return Edit(l, m, row == 1 ? 0 : row, col, Place.Caret(l.Offset));
        }
    }

    // Creating

    /// <summary>
    /// A table with <c>rows</c> rows including the header and <c>columns</c> empty columns, on lines of its own after
    /// the line the selection ends in; the caret goes into the first header cell.
    /// </summary>
    public static TextEdit? Insert(int rows, int columns, string text, MarkdownRange selection)
    {
        var n = Math.Min(Math.Max(columns, 1), 20);
        var r = Math.Min(Math.Max(rows, 1), 200);
        var m = new Model
        {
            Header = Enumerable.Repeat("", n).ToList(),
            Aligns = Enumerable.Repeat(TableAlignment.None, n).ToList(),
            Body = Enumerable.Range(0, r - 1).Select(_ => Enumerable.Repeat("", n).ToList()).ToList(),
        };
        var (table, starts) = Render(m, "\n");
        return MarkdownEditing.InsertBlock(table, starts[0][0], text, selection);
    }

    private static bool IsTrimmed(char c) => c == '\t' || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;

    private static string TrimSpaces(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && IsTrimmed(s[a])) a++;
        while (b > a && IsTrimmed(s[b - 1])) b--;
        return s[a..b];
    }

    /// <summary>
    /// Turns the selected lines (tab-separated, else comma-separated with optional quotes) into a table whose first
    /// line is the header. <c>null</c> when there is no separator, fewer than two columns, or the lines are in code.
    /// </summary>
    public static TextEdit? ConvertSelection(string text, MarkdownRange selection)
    {
        if (MarkdownEditing.ParsedLines(selection, text) is not { } lines || MarkdownEditing.IsInsideCodeBlock(lines[0].Start, text)) return null;
        var raw = lines.Select(l => l.Units[..l.Info.End]).Where(t => !MarkdownEditing.IsBlankText(t)).ToList();
        if (raw.Count == 0) return null;
        var tabs = raw.Any(t => t.Contains('\t'));
        if (!tabs && !raw.Any(t => t.Contains(','))) return null;
        List<string> Split(string line)
        {
            var fields = tabs ? line.Split('\t').ToList() : CsvFields(line);
            return fields.Select(f => TrimSpaces(f).Replace("|", "\\|", StringComparison.Ordinal)).ToList();
        }
        var cells = raw.Select(Split).ToList();
        if (cells.Max(c => c.Count) < 2) return null;
        var m = new Model { Header = cells[0], Aligns = [], Body = cells.Skip(1).ToList() };
        m.Normalize();
        var crlf = lines[0].Info.End < lines[0].Units.Length;
        var eol = crlf ? "\r\n" : "\n";
        var (table, starts) = Render(m, eol);
        var from = lines[0].Start;
        var to = lines[^1].End;
        if (to > from && text[to - 1] == '\r') to--;
        var lead = "";
        if (from > 0)
        {
            var previous = LineBounds(from - 1, text);
            if (!MarkdownEditing.IsBlankText(text.AsSpan(previous.Start, previous.End - previous.Start))) lead = eol;
        }
        if (to < text.Length)
        {
            var following = LineBounds(to + 1, text);
            if (!MarkdownEditing.IsBlankText(text.AsSpan(following.Start, following.End - following.Start))) table += eol;
        }
        var caret = from + lead.Length + starts[0][0];
        return new TextEdit(new(from, to - from), lead + table, new(caret, m.Header[0].Length));
    }

    private static List<string> CsvFields(string line)
    {
        var fields = new List<string>();
        var current = new StringBuilder();
        var quoted = false;
        var chars = new List<string>();
        var e = StringInfo.GetTextElementEnumerator(line);
        while (e.MoveNext()) chars.Add((string)e.Current);
        for (var i = 0; i < chars.Count; i++)
        {
            var c = chars[i];
            if (quoted)
            {
                if (c == "\"")
                {
                    if (i + 1 < chars.Count && chars[i + 1] == "\"") { current.Append('"'); i++; }
                    else quoted = false;
                }
                else
                {
                    current.Append(c);
                }
            }
            else if (c == "\"" && TrimSpaces(current.ToString()).Length == 0)
            {
                quoted = true;
                current.Clear();
            }
            else if (c == ",")
            {
                fields.Add(current.ToString());
                current.Clear();
            }
            else
            {
                current.Append(c);
            }
        }
        fields.Add(current.ToString());
        return fields;
    }
}

/// <summary>Pure geometry of a rendered table (the editor measures the text, this places it).</summary>
public static class TableMetrics
{
    /// <summary>The widest cell of every column; <c>widths[row][column]</c>, rows may be shorter than <c>columns</c>.</summary>
    public static double[] ColumnWidths(IReadOnlyList<IReadOnlyList<double>> widths, int columns)
    {
        var result = new double[columns];
        foreach (var row in widths)
            for (var column = 0; column < row.Count && column < columns; column++)
                result[column] = Math.Max(result[column], row[column]);
        return result;
    }

    /// <summary>
    /// The room left in a column around a cell of <c>cell</c> width: before and after it, by alignment (left and
    /// unaligned: all after; right: all before; center: half each).
    /// </summary>
    public static (double Before, double After) Slack(double cell, double column, TableAlignment alignment)
    {
        var extra = Math.Max(column - cell, 0);
        return alignment switch
        {
            TableAlignment.Right => (extra, 0),
            TableAlignment.Center => (extra / 2, extra / 2),
            _ => (0, extra),
        };
    }
}
