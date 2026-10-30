using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using NotesCore;

namespace Notes.Editor;

/// <summary>Monospaced editor with syntax highlighting for code, data and plain text files (port of CodeEditor.swift).</summary>
internal sealed class CodeEditor : TextEditor
{
    private const double FontSize = 13;

    private readonly CodeLanguage language;
    private List<CodeSpan> spans = [];
    /// <summary>What Tab inserts; set per file from its existing indentation.</summary>
    private string indentUnit = "    ";

    public CodeEditor(NoteDocument note) : base(note, spellCheck: false)
    {
        language = note.Language;
        Box.Padding = new Thickness(24, 16, 24, 16);
        // Four spaces of the monospaced font (about 0.55–0.6 em per character).
        Box.Document.DefaultTabStop = EditorFonts.Points(FontSize) * 4 * 0.58f;
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
        range.ParagraphFormat.SetLineSpacing(LineSpacingRule.Multiple, 1.15f);
        range.ParagraphFormat.SpaceAfter = 0;
    }

    protected override bool HandleTab()
    {
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
