using System.Text;

namespace NotesCore;

public sealed class NoteFileTooLargeException(long bytes) : Exception
{
    public long Bytes { get; } = bytes;

    public override string Message =>
        $"Dosya çok büyük ({Bytes / 1_048_576} MB); en fazla {NoteFile.MaxOpenSize / 1_048_576} MB açılabilir.";
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

    /// <summary>Identifies one version of a file: anything another program writes changes at least one of these.</summary>
    /// <param name="Identity">Volume serial and file index; an atomic save by another program replaces it.</param>
    public readonly record struct Stamp(DateTime? ModificationTime, long? Size, FileIdentity? Identity);

    private static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);

    /// <summary>The stamp of the file `path` points to (through links), or `null` when there is none.</summary>
    public static Stamp? GetStamp(string path)
    {
        Native.Info? info;
        try { info = Native.Query(path); }
        catch (IOException) { return null; } // unresolvable link
        return info is { IsDirectory: false } file ? new Stamp(file.LastWriteUtc, file.Size, file.Identity) : null;
    }

    /// <summary>UTF-8 text with a leading BOM dropped and CRLF turned into LF.</summary>
    public static string Read(string path)
    {
        var text = StrictUtf8.GetString(File.ReadAllBytes(path));
        if (text.StartsWith('\uFEFF')) text = text[1..];
        return text.Replace("\r\n", "\n", StringComparison.Ordinal);
    }

    /// <summary>
    /// Writes `text` as UTF-8 without a BOM, atomically: a temporary file in the same folder, then `ReplaceFile`, which
    /// keeps the original's attributes, creation time, ACL and streams. A link is followed, so the link itself stays.
    /// </summary>
    public static void Write(string text, string path)
    {
        var bytes = StrictUtf8.GetBytes(text); // lone surrogates throw instead of becoming U+FFFD
        var query = Native.Query(path);
        if (query is null && Native.IsLink(path)) throw new IOException($"Bağlantının hedefi bulunamadı: {path}");
        var target = query is { IsDirectory: false } existing ? existing.FinalPath : Path.GetFullPath(path);
        var folder = Path.GetDirectoryName(target)!;
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
                File.Replace(temp, target, backup, ignoreMetadataErrors: true);
            }
            else File.Move(temp, target);
        }
        catch
        {
            Recover(target, temp, backup, replacing);
            throw;
        }
        TryDelete(backup);
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
                throw new IOException($"Kayıt başarısız oldu; özgün dosya \"{backup}\" konumunda duruyor ve \"{target}\" yerine elle taşınmalı.", e);
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
