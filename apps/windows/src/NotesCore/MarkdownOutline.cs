using System.Globalization;

namespace NotesCore;

/// <summary>One ATX heading of a Markdown text, for the outline. See docs/format.md ("Outline").</summary>
/// <param name="Level">1 to 6.</param>
/// <param name="Title">The heading text without <c>#</c> markers and closing <c>#</c>s, trimmed.</param>
/// <param name="Location">UTF-16 offset of the start of the heading's line.</param>
public readonly record struct OutlineHeading(int Level, string Title, int Location);

public static class MarkdownOutline
{
    /// <summary>
    /// The ATX headings (<c># …</c> to <c>###### …</c>) in document order. Lines inside fenced code are not headings,
    /// and headings with no text are left out.
    /// </summary>
    public static List<OutlineHeading> Headings(string text)
    {
        var result = new List<OutlineHeading>();
        foreach (var span in MarkdownStyler.Spans(text))
        {
            if (span.Kind.Kind != MarkdownKind.Heading || span.Range.End > text.Length) continue;
            var title = TitleOf(text.Substring(span.Range.Location, span.Range.Length));
            if (title.Length > 0) result.Add(new OutlineHeading(span.Kind.Level, title, LineStart(span.Range.Location, text)));
        }
        return result;
    }

    /// <summary>Lines end at LF only, like the scanner.</summary>
    private static int LineStart(int location, string text)
    {
        var start = location;
        while (start > 0 && text[start - 1] != '\n') start--;
        return start;
    }

    private static bool IsSpace(char c) => c == '\t' || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;

    private static string TrimSpaces(string s)
    {
        int a = 0, b = s.Length;
        while (a < b && IsSpace(s[a])) a++;
        while (b > a && IsSpace(s[b - 1])) b--;
        return s[a..b];
    }

    internal static string TitleOf(string line)
    {
        var trimmed = line.Trim();
        var text = TrimSpaces(trimmed.TrimStart('#'));
        // Closing sequence: `#`s preceded by a space (or the whole remainder).
        if (text.EndsWith('#'))
        {
            var body = text.TrimEnd('#');
            if (body.Length == 0) return "";
            if (body[^1] == ' ' || body[^1] == '\t') text = TrimSpaces(body);
        }
        return text;
    }
}
