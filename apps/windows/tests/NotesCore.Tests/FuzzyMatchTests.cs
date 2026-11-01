namespace NotesCore.Tests;

public sealed class FuzzyMatchTests
{
    private static List<string> Rank(string query, params (string Name, string Path)[] items)
    {
        var candidates = items.Select(i => new FuzzyMatch.Candidate(i.Name, i.Path)).ToList();
        return FuzzyMatch.Rank(query, candidates).Select(index => items[index].Path).ToList();
    }

    [Fact]
    public void SubsequenceMatches()
    {
        var items = new[] { ("Meeting notes", "Meeting notes.md"), ("Shopping", "Shopping.md") };
        Assert.Equal(["Meeting notes.md"], Rank("mtgn", items));
        Assert.Empty(Rank("zzz", items));
    }

    [Fact]
    public void OrderMatters() => Assert.Empty(Rank("ba", ("ab", "ab.md")));

    [Fact]
    public void EmptyQueryKeepsGivenOrder() => Assert.Equal(["b.md", "a.md"], Rank("  ", ("b", "b.md"), ("a", "a.md")));

    [Fact]
    public void PrefixAndConsecutiveBeatScattered()
    {
        var items = new[] { ("Big red apple", "x/Big red apple.md"), ("Apple pie", "Apple pie.md"), ("Pineapple", "Pineapple.md") };
        Assert.Equal(["Apple pie.md", "x/Big red apple.md", "Pineapple.md"], Rank("apple", items));
    }

    [Fact]
    public void TurkishAndDiacriticsFold()
    {
        var items = new[] { ("Toplantı Notları", "Toplantı Notları.md"), ("Işık", "Işık.md") };
        Assert.Equal(["Toplantı Notları.md"], Rank("toplanti", items));
        Assert.Equal(["Toplantı Notları.md"], Rank("TOPLANTI", items));
        Assert.Equal(["Işık.md"], Rank("isik", items));
        Assert.Equal(["Işık.md"], Rank("İşık", items));
        Assert.Equal(["Café.md"], Rank("cafe", ("Café", "Café.md")));
    }

    [Fact]
    public void EmojiNamesDoNotCrash() => Assert.Equal(["🙂a🙂b.md"], Rank("ab", ("🙂a🙂b", "🙂a🙂b.md")));

    [Fact]
    public void NameMatchBeatsPathOnlyMatch()
    {
        var items = new[] { ("Plan", "Work/Plan.md"), ("Other", "Work/Other.md") };
        Assert.Equal(["Work/Plan.md", "Work/Other.md"], Rank("work", items));
        Assert.Equal(["Work/Plan.md"], Rank("pl", items));
        var both = new[] { ("x", "work/x.md"), ("Notes work", "A/Notes work.md") };
        Assert.Equal("A/Notes work.md", Rank("work", both)[0]);
    }

    [Fact]
    public void LimitApplies()
    {
        var candidates = Enumerable.Range(0, 10).Select(i => new FuzzyMatch.Candidate($"n{i}", $"n{i}.md")).ToList();
        Assert.Equal(3, FuzzyMatch.Rank("n", candidates, limit: 3).Count);
    }
}
