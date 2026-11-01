using System.Text;

namespace NotesCore.Tests;

public sealed class NoteOperationsTests : IDisposable
{
    private readonly NotesTempFolder temp = new();
    private readonly string root;
    private readonly NoteStore store;

    public NoteOperationsTests()
    {
        root = Path.Combine(temp.Path, "Notes");
        store = new NoteStore(root);
    }

    public void Dispose()
    {
        // Names Win32 can't address (con.md) are removed through the extended prefix first.
        foreach (var file in Directory.EnumerateFiles(temp.Path, "*", SearchOption.AllDirectories))
        {
            if (!NoteStore.IsReservedName(Path.GetFileName(file))) continue;
            try { File.Delete(@"\\?\" + file); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }
        temp.Dispose();
    }

    private void Put(string path, string text = "")
    {
        var full = Path.Combine(root, path.Replace('/', '\\'));
        Directory.CreateDirectory(Path.GetDirectoryName(full)!);
        File.WriteAllBytes(full, new UTF8Encoding(false).GetBytes(text));
    }

    private bool Exists(string path) => File.Exists(Path.Combine(root, path.Replace('/', '\\'))) || Directory.Exists(Path.Combine(root, path.Replace('/', '\\')));

    [Fact]
    public void MoveIntoFolderKeepsContent()
    {
        Put("a.md", "hello");
        Put("Work/x.md");
        Assert.Equal("Work/a.md", store.Move("a.md", "Work"));
        Assert.False(Exists("a.md"));
        Assert.Equal("hello", store.Read("Work/a.md"));
    }

    [Fact]
    public void MoveToRootAndNoOp()
    {
        Put("Work/a.md", "x");
        Assert.Equal("Work/a.md", store.Move("Work/a.md", "Work"));
        Assert.Equal("a.md", store.Move("Work/a.md", null));
        Assert.True(Exists("a.md"));
    }

    [Fact]
    public void MoveNeverOverwritesAndNumbersTheName()
    {
        Put("a.md", "new");
        Put("Work/a.md", "old");
        Put("Work/a 2.md", "older");
        Assert.Equal("Work/a 3.md", store.Move("a.md", "Work"));
        Assert.Equal("old", store.Read("Work/a.md"));
        Assert.Equal("new", store.Read("Work/a 3.md"));
    }

    [Fact]
    public void MoveTakenNameIsComparedCaseInsensitively()
    {
        Put("a.md", "new");
        Put("Work/A.md", "old");
        Assert.Equal("Work/a 2.md", store.Move("a.md", "Work"));
        Assert.Equal("old", store.Read("Work/A.md"));
    }

    [Fact]
    public void MoveFolderNumbersWithoutExtension()
    {
        Put("Plans/p.md");
        Put("Work/Plans/q.md");
        Assert.Equal("Work/Plans 2", store.Move("Plans", "Work"));
        Assert.True(Exists("Work/Plans 2/p.md"));
    }

    [Fact]
    public void MoveRejectsItselfAndDescendants()
    {
        Put("A/B/x.md");
        Assert.Throws<NoteStoreException>(() => store.Move("A", "A"));
        Assert.Throws<NoteStoreException>(() => store.Move("A", "A/B"));
        Assert.True(Exists("A/B/x.md"));
    }

    [Fact]
    public void MoveToMissingFolderThrows()
    {
        Put("a.md");
        Assert.Throws<DirectoryNotFoundException>(() => store.Move("a.md", "Gone"));
        Assert.True(Exists("a.md"));
    }

    [Fact]
    public void MoveAcrossStores()
    {
        var other = new NoteStore(Path.Combine(temp.Path, "Other"));
        Put("Turkish/Toplantı ışık.md", "ı");
        File.WriteAllBytes(Path.Combine(other.Root, "Toplantı ışık.md"), []);
        var moved = store.Move("Turkish/Toplantı ışık.md", null, other);
        Assert.Equal("Toplantı ışık 2.md", moved);
        Assert.Equal("ı", other.Read(moved));
        Assert.False(Exists("Turkish/Toplantı ışık.md"));
    }

    [Fact]
    public void DuplicateNamesCopy()
    {
        Put("Plan.md", "text");
        Assert.Equal("Plan copy.md", store.Duplicate("Plan.md"));
        Assert.Equal("Plan copy 2.md", store.Duplicate("Plan.md"));
        Assert.Equal("Plan copy copy.md", store.Duplicate("Plan copy.md"));
        Assert.Equal("text", store.Read("Plan copy 2.md"));
    }

    [Fact]
    public void DuplicateInFolderAndTurkish()
    {
        Put("Work/Plan.md");
        Put("Work/config.json", "{}");
        using var _ = TestCulture.Use("tr");
        Assert.Equal("Work/Plan kopya.md", store.Duplicate("Work/Plan.md"));
        Assert.Equal("Work/config kopya.json", store.Duplicate("Work/config.json"));
    }

    [Fact]
    public void DuplicateCopiesFolders()
    {
        Put("Dir/m.md", "b");
        Assert.Equal("Dir copy", store.Duplicate("Dir"));
        Assert.Equal("b", store.Read("Dir copy/m.md"));
    }

    private string Outside()
    {
        var outside = Path.Combine(temp.Path, "Outside-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(outside);
        return outside;
    }

    [Fact]
    public void CopyInFileAndFolder()
    {
        var outside = Outside();
        Directory.CreateDirectory(Path.Combine(outside, "Dir"));
        File.WriteAllText(Path.Combine(outside, "n.md"), "a");
        File.WriteAllText(Path.Combine(outside, "Dir", "m.md"), "b");
        Put("n.md", "mine");
        Assert.Equal("n 2.md", store.CopyIn(Path.Combine(outside, "n.md"), null));
        Assert.Equal("mine", store.Read("n.md"));
        Assert.Equal("Dir", store.CopyIn(Path.Combine(outside, "Dir"), null));
        Assert.Equal("Dir 2", store.CopyIn(Path.Combine(outside, "Dir"), null));
        Assert.Equal("b", store.Read("Dir 2/m.md"));
        Assert.True(File.Exists(Path.Combine(outside, "n.md")));
    }

    [Fact]
    public void CopyInAndDuplicateMakeNamesPortable()
    {
        var outside = Outside();
        var longName = new string('a', 240) + ".md";
        // "con.md" can only be created through the extended prefix; "a:b.md" can't exist on Windows at all.
        File.WriteAllText(@"\\?\" + Path.Combine(outside, "con.md"), "x");
        foreach (var name in new[] { "Cafe\u0301.md", longName }) File.WriteAllText(Path.Combine(outside, name), "x");
        Assert.Equal("con_.md", store.CopyIn(@"\\?\" + Path.Combine(outside, "con.md"), null));
        Assert.Equal("Caf\u00E9.md", store.CopyIn(Path.Combine(outside, "Cafe\u0301.md"), null));
        var copied = store.CopyIn(Path.Combine(outside, longName), null);
        Assert.True(Encoding.UTF8.GetByteCount(copied) <= 200);
        Assert.EndsWith(".md", copied);
        Put("Plan .md", "q");
        Assert.Equal("Plan copy.md", store.Duplicate("Plan .md"));
    }

    [Fact]
    public void PortableNameRules()
    {
        Assert.Equal("a-b-c--", NoteStore.PortableName(" ..a/b\u0001c*?. "));
        Assert.Equal("", NoteStore.PortableName("..."));
        Assert.True(Encoding.UTF8.GetByteCount(NoteStore.PortableName(string.Concat(Enumerable.Repeat("🙂", 100)))) <= 200);
        Assert.Equal("abc", NoteStore.PortableName("abcdef", maxCharacters: 3));
        Assert.Equal("NUL_.txt", NoteStore.PortableFileName("NUL.txt", isFolder: false));
        Assert.Equal("v1.2", NoteStore.PortableFileName("v1.2", isFolder: true));
        Assert.Equal("---.md", NoteStore.PortableFileName("???.md", isFolder: false));
        Assert.Equal("con_.md", NoteStore.PortableFileName("con.md", isFolder: false));
        Assert.Equal("a-b.md", NoteStore.PortableFileName("a:b.md", isFolder: false));
        Assert.Equal("Caf\u00E9.md", NoteStore.PortableFileName("Cafe\u0301.md", isFolder: false));
        Assert.Equal("item.md", NoteStore.PortableFileName("...md", isFolder: false));
    }

    [Fact]
    public void PortableNamesCutAtClusterBoundaries()
    {
        // A ZWJ family emoji is 18 UTF-8 bytes; the cut never splits it.
        var name = NoteStore.PortableName(string.Concat(Enumerable.Repeat("👨‍👩‍👧", 20)));
        Assert.True(Encoding.UTF8.GetByteCount(name) <= 200);
        Assert.Equal(0, name.Length % "👨‍👩‍👧".Length);
        var file = NoteStore.PortableFileName(new string('ş', 150) + ".md", isFolder: false);
        Assert.True(Encoding.UTF8.GetByteCount(file) <= 200);
        Assert.EndsWith(".md", file);
    }

    [Fact]
    public void CopyInRejectsHiddenAndOwnAncestor()
    {
        Put("Parent/Child/x.md");
        Assert.Throws<NoteStoreException>(() => store.CopyIn(Path.Combine(root, "Parent"), "Parent/Child"));
        var hidden = Path.Combine(root, ".hidden.md");
        File.WriteAllBytes(hidden, []);
        Assert.Throws<NoteStoreException>(() => store.CopyIn(hidden, "Parent"));
    }

    [Fact]
    public void UniqueItemNameCountsFromTheMarker()
    {
        Put("Plan.md");
        Put("Plan copy.md");
        Assert.Equal("Plan copy 2.md", NoteStore.UniqueItemName("Plan.md", false, "copy", root));
        Assert.Equal("Plan 2.md", NoteStore.UniqueItemName("Plan.md", false, null, root));
        Assert.Equal("Fresh.md", NoteStore.UniqueItemName("Fresh.md", false, null, root));
    }

    [Fact]
    public void TreeCarriesModificationDates()
    {
        Put("a.md");
        Put("Work/b.md");
        var tree = store.Tree();
        Assert.Null(tree[0].Modified);
        Assert.NotNull(tree[1].Modified);
    }
}
