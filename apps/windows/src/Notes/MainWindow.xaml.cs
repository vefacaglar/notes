using System.Runtime.InteropServices;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using NotesCore;
using Windows.Foundation;
using Windows.Foundation.Collections;
using Windows.Graphics;
using Windows.Storage.Pickers;
using Windows.System;

namespace Notes;

/// <summary>The only window: the workspace sidebar, the open files as tabs in the title bar, and the active tab's editor.</summary>
public sealed partial class MainWindow : Window
{
    private readonly NotesModel model;
    private readonly Dictionary<NoteTab, TabViewItem> tabItems = [];
    /// <summary>Editors stay alive while their tab is open, so switching tabs keeps cursor, scroll and undo.</summary>
    private readonly Dictionary<NoteTab, NoteEditorView> editors = [];
    private readonly Dictionary<NoteTab, (NoteDocument Document, Action Update)> tabWatchers = [];
    private bool syncingTabs;
    private readonly Func<Task> requestClose;
    private RectInt32[] passthrough = [];
    internal MainWindow(NotesModel model, SessionWindow? session = null)
    {
        this.model = model;
        InitializeComponent();
        if (AppSettings.ThemeOverride is { } theme) Root.RequestedTheme = theme;
        Root.LayoutUpdated += (_, _) => UpdateStrokeGap();
        WindowSupport.Place(this, session?.Bounds, 1100, 720);
        TrackWindow(session?.Bounds);
        WindowSupport.ExtendIntoTitleBar(this, TitleBar);
        requestClose = WindowSupport.GuardClose(this, PrepareToCloseAsync);
        // The tabs and the strip's buttons move when the window or a tab changes size, and after tabs are added.
        TitleBar.SizeChanged += (_, _) => UpdatePassthrough();
        Tabs.SizeChanged += (_, _) => UpdatePassthrough();
        Menu.SizeChanged += (_, _) => UpdatePassthrough();
        SessionGuard.Install(this);
        SessionGuard.BeforeEnd = SaveSessionNow;
        model.OwnerWindow = WinRT.Interop.WindowNative.GetWindowHandle(this);

        ((ThemeShadow)EditorLayer.Shadow).Receivers.Add(ShadowReceiver);
        Sidebar.RestoreExpansion(session?.CollapsedRoots, session?.ExpandedFolders);
        Sidebar.ExpansionChanged += SaveSessionSoon;
        SetSidebarOpen(session?.SidebarVisible ?? !AppSettings.SidebarCollapsed, save: false);
        Sidebar.Attach(model, this);
        model.TabsChanged += SyncTabs;
        model.ActiveTabChanged += ShowActiveTab;
        model.ErrorChanged += ShowError;
        model.WindowRequested += BringToFront;
        Closed += (_, _) =>
        {
            model.TabsChanged -= SyncTabs;
            model.ActiveTabChanged -= ShowActiveTab;
            model.ErrorChanged -= ShowError;
            model.WindowRequested -= BringToFront;
            sessionEnabled = false;
            Sidebar.Detach();
            foreach (var editor in editors.Values) editor.Detach();
            editors.Clear();
        };

        BuildMenu();
        SyncTabs();
        ShowError();
    }

    // MARK: Session

    private bool sessionEnabled;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer sessionTimer = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread().CreateTimer();

    /// <summary>Called once the workspace and the last session's tabs are back: from now on changes are saved.</summary>
    internal void EnableSession()
    {
        sessionEnabled = true;
        sessionTimer.Interval = TimeSpan.FromSeconds(1);
        sessionTimer.IsRepeating = false;
        sessionTimer.Tick += (_, _) =>
        {
            sessionTimer.Stop();
            _ = SaveSessionAsync();
        };
        model.TabsChanged += SaveSessionSoon;
        model.ActiveTabChanged += SaveSessionSoon;
    }

    /// <summary>Something worth restoring changed: saved a moment later.</summary>
    internal void SaveSessionSoon()
    {
        if (!sessionEnabled) return;
        sessionTimer.Stop();
        sessionTimer.Start();
    }

    /// <summary>Captures the window on the UI thread (selection and scroll are read from the editors now) and writes it off it.</summary>
    internal Task SaveSessionAsync()
    {
        if (!sessionEnabled || !SessionStore.CanWrite) return Task.CompletedTask;
        sessionTimer.Stop();
        var state = CaptureSession();
        return Task.Run(() => SessionStore.Write(state));
    }

    /// <summary>Logoff and shutdown: nothing may wait for the dispatcher.</summary>
    private void SaveSessionNow()
    {
        if (!sessionEnabled || !SessionStore.CanWrite) return;
        SessionStore.Write(CaptureSession());
    }

    private SessionWindow CaptureSession()
    {
        var tabs = new List<SessionTab>();
        int? active = null;
        foreach (var tab in model.Tabs)
        {
            if (tab.Document is not { } document) continue;
            if (tab == model.ActiveTab) active = tabs.Count;
            var view = editors.TryGetValue(tab, out var editor) ? editor.CaptureViewState() : tab.ViewState;
            tabs.Add(new SessionTab
            {
                File = document.IsDraft ? null : document.Path,
                Draft = document.IsDraft ? System.IO.Path.GetFileName(document.Path) : null,
                ShowsSource = tab.ShowsSource,
                View = SessionView.From(view),
                Reading = tab.Reading ? true : null,
            });
        }
        return new SessionWindow
        {
            Tabs = tabs,
            ActiveTab = active,
            SidebarVisible = Split.IsPaneOpen,
            CollapsedRoots = Sidebar.CollapsedRootPaths,
            ExpandedFolders = Sidebar.ExpandedFolderPaths,
            Bounds = windowBounds?.Copy(),
        };
    }

    private SessionBounds? windowBounds;

    /// <summary>Remembers where the window is while it is neither maximized nor minimized, and whether it is maximized.</summary>
    private void TrackWindow(SessionBounds? saved)
    {
        // A window that starts maximized has no normal rectangle to read yet: keep the saved one.
        windowBounds = saved?.Copy();
        void Update()
        {
            if (AppWindow.Presenter is not OverlappedPresenter presenter || presenter.State == OverlappedPresenterState.Minimized) return;
            var maximized = presenter.State == OverlappedPresenterState.Maximized;
            if (maximized && windowBounds is { } known)
            {
                known.Maximized = true;
                return;
            }
            windowBounds = new SessionBounds
            {
                X = AppWindow.Position.X, Y = AppWindow.Position.Y, Width = AppWindow.Size.Width, Height = AppWindow.Size.Height,
                Maximized = maximized,
            };
        }
        Update();
        AppWindow.Changed += (_, e) =>
        {
            if (!e.DidSizeChange && !e.DidPositionChange && !e.DidPresenterChange) return;
            Update();
            SaveSessionSoon();
        };
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetForegroundWindow(IntPtr window);

    private void BringToFront()
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter) presenter.Restore();
        Activate();
        SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
    }

    // MARK: Title bar

    /// <summary>The sidebar toggle and the tab strip's tabs and buttons stay clickable; the rest of the title bar drags.</summary>
    private void UpdatePassthrough()
    {
        if (Content.XamlRoot is not { } root) return;
        var scale = root.RasterizationScale;
        CaptionColumn.Width = new GridLength(AppWindow.TitleBar.RightInset / scale);
        var elements = new List<FrameworkElement> { SidebarToggle, Menu };
        Collect(Tabs, elements);
        var rects = elements
            .Where(e => e.Visibility == Visibility.Visible && e.ActualWidth > 0 && e.ActualHeight > 0)
            .Select(e => e.TransformToVisual(null).TransformBounds(new Rect(0, 0, e.ActualWidth, e.ActualHeight)))
            .Select(r => new RectInt32((int)(r.X * scale), (int)(r.Y * scale), (int)Math.Ceiling(r.Width * scale), (int)Math.Ceiling(r.Height * scale)))
            .ToArray();
        if (rects.SequenceEqual(passthrough)) return;
        passthrough = rects;
        InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Passthrough, rects);
    }

    private static void Collect(DependencyObject parent, List<FrameworkElement> into)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is TabViewItem or ButtonBase) into.Add((FrameworkElement)child);
            else Collect(child, into);
        }
    }

    private void SidebarToggle_Click(object sender, RoutedEventArgs e) => SetSidebarOpen(!Split.IsPaneOpen, save: true);

    private void SetSidebarOpen(bool open, bool save)
    {
        Split.IsPaneOpen = open;
        var label = open ? Loc.Get("HideSidebar") : Loc.Get("ShowSidebar");
        ToolTipService.SetToolTip(SidebarToggle, $"{label} (Ctrl+Shift+B)");
        if (sidebarItem is not null) sidebarItem.Text = label;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(SidebarToggle, label);
        if (save) SaveSessionSoon();
    }

    // MARK: Tabs

    private NoteEditorView? ActiveEditor => model.ActiveTab is { } tab && editors.TryGetValue(tab, out var editor) ? editor : null;

    private void SyncTabs()
    {
        syncingTabs = true;
        try
        {
            foreach (var tab in tabItems.Keys.Except(model.Tabs).ToList())
            {
                Tabs.TabItems.Remove(tabItems[tab]);
                tabItems.Remove(tab);
                headers.Remove(tab);
            }
            for (var i = 0; i < model.Tabs.Count; i++)
            {
                var tab = model.Tabs[i];
                if (!tabItems.TryGetValue(tab, out var item))
                {
                    item = new TabViewItem { Tag = tab };
                    item.SizeChanged += (_, _) => UpdatePassthrough();
                    item.ContextFlyout = BuildTabMenu(tab);
                    var created = item;
                    // WinUI closes a tab on a middle click itself; this covers the case where it does not (closing is re-entrancy safe).
                    item.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, e) =>
                    {
                        if (e.GetCurrentPoint(created).Properties.PointerUpdateKind != PointerUpdateKind.MiddleButtonReleased) return;
                        e.Handled = true;
                        _ = CloseTabAsync(tab);
                    }), true);
                    tabItems[tab] = item;
                }
                var index = Tabs.TabItems.IndexOf(item);
                if (index != i)
                {
                    if (index >= 0) Tabs.TabItems.RemoveAt(index);
                    Tabs.TabItems.Insert(i, item);
                }
            }
            foreach (var tab in tabWatchers.Keys.ToList())
            {
                if (model.Tabs.Contains(tab) && tab.Document == tabWatchers[tab].Document) continue;
                tabWatchers[tab].Document.StateChanged -= tabWatchers[tab].Update;
                tabWatchers.Remove(tab);
            }
            foreach (var tab in model.Tabs)
            {
                UpdateHeader(tab);
                if (tab.Document is { } document && !tabWatchers.ContainsKey(tab))
                {
                    var current = tab;
                    void Update() => UpdateHeader(current);
                    document.StateChanged += Update;
                    tabWatchers[tab] = (document, Update);
                }
            }
            foreach (var tab in editors.Keys.ToList())
            {
                if (model.Tabs.Contains(tab) && tab.Document == editors[tab].Document) continue;
                editors[tab].Detach();
                editors.Remove(tab);
            }
        }
        finally
        {
            syncingTabs = false;
        }
        ShowActiveTab();
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, UpdatePassthrough);
    }

    private bool reorderQueued;

    /// <summary>A drag in the tab strip reordered the items: the model follows (after the whole move: remove, then insert).</summary>
    private void Tabs_TabItemsChanged(TabView sender, IVectorChangedEventArgs args)
    {
        if (syncingTabs || reorderQueued) return;
        reorderQueued = true;
        DispatcherQueue.TryEnqueue(() =>
        {
            reorderQueued = false;
            if (syncingTabs) return;
            model.ReorderTabs([.. Tabs.TabItems.OfType<TabViewItem>().Select(i => i.Tag).OfType<NoteTab>()]);
        });
    }

    private MenuFlyout BuildTabMenu(NoteTab tab)
    {
        var menu = new MenuFlyout();
        var close = new MenuFlyoutItem { Text = Loc.Get("CloseTab"), KeyboardAcceleratorTextOverride = "Ctrl+W" };
        close.Click += (_, _) => _ = CloseTabAsync(tab);
        var others = new MenuFlyoutItem { Text = Loc.Get("CloseOtherTabs") };
        others.Click += (_, _) => _ = CloseOtherTabsAsync(tab);
        var separator = new MenuFlyoutSeparator();
        var reveal = new MenuFlyoutItem { Text = Loc.Get("ShowInExplorer") };
        reveal.Click += (_, _) =>
        {
            if (tab.Document is { IsDraft: false } document) model.RevealFileInExplorer(document.Path);
        };
        menu.Items.Add(close);
        menu.Items.Add(others);
        menu.Items.Add(separator);
        menu.Items.Add(reveal);
        menu.Opening += (_, _) =>
        {
            others.IsEnabled = model.Tabs.Count > 1;
            var isFile = tab.Document is { IsDraft: false };
            separator.Visibility = reveal.Visibility = isFile ? Visibility.Visible : Visibility.Collapsed;
        };
        return menu;
    }

    /// <summary>Closes every tab but `keep`, one after the other; a draft with text or a failed save asks first, and the
    /// rest stays open when the user cancels.</summary>
    private async Task CloseOtherTabsAsync(NoteTab keep)
    {
        model.ActivateTab(keep);
        foreach (var other in model.Tabs.Where(t => t != keep).ToList())
        {
            await CloseTabAsync(other);
            if (model.Tabs.Contains(other)) return;
        }
    }

    /// <summary>What each tab header shows, so a keystroke only rebuilds it when the title or the dot changes.</summary>
    private readonly Dictionary<NoteTab, (string? Title, bool Dirty, string? Path, string? ReadOnly)> headers = [];

    /// <summary>Display name, a dot while there are unsaved edits, the path as tooltip.</summary>
    private void UpdateHeader(NoteTab tab)
    {
        if (!tabItems.TryGetValue(tab, out var item)) return;
        var document = tab.Document;
        var state = (document?.Title, document?.ShowsUnsavedDot == true, document?.Path, document?.ReadOnlyReason);
        if (headers.TryGetValue(tab, out var shown) && shown == state && item.Header is not null) return;
        // A file that was renamed (automatically or by hand) changes the session.
        if (shown.Path != state.Path) SaveSessionSoon();
        headers[tab] = state;
        // Inherits the tab's text colour, so it follows the theme.
        var dot = new TextBlock
        {
            Text = "\u25CF",
            FontSize = 8,
            Opacity = 0.6,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = document?.ShowsUnsavedDot == true ? Visibility.Visible : Visibility.Collapsed,
        };
        var header = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Children = { new TextBlock { Text = document?.Title ?? Loc.Get("NewTab"), MaxWidth = 220, TextTrimming = TextTrimming.CharacterEllipsis } },
        };
        if (document?.ReadOnlyReason is not null)
        {
            header.Children.Add(new FontIcon { Glyph = "", FontSize = 11, Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center });
        }
        header.Children.Add(dot);
        item.Header = header;
        item.IconSource = new FontIconSource { Glyph = document is null ? "" : SidebarView.Glyph(document.FileName) };
        var tip = document is { IsDraft: false } ? document.Path : null;
        if (document?.ReadOnlyReason is { } reason) tip = tip is null ? reason : tip + "\n" + reason;
        ToolTipService.SetToolTip(item, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(item, document?.Title ?? Loc.Get("NewTab"));
        if (tab == model.ActiveTab) UpdateTitle();
    }

    private void ShowActiveTab()
    {
        var tab = model.ActiveTab;
        syncingTabs = true;
        try
        {
            Tabs.SelectedItem = tab is not null && tabItems.TryGetValue(tab, out var item) ? item : null;
        }
        finally
        {
            syncingTabs = false;
        }
        NoteEditorView? editor = null;
        if (tab?.Document is { } document && !editors.TryGetValue(tab, out editor))
        {
            editor = new NoteEditorView(document);
            editors[tab] = editor;
            if (tab.ViewState is { } view) editor.ApplyViewState(view);
            tab.ViewState = null;
        }
        if (EditorHost.Child != editor) EditorHost.Child = editor;
        Placeholder.Visibility = editor is null ? Visibility.Visible : Visibility.Collapsed;
        UpdateTitle();
        RefreshMenu();
    }

    private void UpdateTitle() => Title = model.ActiveDocument?.Title ?? Loc.Get("AppName");

    private (double Start, double End, double Width, double Height) strokeGeometry;

    /// <summary>Opens the layer's top stroke under the selected tab, so the tab and the layer read as one surface.</summary>
    private void UpdateStrokeGap()
    {
        const double band = 2;
        double width = EditorLayer.ActualWidth, height = EditorLayer.ActualHeight, start = 0, end = 0;
        if (Tabs.SelectedItem is TabViewItem { ActualWidth: > 0 } item && item.XamlRoot is not null)
        {
            var left = item.TransformToVisual(EditorLayer).TransformPoint(new Point(0, 0)).X;
            start = Math.Clamp(left, 0, width);
            end = Math.Clamp(left + item.ActualWidth, 0, width);
            if (end <= start) start = end = 0;
        }
        if (strokeGeometry == (start, end, width, height)) return;
        strokeGeometry = (start, end, width, height);
        StrokeBody.Clip = new RectangleGeometry { Rect = new Rect(0, start < end ? band : 0, width, Math.Max(0, height - (start < end ? band : 0))) };
        StrokeBefore.Clip = new RectangleGeometry { Rect = start < end ? new Rect(0, 0, start, band) : new Rect(0, 0, 0, 0) };
        StrokeAfter.Clip = new RectangleGeometry { Rect = start < end ? new Rect(end, 0, width - end, band) : new Rect(0, 0, 0, 0) };
    }

    private void Tabs_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (syncingTabs || Tabs.SelectedItem is not TabViewItem { Tag: NoteTab tab }) return;
        model.ActivateTab(tab);
    }

    private void Tabs_AddTabButtonClick(TabView sender, object args) => model.NewTab();

    private void Tabs_TabCloseRequested(TabView sender, TabViewTabCloseRequestedEventArgs args)
    {
        if (args.Tab.Tag is NoteTab tab) _ = CloseTabAsync(tab);
    }

    /// <summary>Before the window closes. Drafts are kept by the store, unless this run could only use a throwaway one: then
    /// they are asked about like unsaved files.</summary>
    private async Task<bool> PrepareToCloseAsync()
    {
        if (Drafts.IsFallback)
        {
            foreach (var tab in model.Tabs.ToList())
            {
                if (tab.Document is not { IsDraft: true } draft || Synced(draft).Length == 0) continue;
                await CloseTabAsync(tab);
                if (model.Tabs.Contains(tab)) return false;
            }
        }
        if (!await model.PrepareToCloseAsync(ConfirmDropAsync)) return false;
        // After the saves: an automatic rename may have changed a path. The editors are still alive to read the caret from.
        await SaveSessionAsync();
        // The window is going: a later capture would find the editors gone and lose the views.
        sessionEnabled = false;
        return true;
    }

    private static string Synced(NoteDocument draft)
    {
        draft.Sync();
        return draft.Text;
    }

    private readonly HashSet<NoteTab> closing = [];

    /// <summary>Closes a tab (the close button, a middle click, Ctrl+W, the menus). A draft needs no saving to close the
    /// window, but closing its tab asks when it has text. Closing the last tab closes the window, as in other tabbed apps
    /// with one window (docs/format.md, "App state").</summary>
    private async Task CloseTabAsync(NoteTab tab)
    {
        if (!model.Tabs.Contains(tab) || !closing.Add(tab)) return;
        try
        {
            if (!await TryCloseTabAsync(tab)) return;
        }
        finally
        {
            closing.Remove(tab);
        }
        if (model.Tabs.Count == 0) await requestClose();
    }

    /// <summary>True when the tab is gone.</summary>
    private async Task<bool> TryCloseTabAsync(NoteTab tab)
    {
        if (tab.Document is { IsDraft: true } draft)
        {
            draft.Sync();
            if (draft.Text.Length > 0)
            {
                if (Content.XamlRoot is not { } root) return false;
                var dialog = new ContentDialog
                {
                    Title = Loc.Format("SaveDraftTitle", draft.Name),
                    Content = new TextBlock { Text = Loc.Get("SaveDraftBody"), TextWrapping = TextWrapping.Wrap },
                    PrimaryButtonText = Loc.Get("Save"),
                    SecondaryButtonText = Loc.Get("DontSave"),
                    CloseButtonText = Loc.Get("Cancel"),
                    DefaultButton = ContentDialogButton.Primary,
                };
                switch (await Dialogs.ShowAsync(root, dialog))
                {
                    case ContentDialogResult.Primary:
                        if (!await model.SaveDraftAsync(draft)) return false;
                        break;
                    case ContentDialogResult.Secondary:
                        await model.DiscardDraftAsync(tab);
                        return true;
                    default:
                        return false;
                }
            }
            else
            {
                await model.DiscardDraftAsync(tab);
                return true;
            }
        }
        return await model.CloseTabAsync(tab, ConfirmDropAsync);
    }

    /// <summary>Ctrl+Shift+S: the active note (a draft or a file) to a file the user picks, which the tab then shows.</summary>
    private async Task SaveAsAsync()
    {
        if (model.ActiveDocument is not { } document) return;
        document.Sync();
        var folder = await model.TargetFolderAsync();
        var title = document.IsDraft ? NoteStore.Title(document.Text) ?? NoteStore.UntitledName : document.Name;
        var picker = new Microsoft.Windows.Storage.Pickers.FileSavePicker(AppWindow.Id)
        {
            SuggestedFileName = document.IsDraft || document.IsNote ? title + ".md" : document.FileName,
        };
        if (document.IsDraft || document.IsNote) picker.FileTypeChoices.Add(Loc.Get("MarkdownFiles"), [".md"]);
        picker.FileTypeChoices.Add(Loc.Get("AllFiles"), ["*"]);
        var start = !document.IsDraft ? System.IO.Path.GetDirectoryName(document.Path) : folder?.FullPath;
        if (start is not null && Directory.Exists(start)) picker.SuggestedFolder = start;
        if (await picker.PickSaveFileAsync() is { } result) await model.SaveAsAsync(document, result.Path);
    }

    /// <summary>
    /// A file's save failed while its tab (or the window) closes: "Save" tries again, "Don't Save" discards the edits,
    /// "Cancel" keeps it open. A conflict that was already resolved into a copy is only reported.
    /// </summary>
    private async Task<bool> ConfirmDropAsync(NoteDocument document)
    {
        if (Content.XamlRoot is not { } root) return false;
        while (true)
        {
            if (document.TrashDialog is { IsCompleted: false } pending)
            {
                // The dialog about the same lost edits is already open: its outcome settles this too.
                await pending;
                document.Error = null;
                continue;
            }
            var message = document.Error ?? "";
            document.Error = null;
            if (!document.HasUnsavedChanges)
            {
                if (message.Length > 0) await Dialogs.MessageAsync(root, Loc.Get("FileChangedTitle"), message);
                return true;
            }
            var abandoned = document.IsAbandoned;
            var dialog = new ContentDialog
            {
                Title = Loc.Format(abandoned ? "TrashedTitle" : "SaveFailedTitle", document.Name),
                Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
                PrimaryButtonText = Loc.Get(abandoned ? "CopyToClipboard" : "Save"),
                SecondaryButtonText = Loc.Get("DontSave"),
                CloseButtonText = Loc.Get("Cancel"),
                DefaultButton = ContentDialogButton.Primary,
            };
            switch (await Dialogs.ShowAsync(root, dialog))
            {
                case ContentDialogResult.Primary:
                    if (abandoned)
                    {
                        CopyToClipboard(document.Text);
                        document.Revert();
                        return true;
                    }
                    if (await document.FlushAsync()) return true;
                    break;
                case ContentDialogResult.Secondary:
                    document.Revert();
                    return true;
                default:
                    document.Error = message;
                    return false;
            }
        }
    }

    private void ShowError()
    {
        ErrorBar.Message = model.ErrorMessage ?? "";
        ErrorBar.IsOpen = model.ErrorMessage is not null;
    }

    private void ErrorBar_CloseButtonClick(InfoBar sender, object args) => model.ShowError(null);

    // MARK: Commands with dialogs

    internal async Task NewFolderAsync(ItemRef? parent)
    {
        if (Content.XamlRoot is not { } root || (parent ?? await model.TargetFolderAsync()) is not { } folder) return;
        if (await Dialogs.AskNameAsync(root, Loc.Get("NewFolder"), Loc.Get("Create"), Loc.Get("NewFolder")) is { } name)
        {
            await model.CreateFolderAsync(name, folder);
        }
    }

    internal async Task RenameAsync(ItemRef item)
    {
        if (item.IsRoot || Content.XamlRoot is not { } root) return;
        var target = model.Track(item);
        try
        {
            if (await Dialogs.AskNameAsync(root, Loc.Get("Rename"), Loc.Get("Rename"), NoteStore.DisplayName(item.Path)) is { } name)
            {
                await model.RenameAsync(target, name);
            }
        }
        finally
        {
            model.Untrack(target);
        }
    }

    internal async Task TrashAsync(ItemRef item)
    {
        if (item.IsRoot || Content.XamlRoot is not { } root) return;
        var target = model.Track(item);
        try
        {
            var title = Loc.Format("TrashConfirmTitle", NoteStore.DisplayName(item.Path));
            if (await Dialogs.ConfirmAsync(root, title, "", Loc.Get("MoveToRecycleBin"))) await model.TrashAsync(target, TrashedWithEditsAsync);
        }
        finally
        {
            model.Untrack(target);
        }
    }

    /// <summary>A file went to the Recycle Bin while it still had edits (typed during the move). They are never written
    /// back, which would recreate the file; the user can copy them instead.</summary>
    private async Task TrashedWithEditsAsync(NoteDocument document)
    {
        if (Content.XamlRoot is not { } root) return;
        var dialog = new ContentDialog
        {
            Title = Loc.Format("TrashedTitle", document.Name),
            Content = new TextBlock
            {
                Text = Loc.Get("TrashedBody"),
                TextWrapping = TextWrapping.Wrap,
            },
            PrimaryButtonText = Loc.Get("CopyToClipboard"),
            CloseButtonText = Loc.Get("Close"),
            DefaultButton = ContentDialogButton.Primary,
        };
        if (await Dialogs.ShowAsync(root, dialog) != ContentDialogResult.Primary) return;
        CopyToClipboard(document.Text);
    }

    private static void CopyToClipboard(string text)
    {
        var package = new Windows.ApplicationModel.DataTransfer.DataPackage();
        package.SetText(text);
        Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(package);
    }

    /// <summary>Nothing on disk changes, so only unsaved edits in its tabs ask anything.</summary>
    internal Task RemoveRootAsync(RootFolder folder) => model.RemoveRootAsync(folder, ConfirmDropAsync);

    internal async Task AddRootAsync()
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, CommitButtonText = Loc.Get("Add") };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFolderAsync() is { } folder) await model.AddRootAsync(folder.Path);
    }
}
