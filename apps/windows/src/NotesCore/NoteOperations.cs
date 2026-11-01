using System.Globalization;
using System.Text;

namespace NotesCore;

/// <summary>
/// Moving, duplicating and copying items in. Like renaming, none of these ever overwrites: a taken name gets a number.
/// See docs/format.md, "Moving, duplicating and copying in".
/// </summary>
public sealed partial class NoteStore
{
    /// <summary>The word Duplicate appends to a copy's name ("Plan copy.md"; "Plan kopya.md" in Turkish), following the UI language.</summary>
    internal static string CopyMarker
    {
        get
        {
            // TODO(l10n): key CopyMarker (en "copy", tr "kopya"); falls back to the culture until the key exists.
            var marker = Strings.Get("CopyMarker");
            if (marker != "CopyMarker") return marker;
            return CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "tr" ? "kopya" : "copy";
        }
    }

    // MARK: Portable names

    /// <summary>
    /// `name` made valid under the portable name rules (docs/format.md, "Paths and names"): <c>/</c>, the forbidden
    /// characters and control characters become <c>-</c>, the result is NFC, leading <c>.</c> and spaces and trailing <c>.</c>
    /// and spaces go (as whole grapheme clusters), it is cut to `maxCharacters` clusters if given and to `maxBytes` UTF-8
    /// bytes at a cluster boundary. Empty when nothing is left. Reserved device names are not handled here: they
    /// depend on the whole file name (<see cref="AvoidingReservedName"/>).
    /// </summary>
    public static string PortableName(string name, int? maxCharacters = null, int maxBytes = 200)
    {
        var mapped = new StringBuilder(name.Length);
        foreach (var rune in name.EnumerateRunes())
        {
            if (rune.Value == '/' || rune.Value <= 0x1F || rune.Value is >= 0x7F and <= 0x9F || (rune.IsBmp && IsForbidden((char)rune.Value)))
                mapped.Append('-');
            else
                mapped.Append(rune.ToString());
        }
        var clusters = Clusters(mapped.ToString().Normalize(NormalizationForm.FormC));
        var skip = 0;
        while (skip < clusters.Count && clusters[skip][0] is '.' or ' ') skip++;
        clusters.RemoveRange(0, skip);
        if (maxCharacters is { } limit && clusters.Count > limit) clusters.RemoveRange(limit, clusters.Count - limit);
        var bytes = clusters.Sum(Encoding.UTF8.GetByteCount);
        while (bytes > maxBytes)
        {
            bytes -= Encoding.UTF8.GetByteCount(clusters[^1]);
            clusters.RemoveAt(clusters.Count - 1);
        }
        return string.Concat(clusters).TrimEnd('.', ' ');
    }

    /// <summary>
    /// A file or folder name made portable for copying in or duplicating: stem and extension each pass through
    /// <see cref="PortableName"/>, the whole name is at most 200 UTF-8 bytes (the extension is kept), and a reserved
    /// device name gets "_". A name that leaves no stem becomes "item".
    /// </summary>
    public static string PortableFileName(string name, bool isFolder)
    {
        var extension = isFolder ? "" : PortableName(PathExtension(name), maxBytes: 20);
        var rawStem = isFolder ? name : DeletingPathExtension(name);
        var suffix = extension.Length == 0 ? "" : "." + extension;
        var stem = PortableName(rawStem, maxBytes: MaxTitleBytes - Encoding.UTF8.GetByteCount(suffix));
        if (stem.Length == 0) stem = "item";
        return AvoidingReservedName(stem + suffix);
    }

    // MARK: Names and folders

    /// <summary>
    /// `fileName`, or with " 2", " 3"… before the extension (folders have none) until `dir` has no entry by that name,
    /// as the file system sees it. With `marker` the first candidate is already "&lt;stem&gt; &lt;marker&gt;" ("Plan copy.md",
    /// "Plan copy 2.md").
    /// </summary>
    public static string UniqueItemName(string fileName, bool isFolder, string? marker, string dir)
    {
        var extension = isFolder ? "" : PathExtension(fileName);
        var stem = isFolder ? fileName : DeletingPathExtension(fileName);
        var baseName = marker is null ? stem : $"{stem} {marker}";
        for (var number = 1; ; number++)
        {
            var candidate = (number == 1 ? baseName : $"{baseName} {number}") + (extension.Length == 0 ? "" : "." + extension);
            if (!IsTaken(Path.Join(dir, candidate), null)) return candidate;
        }
    }

    /// <summary>Whether `child` is `parent` or inside it, comparing resolved full paths.</summary>
    internal static bool IsInside(string child, string parent)
    {
        static string Resolve(string path) =>
            Path.TrimEndingDirectorySeparator(Native.Query(path)?.FinalPath ?? Path.GetFullPath(path));
        var baseName = Resolve(parent);
        var other = Resolve(child);
        return string.Equals(other, baseName, StringComparison.OrdinalIgnoreCase)
            || other.StartsWith(baseName + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private string ExistingFolder(string? folder)
    {
        if (string.IsNullOrEmpty(folder)) return Root;
        var full = FullPath(folder);
        if (!Directory.Exists(full)) throw new DirectoryNotFoundException(Strings.Get("ItemNotFound"));
        return full;
    }

    private static void CopyEntry(string source, string target, bool isDirectory)
    {
        if (!isDirectory)
        {
            File.Copy(source, target, overwrite: false);
            return;
        }
        Directory.CreateDirectory(target);
        foreach (var entry in new DirectoryInfo(source).EnumerateFileSystemInfos())
            CopyEntry(entry.FullName, Path.Join(target, entry.Name), entry.Attributes.HasFlag(FileAttributes.Directory));
    }

    // MARK: Operations

    /// <summary>
    /// Moves `path` into `folder` (<c>null</c>: the root) of `destination` (<c>null</c>: this store; another store moves it
    /// across roots). A taken name gets " 2", " 3"…; moving an item to the folder it is already in changes nothing. Throws
    /// when `folder` is the item or inside it. Returns the new path in the destination store.
    /// </summary>
    public string Move(string path, string? folder, NoteStore? destination = null)
    {
        var target = destination ?? this;
        var source = FullPath(path);
        var isDirectory = Directory.Exists(source);
        if (!isDirectory && !File.Exists(source)) throw new FileNotFoundException(Strings.Get("ItemNotFound"), source);
        var dir = target.ExistingFolder(folder);
        if (IsInside(dir, source)) throw new NoteStoreException(NoteStoreError.InvalidName, LastComponent(path));

        var name = LastComponent(path);
        if (IsSameFile(dir, Path.GetDirectoryName(source)!)) return path;
        var finalName = UniqueItemName(name, isDirectory, null, dir);
        var to = Path.Join(dir, finalName);
        if (!isDirectory) File.Move(source, to);
        else if (!string.Equals(Path.GetPathRoot(source), Path.GetPathRoot(to), StringComparison.OrdinalIgnoreCase))
        {
            // Another volume: copy, then delete, as the OS does.
            CopyEntry(source, to, isDirectory: true);
            Directory.Delete(source, recursive: true);
        }
        else Directory.Move(source, to);
        return Join(folder, finalName);
    }

    /// <summary>
    /// Copies the file at `path` next to itself as "&lt;name&gt; copy" ("&lt;name&gt; kopya" in Turkish; then " 2", " 3"…).
    /// Returns the copy's path.
    /// </summary>
    public string Duplicate(string path)
    {
        var source = FullPath(path);
        var isDirectory = Directory.Exists(source);
        if (!isDirectory && !File.Exists(source)) throw new FileNotFoundException(Strings.Get("ItemNotFound"), source);
        var dir = Path.GetDirectoryName(source)!;
        var name = UniqueItemName(PortableFileName(LastComponent(path), isDirectory), isDirectory, CopyMarker, dir);
        CopyEntry(source, Path.Join(dir, name), isDirectory);
        return Join(Parent(path), name);
    }

    /// <summary>
    /// Copies a file or folder from outside the store into `folder` (<c>null</c>: the root), with a unique name. Throws when
    /// the item is missing, hidden (leading "."), or a folder that contains the destination. Returns the new path.
    /// </summary>
    public string CopyIn(string source, string? folder)
    {
        source = Path.TrimEndingDirectorySeparator(Path.GetFullPath(source));
        var isDirectory = Directory.Exists(source);
        if (!isDirectory && !File.Exists(source)) throw new FileNotFoundException(Strings.Get("ItemNotFound"), source);
        var name = Path.GetFileName(source);
        if (name.Length == 0 || name[0] == '.') throw new NoteStoreException(NoteStoreError.InvalidName, name);
        var dir = ExistingFolder(folder);
        if (IsInside(dir, source)) throw new NoteStoreException(NoteStoreError.InvalidName, name);
        var finalName = UniqueItemName(PortableFileName(name, isDirectory), isDirectory, null, dir);
        CopyEntry(source, Path.Join(dir, finalName), isDirectory);
        return Join(folder, finalName);
    }
}
