using System.Globalization;
using System.Text;

namespace NotesCore.Tests;

public sealed class NotePreviewTests
{
    [Fact]
    public void FirstLineAfterTitle() => Assert.Equal("Second line", NoteStore.Preview("Title\nSecond line\nThird"));

    [Fact]
    public void SkipsBlankLinesAndStripsMarkers()
    {
        Assert.Equal("Heading two", NoteStore.Preview("# Title\n\n\n## Heading two\n"));
        Assert.Equal("done and code", NoteStore.Preview("T\n- [x] **done** and `code`"));
        Assert.Equal("quoted text", NoteStore.Preview("T\n> quoted *text*"));
        Assert.Equal("a link here", NoteStore.Preview("T\n1. [a link](https://x.com) here"));
    }

    [Fact]
    public void SkipsRulesAndFences()
    {
        Assert.Equal("After rule", NoteStore.Preview("T\n---\nAfter rule"));
        Assert.Equal("Real text", NoteStore.Preview("T\n```swift\nlet x = 1\n```\nReal text"));
    }

    [Fact]
    public void NullWithoutSecondLine()
    {
        Assert.Null(NoteStore.Preview(""));
        Assert.Null(NoteStore.Preview("Only title"));
        Assert.Null(NoteStore.Preview("Title\n   \n\t\n"));
    }

    [Fact]
    public void CrlfBomAndCollapsedWhitespace() =>
        Assert.Equal("İlk satır ışık", NoteStore.Preview("﻿Title\r\nİlk   satır\t ışık\r\nTwo"));

    [Fact]
    public void EmojiAndLength()
    {
        Assert.Equal("🙂 hi 👍🏽", NoteStore.Preview("T\n🙂 **hi** 👍🏽"));
        var preview = NoteStore.Preview("T\n" + string.Concat(Enumerable.Repeat("ab ", 200)));
        Assert.NotNull(preview);
        Assert.True(new StringInfo(preview).LengthInTextElements <= NoteStore.MaxPreviewLength);
        var family = NoteStore.Preview("T\n" + string.Concat(Enumerable.Repeat("👨‍👩‍👧 ", 300)));
        Assert.Equal(NoteStore.MaxPreviewLength, new StringInfo(family!).LengthInTextElements);
    }

    [Fact]
    public void ReadsOnlyTheFirstBytesAndSurvivesACutCharacter()
    {
        using var temp = new NotesTempFolder();
        var path = Path.Combine(temp.Path, "Preview.md");
        // The second line runs past the 2048-byte boundary inside a multi-byte character.
        File.WriteAllBytes(path, Encoding.UTF8.GetBytes("Title\nBody " + new string('ş', 2000)));
        var preview = NoteStore.PreviewOfFile(path);
        Assert.NotNull(preview);
        Assert.StartsWith("Body ş", preview);
        Assert.True(Encoding.UTF8.GetByteCount(preview) <= NoteStore.PreviewBytes);
        Assert.Null(NoteStore.PreviewOfFile(path + ".missing"));
    }

    [Fact]
    public void EncryptedNotesHaveNoPreview()
    {
        using var temp = new NotesTempFolder();
        var path = Path.Combine(temp.Path, "Secret.mdenc");
        File.WriteAllText(path, "Title\nBody");
        Assert.Null(NoteStore.PreviewOfFile(path));
    }
}
