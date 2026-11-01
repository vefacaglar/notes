using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using NotesCore;

namespace Notes.Editor;

/// <summary>
/// The capsule of formatting controls above the editor (the counterpart of the macOS toolbar group): Markdown styles with the
/// ones at the caret highlighted, the table picker, Reading Mode and the outline; for a code file that can be formatted, a
/// Format button and Reading Mode. Every action is a method on the editor, the same ones the Format menu runs.
/// </summary>
internal sealed class FormattingBar : Grid
{
    private readonly TextEditor editor;
    private readonly StackPanel stack = new() { Orientation = Orientation.Horizontal, Spacing = 2 };
    private readonly StackPanel formatting = new() { Orientation = Orientation.Horizontal, Spacing = 2 };
    private readonly List<(Button Button, Func<ActiveFormat, bool> Active)> styleButtons = [];
    private readonly List<ToggleMenuFlyoutItem> headingItems = [];
    private Button? readingButton, formatButton;

    /// <summary>The buttons the table picker and the outline are shown from.</summary>
    public Button? TableButton { get; private set; }
    public Button? OutlineButton { get; private set; }

    private static Brush Resource(string key) => (Brush)Application.Current.Resources[key];

    private FormattingBar(TextEditor editor)
    {
        this.editor = editor;
        Children.Add(stack);
        Height = 36;
        Padding = new Thickness(8, 0, 8, 0);
        CornerRadius = new CornerRadius(18);
        BorderThickness = new Thickness(1);
        BorderBrush = Resource("CardStrokeColorDefaultBrush");
        Background = Resource("CardBackgroundFillColorDefaultBrush");
        HorizontalAlignment = HorizontalAlignment.Center;
        VerticalAlignment = VerticalAlignment.Center;
    }

    public static FormattingBar ForMarkdown(MarkdownEditor editor, Action toggleReading)
    {
        var bar = new FormattingBar(editor);
        bar.BuildMarkdown(editor);
        bar.stack.Children.Add(bar.formatting);
        bar.stack.Children.Add(Separator());
        bar.readingButton = bar.AddReading(bar.stack, toggleReading);
        bar.OutlineButton = bar.AddOutline(bar.stack, editor);
        editor.ActiveFormatChanged += bar.SetFormat;
        return bar;
    }

    public static FormattingBar ForOutline(MarkdownEditor editor)
    {
        var bar = new FormattingBar(editor);
        bar.OutlineButton = bar.AddOutline(bar.stack, editor);
        return bar;
    }

    public static FormattingBar ForCode(TextEditor editor, Action toggleReading)
    {
        var bar = new FormattingBar(editor);
        var format = new Button
        {
            Content = new TextBlock { Text = Loc.Get("Format") },
            Height = 28,
            Padding = new Thickness(10, 0, 10, 0),
            CornerRadius = new CornerRadius(14),
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
        };
        ToolTipService.SetToolTip(format, Loc.Get("FormatTip") + " (Shift+Alt+F)");
        format.Click += (_, _) => editor.Format();
        bar.formatButton = format;
        bar.stack.Children.Add(format);
        bar.readingButton = bar.AddReading(bar.stack, toggleReading);
        return bar;
    }

    private static Border Separator() => new()
    {
        Width = 1,
        Height = 14,
        Margin = new Thickness(4, 0, 4, 0),
        Background = Resource("DividerStrokeColorDefaultBrush"),
        VerticalAlignment = VerticalAlignment.Center,
    };

    private Button Make(UIElement icon, string tooltip, Action click)
    {
        var button = new Button
        {
            Content = icon,
            Width = 30,
            Height = 28,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(14),
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            Foreground = Resource("TextFillColorSecondaryBrush"),
        };
        ToolTipService.SetToolTip(button, tooltip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, tooltip.Contains(" (") ? tooltip[..tooltip.LastIndexOf(" (", StringComparison.Ordinal)] : tooltip);
        button.Click += (_, _) => click();
        return button;
    }

    private static FontIcon Glyph(string glyph) => new() { Glyph = glyph, FontSize = 14 };

    private static TextBlock Letters(string text, bool mono = false) => new()
    {
        Text = text,
        FontSize = 13,
        FontWeight = FontWeights.SemiBold,
        FontFamily = mono ? new FontFamily(EditorFonts.Mono) : null,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private static string Tip(EditorCommand command) => $"{Loc.Get(command.TextKey)} ({command.ShortcutText})";

    private Button AddStyle(StackPanel into, UIElement icon, EditorCommand command, MarkdownEditor md, Func<ActiveFormat, bool>? active)
    {
        var button = Make(icon, Tip(command), () => command.Run(md));
        into.Children.Add(button);
        if (active is not null) styleButtons.Add((button, active));
        return button;
    }

    private void BuildMarkdown(MarkdownEditor md)
    {
        // Heading menu: the level at the caret is checked.
        var heading = Make(Glyph(""), Loc.Get("Heading"), () => { });
        var flyout = new MenuFlyout();
        foreach (var command in FormatCommands.Headings)
        {
            var item = new ToggleMenuFlyoutItem { Text = Loc.Get(command.TextKey), KeyboardAcceleratorTextOverride = command.ShortcutText };
            var run = command;
            item.Click += (_, _) =>
            {
                run.Run(md);
                SetFormat(md.ActiveFormat);
            };
            headingItems.Add(item);
            flyout.Items.Add(item);
        }
        heading.Flyout = flyout;
        formatting.Children.Add(heading);
        styleButtons.Add((heading, format => format.Heading > 0));
        formatting.Children.Add(Separator());
        AddStyle(formatting, Glyph(""), FormatCommands.Bold, md, format => format.Inline.Contains(InlineStyle.Bold));
        AddStyle(formatting, Glyph(""), FormatCommands.Italic, md, format => format.Inline.Contains(InlineStyle.Italic));
        AddStyle(formatting, Glyph(""), FormatCommands.Strikethrough, md, format => format.Inline.Contains(InlineStyle.Strikethrough));
        AddStyle(formatting, Letters("</>", mono: true), FormatCommands.InlineCode, md, format => format.Inline.Contains(InlineStyle.Code));
        formatting.Children.Add(Separator());
        AddStyle(formatting, Glyph(""), FormatCommands.BulletedList, md, format => format.Bullet);
        AddStyle(formatting, Letters("1."), FormatCommands.NumberedList, md, format => format.Numbered);
        AddStyle(formatting, Glyph(""), FormatCommands.Checklist, md, format => format.Task);
        AddStyle(formatting, Letters("“"), FormatCommands.Quote, md, format => format.Quote);
        formatting.Children.Add(Separator());
        AddStyle(formatting, Glyph(""), FormatCommands.Link, md, null);
        AddStyle(formatting, Glyph(""), FormatCommands.CodeBlock, md, null);
        TableButton = AddStyle(formatting, Glyph(""), FormatCommands.InsertTable, md, null);
        AddStyle(formatting, Glyph(""), FormatCommands.HorizontalRule, md, null);
    }

    private Button AddReading(StackPanel into, Action toggle)
    {
        var button = Make(Glyph(""), $"{Loc.Get("ReadingMode")} (Ctrl+Shift+E)", toggle);
        into.Children.Add(button);
        return button;
    }

    private Button AddOutline(StackPanel into, MarkdownEditor md)
    {
        var button = Make(Glyph(""), $"{Loc.Get("Outline")} (Ctrl+Shift+D)", md.ToggleOutline);
        into.Children.Add(button);
        return button;
    }

    /// <summary>Highlights the styles at the caret.</summary>
    public void SetFormat(ActiveFormat format)
    {
        foreach (var (button, active) in styleButtons) Highlight(button, active(format));
        if (headingItems.Count == 4)
        {
            for (var i = 0; i < 3; i++) headingItems[i].IsChecked = format.Heading == i + 1;
            headingItems[3].IsChecked = format.Heading == 0;
        }
    }

    private static void Highlight(Button button, bool on)
    {
        button.Background = on ? Resource("SubtleFillColorSecondaryBrush") : new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        button.Foreground = Resource(on ? "TextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush");
    }

    /// <summary>The editor's state changed: the style controls follow whether the text can be edited, Reading Mode shows
    /// whether it is on.</summary>
    public void Refresh(bool reading)
    {
        var editable = editor.IsEditable;
        foreach (var control in formatting.Children.OfType<Control>()) control.IsEnabled = editable;
        if (formatButton is not null) formatButton.IsEnabled = editor.CanFormat;
        if (readingButton is not null) Highlight(readingButton, reading);
    }
}
