using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using NotesCore;
using Windows.System;

namespace Notes.Editor;

/// <summary>Plain-text Markdown editor with live syntax styling (port of MarkdownEditor.swift).</summary>
internal sealed class MarkdownEditor : TextEditor
{
    private const double FontSize = 15;
    private const double MaxLineWidth = 720;
    private static readonly double[] HeadingScale = [1.6, 1.4, 1.25, 1.12, 1.0, 0.93];

    private List<MarkdownRange> codeBlocks = [];
    private List<MarkdownSpan> links = [];

    public MarkdownEditor(NoteDocument note) : base(note, spellCheck: true)
    {
        Box.SizeChanged += (_, e) => UpdatePadding(e.NewSize.Width);
        Box.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(OnPointerPressed), true);
    }

    private void UpdatePadding(double width)
    {
        var horizontal = Math.Max(28, Math.Round((width - MaxLineWidth) / 2));
        if (Box.Padding.Left != horizontal) Box.Padding = new Thickness(horizontal, 24, horizontal, 24);
    }

    protected override void Restyle()
    {
        var text = LastText;
        var length = text.Length;
        if (length > MaxStyledLength)
        {
            // Too long to scan on every keystroke: plain text, styled once.
            if (NeedsFullRestyle) ApplyBase(0, length);
            codeBlocks = [];
            links = [];
            PendingEdit = null;
            NeedsFullRestyle = false;
            return;
        }
        var spans = MarkdownStyler.Spans(text);
        var blocks = spans.Where(s => s.Kind.Kind == MarkdownKind.CodeBlock).Select(s => s.Range).ToList();

        var target = new MarkdownRange(0, length);
        // Only fenced code spans lines, so unless the fences moved, restyling the edited lines is enough.
        if (!NeedsFullRestyle && PendingEdit is { } edit && Shift(codeBlocks, edit).SequenceEqual(blocks))
        {
            target = MarkdownStyler.RestyleRange(new MarkdownRange(edit.Start, edit.End - edit.Start), text);
        }
        codeBlocks = blocks;
        links = spans.Where(s => s.Kind.Kind == MarkdownKind.Link).ToList();
        PendingEdit = null;
        NeedsFullRestyle = false;

        ApplyBase(target.Location, target.End);
        foreach (var span in spans)
        {
            if (span.Range.Location >= target.End) break;
            var start = Math.Max(span.Range.Location, target.Location);
            var end = Math.Min(span.Range.End, target.End);
            if (end > start) Apply(span.Kind, start, end);
        }
    }

    /// <summary>Maps code block ranges from before an edit to where they would be after it, if the edit left fences alone.</summary>
    private static IEnumerable<MarkdownRange> Shift(List<MarkdownRange> ranges, (int Start, int End, int Delta) edit)
    {
        var oldStart = edit.Start;
        var oldEnd = edit.End - edit.Delta;
        foreach (var r in ranges)
        {
            if (r.Location >= oldEnd && r.Location > oldStart) yield return r with { Location = r.Location + edit.Delta };
            else if (r.End >= oldStart) yield return r with { Length = r.Length + edit.Delta };
            else yield return r;
        }
    }

    private void ApplyBase(int start, int end)
    {
        var range = Range(start, end == LastText.Length ? end + 1 : end);
        var format = range.CharacterFormat;
        format.Name = EditorFonts.Text;
        format.Size = EditorFonts.Points(FontSize);
        format.Bold = FormatEffect.Off;
        format.Italic = FormatEffect.Off;
        format.Underline = UnderlineType.None;
        format.Strikethrough = FormatEffect.Off;
        format.ForegroundColor = Palette.Text;
        format.BackgroundColor = Colors.Transparent;
        range.ParagraphFormat.SetLineSpacing(LineSpacingRule.Multiple, 1.2f);
        range.ParagraphFormat.SpaceAfter = 4;
    }

    private void Apply(MarkdownSpanKind kind, int start, int end)
    {
        var range = Range(start, end);
        var format = range.CharacterFormat;
        switch (kind.Kind)
        {
            case MarkdownKind.Marker or MarkdownKind.HorizontalRule:
                format.ForegroundColor = Palette.Tertiary;
                break;
            case MarkdownKind.Heading:
                format.Size = EditorFonts.Points(Math.Round(FontSize * HeadingScale[Math.Clamp(kind.Level, 1, 6) - 1]));
                format.Bold = FormatEffect.On;
                break;
            case MarkdownKind.Bold:
                format.Bold = FormatEffect.On;
                break;
            case MarkdownKind.Italic:
                format.Italic = FormatEffect.On;
                break;
            case MarkdownKind.BoldItalic:
                format.Bold = FormatEffect.On;
                format.Italic = FormatEffect.On;
                break;
            case MarkdownKind.Strikethrough:
                format.Strikethrough = FormatEffect.On;
                break;
            case MarkdownKind.InlineCode or MarkdownKind.CodeBlock:
                // 90% of the size around it (a heading's, inside one).
                var size = Range(start, start + 1).CharacterFormat.Size;
                format.Name = EditorFonts.Mono;
                format.Size = size * 0.9f;
                format.BackgroundColor = Palette.CodeBackground;
                break;
            case MarkdownKind.Blockquote or MarkdownKind.ListMarker:
                format.ForegroundColor = Palette.Secondary;
                break;
            case MarkdownKind.TaskMarker:
                format.ForegroundColor = kind.Checked ? Palette.Tertiary : Palette.Secondary;
                break;
            case MarkdownKind.Task:
                if (!kind.Checked) break;
                format.ForegroundColor = Palette.Tertiary;
                format.Strikethrough = FormatEffect.On;
                break;
            case MarkdownKind.Link:
                format.ForegroundColor = Palette.Link;
                break;
        }
    }

    /// <summary>Ctrl+click opens a link with an absolute URL; relative paths have nothing sensible to open.</summary>
    private async void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (!IsDown(VirtualKey.Control) || e.Pointer.PointerDeviceType == PointerDeviceType.Pen) return;
        var point = e.GetCurrentPoint(Box).Position;
        var position = Box.Document.GetRangeFromPoint(point, PointOptions.ClientCoordinates).StartPosition;
        var link = links.FirstOrDefault(s => s.Range.Contains(position));
        if (link.Kind.Url is not { } url || !Uri.TryCreate(url, UriKind.Absolute, out var uri)) return;
        await Launcher.LaunchUriAsync(uri);
    }

    protected override void HandleShortcut(VirtualKey key, bool shift)
    {
        if (key == VirtualKey.B && shift) ToggleWrap("**");
        else if (key == VirtualKey.I && !shift) ToggleWrap("*");
    }

    /// <summary>Wraps the selection in `marker`, or unwraps it when it is already wrapped.</summary>
    private void ToggleWrap(string marker)
    {
        Sync();
        var text = LastText;
        var selection = Box.Document.Selection;
        var start = Math.Min(selection.StartPosition, text.Length);
        var end = Math.Min(selection.EndPosition, text.Length);
        var m = marker.Length;
        if (start - m >= 0 && end + m <= text.Length
            && string.CompareOrdinal(text, start - m, marker, 0, m) == 0
            && string.CompareOrdinal(text, end, marker, 0, m) == 0)
        {
            Edit(start - m, end - start + 2 * m, text[start..end], start - m, end - m, typing: false);
        }
        else
        {
            Edit(start, end - start, marker + text[start..end] + marker, start + m, end + m, typing: false);
        }
    }
}
