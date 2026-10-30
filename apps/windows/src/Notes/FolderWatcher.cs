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
            watcher.Created += (_, _) => Poke();
            watcher.Changed += (_, _) => Poke();
            watcher.Deleted += (_, _) => Poke();
            watcher.Renamed += (_, _) => Poke();
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
