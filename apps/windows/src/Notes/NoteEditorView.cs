using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Notes.Editor;
using NotesCore;

namespace Notes;

/// <summary>
/// Hosts the editor for one document, shared by the main window and file windows: the Markdown editor for Markdown files,
/// the code editor for the rest, plus the read-only banner, the document's error bar and, for JSON, a "Format" button.
/// Every message here is neutral: the app has no red or yellow states.
/// </summary>
internal sealed class NoteEditorView : Grid
{
    public NoteDocument Document { get; }
    private readonly TextEditor editor;
    private readonly InfoBar errorBar;
    private readonly Border readOnlyBanner;
    private readonly TextBlock readOnlyText;

    public TextEditor Editor => editor;

    public NoteEditorView(NoteDocument document)
    {
        Document = document;
        for (var i = 0; i < 4; i++) RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

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
        editor.FaithfulnessChanged += () => unfaithful.IsOpen = !editor.IsFaithful;
        if (editor.CanFormat)
        {
            var format = new Button
            {
                Content = Loc.Get("Format"),
                HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(12, 8, 12, 0),
            };
            ToolTipService.SetToolTip(format, Loc.Get("FormatTip"));
            format.Click += (_, _) => editor.Format();
            SetRow(format, 3);
            Children.Add(format);
        }
        SetRow(editor.Box, 4);
        Children.Add(editor.Box);

        document.ErrorChanged += ShowError;
        document.ReadOnlyChanged += ShowReadOnly;
        ShowError();
        ShowReadOnly();
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

    public void Detach()
    {
        Document.ErrorChanged -= ShowError;
        Document.ReadOnlyChanged -= ShowReadOnly;
        editor.Detach();
    }
}
