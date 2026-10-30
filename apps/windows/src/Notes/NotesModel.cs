using NotesCore;

namespace Notes;

/// <summary>One root folder of the workspace: a notes folder with its own store, tree and watcher.</summary>
internal sealed class RootFolder(NoteStore store, string canonicalRoot)
{
    public NoteStore Store { get; } = store;
    public string Root => Store.Root;
    /// <summary>The root as the file system spells it, links resolved.</summary>
    public string CanonicalRoot { get; } = canonicalRoot;
    public string Name => Path.GetFileName(Path.TrimEndingDirectorySeparator(Root)) is { Length: > 0 } name ? name : Root;
    public IReadOnlyList<NoteNode> Tree { get; set; } = [];
    public FolderWatcher? Watcher { get; set; }
    public int ScanVersion { get; set; }
}

/// <summary>An item in a root; an empty <see cref="Path"/> is the root itself.</summary>
internal sealed record ItemRef(RootFolder Root, string Path)
{
    public bool IsRoot => Path.Length == 0;
    public string FullPath => IsRoot ? Root.Root : Root.Store.FullPath(Path);
}

/// <summary>An item a dialog is about to act on; follows automatic renames while the dialog is open.</summary>
internal sealed class PathRef(RootFolder root, string path)
{
    public RootFolder Root { get; } = root;
    public string Path { get; set; } = path;
}

/// <summary>A tab of the main window: one open file, or empty.</summary>
internal sealed class NoteTab
{
    public NoteDocument? Document { get; set; }
}

/// <summary>
/// The workspace: its root folders and their trees, search, the sidebar selection and the open tabs. UI thread only;
/// file I/O runs on the thread pool, and everything that writes goes through <see cref="FileGate"/>.
/// </summary>
internal sealed class NotesModel
{
    private readonly List<RootFolder> roots = [];
    private readonly List<NoteTab> tabs = [];

    public IReadOnlyList<RootFolder> Roots => roots;
    public IReadOnlyList<NoteTab> Tabs => tabs;
    public NoteTab? ActiveTab { get; private set; }
    public NoteDocument? ActiveDocument => ActiveTab?.Document;
    /// <summary>The selected item in the sidebar.</summary>
    public ItemRef? Selection { get; private set; }
    public string Query { get; private set; } = "";
    public IReadOnlyList<(RootFolder Root, SearchHit Hit)> Hits { get; private set; } = [];
    public bool IsSearching => Query.Trim().Length > 0;
    public string? ErrorMessage { get; private set; }

    public event Action? RootsChanged;
    public event Action<RootFolder>? TreeChanged;
    public event Action? SelectionChanged;
    public event Action? TabsChanged;
    public event Action? ActiveTabChanged;
    public event Action? QueryChanged;
    public event Action? HitsChanged;
    public event Action? ErrorChanged;
    public event Action? WindowRequested;

    private CancellationTokenSource? searchCancel;
    private int openVersion;
    /// <summary>Pending "is it really gone?" checks, per document.</summary>
    private readonly HashSet<Guid> missingChecks = [];
    private readonly List<PathRef> tracked = [];

    public void ShowError(string? message)
    {
        ErrorMessage = message;
        ErrorChanged?.Invoke();
    }

    private IEnumerable<NoteDocument> OpenDocuments => tabs.Select(t => t.Document).OfType<NoteDocument>();

    // MARK: Roots

    /// <summary>Opens the given roots (a `--root` test run never writes them back; see <see cref="AppSettings.IsPersistent"/>).</summary>
    public async Task StartAsync(IReadOnlyList<string> paths)
    {
        foreach (var path in paths)
        {
            try
            {
                if (await CreateRootAsync(path) is { } root && Validate(root) is null) AddRoot(root);
            }
            catch (Exception e)
            {
                ShowError(Loc.Format("OpenFailed", path, Paths.Describe(e)));
            }
        }
    }

    private static Task<RootFolder> CreateRootAsync(string path) => Task.Run(() =>
    {
        var store = new NoteStore(path);
        return new RootFolder(store, Paths.Canonical(store.Root));
    });

    /// <summary>Why `root` can't join the workspace: it is a root already, or inside or around one (its files would show twice).</summary>
    private string? Validate(RootFolder root)
    {
        foreach (var other in roots)
        {
            if (Paths.Same(other.CanonicalRoot, root.CanonicalRoot)) return Loc.Format("AlreadyInWorkspace", root.Name);
            if (Paths.IsInside(root.CanonicalRoot, other.CanonicalRoot))
                return Loc.Format("InsideWorkspaceFolder", root.Name, other.Name);
            if (Paths.IsInside(other.CanonicalRoot, root.CanonicalRoot))
                return Loc.Format("ContainsWorkspaceFolder", root.Name, other.Name);
        }
        return null;
    }

    private void AddRoot(RootFolder root)
    {
        roots.Add(root);
        root.Watcher = new FolderWatcher(root.Root, Refresh);
        RootsChanged?.Invoke();
        Refresh(root);
    }

    /// <summary>"Add Folder…": adds a folder the user picked and remembers the list.</summary>
    public async Task AddRootAsync(string path)
    {
        try
        {
            var root = await CreateRootAsync(path);
            if (Validate(root) is { } problem)
            {
                ShowError(problem);
                return;
            }
            AddRoot(root);
            await SaveRootsAsync();
        }
        catch (Exception e)
        {
            ShowError(Loc.Format("AddFailed", path, Paths.Describe(e)));
        }
    }

    /// <summary>"Remove Folder from Workspace": closes the root's tabs (saving first; `confirm` decides about edits that can't
    /// be saved) and drops it from the list. Nothing on disk changes.</summary>
    public async Task RemoveRootAsync(RootFolder root, Func<NoteDocument, Task<bool>> confirm)
    {
        var inside = tabs.Where(t => t.Document is { } d && Paths.IsInside(d.Path, root.Root)).ToList();
        foreach (var tab in inside)
        {
            if (tab.Document is { } document && !await SettleAsync(document, confirm)) return;
        }
        if (!roots.Contains(root)) return;
        // Typing after a tab settled keeps that tab open.
        inside.RemoveAll(t => t.Document is { } d && Synced(d).HasUnsavedChanges);
        foreach (var tab in inside) RemoveTab(tab);
        root.Watcher?.Dispose();
        roots.Remove(root);
        if (Selection?.Root == root) SetSelection(null);
        tracked.RemoveAll(t => t.Root == root);
        RootsChanged?.Invoke();
        ScheduleSearch();
        await SaveRootsAsync();
    }

    private async Task SaveRootsAsync()
    {
        var list = roots.Select(r => r.Root).ToList();
        try { await Task.Run(() => AppSettings.SaveRoots(list)); }
        catch (Exception e) { ShowError(Loc.Format("WorkspaceSaveFailed", Paths.Describe(e))); }
    }

    /// <summary>Whether `path` in `root`, or a folder above it, is hidden (does I/O). The sidebar never lists such items,
    /// so they are treated as outside files.</summary>
    private static bool IsHidden(RootFolder root, string path)
    {
        var full = root.Root;
        foreach (var part in NoteStore.Components(path))
        {
            full = Path.Join(full, part);
            try
            {
                if (File.GetAttributes(full).HasFlag(FileAttributes.Hidden)) return true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return false;
            }
        }
        return false;
    }

    /// <summary>The root and relative path of `fullPath` when it is a listed file inside one of the roots (names starting
    /// with "." never are; hidden attributes are checked where opening and renaming do I/O anyway).</summary>
    public ItemRef? Locate(string fullPath)
    {
        fullPath = Path.GetFullPath(fullPath);
        foreach (var root in roots)
        {
            var path = Paths.Relative(fullPath, root.Root) ?? Paths.Relative(fullPath, root.CanonicalRoot);
            if (path is null || !NoteStore.IsListed(path)) continue;
            try { root.Store.FullPath(path); }
            catch (NoteStoreException) { continue; }
            return new ItemRef(root, path);
        }
        return null;
    }

    // MARK: Refreshing

    /// <summary>Re-reads every tree off the UI thread and reloads open files that changed on disk.
    /// Runs on window activation and every file system event below a root, including our own autosaves.</summary>
    public void Refresh()
    {
        foreach (var root in roots) Refresh(root);
        CheckOpenDocuments();
        if (IsSearching) ScheduleSearch();
    }

    private async void Refresh(RootFolder root)
    {
        var version = ++root.ScanVersion;
        IReadOnlyList<NoteNode> tree;
        try { tree = await Task.Run(root.Store.Tree); }
        catch (Exception) { return; }
        if (!roots.Contains(root) || version != root.ScanVersion || tree.SequenceEqual(root.Tree)) return;
        root.Tree = tree;
        TreeChanged?.Invoke(root);
    }

    private async void CheckOpenDocuments()
    {
        var documents = OpenDocuments.Select(d => (Document: d, d.Path)).ToList();
        var missing = await Task.Run(() => documents.Where(d => !File.Exists(d.Path)).Select(d => d.Document).ToHashSet());
        foreach (var (document, path) in documents)
        {
            if (document.Path != path || !OpenDocuments.Contains(document)) continue;
            if (!missing.Contains(document)) _ = document.ReloadIfChangedAsync();
            else if (!document.HasUnsavedChanges) CloseIfStillMissing(document);
        }
    }

    /// <summary>Closes the tab of `document` when its file is gone for good; some programs save by deleting and recreating.</summary>
    private async void CloseIfStillMissing(NoteDocument document)
    {
        if (!missingChecks.Add(document.Id)) return;
        await Task.Delay(1000);
        missingChecks.Remove(document.Id);
        if (document.HasUnsavedChanges) return;
        var path = document.Path;
        if (await Task.Run(() => File.Exists(path))) return;
        if (document.HasUnsavedChanges || document.Path != path) return;
        foreach (var tab in tabs.Where(t => t.Document == document).ToList()) RemoveTab(tab);
    }

    // MARK: Selection and tabs

    public void SetSelection(ItemRef? item)
    {
        if (Selection == item) return;
        Selection = item;
        SelectionChanged?.Invoke();
    }

    public void ActivateTab(NoteTab? tab)
    {
        if (ActiveTab == tab) return;
        ActiveTab = tab;
        ActiveTabChanged?.Invoke();
        if (tab?.Document is { } document && Locate(document.Path) is { } item) SetSelection(item);
    }

    /// <summary>Ctrl+Tab / Ctrl+Shift+Tab.</summary>
    public void CycleTab(int delta)
    {
        if (tabs.Count == 0) return;
        var index = ActiveTab is null ? 0 : tabs.IndexOf(ActiveTab);
        ActivateTab(tabs[((index + delta) % tabs.Count + tabs.Count) % tabs.Count]);
    }

    /// <summary>Ctrl+T: an empty tab after the active one.</summary>
    public NoteTab NewTab()
    {
        var tab = new NoteTab();
        tabs.Insert(ActiveTab is null ? tabs.Count : tabs.IndexOf(ActiveTab) + 1, tab);
        TabsChanged?.Invoke();
        ActivateTab(tab);
        return tab;
    }

    /// <summary>Closes `tab` after saving it; when that fails, `confirm` decides (it may retry, discard or cancel).</summary>
    public async Task<bool> CloseTabAsync(NoteTab tab, Func<NoteDocument, Task<bool>> confirm)
    {
        if (tab.Document is { } document && !await SettleAsync(document, confirm)) return false;
        RemoveTab(tab);
        return true;
    }

    /// <summary>
    /// Saves `document` until it has no unsaved edits (typing may continue while a save runs). When a save fails,
    /// `confirm` asks the user: it retries, discards (reverts) or cancels (false).
    /// </summary>
    private static async Task<bool> SettleAsync(NoteDocument document, Func<NoteDocument, Task<bool>> confirm)
    {
        while (true)
        {
            if (!await document.FlushAsync() && !await confirm(document)) return false;
            if (!document.HasUnsavedChanges) return true;
            // Typing during a save: go round again, but never spin without yielding to the dispatcher.
            await Task.Yield();
        }
    }

    /// <summary>Saves every tab before the window closes; false when the user cancelled.</summary>
    public async Task<bool> PrepareToCloseAsync(Func<NoteDocument, Task<bool>> confirm)
    {
        foreach (var document in OpenDocuments.ToList())
        {
            if (!await SettleAsync(document, confirm)) return false;
        }
        return true;
    }

    private void RemoveTab(NoteTab tab)
    {
        var index = tabs.IndexOf(tab);
        if (index < 0) return;
        tabs.RemoveAt(index);
        if (tab.Document is { } document) Close(document);
        tab.Document = null;
        TabsChanged?.Invoke();
        if (ActiveTab == tab) ActivateTab(tabs.Count == 0 ? null : tabs[Math.Min(index, tabs.Count - 1)]);
    }

    private void Close(NoteDocument document)
    {
        document.AutoRename = null;
        document.Relocated = null;
        document.Release();
    }

    /// <summary>The tab showing the file at `fullPath`, compared as the file system resolves it.</summary>
    private async Task<NoteTab?> FindTabAsync(string fullPath)
    {
        var open = tabs.Where(t => t.Document is not null).Select(t => (Tab: t, t.Document!.Path)).ToList();
        if (open.Count == 0) return null;
        var match = await Task.Run(() =>
        {
            var key = Paths.Canonical(fullPath);
            return open.FirstOrDefault(o => Paths.Same(Paths.Canonical(o.Path), key)).Tab;
        });
        return match is not null && tabs.Contains(match) ? match : null;
    }

    public Task OpenItemAsync(ItemRef item, bool newTab, bool focus = false)
    {
        if (item.IsRoot || !NoteStore.IsListed(item.Path))
        {
            SetSelection(item);
            return Task.CompletedTask;
        }
        return OpenFileAsync(item.FullPath, newTab, focus, item);
    }

    /// <summary>
    /// Shows the file at `fullPath`: focuses its tab if it has one; otherwise opens it in the active tab (after saving that
    /// tab's file; if the save fails, nothing changes and its error says why) or, with `newTab`, in a new tab.
    /// </summary>
    public async Task OpenFileAsync(string fullPath, bool newTab, bool focus = false, ItemRef? item = null, bool cancellable = true)
    {
        var version = ++openVersion;
        // A later click supersedes an earlier one; files from Explorer are queued instead and always open.
        bool Current() => !cancellable || version == openVersion;
        if (item is not null) SetSelection(item);
        if (await FindTabAsync(fullPath) is { } existing)
        {
            if (Current()) ActivateTab(existing);
            return;
        }
        var target = newTab ? null : ActiveTab;
        if (target?.Document is { } current && !await current.FlushAsync())
        {
            if (Current() && Locate(current.Path) is { } open) SetSelection(open);
            return;
        }
        if (!Current()) return;
        try
        {
            if (!await Task.Run(() => File.Exists(fullPath)))
            {
                ShowError(Loc.Format("NotFound", Path.GetFileName(fullPath)));
                return;
            }
            var opened = await NoteDocument.OpenAsync(fullPath);
            if (tabs.FirstOrDefault(t => t.Document == opened) is { } raced)
            {
                opened.Release();
                ActivateTab(raced);
                return;
            }
            if (!Current() && !newTab)
            {
                opened.Release();
                return;
            }
            opened.AutoRename = AutoRenameLockedAsync;
            opened.Relocated = Follow;
            opened.RootOf = d => Locate(d.Path)?.Root.Root;
            opened.FocusOnOpen = focus;
            // Edits typed into the old file while this one loaded keep it in its tab.
            if (target is null || !tabs.Contains(target) || target.Document is { } previous && Synced(previous).HasUnsavedChanges)
            {
                target = NewTab();
            }
            else if (target.Document is { } old)
            {
                Close(old);
            }
            target.Document = opened;
            TabsChanged?.Invoke();
            ActiveTab = null;
            ActivateTab(target);
        }
        catch (Exception e)
        {
            ShowError(Loc.Format("OpenFailed", Path.GetFileName(fullPath), Paths.Describe(e)));
        }
    }

    /// <summary>
    /// Files from the command line or Explorer: each in a tab (the empty active tab, else a new one). A file inside a root
    /// is that root's item (same document as clicking it in the sidebar, named automatically, revealed in the tree); it
    /// is matched by its resolved path, so links, junctions and other spellings of the root count too.
    /// </summary>
    public Task OpenFilesAsync(IEnumerable<string> paths)
    {
        var files = paths.ToList();
        var previous = openQueue;
        return openQueue = Run();

        // One batch after another, each file to the end, in order.
        async Task Run()
        {
            try { await previous; }
            catch (Exception) { }
            WindowRequested?.Invoke();
            foreach (var path in files)
            {
                var canonical = await Task.Run(() => Paths.Canonical(path));
                var item = Locate(canonical) ?? Locate(path);
                if (item is not null && await Task.Run(() => IsHidden(item.Root, item.Path))) item = null;
                SetQuery("");
                await OpenFileAsync(item?.FullPath ?? canonical, newTab: ActiveDocument is not null, item: item, cancellable: false);
            }
        }
    }

    private Task openQueue = Task.CompletedTask;

    /// <summary>Renames an auto-named note after its first line (docs/format.md) while it stays open. Only notes inside
    /// a root are named automatically. Called from a save, with <see cref="FileGate"/> held.</summary>
    private async Task AutoRenameLockedAsync(NoteDocument document, string title)
    {
        if (Locate(document.Path) is not { } item) return;
        var (root, path) = (item.Root, item.Path);
        var folder = NoteStore.Parent(path);
        string newPath;
        try
        {
            // On failure the text is still saved; the name is retried after the next save. Hidden files are not listed
            // in the root, so they count as outside files and keep their names.
            newPath = await Moving(() => IsHidden(root, path)
                ? path
                : root.Store.Rename(path, root.Store.UniqueNoteName(title, folder, path) + ".md"));
        }
        catch (Exception)
        {
            return;
        }
        if (newPath == path) return;
        // The file moved whatever happened to the workspace meanwhile.
        document.Moved(root.Store.FullPath(newPath));
        if (!roots.Contains(root)) return;
        Moved(root, path, newPath);
        Refresh(root);
    }

    /// <summary>Selects the document's file after it switched to a conflict copy, so the sidebar matches the editor.</summary>
    private void Follow(NoteDocument document)
    {
        Refresh();
        if (ActiveDocument == document && Locate(document.Path) is { } item) SetSelection(item);
    }

    /// <summary>Rewrites the selection and paths held by open dialogs after `old` became `newPath` in `root`.</summary>
    private void Moved(RootFolder root, string old, string newPath)
    {
        if (Selection is { } selection && selection.Root == root && NoteStore.Moved(selection.Path, old, newPath) is { } moved)
        {
            SetSelection(new ItemRef(root, moved));
        }
        foreach (var item in tracked.Where(t => t.Root == root))
            if (NoteStore.Moved(item.Path, old, newPath) is { } movedPath) item.Path = movedPath;
    }

    public PathRef Track(ItemRef item)
    {
        var reference = new PathRef(item.Root, item.Path);
        tracked.Add(reference);
        return reference;
    }

    public void Untrack(PathRef reference) => tracked.Remove(reference);

    /// <summary>Saves the open files before `path` in `root` is renamed or trashed (`canceledKey` names the resource of the message) and
    /// returns `path`, following it if a save auto-renamed it. Null when a save needs the user and its file is `path` or
    /// inside it; the operation is then cancelled and that document's error says so.</summary>
    private async Task<string?> SaveDocumentsFollowingLockedAsync(RootFolder root, string path, string canceledKey)
    {
        foreach (var document in OpenDocuments.ToList())
        {
            var before = Locate(document.Path);
            var saved = await document.FlushLockedAsync();
            if (before?.Root == root && Locate(document.Path) is { } after && after.Root == root)
            {
                path = NoteStore.Moved(path, before.Path, after.Path) ?? path;
            }
            if (saved) continue;
            string target;
            try { target = path.Length == 0 ? root.Root : root.Store.FullPath(path); }
            catch (NoteStoreException) { continue; }
            if (!Paths.IsInside(document.Path, target)) continue;
            document.Error = (document.Error ?? "") + " " + Loc.Get(canceledKey);
            return null;
        }
        return path;
    }

    // MARK: Creating, renaming, trashing

    /// <summary>The folder new items go into: the selected folder or root, the selected file's folder, else the first root.</summary>
    public async Task<ItemRef?> TargetFolderAsync()
    {
        if (Selection is not { } selection) return roots.Count == 0 ? null : new ItemRef(roots[0], "");
        if (selection.IsRoot) return selection;
        // Asks the disk, not the tree, which is refreshed in the background.
        var isFolder = await Task.Run(() =>
        {
            try { return Directory.Exists(selection.FullPath); }
            catch (NoteStoreException) { return false; }
        });
        return isFolder ? selection : new ItemRef(selection.Root, NoteStore.Parent(selection.Path));
    }

    /// <summary>Creates "Untitled" (or "Untitled 2"…, "Adsız" in Turkish) right away in the active tab if it is empty, else in a new tab, and focuses
    /// the editor; the first line names it later.</summary>
    public async Task NewNoteAsync(ItemRef? folder = null)
    {
        folder ??= await TargetFolderAsync();
        if (folder is null) return;
        var (root, parent) = (folder.Root, folder.Path.Length == 0 ? null : folder.Path);
        try
        {
            var path = await FileGate.Run(() => Task.Run(() =>
                root.Store.CreateNote(root.Store.UniqueNoteName(NoteStore.UntitledName, parent), parent)));
            SetQuery("");
            Refresh(root);
            WindowRequested?.Invoke();
            var item = new ItemRef(root, path);
            await OpenFileAsync(item.FullPath, newTab: ActiveDocument is not null, focus: true, item: item);
        }
        catch (Exception e)
        {
            ShowError(Paths.Describe(e));
        }
    }

    public async Task CreateFolderAsync(string name, ItemRef parent)
    {
        try
        {
            var root = parent.Root;
            var path = await FileGate.Run(() => Task.Run(() => root.Store.CreateFolder(name, parent.IsRoot ? null : parent.Path)));
            SetQuery("");
            Refresh(root);
            SetSelection(new ItemRef(root, path));
        }
        catch (Exception e)
        {
            ShowError(Paths.Describe(e));
        }
    }

    public async Task RenameAsync(PathRef target, string name)
    {
        var root = target.Root;
        try
        {
            await FileGate.Run(async () =>
            {
                if (await SaveDocumentsFollowingLockedAsync(root, target.Path, "RenameCanceled") is not { } path) return;
                // Before the rename: afterwards the old paths no longer resolve.
                var open = OpenDocuments.Select(d => (Document: d, Item: Locate(d.Path)))
                    .Where(o => o.Item?.Root == root).ToList();
                var newPath = await Moving(() => root.Store.Rename(path, name));
                if (newPath == path) return;
                // Keep open documents (text, cursor, undo) and point them at the new location.
                foreach (var (document, item) in open)
                {
                    if (NoteStore.Moved(item!.Path, path, newPath) is not { } moved) continue;
                    var full = root.Store.FullPath(moved);
                    // Renaming the note itself is a hand-picked name; renaming its folder is not.
                    if (item.Path == path) document.RenamedByHand(full);
                    else document.Moved(full);
                }
                if (!roots.Contains(root)) return;
                Moved(root, path, newPath);
                Refresh(root);
            });
        }
        catch (Exception e)
        {
            ShowError(Paths.Describe(e));
        }
    }

    /// <summary>
    /// Moves an item to the Recycle Bin and closes the tabs of the files in it. The file gate is held throughout, even
    /// while the shell may ask "delete permanently?" (when the volume has no Recycle Bin): a queued autosave must not run
    /// between saving and trashing, or it could recreate the file. Saves only wait meanwhile; no edit is lost.
    /// Edits typed while the item was being trashed are never written back; `trashedWithEdits` shows them to the user.
    /// </summary>
    public async Task TrashAsync(PathRef target, Func<NoteDocument, Task> trashedWithEdits)
    {
        var root = target.Root;
        var closed = new List<(NoteTab Tab, NoteDocument Document)>();
        try
        {
            await FileGate.Run(async () =>
            {
                if (await SaveDocumentsFollowingLockedAsync(root, target.Path, "TrashCanceled") is not { } path) return;
                var full = root.Store.FullPath(path);
                var inside = tabs.Where(t => t.Document is { } d && Paths.IsInside(d.Path, full)).ToList();
                foreach (var tab in inside) tab.Document!.Abandon();
                var owner = OwnerWindow;
                try
                {
                    await Moving(() => { root.Store.Trash(path, owner); return path; });
                }
                catch
                {
                    foreach (var tab in inside) tab.Document?.Unabandon();
                    throw;
                }
                closed.AddRange(inside.Select(t => (t, t.Document!)));
                if (Selection is { } selection && selection.Root == root && NoteStore.Moved(selection.Path, path, path) is not null)
                {
                    SetSelection(null);
                }
                Refresh(root);
            });
        }
        catch (Exception e)
        {
            ShowError(Paths.Describe(e));
        }
        // Outside the gate: the dialog waits for the user.
        foreach (var (tab, document) in closed)
        {
            if (Synced(document).HasUnsavedChanges) await trashedWithEdits(document);
            // Only if the tab still shows the trashed file.
            if (tab.Document == document) RemoveTab(tab);
        }
    }

    /// <summary>`document` after its editors handed over unreported typing.</summary>
    private static NoteDocument Synced(NoteDocument document)
    {
        document.Sync();
        return document;
    }

    /// <summary>Runs a rename or a move to the Recycle Bin off the UI thread, counted so a shutdown save never writes to
    /// a path that is changing.</summary>
    private static async Task<string> Moving(Func<string> move)
    {
        NoteDocument.MovesInProgress++;
        try { return await Task.Run(move); }
        finally { NoteDocument.MovesInProgress--; }
    }

    /// <summary>Parent window for shell prompts (Recycle Bin).</summary>
    public IntPtr OwnerWindow { get; set; }

    public void RevealInExplorer(ItemRef item)
    {
        try
        {
            System.Diagnostics.Process.Start("explorer.exe", item.IsRoot ? $"\"{item.Root.Root}\"" : $"/select,\"{item.FullPath}\"");
        }
        catch (Exception e)
        {
            ShowError(Paths.Describe(e));
        }
    }

    // MARK: Search

    public void SetQuery(string query)
    {
        if (query == Query) return;
        Query = query;
        QueryChanged?.Invoke();
        ScheduleSearch();
    }

    /// <summary>Searches every root; results stay in root order, each root's file name matches first.</summary>
    private void ScheduleSearch()
    {
        searchCancel?.Cancel();
        if (!IsSearching || roots.Count == 0)
        {
            Hits = [];
            HitsChanged?.Invoke();
            return;
        }
        var cancel = searchCancel = new CancellationTokenSource();
        var query = Query;
        var searched = roots.ToList();
        _ = Run();

        async Task Run()
        {
            try
            {
                await Task.Delay(150, cancel.Token);
                var hits = await Task.Run(() => searched.SelectMany(r => r.Store.Search(query).Select(h => (r, h))).ToList(), cancel.Token);
                if (cancel.IsCancellationRequested) return;
                Hits = hits;
                HitsChanged?.Invoke();
            }
            catch (OperationCanceledException)
            {
            }
        }
    }
}
