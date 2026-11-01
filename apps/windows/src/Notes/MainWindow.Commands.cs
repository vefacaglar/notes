using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Notes.Editor;
using NotesCore;
using Windows.System;

namespace Notes;

/// <summary>
/// The command surface: the menu bar in the title bar (File / Edit / Format / View / Help, mirroring the macOS menu bar)
/// and the window-wide keyboard shortcuts. Every command is declared once with <see cref="AddItem"/> (menu text, shortcut
/// text, handler, when it is enabled); a later batch only adds lines to <see cref="BuildMenu"/>. The editor passes these
/// shortcuts on to the window (see <c>TextEditor.OnPreviewKeyDown</c>); Ctrl+B, Ctrl+I, Ctrl+Z… are the editor's own and are
/// only shown here.
/// </summary>
public sealed partial class MainWindow
{
    private readonly record struct Shortcut(VirtualKey Key, VirtualKeyModifiers Modifiers, string? Text = null)
    {
        public string Display => Text ?? FormatCommands.Display(Key, Modifiers);
    }

    /// <summary>VK_OEM_4 and VK_OEM_6: the keys of "[" and "]" on a US keyboard.</summary>
    private const VirtualKey OpenBracketKey = (VirtualKey)0xDB, CloseBracketKey = (VirtualKey)0xDD;
    /// <summary>VK_OEM_PLUS and VK_OEM_MINUS: the keys of "=" and "-" on a US keyboard.</summary>
    private const VirtualKey OemPlusKey = (VirtualKey)0xBB, OemMinusKey = (VirtualKey)0xBD;
    private const VirtualKeyModifiers Ctrl = VirtualKeyModifiers.Control, Shift = VirtualKeyModifiers.Shift, Alt = VirtualKeyModifiers.Menu;

    /// <summary>Items that follow the state of the window (disabled when they can't run).</summary>
    private readonly List<(MenuFlyoutItemBase Item, Func<bool> Enabled)> menuStates = [];
    private MenuFlyoutItem? sidebarItem;

    private TextEditor? Edit => ActiveEditor?.Editor;

    /// <summary>The Markdown editor of the active tab when it can be edited (what the Format commands need).</summary>
    private MarkdownEditor? EditableMarkdown => Edit is MarkdownEditor { IsEditable: true } editor ? editor : null;

    /// <summary>Every shortcut with its action: the editor asks here before RichEdit sees a Ctrl combination, so each one runs
    /// exactly once whether the keyboard is in the editor or elsewhere in the window.</summary>
    private readonly Dictionary<(VirtualKey, VirtualKeyModifiers), (Action Run, Func<bool>? Enabled)> shortcuts = [];
    private (VirtualKey Key, VirtualKeyModifiers Modifiers, long At) lastShortcut;

    private void Accelerator(Shortcut shortcut, Action action, Func<bool>? enabled = null)
    {
        shortcuts[(shortcut.Key, shortcut.Modifiers)] = (action, enabled);
        var accelerator = new KeyboardAccelerator { Key = shortcut.Key, Modifiers = shortcut.Modifiers };
        accelerator.Invoked += (_, e) =>
        {
            e.Handled = true;
            // The editor already ran it from its own key handler.
            if (lastShortcut.Key == shortcut.Key && lastShortcut.Modifiers == shortcut.Modifiers && Environment.TickCount64 - lastShortcut.At < 150) return;
            if (enabled?.Invoke() ?? true) action();
        };
        Root.KeyboardAccelerators.Add(accelerator);
    }

    /// <summary>The editor's hook for window shortcuts: runs the one registered for these keys, if any.</summary>
    private bool TryShortcut(VirtualKey key, VirtualKeyModifiers modifiers)
    {
        if (!shortcuts.TryGetValue((key, modifiers), out var shortcut)) return false;
        lastShortcut = (key, modifiers, Environment.TickCount64);
        if (shortcut.Enabled?.Invoke() ?? true) shortcut.Run();
        return true;
    }

    private static MenuBarItem Group(string key) => new() { Title = Loc.Get(key) };

    /// <summary>
    /// Adds a menu item. `shortcut` is shown on it and, with `register`, also triggers `run` anywhere in the window;
    /// commands the editor handles by itself (Ctrl+B, Ctrl+Z…) are only shown.
    /// </summary>
    private MenuFlyoutItem AddItem(IList<MenuFlyoutItemBase> group, string textKey, Action run, Shortcut? shortcut = null, Func<bool>? enabled = null, bool register = true)
    {
        var item = new MenuFlyoutItem { Text = Loc.Get(textKey) };
        if (shortcut is { } s) item.KeyboardAcceleratorTextOverride = s.Display;
        item.Click += (_, _) =>
        {
            if (enabled?.Invoke() ?? true) run();
        };
        group.Add(item);
        if (shortcut is { } key && register) Accelerator(key, run, enabled);
        if (enabled is not null) menuStates.Add((item, enabled));
        return item;
    }

    private static void AddSeparator(IList<MenuFlyoutItemBase> group) => group.Add(new MenuFlyoutSeparator());

    private readonly List<(ToggleMenuFlyoutItem Item, Func<bool> IsChecked)> checkStates = [];
    private MenuFlyoutItem? outlineItem;

    /// <summary>A menu item with a check mark that follows `isChecked`.</summary>
    private ToggleMenuFlyoutItem AddToggle(IList<MenuFlyoutItemBase> group, string textKey, Action toggle, Func<bool> isChecked, Shortcut? shortcut = null, Func<bool>? enabled = null)
    {
        var item = new ToggleMenuFlyoutItem { Text = Loc.Get(textKey) };
        if (shortcut is { } s) item.KeyboardAcceleratorTextOverride = s.Display;
        item.Click += (_, _) =>
        {
            if (enabled?.Invoke() ?? true) toggle();
            RefreshMenu();
        };
        group.Add(item);
        if (shortcut is { } key)
        {
            Accelerator(key, () =>
            {
                toggle();
                RefreshMenu();
            }, enabled);
        }
        if (enabled is not null) menuStates.Add((item, enabled));
        checkStates.Add((item, isChecked));
        return item;
    }

    /// <summary>A Format command: its menu item and, with a shortcut, its accelerator.</summary>
    private void AddCommand(IList<MenuFlyoutItemBase> group, EditorCommand command)
    {
        Shortcut? shortcut = command.HasShortcut ? new Shortcut(command.Key, command.Modifiers) : null;
        AddItem(group, command.TextKey, () =>
        {
            if (EditableMarkdown is { } editor) command.Run(editor);
        }, shortcut, () => EditableMarkdown is not null);
    }

    /// <summary>Re-evaluates which items can run; called when the tab or the document state changes and when a menu opens.</summary>
    private void RefreshMenu()
    {
        foreach (var (item, enabled) in menuStates) item.IsEnabled = enabled();
        foreach (var (item, isChecked) in checkStates) item.IsChecked = isChecked();
        if (outlineItem is not null) outlineItem.Text = Loc.Get(ActiveEditor?.IsOutlineOpen == true ? "HideOutline" : "ShowOutline");
    }

    private void BuildMenu()
    {
        TextEditor.ShortcutHook = TryShortcut;
        var file = Group("MenuFile");
        var f = file.Items;
        AddItem(f, "NewNote", () => _ = model.NewNoteAsync(), new(VirtualKey.N, Ctrl));
        AddItem(f, "NewTab", () => model.NewTab(), new(VirtualKey.T, Ctrl));
        AddItem(f, "NewFolder", () => _ = NewFolderAsync(null), new(VirtualKey.N, Ctrl | Shift));
        AddSeparator(f);
        AddItem(f, "AddFolderToWorkspace", () => _ = AddRootAsync(), new(VirtualKey.O, Ctrl | Shift));
        AddSeparator(f);
        AddItem(f, "CloseTab", CloseActiveTabOrWindow, new(VirtualKey.W, Ctrl));
        AddSeparator(f);
        AddItem(f, "Save", () => _ = model.SaveActiveAsync(), new(VirtualKey.S, Ctrl));
        AddItem(f, "SaveAs", () => _ = SaveAsAsync(), new(VirtualKey.S, Ctrl | Shift), () => model.ActiveDocument is not null);
        AddSeparator(f);
        AddItem(f, "Exit", () => _ = requestClose());

        var edit = Group("MenuEdit");
        var e = edit.Items;
        AddItem(e, "Undo", () => InEditor(x => x.Undo()), new(VirtualKey.Z, Ctrl), () => Edit?.CanUndo == true, register: false);
        AddItem(e, "Redo", () => InEditor(x => x.Redo()), new(VirtualKey.Y, Ctrl), () => Edit?.CanRedo == true, register: false);
        AddSeparator(e);
        AddItem(e, "Cut", () => InEditor(x => x.Cut()), new(VirtualKey.X, Ctrl), () => Edit is { IsEditable: true, HasSelection: true }, register: false);
        AddItem(e, "Copy", () => InEditor(x => x.Copy()), new(VirtualKey.C, Ctrl), () => Edit is { HasSelection: true }, register: false);
        AddItem(e, "Paste", () => InEditor(x => x.Paste()), new(VirtualKey.V, Ctrl), () => Edit is { IsEditable: true }, register: false);
        AddItem(e, "SelectAll", () => InEditor(x => x.SelectAll()), new(VirtualKey.A, Ctrl), () => Edit is not null, register: false);
        AddSeparator(e);
        AddItem(e, "Find", () => ActiveEditor?.ShowFind(replace: false), new(VirtualKey.F, Ctrl), () => ActiveEditor is not null);
        AddItem(e, "FindNext", () => ActiveEditor?.FindStep(TextEditor.FindStep.Next), new(VirtualKey.F3, VirtualKeyModifiers.None), () => ActiveEditor is not null);
        AddItem(e, "FindPrevious", () => ActiveEditor?.FindStep(TextEditor.FindStep.Previous), new(VirtualKey.F3, Shift), () => ActiveEditor is not null);
        AddItem(e, "Replace", () => ActiveEditor?.ShowFind(replace: true), new(VirtualKey.H, Ctrl), () => Edit is { IsEditable: true });
        AddItem(e, "SearchNotes", ShowSidebarSearch, new(VirtualKey.F, Ctrl | Shift));
        AddSeparator(e);
        AddItem(e, "Format", () => ActiveEditor?.Format(), new(VirtualKey.F, Shift | Alt), () => Edit?.CanFormat == true);

        var format = Group("MenuFormat");
        var m = format.Items;
        foreach (var command in new[] { FormatCommands.Bold, FormatCommands.Italic, FormatCommands.Strikethrough, FormatCommands.InlineCode, FormatCommands.Link }) AddCommand(m, command);
        AddSeparator(m);
        var heading = new MenuFlyoutSubItem { Text = Loc.Get("Heading") };
        foreach (var command in FormatCommands.Headings) AddCommand(heading.Items, command);
        m.Add(heading);
        foreach (var command in new[] { FormatCommands.BulletedList, FormatCommands.NumberedList, FormatCommands.Checklist, FormatCommands.Quote }) AddCommand(m, command);
        AddSeparator(m);
        AddCommand(m, FormatCommands.CodeBlock);
        AddCommand(m, FormatCommands.HorizontalRule);
        AddSeparator(m);
        var table = new MenuFlyoutSubItem { Text = Loc.Get("Table") };
        AddCommand(table.Items, FormatCommands.InsertTable);
        AddCommand(table.Items, FormatCommands.ConvertToTable);
        AddSeparator(table.Items);
        foreach (var command in new[] { FormatCommands.AddRowAbove, FormatCommands.AddRowBelow, FormatCommands.AddColumnLeft, FormatCommands.AddColumnRight, FormatCommands.DeleteRow, FormatCommands.DeleteColumn }) AddCommand(table.Items, command);
        AddSeparator(table.Items);
        foreach (var command in new[] { FormatCommands.AlignLeft, FormatCommands.AlignCenter, FormatCommands.AlignRight }) AddCommand(table.Items, command);
        m.Add(table);
        menuStates.Add((heading, () => EditableMarkdown is not null));
        menuStates.Add((table, () => EditableMarkdown is not null));

        var view = Group("MenuView");
        var v = view.Items;
        sidebarItem = AddItem(v, "HideSidebar", () => SetSidebarOpen(!Split.IsPaneOpen, save: true), new(VirtualKey.B, Ctrl | Shift));
        AddSeparator(v);
        AddToggle(v, "ShowSource", ToggleSource, () => model.ActiveTab?.ShowsSource == true, new(VirtualKey.R, Ctrl | Shift), () => Edit is MarkdownEditor);
        AddToggle(v, "ShowMarkdownSyntax", () => AppSettings.ShowMarkdownSyntax = !AppSettings.ShowMarkdownSyntax, () => AppSettings.ShowMarkdownSyntax, new(VirtualKey.M, Ctrl | Shift), () => Edit is MarkdownEditor);
        AddToggle(v, "ReadingMode", ToggleReading, () => model.ActiveTab?.Reading == true, new(VirtualKey.E, Ctrl | Shift), () => model.ActiveDocument is not null);
        outlineItem = AddItem(v, "ShowOutline", () => (Edit as MarkdownEditor)?.ToggleOutline(), new(VirtualKey.D, Ctrl | Shift), () => Edit is MarkdownEditor);
        AddToggle(v, "FocusMode", () => AppSettings.FocusMode = !AppSettings.FocusMode, () => AppSettings.FocusMode, new(VirtualKey.J, Ctrl | Shift));
        AddSeparator(v);
        AddToggle(v, "ShowStatusBar", () => AppSettings.ShowStatusBar = !AppSettings.ShowStatusBar, () => AppSettings.ShowStatusBar);
        AddToggle(v, "ShowFormattingBar", () => AppSettings.ShowFormattingBar = !AppSettings.ShowFormattingBar, () => AppSettings.ShowFormattingBar);
        AddSeparator(v);
        AddItem(v, "ZoomIn", () => AppSettings.Zoom += AppSettings.ZoomStep, new(OemPlusKey, Ctrl | Shift, "Ctrl++"), () => AppSettings.Zoom < AppSettings.ZoomMax);
        AddItem(v, "ZoomOut", () => AppSettings.Zoom -= AppSettings.ZoomStep, new(OemMinusKey, Ctrl), () => AppSettings.Zoom > AppSettings.ZoomMin);
        AddItem(v, "ActualSize", () => AppSettings.Zoom = 1, new(VirtualKey.Number0, Ctrl), () => AppSettings.Zoom != 1);
        // The same zooming from the other keys: Ctrl+= (no Shift), the numeric keypad.
        Accelerator(new(OemPlusKey, Ctrl), () => AppSettings.Zoom += AppSettings.ZoomStep, () => AppSettings.Zoom < AppSettings.ZoomMax);
        Accelerator(new(VirtualKey.Add, Ctrl), () => AppSettings.Zoom += AppSettings.ZoomStep, () => AppSettings.Zoom < AppSettings.ZoomMax);
        Accelerator(new(VirtualKey.Subtract, Ctrl), () => AppSettings.Zoom -= AppSettings.ZoomStep, () => AppSettings.Zoom > AppSettings.ZoomMin);
        Accelerator(new(VirtualKey.NumberPad0, Ctrl), () => AppSettings.Zoom = 1, () => AppSettings.Zoom != 1);
        AddSeparator(v);
        AddItem(v, "ShowNextTab", () => CycleTab(1), new(VirtualKey.Tab, Ctrl), () => model.Tabs.Count > 1);
        AddItem(v, "ShowPreviousTab", () => CycleTab(-1), new(VirtualKey.Tab, Ctrl | Shift), () => model.Tabs.Count > 1);
        AddItem(v, "SelectNextTab", () => CycleTab(1), new(CloseBracketKey, Ctrl | Shift), () => model.Tabs.Count > 1);
        AddItem(v, "SelectPreviousTab", () => CycleTab(-1), new(OpenBracketKey, Ctrl | Shift), () => model.Tabs.Count > 1);
        // Ctrl+1..8 pick that tab, Ctrl+9 the last one; no menu items, they would only clutter the menu.
        for (var number = 1; number <= 9; number++)
        {
            var n = number;
            Accelerator(new(VirtualKey.Number0 + n, Ctrl), () => SelectTab(n));
        }

        var help = Group("MenuHelp");
        AddItem(help.Items, "AboutNotes", () => _ = ShowAboutAsync());

        sidebarItem.Text = Loc.Get(Split.IsPaneOpen ? "HideSidebar" : "ShowSidebar");
        foreach (var group in new[] { file, edit, format, view, help }) Menu.Items.Add(group);
        // Menu bar items have no "opening" event: refresh when the pointer or the keyboard reaches the bar.
        Menu.AddHandler(UIElement.PointerEnteredEvent, new PointerEventHandler((_, _) => RefreshMenu()), true);
        Menu.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => RefreshMenu()), true);
        Menu.GotFocus += (_, _) => RefreshMenu();

        Accelerator(new(VirtualKey.F2, VirtualKeyModifiers.None), () =>
        {
            if (model.Selection is { IsRoot: false } item) _ = RenameAsync(item);
        });
        RefreshMenu();
    }

    // MARK: Reading mode and source

    /// <summary>Ctrl+Shift+E: the active tab's reading mode (not editable); saved with the tab in the session.</summary>
    private void ToggleReading()
    {
        if (model.ActiveTab is { Document: not null } tab) SetReading(tab, !tab.Reading);
    }

    private void SetReading(NoteTab tab, bool reading)
    {
        if (tab.Reading == reading) return;
        tab.Reading = reading;
        if (editors.TryGetValue(tab, out var view)) view.ApplyModes();
        SaveSessionSoon();
        RefreshMenu();
    }

    /// <summary>Ctrl+Shift+R: Markdown as plain source (same text and undo history).</summary>
    private void ToggleSource()
    {
        if (model.ActiveTab is not { Document.Language: CodeLanguage.Markdown } tab) return;
        tab.ShowsSource = !tab.ShowsSource;
        if (editors.TryGetValue(tab, out var view)) view.ApplyModes();
        SaveSessionSoon();
        RefreshMenu();
    }

    /// <summary>Runs an editor command and puts the keyboard back in the editor, where a menu took it from.</summary>
    private void InEditor(Action<TextEditor> action)
    {
        if (Edit is not { } editor) return;
        action(editor);
        ActiveEditor?.FocusEditor();
    }

    private void ShowSidebarSearch()
    {
        SetSidebarOpen(true, save: true);
        Sidebar.FocusSearch();
    }

    /// <summary>Ctrl+W: closes the active tab; with no tabs left, the window.</summary>
    private void CloseActiveTabOrWindow()
    {
        if (model.ActiveTab is { } tab) _ = CloseTabAsync(tab);
        else _ = requestClose();
    }

    /// <summary>Ctrl+Tab and Ctrl+Shift+[ ]: the next or previous tab, with the keyboard in its editor.</summary>
    private void CycleTab(int delta)
    {
        model.CycleTab(delta);
        FocusActiveEditor();
    }

    private void SelectTab(int number)
    {
        model.SelectTab(number);
        FocusActiveEditor();
    }

    /// <summary>The editor of a tab created now takes the keys when it appears; an existing one gets them right away.</summary>
    private void FocusActiveEditor()
    {
        if (ActiveEditor is { } editor) editor.FocusEditor();
        else if (model.ActiveDocument is { } document) document.FocusOnOpen = true;
    }

    // MARK: About

    /// <summary>The About box: name, version and a short description, like the standard panel of the macOS app.</summary>
    private async Task ShowAboutAsync()
    {
        if (Content.XamlRoot is not { } root) return;
        var version = typeof(MainWindow).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{Math.Max(v.Build, 0)}" : "";
        var secondary = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        var content = new StackPanel
        {
            Spacing = 4,
            MinWidth = 280,
            Children =
            {
                new TextBlock { Text = Loc.Get("AppName"), Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] },
                new TextBlock { Text = Loc.Format("VersionFormat", version), Foreground = secondary },
                new TextBlock { Text = Loc.Get("AboutDescription"), TextWrapping = TextWrapping.Wrap, Foreground = secondary, Margin = new Thickness(0, 8, 0, 0) },
            },
        };
        await Dialogs.ShowAsync(root, new ContentDialog
        {
            Title = Loc.Get("AboutNotes"),
            Content = content,
            CloseButtonText = Loc.Get("OK"),
            DefaultButton = ContentDialogButton.Close,
        });
    }
}
