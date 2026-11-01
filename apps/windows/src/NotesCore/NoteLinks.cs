using System.Globalization;
using System.Text;

namespace NotesCore;

/// <summary>Where a link in a note points.</summary>
public abstract record LinkDestination
{
    /// <summary>An absolute URL with a scheme (<c>https:</c>, <c>mailto:</c>, <c>file:</c>…).</summary>
    public sealed record Web(Uri Url) : LinkDestination;

    /// <summary>A relative (or absolute) file path, percent-decoded, without <c>#fragment</c> and <c>?query</c>.</summary>
    public sealed record File(string Path) : LinkDestination;

    /// <summary><c>[[Note name]]</c>, <c>[[Note name|alias]]</c> or <c>[[Note name#heading]]</c>: the note name.</summary>
    public sealed record Wiki(string Name) : LinkDestination;
}

/// <summary>A file in one of the workspace's roots: the index of the root and the path relative to it, "/"-separated.</summary>
public readonly record struct NoteRef(int Root, string Path);

/// <summary>Link classification and resolution (docs/format.md, "Links").</summary>
public static class NoteLinks
{
    /// <summary>
    /// `raw` is the destination of <c>[text](destination)</c> or a whole <c>[[wiki link]]</c>. <c>null</c> for empty
    /// destinations and in-page anchors (<c>#heading</c>).
    /// </summary>
    public static LinkDestination? Classify(string raw)
    {
        var text = raw.Trim();
        if (text.StartsWith("[[", StringComparison.Ordinal) && text.EndsWith("]]", StringComparison.Ordinal)
            && new StringInfo(text).LengthInTextElements >= 5)
        {
            return WikiName(text[2..^2]) is { } name ? new LinkDestination.Wiki(name) : null;
        }
        if (text.Length == 0 || text[0] == '#') return null;
        var colon = text.IndexOf(':');
        if (colon >= 2 && char.IsAsciiLetter(text[0])
            && text.AsSpan(0, colon).IndexOfAnyExcept(SchemeCharacters) < 0)
        {
            return ParseUrl(text) is { } url ? new LinkDestination.Web(url) : null;
        }
        var path = text;
        var cut = path.IndexOfAny(['#', '?']);
        if (cut >= 0) path = path[..cut];
        path = PercentDecode(path) ?? path;
        return path.Length == 0 ? null : new LinkDestination.File(path);
    }

    private static readonly System.Buffers.SearchValues<char> SchemeCharacters =
        System.Buffers.SearchValues.Create("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-.");

    private const string FragmentAllowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,/:;=?@";

    private static Uri? ParseUrl(string text)
    {
        if (Uri.TryCreate(text, UriKind.Absolute, out var url)) return url;
        var escaped = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(text))
        {
            if (b < 0x80 && FragmentAllowed.Contains((char)b)) escaped.Append((char)b);
            else escaped.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return Uri.TryCreate(escaped.ToString(), UriKind.Absolute, out url) ? url : null;
    }

    /// <summary>The text with <c>%XX</c> sequences decoded as UTF-8; <c>null</c> when a sequence is malformed.</summary>
    internal static string? PercentDecode(string text)
    {
        if (!text.Contains('%')) return text;
        var bytes = new List<byte>(text.Length);
        var literal = new StringBuilder();
        void Flush()
        {
            if (literal.Length == 0) return;
            bytes.AddRange(Encoding.UTF8.GetBytes(literal.ToString()));
            literal.Clear();
        }
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] != '%')
            {
                literal.Append(text[i]);
                continue;
            }
            if (i + 2 >= text.Length || !Uri.IsHexDigit(text[i + 1]) || !Uri.IsHexDigit(text[i + 2])) return null;
            Flush();
            bytes.Add((byte)((Uri.FromHex(text[i + 1]) << 4) | Uri.FromHex(text[i + 2])));
            i += 2;
        }
        Flush();
        try { return new UTF8Encoding(false, true).GetString(bytes.ToArray()); }
        catch (DecoderFallbackException) { return null; }
    }

    /// <summary>The note name of a wiki link's inner text: before <c>|</c> (alias) and <c>#</c> (heading), trimmed; <c>null</c> when empty.</summary>
    public static string? WikiName(string inner)
    {
        var name = inner;
        var cut = name.IndexOfAny(['|', '#']);
        if (cut >= 0) name = name[..cut];
        name = name.Trim();
        return name.Length == 0 ? null : name;
    }

    /// <summary>
    /// Case-insensitive comparison key for note names: NFC, lowercased, with Turkish dotless and dotted i folded
    /// to <c>i</c> so <c>ÇALIŞMA</c> finds <c>çalışma</c>.
    /// </summary>
    public static string FoldedName(string name) =>
        name.Normalize(NormalizationForm.FormC).Replace("İ", "i̇").ToLowerInvariant()
            .Replace('ı', 'i').Replace("i̇", "i");

    /// <summary>
    /// The file `destination` refers to among `candidates` (every listed file of every root), or <c>null</c>.
    /// `origin` is the note holding the link (<c>null</c> for a file outside the roots).
    /// <list type="bullet">
    /// <item>File links are relative to the note's folder and stay inside its root; the match ignores case, and a path
    /// without extension also tries <c>.md</c>. Without an origin they resolve to nothing (the caller tries the disk).</item>
    /// <item>Wiki links match the file's display name, its file name or its path without <c>.md</c>, ignoring case. Of several
    /// matches the one in the same folder wins, then the same root, then notes over other files, then the shortest path.</item>
    /// </list>
    /// </summary>
    public static NoteRef? Resolve(LinkDestination destination, NoteRef? origin, IReadOnlyList<NoteRef> candidates)
    {
        switch (destination)
        {
            case LinkDestination.File(var relative):
            {
                if (origin is not { } from || relative.StartsWith('/')) return null;
                if (Join(NoteStore.Parent(from.Path), relative) is not { } path) return null;
                var inRoot = candidates.Where(c => c.Root == from.Root).ToList();
                var wanted = new List<string> { path };
                if (NoteStore.PathExtension(NoteStore.LastComponent(path)).Length == 0) wanted.Add(path + ".md");
                foreach (var candidate in wanted)
                {
                    foreach (var exact in inRoot)
                        if (string.Equals(exact.Path, candidate, StringComparison.Ordinal)) return exact;
                    var key = FoldedName(candidate);
                    foreach (var loose in inRoot)
                        if (string.Equals(FoldedName(loose.Path), key, StringComparison.Ordinal)) return loose;
                }
                return null;
            }
            case LinkDestination.Wiki(var name):
            {
                var key = FoldedName(name);
                var keyWithoutExtension = key.EndsWith(".md", StringComparison.Ordinal) ? key[..^3] : key;
                NoteRef? best = null;
                (int, int, int, string) bestRank = default;
                foreach (var reference in candidates)
                {
                    var pathKey = FoldedName(WithoutNoteExtension(reference.Path));
                    var matches = FoldedName(DisplayName(reference.Path)) == keyWithoutExtension
                        || FoldedName(NoteStore.LastComponent(reference.Path)) == key
                        || (key.Contains('/') && (pathKey == keyWithoutExtension || pathKey.EndsWith("/" + keyWithoutExtension, StringComparison.Ordinal)));
                    if (!matches) continue;
                    var rank = Rank(reference, origin);
                    if (best is null || Compare(rank, bestRank) < 0)
                    {
                        best = reference;
                        bestRank = rank;
                    }
                }
                return best;
            }
            default:
                return null;
        }
    }

    private static (int, int, int, string) Rank(NoteRef reference, NoteRef? origin)
    {
        var tier = origin is { } from && reference.Root == from.Root
            ? (NoteStore.Parent(reference.Path) == NoteStore.Parent(from.Path) ? 0 : 1)
            : 2;
        return (tier, NoteStore.IsNote(reference.Path) ? 0 : 1, NoteStore.Components(reference.Path).Length, reference.Path);
    }

    private static int Compare((int, int, int, string) a, (int, int, int, string) b)
    {
        if (a.Item1 != b.Item1) return a.Item1.CompareTo(b.Item1);
        if (a.Item2 != b.Item2) return a.Item2.CompareTo(b.Item2);
        if (a.Item3 != b.Item3) return a.Item3.CompareTo(b.Item3);
        return string.CompareOrdinal(a.Item4, b.Item4);
    }

    private static bool IsEncrypted(string path) =>
        string.Equals(NoteStore.PathExtension(NoteStore.LastComponent(path)), "mdenc", StringComparison.OrdinalIgnoreCase);

    /// <summary>Like <see cref="NoteStore.DisplayName"/>, which does not know encrypted notes (<c>.mdenc</c>) yet.</summary>
    private static string DisplayName(string path)
    {
        var name = NoteStore.LastComponent(path);
        return NoteStore.IsNote(name) || IsEncrypted(name) ? NoteStore.DeletingPathExtension(name) : name;
    }

    private static string WithoutNoteExtension(string path) =>
        NoteStore.IsNote(path) || IsEncrypted(path) ? path[..path.LastIndexOf('.')] : path;

    /// <summary>`relative` appended to `folder` with <c>.</c> and <c>..</c> resolved; <c>null</c> when it climbs out of the root.</summary>
    public static string? Join(string folder, string relative)
    {
        var parts = folder.Length == 0 ? new List<string>() : NoteStore.Components(folder).ToList();
        foreach (var part in NoteStore.Components(relative))
        {
            switch (part)
            {
                case "" or ".":
                    continue;
                case "..":
                    if (parts.Count == 0) return null;
                    parts.RemoveAt(parts.Count - 1);
                    break;
                default:
                    parts.Add(part);
                    break;
            }
        }
        return parts.Count == 0 ? null : string.Join("/", parts);
    }

    /// <summary>
    /// Whether the relative `path` of a note inside a root climbs above that root with <c>..</c>. Such a link resolves to
    /// nothing, and the disk is not tried either.
    /// </summary>
    public static bool EscapesRoot(string relative, NoteRef origin)
    {
        var depth = NoteStore.Components(NoteStore.Parent(origin.Path)).Count(c => c.Length > 0);
        foreach (var part in NoteStore.Components(relative))
        {
            switch (part)
            {
                case "" or ".":
                    continue;
                case "..":
                    if (depth == 0) return true;
                    depth--;
                    break;
                default:
                    depth++;
                    break;
            }
        }
        return false;
    }

    /// <summary>
    /// Extensions of programs, scripts and installers (lowercase, no dot). A click on a link to such a file shows it in
    /// the file manager instead of opening it; the apps add their own checks (executable bit, bundles).
    /// </summary>
    public static readonly IReadOnlySet<string> ProgramExtensions = new HashSet<string>(StringComparer.Ordinal)
    {
        "app", "command", "sh", "bash", "zsh", "csh", "ksh", "fish", "pkg", "mpkg", "scpt", "scptd", "workflow", "action", "terminal",
        "exe", "com", "bat", "cmd", "ps1", "psm1", "vbs", "vbe", "wsf", "msi", "msp", "lnk", "scr", "jar", "dmg", "appref-ms",
        "js", "jse", "wsh", "hta", "cpl", "reg", "pif", "msc",
        "url", "website", "application", "appinstaller", "appx", "appxbundle", "msix", "msixbundle", "settingcontent-ms", "library-ms",
        "search-ms", "searchconnector-ms", "chm", "diagcab", "xbap", "wsc", "sct", "inf", "gadget", "ws", "msh", "msh1", "msh2",
        "mshxml", "msh1xml", "msh2xml", "ps1xml", "ps2", "ps2xml", "psc1", "psc2", "vb", "vbscript",
    };

    /// <summary>Windows ignores trailing dots and spaces in a file name, so <c>tool.exe.</c> is <c>tool.exe</c>.</summary>
    public static bool IsProgram(string fileName) =>
        ProgramExtensions.Contains(NoteStore.PathExtension(fileName.TrimEnd('.', ' ')).ToLowerInvariant());
}
