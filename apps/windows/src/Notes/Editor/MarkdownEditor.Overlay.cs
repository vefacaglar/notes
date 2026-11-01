using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using NotesCore;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.UI;

namespace Notes.Editor;

/// <summary>What the Markdown view draws around the text: code bands with their language label and copy button, table grids,
/// bullets, quote bars, rules and inline images. Positions come from RichEdit's layout (see <see cref="TextEditor.RectOf"/>).</summary>
internal sealed partial class MarkdownEditor
{
    private sealed class Pool<T>(Canvas canvas, Func<T> create) where T : UIElement
    {
        private readonly List<T> items = [];
        private int used;

        public void Begin() => used = 0;

        public T Next()
        {
            if (used == items.Count)
            {
                var item = create();
                items.Add(item);
                canvas.Children.Add(item);
            }
            var element = items[used++];
            if (element.Visibility != Visibility.Visible) element.Visibility = Visibility.Visible;
            return element;
        }

        public void End()
        {
            for (var i = used; i < items.Count; i++)
            {
                if (items[i].Visibility != Visibility.Collapsed) items[i].Visibility = Visibility.Collapsed;
            }
        }

        public void Clear()
        {
            Begin();
            End();
        }
    }

    private readonly record struct Band(MarkdownRange Block, double Left, double Right, double Top, double Bottom);

    private Pool<Border> bandPool = null!, tablePool = null!, imagePool = null!;
    private Pool<Rectangle> linePool = null!;
    private Pool<TextBlock> textPool = null!;
    private Button copyButton = null!;
    private FontIcon copyIcon = null!;
    private readonly List<Band> visibleBlocks = [];
    private MarkdownRange? hoveredBlock;
    private Point? lastPointer;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? copiedTimer;

    private static readonly Dictionary<Color, SolidColorBrush> Brushes = [];

    private static SolidColorBrush Solid(Color color)
    {
        if (!Brushes.TryGetValue(color, out var brush)) Brushes[color] = brush = new SolidColorBrush(color);
        return brush;
    }

    private static Color WithAlpha(Color color, double alpha) => Color.FromArgb((byte)Math.Round(color.A * alpha), color.R, color.G, color.B);

    private void InitializeOverlay()
    {
        bandPool = new Pool<Border>(UnderCanvas, () => new Border { CornerRadius = new CornerRadius(4) });
        tablePool = new Pool<Border>(UnderCanvas, () => new Border { CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1) });
        linePool = new Pool<Rectangle>(OverCanvas, () => new Rectangle { IsHitTestVisible = false });
        textPool = new Pool<TextBlock>(OverCanvas, () => new TextBlock { IsHitTestVisible = false, TextAlignment = TextAlignment.Center });
        imagePool = new Pool<Border>(OverCanvas, () => new Border { IsHitTestVisible = false, CornerRadius = new CornerRadius(4), Background = new ImageBrush { Stretch = Stretch.Fill } });

        copyIcon = new FontIcon { Glyph = "", FontSize = 12 };
        copyButton = new Button
        {
            Content = copyIcon,
            Width = 22,
            Height = 22,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(4),
            BorderThickness = new Thickness(0),
            Background = Solid(Microsoft.UI.Colors.Transparent),
            Visibility = Visibility.Collapsed,
            IsTabStop = false,
            AllowFocusOnInteraction = false,
        };
        ToolTipService.SetToolTip(copyButton, Loc.Get("CopyCode"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(copyButton, Loc.Get("CopyCode"));
        copyButton.Click += (_, _) => CopyHoveredCode();
        OverCanvas.Children.Add(copyButton);

        var moved = new Microsoft.UI.Xaml.Input.PointerEventHandler((_, e) =>
        {
            lastPointer = e.GetCurrentPoint(Host).Position;
            UpdateCopyButton();
        });
        Host.AddHandler(UIElement.PointerMovedEvent, moved, true);
        Host.AddHandler(UIElement.PointerEnteredEvent, moved, true);
        Host.AddHandler(UIElement.PointerExitedEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler((_, _) =>
        {
            lastPointer = null;
            UpdateCopyButton();
        }), true);
        InitializeImageDrop();
    }

    private void StopOverlay()
    {
        copiedTimer?.Stop();
    }

    private void ClearOverlay()
    {
        if (bandPool is null) return;
        foreach (var pool in new[] { bandPool, tablePool, imagePool }) pool.Clear();
        linePool.Clear();
        textPool.Clear();
        visibleBlocks.Clear();
        UpdateCopyButton();
    }

    // MARK: Copy button

    private void UpdateCopyButton()
    {
        if (lastPointer is { } pointer && !ShowsSource)
        {
            var y = pointer.Y + ScrollY;
            foreach (var band in visibleBlocks)
            {
                if (pointer.X < band.Left || pointer.X > band.Right || y < band.Top || y > band.Bottom) continue;
                hoveredBlock = band.Block;
                Canvas.SetLeft(copyButton, band.Right - 8 - copyButton.Width);
                Canvas.SetTop(copyButton, band.Top + 3);
                copyButton.Foreground = Solid(Palette.Secondary);
                copyButton.Visibility = Visibility.Visible;
                return;
            }
        }
        hoveredBlock = null;
        if (copyButton.Visibility != Visibility.Collapsed) copyButton.Visibility = Visibility.Collapsed;
    }

    /// <summary>Copies the code of the block under the pointer: the lines between the fences, as plain text.</summary>
    private void CopyHoveredCode()
    {
        if (hoveredBlock is not { } block) return;
        var package = new DataPackage();
        package.SetText(MarkdownCodeBlock.Code(LastText, block));
        try
        {
            Clipboard.SetContent(package);
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or UnauthorizedAccessException)
        {
            return;
        }
        // The check mark shows for 1.5 seconds.
        copyIcon.Glyph = "";
        ToolTipService.SetToolTip(copyButton, Loc.Get("Copied"));
        copiedTimer ??= Box.DispatcherQueue.CreateTimer();
        copiedTimer.Stop();
        copiedTimer.Interval = TimeSpan.FromMilliseconds(1500);
        copiedTimer.IsRepeating = false;
        copiedTimer.Tick -= ResetCopied;
        copiedTimer.Tick += ResetCopied;
        copiedTimer.Start();
    }

    private void ResetCopied(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args)
    {
        sender.Stop();
        copyIcon.Glyph = "";
        ToolTipService.SetToolTip(copyButton, Loc.Get("CopyCode"));
    }

    // MARK: Drawing

    protected override void RenderOverlay()
    {
        var text = LastText;
        if (ShowsSource || text.Length > MaxStyledLength || spans.Count == 0 && imageSlots.Count == 0 && tables.Count == 0 && codeBlocks.Count == 0)
        {
            ClearOverlay();
            return;
        }
        // A selection too long to reveal as a whole follows the viewport.
        if (HidesMarkers && CurrentSelection().Length > LargeSelection) RevealSettled();
        var (first, last) = VisibleCharacters(ViewportHeight);
        var offset = ScrollY;
        foreach (var pool in new[] { bandPool, tablePool, imagePool }) pool.Begin();
        linePool.Begin();
        textPool.Begin();
        visibleBlocks.Clear();
        var palette = Palette;
        DrawCodeBlocks(text, first, last, offset, palette);
        DrawTables(first, last, offset, palette);
        DrawDecorations(text, first, last, offset, palette);
        DrawImages(first, last, offset);
        foreach (var pool in new[] { bandPool, tablePool, imagePool }) pool.End();
        linePool.End();
        textPool.End();
        UpdateCopyButton();
    }

    private void DrawCodeBlocks(string text, int first, int last, double offset, EditorPalette palette)
    {
        if (codeBlocks.Count == 0) return;
        var left = Math.Max(0, Box.Padding.Left - 6);
        var width = Math.Max(0, Box.ActualWidth - left - Math.Max(0, Box.Padding.Right - 6));
        int lo = 0, hi = codeBlocks.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (codeBlocks[mid].End <= first) lo = mid + 1;
            else hi = mid;
        }
        for (var i = lo; i < codeBlocks.Count; i++)
        {
            var block = codeBlocks[i];
            if (block.Location > last) break;
            if (block.End > text.Length) continue;
            var firstEnd = text.IndexOf('\n', block.Location, block.Length);
            if (firstEnd < 0) firstEnd = block.End;
            // The paragraph marks locate the first and the last line even when the fences are hidden.
            if (RectOf(firstEnd, firstEnd + 1) is not { } top || RectOf(block.End, block.End + 1) is not { } bottom) continue;
            var y1 = top.Y + offset;
            var y2 = bottom.Y + bottom.Height + offset;
            var band = bandPool.Next();
            band.Background = Solid(palette.CodeBackground);
            band.Width = width;
            band.Height = Math.Max(0, y2 - y1);
            Canvas.SetLeft(band, left);
            Canvas.SetTop(band, y1);
            visibleBlocks.Add(new Band(block, left, left + width, y1, y2));
            // The language of a hidden opening fence at the block's top-left.
            if (HidesMarkers && !shownMarkers.Contains(new MarkdownRange(block.Location, firstEnd - block.Location))
                && MarkdownRendering.FenceLabel(text, block) is { Length: > 0 } label)
            {
                var caption = textPool.Next();
                caption.Text = label;
                caption.FontSize = 11;
                caption.TextAlignment = TextAlignment.Left;
                caption.Width = double.NaN;
                caption.Height = double.NaN;
                caption.LineHeight = 0;
                caption.Foreground = Solid(palette.Secondary);
                caption.Opacity = 1;
                Canvas.SetLeft(caption, Box.Padding.Left + 4);
                Canvas.SetTop(caption, y1 + Math.Max(0, (top.Height - 15) / 2));
            }
        }
    }

    private void DrawTables(int first, int last, double offset, EditorPalette palette)
    {
        if (grids.Count == 0) return;
        var line = WithAlpha(palette.Tertiary, 0.7);
        foreach (var table in tables)
        {
            if (table.End < first || table.Location > last) continue;
            if (!grids.TryGetValue(table.Location, out var grid) || !grid.Rendered || grid.Rows.Count == 0) continue;
            var rows = grid.Rows;
            if (RectOf(rows[0].End, rows[0].End + 1) is not { } head || RectOf(rows[^1].End, rows[^1].End + 1) is not { } tail) continue;
            var x = Box.Padding.Left;
            if (RectOf(grid.FirstCellStart, grid.FirstCellStart + 1) is { } cell) x = cell.X - grid.FirstCellOffset;
            var width = grid.Edges[^1];
            var top = head.Y + offset - RowGap / 2;
            var bottom = tail.Y + tail.Height + offset + RowGap / 2;
            var outline = tablePool.Next();
            outline.BorderBrush = Solid(line);
            outline.Width = width;
            outline.Height = Math.Max(0, bottom - top);
            Canvas.SetLeft(outline, x);
            Canvas.SetTop(outline, top);
            // Thin lines between the rows, a stronger one under the header.
            double? previousBottom = null;
            for (var i = 0; i < rows.Count; i++)
            {
                var row = rows[i];
                if (row.End < first) continue;
                if (RectOf(row.End, row.End + 1) is not { } rect) continue;
                if (i > 0)
                {
                    previousBottom ??= RectOf(rows[i - 1].End, rows[i - 1].End + 1) is { } before ? before.Y + before.Height : null;
                    if (previousBottom is { } above)
                    {
                        var rule = linePool.Next();
                        rule.Fill = Solid(i == 1 ? line : WithAlpha(line, 0.5));
                        rule.Width = width;
                        rule.Height = 1;
                        rule.Opacity = 1;
                        Canvas.SetLeft(rule, x);
                        Canvas.SetTop(rule, (above + rect.Y) / 2 + offset);
                    }
                }
                previousBottom = rect.Y + rect.Height;
                if (row.Location > last) break;
            }
        }
    }

    private void DrawDecorations(string text, int first, int last, double offset, EditorPalette palette)
    {
        if (!HidesMarkers) return;
        var bright = AppSettings.FocusMode ? this.bright : null;
        for (var k = MarkdownRendering.FirstIndex(spanReach, first); k < spans.Count; k++)
        {
            var span = spans[k];
            if (span.Range.Location > last) break;
            if (span.Range.End < first || shownMarkers.Contains(span.Range) || MarkdownRendering.DecorationOf(span, text) is not { } kind) continue;
            if (RectOf(span.Range.Location, span.Range.Location + 1) is not { } rect) continue;
            var dim = bright is { } paragraph && !(span.Range.Location >= paragraph.Location && span.Range.Location <= paragraph.End) ? 0.3 : 1;
            var y = rect.Y + offset;
            switch (kind)
            {
                case MarkdownDecoration.Bullet:
                    var bullet = textPool.Next();
                    bullet.Text = "•";
                    bullet.FontSize = EditorFonts.Scaled(15);
                    bullet.TextAlignment = TextAlignment.Center;
                    bullet.Width = Math.Max(rect.Width, 6);
                    bullet.LineHeight = rect.Height;
                    bullet.Height = rect.Height;
                    bullet.Foreground = Solid(palette.Secondary);
                    bullet.Opacity = dim;
                    Canvas.SetLeft(bullet, rect.X + (rect.Width - bullet.Width) / 2);
                    Canvas.SetTop(bullet, y);
                    break;
                case MarkdownDecoration.QuoteBar:
                    var bar = linePool.Next();
                    bar.Fill = Solid(palette.Tertiary);
                    bar.Width = 2;
                    bar.Height = rect.Height + BaseSpaceAfter / Pt;
                    bar.Opacity = dim;
                    Canvas.SetLeft(bar, rect.X + 1);
                    Canvas.SetTop(bar, y);
                    break;
                default:
                    var rule = linePool.Next();
                    rule.Fill = Solid(palette.Tertiary);
                    rule.Width = TextWidth;
                    rule.Height = 1;
                    rule.Opacity = dim;
                    Canvas.SetLeft(rule, Box.Padding.Left);
                    Canvas.SetTop(rule, y + rect.Height / 2);
                    break;
            }
        }
    }

    private void DrawImages(int first, int last, double offset)
    {
        if (imageSlots.Count == 0) return;
        var cache = InlineImageCache.Shared;
        int lo = 0, hi = imageSlots.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (imageSlots[mid].Paragraph.End <= first) lo = mid + 1;
            else hi = mid;
        }
        // Images of lines above the window can still reach into it: look back while their lines are within the tallest stack.
        var start = lo;
        while (start > 0 && RectOf(imageSlots[start - 1].Anchor, imageSlots[start - 1].Anchor + 1) is { } above
            && above.Y + offset + InlineImageLayout.MaxHeight * 3 > offset)
        {
            start--;
        }
        for (var i = start; i < imageSlots.Count; i++)
        {
            var slot = imageSlots[i];
            if (slot.Paragraph.Location > last) break;
            if (slot.Paths.Count != slot.Destinations.Count || RectOf(slot.Anchor, slot.Anchor + 1) is not { } rect) continue;
            var y = rect.Y + rect.Height + offset + InlineImageLayout.Gap;
            for (var k = 0; k < slot.Paths.Count; k++)
            {
                var (width, height) = slot.Sizes[k];
                if (slot.Paths[k] is not { } path || height <= 0 || cache.CachedImage(path) is not { } bitmap) continue;
                var frame = imagePool.Next();
                var brush = (ImageBrush)frame.Background;
                if (!ReferenceEquals(brush.ImageSource, bitmap)) brush.ImageSource = bitmap;
                frame.Width = width;
                frame.Height = height;
                Canvas.SetLeft(frame, Box.Padding.Left);
                Canvas.SetTop(frame, y);
                y += height + InlineImageLayout.Gap;
            }
        }
    }
}
