using NotesCore;

namespace Notes;

/// <summary>
/// The store of unsaved "new tab" notes: one Markdown file per draft in the app's own folder (app state, not part of the
/// notes folder), written by the draft's document like any autosave. A <c>--drafts</c> run uses another folder.
/// </summary>
internal static class Drafts
{
    private const string OrderFile = "order.txt";
    private static readonly object OrderLock = new();

    /// <summary>Set by <c>--drafts &lt;dir&gt;</c> for this run.</summary>
    public static string? Override { get; set; }

    // A test run (--root or --drafts) never touches the real store: its drafts are throwaway, kept in a per-process temp
    // folder that is deleted on exit (a --drafts folder is the caller's and stays).
    private static readonly Lazy<string> Default = new(() => AppSettings.IsPersistent
        ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Notes", "Drafts")
        : Path.Combine(Path.GetTempPath(), $"NotesDrafts-{Environment.ProcessId}"));

    /// <summary>Deletes the per-process temp store of a non-persistent run.</summary>
    public static void CleanUpThrowaway()
    {
        if (Override is not null || AppSettings.IsPersistent || !Default.IsValueCreated) return;
        try { Directory.Delete(Default.Value, recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    private static readonly System.Text.RegularExpressions.Regex DraftName = new("^[0-9a-f]{32}\\.md$");

    public static string Folder => Override ?? Default.Value;

    /// <summary>The path of a new draft; its folder exists.</summary>
    public static string NewPath()
    {
        Directory.CreateDirectory(Folder);
        return Path.Combine(Folder, Guid.NewGuid().ToString("N") + ".md");
    }

    /// <summary>The draft files with text, in their last tab order (others after them, oldest first). Empty ones are deleted.</summary>
    public static List<string> Saved()
    {
        var found = new List<string>();
        try
        {
            if (!Directory.Exists(Folder)) return found;
            var files = new DirectoryInfo(Folder).GetFiles("*.md").Where(f => DraftName.IsMatch(f.Name)).OrderBy(f => f.CreationTimeUtc).ToList();
            foreach (var file in files.ToList())
            {
                if (file.Length > 0) continue;
                TryDelete(file.FullName);
                files.Remove(file);
            }
            var order = ReadOrder();
            found.AddRange(order.Select(name => files.FirstOrDefault(f => f.Name == name)).OfType<FileInfo>().Select(f => f.FullName));
            found.AddRange(files.Select(f => f.FullName).Where(f => !found.Contains(f)));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
        return found;
    }

    private static List<string> ReadOrder()
    {
        try { return [.. File.ReadAllLines(Path.Combine(Folder, OrderFile))]; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }

    /// <summary>Remembers the tab order of the open drafts.</summary>
    public static void SaveOrder(IEnumerable<string> paths)
    {
        lock (OrderLock)
        try
        {
            Directory.CreateDirectory(Folder);
            NoteFile.Write(string.Join('\n', paths.Select(Path.GetFileName)), Path.Combine(Folder, OrderFile));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }

    public static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
