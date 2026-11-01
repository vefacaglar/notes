using System.Globalization;
using System.Text;

namespace NotesCore;

/// <summary>Inline Markdown styles of the formatting bar and the Format menu.</summary>
public enum InlineStyle { Bold, Italic, Strikethrough, Code }

public enum LineStyleKind { Bullet, Numbered, Task, Quote, Heading, Body }

/// <summary>Line-level styles: each applies to every line of the selection and replaces the other list or heading marker.</summary>
public readonly record struct LineStyle(LineStyleKind Kind, int Level = 0)
{
    public static LineStyle Bullet => new(LineStyleKind.Bullet);
    public static LineStyle Numbered => new(LineStyleKind.Numbered);
    public static LineStyle Task => new(LineStyleKind.Task);
    public static LineStyle Quote => new(LineStyleKind.Quote);
    /// <summary>Removes a heading marker (list markers stay).</summary>
    public static LineStyle Body => new(LineStyleKind.Body);
    /// <summary><c>#</c> to <c>######</c> (1 to 6).</summary>
    public static LineStyle Heading(int level) => new(LineStyleKind.Heading, level);
}

/// <summary>What the caret (or the start of the selection) is in; the formatting bar highlights these.</summary>
public sealed class ActiveFormat : IEquatable<ActiveFormat>
{
    public HashSet<InlineStyle> Inline { get; } = [];
    /// <summary>0 when the line is not a heading.</summary>
    public int Heading { get; set; }
    public bool Bullet { get; set; }
    public bool Numbered { get; set; }
    public bool Task { get; set; }
    public bool Quote { get; set; }

    public bool Equals(ActiveFormat? other) =>
        other is not null && Inline.SetEquals(other.Inline) && Heading == other.Heading && Bullet == other.Bullet
        && Numbered == other.Numbered && Task == other.Task && Quote == other.Quote;

    public override bool Equals(object? obj) => Equals(obj as ActiveFormat);

    public override int GetHashCode() => HashCode.Combine(Inline.Count, Heading, Bullet, Numbered, Task, Quote);
}

/// <summary>
/// Formatting actions of the Markdown editor as pure functions of the text and the selection (UTF-16).
/// See docs/format.md ("Editing helpers"). Lines end at LF only, like the rest of the core.
/// </summary>
public static partial class MarkdownEditing
{
    private readonly record struct Change(int At, int Removed, string Inserted);

    private static string MarkerOf(InlineStyle style) => style switch
    {
        InlineStyle.Bold => "**",
        InlineStyle.Italic => "*",
        InlineStyle.Strikethrough => "~~",
        _ => "`",
    };

    private static bool IsBlankUnit(char u) => u == ' ' || u == '\t' || u == '\r';

    // Inline

    /// <summary>
    /// Ctrl+B, Ctrl+I and friends: wraps the selection (or the word at the caret) in the style's marker, or removes the
    /// marker when it is already there. Surrounding whitespace stays outside; every line of a multi-line selection is
    /// wrapped on its own. An empty selection away from a word inserts the pair with the caret inside.
    /// </summary>
    public static TextEdit? ToggleInline(InlineStyle style, string text, MarkdownRange selection)
    {
        if (selection.Location < 0 || selection.End > text.Length) return null;
        var marker = MarkerOf(style);
        var m = marker.Length;
        int? caret = null;
        List<MarkdownRange> segments = selection.Length == 0 ? [] : InlineSegments(selection, text);
        if (segments.Count == 0)
        {
            var at = selection.Location;
            caret = at;
            var word = WordRange(at, text);
            if (word.Length > 0)
            {
                segments = [word];
            }
            else
            {
                var (left, right) = MarkerRuns(new MarkdownRange(at, 0), marker[0], text);
                if (left == m && right == m)
                    return new TextEdit(new(at - m, 2 * m), "", new(at - m, 0));
                return new TextEdit(new(at, 0), marker + marker, new(at + m, 0));
            }
        }

        // Kind: 0 outside the segment, 1 inside it, 2 not styled.
        (int Kind, int K) State(MarkdownRange seg)
        {
            var (left, right) = MarkerRuns(seg, marker[0], text);
            if (Removal(style, left, right) is { } k) return (0, k);
            var leading = UnitRun(seg.Location, 1, seg.End, marker[0], text);
            var trailing = UnitRun(seg.End - 1, -1, seg.Location - 1, marker[0], text);
            if (leading + trailing < seg.Length && Removal(style, leading, trailing) is { } inner) return (1, inner);
            return (2, 0);
        }
        var states = segments.Select(State).ToList();
        var unwrapAll = states.All(s => s.Kind != 2);

        var changes = new List<Change>();
        var inners = new List<(int Start, int End, int OldStart)>();
        var delta = 0;
        for (var i = 0; i < segments.Count; i++)
        {
            var seg = segments[i];
            var (kind, k) = states[i];
            if (unwrapAll)
            {
                if (kind == 0)
                {
                    changes.Add(new Change(seg.Location - k, k, ""));
                    changes.Add(new Change(seg.End, k, ""));
                    inners.Add((seg.Location - k + delta, seg.Location - k + delta + seg.Length, seg.Location));
                    delta -= 2 * k;
                }
                else
                {
                    changes.Add(new Change(seg.Location, k, ""));
                    changes.Add(new Change(seg.End - k, k, ""));
                    inners.Add((seg.Location + delta, seg.Location + delta + seg.Length - 2 * k, seg.Location + k));
                    delta -= 2 * k;
                }
            }
            else if (kind == 2)
            {
                changes.Add(new Change(seg.Location, 0, marker));
                changes.Add(new Change(seg.End, 0, marker));
                inners.Add((seg.Location + m + delta, seg.Location + m + delta + seg.Length, seg.Location));
                delta += 2 * m;
            }
            else
            {
                inners.Add((seg.Location + delta, seg.Location + delta + seg.Length, seg.Location));
            }
        }
        var composed = Compose(changes, text);
        if (composed is null || inners.Count == 0) return null;
        var (range, replacement) = composed.Value;
        var first = inners[0];
        var last = inners[^1];
        MarkdownRange newSelection;
        if (caret is { } c)
        {
            var place = Math.Min(Math.Max(c - first.OldStart, 0), first.End - first.Start);
            newSelection = new(first.Start + place, 0);
        }
        else
        {
            newSelection = new(first.Start, last.End - first.Start);
        }
        return new TextEdit(range, replacement, newSelection);
    }

    /// <summary>Units of marker removal when the style is present, given the marker-character runs on both sides.</summary>
    private static int? Removal(InlineStyle style, int left, int right)
    {
        var low = Math.Min(left, right);
        return style switch
        {
            InlineStyle.Bold or InlineStyle.Strikethrough => low >= 2 ? 2 : null,
            InlineStyle.Italic => low % 2 == 1 ? 1 : null,
            _ => left == 1 && right == 1 ? 1 : null,
        };
    }

    private static int UnitRun(int from, int step, int limit, char ch, string text)
    {
        int i = from, count = 0;
        while (i != limit && i >= 0 && i < text.Length && text[i] == ch) { count++; i += step; }
        return count;
    }

    private static (int Left, int Right) MarkerRuns(MarkdownRange range, char ch, string text) =>
        (UnitRun(range.Location - 1, -1, -1, ch, text), UnitRun(range.End, 1, text.Length, ch, text));

    /// <summary>The non-blank part of every line piece of the selection.</summary>
    private static List<MarkdownRange> InlineSegments(MarkdownRange selection, string text)
    {
        var result = new List<MarkdownRange>();
        var pos = selection.Location;
        var end = selection.End;
        while (pos <= end)
        {
            var stop = pos;
            while (stop < end && text[stop] != '\n') stop++;
            int a = pos, b = stop;
            while (a < b && IsBlankUnit(text[a])) a++;
            while (b > a && IsBlankUnit(text[b - 1])) b--;
            if (b > a) result.Add(new MarkdownRange(a, b - a));
            pos = stop + 1;
        }
        return result;
    }

    /// <summary>Letters, marks and numbers: Unicode categories L*, M* and N*, like Foundation's <c>alphanumerics</c>.</summary>
    private static bool IsWordUnit(char u) => char.GetUnicodeCategory(u) switch
    {
        UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
            or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter
            or UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark
            or UnicodeCategory.DecimalDigitNumber or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber => true,
        _ => false,
    };

    /// <summary>The run of letters and digits (marks included) around the caret; empty when the caret touches none.</summary>
    internal static MarkdownRange WordRange(int caret, string text)
    {
        int a = caret, b = caret;
        while (a > 0 && IsWordUnit(text[a - 1])) a--;
        while (b < text.Length && IsWordUnit(text[b])) b++;
        return new MarkdownRange(a, b - a);
    }

    private static (MarkdownRange Range, string Replacement)? Compose(List<Change> changes, string text)
    {
        if (changes.Count == 0) return null;
        var first = changes[0];
        var sb = new StringBuilder();
        var pos = first.At;
        foreach (var change in changes)
        {
            sb.Append(text, pos, change.At - pos).Append(change.Inserted);
            pos = change.At + change.Removed;
        }
        return (new MarkdownRange(first.At, pos - first.At), sb.ToString());
    }

    // Lines

    internal sealed class ParsedLine
    {
        public int Start { get; }
        public string Units { get; }
        public LineInfo Info { get; }
        /// <summary>0 or the ATX level.</summary>
        public int Heading { get; }
        /// <summary>Offset of the text after the markers.</summary>
        public int ContentOffset { get; }

        public int End => Start + Units.Length;
        public string Quote => Units[..Info.QuoteEnd];
        public string Content => Units[ContentOffset..Info.End];
        public string Terminator => Units[Info.End..];
        public string Indent => Heading == 0 ? Units[Info.QuoteEnd..Info.IndentEnd] : "";
        public bool IsBlank => Info.Marker is null && Heading == 0 && Info.IndentEnd >= Info.End;

        public ParsedLine(int start, string units)
        {
            Start = start;
            Units = units;
            Info = new LineInfo(units);
            var level = 0;
            var offset = Math.Min(Info.ContentStart, Info.End);
            if (Info.Marker is null)
            {
                var i = Info.QuoteEnd;
                while (i < Info.End && i - Info.QuoteEnd < 3 && units[i] == ' ') i++;
                var j = i;
                while (j < Info.End && units[j] == '#') j++;
                if (j - i is >= 1 and <= 6 && (j == Info.End || units[j] == ' ' || units[j] == '\t'))
                {
                    level = j - i;
                    offset = j;
                    while (offset < Info.End && (units[offset] == ' ' || units[offset] == '\t')) offset++;
                }
            }
            Heading = level;
            ContentOffset = offset;
        }
    }

    /// <summary>The lines the selection touches (a selection ending right after a line break leaves out the next line).</summary>
    internal static List<ParsedLine>? ParsedLines(MarkdownRange selection, string text)
    {
        if (selection.Location < 0 || selection.End > text.Length) return null;
        var lines = new List<ParsedLine>();
        var cursor = LineBounds(selection.Location, text).Start;
        var stop = selection.End;
        if (selection.Length > 0 && stop > 0 && text[stop - 1] == '\n') stop--;
        while (true)
        {
            var bounds = LineBounds(cursor, text);
            lines.Add(new ParsedLine(bounds.Start, text.Substring(bounds.Start, bounds.End - bounds.Start)));
            if (bounds.End >= stop || bounds.End >= text.Length) break;
            cursor = bounds.End + 1;
        }
        return lines;
    }

    private static bool Has(LineStyle style, ParsedLine line) => style.Kind switch
    {
        LineStyleKind.Bullet => line.Info.Marker is { Ordered: false } && line.Info.Task is null,
        LineStyleKind.Numbered => line.Info.Marker is { Ordered: true },
        LineStyleKind.Task => line.Info.Task is not null,
        LineStyleKind.Quote => line.Info.HasQuote,
        LineStyleKind.Heading => line.Heading == style.Level,
        _ => line.Heading == 0,
    };

    /// <summary>
    /// Applies a line style to every line of the selection. When all of them already have it, it is removed instead
    /// (except <see cref="LineStyle.Body"/>); otherwise it replaces any other list or heading marker. Blank lines are
    /// skipped unless nothing else is selected. <c>null</c> when nothing would change or the lines are in a fenced code block.
    /// </summary>
    public static TextEdit? Apply(LineStyle style, string text, MarkdownRange selection)
    {
        if (ParsedLines(selection, text) is not { } lines || IsInsideCodeBlock(lines[0].Start, text)) return null;
        if (style.Kind == LineStyleKind.Heading && style.Level is < 1 or > 6) return null;
        var nonBlank = lines.Where(l => !l.IsBlank).ToList();
        var eligible = nonBlank.Count == 0 ? lines : nonBlank;
        var eligibleStarts = eligible.Select(l => l.Start).ToHashSet();
        var remove = style.Kind != LineStyleKind.Body && eligible.All(l => Has(style, l));

        var number = 0;
        var rendered = new List<string>();
        foreach (var line in lines)
        {
            if (!eligibleStarts.Contains(line.Start)) { rendered.Add(line.Units); continue; }
            number++;
            rendered.Add(Render(line, style, remove, number));
        }
        if (rendered.SequenceEqual(lines.Select(l => l.Units))) return null;

        var from = lines[0].Start;
        var to = lines[^1].End;
        var sb = new StringBuilder();
        var newStarts = new List<int>();
        for (var i = 0; i < rendered.Count; i++)
        {
            if (i > 0) sb.Append('\n');
            newStarts.Add(from + sb.Length);
            sb.Append(rendered[i]);
        }
        var newEnd = from + sb.Length;
        int Locate(int p)
        {
            if (p > to) return p - to + newEnd;
            var index = 0;
            for (var i = lines.Count - 1; i >= 0; i--)
                if (lines[i].Start <= p) { index = i; break; }
            var line = lines[index];
            var shift = rendered[index].Length - line.Units.Length;
            var rel = p - line.Start;
            return newStarts[index] + (rel >= line.ContentOffset ? rel + shift : line.ContentOffset + shift);
        }
        var start = Locate(selection.Location);
        var end = selection.Length == 0 ? start : Locate(selection.End);
        return new TextEdit(new(from, to - from), sb.ToString(), new(start, Math.Max(end - start, 0)));
    }

    private static string Render(ParsedLine line, LineStyle style, bool remove, int number)
    {
        var content = line.Content;
        var terminator = line.Terminator;
        var quote = line.Quote;
        var indent = line.Indent;
        string prefix;
        switch (style.Kind)
        {
            case LineStyleKind.Quote:
                if (remove)
                {
                    var at = quote.IndexOf('>');
                    if (at >= 0)
                    {
                        var cut = at + 1;
                        if (cut < quote.Length && quote[cut] == ' ') cut++;
                        quote = quote.Remove(at, cut - at);
                    }
                    return quote + line.Units[line.Info.QuoteEnd..line.Info.End] + terminator;
                }
                if (line.Info.HasQuote) return line.Units;
                return "> " + line.Units;
            case LineStyleKind.Heading:
                prefix = remove ? "" : new string('#', style.Level) + " ";
                break;
            case LineStyleKind.Body:
                return line.Heading == 0 ? line.Units : quote + content + terminator;
            case LineStyleKind.Bullet:
            case LineStyleKind.Task:
                var ch = line.Info.Marker is { Ordered: false } bullet ? bullet.Char : '-';
                prefix = remove ? indent : indent + ch + " " + (style.Kind == LineStyleKind.Task ? "[ ] " : "");
                break;
            default:
                prefix = remove ? indent : indent + number.ToString(CultureInfo.InvariantCulture) + ". ";
                break;
        }
        return quote + prefix + content + terminator;
    }

    // Blocks

    /// <summary>
    /// Wraps the selected lines (or the caret's line) in ``` fences; when the selection already is a whole fenced block
    /// (first and last line are fences) it removes the fences instead.
    /// </summary>
    public static TextEdit? CodeBlock(string text, MarkdownRange selection)
    {
        if (ParsedLines(selection, text) is not { } lines) return null;
        var from = lines[0].Start;
        var to = lines[^1].End;
        if (to > from && text[to - 1] == '\r') to--;
        static bool IsFence(ParsedLine line, bool closing)
        {
            var u = line.Units[..line.Info.End];
            var i = 0;
            while (i < u.Length && i < 3 && u[i] == ' ') i++;
            var j = i;
            while (j < u.Length && u[j] == '`') j++;
            if (j - i < 3) return false;
            var rest = u[j..];
            return closing ? rest.All(c => c == ' ' || c == '\t') : !rest.Contains('`');
        }
        var range = new MarkdownRange(from, to - from);
        if (lines.Count >= 2 && IsFence(lines[0], false) && IsFence(lines[^1], true))
        {
            var innerStart = lines[0].End + 1;
            var innerEnd = Math.Max(lines[^1].Start - 1, innerStart);
            var inner = innerEnd > innerStart ? text.Substring(innerStart, innerEnd - innerStart) : "";
            if (inner.EndsWith('\r')) inner = inner[..^1];
            return new TextEdit(range, inner, new(from, inner.Length));
        }
        var eol = lines[0].Info.End < lines[0].Units.Length ? "\r\n" : "\n";
        var body = text.Substring(range.Location, range.Length);
        int longest = 0, run = 0;
        foreach (var u in body)
        {
            run = u == '`' ? run + 1 : 0;
            longest = Math.Max(longest, run);
        }
        var fence = new string('`', Math.Max(3, longest + 1));
        var opening = from + fence.Length + eol.Length;
        if (lines.Count == 1 && lines[0].IsBlank && selection.Length == 0)
            return new TextEdit(range, fence + eol + eol + fence, new(opening, 0));
        return new TextEdit(range, fence + eol + body + eol + fence, new(opening, body.Length));
    }

    /// <summary>
    /// Inserts <c>---</c> on a line of its own after the line the selection ends in, with a blank line before it so the
    /// text above does not turn into a heading. The caret goes to the line after. <c>null</c> inside a fenced code block.
    /// </summary>
    public static TextEdit? HorizontalRule(string text, MarkdownRange selection) => InsertBlock("---", 4, text, selection);

    /// <summary>
    /// Puts a block of lines on lines of its own after the line the selection ends in (replacing that line when it is
    /// blank), set off by a blank line before and after. <c>caretAt</c> is the caret's UTF-16 offset in the block.
    /// </summary>
    internal static TextEdit? InsertBlock(string block, int caretAt, string text, MarkdownRange selection)
    {
        if (selection.Location < 0 || selection.End > text.Length) return null;
        var line = LineBounds(selection.End, text);
        if (IsInsideCodeBlock(LineBounds(selection.Location, text).Start, text)) return null;
        bool Blank((int Start, int End) bounds) => IsBlankText(text.AsSpan(bounds.Start, bounds.End - bounds.Start));
        var previousBlank = line.Start == 0 || Blank(LineBounds(line.Start - 1, text));
        if (Blank(line))
        {
            var prefix = previousBlank ? "" : "\n";
            return new TextEdit(new(line.Start, line.End - line.Start), prefix + block + "\n",
                new(line.Start + prefix.Length + caretAt, 0));
        }
        return new TextEdit(new(line.End, 0), "\n\n" + block + "\n", new(line.End + 2 + caretAt, 0));
    }

    internal static bool IsBlankText(ReadOnlySpan<char> s)
    {
        foreach (var c in s)
            if (c != ' ' && c != '\t' && c != '\r') return false;
        return true;
    }

    // Active state

    /// <summary>The styles at the start of the selection (for the formatting bar). Looks at the caret's line only.</summary>
    public static ActiveFormat GetActiveFormat(string text, MarkdownRange selection)
    {
        var result = new ActiveFormat();
        if (selection.Location < 0 || selection.End > text.Length) return result;
        var bounds = LineBounds(selection.Location, text);
        var line = new ParsedLine(bounds.Start, text.Substring(bounds.Start, bounds.End - bounds.Start));
        result.Heading = line.Heading;
        result.Bullet = Has(LineStyle.Bullet, line);
        result.Numbered = Has(LineStyle.Numbered, line);
        result.Task = Has(LineStyle.Task, line);
        result.Quote = line.Info.HasQuote;

        var target = selection;
        if (selection.Length == 0)
        {
            target = WordRange(selection.Location, text);
            if (target.Length == 0) target = new MarkdownRange(selection.Location, 0);
        }
        else if (InlineSegments(selection, text) is { Count: > 0 } segments)
        {
            target = segments[0];
        }
        foreach (var style in Enum.GetValues<InlineStyle>())
        {
            var (left, right) = MarkerRuns(target, MarkerOf(style)[0], text);
            if (Removal(style, left, right) is not null) result.Inline.Add(style);
        }
        return result;
    }
}
