using System.Globalization;
using System.Runtime.CompilerServices;

namespace NotesCore.Tests;

/// <summary>Messages follow the UI culture. Tests run in English unless they ask for another culture explicitly.</summary>
internal static class TestCulture
{
    [ModuleInitializer]
    internal static void English()
    {
        CultureInfo.DefaultThreadCurrentUICulture = new CultureInfo("en-US");
        CultureInfo.CurrentUICulture = new CultureInfo("en-US");
    }

    /// <summary>Switches the UI culture of the current test until disposed.</summary>
    public static IDisposable Use(string name)
    {
        var previous = CultureInfo.CurrentUICulture;
        CultureInfo.CurrentUICulture = new CultureInfo(name);
        return new Restore(previous);
    }

    private sealed class Restore(CultureInfo previous) : IDisposable
    {
        public void Dispose() => CultureInfo.CurrentUICulture = previous;
    }
}
