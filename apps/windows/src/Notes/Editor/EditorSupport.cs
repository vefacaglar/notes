using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using NotesCore;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI.Core;

namespace Notes.Editor;

/// <summary>
/// A plain-text <see cref="RichEditBox"/> kept in sync with a <see cref="NoteDocument"/>; subclasses style the text in
/// <see cref="Restyle"/>. RichEdit's own undo is off (formatting would land on it), so this class keeps a text-only
/// undo history. RichEdit stores line breaks as CR and always ends with one extra CR; both are mapped here, and
/// positions are the same UTF-16 offsets as in the document text.
/// </summary>
internal abstract class TextEditor
{
    /// <summary>Beyond this many UTF-16 units the text stays plain; styling it would stall typing.</summary>
    public const int MaxStyledLength = 2_000_000;

    public RichEditBox Box { get; }
    protected NoteDocument Note { get; }
    /// <summary>The text RichEdit held after the last processed change (LF line breaks).</summary>
    protected string LastText { get; private set; } = "";
    /// <summary>The last change, in post-edit coordinates: [Start, End) is new text, Delta the change in length.</summary>
    protected (int Start, int End, int Delta)? PendingEdit { get; set; }
    /// <summary>Set on load and on theme changes.</summary>
    protected bool NeedsFullRestyle { get; set; } = true;
    protected EditorPalette Palette => EditorPalette.For(Box.ActualTheme);

    /// <summary>
    /// False when RichEdit can't hold the file's text unchanged (a lone CR, NUL…): the editor is then read-only, so no
    /// edit can ever save the altered text.
    /// </summary>
    public bool IsFaithful { get; private set; } = true;
    public event Action? FaithfulnessChanged;

    private readonly UndoHistory history = new();
    private bool loaded;
    private bool composing;
    /// <summary>RichEdit reported a content change (not just formatting) that hasn't been processed yet.</summary>
    private bool contentChanged;
    /// <summary>The next change is its own undo step (paste, cut, format…), never merged with typing.</summary>
    private bool discreteNext;
    private ScrollViewer? scroller;

    protected TextEditor(NoteDocument note, bool spellCheck)
    {
        Note = note;
        Box = new RichEditBox
        {
            IsSpellCheckEnabled = spellCheck,
            IsTextPredictionEnabled = false,
            TextWrapping = TextWrapping.Wrap,
            AcceptsReturn = true,
            ClipboardCopyFormat = RichEditClipboardFormat.PlainText,
            DisabledFormattingAccelerators = DisabledFormattingAccelerators.All,
            IsReadOnly = note.IsReadOnly,
            BorderThickness = new Thickness(0),
            SelectionFlyout = null,
        };
        var clear = new SolidColorBrush(Colors.Transparent);
        foreach (var key in new[]
        {
            "TextControlBackground", "TextControlBackgroundPointerOver", "TextControlBackgroundFocused", "TextControlBackgroundDisabled",
            "TextControlBorderBrush", "TextControlBorderBrushPointerOver", "TextControlBorderBrushFocused", "TextControlBorderBrushDisabled",
            "TextControlElevationBorderBrush", "TextControlElevationBorderFocusedBrush", "TextControlElevationBorderPointerOverBrush",
            "FocusVisualPrimaryBrush", "FocusVisualSecondaryBrush",
        })
        {
            Box.Resources[key] = clear;
        }
        Box.Resources["TextControlBorderThemeThickness"] = new Thickness(0);
        Box.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(0);
        Box.UseSystemFocusVisuals = false;
        Box.FocusVisualPrimaryBrush = clear;
        Box.FocusVisualSecondaryBrush = clear;
        Box.FocusVisualMargin = new Thickness(0);
        Box.ContextFlyout = BuildContextMenu();
        Box.Loaded += OnLoaded;
        // Styling raises these too; only content changes are processed.
        Box.TextChanging += (_, e) =>
        {
            if (e.IsContentChanging) contentChanged = true;
        };
        Box.TextChanged += (_, _) =>
        {
            if (contentChanged && !composing) ProcessChange(record: true);
        };
        Box.TextCompositionStarted += (_, _) =>
        {
            if (composing) return;
            composing = true;
            Note.ComposingCount++;
        };
        Box.TextCompositionEnded += (_, _) => EndComposition(process: true);
        Box.Paste += (_, e) =>
        {
            e.Handled = true;
            Paste();
        };
        // Only plain text may be dropped (no pictures, files or other objects); RichEdit drops RTF as styled text,
        // which the next restyle turns back into plain text.
        Box.AddHandler(UIElement.DragOverEvent, new DragEventHandler((_, e) =>
        {
            var view = e.DataView;
            if (Box.IsReadOnly || !view.Contains(StandardDataFormats.Text) || view.Contains(StandardDataFormats.StorageItems)
                || view.Contains(StandardDataFormats.Bitmap))
            {
                e.AcceptedOperation = DataPackageOperation.None;
            }
        }), handledEventsToo: true);
        Box.PreviewKeyDown += OnPreviewKeyDown;
        Box.ActualThemeChanged += (_, _) =>
        {
            if (!loaded) return;
            NeedsFullRestyle = true;
            Styled(Restyle);
        };
        Note.TextChanged += OnNoteTextChanged;
        Note.SyncRequested += Sync;
        Note.ReadOnlyChanged += OnReadOnlyChanged;
    }

    /// <summary>The file became (or stopped being) read-only while open.</summary>
    private void OnReadOnlyChanged()
    {
        Sync();
        Box.IsReadOnly = Note.IsReadOnly || !IsFaithful;
    }

    /// <summary>Stops following the document; call when the editor goes away. Unreported typing is handed over first.</summary>
    public void Detach()
    {
        Sync();
        Note.TextChanged -= OnNoteTextChanged;
        Note.SyncRequested -= Sync;
        Note.ReadOnlyChanged -= OnReadOnlyChanged;
        EndComposition(process: false);
    }

    public void Focus() => Box.Focus(FocusState.Programmatic);

    // MARK: Session state

    /// <summary>A state to apply when the editor has loaded (restoring a session).</summary>
    private EditorViewState? pendingView;

    /// <summary>The selection and scroll position now, for the session file.</summary>
    public EditorViewState CaptureViewState()
    {
        if (!loaded) return pendingView ?? new EditorViewState(0, 0, 0, 0);
        var selection = Box.Document.Selection;
        var start = Math.Min(selection.StartPosition, LastText.Length);
        var end = Math.Min(selection.EndPosition, LastText.Length);
        return new EditorViewState(start, end - start, scroller?.HorizontalOffset ?? 0, scroller?.VerticalOffset ?? 0);
    }

    /// <summary>Puts the selection and scroll position back (clamped to the text); before the editor has loaded, once it has.</summary>
    public void ApplyViewState(EditorViewState state)
    {
        if (!loaded)
        {
            pendingView = state;
            return;
        }
        var length = LastText.Length;
        var start = Math.Clamp(state.Location, 0, length);
        var end = Math.Clamp(state.Location + Math.Max(state.Length, 0), start, length);
        Box.Document.Selection.SetRange(start, end);
        if (scroller is not { } view || state.ScrollY <= 0) return;
        // The text is laid out a moment after loading: try until the scroll range reaches the position.
        var tries = 0;
        var timer = Box.DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(30);
        timer.IsRepeating = true;
        timer.Tick += (_, _) =>
        {
            view.ChangeView(state.ScrollX, state.ScrollY, null, true);
            if (++tries >= 10 || Math.Abs(view.VerticalOffset - state.ScrollY) < 1) timer.Stop();
        };
        timer.Start();
    }

    private void EndComposition(bool process)
    {
        if (!composing) return;
        composing = false;
        Note.ComposingCount--;
        if (process) ProcessChange(record: true);
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (loaded) return;
        loaded = true;
        scroller = FindScroller(Box);
        Load(Note.Text);
        if (pendingView is { } view)
        {
            pendingView = null;
            ApplyViewState(view);
        }
        if (Note.FocusOnOpen)
        {
            Note.FocusOnOpen = false;
            Box.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, Focus);
        }
    }

    private static ScrollViewer? FindScroller(DependencyObject root)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is ScrollViewer scroller) return scroller;
            if (FindScroller(child) is { } found) return found;
        }
        return null;
    }

    // MARK: Text

    /// <summary>The editor's text with LF line breaks, without RichEdit's final paragraph mark (one copy of RichEdit's text).</summary>
    protected string ReadText()
    {
        Box.Document.GetText(TextGetOptions.None, out var raw);
        var length = raw.EndsWith('\r') ? raw.Length - 1 : raw.Length;
        return string.Create(length, raw, static (span, source) =>
        {
            source.AsSpan(0, span.Length).CopyTo(span);
            span.Replace('\r', '\n');
        });
    }

    /// <summary>Runs `action` with programmatic changes allowed (RichEdit refuses them while read-only).</summary>
    private void Editable(Action action)
    {
        if (!Box.IsReadOnly)
        {
            action();
            return;
        }
        Box.IsReadOnly = false;
        try { action(); }
        finally { Box.IsReadOnly = true; }
    }

    /// <summary>Runs a styling pass without repainting in between.</summary>
    protected void Styled(Action action) => Editable(() =>
    {
        Box.Document.BatchDisplayUpdates();
        try { action(); }
        finally { Box.Document.ApplyDisplayUpdates(); }
    });

    protected ITextRange Range(int start, int end) => Box.Document.GetRange(start, end);

    /// <summary>
    /// Replaces the whole text with the caret at the start, e.g. when the editor is created. The text goes in through a
    /// range, so it is always plain text (a file starting with "{\rtf" is not read as RTF), and is read back: if RichEdit
    /// changed it, the editor turns read-only.
    /// </summary>
    private void Load(string text)
    {
        Box.Document.UndoLimit = 0;
        Editable(() =>
        {
            Box.Document.SetText(TextSetOptions.None, "");
            Box.Document.GetRange(0, 0).SetText(TextSetOptions.None, text);
        });
        contentChanged = false;
        LastText = ReadText();
        var faithful = string.Equals(LastText, text, StringComparison.Ordinal);
        Box.IsReadOnly = Note.IsReadOnly || !faithful;
        if (faithful != IsFaithful)
        {
            IsFaithful = faithful;
            FaithfulnessChanged?.Invoke();
        }
        history.Clear();
        PendingEdit = null;
        NeedsFullRestyle = true;
        Loading(LastText);
        Styled(Restyle);
        Box.Document.Selection.SetRange(0, 0);
    }

    /// <summary>Called with the new text before the first styling pass of a load.</summary>
    protected virtual void Loading(string text)
    {
    }

    /// <summary>Takes in typing RichEdit hasn't reported yet, so commands and saves see the current text.</summary>
    protected void Sync()
    {
        if (!composing) ProcessChange(record: true);
    }

    /// <summary>Takes in whatever changed in RichEdit since the last call: records undo, restyles, updates the document.</summary>
    private void ProcessChange(bool record)
    {
        contentChanged = false;
        if (!loaded || Box.IsReadOnly) return;
        var text = ReadText();
        var old = LastText;
        var max = Math.Min(text.Length, old.Length);
        var prefix = text.AsSpan(0, max).CommonPrefixLength(old.AsSpan(0, max));
        if (prefix == text.Length && prefix == old.Length) return;
        var suffix = 0;
        while (suffix < max - prefix && text[text.Length - 1 - suffix] == old[old.Length - 1 - suffix]) suffix++;
        var oldEnd = old.Length - suffix;
        var newEnd = text.Length - suffix;
        if (record) history.Record(prefix, old[prefix..oldEnd], text[prefix..newEnd], typing: !discreteNext);
        discreteNext = false;
        LastText = text;
        PendingEdit = (prefix, newEnd, text.Length - old.Length);
        Styled(Restyle);
        Note.SetText(text, this);
    }

    /// <summary>Replaces [start, start + length) with `text` as an edit of the user's, then selects [selStart, selEnd).
    /// Callers compute positions after <see cref="Sync"/>.</summary>
    protected void Edit(int start, int length, string text, int selStart, int selEnd, bool typing, bool record = true)
    {
        if (Box.IsReadOnly) return;
        Box.Document.GetRange(start, start + length).SetText(TextSetOptions.None, text);
        Box.Document.Selection.SetRange(selStart, selEnd);
        discreteNext = !typing;
        ProcessChange(record);
        Box.Document.Selection.ScrollIntoView(PointOptions.None);
    }

    /// <summary>Types `text` over the selection.</summary>
    protected void Insert(string text)
    {
        Sync();
        var selection = Box.Document.Selection;
        var start = Math.Min(selection.StartPosition, LastText.Length);
        var end = Math.Min(selection.EndPosition, LastText.Length);
        Edit(start, end - start, text, start + text.Length, start + text.Length, typing: true);
    }

    /// <summary>Replaces the whole text as one undoable step, keeping the caret where it was if possible.</summary>
    public bool ReplaceAll(string text)
    {
        Sync();
        if (Box.IsReadOnly || string.Equals(text, LastText, StringComparison.Ordinal)) return false;
        history.Break();
        var caret = Math.Min(Box.Document.Selection.StartPosition, text.Length);
        Edit(0, LastText.Length, text, caret, caret, typing: false);
        return true;
    }

    /// <summary>The document changed elsewhere (a reload or a revert): reload, keeping selection and scroll. The document
    /// asked for <see cref="Sync"/> before deciding to reload, so no typing is lost here.</summary>
    private void OnNoteTextChanged(object? origin)
    {
        if (origin == this || !loaded || string.Equals(Note.Text, LastText, StringComparison.Ordinal)) return;
        var selection = Box.Document.Selection;
        var (start, end) = (selection.StartPosition, selection.EndPosition);
        var offset = scroller?.VerticalOffset;
        Load(Note.Text);
        var length = LastText.Length;
        Box.Document.Selection.SetRange(Math.Min(start, length), Math.Min(end, length));
        if (offset is { } y && scroller is { } view)
            Box.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () => view.ChangeView(null, y, null, true));
    }

    protected abstract void Restyle();

    // MARK: Undo

    public bool CanUndo => history.CanUndo && !Box.IsReadOnly;
    public bool CanRedo => history.CanRedo && !Box.IsReadOnly;

    public void Undo()
    {
        Sync();
        if (Box.IsReadOnly || history.PopUndo() is not { } step) return;
        Edit(step.Start, step.Inserted.Length, step.Removed, step.Start, step.Start + step.Removed.Length, typing: false, record: false);
        history.PushRedo(step);
    }

    public void Redo()
    {
        Sync();
        if (Box.IsReadOnly || history.PopRedo() is not { } step) return;
        var end = step.Start + step.Inserted.Length;
        Edit(step.Start, step.Removed.Length, step.Inserted, end, end, typing: false, record: false);
        history.PushUndo(step);
    }

    // MARK: Clipboard and keys

    public void Paste()
    {
        Sync();
        if (Box.IsReadOnly) return;
        history.Break();
        discreteNext = true;
        try { Box.Document.Selection.Paste(13); } // CF_UNICODETEXT: never rich text
        catch (Exception) { return; }
        ProcessChange(record: true);
        history.Break();
        Box.Document.Selection.ScrollIntoView(PointOptions.None);
    }


    /// <summary>Whether the text can be changed (not read-only, and RichEdit holds it unchanged).</summary>
    public bool IsEditable => !Box.IsReadOnly;

    public bool HasSelection => Box.Document.Selection.Length != 0;

    public void SelectAll() => Box.Document.Selection.SetRange(0, LastText.Length);

    /// <summary>Format &gt; Bold / Italic; only the Markdown editor has them.</summary>
    public virtual void ToggleBold()
    {
    }

    public virtual void ToggleItalic()
    {
    }

    private string SelectedText()
    {
        Box.Document.Selection.GetText(TextGetOptions.None, out var text);
        return text.Replace('\r', '\n');
    }

    public void Copy()
    {
        var text = SelectedText();
        if (text.Length == 0) return;
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
    }

    public void Cut()
    {
        Sync();
        if (Box.IsReadOnly) return;
        Copy();
        var selection = Box.Document.Selection;
        var start = selection.StartPosition;
        var end = Math.Min(selection.EndPosition, LastText.Length);
        if (end > start) Edit(start, end - start, "", start, start, typing: false);
    }

    private MenuFlyout BuildContextMenu()
    {
        var menu = new MenuFlyout();
        MenuFlyoutItem Item(string text, string shortcut, Action action)
        {
            var item = new MenuFlyoutItem { Text = text, KeyboardAcceleratorTextOverride = shortcut };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
            return item;
        }
        var undo = Item(Loc.Get("Undo"), "Ctrl+Z", Undo);
        var redo = Item(Loc.Get("Redo"), "Ctrl+Y", Redo);
        menu.Items.Add(new MenuFlyoutSeparator());
        var cut = Item(Loc.Get("Cut"), "Ctrl+X", Cut);
        var copy = Item(Loc.Get("Copy"), "Ctrl+C", Copy);
        var paste = Item(Loc.Get("Paste"), "Ctrl+V", Paste);
        menu.Items.Add(new MenuFlyoutSeparator());
        Item(Loc.Get("SelectAll"), "Ctrl+A", SelectAll);
        AddMenuItems(menu);
        menu.Opening += (_, _) =>
        {
            var hasSelection = Box.Document.Selection.Length != 0;
            undo.IsEnabled = CanUndo;
            redo.IsEnabled = CanRedo;
            cut.IsEnabled = hasSelection && !Box.IsReadOnly;
            copy.IsEnabled = hasSelection;
            paste.IsEnabled = !Box.IsReadOnly;
        };
        return menu;
    }

    protected virtual void AddMenuItems(MenuFlyout menu)
    {
    }

    /// <summary>VK_OEM_4 and VK_OEM_6, the keys of "[" and "]" on a US keyboard.</summary>
    private const VirtualKey OemOpenBrackets = (VirtualKey)0xDB, OemCloseBrackets = (VirtualKey)0xDD;

    protected static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    private void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (composing || e.Key is VirtualKey.Control or VirtualKey.Shift or VirtualKey.Menu or VirtualKey.LeftWindows) return;
        var ctrl = IsDown(VirtualKey.Control);
        var shift = IsDown(VirtualKey.Shift);
        // Ctrl+Alt is AltGr on many keyboards (e.g. @ on Turkish Q): leave it alone.
        var alt = IsDown(VirtualKey.Menu);
        if (ctrl && !alt)
        {
            switch (e.Key)
            {
                case VirtualKey.Z:
                    e.Handled = true;
                    if (shift) Redo(); else Undo();
                    return;
                case VirtualKey.Y:
                    e.Handled = true;
                    Redo();
                    return;
                case VirtualKey.X:
                    Sync();
                    history.Break();
                    discreteNext = true;
                    return;
                // Editing, navigation and the app's own shortcuts pass through (Ctrl+B is Bold, handled below; Ctrl+Shift+B,
                // Ctrl+F, Ctrl+Shift+F, Ctrl+1..9 and Ctrl+Shift+[ ] belong to the window).
                case VirtualKey.A or VirtualKey.C or VirtualKey.V or VirtualKey.Insert or VirtualKey.Back or VirtualKey.Delete
                    or VirtualKey.Left or VirtualKey.Right or VirtualKey.Up or VirtualKey.Down or VirtualKey.Home or VirtualKey.End
                    or VirtualKey.PageUp or VirtualKey.PageDown or VirtualKey.Tab
                    or VirtualKey.N or VirtualKey.S or VirtualKey.F or VirtualKey.O or VirtualKey.T or VirtualKey.W:
                case VirtualKey.B when shift:
                case >= VirtualKey.Number1 and <= VirtualKey.Number9 when !shift:
                case OemOpenBrackets or OemCloseBrackets when shift:
                    return;
                default:
                    // Everything else is a RichEdit formatting shortcut (alignment, lists, line spacing…): swallowed.
                    e.Handled = true;
                    if (!Box.IsReadOnly) HandleShortcut(e.Key, shift);
                    return;
            }
        }
        if (Box.IsReadOnly || ctrl || alt) return;
        if (e.Key == VirtualKey.Enter)
        {
            // Shift+Enter would insert RichEdit's soft line break (VT); every Return is a plain LF.
            e.Handled = true;
            InsertNewline();
        }
        else if (e.Key == VirtualKey.Tab && !shift && HandleTab())
        {
            e.Handled = true;
        }
    }

    /// <summary>Ctrl+`key` in an editable editor.</summary>
    protected virtual void HandleShortcut(VirtualKey key, bool shift)
    {
    }

    protected virtual void InsertNewline() => Insert("\n");

    protected virtual bool HandleTab() => false;

    // MARK: Formatting command

    public bool CanFormat => Note.Language.CanFormat() && !Note.IsReadOnly && IsFaithful;

    /// <summary>"Format": reformats the text as one undoable step. On invalid input it puts the caret at the error
    /// and shows the reason.</summary>
    public async void Format()
    {
        if (!CanFormat || !loaded) return;
        Sync();
        try
        {
            ReplaceAll(Note.Language.Format(LastText));
        }
        catch (JsonFormatException e)
        {
            var caret = Math.Min(e.Offset, LastText.Length);
            Box.Document.Selection.SetRange(caret, caret);
            Box.Document.Selection.ScrollIntoView(PointOptions.None);
            Focus();
            if (Box.XamlRoot is { } root) await Dialogs.MessageAsync(root, Loc.Get("FormatFailed"), e.Message);
        }
    }
}

/// <summary>Text-only undo steps. Consecutive typing (or deleting) at the same spot merges into one step.</summary>
internal sealed class UndoHistory
{
    public sealed class Step(int start, string removed, string inserted, bool typing)
    {
        public int Start { get; set; } = start;
        public string Removed { get; set; } = removed;
        public string Inserted { get; set; } = inserted;
        public bool Typing { get; } = typing;
        public long Time { get; set; } = Environment.TickCount64;
    }

    private const int Limit = 500;
    private readonly List<Step> undo = [];
    private readonly List<Step> redo = [];
    private bool breakNext;

    public bool CanUndo => undo.Count > 0;
    public bool CanRedo => redo.Count > 0;

    public void Clear()
    {
        undo.Clear();
        redo.Clear();
        breakNext = false;
    }

    /// <summary>The next change starts a new step.</summary>
    public void Break() => breakNext = true;

    public void Record(int start, string removed, string inserted, bool typing)
    {
        redo.Clear();
        var now = Environment.TickCount64;
        if (typing && !breakNext && undo.Count > 0 && undo[^1] is { Typing: true } last && now - last.Time < 3000
            && TryMerge(last, start, removed, inserted))
        {
            last.Time = now;
            if (last.Removed.Length == 0 && last.Inserted.Length == 0) undo.RemoveAt(undo.Count - 1);
            return;
        }
        breakNext = !typing;
        PushUndo(new Step(start, removed, inserted, typing));
    }

    private static bool TryMerge(Step last, int start, string removed, string inserted)
    {
        if (removed.Length == 0 && start == last.Start + last.Inserted.Length)
        {
            last.Inserted += inserted;
            return true;
        }
        if (inserted.Length > 0) return false;
        // Backspace over what this step typed.
        if (start + removed.Length == last.Start + last.Inserted.Length && last.Inserted.Length >= removed.Length
            && last.Inserted.EndsWith(removed, StringComparison.Ordinal))
        {
            last.Inserted = last.Inserted[..^removed.Length];
            return true;
        }
        if (last.Inserted.Length > 0) return false;
        if (start + removed.Length == last.Start)
        {
            last.Start = start;
            last.Removed = removed + last.Removed;
            return true;
        }
        if (start == last.Start)
        {
            last.Removed += removed;
            return true;
        }
        return false;
    }

    public void PushUndo(Step step)
    {
        undo.Add(step);
        if (undo.Count > Limit) undo.RemoveAt(0);
    }

    public Step? PopUndo()
    {
        if (undo.Count == 0) return null;
        var step = undo[^1];
        undo.RemoveAt(undo.Count - 1);
        breakNext = true;
        return step;
    }

    public void PushRedo(Step step) => redo.Add(step);

    public Step? PopRedo()
    {
        if (redo.Count == 0) return null;
        var step = redo[^1];
        redo.RemoveAt(redo.Count - 1);
        return step;
    }
}
