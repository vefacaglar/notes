import Testing
@testable import NotesCore

struct MarkdownHTMLTests {
    private func html(_ markdown: String) -> String { MarkdownHTML.body(markdown: markdown) }

    @Test func headingsAndParagraphs() {
        #expect(html("# Title\n\nSome *text*\nmore") == "<h1>Title</h1>\n<p>Some <em>text</em>\nmore</p>\n")
        #expect(html("### Three ###") == "<h3>Three</h3>\n")
        #expect(html("Setext\n===\n\nTwo\n---") == "<h1>Setext</h1>\n<h2>Two</h2>\n")
    }

    @Test func inlineStyles() {
        #expect(html("**b** __b__ *i* _i_ ~~s~~ ***bi***")
                == "<p><strong>b</strong> <strong>b</strong> <em>i</em> <em>i</em> <del>s</del> <strong><em>bi</em></strong></p>\n")
        #expect(html("snake_case_name and 2*3*4") == "<p>snake_case_name and 2<em>3</em>4</p>\n")
    }

    @Test func codeSpansKeepMarkup() {
        #expect(html("use `a *b* <c>` here") == "<p>use <code>a *b* &lt;c&gt;</code> here</p>\n")
        #expect(html("`` a`b ``") == "<p><code>a`b</code></p>\n")
    }

    @Test func fencedCode() {
        #expect(html("```swift\nlet a = 1 < 2\n```") == "<pre><code class=\"language-swift\">let a = 1 &lt; 2</code></pre>\n")
        #expect(html("~~~\n# not heading\n~~~") == "<pre><code># not heading</code></pre>\n")
        #expect(html("```\nunclosed") == "<pre><code>unclosed</code></pre>\n")
    }

    @Test func rawHTMLIsEscaped() {
        #expect(html("<script>alert(1)</script> & \"q\"") == "<p>&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;q&quot;</p>\n")
    }

    @Test func linksAndImages() {
        #expect(html("[a *b*](https://x.com/?a=1&b=2 \"T\")")
                == "<p><a href=\"https://x.com/?a=1&amp;b=2\" title=\"T\">a <em>b</em></a></p>\n")
        #expect(html("![alt](pic.png)") == "<p><img src=\"pic.png\" alt=\"alt\"></p>\n")
        #expect(html("<https://x.com> and https://y.com/a_b_c.")
                == "<p><a href=\"https://x.com\">https://x.com</a> and <a href=\"https://y.com/a_b_c\">https://y.com/a_b_c</a>.</p>\n")
    }

    @Test func dangerousLinksAreNeutralised() {
        #expect(html("[x](javascript:alert(1))").contains("href=\"#\""))
        #expect(html("[x](JavaScript:alert)").contains("href=\"#\""))
    }

    @Test(arguments: [
        "[x](\u{01}javascript:alert%281%29)",
        "[x](\u{1F}JavaScript:alert)",
        "[x]( \u{0B}javascript:alert)",
        "[x](vbscript:x)",
        "[x](data:text/html,hi)",
        "![x](\u{01}javascript:alert)",
        "[x](ftp://a/b)",
        "[x](file:///etc/passwd)",
    ])
    func schemeBypassesAreNeutralised(_ markdown: String) {
        let out = html(markdown)
        #expect(out.contains("href=\"#\"") || out.contains("src=\"#\""), "\(out)")
    }

    @Test func allowedTargetsSurvive() {
        #expect(html("[a](HTTPS://x.com/a:b)").contains("href=\"HTTPS://x.com/a:b\""))
        #expect(html("[a](mailto:me@x.com)").contains("href=\"mailto:me@x.com\""))
        #expect(html("[a](notes/b.md#h:1)").contains("href=\"notes/b.md#h:1\""))
        #expect(html("[a](./x:y)").contains("href=\"./x:y\""))
        #expect(html("[a](#top)").contains("href=\"#top\""))
    }

    @Test(arguments: [
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
    ])
    func hostileDestinationsNeverBreakOutOfAttributes(_ markdown: String) {
        let out = html(markdown)
        // Every attribute value is closed by the tag's own quotes: no quote character is left unescaped inside one.
        let tags = out.components(separatedBy: "<").dropFirst().map { "<" + $0 }
        for tag in tags where tag.hasPrefix("<a ") || tag.hasPrefix("<img ") {
            let head = String(tag.prefix { $0 != ">" })
            // Whatever is left after removing the name and every well-formed `attr="value"` is an injected attribute.
            let rest = head.replacingOccurrences(of: #"^<\w+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s[a-z]+="[^"]*""#, with: "", options: .regularExpression)
            #expect(rest.isEmpty, "\(out)")
            #expect(!head.contains(" onerror=\"") && !head.contains(" onmouseover=\"") && !head.contains(" onfocus=\""), "\(out)")
        }
    }

    @Test func safeURLCleansLikeABrowser() {
        #expect(MarkdownHTML.safeURL("java\tscript:alert(1)") == "#")
        #expect(MarkdownHTML.safeURL("\u{01} \u{1F}javascript:x") == "#")
        #expect(MarkdownHTML.safeURL(" \thttps://a.b/c\n") == "https://a.b/c")
        #expect(MarkdownHTML.safeURL("a/b:c") == "a/b:c")
    }

    @Test func escapedCharactersStillWorkInDestinations() {
        #expect(html("[x](a\\_b.md)").contains("href=\"a_b.md\""))
    }

    @Test func backslashEscapes() {
        #expect(html("\\*not em\\* \\# x") == "<p>*not em* # x</p>\n")
    }

    @Test func lists() {
        #expect(html("- a\n- b") == "<ul>\n<li>a\n</li>\n<li>b\n</li>\n</ul>\n")
        #expect(html("3. a\n4. b") == "<ol start=\"3\">\n<li>a\n</li>\n<li>b\n</li>\n</ol>\n")
        #expect(html("- a\n  - b\n- c") == "<ul>\n<li>a\n<ul>\n<li>b\n</li>\n</ul>\n</li>\n<li>c\n</li>\n</ul>\n")
        #expect(html("- a\n\n- b").contains("<li><p>a</p>\n</li>"))
    }

    @Test func taskLists() {
        let result = html("- [ ] open\n- [x] done")
        #expect(result.contains("<li class=\"task\"><input type=\"checkbox\" disabled> open\n</li>"))
        #expect(result.contains("<li class=\"task\"><input type=\"checkbox\" disabled checked> done\n</li>"))
    }

    @Test func blockquotesAndRules() {
        #expect(html("> a\n> b\n\n---\n***") == "<blockquote>\n<p>a\nb</p>\n</blockquote>\n<hr>\n<hr>\n")
        #expect(html("> # H\n> - x").contains("<blockquote>\n<h1>H</h1>\n<ul>"))
    }

    @Test func tables() {
        let result = html("| A | B |\n|:--|--:|\n| 1 | 2 |")
        #expect(result.contains("<th style=\"text-align: left\">A</th><th style=\"text-align: right\">B</th>"))
        #expect(result.contains("<td style=\"text-align: left\">1</td><td style=\"text-align: right\">2</td>"))
    }

    @Test func hardBreaksAndCRLF() {
        #expect(html("a  \r\nb") == "<p>a<br>\nb</p>\n")
    }

    @Test func unicodeSurvives() {
        #expect(html("# İstanbul 👍\n\nşehir *ığdır*") == "<h1>İstanbul 👍</h1>\n<p>şehir <em>ığdır</em></p>\n")
    }

    @Test func documentUsesFontsAndEscapesTitle() {
        let page = MarkdownHTML.document(markdown: "x", title: "A <b>",
                                          style: .init(textFontFamily: "Avenir \"Next\"", textFontSize: 16, codeFontFamily: "Menlo", codeFontSize: 12))
        #expect(page.contains("<title>A &lt;b&gt;</title>"))
        #expect(page.contains("\"Avenir Next\""))
        #expect(page.contains("16.0px"))
        #expect(page.contains("\"Menlo\""))
    }

    @Test func codeFilesBecomeOnePre() {
        let page = MarkdownHTML.document(code: "a < b\r\nc", title: "x.swift")
        #expect(page.contains("<pre class=\"file\"><code>a &lt; b\nc</code></pre>"))
    }
}
