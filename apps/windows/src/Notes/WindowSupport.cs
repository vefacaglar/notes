using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace Notes;

internal static partial class WindowSupport
{
    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(IntPtr window);

    /// <summary>Sizes the window in device-independent pixels.</summary>
    public static void Resize(Window window, double width, double height)
    {
        var dpi = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(window));
        var scale = dpi == 0 ? 1 : dpi / 96.0;
        window.AppWindow.Resize(new SizeInt32((int)(width * scale), (int)(height * scale)));
    }

    /// <summary>
    /// Puts the window where the last session left it, moved onto the nearest monitor's work area when that monitor is
    /// gone or smaller now; a window with nothing saved opens at `defaultWidth` x `defaultHeight` (device-independent pixels).
    /// </summary>
    public static void Place(Window window, SessionBounds? saved, double defaultWidth, double defaultHeight)
    {
        if (saved is not { Width: >= 320, Height: >= 240 })
        {
            Resize(window, defaultWidth, defaultHeight);
            return;
        }
        var work = DisplayArea.GetFromRect(new RectInt32(saved.X, saved.Y, saved.Width, saved.Height), DisplayAreaFallback.Nearest).WorkArea;
        var width = Math.Min(saved.Width, work.Width);
        var height = Math.Min(saved.Height, work.Height);
        var x = Math.Clamp(saved.X, work.X, work.X + work.Width - width);
        var y = Math.Clamp(saved.Y, work.Y, work.Y + work.Height - height);
        window.AppWindow.MoveAndResize(new RectInt32(x, y, width, height));
        if (!saved.Maximized || window.AppWindow.Presenter is not OverlappedPresenter presenter) return;
        presenter.Maximize();
        // Some systems apply this only once the window is shown.
        window.Activated += Again;

        void Again(object sender, WindowActivatedEventArgs e)
        {
            window.Activated -= Again;
            if (presenter.State != OverlappedPresenterState.Maximized) presenter.Maximize();
        }
    }

    /// <summary>
    /// Draws the window's content under the title bar, Windows 11 style: Mica shows through, `titleBar` is the drag
    /// region (interactive parts need passthrough rectangles), and the caption buttons are transparent with a foreground
    /// that follows the theme.
    /// </summary>
    public static void ExtendIntoTitleBar(Window window, FrameworkElement titleBar)
    {
        window.ExtendsContentIntoTitleBar = true;
        window.SetTitleBar(titleBar);
        var bar = window.AppWindow.TitleBar;
        bar.PreferredHeightOption = TitleBarHeightOption.Tall;
        bar.ButtonBackgroundColor = Colors.Transparent;
        bar.ButtonInactiveBackgroundColor = Colors.Transparent;

        void ApplyTheme()
        {
            var dark = titleBar.ActualTheme == ElementTheme.Dark;
            var foreground = dark ? Colors.White : Colors.Black;
            bar.ButtonForegroundColor = foreground;
            bar.ButtonHoverForegroundColor = foreground;
            bar.ButtonPressedForegroundColor = foreground;
            bar.ButtonInactiveForegroundColor = dark ? ColorHelper.FromArgb(0xFF, 0x78, 0x78, 0x78) : ColorHelper.FromArgb(0xFF, 0x8B, 0x8B, 0x8B);
            bar.ButtonHoverBackgroundColor = dark ? ColorHelper.FromArgb(0x0F, 0xFF, 0xFF, 0xFF) : ColorHelper.FromArgb(0x09, 0x00, 0x00, 0x00);
            bar.ButtonPressedBackgroundColor = dark ? ColorHelper.FromArgb(0x0A, 0xFF, 0xFF, 0xFF) : ColorHelper.FromArgb(0x06, 0x00, 0x00, 0x00);
        }
        titleBar.ActualThemeChanged += (_, _) => ApplyTheme();
        titleBar.Loaded += (_, _) => ApplyTheme();
        ApplyTheme();
    }

    /// <summary>
    /// Runs `prepare` (save everything, asking the user where saving fails) before the window closes; the close is
    /// cancelled when it returns false.
    /// </summary>
    public static void GuardClose(Window window, Func<Task<bool>> prepare)
    {
        var allowed = false;
        var busy = false;
        window.AppWindow.Closing += async (_, e) =>
        {
            if (allowed) return;
            e.Cancel = true;
            if (busy) return;
            busy = true;
            try
            {
                if (!await prepare()) return;
                allowed = true;
                window.Close();
            }
            finally
            {
                busy = false;
            }
        };
    }
}
