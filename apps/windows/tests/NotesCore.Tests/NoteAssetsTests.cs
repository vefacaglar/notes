namespace NotesCore.Tests;

public sealed class MarkdownImagesTests
{
    [Fact]
    public void FindsImagesAndSkipsCode()
    {
        var text = "a ![alt](assets/x%201.png) b\n`![no](c.png)`\n```\n![no](d.png)\n```\n![](<my pic.png> \"t\")\n\\![no](e.png)\n";
        var images = MarkdownImages.References(text);
        Assert.Equal(["assets/x%201.png", "my pic.png"], images.Select(i => i.Destination));
        Assert.Equal("alt", images[0].Alt);
        Assert.Equal("![alt](assets/x%201.png)", text.Substring(images[0].Range.Location, images[0].Range.Length));
    }

    [Fact]
    public void Utf16RangesWithEmoji()
    {
        var text = "😀 ![ç](ü.png)";
        var image = MarkdownImages.References(text)[0];
        Assert.Equal("![ç](ü.png)", text.Substring(image.Range.Location, image.Range.Length));
    }

    [Fact]
    public void RejectsBrokenSyntax()
    {
        Assert.Empty(MarkdownImages.References("![a](b.png\n)"));
        Assert.Empty(MarkdownImages.References("![a] (b.png)"));
        Assert.Empty(MarkdownImages.References("![a]()"));
    }

    [Fact]
    public void ResolvesDestinations()
    {
        var folder = @"C:\tmp\notes\Work";
        Assert.Equal(@"C:\tmp\notes\Work\assets\a b.png", MarkdownImages.FilePath("assets/a%20b.png", folder));
        Assert.Equal(@"C:\tmp\notes\x.png", MarkdownImages.FilePath("../x.png", folder));
        Assert.Equal(@"C:\abs\x.png", MarkdownImages.FilePath(@"C:\abs\x.png", folder));
        Assert.Equal(@"C:\abs\y.png", MarkdownImages.FilePath("file:///C:/abs/y.png", null));
        Assert.Null(MarkdownImages.FilePath("https://example.com/x.png", folder));
        Assert.Null(MarkdownImages.FilePath("a.png", null));
        Assert.Null(MarkdownImages.FilePath("a:b.png", folder));
        Assert.Null(MarkdownImages.FilePath(@"\\server\share\x.png", folder));
        Assert.Null(MarkdownImages.FilePath("file://server/share/x.png", folder));
        Assert.Equal(@"\\server\share\n\assets\x.png", MarkdownImages.FilePath("assets/x.png", @"\\server\share\n"));
        Assert.Null(MarkdownImages.FilePath(@"..\..\x.png", @"\\server\share\n"));
        Assert.Null(MarkdownImages.FilePath(@"\\server\other\x.png", @"\\server\share\n"));
    }
}

public sealed class NoteAssetsTests
{
    [Fact]
    public void NamesFollowPortableRules()
    {
        Assert.Equal("Plan 2.png", NoteAssets.FileName("Plan", 2, "png"));
        Assert.Equal("Why-- a-b 1.png", NoteAssets.FileName("Why?: a/b", 1, "png"));
        Assert.Equal("image 1.png", NoteAssets.FileName("..", 1, "png"));
        Assert.Equal("con_.x 1.png", NoteAssets.FileName("con.x", 1, "png"));
        Assert.Equal(60 + 6, NoteAssets.FileName(new string('a', 100), 1, "jpg").Length);
    }

    [Fact]
    public void DestinationIsPercentEncoded()
    {
        var destination = NoteAssets.Destination("Çalışma (1) 2.png");
        Assert.Equal("assets/%C3%87al%C4%B1%C5%9Fma%20%281%29%202.png", destination);
        Assert.Equal("assets/Çalışma (1) 2.png", NoteLinks.PercentDecode(destination));
    }

    [Fact]
    public void SavesUniqueFilesAndLeavesNoTemporaries()
    {
        using var temp = new NotesTempFolder();
        var note = Path.Combine(temp.Path, "Notlar.md");
        var first = NoteAssets.Save([1], note);
        var second = NoteAssets.Save([2], note);
        Assert.Equal("assets/Notlar%201.png", first);
        Assert.Equal("assets/Notlar%202.png", second);
        var file = MarkdownImages.FilePath(second, temp.Path)!;
        Assert.Equal([2], File.ReadAllBytes(file));
        var names = Directory.GetFileSystemEntries(Path.Combine(temp.Path, "assets")).Select(Path.GetFileName).Order().ToList();
        Assert.Equal(["Notlar 1.png", "Notlar 2.png"], names);
    }

    [Fact]
    public void NeverReplacesAnExistingFile()
    {
        using var temp = new NotesTempFolder();
        var assets = Directory.CreateDirectory(Path.Combine(temp.Path, "assets")).FullName;
        File.WriteAllBytes(Path.Combine(assets, "a 1.png"), [9]);
        Assert.Equal("assets/a%202.png", NoteAssets.Save([1], Path.Combine(temp.Path, "a.md")));
        Assert.Equal([9], File.ReadAllBytes(Path.Combine(assets, "a 1.png")));
    }

    [Fact]
    public void FailsWhenAssetsIsAFile()
    {
        using var temp = new NotesTempFolder();
        File.WriteAllBytes(Path.Combine(temp.Path, "assets"), []);
        Assert.ThrowsAny<IOException>(() => NoteAssets.Save([1], Path.Combine(temp.Path, "a.md")));
    }
}
