using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Notes;

public partial class App : Application
{
    private static App? current;
    private readonly LaunchOptions options;
    private DispatcherQueue? dispatcher;
    private NotesModel? model;

    public App(LaunchOptions options)
    {
        this.options = options;
        current = this;
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        dispatcher = DispatcherQueue.GetForCurrentThread();
        var model = this.model = new NotesModel();
        var window = new MainWindow(model);
        window.Activated += (_, e) =>
        {
            if (e.WindowActivationState == WindowActivationState.Deactivated)
            {
                _ = NoteDocument.FlushAllAsync();
            }
            else
            {
                model.Refresh();
                NoteDocument.ReloadAll();
            }
        };
        window.Closed += (_, _) =>
        {
            Drafts.CleanUpThrowaway();
            Exit();
        };
        window.Activate();
        _ = StartAsync(model);
    }

    private async Task StartAsync(NotesModel model)
    {
        await model.StartAsync(options.Roots.Count > 0 ? options.Roots : AppSettings.Roots);
        if (options.Files.Count > 0) await model.OpenFilesAsync(options.Files);
        await model.RestoreDraftsAsync();
        List<string> early;
        lock (Pending)
        {
            started = true;
            early = [.. Pending];
            Pending.Clear();
        }
        foreach (var commandLine in early) Open(model, commandLine);
    }

    /// <summary>Command lines redirected before the workspace was ready; opened once it is.</summary>
    private static readonly List<string> Pending = [];
    private static bool started;

    /// <summary>A second launch handed over its command line (called on a background thread): open its files as tabs.</summary>
    internal static void Redirected(AppActivationArguments args)
    {
        var commandLine = args.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch ? launch.Arguments : "";
        lock (Pending)
        {
            if (!started || current?.dispatcher is null)
            {
                Pending.Add(commandLine);
                return;
            }
        }
        var app = current;
        app.dispatcher.TryEnqueue(() =>
        {
            if (app.model is { } model) Open(model, commandLine);
        });
    }

    private static void Open(NotesModel model, string commandLine)
    {
        var files = LaunchOptions.FromCommandLine(commandLine).Files;
        _ = model.OpenFilesAsync(files);
    }
}
