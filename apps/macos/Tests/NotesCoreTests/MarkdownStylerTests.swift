import Foundation
import Testing
@testable import NotesCore

struct MarkdownStylerTests {
    /// Spans rendered as `(text, kind)` so expectations stay readable.
    private func styled(_ text: String) -> [(String, MarkdownSpan.Kind)] {
        let ns = text as NSString
        return MarkdownStyler.spans(in: text).map { (ns.substring(with: $0.range), $0.kind) }
    }

    private func expectStyled(_ text: String, _ expected: [(String, MarkdownSpan.Kind)],
                              sourceLocation: SourceLocation = #_sourceLocation) {
        let actual = styled(text)
        #expect(actual.map(\.0) == expected.map(\.0), sourceLocation: sourceLocation)
        #expect(actual.map(\.1) == expected.map(\.1), sourceLocation: sourceLocation)
    }

    @Test func headings() {
        expectStyled("# Başlık", [("# Başlık", .heading(level: 1)), ("# ", .marker)])
        expectStyled("###### Altı ##", [
            ("###### Altı ##", .heading(level: 6)), ("###### ", .marker), ("##", .marker),
        ])
        expectStyled("## **Kalın** başlık", [
            ("## **Kalın** başlık", .heading(level: 2)), ("## ", .marker),
            ("**", .marker), ("Kalın", .bold), ("**", .marker),
        ])
        expectStyled("####### yedi", [])
        expectStyled("#etiket", [])
        expectStyled("# C#", [("# C#", .heading(level: 1)), ("# ", .marker)])
    }

    @Test func emphasis() {
        expectStyled("a **b** c", [("**", .marker), ("b", .bold), ("**", .marker)])
        expectStyled("__b__", [("__", .marker), ("b", .bold), ("__", .marker)])
        expectStyled("*i* _j_", [
            ("*", .marker), ("i", .italic), ("*", .marker),
            ("_", .marker), ("j", .italic), ("_", .marker),
        ])
        expectStyled("***bi***", [("***", .marker), ("bi", .boldItalic), ("***", .marker)])
        expectStyled("**a *b* c**", [
            ("**", .marker), ("a *b* c", .bold), ("*", .marker), ("b", .italic), ("*", .marker), ("**", .marker),
        ])
        expectStyled("~~sil~~ ~tek~", [("~~", .marker), ("sil", .strikethrough), ("~~", .marker)])
        expectStyled("**Ankara**'da", [("**", .marker), ("Ankara", .bold), ("**", .marker)])
    }

    @Test func intrawordAndUnmatchedDelimitersStayPlain() {
        expectStyled("a*b*c", [])
        expectStyled("snake_case_name", [])
        expectStyled("2 * 3 * 4", [])
        expectStyled("**açık", [])
        expectStyled("\\*kaçış\\*", [("\\", .marker), ("\\", .marker)])
    }

    @Test func inlineStylingNeverCrossesLines() {
        expectStyled("**a\nb**", [])
        expectStyled("`a\nb`", [])
        expectStyled("[a\n](b)", [])
    }

    @Test func inlineCodeHidesOtherSyntax() {
        expectStyled("x `**y**` z", [("`", .marker), ("**y**", .inlineCode), ("`", .marker)])
        expectStyled("``a ` b``", [("``", .marker), ("a ` b", .inlineCode), ("``", .marker)])
    }

    @Test func fencedCodeBlocks() {
        let text = "önce\n```swift\nlet **x** = 1\n```\n# sonra"
        expectStyled(text, [
            ("```swift\nlet **x** = 1\n```", .codeBlock), ("```swift", .marker), ("```", .marker),
            ("# sonra", .heading(level: 1)), ("# ", .marker),
        ])
        expectStyled("~~~\n```\n~~~", [("~~~\n```\n~~~", .codeBlock), ("~~~", .marker), ("~~~", .marker)])
        expectStyled("```\nkapanmamış\n# değil", [("```\nkapanmamış\n# değil", .codeBlock), ("```", .marker)])
        expectStyled("``` a`b", [])
    }

    @Test func blockquotesAndLists() {
        expectStyled("> alıntı *x*", [
            ("> alıntı *x*", .blockquote), ("> ", .marker), ("*", .marker), ("x", .italic), ("*", .marker),
        ])
        expectStyled("- madde", [("-", .listMarker)])
        expectStyled("  12. on iki", [("12.", .listMarker)])
        expectStyled("-yok", [])
        expectStyled("> - iç", [("> - iç", .blockquote), ("> ", .marker), ("-", .listMarker)])
    }

    @Test func tasks() {
        expectStyled("- [ ] yapılacak", [
            ("-", .listMarker), ("[ ]", .taskMarker(checked: false)), ("yapılacak", .task(checked: false)),
        ])
        expectStyled("* [x] bitti **çok**", [
            ("*", .listMarker), ("[x]", .taskMarker(checked: true)), ("bitti **çok**", .task(checked: true)),
            ("**", .marker), ("çok", .bold), ("**", .marker),
        ])
        expectStyled("- [y] değil", [("-", .listMarker)])
    }

    @Test func links() {
        expectStyled("bak [Şu sayfa](https://ex.com/a_(b)) tamam", [
            ("[", .marker), ("Şu sayfa", .link(url: "https://ex.com/a_(b)")), ("](https://ex.com/a_(b))", .marker),
        ])
        expectStyled("![resim](a.png \"başlık\")", [
            ("![", .marker), ("resim", .link(url: "a.png")), ("](a.png \"başlık\")", .marker),
        ])
        expectStyled("[yalnız köşeli]", [])
        expectStyled("<https://ex.com>", [("<", .marker), ("https://ex.com", .link(url: "https://ex.com")), (">", .marker)])
        expectStyled("Bkz. https://ex.com/ara?q=ı, sonra", [
            ("https://ex.com/ara?q=ı", .link(url: "https://ex.com/ara?q=ı")),
        ])
        expectStyled("(http://ex.com/x_y)", [("http://ex.com/x_y", .link(url: "http://ex.com/x_y"))])
        expectStyled("xhttps://ex.com", [])
    }

    @Test func horizontalRules() {
        expectStyled("---", [("---", .horizontalRule)])
        expectStyled("* * *", [("* * *", .horizontalRule)])
        expectStyled("--", [])
    }

    @Test func rangesAreUTF16AndSurviveCRLF() {
        let text = "😀🇹🇷 **ğüşİ** 👍🏽\r\n## Çay ☕️"
        let spans = MarkdownStyler.spans(in: text)
        let ns = text as NSString
        #expect(spans.map { ns.substring(with: $0.range) } == ["**", "ğüşİ", "**", "## Çay ☕️", "## "])
        #expect(spans[1].range == NSRange(location: 9, length: 4))
    }

    @Test func spansAreSortedOuterFirst() {
        let text = "> # a **b** [c](d)\n```\nx\n```\n- [ ] *e* `f`"
        let spans = MarkdownStyler.spans(in: text)
        for (a, b) in zip(spans, spans.dropFirst()) {
            #expect(a.range.location < b.range.location
                    || (a.range.location == b.range.location && a.range.length >= b.range.length))
        }
    }

    @Test func emptyAndTrivialInput() {
        #expect(MarkdownStyler.spans(in: "").isEmpty)
        #expect(MarkdownStyler.spans(in: "\n\n").isEmpty)
        #expect(MarkdownStyler.spans(in: "düz metin").isEmpty)
    }

    @Test func largeNoteIsFast() {
        let block = """
        # Başlık **kalın** ve *eğik*
        - [ ] görev `kod` [bağlantı](https://ex.com) ~~sil~~
        > alıntı https://ex.com/yol, devam 😀
        ```
        let x = **1**
        ```
        Düz paragraf satırı a*b*c snake_case_name ve biraz daha metin.
        """
        let text = Array(repeating: block, count: 5_000 / 7).joined(separator: "\n")
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure { count = MarkdownStyler.spans(in: text).count }
        #expect(count > 5_000)
        // Generous bound so debug builds pass too; release is far below this.
        #expect(elapsed < .milliseconds(500))
    }
}
