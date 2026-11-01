using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using NotesCore;

namespace Notes.Editor;

/// <summary>The flyouts of the editor: the table size picker and the outline of the headings.</summary>
internal static class EditorPopups
{
    private const int PickerSize = 8;

    private static Brush Resource(string key) => (Brush)Application.Current.Resources[key];

    /// <summary>A grid of squares to choose a table size (rows include the header), plus conversion of the selected lines.</summary>
    public static FrameworkElement TablePicker(MarkdownEditor editor, Action close)
    {
        var cells = new Border[PickerSize, PickerSize];
        var grid = new Grid { RowSpacing = 3, ColumnSpacing = 3 };
        for (var i = 0; i < PickerSize; i++)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        }
        var label = new TextBlock
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            FontSize = 12,
            Foreground = Resource("TextFillColorSecondaryBrush"),
        };
        void Hover(int rows, int columns)
        {
            for (var r = 0; r < PickerSize; r++)
            {
                for (var c = 0; c < PickerSize; c++) cells[r, c].Opacity = r < rows && c < columns ? 0.3 : 0.08;
            }
            label.Text = $"{rows} × {columns}";
        }
        for (var r = 0; r < PickerSize; r++)
        {
            for (var c = 0; c < PickerSize; c++)
            {
                var (row, column) = (r + 1, c + 1);
                var cell = new Border
                {
                    Width = 18,
                    Height = 18,
                    CornerRadius = new CornerRadius(2),
                    Background = Resource("TextFillColorPrimaryBrush"),
                };
                cell.PointerEntered += (_, _) => Hover(row, column);
                cell.Tapped += (_, _) =>
                {
                    close();
                    editor.InsertTable(row, column);
                };
                cells[r, c] = cell;
                Grid.SetRow(cell, r);
                Grid.SetColumn(cell, c);
                grid.Children.Add(cell);
            }
        }
        Hover(3, 3);
        var convert = new HyperlinkButton
        {
            Content = Loc.Get("ConvertToTable"),
            Padding = new Thickness(4),
            HorizontalAlignment = HorizontalAlignment.Center,
            FontSize = 12,
        };
        convert.Click += (_, _) =>
        {
            close();
            editor.ConvertToTable();
        };
        return new StackPanel
        {
            Spacing = 8,
            Children =
            {
                grid,
                label,
                new Border { Height = 1, Background = Resource("DividerStrokeColorDefaultBrush") },
                convert,
            },
        };
    }

    /// <summary>The headings as an indented list; choosing one calls `select`.</summary>
    public static FrameworkElement Outline(IReadOnlyList<OutlineHeading> headings, Action<OutlineHeading> select)
    {
        if (headings.Count == 0)
        {
            return new TextBlock
            {
                Text = Loc.Get("NoHeadings"),
                Margin = new Thickness(16),
                Foreground = Resource("TextFillColorSecondaryBrush"),
            };
        }
        var top = headings.Min(h => h.Level);
        var list = new ListView { SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = true, Width = 280, MaxHeight = 420 };
        foreach (var heading in headings)
        {
            list.Items.Add(new TextBlock
            {
                Text = heading.Title,
                Tag = heading,
                TextTrimming = TextTrimming.CharacterEllipsis,
                MaxLines = 1,
                Margin = new Thickness((heading.Level - top) * 14, 0, 0, 0),
                FontWeight = heading.Level == top ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
                Foreground = Resource(heading.Level <= top + 1 ? "TextFillColorPrimaryBrush" : "TextFillColorSecondaryBrush"),
            });
        }
        list.ItemClick += (_, e) =>
        {
            if (e.ClickedItem is TextBlock { Tag: OutlineHeading heading }) select(heading);
        };
        return list;
    }
}
