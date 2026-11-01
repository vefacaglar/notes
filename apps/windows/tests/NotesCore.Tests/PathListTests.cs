namespace NotesCore.Tests;

public sealed class PathListTests
{
    [Fact]
    public void AppendAndRemoveAreUnique()
    {
        var list = new PathList();
        list.Append("/a/b.md");
        list.Append("/a/b.md");
        Assert.Equal(["/a/b.md"], list.Paths);
        list.Remove("/a/b.md");
        Assert.Empty(list.Paths);
    }

    [Fact]
    public void PushMovesToFrontAndCaps()
    {
        var list = new PathList(["/1", "/2", "/3"]);
        list.Push("/3", 3);
        Assert.Equal(["/3", "/1", "/2"], list.Paths);
        list.Push("/4", 3);
        Assert.Equal(["/4", "/3", "/1"], list.Paths);
    }

    [Fact]
    public void MovedFollowsItemsAndFolders()
    {
        var list = new PathList(["/r/Work/a.md", "/r/Worker.md", "/r/b.md"]);
        list.MovedFrom("/r/Work", "/r/Plans/Work");
        Assert.Equal(["/r/Plans/Work/a.md", "/r/Worker.md", "/r/b.md"], list.Paths);
        list.MovedFrom("/r/b.md", "/r/Worker.md");
        Assert.Equal(["/r/Plans/Work/a.md", "/r/Worker.md"], list.Paths);
    }

    [Fact]
    public void WindowsPathsIgnoreCaseAndUseBackslashes()
    {
        var list = new PathList([@"C:\r\Work\a.md", @"C:\r\Worker.md"]);
        Assert.True(list.Contains(@"c:\R\WORK\A.md"));
        list.MovedFrom(@"c:\r\work", @"C:\r\Plans\Work");
        Assert.Equal([@"C:\r\Plans\Work\a.md", @"C:\r\Worker.md"], list.Paths);
        list.RemoveItem(@"C:\r\Plans\Work");
        Assert.Equal([@"C:\r\Worker.md"], list.Paths);
    }

    [Fact]
    public void RemoveItemDropsFolderContents()
    {
        var list = new PathList(["/r/Work/a.md", "/r/Worker.md", "/r/Work"]);
        list.RemoveItem("/r/Work");
        Assert.Equal(["/r/Worker.md"], list.Paths);
    }

    [Fact]
    public void WriteAndReadRoundTrip()
    {
        using var temp = new NotesTempFolder();
        var path = Path.Combine(temp.Path, "Paths", "pins.json");
        var list = new PathList(["/r/Işık 🙂.md", @"C:\r\a ""q"".md"]);
        list.Write(path);
        Assert.Equal(list, PathList.Read(path));
        Assert.Contains("\"version\": 1", File.ReadAllText(path));
        Assert.Null(PathList.Read(path + ".none"));
        File.WriteAllText(path, "{\"paths\": 3}");
        Assert.Null(PathList.Read(path));
    }
}
