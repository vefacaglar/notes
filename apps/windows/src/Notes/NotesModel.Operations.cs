using NotesCore;

namespace Notes;

/// <summary>
/// Duplicating, moving (drag and drop in the sidebar) and copying in (files dropped from Explorer). Like a rename, none of
/// them overwrites anything (a taken name gets a number) and unsaved edits are saved first; see docs/format.md, "Moving,
/// duplicating and copying in".
/// </summary>
internal sealed partial class NotesModel
{
    /// <summary>Copies and cross-volume moves running in the background; the sidebar shows "Copying…" meanwhile.</summary>
    public int ActiveOperations { get; private set; }

    public event Action? OperationsChanged;

    /// <summary>An item (or a whole folder) was moved or renamed: full paths, for state keyed by path (open folders in the sidebar).</summary>
    public event Action<string, string>? PathMoved;

    /// <summary>Full paths of items being copied or moved in the background: not touched a second time meanwhile.</summary>
    private readonly HashSet<string> busyPaths = new(StringComparer.OrdinalIgnoreCase);

    private static string Normalize(string path) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

    /// <summary>Selection, open dialogs and the pin and recent lists follow `old` in `from` to `newPath` in `to`.</summary>
    private void Relocate(RootFolder from, string old, RootFolder to, string newPath)
    {
        if (Selection is { } selection && selection.Root == from && NoteStore.Moved(selection.Path, old, newPath) is { } moved)
        {
            SetSelection(new ItemRef(to, moved));
        }
        foreach (var item in tracked.Where(t => t.Root == from).ToList())
        {
            if (NoteStore.Moved(item.Path, old, newPath) is not { } movedPath) continue;
            item.Root = to;
            item.Path = movedPath;
        }
        ItemMovedInLists(from, old, to, newPath);
        try { PathMoved?.Invoke(from.Store.FullPath(old), to.Store.FullPath(newPath)); }
        catch (NoteStoreException) { }
    }

    private void SetBusy(string fullPath, bool busy)
    {
        if (busy) busyPaths.Add(fullPath);
        else busyPaths.Remove(fullPath);
    }

    private void CountOperation(int delta)
    {
        ActiveOperations += delta;
        OperationsChanged?.Invoke();
    }

    /// <summary>The root and path of a file or folder inside a root (any kind, unlike <see cref="Locate"/>).</summary>
    private ItemRef? LocateEntry(string fullPath)
    {
        foreach (var root in roots)
        {
            var path = Paths.Relative(fullPath, root.Root) ?? Paths.Relative(fullPath, root.CanonicalRoot);
            if (path is null) continue;
            try { root.Store.FullPath(path); }
            catch (NoteStoreException) { continue; }
            return new ItemRef(root, path);
        }
        return null;
    }

    // MARK: Duplicate

    /// <summary>Context menu "Duplicate": a copy next to the file ("&lt;name&gt; copy"), with its unsaved edits saved first.
    /// Nothing is opened.</summary>
    public async Task DuplicateAsync(ItemRef item)
    {
        if (item.IsRoot || !roots.Contains(item.Root)) return;
        var root = item.Root;
        try
        {
            await FileGate.Run(async () =>
            {
                if (await SaveDocumentsFollowingLockedAsync(root, item.Path, "DuplicateCanceled") is not { } path) return;
                await Task.Run(() =>
                {
                    // Files only, like the menu.
                    if (!Directory.Exists(root.Store.FullPath(path))) root.Store.Duplicate(path);
                });
            });
            Refresh(root);
        }
        catch (Exception e)
        {
            ShowError(Paths.Describe(e));
        }
    }

    // MARK: Move

    /// <summary>
    /// Moves `item` into `folder`, possibly of another root, with the safety of a rename: unsaved edits are saved first, open
    /// documents follow the file, a taken name gets a number and nothing is overwritten. A move across volumes with nothing
    /// open inside runs in the background; otherwise the file gate is held, so no autosave races the move.
    /// </summary>
    public async Task MoveAsync(ItemRef item, ItemRef folder)
    {
        if (item.IsRoot || !roots.Contains(item.Root) || !roots.Contains(folder.Root)) return;
        var (source, target) = (item.Root, folder.Root);
        if (source == target && string.Equals(NoteStore.Parent(item.Path), folder.Path, StringComparison.Ordinal)) return;
        string sourceFull, folderFull;
        try
        {
            sourceFull = source.Store.FullPath(item.Path);
            folderFull = folder.IsRoot ? target.Root : target.Store.FullPath(folder.Path);
        }
        catch (NoteStoreException e)
        {
            ShowError(e.Message);
            return;
        }
        if (Paths.IsInside(folderFull, sourceFull))
        {
            ShowError(Loc.Format("CannotMoveIntoItself", NoteStore.DisplayName(item.Path)));
            return;
        }
        var destination = folder.IsRoot ? null : folder.Path;
        var crossVolume = !string.Equals(Path.GetPathRoot(sourceFull), Path.GetPathRoot(folderFull), StringComparison.OrdinalIgnoreCase);
        (string Path, string Full)? background = null;
        try
        {
            await FileGate.Run(async () =>
            {
                var key = Normalize(sourceFull);
                if (busyPaths.Contains(key)) return;
                if (await SaveDocumentsFollowingLockedAsync(source, item.Path, "MoveCanceled") is not { } path) return;
                // Before the move: afterwards the old paths no longer resolve.
                var open = OpenDocuments.Select(d => (Document: d, Item: Locate(d.Path)))
                    .Where(o => o.Item?.Root == source && NoteStore.Moved(o.Item.Path, path, path) is not null).ToList();
                if (open.Count == 0 && crossVolume)
                {
                    background = (path, key);
                    return;
                }
                var newPath = await Moving(() => source.Store.Move(path, destination, target.Store));
                Complete(path, newPath, open);
            });
            if (background is not { } work) return;
            SetBusy(work.Full, true);
            CountOperation(1);
            try
            {
                var newPath = await Moving(() => source.Store.Move(work.Path, destination, target.Store));
                Complete(work.Path, newPath, []);
            }
            finally
            {
                SetBusy(work.Full, false);
                CountOperation(-1);
            }
        }
        catch (Exception e)
        {
            ShowError(Paths.Describe(e));
            Refresh(source);
            if (target != source) Refresh(target);
        }

        void Complete(string path, string newPath, List<(NoteDocument Document, ItemRef? Item)> open)
        {
            foreach (var (document, documentItem) in open)
            {
                if (NoteStore.Moved(documentItem!.Path, path, newPath) is { } moved) document.Moved(target.Store.FullPath(moved));
            }
            if (!roots.Contains(source) || !roots.Contains(target)) return;
            Relocate(source, path, target, newPath);
            Refresh(source);
            if (target != source) Refresh(target);
        }
    }

    // MARK: Copy in

    /// <summary>
    /// Files and folders dropped on `folder` from Explorer (or another program): those inside one of the roots move there,
    /// anything else is copied in, in the background, with a unique name. Unsaved edits of an open copy source are saved
    /// first. Only folders and listed files are copied.
    /// </summary>
    public async Task DropAsync(IEnumerable<string> paths, ItemRef folder)
    {
        foreach (var raw in paths.ToList())
        {
            if (!roots.Contains(folder.Root)) return;
            string source;
            try { source = Normalize(raw); }
            catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { continue; }
            var inside = LocateEntry(source) ?? LocateEntry(await Task.Run(() => Paths.Canonical(source)));
            if (inside is { IsRoot: false })
            {
                await MoveAsync(inside, folder);
                continue;
            }
            var isFolder = await Task.Run(() => Directory.Exists(source));
            if (!isFolder && !NoteStore.IsListed(Path.GetFileName(source))) continue;
            if (busyPaths.Contains(source)) continue;
            // Another document may hold unsaved edits of the file (or of files in the folder): copy what the user sees.
            var failed = false;
            foreach (var document in OpenDocuments.Where(d => !d.IsDraft && Paths.IsInside(d.Path, source)).ToList())
            {
                if (await document.FlushAsync()) continue;
                ShowError(string.Join(" ", new[] { document.Error, Loc.Get("CopyCanceled") }.Where(m => !string.IsNullOrEmpty(m))));
                failed = true;
                break;
            }
            if (failed) continue;
            var (root, destination) = (folder.Root, folder.IsRoot ? null : folder.Path);
            SetBusy(source, true);
            CountOperation(1);
            try
            {
                await Task.Run(() => root.Store.CopyIn(source, destination));
            }
            catch (Exception e)
            {
                ShowError(Paths.Describe(e));
            }
            finally
            {
                SetBusy(source, false);
                CountOperation(-1);
            }
            if (roots.Contains(root)) Refresh(root);
        }
    }
}
