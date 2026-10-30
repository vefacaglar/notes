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
    public void WriteConvertsNothingButNeverAddsABOM()
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
}