using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace Notes.Editor;

/// <summary>
/// Find in the note (Ctrl+F): a small panel at the top right of the editor with the match count, next and previous
/// (Enter / Shift+Enter, F3 / Shift+F3 from anywhere), Esc to close, and a replace row (Ctrl+H). The search ignores case.
/// </summary>
internal sealed class FindBar : Grid
{
    /// <summary>What was searched last, shared by every editor (the first search of a new tab starts from it).</summary>
    private static string lastQuery = "";

    private readonly TextEditor editor;
    private readonly TextBox find = new() { Width = 220, MinHeight = 32 };
    private readonly TextBox replace = new() { Width = 220, MinHeight = 32 };
    private readonly TextBlock count = new() { MinWidth = 64, VerticalAlignment = VerticalAlignment.Center, FontSize = 12 };
    private readonly StackPanel replaceRow = new() { Orientation = Orientation.Horizontal, Spacing = 4, Visibility = Visibility.Collapsed };
    private readonly Button toggle;
    private readonly Action closed;

    private static Brush Resource(string key) => (Brush)Application.Current.Resources[key];

    public FindBar(TextEditor editor, Action closed)
    {
        this.editor = editor;
        this.closed = closed;
        Visibility = Visibility.Collapsed;
        HorizontalAlignment = HorizontalAlignment.Right;
        VerticalAlignment = VerticalAlignment.Top;
        Margin = new Thickness(0, 8, 20, 0);
        Padding = new Thickness(8);
        CornerRadius = new CornerRadius(8);
        BorderThickness = new Thickness(1);
        BorderBrush = Resource("CardStrokeColorDefaultBrush");
        Background = Resource("SolidBackgroundFillColorSecondaryBrush");

        count.Foreground = Resource("TextFillColorSecondaryBrush");
        find.PlaceholderText = Loc.Get("FindPlaceholder");
        replace.PlaceholderText = Loc.Get("ReplacePlaceholder");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(find, Loc.Get("FindPlaceholder"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(replace, Loc.Get("ReplacePlaceholder"));

        toggle = IconButton("", Loc.Get("ToggleReplace"), () => SetReplaceVisible(replaceRow.Visibility != Visibility.Visible));
        toggle.VerticalAlignment = VerticalAlignment.Top;
        var previous = IconButton("", $"{Loc.Get("FindPrevious")} (Shift+F3)", () => Step(TextEditor.FindStep.Previous));
        var next = IconButton("", $"{Loc.Get("FindNext")} (F3)", () => Step(TextEditor.FindStep.Next));
        var close = IconButton("", $"{Loc.Get("CloseFind")} (Esc)", Close);
        var findRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Children = { find, count, previous, next, close } };

        var replaceOne = new Button { Content = Loc.Get("Replace"), MinHeight = 32 };
        replaceOne.Click += (_, _) => ReplaceOne();
        var replaceAll = new Button { Content = Loc.Get("ReplaceAll"), MinHeight = 32 };
        replaceAll.Click += (_, _) => ReplaceEverything();
        replaceRow.Children.Add(replace);
        replaceRow.Children.Add(replaceOne);
        replaceRow.Children.Add(replaceAll);

        var rows = new StackPanel { Spacing = 6, Children = { findRow, replaceRow } };
        var layout = new Grid { ColumnSpacing = 4 };
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        layout.ColumnDefinitions.Add(new ColumnDefinition());
        layout.Children.Add(toggle);
        Grid.SetColumn(rows, 1);
        layout.Children.Add(rows);
        Children.Add(layout);

        find.TextChanged += (_, _) =>
        {
            lastQuery = find.Text;
            if (Visibility == Visibility.Visible) Search(TextEditor.FindStep.Stay);
        };
        find.KeyDown += (_, e) => OnKey(e, () => Step(IsShift() ? TextEditor.FindStep.Previous : TextEditor.FindStep.Next));
        replace.KeyDown += (_, e) => OnKey(e, ReplaceOne);
        editor.SelectionSettled += () =>
        {
            if (Visibility == Visibility.Visible) ShowCount(editor.FindStatus(find.Text));
        };
    }

    private static bool IsShift() =>
        Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private static Button IconButton(string glyph, string tip, Action click)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 12 },
            Width = 32,
            Height = 32,
            Padding = new Thickness(0),
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        };
        ToolTipService.SetToolTip(button, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, tip);
        button.Click += (_, _) => click();
        return button;
    }

    private void OnKey(KeyRoutedEventArgs e, Action enter)
    {
        if (e.Key == VirtualKey.Escape)
        {
            e.Handled = true;
            Close();
        }
        else if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            enter();
        }
    }

    public bool IsOpen => Visibility == Visibility.Visible;

    private void SetReplaceVisible(bool visible)
    {
        replaceRow.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        ((FontIcon)toggle.Content).Glyph = visible ? "" : "";
    }

    /// <summary>Shows the bar and puts the keyboard in its field; `withReplace` also shows the replace row.</summary>
    public void Open(bool withReplace)
    {
        Visibility = Visibility.Visible;
        if (withReplace) SetReplaceVisible(true);
        if (editor.SelectionForFind() is { Length: > 0 } selected) find.Text = selected;
        else if (find.Text.Length == 0 && lastQuery.Length > 0) find.Text = lastQuery;
        find.Focus(FocusState.Programmatic);
        find.SelectAll();
        ShowCount(editor.FindStatus(find.Text));
    }

    public void Close()
    {
        if (!IsOpen) return;
        Visibility = Visibility.Collapsed;
        closed();
        editor.Focus();
    }

    /// <summary>F3 / Shift+F3 and the buttons: the next or previous match, opening the bar when it was closed.</summary>
    public void Step(TextEditor.FindStep step)
    {
        if (!IsOpen) Open(withReplace: false);
        if (find.Text.Length == 0) return;
        Search(step);
    }

    private void Search(TextEditor.FindStep step)
    {
        if (find.Text.Length == 0)
        {
            ShowCount((0, 0));
            return;
        }
        ShowCount(editor.Find(find.Text, step));
    }

    private void ReplaceOne()
    {
        if (find.Text.Length > 0) ShowCount(editor.ReplaceCurrent(find.Text, replace.Text));
    }

    private void ReplaceEverything()
    {
        if (find.Text.Length == 0) return;
        editor.ReplaceAllMatches(find.Text, replace.Text);
        ShowCount(editor.FindStatus(find.Text));
    }

    private void ShowCount((int Current, int Total) status) =>
        count.Text = find.Text.Length == 0 ? ""
            : status.Total == 0 ? Loc.Get("FindNoResults")
            : status.Current == 0 ? Loc.Format("FindMatches", status.Total)
            : Loc.Format("FindPosition", status.Current, status.Total);
}
