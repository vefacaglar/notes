using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using NotesCore;
using Windows.Foundation;

namespace Notes.Editor;

/// <summary>Editor commands and view settings shared by both editors: applying core edits, reading mode, find, zoom, the
/// current-line band, revealing a position and keeping the caret line centred.</summary>
internal abstract partial class TextEditor
{
    private readonly Border band = new()
    {
        Visibility = Visibility.Collapsed,
        VerticalAlignment = VerticalAlignment.Top,
        IsHitTestVisible = false,
        CornerRadius = new CornerRadius(4),
    };
    private readonly Grid underHost = new() { IsHitTestVisible = false };
    private readonly Grid overHost = new();
    private readonly TranslateTransform underShift = new(), overShift = new();
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? overlayTimer;
    private bool overlayStale;
    private bool reading;
    private bool pointerDown;
    private bool selectionQueued;
    /// <summary>A setting changed while the editor was out of the visual tree: applied when it comes back.</summary>
    private bool settingsStale;

    /// <summary>Raised when the editor became editable or read-only (the file's state, reading mode).</summary>
    public event Action? ReadOnlyStateChanged;

    /// <summary>The selection or the text moved and the dust has settled (a moment later, on the UI thread).</summary>
    public event Action? SelectionSettled;

    /// <summary>Reading mode of the tab: the text can't be edited.</summary>
    public bool Reading
    {
        get => reading;
        set
        {
            if (reading == value) return;
            reading = value;
            Sync();
            Box.IsReadOnly = Note.IsReadOnly || !IsFaithful || reading;
            ReadingChanged();
            ReadOnlyStateChanged?.Invoke();
        }
    }

    /// <summary>Reading mode was switched on or off (the editor is already read-only or editable again).</summary>
    protected virtual void ReadingChanged()
    {
    }

    // MARK: Overlay layers

    /// <summary>
    /// Drawings behind the text (code bands, table grids) and over it (bullets, images, buttons). Elements are placed in
    /// document coordinates (a range's client rectangle plus <see cref="ScrollY"/>) and both canvases are shifted by the scroll
    /// offset, so scrolling moves them with the text without re-measuring; <see cref="RenderOverlay"/> refills them for the
    /// visible part (and a margin) a moment after a change.
    /// </summary>
    protected Canvas UnderCanvas { get; } = new();
    protected Canvas OverCanvas { get; } = new();

    protected double ScrollY => scroller?.VerticalOffset ?? 0;

    private void SyncOverlayShift()
    {
        var y = -ScrollY;
        if (underShift.Y != y) underShift.Y = y;
        if (overShift.Y != y) overShift.Y = y;
        OverlayShifted(y);
    }

    /// <summary>The overlay moved with the scroll position (`y` is minus the offset).</summary>
    protected virtual void OverlayShifted(double y)
    {
    }

    /// <summary>Asks for <see cref="RenderOverlay"/> soon; calls in between are merged.</summary>
    protected void InvalidateOverlay(int delayMilliseconds = 30)
    {
        if (!loaded) return;
        if (Box.XamlRoot is null)
        {
            overlayStale = true;
            return;
        }
        if (overlayTimer is null)
        {
            overlayTimer = Box.DispatcherQueue.CreateTimer();
            overlayTimer.IsRepeating = false;
            overlayTimer.Tick += (_, _) =>
            {
                if (!loaded || Box.XamlRoot is null) return;
                try { RenderOverlay(); }
                catch (Exception e) when (e is System.Runtime.InteropServices.COMException or InvalidOperationException or ArgumentException) { }
            };
        }
        if (overlayTimer.IsRunning) return;
        overlayTimer.Interval = TimeSpan.FromMilliseconds(delayMilliseconds);
        overlayTimer.Start();
    }

    /// <summary>Redraws the overlay canvases for the current text and scroll position.</summary>
    protected virtual void RenderOverlay()
    {
    }

    /// <summary>The width of the area the text may use (the box without its padding).</summary>
    protected double TextWidth => Math.Max(0, Box.ActualWidth - Box.Padding.Left - Box.Padding.Right);

    /// <summary>The client rectangle of a range, or null when RichEdit can't give one (not laid out).</summary>
    protected Rect? RectOf(int start, int end)
    {
        try
        {
            Box.Document.GetRange(start, end).GetRect(PointOptions.ClientCoordinates, out var rect, out _);
            return rect.Height > 0 || rect.Width > 0 ? rect : null;
        }
        catch (Exception e) when (e is System.Runtime.InteropServices.COMException or ArgumentException)
        {
            return null;
        }
    }

    /// <summary>The first and last characters on screen, grown by about `margin` pixels of lines above and below.</summary>
    protected (int First, int Last) VisibleCharacters(double margin)
    {
        var text = LastText;
        var length = text.Length;
        var height = scroller?.ViewportHeight ?? Box.ActualHeight;
        int At(double y, int fallback)
        {
            try
            {
                return Math.Clamp(Box.Document.GetRangeFromPoint(new Point(Box.Padding.Left + 4, y), PointOptions.ClientCoordinates).StartPosition, 0, length);
            }
            catch (Exception e) when (e is System.Runtime.InteropServices.COMException or ArgumentException)
            {
                return fallback;
            }
        }
        var first = At(1, 0);
        var last = At(Math.Max(1, height - 1), length);
        // Whole lines of text stand in for the margin (about 18 pixels each; wrapped lines make the margin a little shorter).
        for (var i = (int)(margin / 18); i > 0 && first > 0; i--)
        {
            var previous = text.LastIndexOf('\n', first - 1);
            first = previous < 0 ? 0 : previous;
        }
        for (var i = (int)(margin / 18); i > 0 && last < length; i--)
        {
            var next = text.IndexOf('\n', last + 1);
            last = next < 0 ? length : next;
        }
        return (first, last);
    }

    private void InitializeFeatures()
    {
        underHost.Children.Add(UnderCanvas);
        overHost.Children.Add(OverCanvas);
        UnderCanvas.RenderTransform = underShift;
        OverCanvas.RenderTransform = overShift;
        Host.Children.Add(underHost);
        Host.Children.Add(band);
        Host.Children.Add(Box);
        Host.Children.Add(overHost);
        Host.SizeChanged += (_, e) =>
        {
            var rect = new Rect(0, 0, e.NewSize.Width, e.NewSize.Height);
            underHost.Clip = new RectangleGeometry { Rect = rect };
            overHost.Clip = new RectangleGeometry { Rect = rect };
        };
        try
        {
            var accent = (Windows.UI.Color)Application.Current.Resources["SystemAccentColor"];
            Box.SelectionHighlightColorWhenNotFocused = new SolidColorBrush(Windows.UI.Color.FromArgb(0x59, accent.R, accent.G, accent.B));
        }
        catch (Exception)
        {
        }
        Box.SelectionChanged += (_, _) => QueueSelectionSettled();
        Box.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => pointerDown = true), true);
        var released = new PointerEventHandler((_, _) => pointerDown = false);
        Box.AddHandler(UIElement.PointerReleasedEvent, released, true);
        Box.AddHandler(UIElement.PointerCanceledEvent, released, true);
        Box.AddHandler(UIElement.PointerCaptureLostEvent, released, true);
        Box.AddHandler(UIElement.PointerWheelChangedEvent, new PointerEventHandler(OnWheel), true);
        Box.SizeChanged += (_, _) =>
        {
            UpdatePadding();
            UpdateCurrentLine();
            BoxResized();
            InvalidateOverlay();
        };
        Box.Loaded += (_, _) =>
        {
            if (overlayStale && loaded)
            {
                overlayStale = false;
                InvalidateOverlay();
            }
            if (!settingsStale || !loaded) return;
            settingsStale = false;
            ApplyFontSettings();
            SettingChanged("focusMode");
            SettingChanged("codeWrap");
            UpdatePadding();
            UpdateCurrentLine();
        };
        AppSettings.EditorSettingChanged += OnSettingChanged;
        UpdatePadding();
    }

    private void ReleaseFeatures()
    {
        AppSettings.EditorSettingChanged -= OnSettingChanged;
        overlayTimer?.Stop();
    }

    /// <summary>The box changed size (the text column may have changed width).</summary>
    protected virtual void BoxResized()
    {
    }

    // MARK: Settings

    /// <summary>The padding around the text for the editor's current settings and size.</summary>
    protected abstract Thickness ComputePadding();

    protected void UpdatePadding()
    {
        var padding = ComputePadding();
        if (Box.Padding != padding) Box.Padding = padding;
    }

    /// <summary>A hook for the settings the base class doesn't know: "limitLineWidth", "focusMode", "codeWrap".</summary>
    protected virtual void SettingChanged(string key)
    {
    }

    private void OnSettingChanged(string key)
    {
        if (key == "spellCheck") Box.IsSpellCheckEnabled = AppSettings.SpellCheck;
        // An editor of another tab is out of the visual tree: it catches up when it comes back.
        if (!loaded || Box.XamlRoot is null)
        {
            settingsStale = true;
            return;
        }
        switch (key)
        {
            case "zoom" or "lineSpacing":
                ApplyFontSettings();
                break;
            case "highlightCurrentLine":
                UpdateCurrentLine();
                break;
        }
        SettingChanged(key);
        UpdatePadding();
    }

    /// <summary>The font size or the line spacing changed: everything is styled again.</summary>
    private void ApplyFontSettings()
    {
        if (!loaded) return;
        FontSettingsChanged();
        NeedsFullRestyle = true;
        Styled(Restyle);
        UpdatePadding();
        QueueSelectionSettled();
    }

    protected virtual void FontSettingsChanged()
    {
    }

    /// <summary>Ctrl + mouse wheel zooms by one step per notch.</summary>
    private void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        if (!IsDown(Windows.System.VirtualKey.Control)) return;
        var delta = e.GetCurrentPoint(Box).Properties.MouseWheelDelta;
        if (delta == 0) return;
        e.Handled = true;
        AppSettings.Zoom += delta > 0 ? AppSettings.ZoomStep : -AppSettings.ZoomStep;
    }

    // MARK: Selection

    protected void QueueSelectionSettled()
    {
        if (selectionQueued) return;
        selectionQueued = true;
        Box.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            selectionQueued = false;
            if (!loaded) return;
            UpdateCurrentLine();
            OnSelectionSettled(byMouse: pointerDown);
            SelectionSettled?.Invoke();
        });
    }

    /// <summary>The selection moved (typing included); `byMouse` while a pointer button is down.</summary>
    protected virtual void OnSelectionSettled(bool byMouse)
    {
    }

    /// <summary>[start of the line, end of the line) around `position` in `text`, the line break not included.</summary>
    protected static (int Start, int End) LineAt(string text, int position)
    {
        position = Math.Clamp(position, 0, text.Length);
        var start = position == 0 ? 0 : text.LastIndexOf('\n', position - 1) + 1;
        var end = text.IndexOf('\n', position);
        return (start, end < 0 ? text.Length : end);
    }

    /// <summary>The selection in the text's coordinates.</summary>
    protected MarkdownRange CurrentSelection()
    {
        var selection = Box.Document.Selection;
        var length = LastText.Length;
        var start = Math.Min(selection.StartPosition, length);
        var end = Math.Clamp(selection.EndPosition, start, length);
        return new MarkdownRange(start, end - start);
    }

    protected void SetSelection(int start, int end) => Box.Document.Selection.SetRange(start, end);

    // MARK: Current line

    /// <summary>The neutral band behind the caret's line (all its wrapped lines) while nothing is selected.</summary>
    protected void UpdateCurrentLine()
    {
        if (!AppSettings.HighlightCurrentLine || !loaded || Box.XamlRoot is null || Box.Document.Selection.Length != 0)
        {
            band.Visibility = Visibility.Collapsed;
            return;
        }
        var (start, end) = LineAt(LastText, Box.Document.Selection.StartPosition);
        try
        {
            Box.Document.GetRange(start, end).GetRect(PointOptions.ClientCoordinates, out var rect, out _);
            if (rect.Height <= 0)
            {
                band.Visibility = Visibility.Collapsed;
                return;
            }
            band.Background = new SolidColorBrush(Palette.CurrentLine);
            band.Margin = new Thickness(Math.Max(0, Box.Padding.Left - 6), rect.Y, Math.Max(0, Box.Padding.Right - 6), 0);
            band.Height = rect.Height;
            band.Visibility = Visibility.Visible;
        }
        catch (Exception)
        {
            band.Visibility = Visibility.Collapsed;
        }
    }

    // MARK: Core edits

    /// <summary>Applies an edit of the core (UTF-16 ranges in the text's own coordinates) as one undo step, then places the
    /// selection it asks for; without one the selection moves with the text.</summary>
    protected bool ApplyEdit(TextEdit edit)
    {
        Sync();
        if (Box.IsReadOnly) return false;
        var length = LastText.Length;
        var range = edit.Range;
        if (range.Location < 0 || range.Length < 0 || range.End > length) return false;
        MarkdownRange after;
        if (edit.Selection is { } given)
        {
            after = given;
        }
        else
        {
            var selection = CurrentSelection();
            int Map(int position) => position <= range.Location ? position
                : position >= range.End ? position + edit.Replacement.Length - range.Length
                : range.Location + edit.Replacement.Length;
            after = new MarkdownRange(Map(selection.Location), Map(selection.End) - Map(selection.Location));
        }
        if (range.Length == 0 && edit.Replacement.Length == 0)
        {
            SetSelection(after.Location, after.End);
            Box.Document.Selection.ScrollIntoView(PointOptions.None);
            return true;
        }
        Edit(range.Location, range.Length, edit.Replacement, after.Location, after.End, typing: false);
        return true;
    }

    // MARK: Position

    /// <summary>Puts the caret at `location` and brings its line into view: centred in focus mode, else near the top.</summary>
    public void Reveal(int location)
    {
        Sync();
        location = Math.Clamp(location, 0, LastText.Length);
        SetSelection(location, location);
        Focus();
        Box.Document.Selection.ScrollIntoView(PointOptions.None);
        Box.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            if (scroller is not { } view) return;
            if (CentersCaret)
            {
                CenterCaret();
                return;
            }
            Box.Document.Selection.GetRect(PointOptions.ClientCoordinates, out var rect, out _);
            view.ChangeView(null, Math.Max(0, view.VerticalOffset + rect.Y - 60), null, true);
        });
    }

    /// <summary>Whether the caret's line is kept in the vertical middle of the viewport (focus mode).</summary>
    protected virtual bool CentersCaret => false;

    /// <summary>Scrolls so the caret's line is in the vertical middle of the viewport.</summary>
    protected void CenterCaret()
    {
        if (scroller is not { } view || !loaded) return;
        Box.Document.Selection.GetRect(PointOptions.ClientCoordinates, out Rect rect, out _);
        if (rect.Height <= 0) return;
        var target = view.VerticalOffset + rect.Y + rect.Height / 2 - view.ViewportHeight / 2;
        view.ChangeView(null, Math.Max(0, target), null, true);
    }

    protected double ViewportHeight => scroller?.ViewportHeight ?? Box.ActualHeight;

    // MARK: Find

    public enum FindStep { Stay, Next, Previous }

    private static List<int> Matches(string text, string query)
    {
        var found = new List<int>();
        if (query.Length == 0) return found;
        for (var i = text.IndexOf(query, StringComparison.OrdinalIgnoreCase); i >= 0;
             i = text.IndexOf(query, i + query.Length, StringComparison.OrdinalIgnoreCase))
        {
            found.Add(i);
        }
        return found;
    }

    /// <summary>
    /// Finds `query` (case-insensitive) in the text and selects the match: `Stay` keeps the match at the selection (typing in
    /// the find field), `Next` / `Previous` move on, wrapping around. Returns the 1-based number of the selected match and the
    /// number of matches; (0, 0) when there are none.
    /// </summary>
    public (int Current, int Total) Find(string query, FindStep step)
    {
        Sync();
        var matches = Matches(LastText, query);
        if (matches.Count == 0) return (0, 0);
        var selection = CurrentSelection();
        int index;
        switch (step)
        {
            case FindStep.Previous:
                index = matches.FindLastIndex(m => m < selection.Location);
                if (index < 0) index = matches.Count - 1;
                break;
            case FindStep.Next:
                var from = selection.Length > 0 ? selection.End : selection.Location;
                index = matches.FindIndex(m => m >= from);
                if (index < 0) index = 0;
                break;
            default:
                index = matches.FindIndex(m => m >= selection.Location);
                if (index < 0) index = 0;
                break;
        }
        SetSelection(matches[index], matches[index] + query.Length);
        Box.Document.Selection.ScrollIntoView(PointOptions.None);
        if (CentersCaret) CenterCaret();
        return (index + 1, matches.Count);
    }

    /// <summary>The number of matches, and which one the selection is on (0 when it is on none).</summary>
    public (int Current, int Total) FindStatus(string query)
    {
        var matches = Matches(LastText, query);
        var selection = CurrentSelection();
        var index = selection.Length == query.Length ? matches.IndexOf(selection.Location) : -1;
        return (index + 1, matches.Count);
    }

    /// <summary>Replaces the selected match (if the selection is one) and selects the next.</summary>
    public (int Current, int Total) ReplaceCurrent(string query, string replacement)
    {
        Sync();
        var selection = CurrentSelection();
        if (!Box.IsReadOnly && query.Length > 0 && selection.Length == query.Length
            && string.Compare(LastText, selection.Location, query, 0, query.Length, StringComparison.OrdinalIgnoreCase) == 0)
        {
            var caret = selection.Location + replacement.Length;
            Edit(selection.Location, selection.Length, replacement, caret, caret, typing: false);
        }
        return Find(query, FindStep.Stay);
    }

    /// <summary>Replaces every match as one undo step; returns how many there were.</summary>
    public int ReplaceAllMatches(string query, string replacement)
    {
        Sync();
        var matches = Matches(LastText, query);
        if (matches.Count == 0 || Box.IsReadOnly) return 0;
        var text = LastText;
        var builder = new System.Text.StringBuilder(text.Length);
        var last = 0;
        foreach (var match in matches)
        {
            builder.Append(text, last, match - last).Append(replacement);
            last = match + query.Length;
        }
        builder.Append(text, last, text.Length - last);
        ReplaceAll(builder.ToString());
        return matches.Count;
    }

    /// <summary>The selected text when it is a single line (what the find field is prefilled with).</summary>
    public string SelectionForFind()
    {
        var selection = CurrentSelection();
        if (selection.Length == 0 || selection.Length > 200) return "";
        var text = LastText.Substring(selection.Location, selection.Length);
        return text.Contains('\n') ? "" : text;
    }
}
