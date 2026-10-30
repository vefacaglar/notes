using System.Text.Json.Nodes;
using NotesCore;

namespace Notes;

/// <summary>
/// App settings in <c>%APPDATA%\Notes\settings.json</c> (an unpackaged app has no LocalSettings): the workspace's root
/// folders in order, and whether the sidebar is collapsed, and the UI language. A <c>--root</c> test run reads defaults and never writes.
/// </summary>
internal static class AppSettings
{
    private const string RootsKey = "roots";
    private const string SidebarCollapsedKey = "sidebarCollapsed";
    private const string LanguageKey = "language";

    /// <summary>False for a <c>--root</c> test run.</summary>
    public static bool IsPersistent { get; set; } = true;

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
    private static void Update(string key, JsonNode? value)
    {
        if (!IsPersistent) return;
        var settings = Load();
        settings[key] = value;
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        NoteFile.Write(settings.ToJsonString() + "\n", FilePath);
    }

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

    public static void SaveRoots(IEnumerable<string> roots) =>
        Update(RootsKey, new JsonArray(roots.Select(r => (JsonNode?)JsonValue.Create(r)).ToArray()));

    public static bool SidebarCollapsed
    {
        get
        {
            try { return Load()[SidebarCollapsedKey]?.GetValue<bool>() ?? false; }
            catch (Exception e) when (e is InvalidOperationException or FormatException) { return false; }
        }
    }

    public static void SaveSidebarCollapsed(bool collapsed) => Update(SidebarCollapsedKey, collapsed);

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
}
