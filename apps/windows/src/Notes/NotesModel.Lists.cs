using NotesCore;

namespace Notes;

/// <summary>
/// Pinned and recently opened files: two path lists in the support folder (<c>pins.json</c>, <c>recents.json</c>), app state
/// that never lives in a notes folder (docs/format.md, "App state"). Without a support folder, or in a process that does not
/// own the draft store, they are kept in memory only.
/// </summary>
internal sealed partial class NotesModel
{
    public const int RecentLimit = 10;

    public PathList Pins { get; private set; } = new();
    public PathList Recents { get; private set; } = new();

    /// <summary>The pinned files that are inside a root and exist, in pin order, with their modification dates.</summary>
    public IReadOnlyList<(ItemRef Item, NoteNode Node)> PinnedItems { get; private set; } = [];

    public event Action? PinsChanged;
    public event Action? RecentsChanged;

    private int pinnedVersion;
    private readonly Dictionary<string, long> listTickets = [];
    private static readonly object ListLock = new();

    private static string? ListPath(string name) => SessionStore.Folder is { } folder ? Path.Combine(folder, name) : null;

    /// <summary>Reads both lists (once, before the window shows them).</summary>
    private void LoadLists()
    {
        if (!SessionStore.CanWrite) return;
        if (ListPath("pins.json") is { } pins && PathList.Read(pins) is { } pinList) Pins = pinList;
        if (ListPath("recents.json") is { } recents && PathList.Read(recents) is { } recentList) Recents = recentList;
    }

    /// <summary>Writes a list atomically off the UI thread; only the newest save of a list is written. Failures are ignored:
    /// pins and recents are a convenience.</summary>
    private void WriteList(PathList list, string name)
    {
        if (!SessionStore.CanWrite || ListPath(name) is not { } path) return;
        var copy = new PathList(list.Paths);
        long ticket;
        lock (ListLock) ticket = listTickets[name] = listTickets.GetValueOrDefault(name) + 1;
        _ = Task.Run(() =>
        {
            lock (ListLock)
            {
                if (listTickets[name] != ticket) return;
                try { copy.Write(path); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException or NoteFileNotWritableException) { }
            }
        });
    }

    /// <summary>File &gt; Open Recent: a file of a root opens like a click in the sidebar; any other file in a tab of its own.
    /// Either way in write mode (only files from outside the app open for reading).</summary>
    public async Task OpenRecentAsync(string fullPath)
    {
        var item = LocateOrNull(fullPath);
        if (item is not null) await OpenFileAsync(item.FullPath, newTab: false, focus: true, item: item);
        else await OpenFileAsync(fullPath, newTab: !IsEmptyTab, focus: true, cancellable: false);
    }

    private static string Key(string fullPath) => Path.GetFullPath(fullPath);

    public bool IsPinned(string fullPath) => Pins.Contains(Key(fullPath));

    public void TogglePin(string fullPath)
    {
        var key = Key(fullPath);
        if (Pins.Contains(key)) Pins.Remove(key);
        else Pins.Append(key);
        WriteList(Pins, "pins.json");
        UpdatePinnedItems();
    }

    /// <summary>Files the user opened, newest first. Only listed files count; the menu skips those that are gone.</summary>
    private void RecordRecent(string fullPath)
    {
        if (!NoteStore.IsListed(fullPath)) return;
        Recents.Push(Key(fullPath), RecentLimit);
        WriteList(Recents, "recents.json");
        RecentsChanged?.Invoke();
    }

    public void ClearRecents()
    {
        Recents = new PathList();
        WriteList(Recents, "recents.json");
        RecentsChanged?.Invoke();
    }

    /// <summary>An item was renamed or moved: pins and recents follow it.</summary>
    private void ItemMovedInLists(string oldFull, string newFull)
    {
        var pins = new PathList(Pins.Paths);
        var recents = new PathList(Recents.Paths);
        Pins.MovedFrom(Key(oldFull), Key(newFull));
        Recents.MovedFrom(Key(oldFull), Key(newFull));
        if (!Pins.Equals(pins))
        {
            WriteList(Pins, "pins.json");
            UpdatePinnedItems();
        }
        if (!Recents.Equals(recents))
        {
            WriteList(Recents, "recents.json");
            RecentsChanged?.Invoke();
        }
    }

    private void ItemMovedInLists(RootFolder oldRoot, string oldPath, RootFolder newRoot, string newPath)
    {
        try { ItemMovedInLists(oldRoot.Store.FullPath(oldPath), newRoot.Store.FullPath(newPath)); }
        catch (NoteStoreException) { }
    }

    /// <summary>An item went to the Recycle Bin: its pin goes (the recents menu skips files that are missing).</summary>
    private void ItemTrashedInLists(string fullPath)
    {
        var pins = new PathList(Pins.Paths);
        Pins.RemoveItem(Key(fullPath));
        if (Pins.Equals(pins)) return;
        WriteList(Pins, "pins.json");
        UpdatePinnedItems();
    }

    private ItemRef? LocateOrNull(string path)
    {
        try { return Locate(path); }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return null; }
    }

    /// <summary>Recomputes <see cref="PinnedItems"/>; after a scan and whenever the pins change. A pin whose file is missing
    /// or outside the roots is hidden, not deleted: it comes back with its volume.</summary>
    public async void UpdatePinnedItems()
    {
        var version = ++pinnedVersion;
        var located = Pins.Paths.Select(LocateOrNull).OfType<ItemRef>().Where(i => !i.IsRoot).ToList();
        var found = await Task.Run(() => located
            .Select(i => (Item: i, Modified: i.Root.Store.ModificationDate(i.Path)))
            .Where(x => x.Modified is not null)
            .Select(x => (x.Item, Node: new NoteNode(x.Item.Path, NoteStore.DisplayName(x.Item.Path), false, null, x.Modified)))
            .ToList());
        if (version != pinnedVersion) return;
        found.RemoveAll(x => !roots.Contains(x.Item.Root));
        if (found.Count == PinnedItems.Count
            && found.Zip(PinnedItems).All(p => p.First.Item == p.Second.Item && p.First.Node.Modified == p.Second.Node.Modified)) return;
        PinnedItems = found;
        PinsChanged?.Invoke();
    }
}
