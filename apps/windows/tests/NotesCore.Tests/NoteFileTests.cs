using System.Text;
using NotesCore;

namespace NotesCore.Tests;

public sealed class NoteFileTests : IDisposable
{
    private readonly NotesTempFolder temp = new();
    private string Folder => temp.Path;

    public void Dispose() => temp.Dispose();

    [Fact]
    public void ReadDropsBOMAndCRLF()
    {
        var file = Path.Combine(Folder, "a.md");
        File.WriteAllBytes(file, new UTF8Encoding(false).GetBytes("\uFEFFbir\r\niki\r\n"));
        Assert.Equal("bir\niki\n", NoteFile.Read(file));
    }

    [Fact]
    public void ReadRejectsInvalidUtf8()
    {
        var file = Path.Combine(Folder, "latin.md");
        File.WriteAllBytes(file, [0x61, 0xFF, 0x62]);
        Assert.ThrowsAny<DecoderFallbackException>(() => NoteFile.Read(file));
    }

    [Fact]
    public void WriteCreatesAMissingFile()
    {
        var file = Path.Combine(Folder, "yeni.md");
        NoteFile.Write("çğ 😀\n", file);
        Assert.Equal(new UTF8Encoding(false).GetBytes("çğ 😀\n"), File.ReadAllBytes(file));
        Assert.Equal([file], Directory.GetFiles(Folder));
    }

    [Fact]
    public void WriteOverwritesAndNeverAddsABOM()
    {
        var file = Path.Combine(Folder, "a.md");
        File.WriteAllText(file, "eski");
        NoteFile.Write("bir\niki", file);
        Assert.Equal(new UTF8Encoding(false).GetBytes("bir\niki"), File.ReadAllBytes(file));
        Assert.Equal([file], Directory.GetFiles(Folder));
    }

    [Fact]
    public void WriteFollowsSymlinksAndKeepsTheLink()
    {
        var target = Path.Combine(Folder, "gerçek.md");
        var link = Path.Combine(Folder, "bağ.md");
        File.WriteAllText(target, "eski");
        try { File.CreateSymbolicLink(link, target); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; } // no symlink privilege

        NoteFile.Write("yeni", link);
        Assert.Equal(target, new FileInfo(link).LinkTarget);
        Assert.Equal("yeni", File.ReadAllText(target));
        Assert.Equal(NoteFile.GetStamp(target), NoteFile.GetStamp(link));
    }

    [Fact]
    public void WriteKeepsAlternateStreamsAttributesAndCreationTime()
    {
        var file = Path.Combine(Folder, "etiketli.md");
        File.WriteAllText(file, "eski");
        File.WriteAllText(file + ":notes-test", "kırmızı");
        File.SetAttributes(file, FileAttributes.Archive | FileAttributes.NotContentIndexed);
        var created = new DateTime(2020, 1, 2, 3, 4, 5, DateTimeKind.Utc);
        File.SetCreationTimeUtc(file, created);

        NoteFile.Write("yeni", file);
        Assert.Equal("kırmızı", File.ReadAllText(file + ":notes-test"));
        Assert.True(File.GetAttributes(file).HasFlag(FileAttributes.NotContentIndexed));
        Assert.Equal(created, File.GetCreationTimeUtc(file));
        Assert.Equal("yeni", File.ReadAllText(file));
    }

    [Fact]
    public void FailedWriteLeavesTheFileAndNoTemporaryBehind()
    {
        var file = Path.Combine(Folder, "a.md");
        File.WriteAllText(file, "eski");
        using (new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read)) // blocks the replacement
        {
            Assert.ThrowsAny<IOException>(() => NoteFile.Write("yeni", file));
        }
        Assert.Equal("eski", File.ReadAllText(file));
        Assert.Equal([file], Directory.GetFiles(Folder));
    }

    /// <summary>Another program's atomic save is noticed even when it restores the old modification date and size.</summary>
    [Fact]
    public void StampChangesWithTheFileNotJustItsDate()
    {
        var file = Path.Combine(Folder, "a.md");
        NoteFile.Write("abc", file);
        var before = NoteFile.GetStamp(file)!.Value;

        var other = Path.Combine(Folder, "other.tmp");
        File.WriteAllText(other, "xyz");
        File.Replace(other, file, null);
        File.SetLastWriteTimeUtc(file, before.ModificationTime!.Value);

        var after = NoteFile.GetStamp(file)!.Value;
        Assert.Equal(before.ModificationTime, after.ModificationTime);
        Assert.Equal(before.Size, after.Size);
        Assert.NotEqual(before.Identity, after.Identity);
        Assert.NotEqual(before, after);
        Assert.Null(NoteFile.GetStamp(Path.Combine(Folder, "yok.md")));
        Assert.Null(NoteFile.GetStamp(Folder));
    }

    [Fact]
    public void SizeIsTheFileSize()
    {
        var file = Path.Combine(Folder, "a.md");
        NoteFile.Write("çğ", file);
        Assert.Equal(4, NoteFile.GetSize(file));
        Assert.Null(NoteFile.GetSize(Path.Combine(Folder, "yok.md")));
    }

    [Fact]
    public void TooLargeMessageNamesTheLimit()
    {
        Assert.Equal("The file is too large (300 MB); files up to 200 MB can be opened.", new NoteFileTooLargeException(300L * 1_048_576).Message);
        using var _ = TestCulture.Use("tr");
        Assert.Equal("Dosya çok büyük (300 MB); en fazla 200 MB açılabilir.", new NoteFileTooLargeException(300L * 1_048_576).Message);
    }

    [Fact]
    public void ReadRejectsAFileOverTheLimitBeforeReadingIt()
    {
        var file = Path.Combine(Folder, "huge.md");
        using (var stream = new FileStream(file, FileMode.Create)) stream.SetLength(NoteFile.MaxOpenSize + 1);
        var error = Assert.Throws<NoteFileTooLargeException>(() => NoteFile.Read(file));
        Assert.Equal(NoteFile.MaxOpenSize + 1, error.Bytes);
    }

    [Fact]
    public void LoneSurrogateFailsAndKeepsTheOriginal()
    {
        var file = Path.Combine(Folder, "a.md");
        File.WriteAllText(file, "old");
        Assert.ThrowsAny<Exception>(() => NoteFile.Write("x\uD800y", file));
        Assert.Equal("old", File.ReadAllText(file));
        Assert.Equal(["a.md"], Directory.EnumerateFileSystemEntries(Folder).Select(Path.GetFileName));
    }

    [Fact]
    public void FailedReplaceKeepsTheOriginalAndLeavesNoTemporaryFiles()
    {
        var file = Path.Combine(Folder, "a.md");
        File.WriteAllText(file, "old");
        using (new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.Read))
            Assert.ThrowsAny<Exception>(() => NoteFile.Write("new", file));
        Assert.Equal("old", File.ReadAllText(file));
        Assert.Equal(["a.md"], Directory.EnumerateFileSystemEntries(Folder).Select(Path.GetFileName));
    }

    [Fact]
    public void SuccessfulWriteLeavesNoTemporaryFiles()
    {
        var file = Path.Combine(Folder, "a.md");
        File.WriteAllText(file, "old");
        NoteFile.Write("new", file);
        Assert.Equal("new", File.ReadAllText(file));
        Assert.Equal(["a.md"], Directory.EnumerateFileSystemEntries(Folder).Select(Path.GetFileName));
    }

    [Fact]
    public void DanglingSymlinkIsNotReplacedByAFile()
    {
        var link = Path.Combine(Folder, "l.md");
        try { File.CreateSymbolicLink(link, Path.Combine(Folder, "missing.md")); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; } // no symlink privilege
        Assert.Throws<IOException>(() => NoteFile.Write("x", link));
        Assert.NotNull(new FileInfo(link).LinkTarget);
        Assert.Null(NoteFile.GetStamp(link));
    }

    [Fact]
    public void ReadWorksWhileAnotherProgramHasTheFileOpenForWriting()
    {
        var file = Path.Combine(Folder, "open.md");
        File.WriteAllText(file, "açık");
        using var writer = new FileStream(file, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete);
        Assert.Equal("açık", NoteFile.Read(file));
    }

    [Fact]
    public void WriteNormalizesSoWhatIsWrittenReadsBackUnchanged()
    {
        var file = Path.Combine(Folder, "yapıştır.md");
        var pasted = "﻿bir\r\niki\r\nüç 😀\r\n";
        NoteFile.Write(pasted, file);
        Assert.Equal(new UTF8Encoding(false).GetBytes("bir\niki\nüç 😀\n"), File.ReadAllBytes(file));
        Assert.Equal(NoteFile.Normalized(pasted), NoteFile.Read(file));
        // Overwriting an existing file goes through the same path.
        NoteFile.Write("x\r\ny", file);
        Assert.Equal("x\ny", NoteFile.Read(file));
    }

    [Fact]
    public void NormalizedOnlyTouchesBOMAndCRLF()
    {
        Assert.Equal("a\rb", NoteFile.Normalized("a\rb"));
        Assert.Equal("a\n\nb\r", NoteFile.Normalized("a\r\n\r\nb\r"));
        Assert.Equal("﻿a", NoteFile.Normalized("﻿﻿a"));
        Assert.Equal("İ ı çğ 😀\n", NoteFile.Normalized("İ ı çğ 😀\n"));
        Assert.Equal("", NoteFile.Normalized(""));
        Assert.True(NoteFile.NeedsNormalizing("﻿a"));
        Assert.True(NoteFile.NeedsNormalizing("a\r\nb"));
        Assert.False(NoteFile.NeedsNormalizing("a\rb\n"));
    }

    [Fact]
    public void WriteBytesIsAtomicAndKeepsTheBytes()
    {
        var file = Path.Combine(Folder, "a.mdenc");
        byte[] first = [0, 1, 2, 0xFF, 0x0D, 0x0A];
        NoteFile.Write(first, file);
        Assert.Equal(first, NoteFile.ReadData(file));
        byte[] second = [9, 8, 7];
        NoteFile.Write(second, file);
        Assert.Equal(second, NoteFile.ReadData(file));
        Assert.Equal([file], Directory.GetFiles(Folder));
    }

    [Fact]
    public void CoarseTimestampsAreWholeSeconds()
    {
        var whole = new NoteFile.Stamp(new DateTime(2023, 11, 14, 22, 13, 20, DateTimeKind.Utc), 1, null);
        var fine = new NoteFile.Stamp(new DateTime(2023, 11, 14, 22, 13, 20, DateTimeKind.Utc).AddTicks(1_234_560), 1, null);
        Assert.True(whole.HasCoarseTimestamp);
        Assert.False(fine.HasCoarseTimestamp);
        Assert.True(new NoteFile.Stamp(null, 1, null).HasCoarseTimestamp);
    }

    [Fact]
    public void ContentCheckIsForSmallFilesAndRecentCoarseStampsOfBigOnes()
    {
        var now = new DateTime(2024, 1, 1, 12, 0, 0, DateTimeKind.Utc);
        var big = NoteFile.VerifySize + 1;
        Assert.True(NoteFile.NeedsContentCheck(new NoteFile.Stamp(now.AddDays(-9).AddTicks(5), 10, null), now));
        Assert.True(NoteFile.NeedsContentCheck(new NoteFile.Stamp(now.AddSeconds(-1), big, null), now));
        Assert.False(NoteFile.NeedsContentCheck(new NoteFile.Stamp(now.AddSeconds(-1).AddTicks(7), big, null), now));
        Assert.False(NoteFile.NeedsContentCheck(new NoteFile.Stamp(now.AddSeconds(-30), big, null), now));
    }

    [Fact]
    public void BrokenLinkChainIsRejected()
    {
        var first = Path.Combine(Folder, "bir.md");
        var second = Path.Combine(Folder, "iki.md");
        try
        {
            File.CreateSymbolicLink(second, Path.Combine(Folder, "yok.md"));
            File.CreateSymbolicLink(first, second);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; } // no symlink privilege
        Assert.Null(NoteFile.GetStamp(first));
        Assert.Throws<NoteFileBrokenLinkException>(() => NoteFile.Write("x", first));
        Assert.Equal(second, new FileInfo(first).LinkTarget);
    }

    [Fact]
    public void FallsBackToMovingTheTemporaryFileWhenReplaceIsUnsupported()
    {
        var file = Path.Combine(Folder, "a.md");
        File.WriteAllText(file, "eski");
        File.SetAttributes(file, FileAttributes.Hidden);
        NoteFile.Write("yeni çğ", file, (_, _, _) => throw new IOException("share", unchecked((int)0x80070032)));
        Assert.Equal("yeni çğ", File.ReadAllText(file));
        Assert.True(File.GetAttributes(file).HasFlag(FileAttributes.Hidden));
        Assert.Equal(["a.md"], Directory.EnumerateFileSystemEntries(Folder).Select(Path.GetFileName));
    }

    [Fact]
    public void FallbackRestoresAHalfDoneReplace()
    {
        var file = Path.Combine(Folder, "a.md");
        File.WriteAllText(file, "eski");
        NoteFile.Write("yeni", file, (_, target, backup) =>
        {
            File.Move(target, backup); // ReplaceFile moved the original aside, then could not move the new one in
            throw new IOException("share", unchecked((int)0x80070498));
        });
        Assert.Equal("yeni", File.ReadAllText(file));
        Assert.Equal(["a.md"], Directory.EnumerateFileSystemEntries(Folder).Select(Path.GetFileName));
    }

    [Fact]
    public void OtherReplaceFailuresKeepTheOriginal()
    {
        var file = Path.Combine(Folder, "a.md");
        File.WriteAllText(file, "eski");
        // A sharing violation is not a missing capability: no fallback.
        Assert.Throws<IOException>(() => NoteFile.Write("yeni", file, (_, _, _) => throw new IOException("busy", unchecked((int)0x80070020))));
        Assert.Equal("eski", File.ReadAllText(file));
        Assert.Equal(["a.md"], Directory.EnumerateFileSystemEntries(Folder).Select(Path.GetFileName));
    }

    [Fact]
    public void ReadOnlyFileThrowsNotWritableAndKeepsItsContent()
    {
        var file = Path.Combine(Folder, "kilitli.md");
        File.WriteAllText(file, "eski");
        File.SetAttributes(file, FileAttributes.ReadOnly);
        try
        {
            Assert.False(NoteFile.IsWritable(file));
            var error = Assert.Throws<NoteFileNotWritableException>(() => NoteFile.Write("yeni", file));
            Assert.Equal(file, error.Path, ignoreCase: true);
            Assert.Contains("kilitli.md", error.Message);
            Assert.Equal("eski", File.ReadAllText(file));
            Assert.Equal(["kilitli.md"], Directory.EnumerateFileSystemEntries(Folder).Select(Path.GetFileName));
        }
        finally { File.SetAttributes(file, FileAttributes.Normal); }
    }

    [Fact]
    public void NotWritableMessageIsLocalized()
    {
        Assert.Equal("“kilitli.md” can't be saved because it is read-only or locked.",
            new NoteFileNotWritableException(Path.Combine(Folder, "kilitli.md")).Message);
        using var _ = TestCulture.Use("tr");
        Assert.Equal("“kilitli.md” salt okunur ya da kilitli olduğu için kaydedilemiyor.",
            new NoteFileNotWritableException(Path.Combine(Folder, "kilitli.md")).Message);
        Assert.Equal("“l.md”, var olmayan bir dosyaya bağlantı.", new NoteFileBrokenLinkException(Path.Combine(Folder, "l.md")).Message);
    }

    [Fact]
    public void FolderThatRefusesNewFilesIsNotWritable()
    {
        if (!OperatingSystem.IsWindows()) return;
        var sub = Path.Combine(Folder, "sub");
        Directory.CreateDirectory(sub);
        var file = Path.Combine(sub, "a.md");
        File.WriteAllText(file, "eski");
        using var deny = DenyCreatingFiles(sub);
        Assert.False(NoteFile.IsWritable(file));
        Assert.False(NoteFile.IsWritable(Path.Combine(sub, "yeni.md")));
        Assert.Throws<NoteFileNotWritableException>(() => NoteFile.Write("yeni", file));
        deny.Dispose();
        Assert.Equal("eski", File.ReadAllText(file));
        Assert.Equal(["a.md"], Directory.EnumerateFileSystemEntries(sub).Select(Path.GetFileName));
        Assert.True(NoteFile.IsWritable(file));
    }

    [Fact]
    public void IsWritableHandlesMissingFilesFoldersAndLinks()
    {
        var file = Path.Combine(Folder, "a.md");
        File.WriteAllText(file, "a");
        Assert.True(NoteFile.IsWritable(file));
        Assert.True(NoteFile.IsWritable(Path.Combine(Folder, "yeni.md")));
        Assert.False(NoteFile.IsWritable(Path.Combine(Folder, "yok", "yeni.md")));
        Assert.False(NoteFile.IsWritable(Folder));
        var link = Path.Combine(Folder, "bağ.md");
        try { File.CreateSymbolicLink(link, file); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return; } // no symlink privilege
        Assert.True(NoteFile.IsWritable(link));
        File.SetAttributes(file, FileAttributes.ReadOnly);
        try { Assert.False(NoteFile.IsWritable(link)); }
        finally { File.SetAttributes(file, FileAttributes.Normal); }
    }

    [Fact]
    public void IsWritableLeavesNoTemporaryFileBehind()
    {
        var file = Path.Combine(Folder, "a.md");
        File.WriteAllText(file, "a");
        Assert.True(NoteFile.IsWritable(file));
        Assert.Equal(["a.md"], Directory.EnumerateFileSystemEntries(Folder).Select(Path.GetFileName));
    }

    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static IDisposable DenyCreatingFiles(string folder)
    {
        var info = new DirectoryInfo(folder);
        var rule = new System.Security.AccessControl.FileSystemAccessRule(
            System.Security.Principal.WindowsIdentity.GetCurrent().User!,
            System.Security.AccessControl.FileSystemRights.CreateFiles,
            System.Security.AccessControl.AccessControlType.Deny);
        var acl = info.GetAccessControl();
        acl.AddAccessRule(rule);
        info.SetAccessControl(acl);
        return new Undo(() =>
        {
            var current = info.GetAccessControl();
            current.RemoveAccessRule(rule);
            info.SetAccessControl(current);
        });
    }

    private sealed class Undo(Action action) : IDisposable
    {
        private bool done;

        public void Dispose()
        {
            if (done) return;
            done = true;
            action();
        }
    }
}
