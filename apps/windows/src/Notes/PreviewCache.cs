using System.Globalization;
using NotesCore;

namespace Notes;

/// <summary>
/// The sidebar's one-line previews, read lazily (only for rows that appear) from the first bytes of each file off the UI
/// thread and kept until the file's modification date changes. UI thread only.
/// </summary>
internal sealed class PreviewCache
{
    public static PreviewCache Shared { get; } = new();

    private sealed record Entry(DateTime? Modified, string? Text);

    private readonly Dictionary<string, Entry> entries = new(StringComparer.OrdinalIgnoreCase);
    /// <summary>What a row asked for last, so a change during a read is read again.</summary>
    private readonly Dictionary<string, DateTime?> wanted = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> inFlight = new(StringComparer.OrdinalIgnoreCase);
    private const int Limit = 5000;

    /// <summary>A preview was read for this full path.</summary>
    public event Action<string>? Loaded;

    /// <summary>The cached preview of `fullPath`; null while it loads or when there is none.</summary>
    public string? Get(string fullPath) => entries.TryGetValue(fullPath, out var entry) ? entry.Text : null;

    /// <summary>Makes sure the preview of `fullPath` at `modified` gets cached. Only Markdown files have previews.</summary>
    public async void Request(string fullPath, DateTime? modified)
    {
        var name = Path.GetFileName(fullPath);
        if (!NoteStore.IsMarkdown(name)) return;
        if (entries.TryGetValue(fullPath, out var known) && known.Modified == modified && !wanted.ContainsKey(fullPath)) return;
        wanted[fullPath] = modified;
        if (!inFlight.Add(fullPath)) return;
        try
        {
            while (wanted.TryGetValue(fullPath, out var target))
            {
                if (entries.TryGetValue(fullPath, out var entry) && entry.Modified == target)
                {
                    wanted.Remove(fullPath);
                    return;
                }
                var text = await Task.Run(() => NoteStore.PreviewOfFile(fullPath));
                if (entries.Count >= Limit) entries.Clear();
                entries[fullPath] = new Entry(target, text);
                if (wanted.TryGetValue(fullPath, out var latest) && latest == target) wanted.Remove(fullPath);
                Loaded?.Invoke(fullPath);
            }
        }
        finally
        {
            inFlight.Remove(fullPath);
        }
    }

    /// <summary>The time for today's files, else the date, in the app's language.</summary>
    public static string DateText(DateTime modified)
    {
        var local = modified.ToLocalTime();
        return local.Date == DateTime.Now.Date
            ? local.ToString("t", CultureInfo.CurrentUICulture)
            : local.ToString("d", CultureInfo.CurrentUICulture);
    }
}
