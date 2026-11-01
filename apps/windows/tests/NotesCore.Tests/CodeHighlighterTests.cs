using System.Diagnostics;
using K = NotesCore.CodeSpanKind;

namespace NotesCore.Tests;

public class CodeHighlighterTests
{
    private static List<(string Text, CodeSpanKind Kind)> Styled(string text, CodeLanguage language) =>
        CodeHighlighter.Spans(text, language).Select(s => (text.Substring(s.Location, s.Length), s.Kind)).ToList();

    private static void ExpectStyled(string text, CodeLanguage language, params (string, CodeSpanKind)[] expected)
    {
        var actual = Styled(text, language);
        Assert.Equal(expected.Select(e => e.Item1), actual.Select(a => a.Text));
        Assert.Equal(expected.Select(e => e.Item2), actual.Select(a => a.Kind));
    }

    [Theory]
    [InlineData("a.json", CodeLanguage.Json)]
    [InlineData("b.SWIFT", CodeLanguage.Swift)]
    [InlineData("c.tsx", CodeLanguage.JavaScript)]
    [InlineData("d.mjs", CodeLanguage.JavaScript)]
    [InlineData("e.py", CodeLanguage.Python)]
    [InlineData("f.zsh", CodeLanguage.Shell)]
    [InlineData("g.yml", CodeLanguage.Yaml)]
    [InlineData("h.plist", CodeLanguage.Xml)]
    [InlineData("i.svg", CodeLanguage.Xml)]
    [InlineData("j.css", CodeLanguage.Css)]
    [InlineData("k.rs", CodeLanguage.CFamily)]
    [InlineData("l.hpp", CodeLanguage.CFamily)]
    [InlineData("m.sql", CodeLanguage.Sql)]
    [InlineData("n.ini", CodeLanguage.Toml)]
    [InlineData("Klasör/o.md", CodeLanguage.Markdown)]
    [InlineData("x.mkd", CodeLanguage.Markdown)]
    [InlineData("gizli.MDENC", CodeLanguage.Markdown)]
    [InlineData("x.MDOWN", CodeLanguage.Markdown)]
    [InlineData("p.txt", CodeLanguage.PlainText)]
    [InlineData("Makefile", CodeLanguage.PlainText)]
    [InlineData("Not.Defteri/Makefile", CodeLanguage.PlainText)]
    [InlineData(".json", CodeLanguage.PlainText)]
    [InlineData("a.", CodeLanguage.PlainText)]
    [InlineData("İş/ı.JSON", CodeLanguage.Json)]
    public void DetectsLanguageFromExtension(string path, CodeLanguage language) =>
        Assert.Equal(language, CodeLanguages.FromPath(path));

    [Fact]
    public void ExtensionLookupIsCultureInvariant()
    {
        var saved = Thread.CurrentThread.CurrentCulture;
        try
        {
            Thread.CurrentThread.CurrentCulture = new System.Globalization.CultureInfo("tr-TR");
            Assert.Equal(CodeLanguage.Sql, CodeLanguages.FromFileExtension("SQL"));
            Assert.Equal(CodeLanguage.Xml, CodeLanguages.FromFileExtension("HTML"));
        }
        finally { Thread.CurrentThread.CurrentCulture = saved; }
        Assert.Contains("kts", CodeLanguages.FileExtensions);
        Assert.DoesNotContain("txt", CodeLanguages.FileExtensions);
    }

    [Fact]
    public void Json()
    {
        ExpectStyled("""{"ad": "Çağlar", "yaş": -3.5e+2, "ok": true, "x": null, "l": [1, "a\"b"]}""", CodeLanguage.Json,
            ("\"ad\"", K.Property), ("\"Çağlar\"", K.String), ("\"yaş\"", K.Property), ("-3.5e+2", K.Number),
            ("\"ok\"", K.Property), ("true", K.Literal), ("\"x\"", K.Property), ("null", K.Literal),
            ("\"l\"", K.Property), ("1", K.Number), ("\"a\\\"b\"", K.String));
        ExpectStyled("{\"a\"\n  : 1}", CodeLanguage.Json, ("\"a\"", K.String), ("1", K.Number));
    }

    [Fact]
    public void JsonWithCrlf()
    {
        ExpectStyled("{\r\n  \"a\" : 1, // yorum\r\n  \"b\": \"ş\"\r\n}", CodeLanguage.Json,
            ("\"a\"", K.Property), ("1", K.Number), ("// yorum\r", K.Comment), ("\"b\"", K.Property), ("\"ş\"", K.String));
    }

    [Fact]
    public void Swift()
    {
        ExpectStyled("@MainActor final class Not: View { let x = nil // yorum\n}", CodeLanguage.Swift,
            ("@MainActor", K.Keyword), ("final", K.Keyword), ("class", K.Keyword), ("Not", K.Type), ("View", K.Type),
            ("let", K.Keyword), ("nil", K.Literal), ("// yorum", K.Comment));
        ExpectStyled("/* a /* iç */ b */ x", CodeLanguage.Swift, ("/* a /* iç */ b */", K.Comment));
        ExpectStyled("let s = \"\"\"\nçok \"satır\"\n\"\"\"\n#if DEBUG", CodeLanguage.Swift,
            ("let", K.Keyword), ("\"\"\"\nçok \"satır\"\n\"\"\"", K.String), ("#if", K.Keyword));
        ExpectStyled("0..<10 x.0 1_000 0xFF", CodeLanguage.Swift,
            ("0", K.Number), ("10", K.Number), ("0", K.Number), ("1_000", K.Number), ("0xFF", K.Number));
    }

    [Fact]
    public void SwiftWithCrlfAndTurkishIdentifiers()
    {
        ExpectStyled("let ı = 1\r\nvar İş = \"ş\"\r\n/* a\r\nb */ func", CodeLanguage.Swift,
            ("let", K.Keyword), ("1", K.Number), ("var", K.Keyword), ("\"ş\"", K.String), ("/* a\r\nb */", K.Comment),
            ("func", K.Keyword));
    }

    [Fact]
    public void JavascriptTemplateSpansLines()
    {
        ExpectStyled("const t = `a\n${b}` // c", CodeLanguage.JavaScript,
            ("const", K.Keyword), ("`a\n${b}`", K.String), ("// c", K.Comment));
        ExpectStyled("$el.on('x')", CodeLanguage.JavaScript, ("'x'", K.String));
    }

    [Fact]
    public void Python()
    {
        ExpectStyled("@dec\ndef f(self): return None  # yorum\ns = '''a\n'b'\n'''", CodeLanguage.Python,
            ("@dec", K.Keyword), ("def", K.Keyword), ("self", K.Keyword), ("return", K.Keyword), ("None", K.Literal),
            ("# yorum", K.Comment), ("'''a\n'b'\n'''", K.String));
    }

    [Fact]
    public void Shell()
    {
        ExpectStyled("#!/bin/zsh\nif [ \"$HOME\" ]; then echo $# ${PATH} $1 a#b; fi # son", CodeLanguage.Shell,
            ("#!/bin/zsh", K.Comment), ("if", K.Keyword), ("\"$HOME\"", K.String), ("then", K.Keyword),
            ("$#", K.Property), ("${PATH}", K.Property), ("$1", K.Property), ("fi", K.Keyword), ("# son", K.Comment));
    }

    [Fact]
    public void Yaml()
    {
        var text = string.Join("\n",
            "# ayar",
            "ad: Çağlar's app",
            "\"tırnaklı\": yes",
            "liste:",
            "  - isim: x # not",
            "    sayı: -12",
            "url: http://a.b/c#d",
            "run: |",
            "  echo \"a: b\"",
            "  true",
            "sonra: ~");
        ExpectStyled(text, CodeLanguage.Yaml,
            ("# ayar", K.Comment), ("ad", K.Property), ("\"tırnaklı\"", K.Property), ("yes", K.Literal),
            ("liste", K.Property), ("isim", K.Property), ("# not", K.Comment), ("sayı", K.Property), ("-12", K.Number),
            ("url", K.Property), ("run", K.Property), ("echo \"a: b\"", K.String), ("true", K.String), ("sonra", K.Property));
    }

    [Fact]
    public void YamlWithCrlf()
    {
        ExpectStyled("ad: ş # not\r\nrun: |\r\n  satır 😀\r\nson: Evet\r\n", CodeLanguage.Yaml,
            ("ad", K.Property), ("# not\r", K.Comment), ("run", K.Property), ("satır 😀\r", K.String), ("son", K.Property));
    }

    [Fact]
    public void Xml()
    {
        var text = string.Join("\n",
            "<?xml version=\"1.0\"?>",
            "<!-- yorum -->",
            "<a href=x data-y='z' disabled>T &amp; ü</a><br/>",
            "<script>if (a<b) {}</script><![CDATA[<x>]]>");
        ExpectStyled(text, CodeLanguage.Xml,
            ("<?xml", K.Tag), ("version", K.Property), ("\"1.0\"", K.String), ("?>", K.Tag),
            ("<!-- yorum -->", K.Comment),
            ("<a", K.Tag), ("href", K.Property), ("x", K.String), ("data-y", K.Property), ("'z'", K.String),
            ("disabled", K.Property), (">", K.Tag), ("&amp;", K.Literal), ("</a", K.Tag), (">", K.Tag),
            ("<br", K.Tag), ("/>", K.Tag),
            ("<script", K.Tag), (">", K.Tag), ("</script", K.Tag), (">", K.Tag), ("<![CDATA[<x>]]>", K.String));
    }

    [Fact]
    public void XmlWithCrlfAndUppercaseRawTextClose()
    {
        ExpectStyled("<a\r\n  b=\"ş\">\r\nçay &#350;</a>\r\n<STYLE>a<b</STYLE>", CodeLanguage.Xml,
            ("<a", K.Tag), ("b", K.Property), ("\"ş\"", K.String), (">", K.Tag), ("&#350;", K.Literal), ("</a", K.Tag), (">", K.Tag),
            ("<STYLE", K.Tag), (">", K.Tag), ("</STYLE", K.Tag), (">", K.Tag));
    }

    [Fact]
    public void Css()
    {
        ExpectStyled("@media x { #id .c > a:hover { color: #fff !important; -webkit-x: 1.5em } }", CodeLanguage.Css,
            ("@media", K.Keyword), ("#id", K.Type), (".c", K.Type), ("color", K.Property), ("#fff", K.Number), ("important", K.Keyword),
            ("-webkit-x", K.Property), ("1.5em", K.Number));
        ExpectStyled("#id .sınıf { margin: 0 auto } /* c */", CodeLanguage.Css,
            ("#id", K.Type), (".sınıf", K.Type), ("margin", K.Property), ("0", K.Number), ("auto", K.Literal),
            ("/* c */", K.Comment));
    }

    [Fact]
    public void CFamily()
    {
        ExpectStyled("#include <x.h>\nfn f<'a>(c: char) -> &'a str { let c = '\\n'; let d = 'ğ'; NULL }", CodeLanguage.CFamily,
            ("#include", K.Keyword), ("fn", K.Keyword), ("char", K.Keyword),
            ("let", K.Keyword), ("'\\n'", K.String), ("let", K.Keyword), ("'ğ'", K.String), ("NULL", K.Literal));
        ExpectStyled("s := `raw\n\"x`", CodeLanguage.CFamily, ("`raw\n\"x`", K.String));
    }

    [Fact]
    public void CharLiteralWithSurrogatePair()
    {
        ExpectStyled("let d = '😀'; let e = '😀😀';", CodeLanguage.CFamily,
            ("let", K.Keyword), ("'😀'", K.String), ("let", K.Keyword));
    }

    [Fact]
    public void SqlIsCaseInsensitive()
    {
        ExpectStyled("SELECT * FROM t WHERE a = 'it''s' -- son\n/* b */ AND x IS NULL", CodeLanguage.Sql,
            ("SELECT", K.Keyword), ("FROM", K.Keyword), ("WHERE", K.Keyword), ("'it'", K.String), ("'s'", K.String),
            ("-- son", K.Comment), ("/* b */", K.Comment), ("AND", K.Keyword), ("IS", K.Keyword), ("NULL", K.Literal));
    }

    [Fact]
    public void SqlKeywordsAreCaseFoldedOnlyForAscii()
    {
        // Turkish dotted/dotless I are not ASCII and never fold to "if" / "in".
        ExpectStyled("İF ıf Select", CodeLanguage.Sql, ("Select", K.Keyword));
    }

    [Fact]
    public void Toml()
    {
        ExpectStyled("[paket]\nad = \"x\" # c\n\"a b\" = true\nsürüm.alt = 1.0\n; ini", CodeLanguage.Toml,
            ("[paket]", K.Tag), ("ad", K.Property), ("\"x\"", K.String), ("# c", K.Comment), ("\"a b\"", K.Property),
            ("true", K.Literal), ("sürüm.alt", K.Property), ("1.0", K.Number), ("; ini", K.Comment));
    }

    [Fact]
    public void TomlWithCrlf()
    {
        ExpectStyled("[bölüm]\r\nad = \"ş\"\r\n", CodeLanguage.Toml, ("[bölüm]", K.Tag), ("ad", K.Property), ("\"ş\"", K.String));
    }

    [Fact]
    public void UnterminatedTokensStop()
    {
        ExpectStyled("\"açık\nlet x", CodeLanguage.Swift, ("\"açık", K.String), ("let", K.Keyword));
        ExpectStyled("/* açık\nlet x", CodeLanguage.Swift, ("/* açık\nlet x", K.Comment));
        ExpectStyled("`açık", CodeLanguage.JavaScript, ("`açık", K.String));
        ExpectStyled("<a href=\"x", CodeLanguage.Xml, ("<a", K.Tag), ("href", K.Property), ("\"x", K.String));
        ExpectStyled("<!-- açık", CodeLanguage.Xml, ("<!-- açık", K.Comment));
        ExpectStyled("\"a\\", CodeLanguage.Json, ("\"a\\", K.String));
        foreach (var language in Enum.GetValues<CodeLanguage>())
        {
            foreach (var text in new[] { "\"", "'", "`", "/*", "<", "<!", "&", "#", "$", "${", "-", ".", "@", "\\", "a:", "[", "'\\" })
                CodeHighlighter.Spans(text, language);
        }
    }

    [Fact]
    public void RangesAreUtf16()
    {
        var text = "let 😀🇹🇷 = \"ğüşİ 👍🏽\" // Çay ☕️\nvar ı = 1";
        var spans = CodeHighlighter.Spans(text, CodeLanguage.Swift);
        Assert.Equal(["let", "\"ğüşİ 👍🏽\"", "// Çay ☕️", "var", "1"], spans.Select(s => text.Substring(s.Location, s.Length)));
        Assert.Equal(new CodeRange(13, 11), spans[1].Range);
    }

    [Fact]
    public void SpansAreSortedAndDisjoint()
    {
        var text = "{\"a\": [1, \"x\", true]} // c\nfunc f() { \"\"\"\n\"\"\" }";
        foreach (var language in Enum.GetValues<CodeLanguage>().Where(l => l != CodeLanguage.Markdown))
        {
            var spans = CodeHighlighter.Spans(text, language);
            for (var k = 0; k + 1 < spans.Count; k++)
                Assert.True(spans[k].End <= spans[k + 1].Location, language.ToString());
        }
    }

    [Fact]
    public void MarkdownSpansMapToCodeKinds()
    {
        var text = "# Başlık\n\n> alıntı\n\n- [ ] görev `kod` [bağ](http://a.b)\n\n```\nçit\n```\n";
        var styled = Styled(text, CodeLanguage.Markdown);
        Assert.Contains(("# Başlık", K.Keyword), styled);
        Assert.Contains(("kod", K.String), styled);
        Assert.Contains(styled, s => s.Kind == K.Comment && s.Text.Contains("alıntı"));
        Assert.Contains(styled, s => s.Kind == K.Property && s.Text.Contains("bağ"));
        Assert.Contains(styled, s => s.Kind == K.Tag);
    }

    [Fact]
    public void DisplayNames()
    {
        Assert.Equal("JSON", CodeLanguage.Json.DisplayName());
        Assert.Equal("C", CodeLanguage.CFamily.DisplayName());
        Assert.Equal("Plain text", CodeLanguage.PlainText.DisplayName());
        using (TestCulture.Use("tr")) Assert.Equal("Düz metin", CodeLanguage.PlainText.DisplayName());
    }

    [Fact]
    public void IndentUnit()
    {
        Assert.Equal("    ", CodeLanguage.Json.IndentUnit("{\n    \"a\": {\n        \"b\": 1\n    }\n}"));
        Assert.Equal("\t", CodeLanguage.CFamily.IndentUnit("func f() {\n\tx()\n\tif y {\n\t\tz()\n\t}\n}"));
        Assert.Equal("  ", CodeLanguage.Yaml.IndentUnit("a:\n\tb: 1\n\tc: 2"));
        Assert.Equal("    ", CodeLanguage.Swift.IndentUnit(""));
        Assert.Equal("  ", CodeLanguage.Json.IndentUnit("{}"));
        // CRLF and non-ASCII text do not disturb the count.
        Assert.Equal("    ", CodeLanguage.Json.IndentUnit("{\r\n    \"ş\": {\r\n        \"😀\": 1\r\n    }\r\n}"));
    }

    /// <summary>Simulates editor keystrokes: outside ChangedRange, every character must keep its kind.</summary>
    [Fact]
    public void ChangedRangeCoversEveryRestyledCharacter()
    {
        (string, CodeLanguage)[] samples =
        [
            ("let a = \"x\" // c\n/* b */ var ğ = 1\nfunc f() { \"\"\"\nç\n\"\"\" }\n", CodeLanguage.Swift),
            ("{\"a\": [1, true, \"ş\"], \"b\": null}\n", CodeLanguage.Json),
            ("a: 1\nrun: |\n  x: y\nb: 'c' # d\n", CodeLanguage.Yaml),
            ("<a href=\"x\">t &amp;</a><!-- c -->\n", CodeLanguage.Xml),
            ("let a = \"x\" // c\r\n/* b */ var İ = 1\r\n", CodeLanguage.Swift),
        ];
        string[] inserts = ["\"", "/*", "*/", "'", "x", "\n", "\r\n", "`", "<", ">", "#", " ", "😀", "|", "\"\"\"", "ş"];
        var rng = new Random(20260101);
        foreach (var (sample, language) in samples)
        {
            for (var round = 0; round < 300; round++)
            {
                var start = rng.Next(0, sample.Length + 1);
                var removed = rng.Next(0, Math.Min(3, sample.Length - start) + 1);
                var inserted = rng.Next(2) == 0 ? inserts[rng.Next(inserts.Length)] : "";
                var newText = sample.Remove(start, removed).Insert(start, inserted);
                var oldSpans = CodeHighlighter.Spans(sample, language);
                var newSpans = CodeHighlighter.Spans(newText, language);
                var range = CodeHighlighter.ChangedRange(oldSpans, newSpans, new CodeRange(start, inserted.Length),
                    inserted.Length - removed, newText.Length);

                var oldKinds = Kinds(oldSpans, sample.Length);
                var newKinds = Kinds(newSpans, newText.Length);
                for (var x = 0; x < newText.Length; x++)
                {
                    if (x >= range.Location && x < range.End) continue;
                    var before = x < start ? x : x - (inserted.Length - removed);
                    Assert.True(oldKinds[before] == newKinds[x], $"{language} {newText} at {x}");
                }
            }
        }
    }

    private static CodeSpanKind?[] Kinds(List<CodeSpan> spans, int length)
    {
        var result = new CodeSpanKind?[length];
        foreach (var span in spans)
            for (var k = span.Location; k < span.End; k++) result[k] = span.Kind;
        return result;
    }

    [Fact]
    public void LargeFileIsFast()
    {
        const string block = """
            import Foundation
            /// Belge yorumu — açıklama 😀
            @MainActor final class Örnek<T>: NSObject {
                private var değer: [String: Int] = ["a": 1, "b": 0x2F, "c": 3_000]
                func çalıştır(_ x: Double = 1.5e-3) async throws -> Bool {
                    guard let y = değer["a"], y > 0 else { return false } // satır sonu
                    /* blok
                       yorum */
                    print("Merhaba \\(y) \\"dünya\\"")
                    return true
                }
            }
            """;
        var text = string.Join("\n", Enumerable.Repeat(block, 5_000 / 12));
        var json = "[" + string.Join(",\n", Enumerable.Repeat("""{"ad": "Çağlar", "sayı": -12.5e3, "ok": true, "x": null}""", 5_000)) + "]";
        var watch = Stopwatch.StartNew();
        var count = CodeHighlighter.Spans(text, CodeLanguage.Swift).Count + CodeHighlighter.Spans(json, CodeLanguage.Json).Count;
        watch.Stop();
        Assert.True(count > 40_000);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(1), watch.Elapsed.ToString());
    }

    [Fact]
    public void RawTextTagNamesFoldOnlyAscii()
    {
        // Turkish dotted capital I must not turn "SCR\u0130PT" into a script element.
        var spans = Styled("<SCR\u0130PT>a<b</SCR\u0130PT>", CodeLanguage.Xml);
        Assert.Contains(spans, s => s.Text == "<b");
        ExpectStyled("<SCRIPT>a<b</SCRIPT>", CodeLanguage.Xml,
            ("<SCRIPT", K.Tag), (">", K.Tag), ("</SCRIPT", K.Tag), (">", K.Tag));
    }
}
