using System.Text;

namespace NotesCore;

public sealed class NoteFileTooLargeException(long bytes) : Exception
{
    public long Bytes { get; } = bytes;

    public override string Message =>
        Strings.Format("FileTooLarge", Bytes / 1_048_576, NoteFile.MaxOpenSize / 1_048_576);
}

/// <summary>The file or its folder refuses writes (read-only attribute, deny ACL, locked item). <see cref="Path"/> is the resolved file.</summary>
public sealed class NoteFileNotWritableException(string path, Exception? inner = null) : IOException(null, inner)
{
    public string Path { get; } = path;

    public override string Message => Strings.Format("NotWritable", System.IO.Path.GetFileName(Path));
}

/// <summary>`Path` is a symbolic link or junction whose target does not exist; nothing is written.</summary>
public sealed class NoteFileBrokenLinkException(string path) : IOException
{
    public string Path { get; } = path;

    public override string Message => Strings.Format("BrokenLink", System.IO.Path.GetFileName(Path));
}

/// <summary>
/// Reading and writing one text file as both apps do (docs/format.md, "File contents" and "External changes").
/// Paths are followed through links, so a linked note stays a link and its target is what changes.
/// </summary>
public static class NoteFile
{
    /// <summary>Files above this size open read-only.</summary>
    public const long ReadOnlySize = 20 * 1_048_576;
    /// <summary>Files above this size are not opened.</summary>
    public const long MaxOpenSize = 200 * 1_048_576;
    /// <summary>Files up to this size are always compared by content when their stamp is unchanged (see <see cref="NeedsContentCheck"/>).</summary>
    public const long VerifySize = 1_048_576;

    /// <summary>Identifies one version of a file: anything another program writes changes at least one of these.</summary>
    /// <param name="Identity">Volume serial and file index; an atomic save by another program replaces it.</param>
    public readonly record struct Stamp(DateTime? ModificationTime, long? Size, FileIdentity? Identity)
    {
        /// <summary>
        /// Whether the modification time is a whole second: volumes with coarse timestamps (FAT, some shares) can hide an
        /// edit made right after ours; NTFS's 100 ns timestamp is a whole second only by a one-in-ten-million chance.
        /// </summary>
        public bool HasCoarseTimestamp => ModificationTime is not { } time || time.Ticks % TimeSpan.TicksPerSecond == 0;
    }

    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    /// <summary>The stamp of the file `path` points to (through links), or `null` when there is none (also for a broken link).</summary>
    public static Stamp? GetStamp(string path)
    {
        Native.Info? info;
        try { info = Native.Query(path); }
        catch (IOException) { return null; } // unresolvable link
        return info is { IsDirectory: false } file ? new Stamp(file.LastWriteUtc, file.Size, file.Identity) : null;
    }

    /// <summary>
    /// Whether a save must compare the disk text with the last saved text although the stamp is unchanged, because a
    /// coarse-timestamp volume can hide an edit. Small files are always compared; a big file only when its timestamp is
    /// coarse and recent, so saving a large file on NTFS never reads it back.
    /// </summary>
    public static bool NeedsContentCheck(Stamp stamp, DateTime nowUtc)
    {
        if (stamp.Size is { } size && size <= VerifySize) return true;
        if (!stamp.HasCoarseTimestamp) return false;
        return stamp.ModificationTime is not { } modified || Math.Abs((nowUtc - modified).TotalSeconds) < 2;
    }

    /// <summary>
    /// Whether a save of the file `path` points to can succeed: the file (if it exists) and its folder accept writes,
    /// and it is not a link to nothing. The editor opens files for which this is false read-only. The folder is probed
    /// by creating and deleting a temporary file in it.
    /// </summary>
    public static bool IsWritable(string path)
    {
        var info = Native.Query(path);
        string target;
        if (info is null)
        {
            if (Native.IsLink(path)) return false;
            target = Path.GetFullPath(path);
        }
        else if (info.Value.IsDirectory)
        {
            return false;
        }
        else
        {
            target = info.Value.FinalPath;
            var attributes = File.GetAttributes(target);
            if (attributes.HasFlag(FileAttributes.ReadOnly)) return false;
            // Opening a cloud placeholder for writing would download it.
            if (((int)attributes & (int)(FileAttributes.Offline | (FileAttributes)0x40000 | (FileAttributes)0x400000)) == 0)
            {
                try { using var _ = new FileStream(target, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete); }
                catch (UnauthorizedAccessException) { return false; }
                catch (IOException) { } // in use by another program: not a permission problem
            }
        }
        return CanCreateIn(Path.GetDirectoryName(target)!);
    }

    private static bool CanCreateIn(string folder)
    {
        try
        {
            var probe = Path.Combine(folder, $".notes-{Guid.NewGuid():N}.tmp");
            using var _ = new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1, FileOptions.DeleteOnClose);
            return true;
        }
        catch (UnauthorizedAccessException) { return false; }
        catch (DirectoryNotFoundException) { return false; }
        catch (IOException) { return true; }
    }

    /// <summary>
    /// The form of a text on disk: a leading BOM dropped and CRLF turned into LF (a lone CR stays). Both <see cref="Read"/>
    /// and <see cref="Write(string, string)"/> apply it, so what is written reads back unchanged and an editor's text can
    /// be compared with the disk.
    /// </summary>
    public static string Normalized(string text)
    {
        if (!NeedsNormalizing(text)) return text;
        if (text.StartsWith('﻿')) text = text[1..];
        return text.Replace("\r\n", "\n", StringComparison.Ordinal);
    }

    /// <summary>Whether <see cref="Normalized"/> would change `text`; cheap (a vectorized search), so it can run on every keystroke.</summary>
    public static bool NeedsNormalizing(string text) =>
        text.StartsWith('﻿') || text.Contains("\r\n", StringComparison.Ordinal);

    /// <summary>UTF-8 text with a leading BOM dropped and CRLF turned into LF.</summary>
    public static string Read(string path) => Normalized(StrictUtf8.GetString(ReadData(path)));

    /// <summary>
    /// The file's bytes (through links), read without blocking other programs: they may keep it open for writing, or
    /// rename or delete it (an editor saving it atomically) while it is read. Files over <see cref="MaxOpenSize"/> throw
    /// <see cref="NoteFileTooLargeException"/>; for encrypted notes.
    /// </summary>
    public static byte[] ReadData(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (stream.CanSeek && stream.Length > MaxOpenSize) throw new NoteFileTooLargeException(stream.Length);
        var buffer = new MemoryStream(stream.CanSeek ? (int)stream.Length : 0);
        // Bounded, so a file that grows while it is read is rejected without buffering all of it.
        var chunk = new byte[81920];
        long total = 0;
        int count;
        while ((count = stream.Read(chunk, 0, chunk.Length)) > 0)
        {
            total += count;
            if (total > MaxOpenSize) throw new NoteFileTooLargeException(total);
            buffer.Write(chunk, 0, count);
        }
        return buffer.ToArray();
    }

    internal static byte[] ReadBytes(string path) => ReadData(path);

    /// <summary>
    /// Writes `text` (in <see cref="Normalized"/> form) as UTF-8 without a BOM, atomically: a temporary file in the same
    /// folder, then `ReplaceFile`, which keeps the original's attributes, creation time, ACL and streams. A link is
    /// followed, so the link itself stays; a link to a missing file throws <see cref="NoteFileBrokenLinkException"/>.
    /// Permission failures throw <see cref="NoteFileNotWritableException"/>.
    /// </summary>
    public static void Write(string text, string path) => Write(text, path, DefaultReplace);

    /// <summary>Writes `data` as it is, through the same atomic path as the text <see cref="Write(string, string)"/>.</summary>
    public static void Write(byte[] data, string path) => Write(data, path, DefaultReplace);

    internal static void Write(string text, string path, Action<string, string, string> replace) =>
        Write(StrictUtf8.GetBytes(Normalized(text)), path, replace); // lone surrogates throw instead of becoming U+FFFD

    private static void DefaultReplace(string temp, string target, string backup) =>
        File.Replace(temp, target, backup, ignoreMetadataErrors: true);

    /// <summary>
    /// `replace` swaps `temp` into `target`, leaving the old file at `backup`. When it fails the way some network
    /// shares do (ReplaceFile unsupported), the temporary file is moved over the original instead.
    /// </summary>
    internal static void Write(byte[] bytes, string path, Action<string, string, string> replace)
    {
        var query = Native.Query(path);
        if (query is null && Native.IsLink(path)) throw new NoteFileBrokenLinkException(path);
        var target = query is { IsDirectory: false } existing ? existing.FinalPath : Path.GetFullPath(path);
        var folder = Path.GetDirectoryName(target)!;
        if (query is not null && File.GetAttributes(target).HasFlag(FileAttributes.ReadOnly))
            throw new NoteFileNotWritableException(target);
        var id = Guid.NewGuid().ToString("N");
        var temp = Path.Combine(folder, $".notes-{id}.tmp");
        var backup = Path.Combine(folder, $".notes-{id}.bak");
        var replacing = false;
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            if (File.Exists(target))
            {
                replacing = true;
                try
                {
                    replace(temp, target, backup);
                }
                catch (IOException e) when (IsReplaceUnsupported(e))
                {
                    // ReplaceFile may have moved the original aside before failing.
                    if (!File.Exists(target) && File.Exists(backup)) File.Move(backup, target);
                    KeepAttributes(target, temp);
                    File.Move(temp, target, overwrite: true);
                }
            }
            else File.Move(temp, target);
        }
        catch (UnauthorizedAccessException e)
        {
            Recover(target, temp, backup, replacing);
            throw new NoteFileNotWritableException(target, e);
        }
        catch
        {
            Recover(target, temp, backup, replacing);
            throw;
        }
        TryDelete(backup);
    }

    /// <summary>The Win32 errors a share without ReplaceFile support (or a half-done replace) answers with.</summary>
    private static bool IsReplaceUnsupported(IOException e) =>
        (e.HResult & unchecked((int)0xFFFF0000)) == unchecked((int)0x80070000) && (e.HResult & 0xFFFF) is 1 or 50 or 120 or 1175 or 1176 or 1177;

    private static void KeepAttributes(string original, string temp)
    {
        try
        {
            const FileAttributes kept = FileAttributes.Hidden | FileAttributes.System | FileAttributes.NotContentIndexed | FileAttributes.Archive;
            File.SetAttributes(temp, (File.GetAttributes(temp) & ~kept) | (File.GetAttributes(original) & kept));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>
    /// After a failed save: when ReplaceFile moved the original aside and the target is gone, put the backup back.
    /// The temp file is never a restore source (it may be truncated); it is only removed.
    /// </summary>
    private static void Recover(string target, string temp, string backup, bool replacing)
    {
        TryDelete(temp);
        if (!replacing) return;
        if (!File.Exists(target) && File.Exists(backup))
        {
            try { File.Move(backup, target); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                throw new IOException(Strings.Format("SaveRecovery", backup, target), e);
            }
        }
        if (File.Exists(target)) TryDelete(backup);
    }

    private static void TryDelete(string path)
    {
        try { File.Delete(path); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    /// <summary>Size in bytes of the file `path` points to.</summary>
    public static long? GetSize(string path) => GetStamp(path)?.Size;
}
