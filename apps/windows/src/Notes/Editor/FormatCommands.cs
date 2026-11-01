using Microsoft.UI.Xaml.Controls;
using NotesCore;
using Windows.System;

namespace Notes.Editor;

/// <summary>A command on the Markdown editor with its menu text (a resource key) and shortcut.</summary>
internal sealed record EditorCommand(
    string TextKey, Action<MarkdownEditor> Run, VirtualKey Key = VirtualKey.None, VirtualKeyModifiers Modifiers = VirtualKeyModifiers.None)
{
    public bool HasShortcut => Key != VirtualKey.None;

    public string ShortcutText => HasShortcut ? FormatCommands.Display(Key, Modifiers) : "";
}

/// <summary>
/// The Format commands, declared once for the Format menu, the right-click menu and the formatting bar. The shortcuts are
/// the macOS ones with Ctrl for ⌘ and Ctrl+Shift for ⌥⌘ and ⌃⌘, since Ctrl+Alt is AltGr on many keyboards (docs/format.md).
/// </summary>
internal static class FormatCommands
{
    private const VirtualKeyModifiers Ctrl = VirtualKeyModifiers.Control, CtrlShift = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift;

    /// <summary>VK_OEM_7, the key of "'" on a US keyboard.</summary>
    public const VirtualKey QuoteKey = (VirtualKey)0xDE;

    public static readonly EditorCommand Bold = new("Bold", e => e.Toggle(InlineStyle.Bold), VirtualKey.B, Ctrl);
    public static readonly EditorCommand Italic = new("Italic", e => e.Toggle(InlineStyle.Italic), VirtualKey.I, Ctrl);
    public static readonly EditorCommand Strikethrough = new("Strikethrough", e => e.Toggle(InlineStyle.Strikethrough), VirtualKey.X, CtrlShift);
    public static readonly EditorCommand InlineCode = new("InlineCode", e => e.Toggle(InlineStyle.Code), VirtualKey.C, CtrlShift);
    public static readonly EditorCommand Link = new("Link", e => e.InsertLink(), VirtualKey.K, Ctrl);
    public static readonly EditorCommand Heading1 = new("Heading1", e => e.Apply(LineStyle.Heading(1)), VirtualKey.Number1, CtrlShift);
    public static readonly EditorCommand Heading2 = new("Heading2", e => e.Apply(LineStyle.Heading(2)), VirtualKey.Number2, CtrlShift);
    public static readonly EditorCommand Heading3 = new("Heading3", e => e.Apply(LineStyle.Heading(3)), VirtualKey.Number3, CtrlShift);
    public static readonly EditorCommand Body = new("Body", e => e.Apply(LineStyle.Body), VirtualKey.Number0, CtrlShift);
    public static readonly EditorCommand BulletedList = new("BulletedList", e => e.Apply(LineStyle.Bullet), VirtualKey.Number8, CtrlShift);
    public static readonly EditorCommand NumberedList = new("NumberedList", e => e.Apply(LineStyle.Numbered), VirtualKey.Number7, CtrlShift);
    public static readonly EditorCommand Checklist = new("Checklist", e => e.Apply(LineStyle.Task), VirtualKey.L, CtrlShift);
    public static readonly EditorCommand Quote = new("Quote", e => e.Apply(LineStyle.Quote), QuoteKey, CtrlShift);
    public static readonly EditorCommand CodeBlock = new("CodeBlock", e => e.InsertCodeBlock(), VirtualKey.K, CtrlShift);
    public static readonly EditorCommand HorizontalRule = new("HorizontalRule", e => e.InsertRule(), VirtualKey.H, CtrlShift);
    public static readonly EditorCommand InsertTable = new("InsertTable", e => e.ShowTablePicker(), VirtualKey.T, CtrlShift);
    public static readonly EditorCommand ConvertToTable = new("ConvertToTable", e => e.ConvertToTable());
    public static readonly EditorCommand AddRowAbove = new("AddRowAbove", e => e.RunTableCommand(TableCommand.AddRow(above: true)));
    public static readonly EditorCommand AddRowBelow = new("AddRowBelow", e => e.RunTableCommand(TableCommand.AddRow(above: false)));
    public static readonly EditorCommand AddColumnLeft = new("AddColumnLeft", e => e.RunTableCommand(TableCommand.AddColumn(before: true)));
    public static readonly EditorCommand AddColumnRight = new("AddColumnRight", e => e.RunTableCommand(TableCommand.AddColumn(before: false)));
    public static readonly EditorCommand DeleteRow = new("DeleteRow", e => e.RunTableCommand(TableCommand.DeleteRow));
    public static readonly EditorCommand DeleteColumn = new("DeleteColumn", e => e.RunTableCommand(TableCommand.DeleteColumn));
    public static readonly EditorCommand AlignLeft = new("AlignColumnLeft", e => e.RunTableCommand(TableCommand.Align(TableAlignment.Left)));
    public static readonly EditorCommand AlignCenter = new("AlignColumnCenter", e => e.RunTableCommand(TableCommand.Align(TableAlignment.Center)));
    public static readonly EditorCommand AlignRight = new("AlignColumnRight", e => e.RunTableCommand(TableCommand.Align(TableAlignment.Right)));

    public static readonly EditorCommand[] Headings = [Heading1, Heading2, Heading3, Body];

    public static readonly EditorCommand[] TableCommands =
        [ConvertToTable, AddRowAbove, AddRowBelow, AddColumnLeft, AddColumnRight, DeleteRow, DeleteColumn, AlignLeft, AlignCenter, AlignRight];

    /// <summary>Every command with a shortcut or not, for registering accelerators and menus in one pass.</summary>
    public static readonly EditorCommand[] All =
    [
        Bold, Italic, Strikethrough, InlineCode, Link, Heading1, Heading2, Heading3, Body, BulletedList, NumberedList, Checklist, Quote,
        CodeBlock, HorizontalRule, InsertTable, .. TableCommands,
    ];

    /// <summary>"Ctrl+Shift+K" for the keys; a few keys have a symbol instead of their enum name.</summary>
    public static string Display(VirtualKey key, VirtualKeyModifiers modifiers)
    {
        var parts = new List<string>();
        if (modifiers.HasFlag(VirtualKeyModifiers.Control)) parts.Add("Ctrl");
        if (modifiers.HasFlag(VirtualKeyModifiers.Shift)) parts.Add("Shift");
        if (modifiers.HasFlag(VirtualKeyModifiers.Menu)) parts.Add("Alt");
        parts.Add(key switch
        {
            >= VirtualKey.Number0 and <= VirtualKey.Number9 => ((int)key - (int)VirtualKey.Number0).ToString(),
            QuoteKey => "'",
            (VirtualKey)0xDB => "[",
            (VirtualKey)0xDD => "]",
            (VirtualKey)0xBB => "=",
            (VirtualKey)0xBD => "-",
            _ => key.ToString(),
        });
        return string.Join('+', parts);
    }

    /// <summary>A menu item for `command` that runs on the editor `current` returns (and gives it the keyboard back).</summary>
    public static MenuFlyoutItem Item(EditorCommand command, Func<MarkdownEditor?> current)
    {
        var item = new MenuFlyoutItem { Text = Loc.Get(command.TextKey) };
        if (command.HasShortcut) item.KeyboardAcceleratorTextOverride = command.ShortcutText;
        item.Click += (_, _) =>
        {
            if (current() is { } editor) command.Run(editor);
        };
        return item;
    }

    /// <summary>The Format items (inline styles, link, headings, lists, quote, blocks, table) in the right-click menu's order.
    /// Returns the items, so the caller can enable and disable them.</summary>
    public static List<MenuFlyoutItemBase> Populate(IList<MenuFlyoutItemBase> into, Func<MarkdownEditor?> current)
    {
        var all = new List<MenuFlyoutItemBase>();
        void Add(MenuFlyoutItemBase item)
        {
            into.Add(item);
            all.Add(item);
        }
        foreach (var command in new[] { Bold, Italic, Strikethrough, InlineCode, Link }) Add(Item(command, current));
        Add(new MenuFlyoutSeparator());
        var heading = new MenuFlyoutSubItem { Text = Loc.Get("Heading") };
        foreach (var command in Headings) heading.Items.Add(Item(command, current));
        Add(heading);
        foreach (var command in new[] { BulletedList, NumberedList, Checklist, Quote }) Add(Item(command, current));
        Add(new MenuFlyoutSeparator());
        Add(Item(CodeBlock, current));
        Add(Item(HorizontalRule, current));
        Add(new MenuFlyoutSeparator());
        Add(TableSubItem(current));
        return all;
    }

    /// <summary>The Table submenu: insert, convert and the commands on the table around the caret.</summary>
    public static MenuFlyoutSubItem TableSubItem(Func<MarkdownEditor?> current)
    {
        var table = new MenuFlyoutSubItem { Text = Loc.Get("Table") };
        table.Items.Add(Item(InsertTable, current));
        table.Items.Add(Item(ConvertToTable, current));
        table.Items.Add(new MenuFlyoutSeparator());
        foreach (var command in new[] { AddRowAbove, AddRowBelow, AddColumnLeft, AddColumnRight, DeleteRow, DeleteColumn })
        {
            table.Items.Add(Item(command, current));
        }
        table.Items.Add(new MenuFlyoutSeparator());
        foreach (var command in new[] { AlignLeft, AlignCenter, AlignRight }) table.Items.Add(Item(command, current));
        return table;
    }
}
