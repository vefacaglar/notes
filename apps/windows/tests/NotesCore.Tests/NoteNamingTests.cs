using System.Diagnostics;
using NotesCore;

namespace NotesCore.Tests;

public class NoteNamingTests
{
    [Theory]
    [InlineData("Alışveriş listesi", "Alışveriş listesi")]
    [InlineData("\n\n   \n  İlk satır  \nikinci", "İlk satır")]
    [InlineData("# Başlık\ngövde", "Başlık")]
    [InlineData("###   Üç   ###", "Üç")]
    [InlineData("## **Kalın** ve *eğik* başlık", "Kalın ve eğik başlık")]
    [InlineData("**Yarım kalan", "Yarım kalan")]
    [InlineData("> - [ ] Süt al", "Süt al")]
    [InlineData("- [x] Bitti", "Bitti")]
    [InlineData("1. Giriş", "Giriş")]
    [InlineData("[Bağlantı](https://example.com) metni", "Bağlantı metni")]
    [InlineData("`kod` parçası", "kod parçası")]
    [InlineData("~~eski~~ yeni", "eski yeni")]
    [InlineData("Toplantı: 3/4 \"önemli\"", "Toplantı- 3-4 'önemli'")]
    [InlineData("Ne yapmalı?", "Ne yapmalı")]
    [InlineData("a\\b|c<d>e", "a-b-c-d-e")]
    [InlineData("Sekme\tile\u0007ayrılmış", "Sekme ile ayrılmış")]
    [InlineData("...gizli değil...", "gizli değil")]
    [InlineData("Bitiyor . . .", "Bitiyor")]
    [InlineData("çok    boşluklu   satır", "çok boşluklu satır")]
    [InlineData("🎉 Parti 👨\u200D👩\u200D👧", "🎉 Parti 👨\u200D👩\u200D👧")]
    [InlineData("#etiket", "#etiket")]
    [InlineData("Windows satırı\r\nikinci", "Windows satırı")]
    public void Title(string content, string expected) => Assert.Equal(expected, NoteStore.Title(content));

    [Theory]
    [InlineData("")]
    [InlineData("   \n\t\n")]
    [InlineData("# ")]
    [InlineData("#")]
    [InlineData("## ##")]
    [InlineData("- [ ] ")]
    [InlineData("> ")]
    [InlineData("---")]
    [InlineData("***")]
    [InlineData("```swift\nkod\n```")]
    [InlineData("???")]
    [InlineData("//")]
    [InlineData("**")]
    public void NoTitle(string content) => Assert.Null(NoteStore.Title(content));

    [Fact]
    public void TitleIsNormalizedToNFC() =>
        Assert.Equal(6, NoteStore.Title("Gu\u0308nlu\u0308k")!.EnumerateRunes().Count());

    [Fact]
    public void LongTitlesAreCappedOnGraphemeBoundaries()
    {
        var words = string.Concat(Enumerable.Repeat("kelime ", 20));
        var title = NoteStore.Title(words)!;
        Assert.True(NoteStore.Clusters(title).Count <= NoteStore.MaxTitleLength);
        Assert.False(title.EndsWith(' '));
        Assert.StartsWith(title, words);
        Assert.EndsWith("kelime", title);

        const string family = "👨\u200D👩\u200D👧\u200D👦";
        var capped = NoteStore.Title(string.Concat(Enumerable.Repeat(family, 80)))!;
        Assert.True(System.Text.Encoding.UTF8.GetByteCount(capped) <= NoteStore.MaxTitleBytes);
        Assert.All(NoteStore.Clusters(capped), cluster => Assert.Equal(family, cluster));

        var turkish = NoteStore.Title(new string('ş', 100))!;
        Assert.Equal(NoteStore.MaxTitleLength, NoteStore.Clusters(turkish).Count);
    }

    [Fact]
    public void TitlesAreValidNames()
    {
        string[] contents =
        [
            "a/b", ".x.", "x :", "\"q\"", "🎉 👨\u200D👩\u200D👧", new string('ğ', 90),
            ".\u0301Gizli not", "w/🏻 notu", "a/\u200Db", "x.\u0301", "a\u2028b", "\u00A0.x\u3000",
            "CON", "nul.txt", "Lpt9 ", "com1.tar.gz",
        ];
        foreach (var content in contents)
        {
            var title = NoteStore.Title(content);
            Assert.True(title is not null, $"no title for {content}");
            Assert.True(NoteStore.IsValidName(title + ".md"), $"{content} → {title}");
            Assert.True(NoteStore.IsValidName(title), $"{content} → {title}");
        }
    }

    /// <summary>A "/" or "." that carries a combining mark, ZWJ or emoji modifier is one cluster but still a separator or a dot.</summary>
    [Theory]
    [InlineData(".\u0301Gizli not", "Gizli not")]
    [InlineData("w/🏻 notu", "w-🏻 notu")]
    [InlineData("a/\u200Db", "a-\u200Db")]
    [InlineData("...\u0301x", "x")]
    public void SeparatorsAndDotsAreFoundPerScalar(string content, string expected)
    {
        var title = NoteStore.Title(content)!;
        Assert.Equal(expected, title);
        Assert.DoesNotContain('/', title);
    }

    [Fact]
    public void AutoNamedNoteNeverLeavesItsFolder()
    {
        using var temp = new NotesTempFolder();
        var store = new NoteStore(temp.Path);
        store.CreateFolder("w");
        var path = store.CreateNote("Adsız");
        var title = NoteStore.Title("w/🏻 notu")!;
        var newPath = store.Rename(path, store.UniqueNoteName(title, null, path) + ".md");
        Assert.Empty(NoteStore.Parent(newPath));
        Assert.Contains("w-🏻 notu", store.Tree().Select(n => n.Name));
    }

    [Theory]
    [InlineData("CON", "CON_")]
    [InlineData("nul", "nul_")]
    [InlineData("Aux.txt", "Aux_.txt")]
    [InlineData("COM1 .x", "COM1_ .x")]
    [InlineData("LPT10", "LPT10")]
    [InlineData("Console", "Console")]
    [InlineData("PRN.", "PRN_")]
    public void ReservedNamesGetASuffix(string content, string expected) => Assert.Equal(expected, NoteStore.Title(content));

    [Fact]
    public void TypedReservedNamesAreRejected()
    {
        foreach (var name in new[] { "CON", "con.md", "Nul.txt", "COM9", "lpt1 .md" }) Assert.False(NoteStore.IsValidName(name), name);
        foreach (var name in new[] { "CONSOLE", "COM10", "NULL.md", "x.CON" }) Assert.True(NoteStore.IsValidName(name), name);
    }

    [Fact]
    public void ReservedNamesIgnoreTheCurrentCulture()
    {
        var previous = System.Globalization.CultureInfo.CurrentCulture;
        try
        {
            System.Globalization.CultureInfo.CurrentCulture = new System.Globalization.CultureInfo("tr-TR");
            Assert.False(NoteStore.IsValidName("con.md"));
            Assert.False(NoteStore.IsValidName("LPT1"));
            Assert.Equal("Adsız", NoteStore.UntitledName);
        }
        finally { System.Globalization.CultureInfo.CurrentCulture = previous; }
    }

    [Fact]
    public void LinesEndAtLineFeedOnly()
    {
        // A lone CR or U+2028 is not a line break; a CR before LF is dropped.
        Assert.Equal("bir iki", NoteStore.Title("bir\riki\nüç"));
        Assert.Equal("bir iki", NoteStore.Title("bir\u2028iki"));
        Assert.Equal("İlk", NoteStore.Title("\r\n \r\n\u00A0\nİlk\r\n"));
        Assert.Null(NoteStore.AutoName("Eski", "\u00A0\u3000\nYeni"));
        Assert.Equal("Yeni", NoteStore.AutoName("Eski", "Yeni\r\ngövde"));
    }

    [Fact]
    public void TitleIsNormalizedAfterMapping() =>
        // NFC is applied to the mapped text, so a decomposed ğ next to a mapped "/" still composes.
        Assert.Equal("ğ-x", NoteStore.Title("g\u0306/x"));

    [Fact]
    public void TitleOfAHugeNoteOnlyReadsItsFirstLine()
    {
        var note = "# Başlık\n" + string.Concat(Enumerable.Repeat("uzun bir satır daha 😀\n", 300_000));
        NoteStore.Title("# ısınma\nx"); // JIT warm-up
        var clock = Stopwatch.StartNew();
        var title = NoteStore.Title(note);
        _ = NoteStore.AutoName("Başlık", note);
        clock.Stop();
        Assert.Equal("Başlık", title);
        Assert.True(clock.ElapsedMilliseconds < 100, $"took {clock.ElapsedMilliseconds} ms");
    }

    [Theory]
    [InlineData("Adsız", "Adsız")]
    [InlineData("Adsız 2", "Adsız")]
    [InlineData("Adsız 12", "Adsız")]
    [InlineData("Plan 2026", "Plan")]
    [InlineData("Adsız 1", "Adsız 1")]
    [InlineData("Adsız 02", "Adsız 02")]
    [InlineData("Adsız 2a", "Adsız 2a")]
    [InlineData("Adsız -3", "Adsız -3")]
    [InlineData(" 2", " 2")]
    [InlineData("2", "2")]
    public void BaseName(string name, string expected) => Assert.Equal(expected, NoteStore.BaseName(name));

    [Fact]
    public void AutoNamedNotes()
    {
        Assert.True(NoteStore.IsAutoNamed("Adsız", ""));
        Assert.True(NoteStore.IsAutoNamed("Adsız 3", "# Bambaşka"));
        Assert.True(NoteStore.IsAutoNamed("Alışveriş", "# Alışveriş\n- süt"));
        Assert.True(NoteStore.IsAutoNamed("Alışveriş 2", "Alışveriş"));
        Assert.True(NoteStore.IsAutoNamed("Bölüm 2", "Bölüm 2"));
        Assert.False(NoteStore.IsAutoNamed("Elle verilmiş", "# Alışveriş"));
        Assert.False(NoteStore.IsAutoNamed("alışveriş", "Alışveriş"));
        Assert.False(NoteStore.IsAutoNamed("Toplantı", ""));
    }

    /// <summary>
    /// After a rename by hand the app decides again from the new name: a name that is not the title stops
    /// following the first line, while renaming a note to its own title keeps it auto-named.
    /// </summary>
    [Fact]
    public void RenameByHandDecidesAutoNamingAgain()
    {
        const string content = "Market listesi\n- süt";
        Assert.True(NoteStore.IsAutoNamed("Market listesi", content));
        Assert.False(NoteStore.IsAutoNamed("Alışveriş", content));
        Assert.True(NoteStore.IsAutoNamed("Adsız 4", content));
        Assert.Equal("Market listesi", NoteStore.AutoName("Alışveriş", content));
    }

    [Fact]
    public void AutoNameFollowsTheFirstLine()
    {
        Assert.Equal("Yeni başlık", NoteStore.AutoName("Adsız", "# Yeni başlık\n"));
        Assert.Equal("Yeni", NoteStore.AutoName("Eski", "Yeni"));
        Assert.Equal("Eski", NoteStore.AutoName("eski", "Eski"));
        Assert.Null(NoteStore.AutoName("Aynı", "# Aynı\nmetin"));
        Assert.Null(NoteStore.AutoName("Aynı 2", "Aynı"));
        Assert.Null(NoteStore.AutoName("Adsız 2", "Adsız"));
    }

    [Fact]
    public void AutoNameKeepsTheNameWhenTheFirstLineIsCleared()
    {
        Assert.Null(NoteStore.AutoName("Eski", ""));
        Assert.Null(NoteStore.AutoName("Eski", "\ngövde"));
        Assert.Null(NoteStore.AutoName("Eski", "   \ngövde"));
        Assert.Null(NoteStore.AutoName("Eski", "# "));
        Assert.Null(NoteStore.AutoName("Eski", "# \ngövde"));
    }
}

public sealed class UniqueNoteNameTests : IDisposable
{
    private readonly NotesTempFolder temp = new();
    private readonly NoteStore store;

    public UniqueNoteNameTests() => store = new NoteStore(temp.Path);

    public void Dispose() => temp.Dispose();

    [Fact]
    public void PicksTheFirstFreeSuffix()
    {
        Assert.Equal("Adsız", store.UniqueNoteName("Adsız", null));
        store.CreateNote("Adsız");
        Assert.Equal("Adsız 2", store.UniqueNoteName("Adsız", null));
        store.CreateNote("Adsız 2");
        store.CreateNote("Adsız 4");
        Assert.Equal("Adsız 3", store.UniqueNoteName("Adsız", null));
        Assert.Equal("Adsız 3", store.UniqueNoteName("Adsız", ""));
    }

    [Fact]
    public void IsPerFolderAndIgnoresCase()
    {
        store.CreateNote("Plan", "İş");
        Assert.Equal("Plan", store.UniqueNoteName("Plan", null));
        Assert.Equal("plan 2", store.UniqueNoteName("plan", "İş"));
        Assert.Equal("Plan", store.UniqueNoteName("Plan", "Yok"));
    }

    [Fact]
    public void FolderWithTheNoteFileNameCountsAsTaken()
    {
        store.CreateFolder("Notlar.md");
        Assert.Equal("Notlar 2", store.UniqueNoteName("Notlar", null));
    }

    [Fact]
    public void IgnoringTheNoteItselfAllowsKeepingOrRecasingItsName()
    {
        var path = store.CreateNote("fikir");
        Assert.Equal("Fikir", store.UniqueNoteName("Fikir", null, path));
        Assert.Equal("Fikir 2", store.UniqueNoteName("Fikir", null));
        var renamed = store.Rename(path, store.UniqueNoteName("Fikir", null, path) + ".md");
        Assert.Equal("Fikir.md", renamed);
        Assert.Equal(["Fikir.md"], store.NotePaths());
    }

    [Fact]
    public void EmojiAndTurkishNamesRoundTrip()
    {
        var name = NoteStore.Title("# 🎉 Doğum günü 👨\u200D👩\u200D👧")!;
        var path = store.CreateNote(store.UniqueNoteName(name, null));
        Assert.Equal("🎉 Doğum günü 👨\u200D👩\u200D👧.md", path);
        Assert.Equal("🎉 Doğum günü 👨\u200D👩\u200D👧 2", store.UniqueNoteName(name, null));
    }
}

public class ConflictCopyNameTests
{
    [Fact]
    public void AppendsTheMarkerBeforeTheExtension()
    {
        Assert.Equal("Toplantı (çakışma).md", NoteStore.ConflictCopyName("Toplantı.md", _ => false));
        Assert.Equal("config (çakışma).json", NoteStore.ConflictCopyName("config.json", _ => false));
        Assert.Equal("Makefile (çakışma)", NoteStore.ConflictCopyName("Makefile", _ => false));
        Assert.Equal("e\u0301 (çakışma).md", NoteStore.ConflictCopyName("e\u0301.md", _ => false));
    }

    [Fact]
    public void PicksTheFirstFreeNumber()
    {
        var existing = new HashSet<string> { "Not (çakışma).md", "Not (çakışma 2).md" };
        Assert.Equal("Not (çakışma 3).md", NoteStore.ConflictCopyName("Not.md", existing.Contains));
    }

    [Fact]
    public void PathIsNextToTheFileAndUnused()
    {
        using var temp = new NotesTempFolder();
        var file = Path.Combine(temp.Path, "a.md");
        File.WriteAllBytes(file, []);
        File.WriteAllBytes(Path.Combine(temp.Path, "a (çakışma).md"), []);
        Assert.Equal(Path.Combine(temp.Path, "a (çakışma 2).md"), NoteStore.ConflictCopyPath(file));
    }

    [Fact]
    public void AutoNamingComparesAfterNfc()
    {
        var nfd = "C\u0327ay";
        Assert.True(NoteStore.IsAutoNamed(nfd, "Çay"));
        Assert.True(NoteStore.IsAutoNamed(nfd + " 2", "Çay"));
        Assert.True(NoteStore.IsAutoNamed("Çay", "C\u0327ay"));
        Assert.Null(NoteStore.AutoName(nfd, "Çay"));
        Assert.Null(NoteStore.AutoName(nfd + " 3", "Çay"));
        Assert.Equal("Çay", NoteStore.AutoName("Adsız", "Çay"));
    }
}
