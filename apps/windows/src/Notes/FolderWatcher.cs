using Microsoft.UI.Dispatching;

namespace Notes;

/// <summary>Calls `onChange` on the UI thread when anything below `path` changes, coalesced to one call per 300 ms.</summary>
internal sealed class FolderWatcher : IDisposable
{
    private readonly FileSystemWatcher? watcher;
    private readonly DispatcherQueue queue;
    private readonly DispatcherQueueTimer timer;

    public FolderWatcher(string path, Action onChange)
    {
        queue = DispatcherQueue.GetForCurrentThread();
        timer = queue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(300);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => onChange();
        try
        {
            watcher = new FileSystemWatcher(path)
            {
                IncludeSubdirectories = true,
                InternalBufferSize = 64 * 1024,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size,
            };
            watcher.Created += (_, e) => PokeUnlessTemporary(e.Name);
            watcher.Changed += (_, e) => PokeUnlessTemporary(e.Name);
            watcher.Deleted += (_, e) => PokeUnlessTemporary(e.Name);
            watcher.Renamed += (_, e) => PokeUnlessTemporary(e.Name);
            // A buffer overflow loses events: re-read everything.
            watcher.Error += (_, _) => Poke();
            watcher.EnableRaisingEvents = true;
        }
        catch (Exception e) when (e is IOException or ArgumentException or UnauthorizedAccessException)
        {
            watcher?.Dispose();
            watcher = null; // window activation still refreshes
        }
    }

    /// <summary>The app's own temporary files (atomic saves, write probes) are not changes of the folder: reacting to them
    /// would make every check of the folder trigger the next one. The saved file itself is reported by its own name.</summary>
    private void PokeUnlessTemporary(string? name)
    {
        var file = Path.GetFileName(name ?? "");
        if (file.StartsWith(".notes-", StringComparison.Ordinal) && (file.EndsWith(".tmp", StringComparison.Ordinal) || file.EndsWith(".bak", StringComparison.Ordinal))) return;
        Poke();
    }

    private void Poke() => queue.TryEnqueue(() =>
    {
        if (!timer.IsRunning) timer.Start();
    });

    public void Dispose()
    {
        watcher?.Dispose();
        timer.Stop();
    }
}
