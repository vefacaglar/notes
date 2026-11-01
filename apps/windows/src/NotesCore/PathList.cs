using System.Text.Json;

namespace NotesCore;

/// <summary>
/// An ordered list of absolute file paths kept in the app's support folder: the pinned notes (<c>pins.json</c>) and the
/// recently opened ones (<c>recents.json</c>). App state, not part of any notes folder. See docs/format.md, "App state".
/// Paths compare ignoring case, as the file system does; both <c>\</c> and <c>/</c> separate components.
/// </summary>
public sealed class PathList
{
    public int Version { get; private set; } = 1;
    public List<string> Paths { get; private set; }

    public PathList(IEnumerable<string>? paths = null)
    {
        Paths = paths is null ? [] : [.. paths];
    }

    private static bool Same(string a, string b) => string.Equals(a, b, StringComparison.OrdinalIgnoreCase);

    public bool Contains(string path) => Paths.Any(p => Same(p, path));

    /// <summary>Adds `path` at the end (a pin).</summary>
    public void Append(string path)
    {
        if (!Contains(path)) Paths.Add(path);
    }

    public void Remove(string path) => Paths.RemoveAll(p => Same(p, path));

    /// <summary>Puts `path` first, dropping what is past `limit` (a recent file).</summary>
    public void Push(string path, int limit)
    {
        Remove(path);
        Paths.Insert(0, path);
        if (Paths.Count > limit) Paths.RemoveRange(limit, Paths.Count - limit);
    }

    /// <summary>`path` rewritten after `old` was renamed to `newPath`; <c>null</c> when `path` is not `old` or inside it.</summary>
    internal static string? Moved(string path, string old, string newPath)
    {
        if (Same(path, old)) return newPath;
        var trimmed = old.TrimEnd('\\', '/');
        if (path.Length > trimmed.Length && path[trimmed.Length] is '\\' or '/' && path.StartsWith(trimmed, StringComparison.OrdinalIgnoreCase))
            return newPath + path[trimmed.Length..];
        return null;
    }

    /// <summary>Follows an item that was moved or renamed from `old` to `newPath`, whole folders included.</summary>
    public void MovedFrom(string old, string newPath)
    {
        var result = new List<string>();
        foreach (var path in Paths)
        {
            var updated = Moved(path, old, newPath) ?? path;
            if (!result.Any(r => Same(r, updated))) result.Add(updated);
        }
        Paths = result;
    }

    /// <summary>Drops `path` and everything inside it (the item went to the Recycle Bin).</summary>
    public void RemoveItem(string path) => Paths.RemoveAll(p => Moved(p, path, p) is not null);

    public override bool Equals(object? obj) => obj is PathList other && Version == other.Version && Paths.SequenceEqual(other.Paths, StringComparer.Ordinal);

    public override int GetHashCode() => HashCode.Combine(Version, Paths.Count);

    /// <summary>The list in `path`, or <c>null</c> when the file is missing or not a path list.</summary>
    public static PathList? Read(string path)
    {
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllBytes(path));
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("version", out var version) || !version.TryGetInt32(out var number)
                || !root.TryGetProperty("paths", out var paths) || paths.ValueKind != JsonValueKind.Array)
                return null;
            var list = new PathList { Version = number };
            foreach (var item in paths.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String) return null;
                list.Paths.Add(item.GetString()!);
            }
            return list;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }

    /// <summary>Writes atomically, creating the folder.</summary>
    public void Write(string path)
    {
        path = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            writer.WriteStartObject();
            writer.WriteStartArray("paths");
            foreach (var item in Paths) writer.WriteStringValue(item);
            writer.WriteEndArray();
            writer.WriteNumber("version", Version);
            writer.WriteEndObject();
        }
        NoteFile.Write(System.Text.Encoding.UTF8.GetString(stream.ToArray()), path);
    }
}
