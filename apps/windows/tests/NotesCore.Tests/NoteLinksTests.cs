namespace NotesCore.Tests;

public sealed class NoteLinksTests
{
    private static LinkDestination Web(string url) => new LinkDestination.Web(new Uri(url));
    private static LinkDestination File(string path) => new LinkDestination.File(path);
    private static LinkDestination Wiki(string name) => new LinkDestination.Wiki(name);

    [Fact]
    public void ClassifiesDestinations()
    {
        Assert.Equal(Web("https://example.com/a?b=1#c"), NoteLinks.Classify("https://example.com/a?b=1#c"));
        Assert.Equal(Web("mailto:a@b.co"), NoteLinks.Classify("mailto:a@b.co"));
        Assert.Equal(File("Planı.md"), NoteLinks.Classify("Plan%C4%B1.md"));
        Assert.Equal(File("../Gün lük/not.md"), NoteLinks.Classify("../Gün lük/not.md#başlık"));
        Assert.Equal(File("x.md"), NoteLinks.Classify("x.md?a=b"));
        Assert.Equal(File("/tmp/x.md"), NoteLinks.Classify("/tmp/x.md"));
        Assert.Equal(File("C:\\x.md"), NoteLinks.Classify("C:\\x.md"));
        Assert.Null(NoteLinks.Classify("#anchor"));
        Assert.Null(NoteLinks.Classify("  "));
        Assert.Equal(Wiki("Alışveriş Listesi"), NoteLinks.Classify("[[Alışveriş Listesi]]"));
        Assert.Equal(Wiki("Not"), NoteLinks.Classify("[[Not|takma ad]]"));
        Assert.Equal(Wiki("Not"), NoteLinks.Classify("[[Not#Başlık]]"));
        Assert.Null(NoteLinks.Classify("[[ ]]"));
    }

    [Fact]
    public void MalformedPercentEscapesKeepThePathAsWritten()
    {
        Assert.Equal(File("100%.md"), NoteLinks.Classify("100%.md"));
        Assert.Equal(File("%FF.md"), NoteLinks.Classify("%FF.md"));
    }

    private static readonly NoteRef[] Candidates =
    [
        new(0, "Work/Plan.md"),
        new(0, "Work/Sub/Plan.md"),
        new(0, "Ev/Alışveriş.md"),
        new(0, "config.json"),
        new(1, "Plan.md"),
        new(1, "Ev/Alışveriş.md"),
    ];

    private static NoteRef? Resolve(LinkDestination destination, NoteRef? origin) => NoteLinks.Resolve(destination, origin, Candidates);

    [Fact]
    public void ResolvesRelativeFiles()
    {
        var origin = new NoteRef(0, "Work/Sub/a.md");
        Assert.Equal(Candidates[1], Resolve(File("Plan.md"), origin));
        Assert.Equal(Candidates[0], Resolve(File("../Plan.md"), origin));
        Assert.Equal(Candidates[2], Resolve(File("../../Ev/alışveriş.md"), origin));
        Assert.Equal(Candidates[0], Resolve(File("../Plan"), origin));
        Assert.Equal(Candidates[3], Resolve(File("./../../config.json"), origin));
        Assert.Null(Resolve(File("../../../Plan.md"), origin));
        Assert.Null(Resolve(File("yok.md"), origin));
        Assert.Null(Resolve(File("Plan.md"), null));
        Assert.Null(Resolve(File("/Plan.md"), origin));
    }

    [Fact]
    public void RelativeFilesStayInTheirRoot()
    {
        var origin = new NoteRef(1, "Ev/a.md");
        Assert.Equal(Candidates[4], Resolve(File("../Plan.md"), origin));
        Assert.Equal(Candidates[5], Resolve(File("Alışveriş.md"), origin));
    }

    [Fact]
    public void WikiLinksIgnoreCaseAndPreferNearby()
    {
        var origin = new NoteRef(0, "Work/Sub/a.md");
        Assert.Equal(Candidates[1], Resolve(Wiki("plan"), origin));
        Assert.Equal(Candidates[0], Resolve(Wiki("PLAN"), new NoteRef(0, "Work/b.md")));
        // Same root before other roots, shorter path first.
        Assert.Equal(Candidates[0], Resolve(Wiki("plan"), new NoteRef(0, "Ev/c.md")));
        Assert.Equal(Candidates[4], Resolve(Wiki("plan"), new NoteRef(1, "x.md")));
        Assert.Equal(Candidates[2], Resolve(Wiki("ALIŞVERİŞ"), null));
        Assert.Equal(Candidates[2], Resolve(Wiki("Alışveriş.md"), origin));
        Assert.Equal(Candidates[5], Resolve(Wiki("ev/alışveriş"), new NoteRef(1, "x.md")));
        Assert.Equal(Candidates[3], Resolve(Wiki("config.json"), origin));
        Assert.Null(Resolve(Wiki("config"), origin));
        Assert.Null(Resolve(Wiki("yok"), origin));
    }

    [Fact]
    public void FoldsTurkishLetters()
    {
        Assert.Equal(NoteLinks.FoldedName("çalışma"), NoteLinks.FoldedName("ÇALIŞMA"));
        Assert.Equal(NoteLinks.FoldedName("istanbul"), NoteLinks.FoldedName("İstanbul"));
        Assert.Equal(NoteLinks.FoldedName("\u00E9"), NoteLinks.FoldedName("e\u0301"));
    }

    [Fact]
    public void DetectsRootEscapeAndPrograms()
    {
        var note = new NoteRef(0, "a/b/n.md");
        Assert.False(NoteLinks.EscapesRoot("../../x.md", note));
        Assert.True(NoteLinks.EscapesRoot("../../../x.md", note));
        Assert.False(NoteLinks.EscapesRoot("c/../../../x.md", note));
        Assert.True(NoteLinks.EscapesRoot("../../../../x.md", note));
        Assert.True(NoteLinks.EscapesRoot("../x.md", new NoteRef(0, "n.md")));
        Assert.True(NoteLinks.IsProgram("Setup.COMMAND"));
        Assert.True(NoteLinks.IsProgram("tool.ps1"));
        Assert.False(NoteLinks.IsProgram("notes.md"));
        Assert.False(NoteLinks.IsProgram("app"));
    }

    [Theory]
    [InlineData("setup.exe")]
    [InlineData("a.BAT")]
    [InlineData("a.cmd")]
    [InlineData("a.com")]
    [InlineData("a.msi")]
    [InlineData("a.lnk")]
    [InlineData("a.scr")]
    [InlineData("a.vbs")]
    [InlineData("a.js")]
    [InlineData("tool.url")]
    [InlineData("a.application")]
    [InlineData("a.settingcontent-ms")]
    [InlineData("a.chm")]
    [InlineData("tool.exe.")]
    [InlineData("tool.exe ")]
    public void WindowsProgramsAreRevealedNotRun(string fileName) => Assert.True(NoteLinks.IsProgram(fileName));

    [Fact]
    public void SchemeNeedsTwoCharactersLettersDigitsAndSigns()
    {
        Assert.Equal(Web("v2:notes.md"), NoteLinks.Classify("v2:notes.md"));
        Assert.Equal(File("C:\\x.md"), NoteLinks.Classify("C:\\x.md"));
        Assert.Equal(File("2a:x"), NoteLinks.Classify("2a:x"));
    }
}
