namespace NotesCore;

public enum MarkdownKind
{
    /// <summary>Syntax characters (<c>#</c>, <c>**</c>, backtick, <c>[</c>, <c>](url)</c>, fences, escapes) that the editor dims.</summary>
    Marker,
    /// <summary>The whole heading line, marker included (<see cref="MarkdownSpanKind.Level"/>).</summary>
    Heading,
    Bold,
    Italic,
    BoldItalic,
    Strikethrough,
    InlineCode,
    /// <summary>The whole fenced block, fence lines included.</summary>
    CodeBlock,
    /// <summary>The whole quoted line, <c>&gt;</c> included.</summary>
    Blockquote,
    /// <summary><c>-</c>, <c>*</c>, <c>+</c>, <c>1.</c> or <c>1)</c>.</summary>
    ListMarker,
    /// <summary>The <c>[ ]</c> / <c>[x]</c> box of a task item (<see cref="MarkdownSpanKind.Checked"/>).</summary>
    TaskMarker,
    /// <summary>The task text after the box (<see cref="MarkdownSpanKind.Checked"/>).</summary>
    Task,
    /// <summary>Link text, or the URL itself for autolinks and bare URLs (<see cref="MarkdownSpanKind.Url"/>).</summary>
    Link,
    HorizontalRule,
    /// <summary>The text of a <c>[[Note name]]</c> wiki link (alias and heading included); <see cref="MarkdownSpanKind.Target"/> is the note name.</summary>
    WikiLink,
    /// <summary>The header row of a pipe table (its pipes and the delimiter row are <see cref="TableMarker"/>).</summary>
    TableHeader,
    /// <summary>Pipes and the delimiter row of a pipe table: dimmed like markers but never hidden, so the columns stay put.</summary>
    TableMarker,
    /// <summary>A whole pipe table, its lines through the last line break; comes before the spans inside it.</summary>
    Table,
}

/// <summary>A span kind with its payload; value equality, so it can be used in sets and comparisons.</summary>
public readonly record struct MarkdownSpanKind(MarkdownKind Kind, int Level = 0, bool Checked = false, string? Url = null, string? Target = null)
{
    public static MarkdownSpanKind TableHeader => new(MarkdownKind.TableHeader);
    public static MarkdownSpanKind TableMarker => new(MarkdownKind.TableMarker);
    public static MarkdownSpanKind Table => new(MarkdownKind.Table);
    public static MarkdownSpanKind WikiLink(string target) => new(MarkdownKind.WikiLink, Target: target);
    public static MarkdownSpanKind Marker => new(MarkdownKind.Marker);
    public static MarkdownSpanKind Bold => new(MarkdownKind.Bold);
    public static MarkdownSpanKind Italic => new(MarkdownKind.Italic);
    public static MarkdownSpanKind BoldItalic => new(MarkdownKind.BoldItalic);
    public static MarkdownSpanKind Strikethrough => new(MarkdownKind.Strikethrough);
    public static MarkdownSpanKind InlineCode => new(MarkdownKind.InlineCode);
    public static MarkdownSpanKind CodeBlock => new(MarkdownKind.CodeBlock);
    public static MarkdownSpanKind Blockquote => new(MarkdownKind.Blockquote);
    public static MarkdownSpanKind ListMarker => new(MarkdownKind.ListMarker);
    public static MarkdownSpanKind HorizontalRule => new(MarkdownKind.HorizontalRule);
    public static MarkdownSpanKind Heading(int level) => new(MarkdownKind.Heading, Level: level);
    public static MarkdownSpanKind TaskMarker(bool isChecked) => new(MarkdownKind.TaskMarker, Checked: isChecked);
    public static MarkdownSpanKind Task(bool isChecked) => new(MarkdownKind.Task, Checked: isChecked);
    public static MarkdownSpanKind Link(string url) => new(MarkdownKind.Link, Url: url);
}

/// <summary>UTF-16 range (location and length), the same units as <c>string</c> indices and WinUI <c>ITextRange</c>.</summary>
public readonly record struct MarkdownRange(int Location, int Length)
{
    public int End => Location + Length;
    public bool Contains(int index) => index >= Location && index < End;
}

public readonly record struct MarkdownSpan(MarkdownRange Range, MarkdownSpanKind Kind);

/// <summary>
/// A single-pass Markdown scanner for syntax highlighting. Not a full CommonMark parser:
/// only fenced code blocks span lines, every other construct is confined to one line.
/// </summary>
public static class MarkdownStyler
{
    /// <summary>Spans sorted by location; a span that contains others comes before them.</summary>
    public static List<MarkdownSpan> Spans(string text)
    {
        var scanner = new Scanner(text);
        scanner.Run();
        return scanner.Spans;
    }

    /// <summary>
    /// What to restyle after an edit when no fence moved: the whole lines it touches, through the end of the line
    /// where it ends, so text split off by Return (which keeps e.g. a heading's font) is included.
    /// Lines end at LF only, like the scanner. <paramref name="editedRange"/> is in post-edit UTF-16 coordinates of <paramref name="text"/>.
    /// </summary>
    public static MarkdownRange RestyleRange(MarkdownRange editedRange, string text)
    {
        int length = text.Length;
        int start = Math.Min(editedRange.Location, length);
        int end = Math.Min(Math.Max(editedRange.End, start), length);
        while (start > 0 && text[start - 1] != '\n') start--;
        while (end < length && text[end] != '\n') end++;
        if (end < length) end++;
        return new MarkdownRange(start, end - start);
    }

    private sealed class Delimiter(char ch, int start, int count, bool canOpen, bool canClose)
    {
        public readonly char Char = ch;
        public int Start = start;
        public int Count = count;
        public readonly bool CanOpen = canOpen;
        public readonly bool CanClose = canClose;
    }

    private static bool IsSpace(char c) => c == ' ' || c == '\t';
    private static bool IsDigit(char c) => c >= '0' && c <= '9';

    private static bool IsAsciiPunctuation(char c) =>
        (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126);

    /// <summary>ASCII punctuation, general punctuation/symbol blocks and surrogates (emoji).</summary>
    private static bool IsPunctuation(char c) =>
        IsAsciiPunctuation(c) || (c >= 0x2000 && c <= 0x2BFF) || (c >= 0xD800 && c <= 0xDFFF);

    private static bool IsWordUnit(char c) => !IsSpace(c) && !IsPunctuation(c);

    private static readonly string[] Schemes = ["https://", "http://"];

    private sealed class Scanner(string text)
    {
        private readonly string s = text;
        public readonly List<MarkdownSpan> Spans = new(text.Length / 16);
        private readonly List<MarkdownSpan> lineSpans = [];

        private void Add(int start, int end, MarkdownSpanKind kind)
        {
            if (end > start) Spans.Add(new MarkdownSpan(new MarkdownRange(start, end - start), kind));
        }

        private void AddInline(int start, int end, MarkdownSpanKind kind)
        {
            if (end > start) lineSpans.Add(new MarkdownSpan(new MarkdownRange(start, end - start), kind));
        }

        private int SkipSpaces(int i, int end)
        {
            while (i < end && IsSpace(s[i])) i++;
            return i;
        }

        // Blocks

        public void Run()
        {
            int lineStart = 0;
            (char ch, int count, int spanIndex)? fence = null;
            while (lineStart <= s.Length)
            {
                int next = lineStart;
                while (next < s.Length && s[next] != '\n') next++;
                int end = next;
                if (end > lineStart && s[end - 1] == '\r') end--;

                if (fence is { } open)
                {
                    if (FenceRun(lineStart, end) is { } close && close.ch == open.ch && close.count >= open.count
                        && SkipSpaces(close.end, end) == end)
                    {
                        Add(lineStart, end, MarkdownSpanKind.Marker);
                        CloseFence(open.spanIndex, end);
                        fence = null;
                    }
                }
                else if (FenceRun(lineStart, end) is { } opening
                         && (opening.ch == '~' || s.IndexOf('`', opening.end, end - opening.end) < 0))
                {
                    fence = (opening.ch, opening.count, Spans.Count);
                    Add(lineStart, end, MarkdownSpanKind.CodeBlock);
                    Add(lineStart, end, MarkdownSpanKind.Marker);
                }
                else if (MarkdownTable.Rows(s, lineStart) is { } rows)
                {
                    Table(rows);
                    lineStart = rows[^1].Next;
                    continue;
                }
                else
                {
                    Line(lineStart, end);
                }
                lineStart = next + 1;
            }
            if (fence is { } unclosed) CloseFence(unclosed.spanIndex, s.Length);
        }

        private void Table(List<MarkdownTable.TableRow> rows)
        {
            Add(rows[0].Start, Math.Min(rows[^1].Next, s.Length), MarkdownSpanKind.Table);
            for (int index = 0; index < rows.Count; index++)
            {
                var row = rows[index];
                if (index == 1)
                {
                    Add(row.First, row.End, MarkdownSpanKind.TableMarker);
                    continue;
                }
                if (index == 0) AddInline(row.First, row.End, MarkdownSpanKind.TableHeader);
                foreach (var pipe in row.Pipes) AddInline(pipe, pipe + 1, MarkdownSpanKind.TableMarker);
                foreach (var cell in row.Cells) Inline(cell.Location, cell.End);
                FlushInline();
            }
        }

        private void CloseFence(int index, int end)
        {
            int start = Spans[index].Range.Location;
            Spans[index] = new MarkdownSpan(new MarkdownRange(start, end - start), MarkdownSpanKind.CodeBlock);
        }

        /// <summary>A run of 3+ backticks or tildes after at most 3 spaces of indentation.</summary>
        private (char ch, int count, int end)? FenceRun(int start, int end)
        {
            int i = SkipSpaces(start, end);
            if (i - start > 3 || i >= end || (s[i] != '`' && s[i] != '~')) return null;
            int j = i;
            while (j < end && s[j] == s[i]) j++;
            return j - i >= 3 ? (s[i], j - i, j) : null;
        }

        private void Line(int start, int end)
        {
            int i = start;
            // Blockquote prefixes, possibly nested ("> > text").
            bool quoted = false;
            while (true)
            {
                int j = SkipSpaces(i, end);
                if (j - i > 3 || j >= end || s[j] != '>') break;
                if (!quoted) { Add(start, end, MarkdownSpanKind.Blockquote); quoted = true; }
                int after = j + 1 < end && IsSpace(s[j + 1]) ? j + 2 : j + 1;
                Add(j, after, MarkdownSpanKind.Marker);
                i = after;
            }

            int indentEnd = SkipSpaces(i, end);
            if (indentEnd - i <= 3 && IsHorizontalRule(indentEnd, end))
            {
                Add(indentEnd, end, MarkdownSpanKind.HorizontalRule);
                return;
            }
            if (indentEnd - i <= 3 && Heading(indentEnd, end) is { } level)
            {
                Add(indentEnd, end, MarkdownSpanKind.Heading(level));
                int markerEnd = SkipSpaces(indentEnd + level, end);
                Add(indentEnd, markerEnd, MarkdownSpanKind.Marker);
                // Optional closing sequence: " ###".
                int contentEnd = end;
                int k = end;
                while (k > markerEnd && IsSpace(s[k - 1])) k--;
                int h = k;
                while (h > markerEnd && s[h - 1] == '#') h--;
                if (h < k && (h == markerEnd || IsSpace(s[h - 1])))
                {
                    contentEnd = h;
                    while (contentEnd > markerEnd && IsSpace(s[contentEnd - 1])) contentEnd--;
                }
                Inline(markerEnd, contentEnd);
                if (contentEnd < k) Add(h, k, MarkdownSpanKind.Marker);
                FlushInline();
                return;
            }
            if (ListMarker(indentEnd, end) is { } listEnd)
            {
                Add(indentEnd, listEnd, MarkdownSpanKind.ListMarker);
                int contentStart = SkipSpaces(listEnd, end);
                if (TaskBox(contentStart, end) is { } isChecked)
                {
                    Add(contentStart, contentStart + 3, MarkdownSpanKind.TaskMarker(isChecked));
                    contentStart = SkipSpaces(contentStart + 3, end);
                    Add(contentStart, end, MarkdownSpanKind.Task(isChecked));
                }
                Inline(contentStart, end);
                FlushInline();
                return;
            }
            Inline(i, end);
            FlushInline();
        }

        private int? Heading(int i, int end)
        {
            int j = i;
            while (j < end && s[j] == '#') j++;
            int level = j - i;
            if (level < 1 || level > 6 || (j != end && !IsSpace(s[j]))) return null;
            return level;
        }

        private bool IsHorizontalRule(int i, int end)
        {
            if (i >= end || (s[i] != '-' && s[i] != '*' && s[i] != '_')) return false;
            int count = 0;
            for (int j = i; j < end; j++)
            {
                if (s[j] == s[i]) count++;
                else if (!IsSpace(s[j])) return false;
            }
            return count >= 3;
        }

        /// <summary>Returns the end of the marker (<c>-</c>, <c>*</c>, <c>+</c>, <c>12.</c>, <c>12)</c>) when followed by a space or the line end.</summary>
        private int? ListMarker(int i, int end)
        {
            if (i >= end) return null;
            if (s[i] == '-' || s[i] == '*' || s[i] == '+')
                return i + 1 == end || IsSpace(s[i + 1]) ? i + 1 : null;
            int j = i;
            while (j < end && j - i < 9 && IsDigit(s[j])) j++;
            if (j == i || j >= end || (s[j] != '.' && s[j] != ')')) return null;
            return j + 1 == end || IsSpace(s[j + 1]) ? j + 1 : null;
        }

        private bool? TaskBox(int i, int end)
        {
            if (!(i + 2 < end && s[i] == '[' && s[i + 2] == ']' && (i + 3 == end || IsSpace(s[i + 3])))) return null;
            return s[i + 1] switch
            {
                ' ' => false,
                'x' or 'X' => true,
                _ => null,
            };
        }

        // Inlines

        private void FlushInline()
        {
            if (lineSpans.Count == 0) return;
            // Location ascending, length descending; ties keep scan order (stable, like the Swift sort).
            var ordered = lineSpans
                .Select((span, index) => (span, index))
                .OrderBy(x => x.span.Range.Location)
                .ThenByDescending(x => x.span.Range.Length)
                .ThenBy(x => x.index);
            foreach (var (span, _) in ordered) Spans.Add(span);
            lineSpans.Clear();
        }

        private void Inline(int start, int end)
        {
            var delimiters = new List<Delimiter>();
            int i = start;
            while (i < end)
            {
                char c = s[i];
                if (c == '\\' && i + 1 < end && IsAsciiPunctuation(s[i + 1]))
                {
                    AddInline(i, i + 1, MarkdownSpanKind.Marker);
                    i += 2;
                }
                else if (c == '`')
                {
                    i = CodeSpan(i, end);
                }
                else if (c == '<')
                {
                    i = Autolink(i, end) ?? i + 1;
                }
                else if (c == '[')
                {
                    i = WikiLink(i, end) ?? Link(i, i, end) ?? i + 1;
                }
                else if (c == '!' && i + 1 < end && s[i + 1] == '[')
                {
                    i = Link(i, i + 1, end) ?? i + 1;
                }
                else if (c == 'h' && (i == start || !IsWordUnit(s[i - 1])))
                {
                    i = BareUrl(i, end) ?? i + 1;
                }
                else if (c == '*' || c == '_' || c == '~')
                {
                    int j = i;
                    while (j < end && s[j] == c) j++;
                    if (c != '~' || j - i == 2)
                    {
                        char before = i > start ? s[i - 1] : ' ';
                        char after = j < end ? s[j] : ' ';
                        bool left = !IsSpace(after) && (!IsPunctuation(after) || IsSpace(before) || IsPunctuation(before));
                        bool right = !IsSpace(before) && (!IsPunctuation(before) || IsSpace(after) || IsPunctuation(after));
                        // Intraword delimiters never count, for `*` too, so `a*b*c` and `snake_case` stay plain.
                        bool canOpen = left && (!right || IsPunctuation(before));
                        bool canClose = right && (!left || IsPunctuation(after));
                        if (canOpen || canClose) delimiters.Add(new Delimiter(c, i, j - i, canOpen, canClose));
                    }
                    i = j;
                }
                else
                {
                    i++;
                }
            }
            Emphasis(delimiters);
        }

        /// <summary>Matches closers to the nearest compatible opener (CommonMark's "process emphasis", minus the rule of 3).</summary>
        private void Emphasis(List<Delimiter> delimiters)
        {
            var bottom = new Dictionary<char, int>();
            for (int c = 0; c < delimiters.Count; c++)
            {
                if (!delimiters[c].CanClose) continue;
                char ch = delimiters[c].Char;
                while (delimiters[c].Count > 0)
                {
                    int floor = bottom.TryGetValue(ch, out var b) ? b : 0;
                    int found = -1;
                    for (int o = c - 1; o >= floor; o--)
                    {
                        if (delimiters[o].Char == ch && delimiters[o].CanOpen && delimiters[o].Count > 0) { found = o; break; }
                    }
                    if (found < 0) { bottom[ch] = c; break; }
                    var opener = delimiters[found];
                    var closer = delimiters[c];

                    int use;
                    MarkdownSpanKind kind;
                    if (ch == '~') (use, kind) = (2, MarkdownSpanKind.Strikethrough);
                    else if (opener.Count >= 3 && closer.Count >= 3) (use, kind) = (3, MarkdownSpanKind.BoldItalic);
                    else if (opener.Count >= 2 && closer.Count >= 2) (use, kind) = (2, MarkdownSpanKind.Bold);
                    else (use, kind) = (1, MarkdownSpanKind.Italic);

                    int contentStart = opener.Start + opener.Count;
                    int contentEnd = closer.Start;
                    AddInline(contentStart - use, contentStart, MarkdownSpanKind.Marker);
                    AddInline(contentStart, contentEnd, kind);
                    AddInline(contentEnd, contentEnd + use, MarkdownSpanKind.Marker);
                    opener.Count -= use;
                    closer.Start += use;
                    closer.Count -= use;
                    for (int between = found + 1; between < c; between++) delimiters[between].Count = 0;
                }
            }
        }

        private int CodeSpan(int i, int end)
        {
            int j = i;
            while (j < end && s[j] == '`') j++;
            int n = j - i;
            int k = j;
            while (k < end)
            {
                if (s[k] != '`') { k++; continue; }
                int m = k;
                while (m < end && s[m] == '`') m++;
                if (m - k == n)
                {
                    AddInline(i, j, MarkdownSpanKind.Marker);
                    AddInline(j, k, MarkdownSpanKind.InlineCode);
                    AddInline(k, m, MarkdownSpanKind.Marker);
                    return m;
                }
                k = m;
            }
            return j;
        }

        private int? UrlSchemeEnd(int i, int end)
        {
            foreach (var scheme in Schemes)
            {
                if (i + scheme.Length <= end && string.CompareOrdinal(s, i, scheme, 0, scheme.Length) == 0)
                    return i + scheme.Length;
            }
            return null;
        }

        private int? Autolink(int i, int end)
        {
            if (UrlSchemeEnd(i + 1, end) is null) return null;
            int j = i + 1;
            while (j < end && s[j] != '>' && !IsSpace(s[j]) && s[j] != '<') j++;
            if (j >= end || s[j] != '>') return null;
            AddInline(i, i + 1, MarkdownSpanKind.Marker);
            AddInline(i + 1, j, MarkdownSpanKind.Link(Substr(i + 1, j)));
            AddInline(j, j + 1, MarkdownSpanKind.Marker);
            return j + 1;
        }

        private int? BareUrl(int i, int end)
        {
            if (UrlSchemeEnd(i, end) is not { } schemeEnd) return null;
            int j = schemeEnd;
            int parens = 0;
            while (j < end && !IsSpace(s[j]) && s[j] != '<' && s[j] != '>')
            {
                if (s[j] == '(') parens++;
                else if (s[j] == ')') parens--;
                j++;
            }
            // Trailing punctuation belongs to the sentence, not the URL.
            while (j > schemeEnd)
            {
                char u = s[j - 1];
                if (u == ')' && parens < 0) { parens++; j--; continue; }
                if (".,:;!?'\"*_~".IndexOf(u) < 0) break;
                j--;
            }
            if (j <= schemeEnd) return null;
            AddInline(i, j, MarkdownSpanKind.Link(Substr(i, j)));
            return j;
        }

        /// <summary><c>[[Note name]]</c>: no brackets inside, a non-empty name.</summary>
        private int? WikiLink(int i, int end)
        {
            if (i + 1 >= end || s[i + 1] != '[') return null;
            int j = i + 2;
            while (j + 1 < end && s[j] != '[' && s[j] != ']') j++;
            if (j + 1 >= end || s[j] != ']' || s[j + 1] != ']' || NoteLinks.WikiName(Substr(i + 2, j)) is not { } target) return null;
            AddInline(i, i + 2, MarkdownSpanKind.Marker);
            AddInline(i + 2, j, MarkdownSpanKind.WikiLink(target));
            AddInline(j, j + 2, MarkdownSpanKind.Marker);
            return j + 2;
        }

        /// <summary><c>[text](url)</c> starting at <paramref name="bracket"/>; <paramref name="start"/> is the <c>!</c> of an image or the bracket itself.</summary>
        private int? Link(int start, int bracket, int end)
        {
            int limit = Math.Min(end, bracket + 2000);
            int depth = 0;
            int j = bracket;
            int close = -1;
            while (j < limit)
            {
                switch (s[j])
                {
                    case '\\': j++; break;
                    case '[': depth++; break;
                    case ']':
                        depth--;
                        if (depth == 0) close = j;
                        break;
                }
                if (close >= 0) break;
                j++;
            }
            if (close < 0 || close + 1 >= end || s[close + 1] != '(') return null;
            int k = close + 2;
            int parens = 1;
            while (k < end)
            {
                if (s[k] == '\\') { k += 2; continue; }
                if (s[k] == '(') parens++;
                if (s[k] == ')') { parens--; if (parens == 0) break; }
                k++;
            }
            if (k >= end) return null;

            int urlStart = SkipSpaces(close + 2, k);
            int urlEnd = urlStart;
            while (urlEnd < k && !IsSpace(s[urlEnd])) urlEnd++;
            if (urlEnd > urlStart && s[urlStart] == '<' && s[urlEnd - 1] == '>') { urlStart++; urlEnd--; }

            AddInline(start, bracket + 1, MarkdownSpanKind.Marker);
            // Link text is styled as a whole; emphasis inside it is not parsed.
            AddInline(bracket + 1, close, MarkdownSpanKind.Link(Substr(urlStart, urlEnd)));
            AddInline(close, k + 1, MarkdownSpanKind.Marker);
            return k + 1;
        }

        private string Substr(int start, int end) => s.Substring(start, Math.Max(start, end) - start);
    }
}
