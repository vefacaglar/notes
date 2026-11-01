using System.Diagnostics;
using NotesCore;
using Windows.System;

namespace Notes;

/// <summary>
/// Follows a link clicked in a note (docs/format.md, "Links"): web addresses go to the system, notes (relative paths and
/// <c>[[wiki]]</c> links) open in a tab next to the current one, other files open in their default app, and programs are shown
/// in Explorer instead of being run. A target that does not exist is reported with a neutral message.
/// </summary>
internal sealed class LinkOpener(NotesModel model)
{
    /// <summary>`raw` is the destination as written (<see cref="NoteLinks.Classify"/>).</summary>
    public async Task OpenAsync(string raw, NoteDocument from)
    {
        if (NoteLinks.Classify(raw) is not { } destination) return;
        switch (destination)
        {
            case LinkDestination.Web { Url.IsFile: true } web:
                await OpenLocalAsync(web.Url.LocalPath, web.Url.LocalPath);
                break;
            case LinkDestination.Web web:
                bool opened;
                try { opened = await Launcher.LaunchUriAsync(web.Url); }
                catch (Exception) { opened = false; }
                if (!opened) model.ShowError(Loc.Format("LinkNotOpened", web.Url.AbsoluteUri));
                break;
            case LinkDestination.File file:
                await OpenFileLinkAsync(file.Path, destination, from);
                break;
            case LinkDestination.Wiki wiki:
                if (await ResolveAsync(destination, from) is { } target) await OpenLocalAsync(target, wiki.Name);
                else NoSuchNote(wiki.Name);
                break;
        }
    }

    private void NoSuchNote(string name) => model.ShowError(Loc.Format("NoSuchNote", name));

    private static string LastComponent(string path) => path[(path.LastIndexOfAny(['/', '\\']) + 1)..];

    /// <summary>The note's place among the roots, null for drafts and files outside every root.</summary>
    private static NoteRef? Origin(NoteDocument document, IReadOnlyList<RootFolder> roots)
    {
        if (document.IsDraft) return null;
        for (var i = 0; i < roots.Count; i++)
        {
            var path = Paths.Relative(document.Path, roots[i].Root) ?? Paths.Relative(document.Path, roots[i].CanonicalRoot);
            if (path is { Length: > 0 }) return new NoteRef(i, path);
        }
        return null;
    }

    /// <summary>The full path of the file a link resolves to among the files of all roots (<see cref="NoteLinks.Resolve"/> has
    /// the rules); the files are listed off the UI thread.</summary>
    private Task<string?> ResolveAsync(LinkDestination destination, NoteDocument from)
    {
        var roots = model.Roots.ToList();
        var origin = Origin(from, roots);
        return Task.Run(() =>
        {
            try
            {
                var candidates = roots.SelectMany((root, index) => root.Store.NotePaths().Select(path => new NoteRef(index, path))).ToList();
                return NoteLinks.Resolve(destination, origin, candidates) is { } found ? roots[found.Root].Store.FullPath(found.Path) : null;
            }
            catch (Exception e) when (e is NoteStoreException or IOException or UnauthorizedAccessException)
            {
                return null;
            }
        });
    }

    private async Task OpenFileLinkAsync(string path, LinkDestination destination, NoteDocument from)
    {
        var rooted = path.StartsWith('/') || path.StartsWith('\\') || Path.IsPathRooted(path);
        if (Origin(from, model.Roots) is { } origin && !rooted && NoteLinks.EscapesRoot(path, origin))
        {
            NoSuchNote(LastComponent(path));
            return;
        }
        var target = await ResolveAsync(destination, from);
        if (target is null)
        {
            // Outside the roots (or an absolute path): look on disk, relative to the note's folder.
            string? candidate = null;
            try
            {
                if (rooted) candidate = Path.GetFullPath(path);
                else if (!from.IsDraft) candidate = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(from.Path)!, path.Replace('/', Path.DirectorySeparatorChar)));
            }
            catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException)
            {
            }
            if (candidate is null || !await Task.Run(() => File.Exists(candidate)))
            {
                NoSuchNote(LastComponent(path));
                return;
            }
            target = candidate;
        }
        await OpenLocalAsync(target, path);
    }

    /// <summary>Listed files open in a tab; anything else goes to its default app, except programs: a click must never run
    /// one, so those are shown in Explorer instead.</summary>
    private async Task OpenLocalAsync(string fullPath, string shown)
    {
        if (!await Task.Run(() => File.Exists(fullPath)))
        {
            NoSuchNote(LastComponent(shown));
            return;
        }
        if (NoteStore.IsListed(Path.GetFileName(fullPath)))
        {
            await model.OpenFileAsync(fullPath, newTab: true, focus: true, item: model.Locate(fullPath));
        }
        else if (NoteLinks.IsProgram(Path.GetFileName(fullPath)))
        {
            model.RevealFileInExplorer(fullPath);
        }
        else
        {
            try
            {
                Process.Start(new ProcessStartInfo(fullPath) { UseShellExecute = true });
            }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
            {
                model.ShowError(Loc.Format("LinkNotOpened", shown));
            }
        }
    }
}
