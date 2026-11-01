using System.Globalization;

namespace NotesCore;

/// <summary>
/// One replacement in a text, in UTF-16 coordinates, plus where the selection goes afterwards (<c>null</c>: leave it
/// to the text view, which keeps it consistent with the edit).
/// </summary>
public readonly record struct TextEdit(MarkdownRange Range, string Replacement, MarkdownRange? Selection = null);

/// <summary>
/// Editing helpers of the Markdown editor as pure functions of the text and the selection: list continuation, list
/// indentation, link insertion and task toggling. See docs/format.md ("Editing helpers"). Lines end at LF only: a
/// caller whose editor uses CR line endings (RichEditBox) converts the text to LF before and the edit back after.
/// </summary>
public static partial class MarkdownEditing
{
    // Return

    /// <summary>
    /// Return in a list item or blockquote: continues the list (<c>- </c>, <c>* </c>, <c>+ </c>, <c>1. </c> counting
    /// up, <c>- [ ] </c> for tasks, <c>&gt; </c> for quotes) with the same indentation, or ends it when the item is
    /// empty. <c>null</c> means the plain newline applies (selection not empty, caret not after the marker, not a list
    /// line, inside a fenced code block).
    /// </summary>
    public static TextEdit? Newline(string text, MarkdownRange selection)
    {
        if (selection.Length != 0 || selection.Location < 0 || selection.Location > text.Length) return null;
        var caret = selection.Location;
        var line = LineBounds(caret, text);
        var info = new LineInfo(text.Substring(line.Start, line.End - line.Start));
        if (!info.HasQuote && info.Marker is null) return null;
        var rel = caret - line.Start;
        var quotePart = info.QuotePart;

        if (info.Marker is { } marker)
        {
            if (!(info.MarkerEnd < info.End && rel >= info.MarkerEnd && (rel >= info.ContentStart || info.IsEmpty))) return null;
            if (IsInsideCodeBlock(line.Start, text)) return null;
            if (info.IsEmpty)
            {
                var replacement = info.HasQuote ? quotePart : "";
                return new TextEdit(new(line.Start, info.End), replacement, new(line.Start + replacement.Length, 0));
            }
            var next = marker.Ordered
                ? (marker.Number + 1).ToString(CultureInfo.InvariantCulture) + marker.Char
                : marker.Char.ToString();
            var box = info.Task is null ? "" : "[ ] ";
            var insert = "\n" + quotePart + info.Indent + next + " " + box;
            return new TextEdit(selection, insert, new(caret + insert.Length, 0));
        }

        if (rel < info.QuoteEnd || IsInsideCodeBlock(line.Start, text)) return null;
        if (info.QuoteContentIsEmpty)
            return new TextEdit(new(line.Start, info.End), "", new(line.Start, 0));
        var quoteInsert = "\n" + quotePart;
        return new TextEdit(selection, quoteInsert, new(caret + quoteInsert.Length, 0));
    }

    // Tab

    /// <summary>
    /// Tab / Shift-Tab on list item lines (every line the selection touches must be one): adds or removes one level of
    /// indentation, 2 spaces for bullets and tasks, the marker's width for numbered items (<c>1. </c> = 3).
    /// <c>null</c> when the lines are not all list items or there is nothing to remove, so the editor's normal Tab applies.
    /// </summary>
    public static TextEdit? Indent(string text, MarkdownRange selection, bool outdent)
    {
        if (selection.Location < 0 || selection.End > text.Length) return null;
        var lines = new List<(int Start, int End, LineInfo Info)>();
        var cursor = LineBounds(selection.Location, text).Start;
        var stop = selection.End;
        if (selection.Length > 0 && stop > 0 && text[stop - 1] == '\n') stop--;
        while (true)
        {
            var bounds = LineBounds(cursor, text);
            var info = new LineInfo(text.Substring(bounds.Start, bounds.End - bounds.Start));
            if (info.Marker is null) return null;
            lines.Add((bounds.Start, bounds.End, info));
            if (bounds.End >= stop || bounds.End >= text.Length) break;
            cursor = bounds.End + 1;
        }
        if (IsInsideCodeBlock(lines[0].Start, text)) return null;

        // Per line: where the change happens, how many units are removed, what is inserted.
        var changes = new List<(int At, int Removed, string Inserted)>();
        foreach (var line in lines)
        {
            var at = line.Start + line.Info.QuoteEnd;
            var width = line.Info.IndentWidth;
            if (outdent)
            {
                var indent = line.Info.Indent;
                var removed = indent.Length > 0 && indent[0] == '\t' ? 1 : Math.Min(CountLeading(indent, ' '), width);
                if (removed > 0) changes.Add((at, removed, ""));
            }
            else
            {
                changes.Add((at, 0, new string(' ', width)));
            }
        }
        if (changes.Count == 0) return null;

        var from = changes[0].At;
        var to = lines[^1].End;
        var result = text.Substring(from, to - from);
        for (var i = changes.Count - 1; i >= 0; i--)
        {
            var change = changes[i];
            result = result[..(change.At - from)] + change.Inserted + result[(change.At - from + change.Removed)..];
        }

        int Map(int p)
        {
            var offset = 0;
            foreach (var change in changes)
            {
                if (p >= change.At + change.Removed) offset += change.Inserted.Length - change.Removed;
                else if (p > change.At) return change.At + offset;
                else break;
            }
            return p + offset;
        }
        var newStart = Map(selection.Location);
        var newEnd = selection.Length == 0 ? newStart : Map(selection.End);
        return new TextEdit(new(from, to - from), result, new(newStart, newEnd - newStart));
    }

    private static int CountLeading(string s, char c)
    {
        var n = 0;
        while (n < s.Length && s[n] == c) n++;
        return n;
    }

    // Links

    /// <summary>
    /// Ctrl+K: <c>[selection](url)</c> with the caret in the parentheses; an empty selection gives <c>[](url)</c> with
    /// the caret in the brackets, and a selected web address becomes the URL of an empty text, caret in the brackets.
    /// </summary>
    public static TextEdit? Link(string text, MarkdownRange selection)
    {
        if (selection.Location < 0 || selection.End > text.Length) return null;
        var chosen = text.Substring(selection.Location, selection.Length);
        if (chosen.Length == 0)
            return new TextEdit(selection, "[]()", new(selection.Location + 1, 0));
        if (IsWebAddress(chosen))
            return new TextEdit(selection, $"[]({chosen})", new(selection.Location + 1, 0));
        return new TextEdit(selection, $"[{chosen}]()", new(selection.Location + chosen.Length + 3, 0));
    }

    /// <summary>An http(s) address without whitespace (the macOS app asks <c>NoteLinks.classify</c> for a web URL with that scheme).</summary>
    private static bool IsWebAddress(string s)
    {
        foreach (var c in s)
            if (char.IsWhiteSpace(c)) return false;
        var colon = s.IndexOf(':');
        if (colon < 2 || !char.IsAsciiLetter(s[0])) return false;
        foreach (var c in s.AsSpan(0, colon))
            if (!(char.IsAsciiLetterOrDigit(c) || c is '+' or '-' or '.')) return false;
        var scheme = s[..colon].ToLowerInvariant();
        return scheme is "http" or "https";
    }

    // Tasks

    /// <summary>
    /// A click at UTF-16 offset <c>index</c> on a task item's <c>[ ]</c> / <c>[x]</c> box: the edit that flips it.
    /// <c>null</c> when the index is not on a box (boxes inside fenced code are not task items).
    /// </summary>
    public static TextEdit? ToggleTask(string text, int index)
    {
        if (index < 0 || index >= text.Length) return null;
        var line = LineBounds(index, text);
        var info = new LineInfo(text.Substring(line.Start, line.End - line.Start));
        if (info.Task is not { } isChecked) return null;
        var box = line.Start + info.BoxStart;
        if (index < box || index >= box + 3 || IsInsideCodeBlock(line.Start, text)) return null;
        return new TextEdit(new(box + 1, 1), isChecked ? " " : "x");
    }

    // Line parsing

    /// <summary>Range of the line holding <c>location</c>, without its LF (lines end at LF only, like the scanner).</summary>
    internal static (int Start, int End) LineBounds(int location, string text)
    {
        var start = Math.Min(Math.Max(location, 0), text.Length);
        var end = start;
        while (start > 0 && text[start - 1] != '\n') start--;
        while (end < text.Length && text[end] != '\n') end++;
        return (start, end);
    }

    /// <summary>
    /// Whether the line starting at <c>location</c> is part of a fenced code block. Scans only the fence lines before
    /// it (same rules as <see cref="MarkdownStyler"/>), without parsing inline syntax.
    /// </summary>
    internal static bool IsInsideCodeBlock(int location, string text)
    {
        var length = text.Length;
        int SkipSpaces(int from, int end)
        {
            var i = from;
            while (i < end && (text[i] == ' ' || text[i] == '\t')) i++;
            return i;
        }
        (char Char, int Count, int End)? FenceRun(int start, int end)
        {
            var i = SkipSpaces(start, end);
            if (i - start > 3 || i >= end) return null;
            var c = text[i];
            if (c != '`' && c != '~') return null;
            var j = i;
            while (j < end && text[j] == c) j++;
            return j - i >= 3 ? (c, j - i, j) : null;
        }
        bool HasBacktick(int from, int end)
        {
            for (var k = from; k < end; k++)
                if (text[k] == '`') return true;
            return false;
        }

        (char Char, int Count)? open = null;
        var lineStart = 0;
        while (lineStart <= length)
        {
            var next = lineStart;
            while (next < length && text[next] != '\n') next++;
            var end = next;
            if (end > lineStart && text[end - 1] == '\r') end--;
            var run = FenceRun(lineStart, end);
            if (lineStart >= location)
            {
                if (open is not null) return true;
                if (run is not { } r) return false;
                return r.Char == '~' || !HasBacktick(r.End, end);
            }
            if (open is { } current)
            {
                if (run is { } r && r.Char == current.Char && r.Count >= current.Count && SkipSpaces(r.End, end) == end) open = null;
            }
            else if (run is { } r && (r.Char == '~' || !HasBacktick(r.End, end)))
            {
                open = (r.Char, r.Count);
            }
            lineStart = next + 1;
        }
        return open is not null;
    }

    /// <summary>A list marker: a bullet character, or a number with its delimiter (<c>.</c> or <c>)</c>).</summary>
    internal readonly record struct Marker(bool Ordered, int Number, char Char);

    /// <summary>A line split into <c>[quote markers][indent][list marker][task box][content]</c> (offsets inside the line).</summary>
    internal sealed class LineInfo
    {
        private readonly string units;
        public bool HasQuote;
        /// <summary>End of the leading <c>&gt;</c> markers (with their spaces); 0 without any.</summary>
        public int QuoteEnd;
        public int IndentEnd;
        public Marker? Marker;
        /// <summary>End of the marker itself (before its space).</summary>
        public int MarkerEnd;
        public bool? Task;
        /// <summary>Start of the <c>[ ]</c> / <c>[x]</c> box when the line is a task item.</summary>
        public int BoxStart;
        public int ContentStart;
        /// <summary>Without trailing CR.</summary>
        public int End;

        public LineInfo(string units)
        {
            this.units = units;
            End = units.Length;
            if (End > 0 && units[End - 1] == '\r') End--;
            var i = 0;
            while (true)
            {
                var j = Skip(i);
                if (!(j < End && units[j] == '>')) break;
                i = j + 1;
                if (i < End && units[i] == ' ') i++;
                HasQuote = true;
                QuoteEnd = i;
            }
            IndentEnd = Skip(QuoteEnd);
            ContentStart = IndentEnd;
            if (IndentEnd >= End) return;
            var c = units[IndentEnd];
            if (c is '-' or '*' or '+')
            {
                if (!(IndentEnd + 1 == End || IsSpace(units[IndentEnd + 1])) || IsRule(IndentEnd)) return;
                Marker = new Marker(false, 0, c);
                MarkerEnd = IndentEnd + 1;
            }
            else if (c >= '0' && c <= '9')
            {
                var j = IndentEnd;
                while (j < End && j - IndentEnd < 9 && units[j] >= '0' && units[j] <= '9') j++;
                if (!(j < End && (units[j] == '.' || units[j] == ')') && (j + 1 == End || IsSpace(units[j + 1])))) return;
                var number = int.Parse(units.AsSpan(IndentEnd, j - IndentEnd), CultureInfo.InvariantCulture);
                Marker = new Marker(true, number, units[j]);
                MarkerEnd = j + 1;
            }
            else
            {
                return;
            }
            ContentStart = Skip(MarkerEnd);
            if (ContentStart + 2 < End && units[ContentStart] == '[' && units[ContentStart + 2] == ']'
                && (ContentStart + 3 == End || IsSpace(units[ContentStart + 3])))
            {
                switch (units[ContentStart + 1])
                {
                    case ' ': Task = false; break;
                    case 'x' or 'X': Task = true; break;
                }
                if (Task is not null)
                {
                    BoxStart = ContentStart;
                    ContentStart = Skip(ContentStart + 3);
                }
            }
        }

        private static bool IsSpace(char u) => u == ' ' || u == '\t';

        private int Skip(int from)
        {
            var i = from;
            while (i < End && IsSpace(units[i])) i++;
            return i;
        }

        /// <summary><c>- - -</c>, <c>***</c> and the like are thematic breaks, not items.</summary>
        private bool IsRule(int from)
        {
            var count = 0;
            for (var j = from; j < End; j++)
            {
                if (units[j] == units[from]) count++;
                else if (!IsSpace(units[j])) return false;
            }
            return count >= 3;
        }

        /// <summary>The quote markers, ending in a space so the new line reads <c>&gt; text</c>.</summary>
        public string QuotePart
        {
            get
            {
                if (!HasQuote) return "";
                var part = units[..QuoteEnd];
                return part.EndsWith(' ') ? part : part + " ";
            }
        }

        public string Indent => units[QuoteEnd..IndentEnd];

        /// <summary>The marker (and box) has no text after it.</summary>
        public bool IsEmpty => Marker is not null && ContentStart >= End;

        public bool QuoteContentIsEmpty => Skip(QuoteEnd) >= End;

        /// <summary>One indentation level: 2 for bullets and tasks, the marker plus its space for numbered items.</summary>
        public int IndentWidth => Marker is { Ordered: true } ? MarkerEnd - IndentEnd + 1 : 2;
    }
}
