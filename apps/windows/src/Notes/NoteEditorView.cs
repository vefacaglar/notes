using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Notes.Editor;
using NotesCore;

namespace Notes;

/// <summary>
/// Hosts the editor for one document: the Markdown editor for Markdown files, the code editor for the rest, with the
/// read-only banner, the document's error bar, the formatting bar, the find panel and the status bar. Every message here is
/// neutral: the app has no red or yellow states.
/// </summary>
internal sealed class NoteEditorView : Grid
{
    public NoteDocument Document { get; }
    public NoteTab Tab { get; }
    private readonly TextEditor editor;
    private readonly InfoBar errorBar;
    private readonly Border readOnlyBanner;
    private readonly TextBlock readOnlyText;
    private readonly Grid toolbarHost = new() { Margin = new Thickness(0, 8, 0, 4) };
    private readonly FindBar findBar;
    private readonly FormattingBar? fullBar, outlineBar, codeBar;
    private StatusBar? statusBar;
    private Flyout? popup;

    public TextEditor Editor => editor;

    /// <summary>The outline (or the table picker) is open.</summary>
    public bool IsOutlineOpen => popup is { IsOpen: true, Content: ListView or TextBlock };

    /// <summary>A link in the text was clicked: its destination as written.</summary>
    public event Action<string>? LinkActivated;

    /// <summary>The Reading Mode button was pressed.</summary>
    public event Action? ReadingToggleRequested;

    public NoteEditorView(NoteDocument document, NoteTab tab)
    {
        Document = document;
        Tab = tab;
        for (var i = 0; i < 4; i++) RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // Why the file can't be edited: too large, or no permission to write it.
        readOnlyText = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
        };
        var banner = new Grid { ColumnSpacing = 8, Padding = new Thickness(16, 8, 16, 8) };
        banner.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        banner.ColumnDefinitions.Add(new ColumnDefinition());
        banner.Children.Add(new FontIcon
        {
            Glyph = "",
            FontSize = 14,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = readOnlyText.Foreground,
        });
        SetColumn(readOnlyText, 1);
        banner.Children.Add(readOnlyText);
        readOnlyBanner = new Border
        {
            Child = banner,
            BorderThickness = new Thickness(0, 0, 0, 1),
            BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"],
            Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardBackgroundFillColorSecondaryBrush"],
        };
        Children.Add(readOnlyBanner);

        errorBar = new InfoBar { Title = Loc.Get("Error"), Severity = InfoBarSeverity.Informational, Margin = new Thickness(12, 12, 12, 0) };
        errorBar.CloseButtonClick += (_, _) => Document.Error = null;
        SetRow(errorBar, 1);
        Children.Add(errorBar);

        // Shown when RichEdit can't hold the text unchanged (lone CR, NUL…): the editor is then read-only.
        var unfaithful = new InfoBar
        {
            Severity = InfoBarSeverity.Informational,
            IsClosable = false,
            Message = Loc.Get("UnfaithfulBar"),
            Margin = new Thickness(12, 12, 12, 0),
        };
        SetRow(unfaithful, 2);
        Children.Add(unfaithful);

        editor = document.Language == CodeLanguage.Markdown ? new MarkdownEditor(document) : new CodeEditor(document);
        editor.FaithfulnessChanged += () =>
        {
            unfaithful.IsOpen = !editor.IsFaithful;
            RefreshBars();
        };
        editor.ReadOnlyStateChanged += RefreshBars;

        findBar = new FindBar(editor, () => { });
        var area = new Grid();
        area.Children.Add(editor.Host);
        area.Children.Add(findBar);
        SetRow(area, 4);
        Children.Add(area);

        if (editor is MarkdownEditor markdown)
        {
            fullBar = FormattingBar.ForMarkdown(markdown, () => ReadingToggleRequested?.Invoke());
            outlineBar = FormattingBar.ForOutline(markdown);
            markdown.TablePickerRequested += ShowTablePicker;
            markdown.OutlineRequested += ToggleOutline;
            markdown.LinkActivated += raw => LinkActivated?.Invoke(raw);
        }
        else if (document.Language.CanFormat())
        {
            codeBar = FormattingBar.ForCode(editor, () => ReadingToggleRequested?.Invoke());
        }
        SetRow(toolbarHost, 3);
        Children.Add(toolbarHost);

        document.ErrorChanged += ShowError;
        document.ReadOnlyChanged += ShowReadOnly;
        AppSettings.EditorSettingChanged += OnSettingChanged;
        ShowError();
        ShowReadOnly();
        UpdateChrome();
        ApplyModes();
    }

    private void OnSettingChanged(string key)
    {
        if (key is "showFormattingBar" or "showStatusBar") UpdateChrome();
    }

    /// <summary>Shows the bars the settings ask for: the formatting bar (or just the outline button) and the status bar.</summary>
    private void UpdateChrome()
    {
        var bar = fullBar is not null ? (AppSettings.ShowFormattingBar ? fullBar : outlineBar) : codeBar;
        toolbarHost.Children.Clear();
        if (bar is not null) toolbarHost.Children.Add(bar);
        toolbarHost.Visibility = bar is null ? Visibility.Collapsed : Visibility.Visible;
        RefreshBars();
        if (AppSettings.ShowStatusBar && statusBar is null)
        {
            statusBar = new StatusBar(Document);
            SetRow(statusBar, 5);
            Children.Add(statusBar);
        }
        else if (!AppSettings.ShowStatusBar && statusBar is not null)
        {
            Children.Remove(statusBar);
            statusBar.Detach();
            statusBar = null;
        }
    }

    private void RefreshBars()
    {
        foreach (var bar in new[] { fullBar, outlineBar, codeBar }) bar?.Refresh(Tab.Reading);
    }

    /// <summary>Applies the tab's reading mode and source view to the editor.</summary>
    public void ApplyModes()
    {
        if (editor is MarkdownEditor markdown) markdown.ShowsSource = Tab.ShowsSource;
        editor.Reading = Tab.Reading;
        RefreshBars();
    }

    private void ShowError()
    {
        errorBar.Message = Document.Error ?? "";
        errorBar.IsOpen = Document.Error is not null;
    }

    private void ShowReadOnly()
    {
        readOnlyText.Text = Document.ReadOnlyReason ?? "";
        readOnlyBanner.Visibility = Document.ReadOnlyReason is null ? Visibility.Collapsed : Visibility.Visible;
    }

    public void Format() => editor.Format();

    public void FocusEditor() => editor.Focus();

    public EditorViewState CaptureViewState() => editor.CaptureViewState();

    public void ApplyViewState(EditorViewState state) => editor.ApplyViewState(state);

    // MARK: Find, outline, table picker

    /// <summary>Ctrl+F (and Ctrl+H with `replace`): shows the find panel and puts the keyboard in its field.</summary>
    public void ShowFind(bool replace) => findBar.Open(replace);

    /// <summary>F3 / Shift+F3.</summary>
    public void FindStep(TextEditor.FindStep step) => findBar.Step(step);

    private FrameworkElement Anchor(FrameworkElement? preferred) =>
        preferred is { ActualWidth: > 0 } && toolbarHost.Visibility == Visibility.Visible ? preferred : editor.Host;

    private void Show(FrameworkElement content, FrameworkElement anchor)
    {
        popup?.Hide();
        var flyout = new Flyout { Content = content, Placement = FlyoutPlacementMode.Bottom };
        flyout.Closed += (_, _) =>
        {
            if (popup == flyout) popup = null;
        };
        popup = flyout;
        flyout.ShowAt(anchor);
    }

    /// <summary>The outline of the headings; choosing one puts the caret there. Pressing the shortcut again closes it.</summary>
    private void ToggleOutline()
    {
        if (editor is not MarkdownEditor markdown) return;
        if (popup is { IsOpen: true } open && open.Content is ListView or TextBlock)
        {
            open.Hide();
            return;
        }
        var content = EditorPopups.Outline(markdown.Headings(), heading =>
        {
            popup?.Hide();
            markdown.Reveal(heading.Location);
        });
        var anchor = (AppSettings.ShowFormattingBar ? fullBar?.OutlineButton : outlineBar?.OutlineButton);
        Show(content, Anchor(anchor));
    }

    /// <summary>The table size picker; without the formatting bar a 3 × 3 table goes in at once (like the macOS app).</summary>
    private void ShowTablePicker()
    {
        if (editor is not MarkdownEditor markdown) return;
        if (!AppSettings.ShowFormattingBar || fullBar?.TableButton is not { ActualWidth: > 0 } button)
        {
            markdown.InsertTable(3, 3);
            return;
        }
        Show(EditorPopups.TablePicker(markdown, () => popup?.Hide()), button);
    }

    public void Detach()
    {
        Document.ErrorChanged -= ShowError;
        Document.ReadOnlyChanged -= ShowReadOnly;
        AppSettings.EditorSettingChanged -= OnSettingChanged;
        statusBar?.Detach();
        editor.Detach();
    }
}
