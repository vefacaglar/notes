using System.Text.Json;
using System.Text.Json.Serialization;
using NotesCore;

namespace Notes;

/// <summary>A tab's selection (UTF-16 offsets) and scroll position.</summary>
internal sealed record EditorViewState(int Location, int Length, double ScrollX, double ScrollY);

/// <summary>
/// The open tabs and window, saved to <c>session.json</c> in the support folder so they come back after a relaunch
/// (docs/format.md, "App state"). Same shape as the macOS file; paths only, never note contents. The Windows app has one
/// window, so <c>windows</c> holds one main entry.
/// </summary>
internal sealed class SessionFile
{
    public int Version { get; set; } = 1;
    public List<SessionWindow> Windows { get; set; } = [];
}

internal sealed class SessionWindow
{
    public bool IsMain { get; set; } = true;
    public List<SessionTab> Tabs { get; set; } = [];
    public int? ActiveTab { get; set; }
    public bool SidebarVisible { get; set; } = true;
    /// <summary>Sidebar folders (absolute paths): collapsed roots and expanded subfolders.</summary>
    public List<string>? CollapsedRoots { get; set; }
    public List<string>? ExpandedFolders { get; set; }
    /// <summary>Windows only: where the window was.</summary>
    public SessionBounds? Bounds { get; set; }
}

internal sealed class SessionTab
{
    /// <summary>Absolute path of the file, or null for a draft.</summary>
    public string? File { get; set; }
    /// <summary>The draft's file name in the draft store, or null for a file.</summary>
    public string? Draft { get; set; }
    public bool ShowsSource { get; set; }
    public SessionView? View { get; set; }
    /// <summary>Reading mode; absent means write mode.</summary>
    public bool? Reading { get; set; }
}

internal sealed class SessionView
{
    public int Location { get; set; }
    public int Length { get; set; }
    public double ScrollX { get; set; }
    public double ScrollY { get; set; }

    public static SessionView? From(EditorViewState? state) =>
        state is null ? null : new SessionView { Location = state.Location, Length = state.Length, ScrollX = state.ScrollX, ScrollY = state.ScrollY };

    public EditorViewState ToState() => new(Location, Length, ScrollX, ScrollY);
}

/// <summary>The window's restored bounds in physical pixels, and whether it was maximized.</summary>
internal sealed class SessionBounds
{
    public int X { get; set; }
    public int Y { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
    public bool Maximized { get; set; }

    public SessionBounds Copy() => (SessionBounds)MemberwiseClone();
}

/// <summary>Reads and writes <c>session.json</c>. Without a support folder (a test run) nothing is read or written.</summary>
internal static class SessionStore
{
    /// <summary>The app's own folder for the session file: <c>%LOCALAPPDATA%\Notes</c>, <c>--support</c> for a test run,
    /// none for a test run without it.</summary>
    public static string? Folder { get; set; }

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true,
    };

    private static string? FilePath => Folder is null ? null : Path.Combine(Folder, "session.json");

    /// <summary>A second process (pending drafts) must not overwrite the session of the one that owns the app state.</summary>
    public static bool CanWrite => Folder is not null && !Drafts.IsFallback;

    /// <summary>The main window of the last session, or null when there is none or it can't be read.</summary>
    public static SessionWindow? ReadMain()
    {
        if (!CanWrite || FilePath is not { } path) return null;
        try
        {
            var file = JsonSerializer.Deserialize<SessionFile>(File.ReadAllText(path), Options);
            return file?.Windows.FirstOrDefault(w => w.IsMain);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    /// <summary>Writes the session atomically; failures are ignored (the session is a convenience, never user data).</summary>
    public static void Write(SessionWindow main)
    {
        if (!CanWrite || FilePath is not { } path) return;
        try
        {
            Directory.CreateDirectory(Folder!);
            NoteFile.Write(JsonSerializer.Serialize(new SessionFile { Windows = [main] }, Options) + "\n", path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or NoteFileNotWritableException)
        {
        }
    }
}
