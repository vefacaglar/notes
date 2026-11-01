using System.Globalization;
using System.Text;

namespace NotesCore;

/// <summary>Word, character and line counts for the status bar. See docs/format.md, "Status bar counts".</summary>
/// <param name="Words">Runs of non-whitespace characters.</param>
/// <param name="Characters">Characters as the user sees them (grapheme clusters), line breaks excluded.</param>
/// <param name="Lines">Line breaks (LF, CRLF, CR, U+2028, U+2029) plus one: empty text and "a" are one line, "a\n" is two.</param>
public readonly record struct TextStatistics(int Words, int Characters, int Lines)
{
    public TextStatistics(string text) : this(Count(text)) { }

    private TextStatistics((int Words, int Characters, int Lines) counts) : this(counts.Words, counts.Characters, counts.Lines) { }

    private static (int Words, int Characters, int Lines) Count(string text)
    {
        int words = 0, characters = 0, breaks = 0;
        var inWord = false;
        var span = text.AsSpan();
        var i = 0;
        while (i < span.Length)
        {
            var length = StringInfo.GetNextTextElementLength(span[i..]);
            var element = span.Slice(i, length);
            i += length;
            if (IsLineBreak(element))
            {
                breaks++;
                inWord = false;
                continue;
            }
            characters++;
            Rune.DecodeFromUtf16(element, out var first, out _);
            if (Rune.IsWhiteSpace(first))
            {
                inWord = false;
            }
            else if (!inWord)
            {
                inWord = true;
                words++;
            }
        }
        return (words, characters, breaks + 1);
    }

    /// <summary>Exactly the breaks docs/format.md lists; VT, FF and NEL are ordinary characters.</summary>
    private static bool IsLineBreak(ReadOnlySpan<char> element) =>
        element is "\n" or "\r" or "\r\n" or "\u2028" or "\u2029";
}
