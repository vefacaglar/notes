using System.Globalization;
using System.Text;

namespace NotesCore;

/// <summary>Automatic naming: new notes start as "Adsız" and follow their first line. See docs/format.md.</summary>
public sealed partial class NoteStore
{
    public const string UntitledName = "Adsız";
    internal const int MaxTitleLength = 60;
    internal const int MaxTitleBytes = 200;

    /// <summary>The first line of `content`: up to the first LF, without a trailing CR. Scans only that far.</summary>
    internal static string FirstLine(string content)
    {
        var end = content.IndexOf('\n');
        var line = end < 0 ? content : content[..end];
        return line.EndsWith('\r') ? line[..^1] : line;
    }

    private static bool IsBlank(ReadOnlySpan<char> line)
    {
        foreach (var c in line)
            if (!char.IsWhiteSpace(c)) return false;
        return true;
    }

    /// <summary>The first line that is not blank (only Unicode White_Space), found without splitting the whole note.</summary>
    internal static string? FirstNonBlankLine(string content)
    {
        var start = 0;
        while (start < content.Length)
        {
            var end = content.IndexOf('\n', start);
            var stop = end < 0 ? content.Length : end;
            if (stop > start && content[stop - 1] == '\r') stop--;
            if (!IsBlank(content.AsSpan(start, stop - start))) return content[start..stop];
            if (end < 0) break;
            start = end + 1;
        }
        return null;
    }

    private static bool IsTrimmed(char c) =>
        c is '*' or '_' or '~' or '`' or '\t' || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;

    /// <summary>
    /// A note name (without <c>.md</c>) for `content`: its first non-blank line without Markdown syntax, made valid
    /// under the name rules and capped in length. <c>null</c> when that line leaves nothing usable.
    /// </summary>
    public static string? Title(string content)
    {
        var line = FirstNonBlankLine(content);
        if (line is null) return null;

        // 1–2. Remove Markdown syntax.
        var removed = new bool[line.Length];
        foreach (var span in MarkdownStyler.Spans(line))
        {
            switch (span.Kind.Kind)
            {
                case MarkdownKind.HorizontalRule or MarkdownKind.CodeBlock:
                    return null;
                case MarkdownKind.Marker or MarkdownKind.ListMarker or MarkdownKind.TaskMarker:
                    var end = Math.Min(span.Range.End, line.Length);
                    for (var i = Math.Max(span.Range.Location, 0); i < end; i++) removed[i] = true;
                    break;
            }
        }
        var kept = new StringBuilder();
        for (var i = 0; i < line.Length; i++)
            if (!removed[i]) kept.Append(line[i]);
        var text = kept.ToString();
        var from = 0;
        var to = text.Length;
        while (from < to && IsTrimmed(text[from])) from++;
        while (to > from && IsTrimmed(text[to - 1])) to--;
        text = text[from..to];

        // 3. Map characters a name can't hold, per Unicode scalar (a "/" with a combining mark is still a "/"),
        // and collapse White_Space runs to one space.
        var mapped = new StringBuilder();
        var pendingSpace = false;
        foreach (var rune in text.EnumerateRunes())
        {
            string replacement;
            switch (rune.Value)
            {
                case '?' or '*':
                    continue;
                case '"':
                    replacement = "'";
                    break;
                case '\\' or '/' or ':' or '<' or '>' or '|':
                    replacement = "-";
                    break;
                default:
                    if (rune.Value <= 0x1F || rune.Value is >= 0x7F and <= 0x9F || Rune.IsWhiteSpace(rune))
                    {
                        pendingSpace = true;
                        continue;
                    }
                    replacement = rune.ToString();
                    break;
            }
            if (pendingSpace && mapped.Length > 0) mapped.Append(' ');
            pendingSpace = false;
            mapped.Append(replacement);
        }
        // Leading dots and spaces go as whole clusters, so a "." carrying a combining mark can't make it hidden.
        var clusters = Clusters(mapped.ToString());
        var skip = 0;
        while (skip < clusters.Count && clusters[skip][0] is '.' or ' ') skip++;
        var title = string.Concat(clusters.Skip(skip)).Normalize(NormalizationForm.FormC);

        // 4. Cap the length.
        clusters = Clusters(title);
        if (clusters.Count > MaxTitleLength)
        {
            // Cut at the last space within the first 61 clusters if at least 30 come before it.
            var head = clusters.GetRange(0, MaxTitleLength + 1);
            var space = head.FindLastIndex(c => c == " ");
            clusters = space >= MaxTitleLength / 2 ? head.GetRange(0, space) : head.GetRange(0, MaxTitleLength);
        }
        var bytes = clusters.Sum(Encoding.UTF8.GetByteCount);
        while (bytes > MaxTitleBytes)
        {
            bytes -= Encoding.UTF8.GetByteCount(clusters[^1]);
            clusters.RemoveAt(clusters.Count - 1);
        }
        var result = string.Concat(clusters).TrimEnd('.', ' ');

        // 5. Nothing usable left.
        if (result.All(c => c is '-' or ' ')) return null;
        return AvoidingReservedName(result);
    }

    /// <summary>`name` with "_" after its stem when Windows reserves it ("CON" → "CON_", "nul.txt" → "nul_.txt").</summary>
    internal static string AvoidingReservedName(string name)
    {
        if (!IsReservedName(name)) return name;
        var stemEnd = name.IndexOf('.');
        if (stemEnd < 0) stemEnd = name.Length;
        while (stemEnd > 0 && name[stemEnd - 1] == ' ') stemEnd--;
        return name.Insert(stemEnd, "_");
    }

    /// <summary>
    /// Whether a note called `name` follows its first line: its name, ignoring a " 2", " 3"… suffix,
    /// is "Adsız" or the title of `content`.
    /// </summary>
    public static bool IsAutoNamed(string name, string content)
    {
        name = name.Normalize(NormalizationForm.FormC);
        var baseName = BaseName(name);
        if (baseName == UntitledName) return true;
        var title = Title(content);
        return title is not null && (name == title || baseName == title);
    }

    /// <summary>
    /// The name an auto-named note called `name` should get now that it holds `content`, or <c>null</c> to keep its name:
    /// when the first line is blank, yields no title, or the name already matches.
    /// </summary>
    public static string? AutoName(string name, string content)
    {
        if (IsBlank(FirstLine(content))) return null;
        name = name.Normalize(NormalizationForm.FormC);
        var title = Title(content);
        return title is null || title == name || title == BaseName(name) ? null : title;
    }

    /// <summary>`name` without a trailing uniqueness suffix (" 2", " 3"…: ASCII digits, no leading zero, at least 2).</summary>
    internal static string BaseName(string name)
    {
        var space = name.LastIndexOf(' ');
        if (space <= 0) return name;
        var digits = name.AsSpan(space + 1);
        if (digits.IsEmpty || digits[0] == '0' || digits.ContainsAnyExceptInRange('0', '9')) return name;
        return !long.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out var number) || number < 2 ? name : name[..space];
    }

    /// <summary>
    /// `name`, or `name 2`, `name 3`…: the first note name (without <c>.md</c>) that no entry in `folder` has, as the file
    /// system sees it (so its own case and Unicode folding apply). The note at `ignoring` does not count, so a note
    /// can keep its name or change only its case.
    /// </summary>
    public string UniqueNoteName(string name, string? folder, string? ignoring = null)
    {
        string dir;
        try { dir = string.IsNullOrEmpty(folder) ? Root : FullPath(folder); }
        catch (NoteStoreException) { dir = Root; }
        string? own = null;
        if (ignoring is not null)
        {
            try { own = FullPath(ignoring); }
            catch (NoteStoreException) { }
        }
        var candidate = name;
        var number = 2;
        while (IsTaken(Path.Join(dir, candidate + ".md"), own))
        {
            candidate = $"{name} {number}";
            number++;
        }
        return candidate;
    }

    /// <summary>Whether something exists at `path` other than the file at `own`.</summary>
    internal static bool IsTaken(string path, string? own)
    {
        if (!Exists(path)) return false;
        return own is null || !IsSameFile(path, own);
    }

    /// <summary>
    /// Where to keep local edits that would overwrite a file changed by another program: "&lt;name&gt; (çakışma).&lt;ext&gt;",
    /// then "&lt;name&gt; (çakışma 2).&lt;ext&gt;"…, the first name for which `isTaken` is false.
    /// </summary>
    public static string ConflictCopyName(string fileName, Func<string, bool> isTaken)
    {
        var extension = PathExtension(fileName);
        var baseName = DeletingPathExtension(fileName);
        for (var number = 1; ; number++)
        {
            var suffix = number == 1 ? "çakışma" : $"çakışma {number}";
            var candidate = $"{baseName} ({suffix})" + (extension.Length == 0 ? "" : "." + extension);
            if (!isTaken(candidate)) return candidate;
        }
    }

    /// <summary><c>ConflictCopyName</c> for a file anywhere on disk, checked against what its folder holds now.</summary>
    public static string ConflictCopyPath(string path)
    {
        var folder = Path.GetDirectoryName(Path.GetFullPath(path))!;
        return Path.Join(folder, ConflictCopyName(Path.GetFileName(path), name => Exists(Path.Join(folder, name))));
    }
}
