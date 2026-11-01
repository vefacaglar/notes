using System.Text.Json.Nodes;
using NotesCore;

namespace Notes;

/// <summary>
/// App settings in <c>%APPDATA%\Notes\settings.json</c> (an unpackaged app has no LocalSettings): the workspace's root
/// folders in order, and the UI language. A <c>--root</c> test run reads defaults and never writes.
/// </summary>
internal static class AppSettings
{
    private const string RootsKey = "roots";
    private const string SidebarCollapsedKey = "sidebarCollapsed";
    private const string LanguageKey = "language";

    /// <summary>False for a <c>--root</c> test run.</summary>
    public static bool IsPersistent { get; set; } = true;

    /// <summary>The hidden <c>--theme light|dark</c> override for this run; never saved.</summary>
    public static Microsoft.UI.Xaml.ElementTheme? ThemeOverride { get; set; }

    private static string FilePath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Notes", "settings.json");

    public static string DefaultNotesFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Notes");

    private static JsonObject Load()
    {
        if (!IsPersistent) return [];
        try
        {
            return JsonNode.Parse(File.ReadAllText(FilePath)) as JsonObject ?? [];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Text.Json.JsonException)
        {
            return [];
        }
    }

    /// <summary>Changes one setting, keeping the others; writes atomically and throws on failure.</summary>
    private static void Update(string key, JsonNode? value, long? ticket = null)
    {
        if (!IsPersistent) return;
        lock (saveLock)
        {
            if (ticket is { } t && viewTickets.GetValueOrDefault(key) != t) return;
            var settings = Load();
            settings[key] = value;
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            NoteFile.Write(settings.ToJsonString() + "\n", FilePath);
        }
    }

    /// <summary>Read-modify-write of the file must not interleave (view settings are saved off the UI thread).</summary>
    private static readonly object saveLock = new();

    /// <summary>Latest save issued per view key: an older queued save is dropped so the newest value is written last.</summary>
    private static readonly Dictionary<string, long> viewTickets = [];

    /// <summary>The saved roots; the default notes folder when nothing usable is saved.</summary>
    public static IReadOnlyList<string> Roots
    {
        get
        {
            try
            {
                if (Load()[RootsKey] is JsonArray array)
                {
                    var roots = array.Select(n => n?.GetValue<string>()).OfType<string>().Where(p => p.Length > 0).ToList();
                    if (roots.Count > 0) return roots;
                }
            }
            catch (Exception e) when (e is InvalidOperationException or FormatException)
            {
            }
            return [DefaultNotesFolder];
        }
    }

    /// <summary>The very first run: no roots saved yet and no default notes folder. Only then the default folder is created
    /// and the window opens on an empty draft.</summary>
    public static bool IsFirstRun
    {
        get
        {
            if (!IsPersistent) return false;
            try { return Load()[RootsKey] is null && !Directory.Exists(DefaultNotesFolder); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
        }
    }

    public static void SaveRoots(IEnumerable<string> roots) =>
        Update(RootsKey, new JsonArray(roots.Select(r => (JsonNode?)JsonValue.Create(r)).ToArray()));

    /// <summary>Earlier versions kept the sidebar state here; it now lives in the session (used when there is none yet).</summary>
    public static bool SidebarCollapsed
    {
        get
        {
            try { return Load()[SidebarCollapsedKey]?.GetValue<bool>() ?? false; }
            catch (Exception e) when (e is InvalidOperationException or FormatException) { return false; }
        }
    }

    /// <summary>"system" (default: Turkish when Windows is Turkish, else English), "en" or "tr".</summary>
    public static string Language
    {
        get
        {
            try { return Load()[LanguageKey]?.GetValue<string>() is ("en" or "tr") and var language ? language : "system"; }
            catch (Exception e) when (e is InvalidOperationException or FormatException) { return "system"; }
        }
    }

    public static void SaveLanguage(string language) => Update(LanguageKey, language);

    // MARK: Editor and view settings

    /// <summary>Raised on the UI thread when one of the editor or view settings below changed (the argument is its key).</summary>
    public static event Action<string>? EditorSettingChanged;

    public const double ZoomMin = 0.5, ZoomMax = 3.0, ZoomStep = 0.1;
    public const double LineSpacingMin = 1.0, LineSpacingMax = 2.0;

    private static bool viewLoaded;
    private static double zoom = 1, lineSpacing = 1.2;
    private static bool showStatusBar = true, showFormattingBar = true, focusMode, spellCheck, highlightCurrentLine, limitLineWidth, codeWrap = true;

    /// <summary>Reads the saved values once; a missing or bad value keeps its own default. A test run starts from the defaults
    /// and keeps changes in memory only.</summary>
    private static void EnsureViewLoaded()
    {
        if (viewLoaded) return;
        viewLoaded = true;
        var settings = Load();
        double? Number(string key)
        {
            try { return settings[key]?.GetValue<double>() is { } v && double.IsFinite(v) ? v : null; }
            catch (Exception e) when (e is InvalidOperationException or FormatException) { return null; }
        }
        bool Flag(string key, bool fallback)
        {
            try { return settings[key]?.GetValue<bool>() ?? fallback; }
            catch (Exception e) when (e is InvalidOperationException or FormatException) { return fallback; }
        }
        if (Number("zoom") is { } z) zoom = ClampZoom(z);
        if (Number("lineSpacing") is { } l) lineSpacing = Math.Clamp(l, LineSpacingMin, LineSpacingMax);
        showStatusBar = Flag("showStatusBar", true);
        showFormattingBar = Flag("showFormattingBar", true);
        focusMode = Flag("focusMode", false);
        spellCheck = Flag("spellCheck", false);
        highlightCurrentLine = Flag("highlightCurrentLine", false);
        limitLineWidth = Flag("limitLineWidth", false);
        codeWrap = Flag("codeWrap", true);
    }

    /// <summary>Clamped to the range and rounded to a step, so repeated steps never drift (0.7000000001).</summary>
    public static double ClampZoom(double value) => Math.Round(Math.Clamp(value, ZoomMin, ZoomMax) / ZoomStep) * ZoomStep;

    private static void SaveView(string key, JsonNode value)
    {
        EditorSettingChanged?.Invoke(key);
        if (!IsPersistent) return;
        // A view preference is never worth an error message: if it can't be written it stays in effect until the app closes.
        long ticket;
        lock (saveLock) ticket = viewTickets[key] = viewTickets.GetValueOrDefault(key) + 1;
        _ = Task.Run(() =>
        {
            try { Update(key, value, ticket); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        });
    }

    private static void SetFlag(ref bool field, bool value, string key)
    {
        if (field == value) return;
        field = value;
        SaveView(key, value);
    }

    /// <summary>View &gt; Zoom: the editors' font scale, 50% to 300% in steps of 10% (default 100%).</summary>
    public static double Zoom
    {
        get { EnsureViewLoaded(); return zoom; }
        set
        {
            EnsureViewLoaded();
            value = ClampZoom(value);
            if (value == zoom) return;
            zoom = value;
            SaveView("zoom", value);
        }
    }

    public static bool ShowStatusBar { get { EnsureViewLoaded(); return showStatusBar; } set { EnsureViewLoaded(); SetFlag(ref showStatusBar, value, "showStatusBar"); } }

    public static bool ShowFormattingBar { get { EnsureViewLoaded(); return showFormattingBar; } set { EnsureViewLoaded(); SetFlag(ref showFormattingBar, value, "showFormattingBar"); } }

    /// <summary>Markdown editor: dims every paragraph but the ones with the selection and keeps the caret line centred.</summary>
    public static bool FocusMode { get { EnsureViewLoaded(); return focusMode; } set { EnsureViewLoaded(); SetFlag(ref focusMode, value, "focusMode"); } }

    public static bool SpellCheck { get { EnsureViewLoaded(); return spellCheck; } set { EnsureViewLoaded(); SetFlag(ref spellCheck, value, "spellCheck"); } }

    /// <summary>A neutral band behind the caret's line in both editors.</summary>
    public static bool HighlightCurrentLine { get { EnsureViewLoaded(); return highlightCurrentLine; } set { EnsureViewLoaded(); SetFlag(ref highlightCurrentLine, value, "highlightCurrentLine"); } }

    /// <summary>Markdown editor: the text column is at most 720 px wide and centred; off, it fills the window.</summary>
    public static bool LimitLineWidth { get { EnsureViewLoaded(); return limitLineWidth; } set { EnsureViewLoaded(); SetFlag(ref limitLineWidth, value, "limitLineWidth"); } }

    /// <summary>Code editor: long lines wrap; off, the editor scrolls sideways.</summary>
    public static bool CodeWrap { get { EnsureViewLoaded(); return codeWrap; } set { EnsureViewLoaded(); SetFlag(ref codeWrap, value, "codeWrap"); } }

    /// <summary>Line height of both editors as a multiple of the font's, 1.0 to 2.0 (default 1.2).</summary>
    public static double LineSpacing
    {
        get { EnsureViewLoaded(); return lineSpacing; }
        set
        {
            EnsureViewLoaded();
            value = Math.Clamp(value, LineSpacingMin, LineSpacingMax);
            if (value == lineSpacing) return;
            lineSpacing = value;
            SaveView("lineSpacing", value);
        }
    }
}
