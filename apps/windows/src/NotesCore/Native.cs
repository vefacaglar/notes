using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace NotesCore;

/// <summary>Identifies one file on one volume: volume serial number plus file index.</summary>
public readonly record struct FileIdentity(uint VolumeSerial, ulong FileIndex);

/// <summary>Win32 calls the spec names: StrCmpLogicalW, file identity, final path of a link, Recycle Bin.</summary>
internal static class Native
{
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int StrCmpLogicalW(string x, string y);

    [StructLayout(LayoutKind.Sequential)]
    private struct FileTime
    {
        public uint Low;
        public uint High;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public FileTime CreationTime;
        public FileTime LastAccessTime;
        public FileTime LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string fileName, uint access, uint share, IntPtr security,
        uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle file, out ByHandleFileInformation info);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, [Out] char[] buffer, uint length, uint flags);

    private const uint ShareAll = 0x7; // read | write | delete
    private const uint OpenExisting = 3;
    private const uint BackupSemantics = 0x02000000; // needed to open directories
    private const uint OpenReparsePoint = 0x00200000; // do not follow a link

    /// <summary>What <see cref="Query"/> learns from one handle.</summary>
    internal readonly record struct Info(FileIdentity Identity, long Size, DateTime LastWriteUtc, bool IsDirectory, string FinalPath);

    /// <summary>
    /// Opens `path` without access rights (no placeholder hydration, no sharing conflicts) and reads its identity, size,
    /// modification time and final path. Links are followed unless `followLinks` is false. `null` when it can't be opened.
    /// </summary>
    internal static Info? Query(string path, bool followLinks = true)
    {
        using var handle = CreateFileW(Extended(path), 0, ShareAll, IntPtr.Zero, OpenExisting,
            BackupSemantics | (followLinks ? 0 : OpenReparsePoint), IntPtr.Zero);
        if (handle.IsInvalid || !GetFileInformationByHandle(handle, out var info)) return null;
        var written = ((long)info.LastWriteTime.High << 32) | info.LastWriteTime.Low;
        var time = written > 0 ? DateTime.FromFileTimeUtc(written) : DateTime.MinValue;
        return new Info(
            new FileIdentity(info.VolumeSerialNumber, ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow),
            ((long)info.FileSizeHigh << 32) | info.FileSizeLow,
            time,
            (info.FileAttributes & (uint)FileAttributes.Directory) != 0,
            FinalPath(handle) ?? UnresolvedPath(path, followLinks));
    }

    /// <summary>Fallback when the final path is unknown: fine for plain files, an error for a link (writing would replace the link itself).</summary>
    private static string UnresolvedPath(string path, bool followLinks)
    {
        if (!followLinks) return path;
        return IsLink(path) ? throw new IOException($"Bağlantının hedefi çözülemedi: {path}") : path;
    }

    /// <summary>Whether `path` itself is a symbolic link or junction (not a cloud-file or dedup reparse point).</summary>
    internal static bool IsLink(string path)
    {
        try { return new FileInfo(path).LinkTarget is not null; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    private static string? FinalPath(SafeFileHandle handle)
    {
        var buffer = new char[512];
        var length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Length, 0);
        if (length > buffer.Length)
        {
            buffer = new char[length];
            length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Length, 0);
        }
        if (length == 0 || length > buffer.Length) return null;
        var path = new string(buffer, 0, (int)length);
        if (path.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) return @"\\" + path[8..];
        return path.StartsWith(@"\\?\", StringComparison.Ordinal) ? path[4..] : path;
    }

    /// <summary>Long drive-letter paths need the extended prefix for the raw Win32 calls.</summary>
    private static string Extended(string path)
    {
        var full = Path.GetFullPath(path);
        return full.Length >= 240 && full.Length > 2 && full[1] == ':' ? @"\\?\" + full : full;
    }

    /// <summary>Whether both paths name the same existing item (links are not followed).</summary>
    internal static bool IsSameItem(string a, string b)
    {
        var x = Query(a, followLinks: false);
        var y = Query(b, followLinks: false);
        return x is not null && y is not null && x.Value.Identity == y.Value.Identity;
    }

    /// <summary>Natural order as Explorer sorts: case-insensitive, digit runs by value.</summary>
    internal static int CompareLogical(string a, string b)
    {
        var result = StrCmpLogicalW(a, b);
        return result != 0 ? result : string.CompareOrdinal(a, b);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ShFileOpStruct
    {
        public IntPtr Window;
        public uint Function;
        public string From;
        public string? To;
        public ushort Flags;
        public bool AnyOperationsAborted;
        public IntPtr NameMappings;
        public string? ProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SHFileOperationW(ref ShFileOpStruct operation);

    /// <summary>
    /// Moves a file or folder to the Recycle Bin. If the volume can't recycle it, the shell asks before deleting
    /// permanently (FOF_WANTNUKEWARNING); declining, or any failure, throws. Never deletes silently.
    /// </summary>
    internal static void Recycle(string path)
    {
        const uint delete = 3; // FO_DELETE
        const ushort allowUndo = 0x40, noErrorUi = 0x400, wantNukeWarning = 0x4000;
        var operation = new ShFileOpStruct
        {
            Function = delete,
            From = Path.GetFullPath(path) + "\0", // the marshaller adds the second terminator
            Flags = allowUndo | noErrorUi | wantNukeWarning,
        };
        var code = SHFileOperationW(ref operation);
        if (code != 0) throw new IOException($"Geri dönüşüm kutusuna taşınamadı (kod 0x{code:X}): {path}");
        if (operation.AnyOperationsAborted) throw new OperationCanceledException($"Geri dönüşüm kutusuna taşıma iptal edildi: {path}");
    }
}
