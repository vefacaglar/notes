using System.Globalization;
using System.Resources;

namespace NotesCore;

/// <summary>User-visible core texts, English by default and Turkish when the UI culture is Turkish (<c>Strings.resx</c>, <c>Strings.tr.resx</c>).</summary>
internal static class Strings
{
    private static readonly ResourceManager Manager = new("NotesCore.Strings", typeof(Strings).Assembly);

    public static string Get(string key) => Manager.GetString(key, CultureInfo.CurrentUICulture) ?? key;

    public static string Format(string key, params object[] args) => string.Format(CultureInfo.CurrentUICulture, Get(key), args);
}
