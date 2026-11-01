using System.Diagnostics;
using NotesCore;

namespace NotesCore.Tests;

public class MarkdownStylerTests
{
    private static readonly MarkdownSpanKind Marker = MarkdownSpanKind.Marker;

    /// <summary>Spans rendered as (text, kind) so expectations stay readable.</summary>
    private static List<(string Text, MarkdownSpanKind Kind)> Styled(string text) =>
        MarkdownStyler.Spans(text).Select(s => (text.Substring(s.Range.Location, s.Range.Length), s.Kind)).ToList();

    private static void ExpectStyled(string text, params (string, MarkdownSpanKind)[] expected)
    {
        var actual = Styled(text);
        Assert.Equal(expected.Select(e => e.Item1).ToList(), actual.Select(a => a.Text).ToList());
        Assert.Equal(expected.Select(e => e.Item2).ToList(), actual.Select(a => a.Kind).ToList());
    }

    [Fact]
    public void Headings()
    {
        ExpectStyled("# Başlık", ("# Başlık", MarkdownSpanKind.Heading(1)), ("# ", Marker));
        ExpectStyled("###### Altı ##",
            ("###### Altı ##", MarkdownSpanKind.Heading(6)), ("###### ", Marker), ("##", Marker));
        ExpectStyled("## **Kalın** başlık",
            ("## **Kalın** başlık", MarkdownSpanKind.Heading(2)), ("## ", Marker),
            ("**", Marker), ("Kalın", MarkdownSpanKind.Bold), ("**", Marker));
        ExpectStyled("####### yedi");
        ExpectStyled("#etiket");
        ExpectStyled("# C#", ("# C#", MarkdownSpanKind.Heading(1)), ("# ", Marker));
    }

    [Fact]
    public void Emphasis()
    {
        ExpectStyled("a **b** c", ("**", Marker), ("b", MarkdownSpanKind.Bold), ("**", Marker));
        ExpectStyled("__b__", ("__", Marker), ("b", MarkdownSpanKind.Bold), ("__", Marker));
        ExpectStyled("*i* _j_",
            ("*", Marker), ("i", MarkdownSpanKind.Italic), ("*", Marker),
            ("_", Marker), ("j", MarkdownSpanKind.Italic), ("_", Marker));
        ExpectStyled("***bi***", ("***", Marker), ("bi", MarkdownSpanKind.BoldItalic), ("***", Marker));
        ExpectStyled("**a *b* c**",
            ("**", Marker), ("a *b* c", MarkdownSpanKind.Bold), ("*", Marker), ("b", MarkdownSpanKind.Italic),
            ("*", Marker), ("**", Marker));
        ExpectStyled("~~sil~~ ~tek~", ("~~", Marker), ("sil", MarkdownSpanKind.Strikethrough), ("~~", Marker));
        ExpectStyled("**Ankara**'da", ("**", Marker), ("Ankara", MarkdownSpanKind.Bold), ("**", Marker));
    }

    [Fact]
    public void IntrawordAndUnmatchedDelimitersStayPlain()
    {
        ExpectStyled("a*b*c");
        ExpectStyled("snake_case_name");
        ExpectStyled("2 * 3 * 4");
        ExpectStyled("**açık");
        ExpectStyled("\\*kaçış\\*", ("\\", Marker), ("\\", Marker));
    }

    [Fact]
    public void InlineStylingNeverCrossesLines()
    {
        ExpectStyled("**a\nb**");
        ExpectStyled("`a\nb`");
        ExpectStyled("[a\n](b)");
    }

    [Fact]
    public void InlineCodeHidesOtherSyntax()
    {
        ExpectStyled("x `**y**` z", ("`", Marker), ("**y**", MarkdownSpanKind.InlineCode), ("`", Marker));
        ExpectStyled("``a ` b``", ("``", Marker), ("a ` b", MarkdownSpanKind.InlineCode), ("``", Marker));
    }

    [Fact]
    public void FencedCodeBlocks()
    {
        ExpectStyled("önce\n```swift\nlet **x** = 1\n```\n# sonra",
            ("```swift\nlet **x** = 1\n```", MarkdownSpanKind.CodeBlock), ("```swift", Marker), ("```", Marker),
            ("# sonra", MarkdownSpanKind.Heading(1)), ("# ", Marker));
        ExpectStyled("~~~\n```\n~~~", ("~~~\n```\n~~~", MarkdownSpanKind.CodeBlock), ("~~~", Marker), ("~~~", Marker));
        ExpectStyled("```\nkapanmamış\n# değil", ("```\nkapanmamış\n# değil", MarkdownSpanKind.CodeBlock), ("```", Marker));
        ExpectStyled("``` a`b");
    }

    [Fact]
    public void BlockquotesAndLists()
    {
        ExpectStyled("> alıntı *x*",
            ("> alıntı *x*", MarkdownSpanKind.Blockquote), ("> ", Marker), ("*", Marker),
            ("x", MarkdownSpanKind.Italic), ("*", Marker));
        ExpectStyled("- madde", ("-", MarkdownSpanKind.ListMarker));
        ExpectStyled("  12. on iki", ("12.", MarkdownSpanKind.ListMarker));
        ExpectStyled("-yok");
        ExpectStyled("> - iç", ("> - iç", MarkdownSpanKind.Blockquote), ("> ", Marker), ("-", MarkdownSpanKind.ListMarker));
    }

    [Fact]
    public void Tasks()
    {
        ExpectStyled("- [ ] yapılacak",
            ("-", MarkdownSpanKind.ListMarker), ("[ ]", MarkdownSpanKind.TaskMarker(false)),
            ("yapılacak", MarkdownSpanKind.Task(false)));
        ExpectStyled("* [x] bitti **çok**",
            ("*", MarkdownSpanKind.ListMarker), ("[x]", MarkdownSpanKind.TaskMarker(true)),
            ("bitti **çok**", MarkdownSpanKind.Task(true)),
            ("**", Marker), ("çok", MarkdownSpanKind.Bold), ("**", Marker));
        ExpectStyled("- [y] değil", ("-", MarkdownSpanKind.ListMarker));
    }

    [Fact]
    public void WikiLinks()
    {
        var wiki = MarkdownSpanKind.WikiLink;
        ExpectStyled("bkz [[Alışveriş]] ve", ("[[", Marker), ("Alışveriş", wiki("Alışveriş")), ("]]", Marker));
        ExpectStyled("[[Not#Başlık]]", ("[[", Marker), ("Not#Başlık", wiki("Not")), ("]]", Marker));
        ExpectStyled("[[Not|takma ad]] 😀 [[İki]]",
            ("[[", Marker), ("Not|takma ad", wiki("Not")), ("]]", Marker),
            ("[[", Marker), ("İki", wiki("İki")), ("]]", Marker));
        ExpectStyled("[[]]");
        ExpectStyled("[[ ]]");
        ExpectStyled("[[a [b]]");
        ExpectStyled("[[açık");
        ExpectStyled("`[[kod]]`", ("`", Marker), ("[[kod]]", MarkdownSpanKind.InlineCode), ("`", Marker));
    }

    [Fact]
    public void Links()
    {
        ExpectStyled("bak [Şu sayfa](https://ex.com/a_(b)) tamam",
            ("[", Marker), ("Şu sayfa", MarkdownSpanKind.Link("https://ex.com/a_(b)")),
            ("](https://ex.com/a_(b))", Marker));
        ExpectStyled("![resim](a.png \"başlık\")",
            ("![", Marker), ("resim", MarkdownSpanKind.Link("a.png")), ("](a.png \"başlık\")", Marker));
        ExpectStyled("[yalnız köşeli]");
        ExpectStyled("<https://ex.com>",
            ("<", Marker), ("https://ex.com", MarkdownSpanKind.Link("https://ex.com")), (">", Marker));
        ExpectStyled("Bkz. https://ex.com/ara?q=ı, sonra",
            ("https://ex.com/ara?q=ı", MarkdownSpanKind.Link("https://ex.com/ara?q=ı")));
        ExpectStyled("(http://ex.com/x_y)", ("http://ex.com/x_y", MarkdownSpanKind.Link("http://ex.com/x_y")));
        ExpectStyled("xhttps://ex.com");
    }

    [Fact]
    public void HorizontalRules()
    {
        ExpectStyled("---", ("---", MarkdownSpanKind.HorizontalRule));
        ExpectStyled("* * *", ("* * *", MarkdownSpanKind.HorizontalRule));
        ExpectStyled("--");
    }

    [Fact]
    public void RangesAreUTF16AndSurviveCRLF()
    {
        var text = "😀🇹🇷 **ğüşİ** 👍🏽\r\n## Çay ☕️";
        var spans = MarkdownStyler.Spans(text);
        Assert.Equal(new[] { "**", "ğüşİ", "**", "## Çay ☕️", "## " },
            spans.Select(s => text.Substring(s.Range.Location, s.Range.Length)).ToArray());
        Assert.Equal(new MarkdownRange(9, 4), spans[1].Range);
    }

    [Fact]
    public void SpansAreSortedOuterFirst()
    {
        var text = "> # a **b** [c](d)\n```\nx\n```\n- [ ] *e* `f`";
        var spans = MarkdownStyler.Spans(text);
        foreach (var (a, b) in spans.Zip(spans.Skip(1)))
        {
            Assert.True(a.Range.Location < b.Range.Location
                || (a.Range.Location == b.Range.Location && a.Range.Length >= b.Range.Length));
        }
    }

    [Fact]
    public void RestyleAfterReturnInsideAHeadingIncludesTheSplitOffLine()
    {
        var text = "# Başlık devam\nsonraki\nüçüncü";
        // Return after "Başlık": the inserted "\n" is at UTF-16 offset 8.
        var edited = text.Insert(8, "\n");
        var range = MarkdownStyler.RestyleRange(new MarkdownRange(8, 1), edited);
        Assert.Equal("# Başlık\n devam\n", edited.Substring(range.Location, range.Length));
    }

    [Fact]
    public void RestyleRangeAtTheEdges()
    {
        Assert.Equal(new MarkdownRange(0, 0), MarkdownStyler.RestyleRange(new MarkdownRange(0, 0), ""));
        Assert.Equal(new MarkdownRange(0, 3), MarkdownStyler.RestyleRange(new MarkdownRange(3, 0), "abc"));
        // A deletion inside a line restyles that line only.
        Assert.Equal(new MarkdownRange(0, 6), MarkdownStyler.RestyleRange(new MarkdownRange(3, 0), "# aüb\nc"));
        // Deleting the line break between two lines restyles the merged line.
        Assert.Equal(new MarkdownRange(0, 7), MarkdownStyler.RestyleRange(new MarkdownRange(5, 0), "# aübc\nd"));
    }

    /// <summary>Simulates keystrokes without fences: outside the restyle range, every character keeps exactly the spans it had.</summary>
    [Fact]
    public void RestyleRangeCoversEveryRestyledCharacter()
    {
        string[] samples =
        [
            "# Başlık **kalın** ve *eğik*\n- [ ] görev `kod`\n> alıntı [b](https://ex.com) 😀\nDüz ~~sil~~ metin\n",
            "## İki\r\n1. bir\r\n2) iki **x**\r\n\r\n***\r\nson",
        ];
        string[] inserts = ["\n", "#", "# ", "*", "**", "~~", "`", "[", "](u)", "> ", "- ", "x", " ", "😀", "\r\n"];
        var rng = new Random(20260101);
        foreach (var sample in samples)
        {
            var oldKinds = Kinds(sample);
            for (int n = 0; n < 400; n++)
            {
                int start = rng.Next(0, sample.Length + 1);
                int removed = rng.Next(0, Math.Min(3, sample.Length - start) + 1);
                var inserted = rng.Next(2) == 0 ? inserts[rng.Next(inserts.Length)] : "";
                var newText = sample.Remove(start, removed).Insert(start, inserted);
                int delta = inserted.Length - removed;
                var range = MarkdownStyler.RestyleRange(new MarkdownRange(start, inserted.Length), newText);

                var newKinds = Kinds(newText);
                for (int x = 0; x < newKinds.Length; x++)
                {
                    if (range.Contains(x)) continue;
                    int before = x < start ? x : x - delta;
                    Assert.True(oldKinds[before].SetEquals(newKinds[x]), $"{newText} at {x}");
                }
            }
        }
    }

    private static HashSet<MarkdownSpanKind>[] Kinds(string text)
    {
        var result = Enumerable.Range(0, text.Length).Select(_ => new HashSet<MarkdownSpanKind>()).ToArray();
        foreach (var span in MarkdownStyler.Spans(text))
            for (int k = span.Range.Location; k < span.Range.End; k++) result[k].Add(span.Kind);
        return result;
    }

    [Fact]
    public void EmptyAndTrivialInput()
    {
        Assert.Empty(MarkdownStyler.Spans(""));
        Assert.Empty(MarkdownStyler.Spans("\n\n"));
        Assert.Empty(MarkdownStyler.Spans("düz metin"));
    }

    [Fact]
    public void LargeNoteIsFast()
    {
        const string block = """
            # Başlık **kalın** ve *eğik*
            - [ ] görev `kod` [bağlantı](https://ex.com) ~~sil~~
            > alıntı https://ex.com/yol, devam 😀
            ```
            let x = **1**
            ```
            Düz paragraf satırı a*b*c snake_case_name ve biraz daha metin.
            """;
        var text = string.Join("\n", Enumerable.Repeat(block.ReplaceLineEndings("\n"), 5_000 / 7));
        MarkdownStyler.Spans(text); // warm up the JIT
        var watch = Stopwatch.StartNew();
        int count = MarkdownStyler.Spans(text).Count;
        watch.Stop();
        Assert.True(count > 5_000);
        // Generous bound so debug builds pass too; release is far below this.
        Assert.True(watch.ElapsedMilliseconds < 500, $"took {watch.ElapsedMilliseconds} ms");
    }

    // Extra cases beyond the Swift suite: string units and line endings.

    [Fact]
    public void TurkishCharactersAreSingleUnitsAndDoNotBreakEmphasis()
    {
        var text = "ıİşŞğĞ **İstanbul'da** *ığdır*";
        var spans = MarkdownStyler.Spans(text);
        Assert.Equal(new[] { "**", "İstanbul'da", "**", "*", "ığdır", "*" },
            spans.Select(s => text.Substring(s.Range.Location, s.Range.Length)).ToArray());
        Assert.Equal(new MarkdownRange(7, 2), spans[0].Range);
        Assert.Equal(MarkdownSpanKind.Bold, spans[1].Kind);
        Assert.Equal(MarkdownSpanKind.Italic, spans[4].Kind);
        // Intraword Turkish letters never open or close emphasis.
        ExpectStyled("ış*ğ*ü");
        ExpectStyled("İ_ı_ş");
    }

    [Fact]
    public void ZwjEmojiAndFlagsCountAsUtf16Units()
    {
        // Family emoji: 3 scalars joined by 2 ZWJ = 8 UTF-16 units; flag = 2 regional indicators = 4 units.
        var family = "👨‍👩‍👧";
        Assert.Equal(8, family.Length);
        var text = $"{family} **kalın** 🇹🇷 *eğik*";
        var spans = MarkdownStyler.Spans(text);
        Assert.Equal(6, spans.Count);
        Assert.Equal(new MarkdownRange(9, 2), spans[0].Range);
        Assert.Equal(new MarkdownRange(11, 5), spans[1].Range);
        Assert.Equal("kalın", text.Substring(spans[1].Range.Location, spans[1].Range.Length));
        int flag = text.IndexOf("🇹🇷", StringComparison.Ordinal);
        Assert.Equal(new MarkdownRange(flag + 5, 1), spans[3].Range);
        Assert.Equal(MarkdownSpanKind.Italic, spans[4].Kind);
        Assert.Equal("eğik", text.Substring(spans[4].Range.Location, spans[4].Range.Length));
    }

    [Fact]
    public void EmojiNextToDelimitersCountsAsPunctuation()
    {
        // Surrogates are punctuation, so emphasis may open and close right next to an emoji.
        ExpectStyled("**😀**", ("**", Marker), ("😀", MarkdownSpanKind.Bold), ("**", Marker));
        ExpectStyled("a*😀*b"); // intraword next to a word letter stays plain
    }

    [Fact]
    public void CombiningMarksStayInsideSpans()
    {
        var text = "# Café **ş̧eker**\n- *ä́*";
        var spans = MarkdownStyler.Spans(text);
        var rendered = spans.Select(s => text.Substring(s.Range.Location, s.Range.Length)).ToArray();
        Assert.Equal(new[]
        {
            "# Café **ş̧eker**", "# ", "**", "ş̧eker", "**",
            "-", "*", "ä́", "*",
        }, rendered);
        // A combining mark right after a delimiter is an ordinary word unit, not punctuation.
        ExpectStyled("*́x*", ("*", Marker), ("́x", MarkdownSpanKind.Italic), ("*", Marker));
    }

    [Fact]
    public void CrlfLinesExcludeTheCarriageReturn()
    {
        var text = "# Başlık\r\n- [x] iş **bitti**\r\n> alıntı\r\n```\r\nkod\r\n```\r\n---\r\nson";
        var spans = MarkdownStyler.Spans(text);
        var rendered = spans.Select(s => text.Substring(s.Range.Location, s.Range.Length)).ToArray();
        Assert.Equal(new[]
        {
            "# Başlık", "# ",
            "-", "[x]", "iş **bitti**", "**", "bitti", "**",
            "> alıntı", "> ",
            "```\r\nkod\r\n```", "```", "```",
            "---",
        }, rendered);
        Assert.DoesNotContain(rendered, r => r.EndsWith('\r') && r.Length < 10 && !r.StartsWith("```"));
        Assert.Equal(MarkdownSpanKind.HorizontalRule, spans[^1].Kind);
    }

    [Fact]
    public void Tables()
    {
        var m = MarkdownSpanKind.TableMarker;
        const string table = "| Ad | **Şehir** |\n| :-- | --: |\n| 🎉 | `a|b` |";
        ExpectStyled(table,
            (table, MarkdownSpanKind.Table),
            ("| Ad | **Şehir** |", MarkdownSpanKind.TableHeader), ("|", m), ("|", m),
            ("**", Marker), ("Şehir", MarkdownSpanKind.Bold), ("**", Marker), ("|", m),
            ("| :-- | --: |", m),
            ("|", m), ("|", m),
            ("`", Marker), ("a|b", MarkdownSpanKind.InlineCode), ("`", Marker), ("|", m));
    }

    [Fact]
    public void NotATableWithoutDelimiterRow()
    {
        ExpectStyled("a | b\n---", ("---", MarkdownSpanKind.HorizontalRule));
    }

    [Fact]
    public void TableEdgeCases()
    {
        var text = "|a|b|\r\n|-|-|\r\n|1|2|\r\nnormal";
        var spans = MarkdownStyler.Spans(text);
        Assert.Equal(MarkdownSpanKind.Table, spans[0].Kind);
        Assert.Equal(new MarkdownRange(0, text.IndexOf("normal", StringComparison.Ordinal)), spans[0].Range);
        ExpectStyled("| a | b |\n| - |");
        ExpectStyled("    | a |\n    | - |");
        Assert.Equal(MarkdownSpanKind.Table, MarkdownStyler.Spans("| a |\n| - |")[0].Kind);
        Assert.Equal(MarkdownSpanKind.CodeBlock, MarkdownStyler.Spans("```\n| a |\n| - |\n```")[0].Kind);
    }

    [Fact]
    public void LoneCarriageReturnIsNotALineBreak()
    {
        // The scanner splits at LF only, so inline styling continues across a lone CR.
        var text = "**a\rb**";
        ExpectStyled(text, ("**", Marker), ("a\rb", MarkdownSpanKind.Bold), ("**", Marker));
        var range = MarkdownStyler.RestyleRange(new MarkdownRange(2, 0), "ab\rcd\nef");
        Assert.Equal(new MarkdownRange(0, 6), range);
    }

    [Fact]
    public void RestyleRangeWithCrlfAndClampedInput()
    {
        var text = "a\r\nb\r\nc";
        Assert.Equal(new MarkdownRange(0, 3), MarkdownStyler.RestyleRange(new MarkdownRange(1, 0), text));
        Assert.Equal(new MarkdownRange(3, 3), MarkdownStyler.RestyleRange(new MarkdownRange(3, 1), text));
        Assert.Equal(new MarkdownRange(6, 1), MarkdownStyler.RestyleRange(new MarkdownRange(6, 1), text));
        // Out-of-range input is clamped to the text.
        Assert.Equal(new MarkdownRange(6, 1), MarkdownStyler.RestyleRange(new MarkdownRange(50, 5), text));
    }
}
