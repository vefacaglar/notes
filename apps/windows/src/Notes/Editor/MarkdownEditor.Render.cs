using Microsoft.UI;
using Microsoft.UI.Text;
using NotesCore;

namespace Notes.Editor;

/// <summary>
/// Rendering of the Markdown view: markers hidden except where the selection is (character formatting "hidden", the text itself
/// is never touched), tables laid out in columns with character spacing, highlighted fenced code, room for inline images.
/// What is drawn (bands, grids, bullets, images) lives in <c>MarkdownEditor.Overlay.cs</c>.
/// </summary>
internal sealed partial class MarkdownEditor
{
    /// <summary>A selection longer than this reveals only the lines around the viewport.</summary>
    private const int LargeSelection = 20_000;
    /// <summary>Cell padding on each side of a rendered table's cells, and the gap between its rows (layout pixels).</summary>
    private const double TablePad = 12, RowGap = 6;
    /// <summary>Points per layout pixel: RichEdit measures spacing, indents and sizes in points.</summary>
    private const double Pt = 0.75;

    private List<MarkdownRange> tables = [];
    private Dictionary<int, TableGridInfo> grids = [];
    /// <summary>The tables the selection touches: shown as source so they can be edited.</summary>
    private HashSet<MarkdownRange> shownTables = [];
    /// <summary>Width the tables may use, as of the last styling pass.</summary>
    private double containerWidth;
    private int measureRetries;
    private List<ImageSlot> imageSlots = [];
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? refitTimer;

    /// <summary>How a rendered pipe table is laid out: what the overlay needs to draw its grid behind the text.</summary>
    private sealed record TableGridInfo(MarkdownRange Range, double NaturalWidth, bool Rendered, List<MarkdownRange> Rows, double[] Edges,
        int FirstCellStart, double FirstCellOffset)
    {
        /// <summary>The same layout after the table moved to <paramref name="to"/> (text was inserted or removed above it).</summary>
        public TableGridInfo Moved(MarkdownRange to)
        {
            var delta = to.Location - Range.Location;
            return delta == 0
                ? this with { Range = to }
                : this with { Range = to, Rows = [.. Rows.Select(r => r with { Location = r.Location + delta })], FirstCellStart = FirstCellStart + delta };
        }
    }

    /// <summary>The `![](…)` images of one source line: shown stacked under it.</summary>
    private sealed class ImageSlot
    {
        public MarkdownRange Paragraph;
        /// <summary>The line's paragraph mark, which locates its last line fragment.</summary>
        public int Anchor;
        public List<string> Destinations = [];
        public List<string?> Paths = [];
        public List<(double Width, double Height)> Sizes = [];
    }

    private void InitializeRendering()
    {
        InitializeOverlay();
        Note.PathChanged += OnNotePathChanged;
        // Images that changed on disk while another app was in front are loaded again.
        Box.GotFocus += (_, _) =>
        {
            if (imageSlots.Count == 0 || IsComposing || !IsReady) return;
            InlineImageCache.Shared.ExpireChecks();
            Styled(ApplyImageSpacing);
        };
    }

    protected override void OnDetach()
    {
        Note.PathChanged -= OnNotePathChanged;
        refitTimer?.Stop();
        StopOverlay();
    }

    private void OnNotePathChanged()
    {
        if (!IsReady || imageSlots.Count == 0 || IsComposing) return;
        Styled(ApplyImageSpacing);
    }

    /// <summary>Forgets everything the rendering holds (source view, text too long to style).</summary>
    private void ResetRendering()
    {
        tables = [];
        grids = [];
        shownTables = [];
        imageSlots = [];
        ClearOverlay();
    }

    // MARK: Reveal

    /// <summary>The lines the selection covers; for a huge selection only those around the viewport.</summary>
    private MarkdownRange RevealRange()
    {
        var text = LastText;
        var reveal = MarkdownRendering.LineRange(CurrentSelection(), text);
        if (reveal.Length <= LargeSelection) return reveal;
        var (first, last) = VisibleCharacters(ViewportHeight);
        var visible = MarkdownRendering.LineRange(new MarkdownRange(first, Math.Max(0, last - first)), text);
        var start = Math.Max(reveal.Location, visible.Location);
        return new MarkdownRange(start, Math.Max(0, Math.Min(reveal.End, visible.End) - start));
    }

    /// <summary>Re-hides the markers the caret left and shows those it touches now. Only the lines of the markers that changed
    /// are styled again.</summary>
    private void RevealSettled()
    {
        if (!IsReady || !HidesMarkers || PendingEdit is not null || NeedsFullRestyle || IsComposing || ShowsSource) return;
        var text = LastText;
        if (text.Length > MaxStyledLength) return;
        var reveal = RevealRange();
        var shown = MarkdownRendering.ShownMarkers(spans, spanReach, [CurrentSelection()], reveal, text, Reading);
        var shownNow = TablesShown(reveal);
        revealed = reveal;
        if (shown.SetEquals(shownMarkers) && shownNow.SetEquals(shownTables)) return;
        var changed = shown.Except(shownMarkers).Concat(shownMarkers.Except(shown)).Where(r => r.End <= text.Length);
        var changedTables = shownNow.Except(shownTables).Concat(shownTables.Except(shownNow)).Where(r => r.End <= text.Length);
        shownMarkers = shown;
        shownTables = shownNow;
        containerWidth = TextWidth;
        var lines = Merged(changed.Select(r => MarkdownRendering.LineRange(r, text)).Concat(changedTables));
        if (lines.Count == 0) return;
        var targets = Coalesced(Merged(Expanded(lines, RenderedTables())));
        Styled(() =>
        {
            foreach (var target in targets) ApplyTarget(target);
            if (AppSettings.FocusMode) Dim(targets);
            // Restyling a line resets its paragraph format, which holds the room reserved for its images.
            if (imageSlots.Count > 0) ApplyImageSpacing();
        });
        InvalidateOverlay();
    }

    // MARK: Ranges

    private static bool Intersects(MarkdownRange a, MarkdownRange b) => a.Location < b.End && b.Location < a.End;

    /// <summary>Sorted, with overlapping or touching ranges joined.</summary>
    private static List<MarkdownRange> Merged(IEnumerable<MarkdownRange> ranges)
    {
        var result = new List<MarkdownRange>();
        foreach (var r in ranges.OrderBy(r => r.Location))
        {
            if (result.Count > 0 && r.Location <= result[^1].End)
            {
                var last = result[^1];
                result[^1] = new MarkdownRange(last.Location, Math.Max(last.End, r.End) - last.Location);
            }
            else
            {
                result.Add(r);
            }
        }
        return result;
    }

    /// <summary>Lines close to each other become one range (at most 4000 UTF-16 units apart): one formatting pass over it is far
    /// cheaper than many small ones.</summary>
    private static List<MarkdownRange> Coalesced(List<MarkdownRange> lines)
    {
        var result = new List<MarkdownRange>();
        foreach (var line in lines)
        {
            if (result.Count > 0 && line.Location - result[^1].End <= 4000)
            {
                var last = result[^1];
                result[^1] = new MarkdownRange(last.Location, Math.Max(last.End, line.End) - last.Location);
            }
            else
            {
                result.Add(line);
            }
        }
        return result;
    }

    /// <summary>`ranges` with every table they touch added whole, so a table is always styled as a unit.</summary>
    private static List<MarkdownRange> Expanded(List<MarkdownRange> ranges, List<MarkdownRange> tables)
    {
        var result = new List<MarkdownRange>(ranges);
        foreach (var table in tables)
        {
            if (ranges.Any(r => Intersects(r, table))) result.Add(table);
        }
        return result;
    }

    /// <summary>A range from before an edit, moved to post-edit coordinates and widened to whole lines.</summary>
    private static MarkdownRange ShiftLines(MarkdownRange range, (int Start, int End, int Delta) edit, string text)
    {
        // A range that ends where the edit starts is before it (unlike a code block, which an edit at its end extends).
        var moved = range.End <= edit.Start ? range : Shift([range], edit).First();
        var location = Math.Clamp(moved.Location, 0, text.Length);
        return MarkdownStyler.RestyleRange(new MarkdownRange(location, Math.Clamp(moved.Length, 0, text.Length - location)), text);
    }

    // MARK: Styling a range

    /// <summary>Styles `target` from scratch: base format, then the spans (markers hidden or drawn), highlighted code, tables.</summary>
    private void ApplyTarget(MarkdownRange target)
    {
        ApplyBase(target.Location, target.End);
        var text = LastText;
        var hides = HidesMarkers;
        List<MarkdownRange>? laidOut = null;
        for (var k = MarkdownRendering.FirstIndex(spanReach, target.Location); k < spans.Count; k++)
        {
            var span = spans[k];
            if (span.Range.Location >= target.End) break;
            var start = Math.Max(span.Range.Location, target.Location);
            var end = Math.Min(span.Range.End, target.End);
            if (end <= start) continue;
            if (span.Kind.Kind == MarkdownKind.Table)
            {
                if (start == span.Range.Location && end == span.Range.End) (laidOut ??= []).Add(span.Range);
                continue;
            }
            var hidden = hides && !shownMarkers.Contains(span.Range);
            var decoration = hidden ? MarkdownRendering.DecorationOf(span, text) : null;
            if (hidden && span.Kind.Kind == MarkdownKind.Marker && decoration is null)
            {
                Range(start, end).CharacterFormat.Hidden = FormatEffect.On;
                continue;
            }
            Apply(span.Kind, start, end);
            // Drawn by the overlay instead: same width, invisible glyph.
            if (decoration is not null) Range(start, end).CharacterFormat.ForegroundColor = Colors.Transparent;
            if (span.Kind.Kind == MarkdownKind.CodeBlock) HighlightCode(span.Range, target);
        }
        if (laidOut is not null)
        {
            foreach (var table in laidOut) LayoutTable(table);
        }
    }

    /// <summary>Syntax colours for a fenced block whose info string names a known language (```swift, ```json…).</summary>
    private void HighlightCode(MarkdownRange block, MarkdownRange target)
    {
        var text = LastText;
        if (MarkdownRendering.FencedCode(text, block) is not { } fenced) return;
        var (inner, language) = fenced;
        if (language is CodeLanguage.PlainText or CodeLanguage.Markdown || !Intersects(inner, target)) return;
        var palette = Palette;
        foreach (var span in CodeHighlighter.Spans(text.Substring(inner.Location, inner.Length), language))
        {
            var start = Math.Max(span.Location + inner.Location, target.Location);
            var end = Math.Min(span.End + inner.Location, target.End);
            if (end > start) Range(start, end).CharacterFormat.ForegroundColor = palette.Code(span.Kind).Color;
        }
    }

    /// <summary>The dim of focus mode would show the glyphs of drawn markers over their drawings: keep them clear.</summary>
    private void ClearDecorationGlyphs(int start, int end)
    {
        if (end <= start || !HidesMarkers) return;
        var text = LastText;
        for (var k = MarkdownRendering.FirstIndex(spanReach, start); k < spans.Count && spans[k].Range.Location < end; k++)
        {
            var span = spans[k];
            if (span.Range.End <= start || shownMarkers.Contains(span.Range) || MarkdownRendering.DecorationOf(span, text) is null) continue;
            Range(Math.Max(start, span.Range.Location), Math.Min(end, span.Range.End)).CharacterFormat.ForegroundColor = Colors.Transparent;
        }
    }

    // MARK: Tables

    /// <summary>Tables the selection touches stay source (none in reading mode, which renders them always).</summary>
    private HashSet<MarkdownRange> TablesShown(MarkdownRange? reveal) =>
        reveal is not { } lines || Reading ? [] : [.. tables.Where(t => Intersects(t, lines))];

    /// <summary>Tables that are laid out as tables now: only those must be styled as a unit.</summary>
    private List<MarkdownRange> RenderedTables() =>
        HidesMarkers ? [.. tables.Where(t => !shownTables.Contains(t))] : [];

    /// <summary>
    /// Renders a table in place: the pipes, the delimiter row and the spaces around the cells are hidden (still real text), and
    /// every cell is placed in its column by the character spacing after the previous cell's last character (or the paragraph
    /// indent for the first column). The overlay draws the grid behind it from the stored <see cref="TableGridInfo"/>. A table the
    /// selection touches, or wider than the text column, keeps its source styling.
    /// </summary>
    private void LayoutTable(MarkdownRange range)
    {
        grids.Remove(range.Location);
        var text = LastText;
        if (!HidesMarkers || shownTables.Contains(range) || range.End > text.Length) return;
        if (MarkdownTable.GetGrid(text.Substring(range.Location, range.Length), 0, range.Location) is not { } grid) return;

        // Cell widths come from RichEdit's own layout of the styled cells (bold header, code, hidden emphasis markers).
        var measurable = true;
        var widths = new List<IReadOnlyList<double>>();
        foreach (var row in grid.Rows)
        {
            var rowWidths = new List<double>();
            foreach (var cell in row.Cells)
            {
                if (cell.Length == 0)
                {
                    rowWidths.Add(0);
                    continue;
                }
                if (RectOf(cell.Location, cell.End) is { Width: > 0 } rect) rowWidths.Add(rect.Width);
                else
                {
                    measurable = false;
                    rowWidths.Add(0);
                }
            }
            widths.Add(rowWidths);
        }
        var rows = grid.Rows.Select(r => r.Line).ToList();
        if (!measurable)
        {
            // Not laid out yet: show the source for now and try again a moment later.
            grids[range.Location] = new TableGridInfo(range, double.PositiveInfinity, false, rows, [0], range.Location, 0);
            if (measureRetries++ < 3) RefitSoon();
            return;
        }
        measureRetries = 0;
        var columns = TableMetrics.ColumnWidths(widths, grid.Columns);
        var edges = new double[columns.Length + 1];
        for (var c = 0; c < columns.Length; c++) edges[c + 1] = edges[c] + columns[c] + 2 * TablePad;
        var natural = edges[^1];
        var rendered = natural <= containerWidth;
        var firstStart = range.Location;
        var firstOffset = 0.0;
        var firstFound = false;

        if (rendered)
        {
            for (var r = 0; r < grid.Rows.Count; r++)
            {
                var row = grid.Rows[r];
                var cursor = row.Line.Location;
                double indent = 0, pending = 0;
                (int Start, int End)? carrier = null;
                for (var c = 0; c < row.Cells.Count; c++)
                {
                    var cell = row.Cells[c];
                    var alignment = c < grid.Alignments.Count ? grid.Alignments[c] : TableAlignment.None;
                    var slack = TableMetrics.Slack(widths[r][c], columns[c], alignment);
                    pending += TablePad + slack.Before;
                    if (cell.Length > 0)
                    {
                        if (cell.Location > cursor) Range(cursor, cell.Location).CharacterFormat.Hidden = FormatEffect.On;
                        cursor = cell.End;
                        if (carrier is { } previous) Range(previous.Start, previous.End).CharacterFormat.Spacing = (float)(pending * Pt);
                        else indent += pending;
                        if (r == 0 && !firstFound)
                        {
                            firstFound = true;
                            firstStart = cell.Location;
                            firstOffset = indent;
                        }
                        pending = 0;
                        var last = cell.End - 1;
                        var from = last > cell.Location && char.IsLowSurrogate(text[last]) && char.IsHighSurrogate(text[last - 1]) ? last - 1 : last;
                        carrier = (from, cell.End);
                    }
                    pending += slack.After + TablePad;
                }
                if (row.Line.End > cursor) Range(cursor, row.Line.End).CharacterFormat.Hidden = FormatEffect.On;
                var paragraph = Range(row.Line.Location, row.Line.End + 1).ParagraphFormat;
                var lastRow = r == grid.Rows.Count - 1;
                paragraph.SetIndents(0, (float)(indent * Pt), 0);
                paragraph.SetLineSpacing(LineSpacingRule.Multiple, 1);
                paragraph.SpaceBefore = r == 0 ? (float)(8 * Pt) : 0;
                paragraph.SpaceAfter = (float)((lastRow ? 14 : RowGap) * Pt);
            }
            // The delimiter row takes no height.
            var delimiter = grid.Delimiter;
            Range(delimiter.Location, delimiter.End).CharacterFormat.Hidden = FormatEffect.On;
            var mark = Range(delimiter.Location, delimiter.End + 1);
            mark.CharacterFormat.Size = 1;
            mark.ParagraphFormat.SetLineSpacing(LineSpacingRule.Exactly, 1);
            mark.ParagraphFormat.SpaceBefore = 0;
            mark.ParagraphFormat.SpaceAfter = 0;
        }
        grids[range.Location] = new TableGridInfo(range, natural, rendered, rows, edges, firstStart, firstOffset);
    }

    protected override void BoxResized() => RefitSoon();

    private void RefitSoon()
    {
        if (!IsReady) return;
        if (refitTimer is null)
        {
            refitTimer = Box.DispatcherQueue.CreateTimer();
            refitTimer.Interval = TimeSpan.FromMilliseconds(120);
            refitTimer.IsRepeating = false;
            refitTimer.Tick += (_, _) => RefitTables();
        }
        refitTimer.Stop();
        refitTimer.Start();
    }

    /// <summary>A narrower or wider text column can flip a table between rendered and source, and changes the size of images:
    /// those are styled again.</summary>
    private void RefitTables()
    {
        if (!IsReady || Box.XamlRoot is null || ShowsSource || PendingEdit is not null || NeedsFullRestyle || IsComposing
            || LastText.Length > MaxStyledLength) return;
        var changed = Math.Abs(containerWidth - TextWidth) > 0.5;
        containerWidth = TextWidth;
        var stale = !HidesMarkers ? [] : tables.Where(t => grids.TryGetValue(t.Location, out var g)
            && ((g.NaturalWidth <= containerWidth) != g.Rendered || double.IsInfinity(g.NaturalWidth))).ToList();
        if (stale.Count > 0 || (changed && imageSlots.Count > 0))
        {
            Styled(() =>
            {
                foreach (var table in stale) ApplyTarget(table);
                if (AppSettings.FocusMode && stale.Count > 0) Dim(stale);
                if (imageSlots.Count > 0) ApplyImageSpacing();
            });
        }
        InvalidateOverlay();
    }

    // MARK: Images

    private string? NoteFolder => Note.IsDraft ? null : System.IO.Path.GetDirectoryName(Note.Path);

    /// <summary>Finds the `![](…)` lines of the text (after a restyle) and reserves room under them.</summary>
    private void UpdateImageSlots()
    {
        var text = LastText;
        var references = MarkdownImages.References(text, MarkdownImages.CodeRanges(spans));
        var slots = new List<ImageSlot>();
        foreach (var reference in references)
        {
            var line = MarkdownRendering.LineRange(reference.Range, text);
            if (slots.Count > 0 && slots[^1].Paragraph == line)
            {
                slots[^1].Destinations.Add(reference.Destination);
                continue;
            }
            var endsWithBreak = line.End > line.Location && text[line.End - 1] == '\n';
            slots.Add(new ImageSlot { Paragraph = line, Anchor = line.End - (endsWithBreak ? 1 : 0), Destinations = [reference.Destination] });
        }
        if (slots.Count == 0 && imageSlots.Count == 0) return;
        imageSlots = slots;
        ApplyImageSpacing();
    }

    /// <summary>
    /// Resolves the images (reading them in the background), reserves their height as paragraph spacing under their lines and
    /// leaves the drawing to the overlay. Only paragraph formatting changes; the text and undo history are untouched.
    /// </summary>
    private void ApplyImageSpacing()
    {
        var folder = NoteFolder;
        var cache = InlineImageCache.Shared;
        cache.BeginPass();
        var width = TextWidth;
        var length = LastText.Length;
        foreach (var slot in imageSlots)
        {
            slot.Paths = [.. slot.Destinations.Select(d => MarkdownImages.FilePath(d, folder) is { } path && (IsLocalDrive(path) || MarkdownImages.IsInside(path, folder)) ? path : null)];
            slot.Sizes = [.. slot.Paths.Select(p => p is not null && cache.Size(p, this, ImagesLoaded) is { } natural
                ? InlineImageLayout.Size(natural.Width, natural.Height, width) : (0.0, 0.0))];
            if (slot.Paragraph.End > length || IsComposing) continue;
            var spacing = (float)(BaseSpaceAfter + InlineImageLayout.ReservedHeight(slot.Sizes.Select(s => s.Height)) * Pt);
            var format = Range(slot.Paragraph.Location, slot.Paragraph.Location).ParagraphFormat;
            if (Math.Abs(format.SpaceAfter - spacing) > 0.01f) format.SpaceAfter = spacing;
        }
        InvalidateOverlay();
    }

    private static readonly Dictionary<string, bool> LocalRoots = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Images come from local drives only: a mapped network drive would be reached over the network.</summary>
    private static bool IsLocalDrive(string path)
    {
        var root = System.IO.Path.GetPathRoot(path);
        if (string.IsNullOrEmpty(root)) return false;
        if (LocalRoots.TryGetValue(root, out var local)) return local;
        try { local = new DriveInfo(root).DriveType != DriveType.Network; }
        catch (Exception e) when (e is ArgumentException or IOException) { local = false; }
        return LocalRoots[root] = local;
    }

    /// <summary>An image finished loading (or changed on disk): its room is reserved and it is drawn.</summary>
    private void ImagesLoaded()
    {
        if (!IsReady || IsComposing || imageSlots.Count == 0) return;
        Styled(ApplyImageSpacing);
    }
}
