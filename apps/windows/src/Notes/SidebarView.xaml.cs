using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using NotesCore;
using Windows.System;
using Windows.UI.Core;
using Windows.UI.Text;

namespace Notes;

/// <summary>A row of the tree: a root's section header, a folder or a file.</summary>
public sealed class SidebarItem
{
    internal SidebarItem(ItemRef item, NoteNode? node)
    {
        Item = item;
        Node = node;
    }

    internal ItemRef Item { get; }
    /// <summary>Null for a root's header.</summary>
    internal NoteNode? Node { get; }
    internal bool IsFolder => Node is null || Node.IsFolder;
    public string Name => Node?.Name ?? Item.Root.Name;
    public string Glyph => Node is null ? "" : Node.IsFolder ? "" : SidebarView.Glyph(Node.Path);
    public FontWeight Weight => Node is null ? FontWeights.SemiBold : FontWeights.Normal;
    public string? ToolTip => Node is null ? Item.Root.Root : null;
    /// <summary>With "Show preview in sidebar": the modified date and the first line after the title, under the name. Reading it
    /// asks the cache for the preview, which only rows that appear do.</summary>
    public string Detail => SidebarPreview.Detail(Item, Node);
    public Visibility DetailVisibility => Detail.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    /// <summary>The tree item's accessible name.</summary>
    public override string ToString() => Name;
}

/// <summary>The date and preview line of a file row.</summary>
internal static class SidebarPreview
{
    public static string Detail(ItemRef item, NoteNode? node)
    {
        if (node is not { IsFolder: false } || !AppSettings.ShowSidebarPreview) return "";
        string full;
        try { full = item.FullPath; }
        catch (NoteStoreException) { return ""; }
        PreviewCache.Shared.Request(full, node.Modified);
        var date = node.Modified is { } modified ? PreviewCache.DateText(modified) : "";
        var preview = PreviewCache.Shared.Get(full);
        return preview is null ? date : date.Length == 0 ? preview : date + "  " + preview;
    }
}

/// <summary>A search result, or the header of a root's results when there are several roots.</summary>
public sealed class HitItem
{
    internal HitItem(RootFolder root, SearchHit? hit)
    {
        Root = root;
        Hit = hit;
    }

    internal RootFolder Root { get; }
    internal SearchHit? Hit { get; }
    public string Glyph => Hit is null ? "" : SidebarView.Glyph(Hit.Path);
    public string Name => Hit is null ? Root.Name : NoteStore.DisplayName(Hit.Path);
    public FontWeight Weight => Hit is null ? FontWeights.SemiBold : FontWeights.Normal;
    public string Detail => Hit is { Line: { } line, Snippet: { } snippet } ? $"{line}: {snippet}" : Hit is null ? "" : NoteStore.Parent(Hit.Path);
    public Visibility DetailVisibility => Detail.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
}

/// <summary>One collapsible section per root folder with its tree in display order, or search results while searching.</summary>
public sealed partial class SidebarView : UserControl
{
    private NotesModel? model;
    private MainWindow? owner;

    /// <summary>A folder was expanded or collapsed (the session remembers which).</summary>
    internal event Action? ExpansionChanged;
    /// <summary>Set while the view itself changes the selection, so that doesn't count as the user's choice.</summary>
    private bool syncing;

    public SidebarView()
    {
        InitializeComponent();
        SetupLabels();
    }

    internal void Attach(NotesModel model, MainWindow owner)
    {
        this.model = model;
        this.owner = owner;
        model.RootsChanged += SyncTree;
        model.TreeChanged += OnTreeChanged;
        model.SelectionChanged += SyncSelection;
        model.HitsChanged += ShowHits;
        model.QueryChanged += SyncQuery;
        model.PinsChanged += SyncPinned;
        PreviewCache.Shared.Loaded += OnPreviewLoaded;
        AppSettings.EditorSettingChanged += OnSettingChanged;
        SyncTree();
        SyncQuery();
        SyncPinned();
    }

    internal void Detach()
    {
        if (model is null) return;
        model.RootsChanged -= SyncTree;
        model.TreeChanged -= OnTreeChanged;
        model.SelectionChanged -= SyncSelection;
        model.HitsChanged -= ShowHits;
        model.QueryChanged -= SyncQuery;
        model.PinsChanged -= SyncPinned;
        PreviewCache.Shared.Loaded -= OnPreviewLoaded;
        AppSettings.EditorSettingChanged -= OnSettingChanged;
    }

    /// <summary>A preview arrived: its row shows it (a node whose content is replaced is bound again).</summary>
    private void OnPreviewLoaded(string fullPath)
    {
        if (model is null || !AppSettings.ShowSidebarPreview) return;
        if (model.Locate(fullPath) is { } item && Find(item) is { } node) Refresh(node);
        if (model.PinnedItems.Any(p => p.Item.FullPath.Equals(fullPath, StringComparison.OrdinalIgnoreCase))) SyncPinned(force: true);
    }

    private static void Refresh(TreeViewNode node)
    {
        if (node.Content is SidebarItem old) node.Content = new SidebarItem(old.Item, old.Node);
    }

    private void OnSettingChanged(string key)
    {
        if (key == "showSidebarPreview")
        {
            RefreshAll(Tree.RootNodes);
            SyncPinned(force: true);
        }
        if (key is "sidebarSort" or "showNonMarkdownFiles" or "showSidebarPreview") SyncMoreMenu();
    }

    private static void RefreshAll(IList<TreeViewNode> nodes)
    {
        foreach (var node in nodes)
        {
            if (node.Content is SidebarItem { Node: { IsFolder: false } }) Refresh(node);
            else RefreshAll(node.Children);
        }
    }

    public void FocusSearch()
    {
        SearchBox.Focus(FocusState.Keyboard);
        SearchBox.SelectAll();
    }

    /// <summary>One icon per kind of file: notes, structured data, markup, code, tables, plain text.</summary>
    internal static string Glyph(string path)
    {
        if (NoteStore.IsNote(path)) return "";
        return CodeLanguages.FromPath(path) switch
        {
            CodeLanguage.Yaml or CodeLanguage.Toml => "",
            CodeLanguage.Shell => "",
            CodeLanguage.Markdown => "",
            CodeLanguage.PlainText => string.Equals(Path.GetExtension(path), ".csv", StringComparison.OrdinalIgnoreCase) ? "" : "",
            _ => "",
        };
    }

    private static bool CtrlDown =>
        InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down);

    // MARK: Tree

    private static SidebarItem ItemOf(TreeViewNode node) => (SidebarItem)node.Content;

    private void OnTreeChanged(RootFolder root)
    {
        if (Tree.RootNodes.FirstOrDefault(n => ItemOf(n).Item.Root == root) is not { } node)
        {
            SyncTree();
            return;
        }
        syncing = true;
        try
        {
            Sync(node.Children, root, root.Tree);
            // A node without children loses its expansion; sections stay open unless the user closed them.
            if (!collapsedRoots.Contains(root.Root)) node.IsExpanded = true;
        }
        finally
        {
            syncing = false;
        }
        SyncSelection();
    }

    /// <summary>Root sections the user collapsed (root paths), and the subfolders that are open (full paths). Both come back
    /// with the session, so they can name folders whose root hasn't loaded yet.</summary>
    private readonly HashSet<string> collapsedRoots = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> expandedFolders = new(StringComparer.OrdinalIgnoreCase);

    internal void RestoreExpansion(IEnumerable<string>? collapsed, IEnumerable<string>? expanded)
    {
        collapsedRoots.Clear();
        expandedFolders.Clear();
        foreach (var path in collapsed ?? []) collapsedRoots.Add(path);
        foreach (var path in expanded ?? []) expandedFolders.Add(path);
    }

    internal List<string> CollapsedRootPaths => [.. collapsedRoots.Order(StringComparer.OrdinalIgnoreCase)];

    /// <summary>The open subfolders; those a loaded tree no longer has are dropped.</summary>
    internal List<string> ExpandedFolderPaths => [.. expandedFolders.Where(StillExists).Order(StringComparer.OrdinalIgnoreCase)];

    private bool StillExists(string path)
    {
        var root = model?.Roots.FirstOrDefault(r => Paths.IsInside(path, r.Root));
        if (root is null || root.Tree.Count == 0 || Paths.Relative(path, root.Root) is not { } relative) return true;
        IReadOnlyList<NoteNode> nodes = root.Tree;
        foreach (var part in relative.Split('/'))
        {
            var next = nodes.FirstOrDefault(n => n.IsFolder && string.Equals(n.Name, part, StringComparison.OrdinalIgnoreCase));
            if (next is null) return false;
            nodes = next.Children ?? [];
        }
        return true;
    }

    private static string FullPath(RootFolder root, string path) => System.IO.Path.Join(root.Root, path.Replace('/', '\\'));

    private void Tree_Expanding(TreeView sender, TreeViewExpandingEventArgs args)
    {
        if (args.Node.Content is not SidebarItem item) return;
        var changed = item.Node is null
            ? collapsedRoots.Remove(item.Item.Root.Root)
            : item.IsFolder && expandedFolders.Add(FullPath(item.Item.Root, item.Item.Path));
        if (changed) ExpansionChanged?.Invoke();
    }

    private void Tree_Collapsed(TreeView sender, TreeViewCollapsedEventArgs args)
    {
        if (syncing || args.Node.Content is not SidebarItem item) return;
        var changed = item.Node is null
            ? collapsedRoots.Add(item.Item.Root.Root)
            : item.IsFolder && expandedFolders.Remove(FullPath(item.Item.Root, item.Item.Path));
        if (changed) ExpansionChanged?.Invoke();
    }

    /// <summary>Brings the tree view in line with the model, reusing nodes so expansion, selection and scrolling stay.</summary>
    private void SyncTree()
    {
        if (model is null) return;
        syncing = true;
        try
        {
            var nodes = Tree.RootNodes;
            for (var i = nodes.Count - 1; i >= 0; i--)
                if (!model.Roots.Contains(ItemOf(nodes[i]).Item.Root)) nodes.RemoveAt(i);
            for (var i = 0; i < model.Roots.Count; i++)
            {
                var root = model.Roots[i];
                var index = -1;
                for (var j = i; j < nodes.Count; j++)
                    if (ItemOf(nodes[j]).Item.Root == root) index = j;
                TreeViewNode node;
                if (index < 0)
                {
                    node = new TreeViewNode { Content = new SidebarItem(new ItemRef(root, ""), null), IsExpanded = !collapsedRoots.Contains(root.Root) };
                    nodes.Insert(i, node);
                }
                else
                {
                    node = nodes[index];
                    if (index != i)
                    {
                        nodes.RemoveAt(index);
                        nodes.Insert(i, node);
                    }
                }
                Sync(node.Children, root, root.Tree);
                if (!collapsedRoots.Contains(root.Root)) node.IsExpanded = true;
            }
        }
        finally
        {
            syncing = false;
        }
        SyncSelection();
        SyncUnavailable();
    }

    // MARK: Unavailable roots

    private void SyncUnavailable()
    {
        UnavailableList.Children.Clear();
        if (model is not null)
        {
            foreach (var root in model.UnavailableRoots) UnavailableList.Children.Add(BuildUnavailable(root));
        }
        UnavailableScroll.Visibility = UnavailableList.Children.Count > 0 && model?.IsSearching != true ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>A folder of the workspace that can't be opened right now: its name and the reason, greyed, with Retry and Remove.</summary>
    private UIElement BuildUnavailable(UnavailableRoot root)
    {
        var secondary = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        title.Children.Add(new FontIcon { Glyph = "\uE8B7", FontSize = 16, Foreground = secondary });
        title.Children.Add(new TextBlock { Text = root.Name, FontWeight = FontWeights.SemiBold, Foreground = secondary, TextTrimming = TextTrimming.CharacterEllipsis });
        var retry = new Button { Content = Loc.Get("Retry"), Padding = new Thickness(10, 2, 10, 3) };
        retry.Click += (_, _) => _ = model?.RetryRootAsync(root);
        var remove = new Button { Content = Loc.Get("RemoveFromWorkspace"), Padding = new Thickness(10, 2, 10, 3) };
        remove.Click += (_, _) => _ = model?.RemoveUnavailableRootAsync(root);
        var panel = new StackPanel { Spacing = 4, Padding = new Thickness(4, 0, 4, 0) };
        panel.Children.Add(title);
        panel.Children.Add(new TextBlock
        {
            Text = root.Reason,
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            Foreground = secondary,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 3,
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        panel.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { retry, remove } });
        ToolTipService.SetToolTip(panel, root.Path);
        var menu = new MenuFlyout();
        var retryItem = new MenuFlyoutItem { Text = Loc.Get("Retry") };
        retryItem.Click += (_, _) => _ = model?.RetryRootAsync(root);
        var removeItem = new MenuFlyoutItem { Text = Loc.Get("RemoveFromWorkspace") };
        removeItem.Click += (_, _) => _ = model?.RemoveUnavailableRootAsync(root);
        menu.Items.Add(retryItem);
        menu.Items.Add(removeItem);
        panel.ContextFlyout = menu;
        return panel;
    }

    /// <summary>Makes `nodes` match `items` in order, reusing the node of each existing item. Linear: unchanged lists
    /// only compare, changed ones are rebuilt from a path lookup.</summary>
    private void Sync(IList<TreeViewNode> nodes, RootFolder root, IReadOnlyList<NoteNode> items)
    {
        static (string, bool) Key(NoteNode node) => (node.Path, node.IsFolder);

        var same = nodes.Count == items.Count;
        for (var i = 0; same && i < items.Count; i++) same = Key(ItemOf(nodes[i]).Node!) == Key(items[i]);
        if (!same)
        {
            var existing = new Dictionary<(string, bool), TreeViewNode>();
            foreach (var node in nodes) existing[Key(ItemOf(node).Node!)] = node;
            nodes.Clear();
            foreach (var item in items)
            {
                nodes.Add(existing.TryGetValue(Key(item), out var node)
                    ? node
                    : new TreeViewNode
                    {
                        Content = new SidebarItem(new ItemRef(root, item.Path), item),
                        IsExpanded = item.IsFolder && expandedFolders.Contains(FullPath(root, item.Path)),
                    });
            }
        }
        for (var i = 0; i < items.Count; i++)
        {
            if (items[i].IsFolder) Sync(nodes[i].Children, root, items[i].Children ?? []);
            // A saved file: its date (and so its preview) changed.
            else if (ItemOf(nodes[i]).Node?.Modified != items[i].Modified) nodes[i].Content = new SidebarItem(new ItemRef(root, items[i].Path), items[i]);
        }
    }
    private TreeViewNode? Find(ItemRef item)
    {
        var rootNode = Tree.RootNodes.FirstOrDefault(n => ItemOf(n).Item.Root == item.Root);
        if (rootNode is null || item.IsRoot) return rootNode;
        var nodes = rootNode.Children;
        while (true)
        {
            TreeViewNode? next = null;
            foreach (var node in nodes)
            {
                var path = ItemOf(node).Item.Path;
                if (path == item.Path) return node;
                if (item.Path.StartsWith(path + "/", StringComparison.Ordinal)) next = node;
            }
            if (next is null) return null;
            nodes = next.Children;
        }
    }

    /// <summary>Selects the model's selection in the tree, expanding its parent folders.</summary>
    private void SyncSelection()
    {
        if (model is null) return;
        if (pinnedSelection is not null && pinnedSelection != model.Selection)
        {
            pinnedSelection = null;
            SelectPinned();
        }
        var target = model.Selection is { } item ? Find(item) : null;
        if (Tree.SelectedNode == target) return;
        syncing = true;
        try
        {
            for (var parent = target?.Parent; parent is not null; parent = parent.Parent) parent.IsExpanded = true;
            Tree.SelectedNode = target;
        }
        finally
        {
            syncing = false;
        }
    }

    private void Tree_SelectionChanged(TreeView sender, TreeViewSelectionChangedEventArgs args)
    {
        if (syncing || model is null || sender.SelectedNode is not { } node) return;
        var item = ItemOf(node);
        if (item.Item == model.Selection) return;
        _ = model.OpenItemAsync(item.Item, newTab: CtrlDown);
    }

    private void Tree_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Delete && Tree.SelectedNode is { } node && ItemOf(node).Node is not null)
        {
            e.Handled = true;
            _ = owner?.TrashAsync(ItemOf(node).Item);
        }
    }

    /// <summary>Builds the item's context menu: per root, folder or file.</summary>
    private void Item_ContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        if ((sender as FrameworkElement)?.DataContext is TreeViewNode node) ShowMenu(sender, args, ItemOf(node));
    }

    private void Pinned_ContextRequested(UIElement sender, ContextRequestedEventArgs args)
    {
        if ((sender as FrameworkElement)?.DataContext is SidebarItem item) ShowMenu(sender, args, item);
    }

    private void ShowMenu(UIElement sender, ContextRequestedEventArgs args, SidebarItem item)
    {
        if (model is null || owner is null) return;
        args.Handled = true;
        var menu = new MenuFlyout();
        void Add(string text, string glyph, Action action)
        {
            var entry = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
            entry.Click += (_, _) => action();
            menu.Items.Add(entry);
        }
        var target = item.Item;
        if (item.IsFolder)
        {
            Add(Loc.Get("NewNote"), "", () => _ = model.NewNoteAsync(target));
            Add(Loc.Get("NewFolder"), "", () => _ = owner.NewFolderAsync(target));
        }
        else
        {
            Add(Loc.Get("OpenInNewTab"), "", () => _ = model.OpenItemAsync(target, newTab: true));
            var full = target.FullPath;
            if (model.IsPinned(full)) Add(Loc.Get("Unpin"), "", () => model.TogglePin(full));
            else Add(Loc.Get("Pin"), "", () => model.TogglePin(full));
        }
        if (item.Node is not null) Add(Loc.Get("Rename"), "", () => _ = owner.RenameAsync(target));
        Add(Loc.Get("ShowInExplorer"), "", () => model.RevealInExplorer(target));
        menu.Items.Add(new MenuFlyoutSeparator());
        if (item.Node is null) Add(Loc.Get("RemoveFromWorkspace"), "", () => _ = owner.RemoveRootAsync(target.Root));
        else Add(Loc.Get("MoveToRecycleBin"), "", () => _ = owner.TrashAsync(target));
        if (args.TryGetPosition(sender, out var point)) menu.ShowAt(sender, point);
        else menu.ShowAt(sender as FrameworkElement);
    }

    private void SetupLabels()
    {
        Label(NewNoteButton, "NewNote", "NewNoteTip");
        Label(NewFolderButton, "NewFolder", "NewFolderTip");
        Label(AddFolderButton, "AddFolder", "AddFolderTip");
        Label(MoreButton, "MoreOptions", "MoreOptions");
        SyncMoreMenu();
        var current = AppSettings.Language;
        LangSystem.IsChecked = current == "system";
        LangEnglish.IsChecked = current == "en";
        LangTurkish.IsChecked = current == "tr";
    }

    private void SyncMoreMenu()
    {
        SortName.IsChecked = AppSettings.SidebarSort == "name";
        SortModified.IsChecked = AppSettings.SidebarSort == "modified";
        ShowOtherFiles.IsChecked = AppSettings.ShowOtherFiles;
        ShowPreview.IsChecked = AppSettings.ShowSidebarPreview;
    }

    private void MoreMenu_Opening(object sender, object e) => SyncMoreMenu();

    private void Sort_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string sort }) AppSettings.SidebarSort = sort;
        SyncMoreMenu();
    }

    private void ShowOtherFiles_Click(object sender, RoutedEventArgs e)
    {
        AppSettings.ShowOtherFiles = !AppSettings.ShowOtherFiles;
        SyncMoreMenu();
    }

    private void ShowPreview_Click(object sender, RoutedEventArgs e)
    {
        AppSettings.ShowSidebarPreview = !AppSettings.ShowSidebarPreview;
        SyncMoreMenu();
    }

    private static void Label(Button button, string name, string tip)
    {
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, Loc.Get(name));
        ToolTipService.SetToolTip(button, Loc.Get(tip));
    }

    private async void Language_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { Tag: string code }) return;
        try
        {
            AppSettings.SaveLanguage(code);
        }
        catch (Exception ex)
        {
            model?.ShowError(Loc.Format("SettingSaveFailed", Paths.Describe(ex)));
            return;
        }
        if (XamlRoot is { } root) await Dialogs.MessageAsync(root, Loc.Get("RestartTitle"), Loc.Get("RestartBody"));
    }

    private void NewNote_Click(object sender, RoutedEventArgs e) => _ = model?.NewNoteAsync();

    private void NewFolder_Click(object sender, RoutedEventArgs e) => _ = owner?.NewFolderAsync(null);

    private void AddRoot_Click(object sender, RoutedEventArgs e) => _ = owner?.AddRootAsync();

    // MARK: Pinned

    /// <summary>The pinned row the selection came from, if it was chosen there (the same file is also in the tree).</summary>
    private ItemRef? pinnedSelection;

    private void SyncPinned() => SyncPinned(force: false);

    private void SyncPinned(bool force)
    {
        if (model is null) return;
        var pinned = model.PinnedItems;
        PinnedPanel.Visibility = pinned.Count > 0 && !model.IsSearching ? Visibility.Visible : Visibility.Collapsed;
        if (!force && PinnedList.ItemsSource is List<SidebarItem> shown
            && shown.Count == pinned.Count && shown.Zip(pinned).All(p => p.First.Item == p.Second.Item && p.First.Node == p.Second.Node)) return;
        syncing = true;
        try
        {
            PinnedList.ItemsSource = pinned.Select(p => new SidebarItem(p.Item, p.Node)).ToList();
        }
        finally
        {
            syncing = false;
        }
        SelectPinned();
    }

    /// <summary>Selects the pinned row for pinnedSelection (none when it isn't pinned or wasn't chosen there).</summary>
    private void SelectPinned()
    {
        syncing = true;
        try
        {
            PinnedList.SelectedItem = pinnedSelection is { } item && PinnedList.ItemsSource is List<SidebarItem> shown
                ? shown.FirstOrDefault(s => s.Item == item)
                : null;
        }
        finally
        {
            syncing = false;
        }
    }

    private void Pinned_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (syncing || model is null || PinnedList.SelectedItem is not SidebarItem pinned) return;
        pinnedSelection = pinned.Item;
        _ = model.OpenItemAsync(pinned.Item, newTab: CtrlDown);
    }

    // MARK: Search

    private void SyncQuery()
    {
        if (model is null) return;
        if (SearchBox.Text != model.Query) SearchBox.Text = model.Query;
        ShowHits();
    }

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e) => model?.SetQuery(SearchBox.Text);

    private void SearchBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Escape || SearchBox.Text.Length == 0) return;
        e.Handled = true;
        SearchBox.Text = "";
    }

    private void ShowHits()
    {
        if (model is null) return;
        var searching = model.IsSearching;
        SyncPinned();
        Tree.Visibility = searching ? Visibility.Collapsed : Visibility.Visible;
        SyncUnavailable();
        var items = new List<HitItem>();
        if (searching)
        {
            // Grouped under a header per root when there are several.
            foreach (var group in model.Hits.GroupBy(h => h.Root))
            {
                if (model.Roots.Count > 1) items.Add(new HitItem(group.Key, null));
                items.AddRange(group.Select(h => new HitItem(h.Root, h.Hit)));
            }
        }
        syncing = true;
        try
        {
            Hits.ItemsSource = searching ? items : null;
        }
        finally
        {
            syncing = false;
        }
        Hits.Visibility = searching && items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        NoResults.Visibility = searching && items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        NoResults.Text = Loc.Format("NoResults", model.Query.Trim());
    }

    private void Hits_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (syncing || model is null || Hits.SelectedItem is not HitItem { Hit: { } hit } item) return;
        _ = model.OpenItemAsync(new ItemRef(item.Root, hit.Path), newTab: CtrlDown);
    }
}
