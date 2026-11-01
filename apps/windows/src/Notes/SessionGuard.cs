using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace Notes;

/// <summary>
/// Logoff and shutdown: Windows asks every window (WM_QUERYENDSESSION) and then ends the process without closing
/// windows, so the usual close path never runs. Everything is saved synchronously here (nothing may wait for the
/// dispatcher); if a save fails, the shutdown is blocked with a reason and the edits stay in the window.
/// </summary>
internal static partial class SessionGuard
{
    private const uint QueryEndSession = 0x0011, EndSession = 0x0016;

    private delegate IntPtr SubclassProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr data);

    [LibraryImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowSubclass(IntPtr window, IntPtr proc, UIntPtr id, UIntPtr data);

    [LibraryImport("comctl32.dll")]
    private static partial IntPtr DefSubclassProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShutdownBlockReasonCreate(IntPtr window, string reason);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShutdownBlockReasonDestroy(IntPtr window);

    /// <summary>Called before a logoff or shutdown is allowed: writes the session synchronously.</summary>
    public static Action? BeforeEnd { get; set; }

    // Kept alive for the life of the process: the window calls it.
    private static readonly SubclassProc Proc = WindowProc;

    public static void Install(Window window)
    {
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(window);
        SetWindowSubclass(handle, Marshal.GetFunctionPointerForDelegate(Proc), 1, 0);
    }

    private static IntPtr WindowProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr data)
    {
        switch (message)
        {
            case QueryEndSession:
                if (NoteDocument.SaveAllNow())
                {
                    BeforeEnd?.Invoke();
                    ShutdownBlockReasonDestroy(window);
                    return 1;
                }
                ShutdownBlockReasonCreate(window, Loc.Get("ShutdownBlock"));
                return 0;
            case EndSession:
                if (wParam != IntPtr.Zero) Drafts.FinishRun();
                ShutdownBlockReasonDestroy(window);
                return 0;
            default:
                return DefSubclassProc(window, message, wParam, lParam);
        }
    }
}
