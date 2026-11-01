using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;

[assembly: InternalsVisibleTo("NotesCore.Tests")]

namespace NotesCore;

public enum NoteStoreError
{
    InvalidName,
    AlreadyExists,
}

public sealed class NoteStoreException(NoteStoreError error, string name) : Exception
{
    public NoteStoreError Error { get; } = error;
    public string Name { get; } = name;

    public override string Message => Error switch
    {
        NoteStoreError.InvalidName => Strings.Format("InvalidName", Name),
        _ => Strings.Format("AlreadyExists", Name),
    };
}

/// <summary>An entry of the notes tree; equality is by value, children included. <c>Modified</c> (files only) is not compared, so
/// our own autosaves do not make a tree look changed.</summary>
public sealed record NoteNode(string Path, string Name, bool IsFolder, IReadOnlyList<NoteNode>? Children, DateTime? Modified = null)
{
    /// <summary><c>Path</c> relative to the store root, always "/"-separated.</summary>
    public string Id => Path;
    public bool IsNote => !IsFolder && NoteStore.IsNote(Path);

    public bool Equals(NoteNode? other) =>
        other is not null && Path == other.Path && Name == other.Name && IsFolder == other.IsFolder
        && (Children is null ? other.Children is null : other.Children is not null && Children.SequenceEqual(other.Children));

    public override int GetHashCode() => HashCode.Combine(Path, Name, IsFolder, Children?.Count);
}

public sealed record SearchHit(string Path, int? Line, string? Snippet)
{
    public string Id => $"{Path}:{Line ?? 0}";
}

/// <summary>A folder of plain Markdown notes plus other readable text files. See docs/format.md for the rules both apps follow.</summary>
public sealed partial class NoteStore
{
    /// <summary>Folders nested deeper than this are not listed (guards against link cycles).</summary>
    private const int MaxDepth = 32;

    public string Root { get; }

    public NoteStore(string root)
    {
        Root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        if (Root.Length == 2 && Root[1] == ':') Root += System.IO.Path.DirectorySeparatorChar;
        Directory.CreateDirectory(Root);
    }

    /// <summary>Notes are the <c>.md</c> files; only they are created by New Note and named automatically.</summary>
    public static bool IsNote(string path) => PathExtension(LastComponent(path)).ToLowerInvariant() == "md";

    /// <summary>Extensions (lowercased) of the files that are listed, searched and opened: notes, code and plain text.</summary>
    public static readonly IReadOnlySet<string> ListedExtensions = new HashSet<string>(StringComparer.Ordinal)
    {
        "md", "markdown", "mdown", "mkd", "json", "swift", "js", "mjs", "cjs", "jsx", "ts", "tsx", "mts", "cts", "py",
        "sh", "bash", "zsh", "yaml", "yml", "xml", "html", "htm", "plist", "svg", "css",
        "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "kts", "cs", "go", "rs", "sql", "toml", "ini",
        "txt", "log", "csv",
    };

    public static bool IsListed(string path)
    {
        var extension = PathExtension(LastComponent(path)).ToLowerInvariant();
        return extension.Length > 0 && ListedExtensions.Contains(extension);
    }

    // Paths are split on the scalar "/", never on grapheme clusters; UTF-16 '/' is the same thing.

    /// <summary>The extension after the last "." of a file name, without it; empty for ".hidden" and "name.".</summary>
    internal static string PathExtension(string name)
    {
        var dot = name.LastIndexOf('.');
        return dot <= 0 || dot == name.Length - 1 ? "" : name[(dot + 1)..];
    }

    internal static string DeletingPathExtension(string name)
    {
        var dot = name.LastIndexOf('.');
        return dot <= 0 || dot == name.Length - 1 ? name : name[..dot];
    }

    public static string[] Components(string path) => path.Split('/');

    public static string LastComponent(string path) => path[(path.LastIndexOf('/') + 1)..];

    /// <summary>The containing folder's path; empty for items in the root.</summary>
    public static string Parent(string path)
    {
        var slash = path.LastIndexOf('/');
        return slash < 0 ? "" : path[..slash];
    }

    /// <summary>The name shown for an item: the file name without <c>.md</c> for notes, the full name otherwise.</summary>
    public static string DisplayName(string path)
    {
        var name = LastComponent(path);
        return IsNote(name) ? DeletingPathExtension(name) : name;
    }

    /// <summary><c>path</c> rewritten after <c>old</c> was renamed to <c>newPath</c>; <c>null</c> when <c>path</c> is not <c>old</c> or inside it.</summary>
    public static string? Moved(string path, string old, string newPath)
    {
        if (string.Equals(path, old, StringComparison.Ordinal)) return newPath;
        var prefix = old + "/";
        return path.StartsWith(prefix, StringComparison.Ordinal) ? newPath + "/" + path[prefix.Length..] : null;
    }

    private static readonly HashSet<string> ReservedNames = new(
        ["CON", "PRN", "AUX", "NUL", .. Enumerable.Range(1, 9).SelectMany(n => new[] { $"COM{n}", $"LPT{n}" })],
        StringComparer.OrdinalIgnoreCase);

    /// <summary>Whether `name`'s part before the first "." (trailing spaces ignored) is a reserved device name.</summary>
    public static bool IsReservedName(string name)
    {
        var dot = name.IndexOf('.');
        return ReservedNames.Contains((dot < 0 ? name : name[..dot]).TrimEnd(' '));
    }

    /// <summary>Characters invalid in Windows file names; only C0/C1 controls, so the emoji joiner U+200D stays allowed.</summary>
    private static bool IsForbidden(char c) =>
        c is '\\' or ':' or '*' or '?' or '"' or '<' or '>' or '|' || c <= '\u001F' || c is >= '\u007F' and <= '\u009F';

    /// <summary>Whether `name` may be given to a new or renamed item: the portable (Windows) file name rules.</summary>
    public static bool IsValidName(string name) =>
        name.Length > 0 && name[0] != '.' && name[^1] != '.' && name[^1] != ' '
        && !name.Contains('/') && !name.Any(IsForbidden) && !IsReservedName(name);

    /// <summary>
    /// The full path of an existing item. Lenient so files made elsewhere still open: it rejects empty components and
    /// components starting with "." (hidden names, "." and ".."), components ending in "." or " " (Win32 strips it, so "bar." would
    /// alias "bar"), plus "\" and ":" which on Windows would leave the root (relative segments, drive letters, streams) and
    /// the wildcard and reserved characters * ? < > " |.
    /// </summary>
    private static readonly char[] UnaddressableChars = ['\\', ':', '*', '?', '<', '>', '"', '|'];

    public string FullPath(string path)
    {
        var parts = Components(path);
        if (!parts.All(p => p.Length > 0 && p[0] != '.' && p[^1] != '.' && p[^1] != ' ' && p.IndexOfAny(UnaddressableChars) < 0))
            throw new NoteStoreException(NoteStoreError.InvalidName, path);
        var full = Root;
        foreach (var part in parts) full = System.IO.Path.Join(full, part);
        return full;
    }

    /// <summary>The path for a new item called `name` in `folder`, after checking `name` against the portable rules.</summary>
    private (string Path, string FullPath) NewPath(string name, string? folder)
    {
        if (!IsValidName(name)) throw new NoteStoreException(NoteStoreError.InvalidName, name);
        var path = Join(folder, name);
        return (path, FullPath(path));
    }

    private static string Join(string? folder, string name) => string.IsNullOrEmpty(folder) ? name : folder + "/" + name;

    private static bool Exists(string fullPath) => File.Exists(fullPath) || Directory.Exists(fullPath);

    // MARK: Listing

    public IReadOnlyList<NoteNode> Tree() =>
        Children(Root, "", 0, [Native.Query(Root)?.FinalPath ?? Root]);

    /// <summary>Paths of all listed files (notes and other text files), in display order.</summary>
    public IReadOnlyList<string> NotePaths()
    {
        var paths = new List<string>();
        void Flatten(IReadOnlyList<NoteNode> nodes)
        {
            foreach (var node in nodes)
            {
                if (node.IsFolder) Flatten(node.Children ?? []);
                else paths.Add(node.Path);
            }
        }
        Flatten(Tree());
        return paths;
    }

    private static readonly Comparer<string> DisplayOrder = Comparer<string>.Create(Native.CompareLogical);

    /// <summary>`ancestors` are the final paths of `dir` and the folders above it: a directory link back to one of them
    /// is listed as an empty folder instead of being followed in a cycle.</summary>
    private List<NoteNode> Children(string dir, string prefix, int depth, List<string> ancestors)
    {
        if (depth > MaxDepth) return [];
        List<FileSystemInfo> entries;
        try { entries = new DirectoryInfo(dir).EnumerateFileSystemInfos().ToList(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }

        var nodes = new List<NoteNode>();
        foreach (var entry in entries)
        {
            var name = entry.Name;
            if (name.StartsWith('.') || name.EndsWith('.') || name.EndsWith(' ') || entry.Attributes.HasFlag(FileAttributes.Hidden)) continue;
            var path = prefix + name;
            if (entry.Attributes.HasFlag(FileAttributes.Directory))
            {
                var final = entry.Attributes.HasFlag(FileAttributes.ReparsePoint)
                    ? Native.Query(entry.FullName)?.FinalPath
                    : System.IO.Path.Join(ancestors[^1], name);
                var cycle = final is null || ancestors.Any(a => string.Equals(
                    System.IO.Path.TrimEndingDirectorySeparator(a), System.IO.Path.TrimEndingDirectorySeparator(final), StringComparison.OrdinalIgnoreCase));
                nodes.Add(new NoteNode(path, name, true, cycle ? [] : Children(entry.FullName, path + "/", depth + 1, [.. ancestors, final!])));
            }
            else if (IsListed(name))
                nodes.Add(new NoteNode(path, DisplayName(name), false, null, ModifiedOf(entry)));
        }
        return nodes.OrderBy(n => n.IsFolder ? 0 : 1).ThenBy(n => n.Name, DisplayOrder).ToList();
    }

    private static DateTime? ModifiedOf(FileSystemInfo entry)
    {
        try { return entry.LastWriteTimeUtc; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return null; }
    }

    // MARK: Reading & writing

    /// <summary>The file's text (UTF-8, a leading BOM dropped, line endings as stored).</summary>
    public string Read(string path)
    {
        var text = new UTF8Encoding(false, true).GetString(NoteFile.ReadBytes(FullPath(path)));
        return text.StartsWith('\uFEFF') ? text[1..] : text;
    }

    public void Write(string text, string path) => NoteFile.Write(text, FullPath(path));

    public DateTime? ModificationDate(string path)
    {
        try
        {
            var info = new FileInfo(FullPath(path));
            return info.Exists ? info.LastWriteTimeUtc : null;
        }
        catch (Exception e) when (e is NoteStoreException or IOException or UnauthorizedAccessException) { return null; }
    }

    // MARK: Managing

    /// <summary>Creates an empty note, appending <c>.md</c> when missing. Returns its path.</summary>
    public string CreateNote(string name, string? folder = null)
    {
        name = name.Trim();
        if (!IsNote(name)) name += ".md";
        var (path, full) = NewPath(name, folder);
        if (Exists(full)) throw new NoteStoreException(NoteStoreError.AlreadyExists, path);
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(full)!);
        using (new FileStream(full, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
        return path;
    }

    public string CreateFolder(string name, string? parent = null)
    {
        var (path, full) = NewPath(name.Trim(), parent);
        if (Exists(full)) throw new NoteStoreException(NoteStoreError.AlreadyExists, path);
        Directory.CreateDirectory(full);
        return path;
    }

    /// <summary>
    /// Renames an item in place. Notes keep their <c>.md</c> extension; other files keep theirs unless the new name ends in
    /// a listed extension (so "Meeting 3.5" for <c>a.txt</c> gives <c>Meeting 3.5.txt</c>). Returns the new path.
    /// </summary>
    public string Rename(string path, string newName)
    {
        var source = FullPath(path);
        newName = newName.Trim();
        if (newName.Length == 0 || newName.Contains('/')) throw new NoteStoreException(NoteStoreError.InvalidName, newName);
        var isFolder = Directory.Exists(source);
        if (!isFolder && !File.Exists(source)) throw new FileNotFoundException(Strings.Get("ItemNotFound"), source);

        var oldExtension = PathExtension(LastComponent(path));
        if (!isFolder && IsNote(path))
        {
            if (!IsNote(newName)) newName += ".md";
        }
        else if (!isFolder && oldExtension.Length > 0 && !IsListed(newName))
        {
            newName += "." + oldExtension;
        }

        var parent = Parent(path);
        var newPath = Join(parent, newName);
        if (string.Equals(newPath, path, StringComparison.Ordinal)) return path;
        var target = NewPath(newName, parent).FullPath;

        void Move(string from, string to)
        {
            if (isFolder) Directory.Move(from, to);
            else File.Move(from, to);
        }

        if (Exists(target))
        {
            // The same item under another spelling (case, or Unicode folding) is a rename the volume can't do in
            // one step, so go through a temporary name and move back if the second step fails.
            if (!IsSameFile(source, target)) throw new NoteStoreException(NoteStoreError.AlreadyExists, newPath);
            var temp = System.IO.Path.Join(System.IO.Path.GetDirectoryName(source)!, $"~rename-{Guid.NewGuid():N}");
            Move(source, temp);
            try { Move(temp, target); }
            catch
            {
                try { Move(temp, source); }
                catch (Exception rollback)
                {
                    throw new IOException(Strings.Format("RenameRollbackFailed", temp), rollback);
                }
                throw;
            }
        }
        else
        {
            Move(source, target);
        }
        return newPath;
    }

    /// <summary>Whether both paths name the same existing file system object (e.g. "a.md" and "A.md": NTFS asks its own case table).</summary>
    internal static bool IsSameFile(string a, string b) => Native.IsSameItem(a, b);

    /// <summary>Moves a note or folder to the Recycle Bin so it can be restored.</summary>
    public void Trash(string path) => Native.Recycle(FullPath(path), IntPtr.Zero);

    /// <summary><see cref="Trash(string)"/> with `owner` as the parent window of any shell prompt (e.g. "delete permanently?").</summary>
    public void Trash(string path, IntPtr owner) => Native.Recycle(FullPath(path), owner);

    // MARK: Search

    private static readonly CompareInfo Comparison = CultureInfo.InvariantCulture.CompareInfo;
    private const CompareOptions SearchOptions = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace;

    /// <summary>Case- and diacritic-insensitive search over file names and contents. File name matches come first.</summary>
    public List<SearchHit> Search(string query, int limit = 100)
    {
        query = FoldDotlessI(query.Trim());
        if (query.Length == 0 || query.All(IsIgnorable)) return [];

        var nameHits = new List<SearchHit>();
        var contentHits = new List<SearchHit>();
        foreach (var path in NotePaths())
        {
            var name = IsNote(path) ? DeletingPathExtension(path) : path;
            if (Comparison.IndexOf(FoldDotlessI(name), query, SearchOptions) >= 0) nameHits.Add(new SearchHit(path, null, null));
            if (contentHits.Count >= limit) continue;
            string text;
            try
            {
                if (NoteFile.GetSize(FullPath(path)) > NoteFile.MaxOpenSize) continue;
                text = Read(path);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or DecoderFallbackException or NoteStoreException) { continue; }

            var matchesInFile = 0;
            var lines = text.Split('\n');
            for (var index = 0; index < lines.Length; index++)
            {
                if (Comparison.IndexOf(FoldDotlessI(lines[index]), query, SearchOptions) < 0) continue;
                var snippet = Snippet(lines[index]);
                contentHits.Add(new SearchHit(path, index + 1, snippet));
                if (++matchesInFile == 3) break;
            }
        }
        return nameHits.Concat(contentHits).Take(limit).ToList();
    }

    /// <summary>Characters the comparison ignores entirely (joiners and other format characters, combining marks).</summary>
    private static bool IsIgnorable(char c) =>
        CharUnicodeInfo.GetUnicodeCategory(c) is UnicodeCategory.Format or UnicodeCategory.NonSpacingMark
            or UnicodeCategory.EnclosingMark or UnicodeCategory.SpacingCombiningMark;

    /// <summary>The trimmed line cut after 160 grapheme clusters; only that much is enumerated.</summary>
    internal static string Snippet(string line)
    {
        var text = line.AsSpan().Trim();
        var length = 0;
        for (var count = 0; count < 160 && length < text.Length; count++)
            length += StringInfo.GetNextTextElementLength(text[length..]);
        return new string(text[..length]);
    }

    /// <summary>Diacritic folding leaves Turkish ı/İ alone, so "toplanti" would miss "Toplantı".</summary>
    private static string FoldDotlessI(string text) =>
        text.Contains('ı') || text.Contains('İ') ? text.Replace('ı', 'i').Replace('İ', 'i') : text;

    /// <summary>Extended grapheme clusters of `text`.</summary>
    internal static List<string> Clusters(string text)
    {
        var clusters = new List<string>();
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext()) clusters.Add((string)enumerator.Current);
        return clusters;
    }
}
