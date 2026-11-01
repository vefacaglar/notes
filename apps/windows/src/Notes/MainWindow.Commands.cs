using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Notes.Editor;
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
    private readonly record struct Shortcut(VirtualKey Key, VirtualKeyModifiers Modifiers)
    {
        public string Display
        {
            get
            {
                var parts = new List<string>();
                if (Modifiers.HasFlag(VirtualKeyModifiers.Control)) parts.Add("Ctrl");
                if (Modifiers.HasFlag(VirtualKeyModifiers.Shift)) parts.Add("Shift");
                if (Modifiers.HasFlag(VirtualKeyModifiers.Menu)) parts.Add("Alt");
                parts.Add(Key switch
                {
                    >= VirtualKey.Number0 and <= VirtualKey.Number9 => ((int)Key - (int)VirtualKey.Number0).ToString(),
                    OpenBracketKey => "[",
                    CloseBracketKey => "]",
                    _ => Key.ToString(),
                });
                return string.Join('+', parts);
            }
        }
    }

    /// <summary>VK_OEM_4 and VK_OEM_6: the keys of "[" and "]" on a US keyboard.</summary>
    private const VirtualKey OpenBracketKey = (VirtualKey)0xDB, CloseBracketKey = (VirtualKey)0xDD;
    private const VirtualKeyModifiers Ctrl = VirtualKeyModifiers.Control, Shift = VirtualKeyModifiers.Shift, Alt = VirtualKeyModifiers.Menu;

    /// <summary>Items that follow the state of the window (disabled when they can't run).</summary>
    private readonly List<(MenuFlyoutItem Item, Func<bool> Enabled)> menuStates = [];
    private MenuFlyoutItem? sidebarItem;

    private TextEditor? Edit => ActiveEditor?.Editor;

    private void Accelerator(Shortcut shortcut, Action action, Func<bool>? enabled = null)
    {
        var accelerator = new KeyboardAccelerator { Key = shortcut.Key, Modifiers = shortcut.Modifiers };
        accelerator.Invoked += (_, e) =>
        {
            e.Handled = true;
            if (enabled?.Invoke() ?? true) action();
        };
        Root.KeyboardAccelerators.Add(accelerator);
    }

    private static MenuBarItem Group(string key) => new() { Title = Loc.Get(key) };

    /// <summary>
    /// Adds a menu item. `shortcut` is shown on it and, with `register`, also triggers `run` anywhere in the window;
    /// commands the editor handles by itself (Ctrl+B, Ctrl+Z…) are only shown.
    /// </summary>
    private MenuFlyoutItem AddItem(MenuBarItem group, string textKey, Action run, Shortcut? shortcut = null, Func<bool>? enabled = null, bool register = true)
    {
        var item = new MenuFlyoutItem { Text = Loc.Get(textKey) };
        if (shortcut is { } s) item.KeyboardAcceleratorTextOverride = s.Display;
        item.Click += (_, _) =>
        {
            if (enabled?.Invoke() ?? true) run();
        };
        group.Items.Add(item);
        if (shortcut is { } key && register) Accelerator(key, run, enabled);
        if (enabled is not null) menuStates.Add((item, enabled));
        return item;
    }

    private static void AddSeparator(MenuBarItem group) => group.Items.Add(new MenuFlyoutSeparator());

    /// <summary>Re-evaluates which items can run; called when the tab or the document state changes and when a menu opens.</summary>
    private void RefreshMenu()
    {
        foreach (var (item, enabled) in menuStates) item.IsEnabled = enabled();
    }

    private void BuildMenu()
    {
        var file = Group("MenuFile");
        AddItem(file, "NewNote", () => _ = model.NewNoteAsync(), new(VirtualKey.N, Ctrl));
        AddItem(file, "NewTab", () => model.NewTab(), new(VirtualKey.T, Ctrl));
        AddItem(file, "NewFolder", () => _ = NewFolderAsync(null), new(VirtualKey.N, Ctrl | Shift));
        AddSeparator(file);
        AddItem(file, "AddFolderToWorkspace", () => _ = AddRootAsync(), new(VirtualKey.O, Ctrl | Shift));
        AddSeparator(file);
        AddItem(file, "CloseTab", CloseActiveTabOrWindow, new(VirtualKey.W, Ctrl));
        AddSeparator(file);
        AddItem(file, "Save", () => _ = model.SaveActiveAsync(), new(VirtualKey.S, Ctrl));
        AddItem(file, "SaveAs", () => _ = SaveAsAsync(), new(VirtualKey.S, Ctrl | Shift), () => model.ActiveDocument is not null);
        AddSeparator(file);
        AddItem(file, "Exit", Close);

        var edit = Group("MenuEdit");
        AddItem(edit, "Undo", () => InEditor(e => e.Undo()), new(VirtualKey.Z, Ctrl), () => Edit?.CanUndo == true, register: false);
        AddItem(edit, "Redo", () => InEditor(e => e.Redo()), new(VirtualKey.Y, Ctrl), () => Edit?.CanRedo == true, register: false);
        AddSeparator(edit);
        AddItem(edit, "Cut", () => InEditor(e => e.Cut()), new(VirtualKey.X, Ctrl), () => Edit is { IsEditable: true, HasSelection: true }, register: false);
        AddItem(edit, "Copy", () => InEditor(e => e.Copy()), new(VirtualKey.C, Ctrl), () => Edit is { HasSelection: true }, register: false);
        AddItem(edit, "Paste", () => InEditor(e => e.Paste()), new(VirtualKey.V, Ctrl), () => Edit is { IsEditable: true }, register: false);
        AddItem(edit, "SelectAll", () => InEditor(e => e.SelectAll()), new(VirtualKey.A, Ctrl), () => Edit is not null, register: false);
        AddSeparator(edit);
        AddItem(edit, "SearchNotes", ShowSidebarSearch, new(VirtualKey.F, Ctrl | Shift));
        AddSeparator(edit);
        AddItem(edit, "Format", () => ActiveEditor?.Format(), new(VirtualKey.F, Shift | Alt), () => Edit?.CanFormat == true);

        // Ctrl+F is reserved for find in the note (the find bar comes with the editor commands).
        var format = Group("MenuFormat");
        AddItem(format, "Bold", () => InEditor(e => e.ToggleBold()), new(VirtualKey.B, Ctrl), () => Edit is MarkdownEditor { IsEditable: true }, register: false);
        AddItem(format, "Italic", () => InEditor(e => e.ToggleItalic()), new(VirtualKey.I, Ctrl), () => Edit is MarkdownEditor { IsEditable: true }, register: false);

        var view = Group("MenuView");
        sidebarItem = AddItem(view, "HideSidebar", () => SetSidebarOpen(!Split.IsPaneOpen, save: true), new(VirtualKey.B, Ctrl | Shift));
        AddSeparator(view);
        AddItem(view, "ShowNextTab", () => CycleTab(1), new(VirtualKey.Tab, Ctrl), () => model.Tabs.Count > 1);
        AddItem(view, "ShowPreviousTab", () => CycleTab(-1), new(VirtualKey.Tab, Ctrl | Shift), () => model.Tabs.Count > 1);
        AddItem(view, "SelectNextTab", () => CycleTab(1), new(CloseBracketKey, Ctrl | Shift), () => model.Tabs.Count > 1);
        AddItem(view, "SelectPreviousTab", () => CycleTab(-1), new(OpenBracketKey, Ctrl | Shift), () => model.Tabs.Count > 1);
        // Ctrl+1..8 pick that tab, Ctrl+9 the last one; no menu items, they would only clutter the menu.
        for (var number = 1; number <= 9; number++)
        {
            var n = number;
            Accelerator(new(VirtualKey.Number0 + n, Ctrl), () => SelectTab(n));
        }

        var help = Group("MenuHelp");
        AddItem(help, "AboutNotes", () => _ = ShowAboutAsync());

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
        else Close();
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
