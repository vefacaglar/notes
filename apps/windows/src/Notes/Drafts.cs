using NotesCore;

namespace Notes;

/// <summary>
/// The store of unsaved "new tab" notes: one Markdown file per draft in the app's own folder (app state, not part of the
/// notes folder), written by the draft's document like any autosave. A <c>--drafts</c> run uses another folder.
/// </summary>
internal static class Drafts
{
    private const string OrderFile = "order.txt";
    private const string LockFile = ".lock";

    /// <summary>Taken for writing the order file and for cleanup; never on the UI thread.</summary>
    private static readonly object OrderLock = new();
    /// <summary>Guards the latest order and its version only; held for an instant.</summary>
    private static readonly object OrderState = new();

    /// <summary>Set by <c>--drafts &lt;dir&gt;</c> for this run.</summary>
    public static string? Override { get; set; }

    // A test run (--root) never touches the real store or PendingDrafts: its drafts are throwaway, kept in a temp folder
    // that is deleted on exit (a --drafts folder is the caller's and stays). A persistent run that can't own the store
    // keeps its drafts in its own folder under PendingDrafts, locked while it runs, and the next store owner adopts it.
    private static readonly Lazy<string> Default = new(() =>
    {
        if (!AppSettings.IsPersistent) return Path.Combine(Path.GetTempPath(), "NotesTestDrafts-" + Guid.NewGuid().ToString("N"));
        if (!IsFallback) return RealFolder;
        var folder = Path.Combine(PendingRoot, Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(folder);
            pendingLock = new FileStream(Path.Combine(folder, LockFile), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
        return folder;
    });

    /// <summary>The app's own folder for drafts and the session.</summary>
    public static string AppFolder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Notes");
    private static string RealFolder => Path.Combine(AppFolder, "Drafts");
    private static string PendingRoot => Path.Combine(AppFolder, "PendingDrafts");

    private static FileStream? storeLock, pendingLock;

    /// <summary>Another Notes process holds the persistent store; this run keeps its drafts in a folder of its own.</summary>
    public static bool SharedWithOtherWindow { get; private set; }
    /// <summary>The persistent store can't be used for another reason (permissions, disk); same fallback.</summary>
    public static bool Unavailable { get; private set; }
    /// <summary>A persistent run whose drafts are in a folder of its own: they need handing over (or asking about) on exit.</summary>
    public static bool IsFallback => SharedWithOtherWindow || Unavailable;
    /// <summary>The run's own store was handed over or deleted; saving to it would recreate it.</summary>
    public static bool IsClosed => cleanedUp;

    private static bool TryLock()
    {
        try
        {
            Directory.CreateDirectory(RealFolder);
            storeLock = new FileStream(Path.Combine(RealFolder, LockFile), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            return true;
        }
        catch (IOException e) when ((e.HResult & 0xFFFF) is 32 or 33)
        {
            SharedWithOtherWindow = true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Unavailable = true;
        }
        return false;
    }

    /// <summary>Takes the persistent store exclusively for the life of the process (persistent runs only).</summary>
    public static void Acquire()
    {
        if (Override is not null || !AppSettings.IsPersistent) return;
        TryLock();
    }

    /// <summary>The store owner takes over the drafts of earlier runs that could not own it (their folders are no longer locked).</summary>
    public static void AdoptPending()
    {
        if (Override is not null || !AppSettings.IsPersistent || storeLock is null) return;
        lock (OrderLock)
        {
            string[] folders;
            try { folders = Directory.Exists(PendingRoot) ? Directory.GetDirectories(PendingRoot) : []; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; }
            foreach (var folder in folders)
            {
                try
                {
                    using var held = new FileStream(Path.Combine(folder, LockFile), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                    if (!MoveInto(folder)) continue;
                    held.Dispose();
                    Directory.Delete(folder, recursive: true);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                }
            }
        }
    }

    private static volatile bool cleanedUp;

    /// <summary>
    /// On exit: a test run's temp store is deleted. A persistent run that had to use its own folder moves its drafts
    /// into the real store if that is free now (and deletes the folder only after that worked); otherwise the folder
    /// stays under PendingDrafts for the next store owner, so nothing is destroyed.
    /// </summary>
    public static void FinishRun()
    {
        if (Override is not null || !Default.IsValueCreated || Default.Value == RealFolder || cleanedUp) return;
        NoteDocument.SaveAllNow();
        cleanedUp = true;
        var folder = Default.Value;
        // Waits for a pending order write; later ones are skipped.
        Task.Run(() =>
        {
            lock (OrderLock)
            {
                try
                {
                    var done = !AppSettings.IsPersistent || (storeLock is not null || TryLock()) && MoveInto(folder);
                    if (!done) return;
                    pendingLock?.Dispose();
                    Directory.Delete(folder, recursive: true);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                }
            }
        }).Wait();
    }

    /// <summary>Moves the drafts of `folder` into the real store under new names (the caller owns the store). False when that failed.</summary>
    private static bool MoveInto(string folder)
    {
        var drafts = SavedIn(folder);
        if (drafts.Count == 0) return true;
        var names = new List<string>();
        foreach (var draft in drafts)
        {
            var name = Guid.NewGuid().ToString("N") + ".md";
            try { File.Move(draft, Path.Combine(RealFolder, name)); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
            names.Add(name);
        }
        try { NoteFile.Write(string.Join('\n', ReadOrder(RealFolder).Concat(names)), Path.Combine(RealFolder, OrderFile)); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        return true;
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
    public static List<string> Saved() => SavedIn(Folder);

    private static List<string> SavedIn(string folder)
    {
        var found = new List<string>();
        try
        {
            if (!Directory.Exists(folder)) return found;
            var files = new DirectoryInfo(folder).GetFiles("*.md").Where(f => DraftName.IsMatch(f.Name)).OrderBy(f => f.CreationTimeUtc).ToList();
            foreach (var file in files.ToList())
            {
                if (file.Length > 0) continue;
                TryDelete(file.FullName);
                files.Remove(file);
            }
            var order = ReadOrder(folder);
            found.AddRange(order.Select(name => files.FirstOrDefault(f => f.Name == name)).OfType<FileInfo>().Select(f => f.FullName));
            found.AddRange(files.Select(f => f.FullName).Where(f => !found.Contains(f)));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
        return found;
    }

    private static List<string> ReadOrder(string folder)
    {
        try { return [.. File.ReadAllLines(Path.Combine(folder, OrderFile))]; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return []; }
    }

    private static List<string> latestOrder = [];
    private static int orderVersion, writtenVersion;

    /// <summary>Remembers the tab order of the open drafts: only the newest order is ever written, off the UI thread.</summary>
    public static void QueueOrder(IReadOnlyList<string> paths)
    {
        lock (OrderState)
        {
            latestOrder = [.. paths.Select(p => Path.GetFileName(p))];
            orderVersion++;
        }
        _ = Task.Run(WriteOrder);
    }

    private static void WriteOrder()
    {
        lock (OrderLock)
        {
            if (cleanedUp) return;
            List<string> order;
            int version;
            lock (OrderState)
            {
                if (writtenVersion == orderVersion) return;
                (order, version) = (latestOrder, orderVersion);
            }
            try
            {
                Directory.CreateDirectory(Folder);
                NoteFile.Write(string.Join('\n', order), Path.Combine(Folder, OrderFile));
                writtenVersion = version;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
            }
        }
    }

    public static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}
