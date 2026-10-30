using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Notes;

/// <summary>Single instance per notes folder: a second launch (e.g. a file double-clicked in Explorer) hands its
/// arguments to the running app and exits.</summary>
public static partial class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();
        var options = LaunchOptions.Parse(args);
        // `--root` is for this run only: the settings are neither read nor written.
        AppSettings.IsPersistent = options.Roots.Count == 0 && options.Drafts is null;
        var instance = AppInstance.FindOrRegisterForKey(options.InstanceKey);
        if (!instance.IsCurrent)
        {
            AllowSetForegroundWindow(instance.ProcessId);
            Task.Run(async () => await instance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs())).Wait();
            return 0;
        }
        AppSettings.ThemeOverride = options.Theme;
        Notes.Drafts.Override = options.Drafts;
        Notes.Drafts.Acquire();
        Loc.Initialize(options.Language ?? AppSettings.Language);
        instance.Activated += (_, e) => App.Redirected(e);
        Application.Start(callback =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App(options);
        });
        return 0;
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AllowSetForegroundWindow(uint processId);
}

/// <summary>
/// Command line: file paths to open, plus <c>--root &lt;path&gt;</c> (repeatable) to use other root folders for this run
/// only; such a run never writes the settings. <c>--lang en|tr</c> overrides the UI language for this run.
/// </summary>
public sealed record LaunchOptions(IReadOnlyList<string> Roots, IReadOnlyList<string> Files, string? Language = null, ElementTheme? Theme = null, string? Drafts = null)
{
    public static LaunchOptions Parse(IEnumerable<string> args)
    {
        var roots = new List<string>();
        var files = new List<string>();
        string? language = null;
        ElementTheme? theme = null;
        string? drafts = null;
        using var e = args.GetEnumerator();
        while (e.MoveNext())
        {
            if (e.Current == "--root")
            {
                if (e.MoveNext() && e.Current.Length > 0) roots.Add(Path.GetFullPath(e.Current));
            }
            else if (e.Current == "--lang")
            {
                if (e.MoveNext() && e.Current is "en" or "tr" or "system") language = e.Current;
            }
            else if (e.Current == "--drafts")
            {
                if (e.MoveNext() && e.Current.Length > 0) drafts = Path.GetFullPath(e.Current);
            }
            else if (e.Current == "--theme")
            {
                if (e.MoveNext()) theme = e.Current switch { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => null };
            }
            else if (e.Current.Length > 0)
            {
                files.Add(Path.GetFullPath(e.Current));
            }
        }
        return new LaunchOptions(roots, files, language, theme, drafts);
    }

    /// <summary>Launches share one window only with the same roots, so a test run never reaches the real workspace.</summary>
    public string InstanceKey => Roots.Count == 0 && Drafts is null
        ? "main"
        : "main-" + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(
            System.Text.Encoding.UTF8.GetBytes(string.Join('|', Roots).ToUpperInvariant() + "||" + Drafts?.ToUpperInvariant())))[..16];

    /// <summary>Splits a command line as Windows does; a leading path to this executable is dropped.</summary>
    public static LaunchOptions FromCommandLine(string commandLine)
    {
        var args = CommandLine.Split(commandLine);
        if (args.Count > 0 && (string.Equals(args[0], Environment.ProcessPath, StringComparison.OrdinalIgnoreCase)
            || string.Equals(Path.GetFileName(args[0]), Path.GetFileName(Environment.ProcessPath), StringComparison.OrdinalIgnoreCase)))
        {
            args.RemoveAt(0);
        }
        return Parse(args);
    }
}

internal static partial class CommandLine
{
    [LibraryImport("shell32.dll", StringMarshalling = StringMarshalling.Utf16)]
    private static partial IntPtr CommandLineToArgvW(string commandLine, out int count);

    [LibraryImport("kernel32.dll")]
    private static partial IntPtr LocalFree(IntPtr memory);

    public static List<string> Split(string commandLine)
    {
        var result = new List<string>();
        if (string.IsNullOrWhiteSpace(commandLine)) return result;
        // A placeholder program name, so the real first argument gets the normal quoting rules.
        var argv = CommandLineToArgvW("x " + commandLine, out var count);
        if (argv == IntPtr.Zero) return result;
        try
        {
            for (var i = 1; i < count; i++) result.Add(Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size)) ?? "");
        }
        finally
        {
            LocalFree(argv);
        }
        return result;
    }
}
