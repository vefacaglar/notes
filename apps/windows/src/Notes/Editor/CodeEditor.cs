using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using NotesCore;
using Windows.Foundation;

namespace Notes.Editor;

/// <summary>Monospaced editor with syntax highlighting for code, data and plain text files (port of CodeEditor.swift).</summary>
internal sealed class CodeEditor : TextEditor
{
    private const double BaseFontSize = 13;
    private static double FontSize => EditorFonts.Scaled(BaseFontSize);

    private readonly CodeLanguage language;
    private List<CodeSpan> spans = [];
    /// <summary>What Tab inserts; set per file from its existing indentation.</summary>
    private string indentUnit = "    ";

    // Line numbers: one per logical line (wrapped continuations get none), in a column left of the box.
    private readonly Canvas gutter = new();
    private readonly Grid gutterHost = new() { IsHitTestVisible = false };
    private readonly TranslateTransform gutterShift = new();
    private readonly List<int> lineStarts = [0];
    private string? lineStartsFor;
    private readonly List<TextBlock> numbers = [];
    private int digits = 3;

    public CodeEditor(NoteDocument note) : base(note)
    {
        language = note.Language;
        Box.TextWrapping = AppSettings.CodeWrap ? TextWrapping.Wrap : TextWrapping.NoWrap;
        FontSettingsChanged();
        Host.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Host.ColumnDefinitions.Add(new ColumnDefinition());
        foreach (var child in Host.Children.OfType<FrameworkElement>()) Grid.SetColumn(child, 1);
        gutter.RenderTransform = gutterShift;
        gutterHost.Children.Add(gutter);
        gutterHost.SizeChanged += (_, e) => gutterHost.Clip = new RectangleGeometry { Rect = new Rect(0, 0, e.NewSize.Width, e.NewSize.Height) };
        Host.Children.Add(gutterHost);
        gutterHost.Visibility = AppSettings.CodeLineNumbers ? Visibility.Visible : Visibility.Collapsed;
    }

    protected override Thickness ComputePadding() => new(AppSettings.CodeLineNumbers ? 12 : 24, 16, 24, 16);

    protected override void FontSettingsChanged() =>
        // Four spaces of the monospaced font (about 0.55–0.6 em per character).
        Box.Document.DefaultTabStop = EditorFonts.Points(FontSize) * 4 * 0.58f;

    protected override void SettingChanged(string key)
    {
        if (key == "codeWrap") Box.TextWrapping = AppSettings.CodeWrap ? TextWrapping.Wrap : TextWrapping.NoWrap;
        if (key is "codeLineNumbers" or "highlightCurrentLine" or "zoom" or "lineSpacing" or "codeWrap") InvalidateOverlay(10);
    }

    protected override void OnSelectionSettled(bool byMouse)
    {
        if (AppSettings.HighlightCurrentLine && AppSettings.CodeLineNumbers) InvalidateOverlay(10);
    }

    protected override void OverlayShifted(double y) => gutterShift.Y = y;

    // MARK: Line numbers

    private void EnsureLineStarts(string text)
    {
        if (ReferenceEquals(text, lineStartsFor)) return;
        lineStartsFor = text;
        lineStarts.Clear();
        lineStarts.Add(0);
        for (var i = text.IndexOf('\n'); i >= 0; i = text.IndexOf('\n', i + 1)) lineStarts.Add(i + 1);
    }

    /// <summary>Index of the last line starting at or before `position`.</summary>
    private int LineIndexAt(int position)
    {
        var index = lineStarts.BinarySearch(position);
        return index >= 0 ? index : ~index - 1;
    }

    protected override void RenderOverlay()
    {
        var shows = AppSettings.CodeLineNumbers;
        gutterHost.Visibility = shows ? Visibility.Visible : Visibility.Collapsed;
        if (!shows) return;
        var text = LastText;
        EnsureLineStarts(text);
        var numberSize = Math.Max(EditorFonts.Scaled(13) * 0.85, 8);
        var needed = Math.Max(3, lineStarts.Count.ToString(System.Globalization.CultureInfo.InvariantCulture).Length);
        var width = Math.Ceiling(needed * numberSize * 0.62) + 16;
        if (gutterHost.Width != width || digits != needed)
        {
            digits = needed;
            gutterHost.Width = width;
        }
        var palette = Palette;
        var (first, last) = VisibleCharacters(ViewportHeight);
        var offset = ScrollY;
        var caretLine = AppSettings.HighlightCurrentLine && CurrentSelection().Length == 0 ? LineIndexAt(CurrentSelection().Location) : -1;
        var used = 0;
        for (var line = LineIndexAt(first); line < lineStarts.Count && lineStarts[line] <= last; line++)
        {
            if (RectOf(lineStarts[line], lineStarts[line] + 1) is not { } rect) continue;
            if (used == numbers.Count)
            {
                var block = new TextBlock { TextAlignment = TextAlignment.Right, FontFamily = new FontFamily(EditorFonts.Mono) };
                numbers.Add(block);
                gutter.Children.Add(block);
            }
            var number = numbers[used++];
            number.Visibility = Visibility.Visible;
            number.Text = (line + 1).ToString(System.Globalization.CultureInfo.InvariantCulture);
            number.FontSize = numberSize;
            number.Width = width - 8;
            var color = line == caretLine ? palette.Secondary : Windows.UI.Color.FromArgb((byte)(palette.Secondary.A / 2), palette.Secondary.R, palette.Secondary.G, palette.Secondary.B);
            number.Foreground = new SolidColorBrush(color);
            Canvas.SetLeft(number, 0);
            Canvas.SetTop(number, rect.Y + offset + Math.Max(0, (rect.Height - numberSize * 1.35) / 2));
        }
        for (var i = used; i < numbers.Count; i++) numbers[i].Visibility = Visibility.Collapsed;
    }

    protected override void Loading(string text) => indentUnit = language.IndentUnit(text);

    /// <summary>Tokenizes the whole text, then restyles only where the spans differ from last time.</summary>
    protected override void Restyle()
    {
        var text = LastText;
        var length = text.Length;
        var updated = length > MaxStyledLength ? [] : CodeHighlighter.Spans(text, language);
        var target = new CodeRange(0, length);
        if (!NeedsFullRestyle && PendingEdit is { } edit)
        {
            target = CodeHighlighter.ChangedRange(spans, updated, new CodeRange(edit.Start, edit.End - edit.Start), edit.Delta, length);
        }
        spans = updated;
        PendingEdit = null;
        var full = NeedsFullRestyle;
        NeedsFullRestyle = false;
        if (target.Length == 0 && !full) return;

        ApplyBase(target.Location, target.End);
        var palette = Palette;
        // Markdown spans nest, so their ends are not sorted.
        var k = language == CodeLanguage.Markdown ? 0 : FirstSpan(updated, target.Location);
        for (; k < updated.Count && updated[k].Location < target.End; k++)
        {
            var start = Math.Max(updated[k].Location, target.Location);
            var end = Math.Min(updated[k].End, target.End);
            if (end <= start) continue;
            var (color, semibold) = palette.Code(updated[k].Kind);
            var format = Range(start, end).CharacterFormat;
            format.ForegroundColor = color;
            if (semibold) format.Weight = 600;
        }
    }

    private static int FirstSpan(List<CodeSpan> spans, int location)
    {
        int lo = 0, hi = spans.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (spans[mid].End <= location) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    private void ApplyBase(int start, int end)
    {
        var range = Range(start, end == LastText.Length ? end + 1 : end);
        var format = range.CharacterFormat;
        format.Name = EditorFonts.Mono;
        format.Size = EditorFonts.Points(FontSize);
        format.Bold = FormatEffect.Off;
        format.Weight = 400;
        format.Italic = FormatEffect.Off;
        format.Underline = UnderlineType.None;
        format.Strikethrough = FormatEffect.Off;
        format.ForegroundColor = Palette.Text;
        format.BackgroundColor = Colors.Transparent;
        range.ParagraphFormat.SetLineSpacing(LineSpacingRule.Multiple, (float)AppSettings.LineSpacing);
        range.ParagraphFormat.SpaceAfter = 0;
    }

    protected override bool HandleTab(bool backward)
    {
        if (backward) return false;
        Insert(indentUnit);
        return true;
    }

    /// <summary>Return keeps the current line's indentation.</summary>
    protected override void InsertNewline()
    {
        Sync();
        var text = LastText;
        var caret = Math.Min(Box.Document.Selection.StartPosition, text.Length);
        var lineStart = caret == 0 ? 0 : text.LastIndexOf('\n', caret - 1) + 1;
        var end = lineStart;
        while (end < caret && text[end] is ' ' or '\t') end++;
        Insert("\n" + text[lineStart..end]);
    }

    protected override void AddMenuItems(MenuFlyout menu)
    {
        if (!CanFormat) return;
        menu.Items.Add(new MenuFlyoutSeparator());
        var item = new MenuFlyoutItem { Text = Loc.Get("Format"), KeyboardAcceleratorTextOverride = "Shift+Alt+F" };
        item.Click += (_, _) => Format();
        menu.Items.Add(item);
    }
}
