using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using NotesCore;

namespace Notes.Editor;

/// <summary>Words, characters and lines of the document under the editor. Counted off the UI thread, a moment after typing
/// pauses (docs/format.md, "Status bar counts").</summary>
internal sealed class StatusBar : Grid
{
    private readonly NoteDocument document;
    private readonly TextBlock words = new(), characters = new(), lines = new();
    private readonly DispatcherQueueTimer timer = DispatcherQueue.GetForCurrentThread().CreateTimer();
    private int version;

    public StatusBar(NoteDocument document)
    {
        this.document = document;
        var secondary = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14, VerticalAlignment = VerticalAlignment.Center };
        foreach (var block in new[] { words, characters, lines })
        {
            block.FontSize = 12;
            block.Foreground = secondary;
            block.IsTextScaleFactorEnabled = false;
            row.Children.Add(block);
        }
        Children.Add(row);
        Height = 24;
        Padding = new Thickness(12, 0, 12, 0);
        BorderThickness = new Thickness(0, 1, 0, 0);
        BorderBrush = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"];
        Background = (Brush)Application.Current.Resources["LayerFillColorDefaultBrush"];

        timer.Interval = TimeSpan.FromMilliseconds(250);
        timer.IsRepeating = false;
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            Count();
        };
        document.TextChanged += OnTextChanged;
        Count();
    }

    /// <summary>Stops following the document (the tab closed or its editor went away).</summary>
    public void Detach()
    {
        document.TextChanged -= OnTextChanged;
        timer.Stop();
        version++;
    }

    private void OnTextChanged(object? origin)
    {
        // The first count is immediate; later ones wait for a pause in typing.
        timer.Stop();
        timer.Start();
    }

    private async void Count()
    {
        var mine = ++version;
        var text = document.Text;
        var statistics = await Task.Run(() => new TextStatistics(text));
        if (mine != version) return;
        words.Text = Loc.Format(statistics.Words == 1 ? "WordsOne" : "WordsMany", statistics.Words);
        characters.Text = Loc.Format(statistics.Characters == 1 ? "CharactersOne" : "CharactersMany", statistics.Characters);
        lines.Text = Loc.Format(statistics.Lines == 1 ? "LinesOne" : "LinesMany", statistics.Lines);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, $"{words.Text}, {characters.Text}, {lines.Text}");
    }
}
