using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using NotesCore;

namespace Notes;

/// <summary>Full-path helpers and user-facing error text.</summary>
internal static partial class Paths
{
    [LibraryImport("kernel32.dll", EntryPoint = "CreateFileW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    private static partial SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle file, [Out] char[] buffer, uint length, uint flags);

    /// <summary>The path as the file system spells it, links resolved. Does I/O: call it off the UI thread.</summary>
    public static string Canonical(string path)
    {
        var full = Path.GetFullPath(path);
        using var handle = CreateFile(full, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle.IsInvalid) return full;
        var buffer = new char[1024];
        var length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Length, 0);
        if (length > buffer.Length)
        {
            buffer = new char[length];
            length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Length, 0);
        }
        if (length == 0 || length > buffer.Length) return full;
        var result = new string(buffer, 0, (int)length);
        if (result.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) return @"\\" + result[8..];
        return result.StartsWith(@"\\?\", StringComparison.Ordinal) ? result[4..] : result;
    }

    /// <summary>Windows paths compare case-insensitively (invariant, so Turkish i/I are safe).</summary>
    public static bool Same(string a, string b) =>
        string.Equals(Path.TrimEndingDirectorySeparator(a), Path.TrimEndingDirectorySeparator(b), StringComparison.OrdinalIgnoreCase);

    /// <summary>Whether `path` is `folder` or inside it (string comparison of full paths).</summary>
    public static bool IsInside(string path, string folder)
    {
        path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
        folder = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));
        return string.Equals(path, folder, StringComparison.OrdinalIgnoreCase)
            || path.StartsWith(folder + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>`full` relative to `root` with "/" separators, or null when it is not below it.</summary>
    public static string? Relative(string full, string root)
    {
        var prefix = Path.EndsInDirectorySeparator(root) ? root : root + Path.DirectorySeparatorChar;
        return full.Length > prefix.Length && full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            ? full[prefix.Length..].Replace(Path.DirectorySeparatorChar, '/')
            : null;
    }

    /// <summary>A description of a file error.</summary>
    public static string Describe(Exception e) => e switch
    {
        NoteStoreException or NoteFileTooLargeException or OperationCanceledException => e.Message,
        DecoderFallbackException => Loc.Get("DecodeFailed"),
        FileNotFoundException or DirectoryNotFoundException => Loc.Get("ItemNotFound"),
        UnauthorizedAccessException => Loc.Get("AccessDenied"),
        PathTooLongException => Loc.Get("PathTooLong"),
        _ => e.Message,
    };
}
