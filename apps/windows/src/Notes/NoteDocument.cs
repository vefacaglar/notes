using System.Text;
using Microsoft.UI.Dispatching;
using NotesCore;

namespace Notes;

/// <summary>
/// Serializes everything that writes files (saves, renames, trashing, creating) and reloads, so an autosave never
/// races a rename. Holders never wait for the user while holding it.
/// </summary>
internal static class FileGate
{
    private static readonly SemaphoreSlim Gate = new(1, 1);

    public static async Task<T> Run<T>(Func<Task<T>> action)
    {
        await Gate.WaitAsync();
        try { return await action(); }
        finally { Gate.Release(); }
    }

    public static async Task Run(Func<Task> action)
    {
        await Gate.WaitAsync();
        try { await action(); }
        finally { Gate.Release(); }
    }
}

/// <summary>
/// One open file: holds the editor text, autosaves it with a debounce and reloads external changes. There is at most one
/// document per file, shared by every window that shows it. Lives on the UI thread; file I/O runs on the thread pool.
/// </summary>
internal sealed class NoteDocument
{
    private static readonly List<NoteDocument> Open = [];

    public static IReadOnlyList<NoteDocument> All => Open;

    private sealed record Loaded(string Text, NoteFile.Stamp? Stamp, bool IsReadOnly);

    /// <summary>The open document for `path`, or a new one loaded from disk. Balance with <see cref="Release"/>.</summary>
    public static async Task<NoteDocument> OpenAsync(string path)
    {
        path = System.IO.Path.GetFullPath(path);
        var candidates = Open.Select(d => (Document: d, d.Path)).ToList();
        var (existing, loaded) = await Task.Run(() =>
        {
            var key = Paths.Canonical(path);
            foreach (var (document, other) in candidates)
                if (Paths.Same(Paths.Canonical(other), key)) return (document, (Loaded?)null);
            return ((NoteDocument?)null, Load(path));
        });
        if (existing is not null && Open.Contains(existing))
        {
            existing.users++;
            return existing;
        }
        loaded ??= await Task.Run(() => Load(path));
        // Opened by someone else while this one was reading.
        if (Open.FirstOrDefault(d => Paths.Same(d.Path, path)) is { } raced)
        {
            raced.users++;
            return raced;
        }
        var created = new NoteDocument(path, loaded);
        Open.Add(created);
        return created;
    }

    /// <summary>A draft: a note with no file in the notes folders. Its text lives in a file of the draft store, written by
    /// the usual autosave and read back when the app starts. A missing file is an empty draft.</summary>
    public static async Task<NoteDocument> OpenDraftAsync(string path)
    {
        path = System.IO.Path.GetFullPath(path);
        var candidates = Open.Select(d => (Document: d, d.Path)).ToList();
        var (existing, loaded) = await Task.Run(() =>
        {
            var key = Paths.Canonical(path);
            foreach (var (open, other) in candidates)
                if (Paths.Same(Paths.Canonical(other), key)) return (open, (Loaded?)null);
            return ((NoteDocument?)null, File.Exists(path) ? Load(path) : new Loaded("", null, false));
        });
        var document = existing is not null && Open.Contains(existing) ? existing : Open.FirstOrDefault(d => Paths.Same(d.Path, path));
        if (document is not null)
        {
            document.users++;
            return document;
        }
        // The match left Open while this ran: read the file after all.
        loaded ??= await Task.Run(() => File.Exists(path) ? Load(path) : new Loaded("", null, false));
        document = new NoteDocument(path, loaded) { IsDraft = true };
        Open.Add(document);
        return document;
    }

    /// <summary>A new empty draft in the draft store. Balance with <see cref="Release"/>.</summary>
    public static NoteDocument NewDraft(string path)
    {
        var document = new NoteDocument(path, new Loaded("", null, false)) { IsDraft = true };
        Open.Add(document);
        return document;
    }

    private static Loaded Load(string path)
    {
        var size = NoteFile.GetSize(path) ?? 0;
        if (size > NoteFile.MaxOpenSize) throw new NoteFileTooLargeException(size);
        var stamp = NoteFile.GetStamp(path);
        var text = NoteFile.Read(path);
        return new Loaded(text, stamp, size > NoteFile.ReadOnlySize);
    }

    /// <summary>Flushes every open document; false if any of them needs the user's attention (see <see cref="FlushAsync"/>).</summary>
    public static async Task<bool> FlushAllAsync()
    {
        var ok = true;
        foreach (var document in Open.ToList()) ok &= await document.FlushAsync();
        return ok;
    }

    public static void ReloadAll()
    {
        foreach (var document in Open.ToList()) _ = document.ReloadIfChangedAsync();
    }

    /// <summary>Stable across renames, unlike <see cref="Path"/>.</summary>
    public Guid Id { get; } = Guid.NewGuid();
    public string Path { get; private set; }
    public string Text { get; private set; }
    /// <summary>Large files open read-only; nothing is ever saved for them.</summary>
    public bool IsReadOnly { get; }
    /// <summary>Set for files in the notes folder only: renames an auto-named note to the given title after a save.
    /// Runs while <see cref="FileGate"/> is held.</summary>
    public Func<NoteDocument, string, Task>? AutoRename { get; set; }
    /// <summary>Called when the document switched to another file by itself (its edits went to a conflict copy).</summary>
    public Action<NoteDocument>? Relocated { get; set; }
    /// <summary>The root folder holding the file, if any: a save may recreate missing folders below it.</summary>
    public Func<NoteDocument, string?>? RootOf { get; set; }
    /// <summary>Set on a note just made with New Note so its editor takes keyboard focus.</summary>
    public bool FocusOnOpen { get; set; }
    /// <summary>Editors composing IME input; reloads and conflict resolution wait until they are done.</summary>
    public int ComposingCount { get; set; }

    /// <summary>The text changed; the argument is the editor that changed it, or null for a reload or revert.</summary>
    public event Action<object?>? TextChanged;
    public event Action? ErrorChanged;
    public event Action? PathChanged;
    /// <summary>The title or the unsaved state may have changed (tab headers).</summary>
    public event Action? StateChanged;
    /// <summary>Raised before a save or reload, so editors hand over typing they haven't reported yet.</summary>
    public event Action? SyncRequested;

    private string savedText;
    /// <summary>The file as last loaded or saved here; any other stamp means another program wrote it.</summary>
    private NoteFile.Stamp? savedStamp;
    /// <summary>Whether the name follows the first line; decided on load, reload and rename by hand.</summary>
    private bool isAutoNamed;
    private readonly DispatcherQueueTimer saveTimer;
    private int users = 1;
    private string? error;
    /// <summary>The current error is a failed save, cleared by the next successful one.</summary>
    private bool errorIsFailedSave;
    /// <summary>The file was moved to the Recycle Bin: nothing is written to its path any more.</summary>
    private bool abandoned;
    /// <summary>The last user let go: late edits from a detaching editor must not restart the autosave.</summary>
    private bool released;

    private NoteDocument(string path, Loaded loaded)
    {
        Path = path;
        Text = loaded.Text;
        savedText = loaded.Text;
        savedStamp = loaded.Stamp;
        IsReadOnly = loaded.IsReadOnly;
        isAutoNamed = IsNote && NoteStore.IsAutoNamed(Name, loaded.Text);
        saveTimer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        saveTimer.Interval = TimeSpan.FromMilliseconds(500);
        saveTimer.IsRepeating = false;
        saveTimer.Tick += (_, _) =>
        {
            saveTimer.Stop();
            _ = FlushAsync();
        };
    }

    /// <summary>A note that was never saved into a folder (see <see cref="Drafts"/>).</summary>
    public bool IsDraft { get; private set; }
    /// <summary>The tab header's dot: unsaved edits, or a draft that has text.</summary>
    public bool ShowsUnsavedDot => IsDraft ? Text.Length > 0 : HasUnsavedChanges;

    public string FileName => System.IO.Path.GetFileName(Path);
    /// <summary>Only <c>.md</c> files are notes: automatic names. Other files keep their names.</summary>
    public bool IsNote => NoteStore.IsNote(FileName);
    public CodeLanguage Language => CodeLanguages.FromPath(FileName);
    /// <summary>File name without <c>.md</c> for notes; the full file name for other files.</summary>
    public string Name => IsDraft ? DraftTitle() : NoteStore.DisplayName(FileName);
    /// <summary>What an error message calls the file: a draft's title, not its store file name.</summary>
    private string DisplayFileName => IsDraft ? Name : FileName;

    private string? titleHead, draftTitle;

    /// <summary>The first line's title; only the start of the text is looked at, and it is recomputed only when that changes.</summary>
    private string DraftTitle()
    {
        var head = Text.Length > 2048 ? Text[..2048] : Text;
        if (!string.Equals(head, titleHead, StringComparison.Ordinal))
        {
            titleHead = head;
            draftTitle = NoteStore.Title(head) ?? NoteStore.UntitledName;
        }
        return draftTitle!;
    }
    /// <summary>Compares lengths first, so it is cheap while typing changes the length.</summary>
    public bool HasUnsavedChanges => !string.Equals(Text, savedText, StringComparison.Ordinal);
    public string Title => IsReadOnly ? Loc.Format("ReadOnlyTitle", Name) : Name;

    /// <summary>A failed save or a resolved conflict, shown in the windows that show the document.</summary>
    public string? Error
    {
        get => error;
        set
        {
            errorIsFailedSave = false;
            if (error == value) return;
            error = value;
            ErrorChanged?.Invoke();
        }
    }

    public void Retain() => users++;

    /// <summary>Drops one user; the last one closes the document. Callers save first (or the user chose to discard):
    /// nothing is written here.</summary>
    public void Release()
    {
        if (--users > 0) return;
        released = true;
        saveTimer.Stop();
        Open.Remove(this);
    }

    /// <summary>The file went to the Recycle Bin; its edits can only be copied or discarded.</summary>
    public bool IsAbandoned => abandoned;

    /// <summary>The dialog about edits lost to the Recycle Bin, while it is open (it ends by discarding them).</summary>
    public Task? TrashDialog { get; set; }

    /// <summary>After the file went to the Recycle Bin: no later save may recreate it.</summary>
    public void Abandon()
    {
        abandoned = true;
        saveTimer.Stop();
    }

    /// <summary>Undoes <see cref="Abandon"/> when moving the file to the Recycle Bin failed.</summary>
    public void Unabandon()
    {
        abandoned = false;
        if (HasUnsavedChanges && !IsReadOnly && !released) saveTimer.Start();
    }

    /// <summary>An edit from an editor (`origin`), autosaved after a pause.</summary>
    public void SetText(string text, object? origin)
    {
        if (string.Equals(text, Text, StringComparison.Ordinal)) return;
        Text = text;
        TextChanged?.Invoke(origin);
        StateChanged?.Invoke();
        saveTimer.Stop();
        if (HasUnsavedChanges && !IsReadOnly && !abandoned && !released) saveTimer.Start();
    }

    public Task<bool> FlushAsync() => FileGate.Run(FlushLockedAsync);

    private abstract record SaveOutcome;
    private sealed record Saved(NoteFile.Stamp? Stamp) : SaveOutcome;
    private sealed record Failed(string Message) : SaveOutcome;
    private sealed record Conflict(string Disk, NoteFile.Stamp Stamp, string Copy) : SaveOutcome;
    private sealed record MovedToCopy(string Copy, NoteFile.Stamp? Stamp) : SaveOutcome;
    /// <summary>A draft's store file changed under it: its text went to a new draft file.</summary>
    private sealed record DraftMoved(string Path, NoteFile.Stamp? Stamp) : SaveOutcome;
    private sealed record CopyFailed(string Message, bool Unreadable) : SaveOutcome;

    /// <summary>
    /// Writes pending edits now (the caller holds <see cref="FileGate"/>). Returns false, with <see cref="Error"/> set,
    /// when the user must be told something: the save failed (the edits stay in memory and the next autosave retries);
    /// the file changed on disk meanwhile (the edits went to a conflict copy and the document shows the disk version);
    /// or it changed and can't be read (the edits went to a conflict copy, which the document now edits). Never
    /// overwrites another program's content.
    /// </summary>
    internal async Task<bool> FlushLockedAsync()
    {
        saveTimer.Stop();
        SyncRequested?.Invoke();
        if (abandoned && HasUnsavedChanges)
        {
            // Never written back (it would recreate the trashed file); the caller must ask the user, who may discard.
            Error = Loc.Format("AbandonedUnsaved", Name);
            return false;
        }
        if (abandoned || !HasUnsavedChanges || IsReadOnly) return true;
        var snapshot = Text;
        var path = Path;
        var recordedText = savedText;
        var recordedStamp = savedStamp;
        var root = RootOf?.Invoke(this);
        var generation = saveGeneration;
        var isDraft = IsDraft;
        var task = Task.Run(() => Save(path, snapshot, recordedText, recordedStamp, root, isDraft));
        inflight = (task, snapshot);
        var outcome = await task;
        if (inflight?.Task == task) inflight = null;
        // A shutdown save (SaveNow) ran meanwhile and took over this result.
        if (generation != saveGeneration) return !HasUnsavedChanges;
        if (outcome is Conflict conflict)
        {
            // The disk version replaces the editor's text: not in the middle of IME input (waiting a few seconds at
            // most, since the file gate is held), and only once everything typed meanwhile is in the copy too. If that
            // fails, the local text stays.
            for (var waited = 0; ComposingCount > 0 && waited < 5000; waited += 100) await Task.Delay(100);
            var written = snapshot;
            while (true)
            {
                // A shutdown save ran meanwhile and has its own copy: do not overwrite this one with older state.
                if (generation != saveGeneration) break;
                SyncRequested?.Invoke();
                if (string.Equals(Text, written, StringComparison.Ordinal)) break;
                written = Text;
                var latest = written;
                try
                {
                    await Task.Run(() => NoteFile.Write(latest, conflict.Copy));
                }
                catch (Exception e)
                {
                    outcome = new CopyFailed(Paths.Describe(e), Unreadable: false);
                    break;
                }
            }
        }
        if (generation != saveGeneration) return !HasUnsavedChanges;
        if (!Apply(outcome, snapshot, IsDraft ? Name : System.IO.Path.GetFileName(path))) return false;
        if (isAutoNamed && AutoRename is { } rename && NoteStore.AutoName(Name, snapshot) is { } title)
        {
            await rename(this, title);
        }
        return true;
    }

    /// <summary>Saves synchronously on the UI thread, for logoff and shutdown only, when nothing may wait for the
    /// dispatcher. No automatic rename. False when the user must be told something (see <see cref="FlushLockedAsync"/>).</summary>
    /// <remarks>
    /// An autosave whose write is still running would land after this one with older text, so it is waited for first
    /// (it never needs the UI thread) and its result adopted; <see cref="saveGeneration"/> then tells it not to apply
    /// anything. While a rename or move to the Recycle Bin runs, the path may be stale: shutdown is blocked instead.
    /// True only when nothing unsaved is left.
    /// </remarks>
    public bool SaveNow()
    {
        saveTimer.Stop();
        Sync();
        if (inflight is var (task, snapshotInFlight))
        {
            inflight = null;
            saveGeneration++;
            try
            {
                if (task.Result is Saved or DraftMoved or MovedToCopy) Apply(task.Result, snapshotInFlight, DisplayFileName);
            }
            catch (AggregateException)
            {
            }
        }
        if (IsReadOnly || !HasUnsavedChanges) return true;
        // Trashed files are never written back; their edits block the shutdown.
        if (abandoned || MovesInProgress > 0) return false;
        saveGeneration++;
        var snapshot = Text;
        Apply(Save(Path, snapshot, savedText, savedStamp, RootOf?.Invoke(this), IsDraft), snapshot, DisplayFileName);
        // A conflict copy or a move to it keeps the text safe; only edits that are still unsaved block the shutdown.
        return !HasUnsavedChanges;
    }

    /// <summary>Hands over typing the editors haven't reported yet.</summary>
    public void Sync() => SyncRequested?.Invoke();

    /// <summary>Renames and moves to the Recycle Bin in progress (the model counts them); a shutdown save must not
    /// write to a path that is about to change.</summary>
    public static int MovesInProgress { get; set; }

    /// <summary>The autosave whose write is running on the thread pool, with the text it writes.</summary>
    private (Task<SaveOutcome> Task, string Snapshot)? inflight;
    /// <summary>Bumped by <see cref="SaveNow"/>, so an autosave that was running meanwhile applies nothing.</summary>
    private int saveGeneration;

    public static bool SaveAllNow()
    {
        var ok = true;
        foreach (var document in Open.ToList()) ok &= document.SaveNow();
        return ok;
    }

    private bool Apply(SaveOutcome outcome, string snapshot, string fileName)
    {
        var changed = Loc.Format("ChangedElsewhere", fileName);
        var unreadable = Loc.Format("ChangedUnreadable", fileName);
        switch (outcome)
        {
            case Saved saved:
                savedText = snapshot;
                // The file ID changes with every replace, so the stamp is read again after the write.
                savedStamp = saved.Stamp;
                if (errorIsFailedSave) Error = null;
                StateChanged?.Invoke();
                return true;
            case Failed failed:
                Error = Loc.Format("SaveFailed", fileName, failed.Message);
                // The edits stay; the next edit's autosave (or Ctrl+S) tries again.
                errorIsFailedSave = true;
                return false;
            case CopyFailed failed:
                Error = $"{(failed.Unreadable ? unreadable : changed)} {Loc.Format("CopyAlsoFailed", failed.Message)}";
                return false;
            case Conflict conflict:
                Replace(conflict.Disk, conflict.Stamp);
                Error = $"{changed} {Loc.Format("DiskVersionOpened", System.IO.Path.GetFileName(conflict.Copy))}";
                return false;
            case DraftMoved draftMoved:
                if (errorIsFailedSave) Error = null;
                Path = draftMoved.Path;
                savedText = snapshot;
                savedStamp = draftMoved.Stamp;
                PathChanged?.Invoke();
                StateChanged?.Invoke();
                Relocated?.Invoke(this);
                return true;
            case MovedToCopy moved:
                Path = moved.Copy;
                savedText = snapshot;
                savedStamp = moved.Stamp;
                isAutoNamed = false;
                PathChanged?.Invoke();
                StateChanged?.Invoke();
                Error = $"{unreadable} {Loc.Format("MovedToCopy", System.IO.Path.GetFileName(moved.Copy))}";
                Relocated?.Invoke(this);
                return false;
            default:
                return false;
        }
    }

    /// <summary>The disk content can't be shown: not UTF-8, no permission, or too large. Other read errors are
    /// transient (a sharing violation while another program saves) and only fail this save.</summary>
    private static bool IsUnreadable(Exception e) =>
        e is DecoderFallbackException or UnauthorizedAccessException or NoteFileTooLargeException;

    private static SaveOutcome Save(string path, string snapshot, string recordedText, NoteFile.Stamp? recordedStamp, string? root, bool draft = false)
    {
        if (draft)
        {
            // The store belongs to one process; a changed file means another one wrote it, so this text gets its own draft.
            try
            {
                if (NoteFile.GetStamp(path) is { } current && current != recordedStamp)
                {
                    var other = Drafts.NewPath();
                    NoteFile.Write(snapshot, other);
                    return new DraftMoved(other, NoteFile.GetStamp(other));
                }
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
            }
            catch (Exception e)
            {
                return new Failed(Paths.Describe(e));
            }
        }
        if (!draft && NoteFile.GetStamp(path) is { } stamp && stamp != recordedStamp)
        {
            // Changed on disk since it was loaded or saved here; only a touch without a content change may be overwritten.
            string disk;
            try
            {
                if (stamp.Size > NoteFile.MaxOpenSize) throw new NoteFileTooLargeException(stamp.Size ?? 0);
                try
                {
                    disk = NoteFile.Read(path);
                }
                catch (UnauthorizedAccessException)
                {
                    // A file another program is replacing can be delete-pending for a moment: try once more.
                    Thread.Sleep(100);
                    disk = NoteFile.Read(path);
                }
            }
            catch (Exception e) when (IsUnreadable(e))
            {
                var (moved, failure) = WriteConflictCopy(path, snapshot);
                return moved is not null
                    ? new MovedToCopy(moved, NoteFile.GetStamp(moved))
                    : new CopyFailed(failure ?? "", Unreadable: true);
            }
            catch (Exception e)
            {
                return new Failed(Paths.Describe(e));
            }
            if (string.Equals(disk, snapshot, StringComparison.Ordinal)) return new Saved(stamp);
            if (!string.Equals(disk, recordedText, StringComparison.Ordinal))
            {
                var (copy, error) = WriteConflictCopy(path, snapshot);
                return copy is not null ? new Conflict(disk, stamp, copy) : new CopyFailed(error ?? "", Unreadable: false);
            }
        }
        try
        {
            try
            {
                NoteFile.Write(snapshot, path);
            }
            catch (DirectoryNotFoundException) when (root is not null && Directory.Exists(root) && Paths.IsInside(path, root))
            {
                // Its folder was removed while the file was open; the root is still there, so the save recreates it.
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path))!);
                NoteFile.Write(snapshot, path);
            }
        }
        catch (Exception e)
        {
            return new Failed(Paths.Describe(e));
        }
        var written = NoteFile.GetStamp(path);
        if (draft || written?.Size == Encoding.UTF8.GetByteCount(snapshot)) return new Saved(written);
        // Another program wrote the file right after this save: an outside change like any other.
        try
        {
            var disk = NoteFile.Read(path);
            if (string.Equals(disk, snapshot, StringComparison.Ordinal)) return new Saved(written);
            var (copy, error) = WriteConflictCopy(path, snapshot);
            return copy is not null && written is { } current
                ? new Conflict(disk, current, copy)
                : new CopyFailed(error ?? "", Unreadable: false);
        }
        catch (Exception)
        {
            // Unknown state: the next save or reload sees a different stamp and compares again.
            return new Saved(null);
        }
    }

    /// <summary>Writes `text` to a new "&lt;name&gt; (conflict)" file next to `path`, never over an existing file.</summary>
    private static (string? Copy, string? Error) WriteConflictCopy(string path, string text)
    {
        try
        {
            var copy = NoteStore.ConflictCopyPath(path);
            using var stream = new FileStream(copy, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            stream.Write(new UTF8Encoding(false).GetBytes(text));
            stream.Flush(flushToDisk: true);
            return (copy, null);
        }
        catch (Exception e)
        {
            return (null, Paths.Describe(e));
        }
    }

    /// <summary>A draft whose text was just written to `path` (a file in a notes folder): from now on it is that file's note.</summary>
    public void BecomeFile(string path, string writtenText, NoteFile.Stamp? stamp)
    {
        if (!IsDraft) return;
        var draftPath = Path;
        IsDraft = false;
        Error = null;
        Path = path;
        savedText = writtenText;
        savedStamp = stamp;
        isAutoNamed = IsNote && NoteStore.IsAutoNamed(Name, writtenText);
        if (Paths.IsInside(draftPath, Drafts.Folder)) Drafts.TryDelete(draftPath);
        PathChanged?.Invoke();
        StateChanged?.Invoke();
        if (HasUnsavedChanges && !IsReadOnly && !released) saveTimer.Start();
    }

    /// <summary>Points the document at its file's new location after a rename, keeping the text and edit state.
    /// A rename keeps the file's stamp, so an external change made before it is still detected.</summary>
    public void Moved(string path)
    {
        Path = path;
        PathChanged?.Invoke();
        StateChanged?.Invoke();
    }

    /// <summary>After the user renamed the file: decides again whether the name follows the first line.</summary>
    public void RenamedByHand(string path)
    {
        Path = path;
        isAutoNamed = IsNote && NoteStore.IsAutoNamed(Name, Text);
        PathChanged?.Invoke();
        StateChanged?.Invoke();
    }

    /// <summary>Throws away unsaved edits, e.g. when the user closes a tab whose save failed.</summary>
    public void Revert()
    {
        saveTimer.Stop();
        if (errorIsFailedSave) Error = null;
        if (string.Equals(Text, savedText, StringComparison.Ordinal)) return;
        Text = savedText;
        TextChanged?.Invoke(null);
        StateChanged?.Invoke();
    }

    /// <summary>Reloads the file if it changed on disk and there are no local edits (with local edits the next save
    /// detects the change and keeps a conflict copy). Waits while an input method is composing text.</summary>
    public Task ReloadIfChangedAsync() => FileGate.Run(async () =>
    {
        SyncRequested?.Invoke();
        if (abandoned || HasUnsavedChanges || ComposingCount > 0) return;
        var path = Path;
        var recorded = savedStamp;
        NoteFileTooLargeException? tooLarge = null;
        NoteFile.Stamp? seen = null;
        var result = await Task.Run(() =>
        {
            if (NoteFile.GetStamp(path) is not { } stamp || stamp == recorded) return null;
            seen = stamp;
            try { return (Stamp: stamp, Text: NoteFile.Read(path)) as (NoteFile.Stamp Stamp, string Text)?; }
            catch (NoteFileTooLargeException e) { tooLarge = e; return null; }
            catch (Exception) { return null; }
        });
        SyncRequested?.Invoke();
        if (tooLarge is not null && !HasUnsavedChanges && Path == path)
        {
            // The tab keeps the old text; the next save sees the changed file and keeps a conflict copy.
            // Reported once per version of the file, not on every activation.
            if (seen != tooLargeReported)
            {
                tooLargeReported = seen;
                Error = tooLarge.Message;
            }
            return;
        }
        if (result is not { } disk || HasUnsavedChanges || ComposingCount > 0 || Path != path) return;
        if (string.Equals(disk.Text, savedText, StringComparison.Ordinal)) savedStamp = disk.Stamp;
        else Replace(disk.Text, disk.Stamp);
    });

    private NoteFile.Stamp? tooLargeReported;

    private void Replace(string content, NoteFile.Stamp stamp)
    {
        saveTimer.Stop();
        savedText = content;
        savedStamp = stamp;
        isAutoNamed = IsNote && NoteStore.IsAutoNamed(Name, content);
        Text = content;
        // Editors reload and drop their undo history, which refers to the old text.
        TextChanged?.Invoke(null);
        StateChanged?.Invoke();
    }
}
