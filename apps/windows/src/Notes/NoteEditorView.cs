using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Notes.Editor;
using NotesCore;

namespace Notes;

/// <summary>
/// Hosts the editor for one document, shared by the main window and file windows: the Markdown editor for Markdown files,
/// the code editor for the rest, plus the document's error bar and, for JSON, a "Format" button.
/// </summary>
internal sealed class NoteEditorView : Grid
{
    public NoteDocument Document { get; }
    private readonly TextEditor editor;
    private readonly InfoBar errorBar;

    public NoteEditorView(NoteDocument document)
    {
        Document = document;
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        errorBar = new InfoBar { Title = Loc.Get("Error"), Margin = new Thickness(12, 12, 12, 0) };
        errorBar.CloseButtonClick += (_, _) => Document.Error = null;
        Children.Add(errorBar);

        // Shown when RichEdit can't hold the text unchanged (lone CR, NUL…): the editor is then read-only.
        var unfaithful = new InfoBar
        {
            Severity = InfoBarSeverity.Warning,
            IsClosable = false,
            Message = Loc.Get("UnfaithfulBar"),
            Margin = new Thickness(12, 12, 12, 0),
        };
        SetRow(unfaithful, 1);
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
            SetRow(format, 2);
            Children.Add(format);
        }
        SetRow(editor.Box, 3);
        Children.Add(editor.Box);

        document.ErrorChanged += ShowError;
        ShowError();
    }

    private void ShowError()
    {
        errorBar.Message = Document.Error ?? "";
        errorBar.Severity = Document.HasUnsavedChanges ? InfoBarSeverity.Error : InfoBarSeverity.Warning;
        errorBar.IsOpen = Document.Error is not null;
    }

    public void Format() => editor.Format();

    public void FocusEditor() => editor.Focus();

    public void Detach()
    {
        Document.ErrorChanged -= ShowError;
        editor.Detach();
    }
}
