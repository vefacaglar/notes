using System.Globalization;
using System.Text;

namespace NotesCore;

/// <summary>An image reference <c>![alt](destination)</c> found in a Markdown text.</summary>
/// <param name="Range">The whole <c>![…](…)</c>, in UTF-16 coordinates.</param>
/// <param name="Alt">The alt text as written.</param>
/// <param name="Destination">The destination as written (percent-encoded, without the <c>&lt;&gt;</c> or title).</param>
public readonly record struct MarkdownImage(MarkdownRange Range, string Alt, string Destination);

/// <summary>Images in Markdown notes. See docs/format.md ("Images").</summary>
public static class MarkdownImages
{
    /// <summary>The images in `text`, in order, except those inside `excluded` (code spans and fenced blocks, ascending).</summary>
    public static List<MarkdownImage> References(string text, IReadOnlyList<MarkdownRange> excluded)
    {
        var result = new List<MarkdownImage>();
        var from = 0;
        while (from < text.Length)
        {
            var found = text.IndexOf("![", from, StringComparison.Ordinal);
            if (found < 0) break;
            from = found + 2;
            if (IsExcluded(found, excluded)) continue;
            if (found > 0 && text[found - 1] == '\\') continue;
            if (Parse(text, found) is { } image)
            {
                result.Add(image);
                from = image.Range.End;
            }
        }
        return result;
    }

    /// <summary>Same, finding code spans itself.</summary>
    public static List<MarkdownImage> References(string text) =>
        References(text, CodeRanges(MarkdownStyler.Spans(text)));

    /// <summary>Ranges of code spans and fenced blocks among `spans`, ascending.</summary>
    public static List<MarkdownRange> CodeRanges(IEnumerable<MarkdownSpan> spans) =>
        spans.Where(s => s.Kind.Kind is MarkdownKind.CodeBlock or MarkdownKind.InlineCode).Select(s => s.Range).ToList();

    private static bool IsExcluded(int location, IReadOnlyList<MarkdownRange> ranges)
    {
        int lo = 0, hi = ranges.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (ranges[mid].End <= location) lo = mid + 1;
            else hi = mid;
        }
        for (var k = lo; k < ranges.Count && ranges[k].Location <= location; k++)
            if (ranges[k].Contains(location)) return true;
        return false;
    }

    private static MarkdownImage? Parse(string text, int start)
    {
        int At(int index) => index < text.Length ? text[index] : -1;

        // Alt text: up to the matching `]` on the same line.
        var i = start + 2;
        var depth = 1;
        while (At(i) is var c and >= 0 && c != '\n')
        {
            if (c == '\\')
            {
                i += 2;
                continue;
            }
            if (c == '[') depth++;
            else if (c == ']' && --depth == 0) break;
            i++;
        }
        if (At(i) != ']' || At(i + 1) != '(') return null;
        var alt = text.Substring(start + 2, i - start - 2);
        i += 2;
        void SkipSpaces()
        {
            while (At(i) is ' ' or '\t') i++;
        }
        SkipSpaces();
        string destination;
        if (At(i) == '<')
        {
            var begin = i + 1;
            i = begin;
            while (At(i) is var d and >= 0 && d != '>' && d != '\n') i++;
            if (At(i) != '>') return null;
            destination = text.Substring(begin, i - begin);
            i++;
        }
        else
        {
            var begin = i;
            var parens = 0;
            while (At(i) is var d and >= 0 && d != ' ' && d != '\t' && d != '\n' && d != '\r')
            {
                if (d == '(') parens++;
                else if (d == ')')
                {
                    if (parens == 0) break;
                    parens--;
                }
                i++;
            }
            destination = text.Substring(begin, i - begin);
        }
        SkipSpaces();
        if (At(i) is '"' or '\'')
        {
            var quote = At(i);
            i++;
            while (At(i) is var d and >= 0 && d != quote && d != '\n') i++;
            if (At(i) != quote) return null;
            i++;
            SkipSpaces();
        }
        if (At(i) != ')' || destination.Length == 0) return null;
        return new MarkdownImage(new MarkdownRange(start, i + 1 - start), alt, destination);
    }

    /// <summary>
    /// The local file an image destination names: a relative path resolved against `noteFolder` (<c>null</c> for a draft
    /// without a file), an absolute path, or a <c>file:</c> URL. Remote addresses (<c>http:</c>…) and anything else give <c>null</c>.
    /// </summary>
    public static string? FilePath(string destination, string? noteFolder)
    {
        // Network shares (\\server\share, file://server/share) are not local files: reading one would sign in to that server.
        var path = LocalFilePath(destination, noteFolder);
        return path is null || path.StartsWith(@"\\", StringComparison.Ordinal) ? null : path;
    }

    private static string? LocalFilePath(string destination, string? noteFolder)
    {
        try
        {
            switch (NoteLinks.Classify(destination))
            {
                case LinkDestination.Web(var url):
                    return url.IsFile ? Path.GetFullPath(url.LocalPath) : null;
                case LinkDestination.File(var path):
                    if (path.StartsWith('/') || path.StartsWith('\\') || Path.IsPathFullyQualified(path)) return Path.GetFullPath(path);
                    // A colon here would address an alternate data stream.
                    return noteFolder is null || path.Contains(':') ? null : Path.GetFullPath(Path.Join(noteFolder, path));
                default:
                    return null;
            }
        }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return null;
        }
    }
}

/// <summary>Pasted and dropped images: written to <c>assets\</c> next to the note, named after the note.</summary>
public static class NoteAssets
{
    public const string FolderName = "assets";

    /// <summary>
    /// <c>&lt;note name&gt; &lt;n&gt;.&lt;ext&gt;</c>, valid under the portable name rules (<c>NoteStore.PortableName</c>, the note name
    /// capped at 60 characters; reserved device names fixed).
    /// </summary>
    public static string FileName(string noteName, int index, string fileExtension)
    {
        var name = NoteStore.PortableName(noteName, maxCharacters: 60);
        if (name.Length == 0) name = "image";
        return NoteStore.AvoidingReservedName($"{name} {index}.{fileExtension}");
    }

    /// <summary>
    /// The Markdown destination for a file in the assets folder: <c>assets/</c> plus the name percent-encoded
    /// (everything but ASCII letters, digits and <c>-._~</c>), so spaces, parentheses and non-ASCII are safe.
    /// </summary>
    public static string Destination(string fileName)
    {
        var encoded = new StringBuilder(FolderName + "/");
        foreach (var b in Encoding.UTF8.GetBytes(fileName))
        {
            if (b < 0x80 && (char.IsAsciiLetterOrDigit((char)b) || b is (byte)'-' or (byte)'.' or (byte)'_' or (byte)'~')) encoded.Append((char)b);
            else encoded.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return encoded.ToString();
    }

    /// <summary>
    /// Writes `data` as a new file in the <c>assets</c> folder next to the note at `notePath` (created if missing) and
    /// returns the Markdown destination. The file is written to a hidden temporary file and moved into place, so a
    /// half-written image never shows and an existing file is never replaced.
    /// </summary>
    public static string Save(byte[] data, string notePath, string fileExtension = "png")
    {
        var folder = Path.Join(Path.GetDirectoryName(Path.GetFullPath(notePath))!, FolderName);
        Directory.CreateDirectory(folder);
        var noteName = NoteStore.DeletingPathExtension(Path.GetFileName(notePath));
        var temporary = Path.Join(folder, $".{Guid.NewGuid():D}.tmp");
        using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
        {
            stream.Write(data);
            stream.Flush(flushToDisk: true);
        }
        try
        {
            for (var index = 1; index <= 9_999; index++)
            {
                var name = FileName(noteName, index, fileExtension);
                var target = Path.Join(folder, name);
                if (File.Exists(target) || Directory.Exists(target)) continue;
                try
                {
                    File.Move(temporary, target);
                    return Destination(name);
                }
                catch (IOException) when (File.Exists(target))
                {
                    continue;
                }
            }
            throw new IOException(Strings.Format("AlreadyExists", FolderName));
        }
        catch
        {
            try { File.Delete(temporary); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            throw;
        }
    }
}
