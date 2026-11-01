using NotesCore;

namespace NotesCore.Tests;

/// <summary>A fresh folder under the system temp folder, removed on dispose. Tests never touch real notes.</summary>
internal sealed class NotesTempFolder : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "NotesCoreTests-" + Guid.NewGuid().ToString("N"));

    public NotesTempFolder() => Directory.CreateDirectory(Path);

    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

/// <summary>Sends items to the real Recycle Bin, so it only runs with NOTES_TEST_RECYCLE=1.</summary>
internal sealed class RecycleFactAttribute : FactAttribute
{
    public RecycleFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("NOTES_TEST_RECYCLE") != "1") Skip = "set NOTES_TEST_RECYCLE=1 to run";
    }
}

public sealed class NoteStoreTests : IDisposable
{
    private readonly NotesTempFolder temp = new();
    private readonly string root;
    private readonly NoteStore store;

    public NoteStoreTests()
    {
        root = System.IO.Path.Combine(temp.Path, "Notes");
        store = new NoteStore(root);
    }

    public void Dispose() => temp.Dispose();

    private void Put(string path, string text = "")
    {
        var full = System.IO.Path.Combine(root, path.Replace('/', '\\'));
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(full)!);
        File.WriteAllBytes(full, new System.Text.UTF8Encoding(false).GetBytes(text));
    }

    private static NoteStoreException Invalid(string name) => new(NoteStoreError.InvalidName, name);

    private static void AssertThrows(NoteStoreError error, string name, Action action)
    {
        var e = Assert.Throws<NoteStoreException>(action);
        Assert.Equal((error, name), (e.Error, e.Name));
    }

    [Fact]
    public void RootIsCreated()
    {
        Assert.True(Directory.Exists(root));
        Assert.Equal(root, store.Root);
    }

    [Fact]
    public void TreeListsFoldersFirstAndSkipsHiddenAndUnknownFiles()
    {
        Put("b.md");
        Put("a.md");
        Put("image.png");
        Put("Makefile");
        Put(".hidden.md");
        Put(".git/config");
        Put("Work/plan.md");

        var tree = store.Tree();
        Assert.Equal(["Work", "a.md", "b.md"], tree.Select(n => n.Path));
        Assert.Equal(["Work/plan.md"], tree[0].Children!.Select(n => n.Path));
        Assert.Equal("a", tree[1].Name);
        Assert.True(tree[1].IsNote);
        Assert.Null(tree[1].Children);
    }

    [Fact]
    public void TreeListsCodeAndTextFilesWithTheirExtension()
    {
        Put("config.json");
        Put("a.md");
        Put("Log.TXT");
        Put("data.csv");
        Put("server.log");
        Put("script.py");
        Put("Work/app.swift");

        var tree = store.Tree();
        Assert.Equal(["Work", "a", "config.json", "data.csv", "Log.TXT", "script.py", "server.log"], tree.Select(n => n.Name));
        Assert.Equal(["a.md"], tree.Where(n => n.IsNote).Select(n => n.Path));
        Assert.Equal(["app.swift"], tree[0].Children!.Select(n => n.Name));
        Assert.Equal(["Work/app.swift", "a.md", "config.json", "data.csv", "Log.TXT", "script.py", "server.log"], store.NotePaths());
    }

    [Fact]
    public void TreeOrdersNumbersByValueAndIgnoresCase()
    {
        foreach (var name in new[] { "10.md", "2.md", "b.md", "A.md", "Work 10/x.md", "Work 2/x.md" }) Put(name);
        Assert.Equal(["Work 2", "Work 10", "2", "10", "A", "b"], store.Tree().Select(n => n.Name));
    }

    [Fact]
    public void TreeIsComparedByValue()
    {
        Put("Work/plan.md");
        Assert.Equal(store.Tree(), store.Tree());
        Put("Work/other.md");
        var before = store.Tree();
        File.Delete(System.IO.Path.Combine(root, "Work", "other.md"));
        Assert.NotEqual(before, store.Tree());
    }

    [Theory]
    [InlineData("a.md")]
    [InlineData("A.MD")]
    [InlineData("x.mdown")]
    [InlineData("x.mkd")]
    [InlineData("x.markdown")]
    [InlineData("x.json")]
    [InlineData("x.yml")]
    [InlineData("x.ts")]
    [InlineData("x.txt")]
    [InlineData("x.log")]
    [InlineData("x.csv")]
    [InlineData("Work/x.swift")]
    public void ListsKnownExtensions(string path) => Assert.True(NoteStore.IsListed(path));

    [Theory]
    [InlineData("x.png")]
    [InlineData("x.pdf")]
    [InlineData("Makefile")]
    [InlineData("x.")]
    [InlineData("x.docx")]
    public void SkipsUnknownExtensions(string path) => Assert.False(NoteStore.IsListed(path));

    [Fact]
    public void CreateWriteReadRoundTrip()
    {
        var path = store.CreateNote("  Günlük  ", "Kişisel");
        Assert.Equal("Kişisel/Günlük.md", path);
        Assert.Equal("", store.Read(path));

        store.Write("# Başlık\nçğıöşü\n", path);
        Assert.Equal("# Başlık\nçğıöşü\n", store.Read(path));
    }

    [Fact]
    public void CreateRejectsDuplicates()
    {
        store.CreateNote("a");
        AssertThrows(NoteStoreError.AlreadyExists, "a.md", () => store.CreateNote("a.md"));
        AssertThrows(NoteStoreError.AlreadyExists, "A.md", () => store.CreateNote("A"));
        store.CreateFolder("F");
        AssertThrows(NoteStoreError.AlreadyExists, "F", () => store.CreateFolder("F"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("../escape")]
    [InlineData("a/../b")]
    [InlineData("a/./b")]
    [InlineData(".")]
    [InlineData(".hidden")]
    [InlineData("x//y")]
    [InlineData("/abs")]
    [InlineData("a/")]
    [InlineData("..\u0301/x")]
    [InlineData("a/.\u200D./b")]
    // Windows: a backslash or colon would leave the root or address a stream.
    [InlineData("a\\b")]
    [InlineData("a\\..\\..\\x")]
    [InlineData("C:x")]
    [InlineData("C:\\x")]
    [InlineData("a.md:stream")]
    public void RejectsInvalidPaths(string path) => AssertThrows(NoteStoreError.InvalidName, path, () => store.FullPath(path));

    /// <summary>Components that merely look like ".." (a mark or ZWJ before the dots) are ordinary names inside the root.</summary>
    [Fact]
    public void LookalikeDotComponentsStayInsideTheRoot()
    {
        var full = store.FullPath("a/\u200D..\u200D/b");
        Assert.StartsWith(root + "\\a\\", System.IO.Path.GetFullPath(full), StringComparison.Ordinal);
        Assert.Equal("b", System.IO.Path.GetFileName(full));
    }

    [Fact]
    public void PathsSplitOnTheSlashScalar()
    {
        // "/" + U+0301 is one grapheme cluster; it must still separate components.
        const string path = "w/\u0301x.md";
        Assert.Equal(["w", "\u0301x.md"], NoteStore.Components(path));
        Assert.Equal(System.IO.Path.Join(root, "w", "\u0301x.md"), store.FullPath(path));
        Assert.Equal("w", NoteStore.Parent(path));
        Assert.Equal("v/\u0301x.md", NoteStore.Moved(path, "w", "v"));
        Assert.Null(NoteStore.Moved("wx", "w", "v"));
        Assert.Equal("\u0301x", NoteStore.DisplayName(path));
        Assert.Equal("", NoteStore.Parent("a.md"));
        Assert.Equal("v", NoteStore.Moved("w", "w", "v"));
    }

    /// <summary>
    /// Files made by other apps may break the portable rules; they must still open, rename and trash. Windows can't
    /// create names with ":" or "?", so C1 control characters (allowed by NTFS, rejected by the rules) stand in.
    /// </summary>
    [Fact]
    public void ExistingNonPortableNamesStillWork()
    {
        Put("Why\u0080.md", "x");
        Put("10\u009F30.md", "y");
        Put("trailing..md", "z");
        Assert.Equal(["10\u009F30.md", "trailing..md", "Why\u0080.md"], store.NotePaths());
        Assert.Equal("x", store.Read("Why\u0080.md"));

        Assert.Equal("Why.md", store.Rename("Why\u0080.md", "Why"));
        Assert.Equal("x", store.Read("Why.md"));
        File.Delete(store.FullPath("10\u009F30.md"));
        Assert.Equal(["trailing..md", "Why.md"], store.NotePaths());
    }

    [Theory]
    [InlineData("a:b")]
    [InlineData("a?b")]
    [InlineData("a*b")]
    [InlineData("a|b")]
    [InlineData("a<b")]
    [InlineData("a\"b")]
    [InlineData("a\\b")]
    [InlineData("tab\tname")]
    [InlineData(".hidden")]
    [InlineData("CON")]
    public void TypedNamesFollowPortableRules(string name)
    {
        Put("a.md");
        Assert.Throws<NoteStoreException>(() => store.CreateNote(name));
        Assert.Throws<NoteStoreException>(() => store.CreateFolder(name));
        Assert.Throws<NoteStoreException>(() => store.Rename("a.md", name));
        Assert.Equal(["a.md"], store.NotePaths());
    }

    [Fact]
    public void TypedFolderNamesCannotEndWithADot()
    {
        AssertThrows(NoteStoreError.InvalidName, "F.", () => store.CreateFolder("F."));
        store.CreateFolder("F");
        AssertThrows(NoteStoreError.InvalidName, "G.", () => store.Rename("F", "G."));
    }

    [Fact]
    public void RenameKeepsExtensionAndFolder()
    {
        Put("Work/old.md", "x");
        var newPath = store.Rename("Work/old.md", "new");
        Assert.Equal("Work/new.md", newPath);
        Assert.Equal("x", store.Read(newPath));
        Assert.Null(store.ModificationDate("Work/old.md"));
        Assert.NotNull(store.ModificationDate(newPath));
    }

    [Fact]
    public void RenameToTheSameNameIsANoOp()
    {
        Put("Work/note.md", "x");
        Assert.Equal("Work/note.md", store.Rename("Work/note.md", "note"));
        Assert.Equal("Work/note.md", store.Rename("Work/note.md", " note.md "));
        Assert.Equal("x", store.Read("Work/note.md"));
    }

    [Fact]
    public void RenameKeepsTheExtensionOfOtherFiles()
    {
        Put("config.json", "{}");
        Assert.Equal("settings.json", store.Rename("config.json", "settings"));
        Assert.Equal("settings.yaml", store.Rename("settings.json", "settings.yaml"));
        // Only listed extensions count as extensions: ".5" or ".png" would make the file vanish from the list.
        Assert.Equal("Toplantı 3.5.yaml", store.Rename("settings.yaml", "Toplantı 3.5"));
        Assert.Equal("resim.png.yaml", store.Rename("Toplantı 3.5.yaml", "resim.png"));
        Assert.Equal(["resim.png.yaml"], store.NotePaths());
        store.CreateFolder("Folder");
        Assert.Equal("Klasör", store.Rename("Folder", "Klasör"));
    }

    [Fact]
    public void RenameChangingOnlyCase()
    {
        Put("note.md", "x");
        var newPath = store.Rename("note.md", "Note");
        Assert.Equal("Note.md", newPath);
        Assert.Equal(["Note.md"], store.NotePaths());
        Assert.Equal("x", store.Read("Note.md"));
        Assert.DoesNotContain(Directory.GetFileSystemEntries(root), e => System.IO.Path.GetFileName(e).StartsWith('.'));
    }

    [Fact]
    public void RenameFolderChangingOnlyCase()
    {
        Put("work/plan.md", "x");
        Assert.Equal("Work", store.Rename("work", "Work"));
        Assert.Equal(["Work/plan.md"], store.NotePaths());
        Assert.Equal(["Work"], store.Tree().Select(n => n.Name));
    }

    [Fact]
    public void RenameRejectsExistingTargetAndSlashes()
    {
        Put("a.md");
        Put("b.md");
        AssertThrows(NoteStoreError.AlreadyExists, "b.md", () => store.Rename("a.md", "b"));
        AssertThrows(NoteStoreError.AlreadyExists, "B.md", () => store.Rename("a.md", "B"));
        AssertThrows(NoteStoreError.InvalidName, "x/y", () => store.Rename("a.md", "x/y"));
        Assert.Equal(["a.md", "b.md"], store.NotePaths());
    }

    [Fact]
    public void RenameOfAMissingItemFails()
    {
        Assert.Throws<FileNotFoundException>(() => store.Rename("yok.md", "x"));
    }

    [RecycleFact]
    public void TrashMovesToTheRecycleBin()
    {
        Put("Work/plan.md", "x");
        store.Trash("Work/plan.md");
        Assert.False(File.Exists(System.IO.Path.Combine(root, "Work", "plan.md")));
        Assert.Empty(store.NotePaths());
        store.Trash("Work");
        Assert.Empty(store.Tree());
    }

    [Fact]
    public void SearchMatchesNamesThenLinesIgnoringCaseAndDiacritics()
    {
        Put("Toplantı.md", "gündem\n");
        Put("other.md", "ilk satır\nTOPLANTI notları\nson");

        var hits = store.Search("toplanti");
        Assert.Equal(["Toplantı.md", "other.md"], hits.Select(h => h.Path));
        Assert.Null(hits[0].Line);
        Assert.Equal(2, hits[1].Line);
        Assert.Equal("TOPLANTI notları", hits[1].Snippet);
        Assert.Empty(store.Search("   "));
    }

    [Fact]
    public void SearchIgnoresTheCurrentCulture()
    {
        Put("Işık.md", "x");
        var previous = System.Globalization.CultureInfo.CurrentCulture;
        try
        {
            System.Globalization.CultureInfo.CurrentCulture = new System.Globalization.CultureInfo("tr-TR");
            Assert.Equal(["Işık.md"], store.Search("ışık").Select(h => h.Path));
            Assert.Equal(["Işık.md"], store.Search("ISIK").Select(h => h.Path));
        }
        finally { System.Globalization.CultureInfo.CurrentCulture = previous; }
    }

    [Fact]
    public void SearchCoversTextFilesAndTheirExtensions()
    {
        Put("config.json", "{\"toplantı\": 1}");
        Put("notes.txt", "nothing");

        Assert.Equal(["config.json"], store.Search("toplanti").Select(h => h.Path));
        Assert.Equal(["notes.txt"], store.Search(".txt").Select(h => h.Path));
        Assert.Empty(store.Search("md"));
    }

    [Fact]
    public void SearchTakesAtMostThreeLinesPerFileAndHonoursTheLimit()
    {
        Put("a.md", "x\nx\nx\nx\nx");
        Put("b.md", "x");
        Assert.Equal([1, 2, 3], store.Search("x").Where(h => h.Path == "a.md").Select(h => h.Line!.Value));
        Assert.Equal(2, store.Search("x", limit: 2).Count);
    }

    [Fact]
    public void ReadToleratesABomAndKeepsLineEndings()
    {
        Put("a.md", "\uFEFFbir\r\niki");
        Assert.Equal("bir\r\niki", store.Read("a.md"));
    }

    /// <summary>Creates entries the way Win32 normally refuses to: through the extended-length prefix.</summary>
    private static string Raw(string root, string relative)
    {
        var sep = System.IO.Path.DirectorySeparatorChar;
        return new string(sep, 2) + "?" + sep + root + sep + relative;
    }

    [Fact]
    public void TrailingDotEntriesAreSkippedAndRejected()
    {
        Put("bar.md", "x");
        File.WriteAllText(Raw(root, "bar."), "dot file");
        Directory.CreateDirectory(Raw(root, "dir."));
        File.WriteAllText(Raw(root, "dir.") + System.IO.Path.DirectorySeparatorChar + "in.md", "x");
        Assert.Equal(["bar.md"], store.NotePaths());
        Assert.Equal(["bar.md"], store.Tree().Select(n => n.Path));
        foreach (var path in new[] { "bar.", "dir./in.md", "Work/x.md." })
            Assert.Throws<NoteStoreException>(() => store.FullPath(path));
    }

    [Theory]
    [InlineData("a*.md")]
    [InlineData("a?.md")]
    [InlineData("a<b.md")]
    [InlineData("a>b.md")]
    [InlineData("a\"b.md")]
    [InlineData("a|b.md")]
    [InlineData("dir/*")]
    public void FullPathRejectsWildcardsAndReservedCharacters(string path) =>
        Assert.Throws<NoteStoreException>(() => store.FullPath(path));

    [Fact]
    public void CaseOnlyRenameLeavesNoTemporaryItem()
    {
        Put("a.md", "x");
        Assert.Equal("A.md", store.Rename("a.md", "A"));
        Assert.Equal(["A.md"], store.NotePaths());
        Assert.Equal(["A.md"], Directory.EnumerateFileSystemEntries(root).Select(System.IO.Path.GetFileName));
    }

    [Fact]
    public void SearchWithOnlyIgnorableCharactersFindsNothing()
    {
        Put("a.md", "a\u200Db \u0301 x");
        Assert.Empty(store.Search("\u200D"));
        Assert.Empty(store.Search("\u0301"));
        Assert.Empty(store.Search(" \u200D\u0301 "));
        Assert.Single(store.Search("x"));
    }

    [Fact]
    public void SnippetOfAHugeLineIsCheap()
    {
        var line = "  " + new string('x', 5_000_000) + "  ";
        NoteStore.Snippet(line);
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var snippet = NoteStore.Snippet(line);
        watch.Stop();
        Assert.Equal(160, snippet.Length);
        Assert.True(watch.ElapsedMilliseconds < 100, watch.Elapsed.ToString());
    }

    [Fact]
    public void SnippetCutsAfter160ClustersWithoutSplittingOne()
    {
        var family = "\U0001F468\u200D\U0001F469\u200D\U0001F467";
        var line = string.Concat(Enumerable.Repeat(family, 170));
        Assert.Equal(160, NoteStore.Clusters(NoteStore.Snippet(line)).Count);
        Assert.Equal("ab", NoteStore.Snippet("  ab \t"));
        Assert.Equal("", NoteStore.Snippet("   "));
    }

    [Fact]
    public void TrailingSpaceEntriesAreSkippedAndRejected()
    {
        Put("bar.md", "x");
        Directory.CreateDirectory(Raw(root, "bar "));
        File.WriteAllText(Raw(root, "bar ") + System.IO.Path.DirectorySeparatorChar + "in.md", "x");
        File.WriteAllText(Raw(root, "baz.md "), "x");
        Assert.Equal(["bar.md"], store.NotePaths());
        foreach (var path in new[] { "bar ", "bar /in.md", "baz.md " })
            Assert.Throws<NoteStoreException>(() => store.FullPath(path));
    }

    [Fact]
    public void JunctionBackToAnAncestorIsListedButNotFollowed()
    {
        Put("Üst/Alt/not.md");
        var link = Path.Combine(root, "Üst", "Alt", "döngü");
        var mklink = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("cmd.exe", $"/c mklink /J \"{link}\" \"{Path.Combine(root, "Üst")}\"")
        {
            CreateNoWindow = true,
            UseShellExecute = false,
        })!;
        mklink.WaitForExit();
        Assert.True(Directory.Exists(link));
        var loop = store.Tree().Single().Children!.Single().Children!.Single(n => n.IsFolder);
        Assert.Equal("Üst/Alt/döngü", loop.Path);
        Assert.Empty(loop.Children!);
        Assert.Equal(["Üst/Alt/not.md"], store.NotePaths());
    }

    [Fact]
    public void MissingRootIsOnlyCreatedOnRequest()
    {
        var missing = System.IO.Path.Combine(root, "yok");
        var e = Assert.Throws<NoteStoreException>(() => new NoteStore(missing, createIfMissing: false));
        Assert.Equal((NoteStoreError.RootUnavailable, missing), (e.Error, e.Name));
        Assert.False(Directory.Exists(missing));
        Put("dosya.md");
        Assert.Throws<NoteStoreException>(() => new NoteStore(System.IO.Path.Combine(root, "dosya.md"), createIfMissing: false));
        _ = new NoteStore(missing);
        Assert.True(Directory.Exists(missing));
    }
}
