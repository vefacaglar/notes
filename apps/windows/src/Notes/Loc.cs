using System.Globalization;
using Microsoft.Windows.ApplicationModel.Resources;
using Microsoft.Windows.Globalization;

namespace Notes;

/// <summary>
/// UI language: English or Turkish, from the settings (<c>system</c>, <c>en</c>, <c>tr</c>) or <c>--lang</c>. Set once at
/// startup, before any UI exists; a change in the menu applies after a restart. Texts live in <c>Strings\*\Resources.resw</c>
/// (XAML uses <c>x:Uid</c>, code uses <see cref="Get"/>).
/// </summary>
internal static class Loc
{
    private static ResourceMap? map;
    private static ResourceContext? context;

    /// <summary>"en" or "tr": what the UI uses.</summary>
    public static string Code { get; private set; } = "en";

    /// <summary>`setting` is "system", "en" or "tr" (anything else counts as "system").</summary>
    public static void Initialize(string setting)
    {
        Code = setting switch
        {
            "en" or "tr" => setting,
            _ => string.Equals(CultureInfo.CurrentUICulture.TwoLetterISOLanguageName, "tr", StringComparison.OrdinalIgnoreCase) ? "tr" : "en",
        };
        var tag = Code == "tr" ? "tr-TR" : "en-US";
        var culture = new CultureInfo(tag);
        CultureInfo.DefaultThreadCurrentUICulture = culture;
        CultureInfo.CurrentUICulture = culture;
        try { ApplicationLanguages.PrimaryLanguageOverride = tag; }
        catch (Exception) { /* the code lookups below do not depend on it */ }
        try
        {
            var manager = new ResourceManager();
            map = manager.MainResourceMap.GetSubtree("Resources");
            context = manager.CreateResourceContext();
            context.QualifierValues["Language"] = tag;
        }
        catch (Exception)
        {
            map = null;
        }
    }

    public static string Get(string key)
    {
        try
        {
            if (map?.TryGetValue(key, context) is { } candidate) return candidate.ValueAsString;
        }
        catch (Exception)
        {
        }
        return key;
    }

    public static string Format(string key, params object[] args) => string.Format(CultureInfo.CurrentUICulture, Get(key), args);
}
