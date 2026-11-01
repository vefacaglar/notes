using System.Globalization;
using System.Text;

namespace NotesCore;

/// <summary>The one-line preview the sidebar shows under a note's name. See docs/format.md, "Sidebar preview".</summary>
public sealed partial class NoteStore
{
    /// <summary>How much of a file is read for its preview.</summary>
    public const int PreviewBytes = 2048;
    public const int MaxPreviewLength = 200;

    /// <summary>Swift's <c>.newlines</c>: LF, VT, FF, CR, NEL, LS, PS.</summary>
    private static bool IsNewline(char c) => c is >= '\n' and <= '\r' or '\u0085' or '\u2028' or '\u2029';

    private static bool IsLineBreakChar(char c) => c is '\n' or '\r' or '\u0085' or '\u2028' or '\u2029';

    /// <summary>
    /// The first line after the title (the first non-blank line) that is not blank, a thematic break or inside a code
    /// fence, with Markdown syntax removed and whitespace runs collapsed to one space. <c>null</c> when there is none.
    /// </summary>
    public static string? Preview(string content)
    {
        var text = content.StartsWith('﻿') ? content[1..] : content;
        var skipped = new List<MarkdownRange>();
        var removed = new List<MarkdownRange>();
        foreach (var span in MarkdownStyler.Spans(text))
        {
            switch (span.Kind.Kind)
            {
                case MarkdownKind.HorizontalRule or MarkdownKind.CodeBlock:
                    skipped.Add(span.Range);
                    break;
                case MarkdownKind.Marker or MarkdownKind.ListMarker or MarkdownKind.TaskMarker:
                    removed.Add(span.Range);
                    break;
            }
        }

        var sawTitle = false;
        var location = 0;
        while (location < text.Length)
        {
            var lineStart = location;
            var end = lineStart;
            while (end < text.Length && !IsLineBreakChar(text[end])) end++;
            var contentEnd = end;
            if (end < text.Length) end += text[end] == '\r' && end + 1 < text.Length && text[end + 1] == '\n' ? 2 : 1;
            location = end;
            var lineEnd = end;

            // The line without its terminator, trimmed of newline characters at both ends.
            var from = lineStart;
            var to = contentEnd;
            while (from < to && IsNewline(text[from])) from++;
            while (to > from && IsNewline(text[to - 1])) to--;
            var line = text.AsSpan(from, to - from);
            if (line.IsEmpty || !line.ContainsAnyExcept(WhitespaceCharacters)) continue;
            if (!sawTitle)
            {
                sawTitle = true;
                continue;
            }
            if (skipped.Any(r => Math.Min(r.End, lineEnd) > Math.Max(r.Location, lineStart))) continue;

            var kept = new StringBuilder();
            var lineLength = to - from;
            for (var i = lineStart; i < lineStart + lineLength && i < text.Length; i++)
            {
                if (removed.Any(r => r.Contains(i))) continue;
                kept.Append(text[i]);
            }
            var words = new List<string>();
            var word = new StringBuilder();
            foreach (var cluster in Clusters(kept.ToString()))
            {
                if (cluster.All(char.IsWhiteSpace))
                {
                    if (word.Length > 0) words.Add(word.ToString());
                    word.Clear();
                }
                else word.Append(cluster);
            }
            if (word.Length > 0) words.Add(word.ToString());

            var result = TrimPreview(string.Join(" ", words));
            if (result.Length > 0) return TakeClusters(result, MaxPreviewLength);
        }
        return null;
    }

    private static readonly System.Buffers.SearchValues<char> WhitespaceCharacters = System.Buffers.SearchValues.Create(
        "\t\n\u000B\u000C\r \u0085             \u2028\u2029  　");

    /// <summary>Trims <c>*</c>, <c>_</c>, <c>~</c>, backticks, spaces and tabs from both ends, in any mix.</summary>
    private static string TrimPreview(string text)
    {
        var from = 0;
        var to = text.Length;
        while (from < to && IsPreviewTrimmed(text[from])) from++;
        while (to > from && IsPreviewTrimmed(text[to - 1])) to--;
        return text[from..to];
    }

    private static bool IsPreviewTrimmed(char c) =>
        c is '*' or '_' or '~' or '`' or '\t' || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;

    private static string TakeClusters(string text, int count)
    {
        var length = 0;
        for (var taken = 0; taken < count && length < text.Length; taken++)
            length += StringInfo.GetNextTextElementLength(text.AsSpan(length));
        return text[..length];
    }

    /// <summary>The preview of the file at `path`, reading only its first <see cref="PreviewBytes"/> bytes. <c>null</c> when unreadable or empty.</summary>
    public static string? PreviewOfFile(string path)
    {
        if (string.Equals(PathExtension(Path.GetFileName(path)), "mdenc", StringComparison.OrdinalIgnoreCase)) return null;
        byte[] data;
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var buffer = new byte[PreviewBytes];
            var total = 0;
            int count;
            while (total < buffer.Length && (count = stream.Read(buffer, total, buffer.Length - total)) > 0) total += count;
            data = buffer[..total];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
        if (data.Length == 0) return null;

        // The cut may fall inside a multi-byte character: drop up to three bytes of it.
        var strict = new UTF8Encoding(false, true);
        for (var dropped = 0; dropped <= 3 && data.Length - dropped > 0; dropped++)
        {
            try { return Preview(strict.GetString(data, 0, data.Length - dropped)); }
            catch (DecoderFallbackException) { }
        }
        return null;
    }
}
