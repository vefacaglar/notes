using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Notes;

/// <summary>Content dialogs; one at a time per window (WinUI allows only one open dialog per XamlRoot).</summary>
internal static class Dialogs
{
    private static readonly Dictionary<XamlRoot, SemaphoreSlim> Gates = [];

    public static async Task<ContentDialogResult> ShowAsync(XamlRoot root, ContentDialog dialog)
    {
        if (!Gates.TryGetValue(root, out var gate)) Gates[root] = gate = new SemaphoreSlim(1, 1);
        await gate.WaitAsync();
        try
        {
            dialog.XamlRoot = root;
            dialog.Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"];
            return await dialog.ShowAsync();
        }
        finally
        {
            gate.Release();
        }
    }

    public static Task MessageAsync(XamlRoot root, string title, string message) =>
        ShowAsync(root, new ContentDialog { Title = title, Content = Wrapped(message), CloseButtonText = Loc.Get("OK"), DefaultButton = ContentDialogButton.Close });

    /// <summary>Asks for a name; null when cancelled.</summary>
    public static async Task<string?> AskNameAsync(XamlRoot root, string title, string action, string initial)
    {
        var box = new TextBox { Text = initial, PlaceholderText = Loc.Get("Name"), MinWidth = 280 };
        box.Loaded += (_, _) =>
        {
            box.Focus(FocusState.Programmatic);
            box.SelectAll();
        };
        var dialog = new ContentDialog
        {
            Title = title,
            Content = box,
            PrimaryButtonText = action,
            CloseButtonText = Loc.Get("CancelDialog"),
            DefaultButton = ContentDialogButton.Primary,
        };
        return await ShowAsync(root, dialog) == ContentDialogResult.Primary ? box.Text : null;
    }

    /// <summary>A yes/cancel question whose confirming button is destructive, so Enter cancels.</summary>
    public static async Task<bool> ConfirmAsync(XamlRoot root, string title, string message, string action, string? cancel = null)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = message.Length == 0 ? null : Wrapped(message),
            PrimaryButtonText = action,
            CloseButtonText = cancel ?? Loc.Get("CancelDialog"),
            DefaultButton = ContentDialogButton.Close,
        };
        return await ShowAsync(root, dialog) == ContentDialogResult.Primary;
    }

    private static TextBlock Wrapped(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
}
