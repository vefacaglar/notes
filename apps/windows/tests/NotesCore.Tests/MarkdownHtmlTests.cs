using System.Text.RegularExpressions;

namespace NotesCore.Tests;

public sealed class MarkdownHtmlTests
{
    private static string Html(string markdown) => MarkdownHtml.Body(markdown);

    [Fact]
    public void HeadingsAndParagraphs()
    {
        Assert.Equal("<h1>Title</h1>\n<p>Some <em>text</em>\nmore</p>\n", Html("# Title\n\nSome *text*\nmore"));
        Assert.Equal("<h3>Three</h3>\n", Html("### Three ###"));
        Assert.Equal("<h1>Setext</h1>\n<h2>Two</h2>\n", Html("Setext\n===\n\nTwo\n---"));
    }

    [Fact]
    public void InlineStyles()
    {
        Assert.Equal("<p><strong>b</strong> <strong>b</strong> <em>i</em> <em>i</em> <del>s</del> <strong><em>bi</em></strong></p>\n",
            Html("**b** __b__ *i* _i_ ~~s~~ ***bi***"));
        Assert.Equal("<p>snake_case_name and 2<em>3</em>4</p>\n", Html("snake_case_name and 2*3*4"));
    }

    [Fact]
    public void CodeSpansKeepMarkup()
    {
        Assert.Equal("<p>use <code>a *b* &lt;c&gt;</code> here</p>\n", Html("use `a *b* <c>` here"));
        Assert.Equal("<p><code>a`b</code></p>\n", Html("`` a`b ``"));
    }

    [Fact]
    public void FencedCode()
    {
        Assert.Equal("<pre><code class=\"language-swift\">let a = 1 &lt; 2</code></pre>\n", Html("```swift\nlet a = 1 < 2\n```"));
        Assert.Equal("<pre><code># not heading</code></pre>\n", Html("~~~\n# not heading\n~~~"));
        Assert.Equal("<pre><code>unclosed</code></pre>\n", Html("```\nunclosed"));
    }

    [Fact]
    public void RawHtmlIsEscaped() =>
        Assert.Equal("<p>&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;q&quot;</p>\n", Html("<script>alert(1)</script> & \"q\""));

    [Fact]
    public void LinksAndImages()
    {
        Assert.Equal("<p><a href=\"https://x.com/?a=1&amp;b=2\" title=\"T\">a <em>b</em></a></p>\n", Html("[a *b*](https://x.com/?a=1&b=2 \"T\")"));
        Assert.Equal("<p><img src=\"pic.png\" alt=\"alt\"></p>\n", Html("![alt](pic.png)"));
        Assert.Equal("<p><a href=\"https://x.com\">https://x.com</a> and <a href=\"https://y.com/a_b_c\">https://y.com/a_b_c</a>.</p>\n",
            Html("<https://x.com> and https://y.com/a_b_c."));
    }

    [Fact]
    public void DangerousLinksAreNeutralised()
    {
        Assert.Contains("href=\"#\"", Html("[x](javascript:alert(1))"));
        Assert.Contains("href=\"#\"", Html("[x](JavaScript:alert)"));
    }

    public static TheoryData<string> SchemeBypasses =>
    [
        "[x](\u0001javascript:alert%281%29)",
        "[x](\u001FJavaScript:alert)",
        "[x]( \u000Bjavascript:alert)",
        "[x](vbscript:x)",
        "[x](data:text/html,hi)",
        "![x](\u0001javascript:alert)",
        "[x](ftp://a/b)",
        "[x](file:///etc/passwd)",
    ];

    [Theory]
    [MemberData(nameof(SchemeBypasses))]
    public void SchemeBypassesAreNeutralised(string markdown)
    {
        var output = Html(markdown);
        Assert.True(output.Contains("href=\"#\"") || output.Contains("src=\"#\""), output);
    }

    [Fact]
    public void AllowedTargetsSurvive()
    {
        Assert.Contains("href=\"HTTPS://x.com/a:b\"", Html("[a](HTTPS://x.com/a:b)"));
        Assert.Contains("href=\"mailto:me@x.com\"", Html("[a](mailto:me@x.com)"));
        Assert.Contains("href=\"notes/b.md#h:1\"", Html("[a](notes/b.md#h:1)"));
        Assert.Contains("href=\"./x:y\"", Html("[a](./x:y)"));
        Assert.Contains("href=\"#top\"", Html("[a](#top)"));
    }

    public static TheoryData<string> HostileDestinations =>
    [
        "[x](<http://a/onerror=alert(1)//>)",
        "![x](<http://a/\"onerror=alert(1)>)",
        "[x](<https://a> \"t\")",
        "[x](a \"<https://b/\" onmouseover=\"alert(1)>\")",
        "![x](a \"<https://b/\" onerror=\"alert(1)>\")",
        "[x](`a\"onerror=1`)",
        "[x](a \"`b\" onfocus=\"1`\")",
        "[x](\"onerror=alert(1) \"b\")",
        "![\"onerror=1](x\" onerror=\"1)",
        "[x](a<b>\"onerror=1)",
    ];

    [Theory]
    [MemberData(nameof(HostileDestinations))]
    public void HostileDestinationsNeverBreakOutOfAttributes(string markdown)
    {
        var output = Html(markdown);
        // Every attribute value is closed by the tag's own quotes: no quote character is left unescaped inside one.
        foreach (var part in output.Split('<').Skip(1))
        {
            var tag = "<" + part;
            if (!tag.StartsWith("<a ") && !tag.StartsWith("<img ")) continue;
            var head = new string(tag.TakeWhile(c => c != '>').ToArray());
            // Whatever is left after removing the name and every well-formed `attr="value"` is an injected attribute.
            var rest = Regex.Replace(Regex.Replace(head, @"^<\w+", ""), @"\s[a-z]+=""[^""]*""", "");
            Assert.True(rest.Length == 0, output);
            Assert.True(!head.Contains(" onerror=\"") && !head.Contains(" onmouseover=\"") && !head.Contains(" onfocus=\""), output);
        }
    }

    [Fact]
    public void SafeUrlCleansLikeABrowser()
    {
        Assert.Equal("#", MarkdownHtml.SafeUrl("java\tscript:alert(1)"));
        Assert.Equal("#", MarkdownHtml.SafeUrl("\u0001 \u001Fjavascript:x"));
        Assert.Equal("https://a.b/c", MarkdownHtml.SafeUrl(" \thttps://a.b/c\n"));
        Assert.Equal("a/b:c", MarkdownHtml.SafeUrl("a/b:c"));
    }

    [Fact]
    public void EscapedCharactersStillWorkInDestinations() => Assert.Contains("href=\"a_b.md\"", Html("[x](a\\_b.md)"));

    [Fact]
    public void BackslashEscapes() => Assert.Equal("<p>*not em* # x</p>\n", Html("\\*not em\\* \\# x"));

    [Fact]
    public void Lists()
    {
        Assert.Equal("<ul>\n<li>a\n</li>\n<li>b\n</li>\n</ul>\n", Html("- a\n- b"));
        Assert.Equal("<ol start=\"3\">\n<li>a\n</li>\n<li>b\n</li>\n</ol>\n", Html("3. a\n4. b"));
        Assert.Equal("<ul>\n<li>a\n<ul>\n<li>b\n</li>\n</ul>\n</li>\n<li>c\n</li>\n</ul>\n", Html("- a\n  - b\n- c"));
        Assert.Contains("<li><p>a</p>\n</li>", Html("- a\n\n- b"));
    }

    [Fact]
    public void TaskLists()
    {
        var result = Html("- [ ] open\n- [x] done");
        Assert.Contains("<li class=\"task\"><input type=\"checkbox\" disabled> open\n</li>", result);
        Assert.Contains("<li class=\"task\"><input type=\"checkbox\" disabled checked> done\n</li>", result);
    }

    [Fact]
    public void BlockquotesAndRules()
    {
        Assert.Equal("<blockquote>\n<p>a\nb</p>\n</blockquote>\n<hr>\n<hr>\n", Html("> a\n> b\n\n---\n***"));
        Assert.Contains("<blockquote>\n<h1>H</h1>\n<ul>", Html("> # H\n> - x"));
    }

    [Fact]
    public void Tables()
    {
        var result = Html("| A | B |\n|:--|--:|\n| 1 | 2 |");
        Assert.Contains("<th style=\"text-align: left\">A</th><th style=\"text-align: right\">B</th>", result);
        Assert.Contains("<td style=\"text-align: left\">1</td><td style=\"text-align: right\">2</td>", result);
    }

    [Fact]
    public void HardBreaksAndCrlf() => Assert.Equal("<p>a<br>\nb</p>\n", Html("a  \r\nb"));

    [Fact]
    public void UnicodeSurvives() =>
        Assert.Equal("<h1>İstanbul 👍</h1>\n<p>şehir <em>ığdır</em></p>\n", Html("# İstanbul 👍\n\nşehir *ığdır*"));

    [Fact]
    public void LineSeparatorsAreOrdinaryTextLikeOnMacOs()
    {
        // ICU's `.` stops at U+2028, so such a line is no heading there; the port keeps that.
        Assert.Equal("<p># a\u2028b</p>\n", Html("# a\u2028b"));
    }

    [Fact]
    public void DocumentUsesFontsAndEscapesTitle()
    {
        var page = MarkdownHtml.Document("x", "A <b>", new MarkdownHtml.Style("Avenir \"Next\"", 16, "Menlo", 12));
        Assert.Contains("<title>A &lt;b&gt;</title>", page);
        Assert.Contains("\"Avenir Next\"", page);
        Assert.Contains("16.0px", page);
        Assert.Contains("\"Menlo\"", page);
        Assert.StartsWith("<!doctype html>\n<html>\n<head>\n", page);
        Assert.EndsWith("<main>\n<p>x</p>\n</main>\n</body>\n</html>\n", page);
        Assert.DoesNotContain("\r", page);
    }

    [Fact]
    public void CodeFilesBecomeOnePre()
    {
        var page = MarkdownHtml.DocumentForCode("a < b\r\nc", "x.swift");
        Assert.Contains("<pre class=\"file\"><code>a &lt; b\nc</code></pre>", page);
    }
}
