namespace NotesCore;

/// <summary>What is drawn in place of a marker character while Markdown syntax is hidden.</summary>
public enum MarkdownDecoration { Bullet, QuoteBar, Rule }

/// <summary>
/// Pure helpers of the live Markdown editor's rendering (which markers stay visible, which are drawn instead, the language of a
/// fenced block, geometry of inline images). Offsets are UTF-16 and text is LF-based, like the styler's.
/// </summary>
public static class MarkdownRendering
{
    /// <summary>Whole lines (LF only, like the scanner) touched by <paramref name="range"/>, through the line break where it ends.</summary>
    public static MarkdownRange LineRange(MarkdownRange range, string text)
    {
        int length = text.Length;
        int start = Math.Clamp(range.Location, 0, length);
        int end = Math.Clamp(Math.Max(range.End, start), start, length);
        while (start > 0 && text[start - 1] != '\n') start--;
        while (end < length && text[end] != '\n') end++;
        if (end < length) end++;
        return new MarkdownRange(start, end - start);
    }

    /// <summary>Running maximum of the spans' ends, so the first span that can reach a location is found by bisection.</summary>
    public static int[] Reach(IReadOnlyList<MarkdownSpan> spans)
    {
        var result = new int[spans.Count];
        int peak = 0;
        for (int i = 0; i < spans.Count; i++)
        {
            peak = Math.Max(peak, spans[i].Range.End);
            result[i] = peak;
        }
        return result;
    }

    /// <summary>First index whose running maximum (<paramref name="reach"/>, non-decreasing) is greater than <paramref name="location"/>.</summary>
    public static int FirstIndex(IReadOnlyList<int> reach, int location)
    {
        int lo = 0, hi = reach.Count;
        while (lo < hi)
        {
            int mid = (lo + hi) / 2;
            if (reach[mid] <= location) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    /// <summary>`>` of a blockquote (only spaces and other `>` before it on its line); drawn as a bar while markers are hidden.</summary>
    public static bool IsQuoteMarker(MarkdownRange range, string text)
    {
        if (range.Location >= text.Length || text[range.Location] != '>') return false;
        int i = range.Location;
        while (i > 0)
        {
            char c = text[i - 1];
            if (c == '\n') return true;
            if (c != ' ' && c != '\t' && c != '>') return false;
            i--;
        }
        return true;
    }

    /// <summary>`-`, `*` or `+` of a list item that is not a task (those keep their text).</summary>
    public static bool IsBullet(MarkdownRange range, string text)
    {
        if (range.Length != 1 || range.Location >= text.Length || text[range.Location] is not ('-' or '*' or '+')) return false;
        int box = range.Location + 2;
        return !(box + 2 < text.Length && text[box] == '[' && text[box + 2] == ']');
    }

    /// <summary>The drawing that replaces <paramref name="span"/> while markers are hidden, if any.</summary>
    public static MarkdownDecoration? DecorationOf(MarkdownSpan span, string text) => span.Kind.Kind switch
    {
        MarkdownKind.ListMarker when IsBullet(span.Range, text) => MarkdownDecoration.Bullet,
        MarkdownKind.Marker when IsQuoteMarker(span.Range, text) => MarkdownDecoration.QuoteBar,
        MarkdownKind.HorizontalRule => MarkdownDecoration.Rule,
        _ => null,
    };

    /// <summary>
    /// The hideable markers inside <paramref name="lines"/> that stay visible: those a selection touches (either end counts),
    /// and both delimiters of an emphasis, code span or link whose text or delimiters a selection touches, so a pair shows
    /// together. A heading's `#`s show when the caret is next to them, not anywhere on the line; fences when it is on the
    /// fence line. Drawn markers (bullets, quote bars, rules) are included, so they show as source when touched. None in
    /// reading mode.
    /// </summary>
    public static HashSet<MarkdownRange> ShownMarkers(IReadOnlyList<MarkdownSpan> spans, IReadOnlyList<int> reach,
        IReadOnlyList<MarkdownRange> selections, MarkdownRange lines, string text, bool reading)
    {
        var shown = new HashSet<MarkdownRange>();
        if (reading) return shown;
        bool Touched(MarkdownRange r) => selections.Any(s => r.Location <= s.End && s.Location <= r.End);
        List<MarkdownRange> markers = [], elements = [], decorated = [];
        for (int k = FirstIndex(reach, lines.Location); k < spans.Count && spans[k].Range.Location < lines.End; k++)
        {
            var span = spans[k];
            if (span.Range.Location < lines.Location || span.Range.End > lines.End) continue;
            switch (span.Kind.Kind)
            {
                case MarkdownKind.Marker when !IsQuoteMarker(span.Range, text):
                    markers.Add(span.Range);
                    break;
                case MarkdownKind.Marker or MarkdownKind.HorizontalRule:
                    decorated.Add(span.Range);
                    break;
                case MarkdownKind.ListMarker when IsBullet(span.Range, text):
                    decorated.Add(span.Range);
                    break;
                case MarkdownKind.Bold or MarkdownKind.Italic or MarkdownKind.BoldItalic or MarkdownKind.Strikethrough
                    or MarkdownKind.InlineCode or MarkdownKind.Link or MarkdownKind.WikiLink:
                    elements.Add(span.Range);
                    break;
            }
        }
        shown.UnionWith(markers.Where(Touched));
        shown.UnionWith(decorated.Where(Touched));
        if (elements.Count == 0) return shown;
        var byEnd = new Dictionary<int, MarkdownRange>();
        var byStart = new Dictionary<int, MarkdownRange>();
        foreach (var marker in markers)
        {
            byEnd[marker.End] = marker;
            byStart[marker.Location] = marker;
        }
        foreach (var element in elements)
        {
            // Both or none: a bare URL has no delimiters of its own, and a heading's `#` before it is not one.
            if (!byEnd.TryGetValue(element.Location, out var open) || !byStart.TryGetValue(element.End, out var close)) continue;
            var union = new MarkdownRange(open.Location, Math.Max(open.End, close.End) - open.Location);
            if (!Touched(union)) continue;
            shown.Add(open);
            shown.Add(close);
        }
        return shown;
    }

    // MARK: Fenced code

    private static readonly Dictionary<string, string> InfoAliases = new(StringComparer.Ordinal)
    {
        ["javascript"] = "js", ["typescript"] = "ts", ["python"] = "py", ["shell"] = "sh", ["console"] = "sh", ["objc"] = "m",
        ["objective-c"] = "m", ["c++"] = "cpp", ["csharp"] = "cs", ["c#"] = "cs", ["rust"] = "rs", ["golang"] = "go", ["kotlin"] = "kt",
        ["jsonc"] = "json", ["json5"] = "json",
    };

    private static readonly char[] WithComma = [' ', '{', ','], WithoutComma = [' ', '{'];

    /// <summary>The language word of a fence line: its first word without the fence characters (<c>```swift</c> → <c>swift</c>);
    /// a comma ends it too when <paramref name="commaSeparates"/> (the highlighter reads <c>```json,ignore</c> as json).</summary>
    public static string FenceInfo(string line, bool commaSeparates)
    {
        static bool Trimmed(char c) => c is '`' or '~' || char.IsWhiteSpace(c);
        int start = 0, end = line.Length;
        while (start < end && Trimmed(line[start])) start++;
        while (end > start && Trimmed(line[end - 1])) end--;
        var info = line.AsSpan(start, end - start);
        var separators = commaSeparates ? WithComma : WithoutComma;
        int cut = info.IndexOfAny(separators);
        // `split` drops empty parts: a leading separator moves the word on.
        while (cut == 0)
        {
            info = info[1..];
            cut = info.IndexOfAny(separators);
        }
        return (cut < 0 ? info : info[..cut]).ToString();
    }

    /// <summary>The code language an info word names (<c>js</c>, <c>python</c>, <c>c#</c>…); plain text when unknown.</summary>
    public static CodeLanguage LanguageForInfo(string info)
    {
        var key = info.ToLowerInvariant();
        return CodeLanguages.FromFileExtension(InfoAliases.GetValueOrDefault(key, key));
    }

    /// <summary>
    /// The lines after the opening fence of <paramref name="block"/> (the styler's code block range) and the language its
    /// info string names; null for a block without code lines.
    /// </summary>
    public static (MarkdownRange Inner, CodeLanguage Language)? FencedCode(string text, MarkdownRange block)
    {
        if (block.Location < 0 || block.End > text.Length) return null;
        int newline = text.IndexOf('\n', block.Location, block.Length);
        if (newline < 0) return null;
        var inner = new MarkdownRange(newline + 1, block.End - newline - 1);
        if (inner.Length <= 0) return null;
        return (inner, LanguageForInfo(FenceInfo(text.Substring(block.Location, newline - block.Location), commaSeparates: true)));
    }

    /// <summary>The language label drawn at the top-left of a block whose opening fence is hidden; empty when it has none.</summary>
    public static string FenceLabel(string text, MarkdownRange block)
    {
        if (block.Location < 0 || block.End > text.Length || block.Length == 0) return "";
        int newline = text.IndexOf('\n', block.Location, block.Length);
        int end = newline < 0 ? block.End : newline;
        return FenceInfo(text.Substring(block.Location, end - block.Location), commaSeparates: false);
    }
}

/// <summary>Size of inline images under their lines (docs/format.md, "Images").</summary>
public static class InlineImageLayout
{
    public const double MaxHeight = 420;
    public const double Gap = 6;

    /// <summary>Displayed size: natural size, shrunk to fit <paramref name="width"/> and <see cref="MaxHeight"/>, aspect kept, never enlarged.</summary>
    public static (double Width, double Height) Size(double naturalWidth, double naturalHeight, double width)
    {
        if (naturalWidth <= 0 || naturalHeight <= 0 || width <= 0) return (0, 0);
        var scale = Math.Min(1, Math.Min(width / naturalWidth, MaxHeight / naturalHeight));
        return (Math.Round(naturalWidth * scale, MidpointRounding.AwayFromZero), Math.Round(naturalHeight * scale, MidpointRounding.AwayFromZero));
    }

    /// <summary>Space to reserve below a line for images of these heights (0 when none is shown).</summary>
    public static double ReservedHeight(IEnumerable<double> heights)
    {
        var shown = heights.Where(h => h > 0).ToList();
        return shown.Count == 0 ? 0 : shown.Aggregate(Gap, (sum, h) => sum + h + Gap);
    }

    /// <summary>Scale from a file's pixels to layout units: a high-DPI file is shown smaller, up to four times; low-DPI files as is.</summary>
    public static double Density(double dpi) => dpi >= 72 ? Math.Min(dpi / 72, 4) : 1;
}
