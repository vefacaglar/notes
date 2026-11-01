using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using NotesCore;
using Windows.Foundation;
using Windows.System;

namespace Notes.Editor;

/// <summary>Plain-text Markdown editor with live syntax styling (port of MarkdownEditor.swift).</summary>
internal sealed partial class MarkdownEditor : TextEditor
{
    private const double BaseFontSize = 15;
    private const double BaseCodeSize = 13;
    private const double MaxLineWidth = 720;
    private static readonly double[] HeadingScale = [1.6, 1.4, 1.25, 1.12, 1.0, 0.93];

    private static double FontSize => EditorFonts.Scaled(BaseFontSize);

    private List<MarkdownRange> codeBlocks = [];
    private List<MarkdownSpan> links = [];
    private List<MarkdownSpan> spans = [];
    /// <summary>Running maximum of the spans' ends (<see cref="MarkdownRendering.Reach"/>).</summary>
    private int[] spanReach = [];
    private bool showsSource;
    /// <summary>Whether the last styling pass hid the markers.</summary>
    private bool hidesApplied;
    private bool plainApplied;
    /// <summary>The lines (through their break) with the selection, where markers can be shown while they are hidden elsewhere.
    /// Null when markers are not hidden.</summary>
    private MarkdownRange? revealed;
    /// <summary>The hidden-elsewhere markers that are shown, all inside <see cref="revealed"/>.</summary>
    private HashSet<MarkdownRange> shownMarkers = [];
    /// <summary>The paragraphs left bright by focus mode (everything else is dimmed).</summary>
    private MarkdownRange? bright;
    /// <summary>Set by <see cref="UpdateFocus"/>: the next styling pass restyles exactly these ranges.</summary>
    private List<MarkdownRange>? forcedTargets;
    private (Point Position, string Link, bool Ctrl, int Index)? press;
    private (long Tick, int Index)? lastToggle;

    [System.Runtime.InteropServices.DllImport("user32.dll", ExactSpelling = true)]
    private static extern uint GetDoubleClickTime();

    private string? contextLink;
    private MarkdownRange previousSelection, currentSelection;

    /// <summary>The styles at the caret, for the formatting bar.</summary>
    public ActiveFormat ActiveFormat { get; private set; } = new();
    public event Action<ActiveFormat>? ActiveFormatChanged;
    /// <summary>A link was clicked: its destination as written (<see cref="NoteLinks.Classify"/>).</summary>
    public event Action<string>? LinkActivated;
    public event Action? OutlineRequested;
    public event Action? TablePickerRequested;

    public MarkdownEditor(NoteDocument note) : base(note)
    {
        Box.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler(OnPointerPressed), true);
        Box.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler(OnPointerReleased), true);
        Box.SelectionChanged += (_, _) =>
        {
            var now = CurrentSelection();
            if (now == currentSelection) return;
            previousSelection = currentSelection;
            currentSelection = now;
        };
        // While the mouse is down the reveal waits for the button to come up, so the text doesn't shift under the pointer.
        var released = new PointerEventHandler((_, _) =>
            Box.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, RevealSettled));
        Box.AddHandler(UIElement.PointerReleasedEvent, released, true);
        Box.AddHandler(UIElement.PointerCanceledEvent, released, true);
        InitializeRendering();
    }

    /// <summary>Show Source: the text as plain monospaced source (same text and undo history).</summary>
    public bool ShowsSource
    {
        get => showsSource;
        set
        {
            if (showsSource == value) return;
            showsSource = value;
            bright = null;
            if (!IsReady) return;
            RestyleAll();
        }
    }

    protected override Thickness ComputePadding()
    {
        var horizontal = AppSettings.LimitLineWidth ? Math.Max(28, Math.Round((Box.ActualWidth - MaxLineWidth) / 2)) : 28;
        var vertical = AppSettings.FocusMode ? Math.Max(24, Math.Round(ViewportHeight / 2)) : 24;
        return new Thickness(horizontal, vertical, horizontal, vertical);
    }

    protected override bool CentersCaret => AppSettings.FocusMode && !ShowsSource;

    protected override void SettingChanged(string key)
    {
        switch (key)
        {
            case "focusMode":
                UpdateFocus();
                if (CentersCaret) QueueSelectionSettled();
                break;
            case "showMarkdownSyntax":
                if (IsReady && HidesMarkers != hidesApplied) RestyleAll();
                break;
            case "limitLineWidth" or "zoom":
                RefitSoon();
                break;
        }
    }

    protected override void ReadingChanged()
    {
        if (IsReady && HidesMarkers != hidesApplied) RestyleAll();
        else if (IsReady) QueueSelectionSettled();
    }

    /// <summary>Styles the whole text again (a mode changed) and brings the revealed markers in line with the selection.</summary>
    private void RestyleAll()
    {
        NeedsFullRestyle = true;
        Styled(Restyle);
        QueueSelectionSettled();
        InvalidateOverlay();
    }

    /// <summary>Markdown syntax is hidden: the setting says so (or reading mode does), and the source view is not shown.</summary>
    private bool HidesMarkers => (!AppSettings.ShowMarkdownSyntax || Reading) && !ShowsSource;

    // MARK: Styling

    protected override void Restyle()
    {
        var text = LastText;
        var length = text.Length;
        hidesApplied = HidesMarkers;
        if (ShowsSource || length > MaxStyledLength)
        {
            // Source view, or too long to scan on every keystroke: plain text, styled once.
            // Crossing into plain mode resets everything once: hidden markers and drawn glyphs must not stay behind.
            var wasStyled = !plainApplied;
            plainApplied = true;
            if (NeedsFullRestyle || wasStyled) ApplyBase(0, length);
            else if (PendingEdit is { } plain)
            {
                var lines = MarkdownStyler.RestyleRange(new MarkdownRange(plain.Start, plain.End - plain.Start), text);
                ApplyBase(lines.Location, lines.End);
            }
            codeBlocks = [];
            links = [];
            spans = [];
            spanReach = [];
            revealed = null;
            shownMarkers = [];
            ResetRendering();
            PendingEdit = null;
            NeedsFullRestyle = false;
            forcedTargets = null;
            bright = null;
            return;
        }
        plainApplied = false;
        var scanned = MarkdownStyler.Spans(text);
        var blocks = scanned.Where(s => s.Kind.Kind == MarkdownKind.CodeBlock).Select(s => s.Range).ToList();
        var reveal = HidesMarkers ? RevealRange() : (MarkdownRange?)null;
        var oldGrids = grids;
        var oldTables = tables;
        containerWidth = TextWidth;
        tables = scanned.Where(s => s.Kind.Kind == MarkdownKind.Table).Select(s => s.Range).ToList();
        grids = [];
        shownTables = TablesShown(reveal);

        List<MarkdownRange> targets;
        (int Start, int End, int Delta)? moved = null;
        if (forcedTargets is { } forced)
        {
            targets = [.. forced.Select(r => new MarkdownRange(Math.Min(r.Location, length), Math.Min(r.Length, Math.Max(0, length - Math.Min(r.Location, length)))))];
            targets = Expanded(targets, RenderedTables());
        }
        else
        {
            var target = new MarkdownRange(0, length);
            targets = [target];
            // Only fenced code spans lines, so unless the fences moved, restyling the edited lines is enough (plus the lines whose
            // markers were or are now revealed).
            if (!NeedsFullRestyle && PendingEdit is { } edit && Shift(codeBlocks, edit).SequenceEqual(blocks))
            {
                moved = edit;
                target = MarkdownStyler.RestyleRange(new MarkdownRange(edit.Start, edit.End - edit.Start), text);
                // A fence or a comment/string opener can change the colours of the whole block.
                foreach (var block in blocks)
                {
                    if (block.Location < target.End && block.End > target.Location)
                    {
                        var start = Math.Min(target.Location, block.Location);
                        target = new MarkdownRange(start, Math.Max(target.End, block.End) - start);
                    }
                }
                targets = [target];
                if (revealed is { } old) targets.Add(ShiftLines(old, edit, text));
                if (reveal is { } now) targets.Add(now);
                // An edit in one row can change every column: tables it touches, before or after it, are restyled whole.
                foreach (var table in oldTables)
                {
                    if (!oldGrids.TryGetValue(table.Location, out var grid) || !grid.Rendered) continue;
                    var shifted = ShiftLines(table, edit, text);
                    if (Intersects(shifted, target)) targets.Add(shifted);
                }
                // An edit that moved the caret to another paragraph (undo, replace): the old bright one must be dimmed again.
                if (AppSettings.FocusMode && bright is { } brightOld)
                {
                    var shifted = ShiftLines(brightOld, edit, text);
                    if (shifted != FocusParagraph()) targets.Add(shifted);
                }
                targets = Expanded(targets, RenderedTables());
            }
        }
        forcedTargets = null;
        // Tables that are not restyled keep the layout they had.
        foreach (var table in tables)
        {
            if (targets.Any(t => Intersects(t, table))) continue;
            var before = moved is { } m && table.Location >= m.End ? table.Location - m.Delta : table.Location;
            if (oldGrids.TryGetValue(before, out var kept)) grids[table.Location] = kept.Moved(table);
        }
        codeBlocks = blocks;
        spans = scanned;
        spanReach = MarkdownRendering.Reach(scanned);
        links = scanned.Where(s => s.Kind.Kind is MarkdownKind.Link or MarkdownKind.WikiLink).ToList();
        PendingEdit = null;
        NeedsFullRestyle = false;
        revealed = reveal;
        shownMarkers = reveal is { } lines2
            ? MarkdownRendering.ShownMarkers(scanned, spanReach, [CurrentSelection()], lines2, text, Reading)
            : [];

        var merged = Merged(targets);
        foreach (var target in merged)
        {
            if (target.Length > 0 || length == 0) ApplyTarget(target);
        }
        if (AppSettings.FocusMode) Dim(merged);
        else bright = null;
        UpdateImageSlots();
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

    protected override void FontSettingsChanged() => bright = null;

    private void ApplyBase(int start, int end)
    {
        var range = Range(start, end == LastText.Length ? end + 1 : end);
        var format = range.CharacterFormat;
        format.Name = ShowsSource ? EditorFonts.Mono : EditorFonts.Text;
        format.Size = EditorFonts.Points(ShowsSource ? EditorFonts.Scaled(BaseCodeSize) : FontSize);
        format.Bold = FormatEffect.Off;
        format.Italic = FormatEffect.Off;
        format.Underline = UnderlineType.None;
        format.Strikethrough = FormatEffect.Off;
        format.Hidden = FormatEffect.Off;
        format.Spacing = 0;
        format.ForegroundColor = Palette.Text;
        format.BackgroundColor = Colors.Transparent;
        var paragraph = range.ParagraphFormat;
        paragraph.SetLineSpacing(LineSpacingRule.Multiple, (float)AppSettings.LineSpacing);
        paragraph.SpaceBefore = 0;
        paragraph.SpaceAfter = ShowsSource ? 0 : BaseSpaceAfter;
        paragraph.SetIndents(0, 0, 0);
    }

    /// <summary>Space after a paragraph, in points.</summary>
    private const float BaseSpaceAfter = 4;

    private void Apply(MarkdownSpanKind kind, int start, int end)
    {
        var range = Range(start, end);
        var format = range.CharacterFormat;
        switch (kind.Kind)
        {
            case MarkdownKind.Marker or MarkdownKind.HorizontalRule or MarkdownKind.TableMarker:
                format.ForegroundColor = Palette.Tertiary;
                break;
            case MarkdownKind.Heading:
                format.Size = EditorFonts.Points(Math.Round(FontSize * HeadingScale[Math.Clamp(kind.Level, 1, 6) - 1]));
                format.Bold = FormatEffect.On;
                break;
            case MarkdownKind.TableHeader:
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
                // Fenced blocks get a full-width band from the overlay instead of a background behind the glyphs.
                if (kind.Kind == MarkdownKind.InlineCode) format.BackgroundColor = Palette.CodeBackground;
                break;
            case MarkdownKind.ListMarker:
                format.ForegroundColor = Palette.Tertiary;
                break;
            case MarkdownKind.Blockquote:
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
            case MarkdownKind.Link or MarkdownKind.WikiLink:
                format.ForegroundColor = Palette.Link;
                break;
        }
    }

    // MARK: Focus mode

    /// <summary>The lines the selection touches, line break after them excluded.</summary>
    private MarkdownRange FocusParagraph()
    {
        var text = LastText;
        var selection = CurrentSelection();
        var start = LineAt(text, selection.Location).Start;
        var end = LineAt(text, selection.End).End;
        return new MarkdownRange(start, end - start);
    }

    /// <summary>Dims the parts of the freshly styled `targets` that lie outside the selection's paragraphs.</summary>
    private void Dim(List<MarkdownRange> targets)
    {
        var paragraph = FocusParagraph();
        bright = paragraph;
        var dim = Palette.Dim;
        foreach (var target in targets)
        {
            var end = target.End == LastText.Length ? target.End + 1 : target.End;
            if (Math.Min(end, paragraph.Location) > target.Location)
            {
                Range(target.Location, Math.Min(end, paragraph.Location)).CharacterFormat.ForegroundColor = dim;
            }
            var from = Math.Max(target.Location, paragraph.End);
            if (end > from) Range(from, end).CharacterFormat.ForegroundColor = dim;
            // The dim would show the glyphs of drawn markers (-, >, ---) over their drawings: keep them clear.
            ClearDecorationGlyphs(target.Location, Math.Min(paragraph.Location, target.End));
            ClearDecorationGlyphs(Math.Max(target.Location, paragraph.End), target.End);
        }
        InvalidateOverlay();
    }

    /// <summary>The selection moved: the old and the new paragraphs are styled again, which also dims the right ones.</summary>
    private void UpdateFocus()
    {
        if (!IsReady) return;
        var on = AppSettings.FocusMode && !ShowsSource && LastText.Length <= MaxStyledLength;
        if (!on)
        {
            if (bright is null) return;
            bright = null;
            NeedsFullRestyle = true;
            Styled(Restyle);
            return;
        }
        var paragraph = FocusParagraph();
        if (bright == paragraph) return;
        forcedTargets = bright is { } old ? [old, paragraph] : [new MarkdownRange(0, LastText.Length)];
        Styled(Restyle);
    }

    protected override void OnSelectionSettled(bool byMouse)
    {
        if (LastText.Length > MaxStyledLength)
        {
            SetActiveFormat(new ActiveFormat());
            UpdateFocus();
            return;
        }
        if (!byMouse) RevealSettled();
        SetActiveFormat(MarkdownEditing.GetActiveFormat(LastText, CurrentSelection()));
        UpdateFocus();
        // Typing and arrow keys keep the caret line in the middle; a click leaves the text where the user put it.
        if (CentersCaret && !byMouse) CenterCaret();
    }

    private void SetActiveFormat(ActiveFormat format)
    {
        if (format.Equals(ActiveFormat)) return;
        ActiveFormat = format;
        ActiveFormatChanged?.Invoke(format);
    }

    // MARK: Commands

    /// <summary>Runs a core formatting action as one undo step and puts the keyboard back in the editor.</summary>
    private void Perform(Func<string, MarkdownRange, TextEdit?> make)
    {
        Sync();
        if (Box.IsReadOnly) return;
        if (make(LastText, CurrentSelection()) is { } edit) ApplyEdit(edit);
        Focus();
    }

    public void Toggle(InlineStyle style) => Perform((text, selection) => MarkdownEditing.ToggleInline(style, text, selection));

    public void Apply(LineStyle style) => Perform((text, selection) => MarkdownEditing.Apply(style, text, selection));

    public void InsertLink() => Perform(MarkdownEditing.Link);

    public void InsertCodeBlock() => Perform(MarkdownEditing.CodeBlock);

    public void InsertRule() => Perform(MarkdownEditing.HorizontalRule);

    public void InsertTable(int rows, int columns) => Perform((text, selection) => MarkdownTable.Insert(rows, columns, text, selection));

    public void ConvertToTable() => Perform(MarkdownTable.ConvertSelection);

    public void RunTableCommand(TableCommand command) => Perform((text, selection) => MarkdownTable.Perform(command, text, selection));

    /// <summary>Asks the host to show the table size picker.</summary>
    public void ShowTablePicker() => TablePickerRequested?.Invoke();

    /// <summary>Asks the host to show or hide the outline.</summary>
    public void ToggleOutline() => OutlineRequested?.Invoke();

    public List<OutlineHeading> Headings()
    {
        Sync();
        return MarkdownOutline.Headings(LastText);
    }

    // MARK: Return, Tab

    /// <summary>Return continues lists and quotes and adds table rows; anywhere else it is a plain line break.</summary>
    protected override void InsertNewline()
    {
        Sync();
        var selection = CurrentSelection();
        if ((MarkdownTable.Newline(LastText, selection) ?? MarkdownEditing.Newline(LastText, selection)) is { } edit)
        {
            ApplyEdit(edit);
            return;
        }
        base.InsertNewline();
    }

    /// <summary>Tab and Shift+Tab move between table cells and indent or outdent list items; elsewhere Tab inserts a tab.</summary>
    protected override bool HandleTab(bool backward)
    {
        Sync();
        var selection = CurrentSelection();
        if ((MarkdownTable.Tab(LastText, selection, backward) ?? MarkdownEditing.Indent(LastText, selection, outdent: backward)) is { } edit)
        {
            ApplyEdit(edit);
            return true;
        }
        // Shift+Tab elsewhere does nothing (it must not move the focus out of the editor); Tab is RichEdit's own.
        return backward;
    }

    // MARK: Links and tasks

    /// <summary>The character under `point` (client coordinates), null beside the text.</summary>
    private int? HitCharacter(Point point)
    {
        var index = Box.Document.GetRangeFromPoint(point, PointOptions.ClientCoordinates).StartPosition;
        if (index < 0 || index >= LastText.Length) return null;
        Box.Document.GetRange(index, index + 1).GetRect(PointOptions.ClientCoordinates, out var rect, out _);
        rect.X -= 1;
        rect.Width += 2;
        return rect.Contains(point) ? index : null;
    }

    private string? LinkAt(int index)
    {
        foreach (var span in links)
        {
            if (!span.Range.Contains(index)) continue;
            var raw = span.Kind.Kind == MarkdownKind.WikiLink ? "[[" + span.Kind.Target + "]]" : span.Kind.Url;
            if (!string.IsNullOrEmpty(raw)) return raw;
        }
        return null;
    }

    private string? LinkAt(Point point) => HitCharacter(point) is { } index ? LinkAt(index) : null;

    /// <summary>A click on a task box flips it (the caret stays); a click on a link, with or without Ctrl, follows it when it
    /// ends where it began and selects nothing (see docs/format.md, "Links").</summary>
    private void OnPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        press = null;
        contextLink = null;
        if (e.Pointer.PointerDeviceType == PointerDeviceType.Pen || ShowsSource) return;
        var point = e.GetCurrentPoint(Box);
        if (point.Properties.IsRightButtonPressed)
        {
            contextLink = LinkAt(point.Position);
            return;
        }
        if (!point.Properties.IsLeftButtonPressed || IsDown(VirtualKey.Shift) || IsDown(VirtualKey.Menu)) return;
        if (HitCharacter(point.Position) is not { } index) return;
        Sync();
        var text = LastText;
        if (!Box.IsReadOnly && index < text.Length && text[index] is '[' or ' ' or 'x' or 'X' or ']'
            && MarkdownEditing.ToggleTask(text, index) is { } toggle)
        {
            // Only the first click of a double click toggles (macOS: clickCount == 1).
            var now = Environment.TickCount64;
            var doubled = lastToggle is { } last && last.Index == index && now - last.Tick <= GetDoubleClickTime();
            lastToggle = (now, index);
            if (doubled) return;
            // RichEdit puts the caret under the click, before or after this handler: put it back where it was.
            var keep = currentSelection.Location >= index && currentSelection.End <= index + 3 && currentSelection.Length == 0
                ? previousSelection : currentSelection;
            ApplyEdit(toggle with { Selection = keep });
            Box.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => SetSelection(keep.Location, keep.End));
            return;
        }
        if (LinkAt(index) is { } link) press = (point.Position, link, IsDown(VirtualKey.Control), index);
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (press is not { } started) return;
        press = null;
        var position = e.GetCurrentPoint(Box).Position;
        if (Math.Abs(position.X - started.Position.X) > 4 || Math.Abs(position.Y - started.Position.Y) > 4) return;
        if (started.Ctrl) Box.Document.Selection.SetRange(started.Index, started.Index);
        else if (Box.Document.Selection.Length != 0) return;
        LinkActivated?.Invoke(started.Link);
    }

    // MARK: Context menu

    protected override void AddMenuItems(MenuFlyout menu)
    {
        var open = new MenuFlyoutItem { Text = Loc.Get("OpenLink"), Visibility = Visibility.Collapsed };
        open.Click += (_, _) =>
        {
            if (contextLink is { } link) LinkActivated?.Invoke(link);
        };
        var separator = new MenuFlyoutSeparator { Visibility = Visibility.Collapsed };
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(open);
        menu.Items.Add(separator);
        var format = new MenuFlyoutSubItem { Text = Loc.Get("MenuFormat") };
        var items = FormatCommands.Populate(format.Items, () => this);
        menu.Items.Add(format);
        menu.Opening += (_, _) =>
        {
            open.Visibility = separator.Visibility = contextLink is null ? Visibility.Collapsed : Visibility.Visible;
            format.IsEnabled = IsEditable;
            foreach (var item in items) item.IsEnabled = IsEditable;
        };
    }
}
