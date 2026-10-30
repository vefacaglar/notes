import Foundation
import Testing
@testable import NotesCore

struct CodeHighlighterTests {
    private func styled(_ text: String, _ language: CodeLanguage) -> [(String, CodeSpan.Kind)] {
        let ns = text as NSString
        return CodeHighlighter.spans(in: text, language: language).map { (ns.substring(with: $0.range), $0.kind) }
    }

    private func expectStyled(_ text: String, _ language: CodeLanguage, _ expected: [(String, CodeSpan.Kind)],
                              sourceLocation: SourceLocation = #_sourceLocation) {
        let actual = styled(text, language)
        #expect(actual.map(\.0) == expected.map(\.0), sourceLocation: sourceLocation)
        #expect(actual.map(\.1) == expected.map(\.1), sourceLocation: sourceLocation)
    }

    @Test(arguments: [
        ("a.json", CodeLanguage.json), ("b.SWIFT", .swift), ("c.tsx", .javascript), ("d.mjs", .javascript),
        ("e.py", .python), ("f.zsh", .shell), ("g.yml", .yaml), ("h.plist", .xml), ("i.svg", .xml),
        ("j.css", .css), ("k.rs", .cFamily), ("l.hpp", .cFamily), ("m.sql", .sql), ("n.ini", .toml),
        ("Klasör/o.md", .markdown), ("p.txt", .plainText), ("Makefile", .plainText),
    ])
    func detectsLanguageFromExtension(path: String, language: CodeLanguage) {
        #expect(CodeLanguage(path: path) == language)
    }

    @Test func json() {
        expectStyled(#"{"ad": "Çağlar", "yaş": -3.5e+2, "ok": true, "x": null, "l": [1, "a\"b"]}"#, .json, [
            (#""ad""#, .property), (#""Çağlar""#, .string), (#""yaş""#, .property), ("-3.5e+2", .number),
            (#""ok""#, .property), ("true", .literal), (#""x""#, .property), ("null", .literal),
            (#""l""#, .property), ("1", .number), (#""a\"b""#, .string),
        ])
        expectStyled("{\"a\"\n  : 1}", .json, [("\"a\"", .string), ("1", .number)])
    }

    @Test func swift() {
        expectStyled("@MainActor final class Not: View { let x = nil // yorum\n}", .swift, [
            ("@MainActor", .keyword), ("final", .keyword), ("class", .keyword), ("Not", .type), ("View", .type),
            ("let", .keyword), ("nil", .literal), ("// yorum", .comment),
        ])
        expectStyled("/* a /* iç */ b */ x", .swift, [("/* a /* iç */ b */", .comment)])
        expectStyled("let s = \"\"\"\nçok \"satır\"\n\"\"\"\n#if DEBUG", .swift, [
            ("let", .keyword), ("\"\"\"\nçok \"satır\"\n\"\"\"", .string), ("#if", .keyword),
        ])
        expectStyled("0..<10 x.0 1_000 0xFF", .swift, [
            ("0", .number), ("10", .number), ("0", .number), ("1_000", .number), ("0xFF", .number),
        ])
    }

    @Test func javascriptTemplateSpansLines() {
        expectStyled("const t = `a\n${b}` // c", .javascript, [
            ("const", .keyword), ("`a\n${b}`", .string), ("// c", .comment),
        ])
        expectStyled("$el.on('x')", .javascript, [("'x'", .string)])
    }

    @Test func python() {
        expectStyled("@dec\ndef f(self): return None  # yorum\ns = '''a\n'b'\n'''", .python, [
            ("@dec", .keyword), ("def", .keyword), ("self", .keyword), ("return", .keyword), ("None", .literal),
            ("# yorum", .comment), ("'''a\n'b'\n'''", .string),
        ])
    }

    @Test func shell() {
        expectStyled("#!/bin/zsh\nif [ \"$HOME\" ]; then echo $# ${PATH} $1 a#b; fi # son", .shell, [
            ("#!/bin/zsh", .comment), ("if", .keyword), ("\"$HOME\"", .string), ("then", .keyword),
            ("$#", .property), ("${PATH}", .property), ("$1", .property), ("fi", .keyword), ("# son", .comment),
        ])
    }

    @Test func yaml() {
        let text = """
        # ayar
        ad: Çağlar's app
        "tırnaklı": yes
        liste:
          - isim: x # not
            sayı: -12
        url: http://a.b/c#d
        run: |
          echo "a: b"
          true
        sonra: ~
        """
        expectStyled(text, .yaml, [
            ("# ayar", .comment), ("ad", .property), ("\"tırnaklı\"", .property), ("yes", .literal),
            ("liste", .property), ("isim", .property), ("# not", .comment), ("sayı", .property), ("-12", .number),
            ("url", .property), ("run", .property), ("echo \"a: b\"", .string), ("true", .string), ("sonra", .property),
        ])
    }

    @Test func xml() {
        let text = """
        <?xml version="1.0"?>
        <!-- yorum -->
        <a href=x data-y='z' disabled>T &amp; ü</a><br/>
        <script>if (a<b) {}</script><![CDATA[<x>]]>
        """
        expectStyled(text, .xml, [
            ("<?xml", .tag), ("version", .property), ("\"1.0\"", .string), ("?>", .tag),
            ("<!-- yorum -->", .comment),
            ("<a", .tag), ("href", .property), ("x", .string), ("data-y", .property), ("'z'", .string),
            ("disabled", .property), (">", .tag), ("&amp;", .literal), ("</a", .tag), (">", .tag),
            ("<br", .tag), ("/>", .tag),
            ("<script", .tag), (">", .tag), ("</script", .tag), (">", .tag), ("<![CDATA[<x>]]>", .string),
        ])
    }

    @Test func css() {
        expectStyled("@media x { #id .c > a:hover { color: #fff !important; -webkit-x: 1.5em } }", .css, [
            ("@media", .keyword), ("#id", .type), (".c", .type), ("color", .property), ("#fff", .number), ("important", .keyword),
            ("-webkit-x", .property), ("1.5em", .number),
        ])
        expectStyled("#id .sınıf { margin: 0 auto } /* c */", .css, [
            ("#id", .type), (".sınıf", .type), ("margin", .property), ("0", .number), ("auto", .literal),
            ("/* c */", .comment),
        ])
    }

    @Test func cFamily() {
        expectStyled("#include <x.h>\nfn f<'a>(c: char) -> &'a str { let c = '\\n'; let d = 'ğ'; NULL }", .cFamily, [
            ("#include", .keyword), ("fn", .keyword), ("char", .keyword),
            ("let", .keyword), ("'\\n'", .string), ("let", .keyword), ("'ğ'", .string), ("NULL", .literal),
        ])
        expectStyled("s := `raw\n\"x`", .cFamily, [("`raw\n\"x`", .string)])
    }

    @Test func sqlIsCaseInsensitive() {
        expectStyled("SELECT * FROM t WHERE a = 'it''s' -- son\n/* b */ AND x IS NULL", .sql, [
            ("SELECT", .keyword), ("FROM", .keyword), ("WHERE", .keyword), ("'it'", .string), ("'s'", .string),
            ("-- son", .comment), ("/* b */", .comment), ("AND", .keyword), ("IS", .keyword), ("NULL", .literal),
        ])
    }

    @Test func toml() {
        expectStyled("[paket]\nad = \"x\" # c\n\"a b\" = true\nsürüm.alt = 1.0\n; ini", .toml, [
            ("[paket]", .tag), ("ad", .property), ("\"x\"", .string), ("# c", .comment), ("\"a b\"", .property),
            ("true", .literal), ("sürüm.alt", .property), ("1.0", .number), ("; ini", .comment),
        ])
    }

    @Test func unterminatedTokensStop() {
        expectStyled("\"açık\nlet x", .swift, [("\"açık", .string), ("let", .keyword)])
        expectStyled("/* açık\nlet x", .swift, [("/* açık\nlet x", .comment)])
        expectStyled("`açık", .javascript, [("`açık", .string)])
        expectStyled("<a href=\"x", .xml, [("<a", .tag), ("href", .property), ("\"x", .string)])
        expectStyled("<!-- açık", .xml, [("<!-- açık", .comment)])
        expectStyled("\"a\\", .json, [("\"a\\", .string)])
        for language in CodeLanguage.allCases {
            for text in ["\"", "'", "`", "/*", "<", "<!", "&", "#", "$", "${", "-", ".", "@", "\\", "a:", "[", "'\\"] {
                _ = CodeHighlighter.spans(in: text, language: language)
            }
        }
    }

    @Test func rangesAreUTF16() {
        let text = "let 😀🇹🇷 = \"ğüşİ 👍🏽\" // Çay ☕️\nvar ı = 1"
        let ns = text as NSString
        let spans = CodeHighlighter.spans(in: text, language: .swift)
        #expect(spans.map { ns.substring(with: $0.range) } == ["let", "\"ğüşİ 👍🏽\"", "// Çay ☕️", "var", "1"])
        #expect(spans[1].range == NSRange(location: 13, length: 11))
    }

    @Test func spansAreSortedAndDisjoint() {
        let text = "{\"a\": [1, \"x\", true]} // c\nfunc f() { \"\"\"\n\"\"\" }"
        for language in CodeLanguage.allCases where language != .markdown {
            let spans = CodeHighlighter.spans(in: text, language: language)
            for (a, b) in zip(spans, spans.dropFirst()) {
                #expect(NSMaxRange(a.range) <= b.range.location, "\(language)")
            }
        }
    }

    @Test func indentUnit() {
        #expect(CodeLanguage.json.indentUnit(for: "{\n    \"a\": {\n        \"b\": 1\n    }\n}") == "    ")
        #expect(CodeLanguage.cFamily.indentUnit(for: "func f() {\n\tx()\n\tif y {\n\t\tz()\n\t}\n}") == "\t")
        #expect(CodeLanguage.yaml.indentUnit(for: "a:\n\tb: 1\n\tc: 2") == "  ")
        #expect(CodeLanguage.swift.indentUnit(for: "") == "    ")
        #expect(CodeLanguage.json.indentUnit(for: "{}") == "  ")
    }

    /// Simulates editor keystrokes: outside `changedRange`, every character must keep its kind.
    @Test func changedRangeCoversEveryRestyledCharacter() {
        let samples: [(String, CodeLanguage)] = [
            ("let a = \"x\" // c\n/* b */ var ğ = 1\nfunc f() { \"\"\"\nç\n\"\"\" }\n", .swift),
            ("{\"a\": [1, true, \"ş\"], \"b\": null}\n", .json),
            ("a: 1\nrun: |\n  x: y\nb: 'c' # d\n", .yaml),
            ("<a href=\"x\">t &amp;</a><!-- c -->\n", .xml),
        ]
        let inserts = ["\"", "/*", "*/", "'", "x", "\n", "`", "<", ">", "#", " ", "😀", "|", "\"\"\""]
        var rng = SystemRandomNumberGenerator()
        for (sample, language) in samples {
            for _ in 0..<300 {
                let old = sample as NSString
                let start = Int.random(in: 0...old.length, using: &rng)
                let removed = Int.random(in: 0...min(3, old.length - start), using: &rng)
                let inserted = Bool.random(using: &rng) ? inserts.randomElement(using: &rng)! : ""
                let newText = old.replacingCharacters(in: NSRange(location: start, length: removed), with: inserted)
                let newLength = (newText as NSString).length
                let oldSpans = CodeHighlighter.spans(in: sample, language: language)
                let newSpans = CodeHighlighter.spans(in: newText, language: language)
                let insertedLength = (inserted as NSString).length
                let range = CodeHighlighter.changedRange(
                    from: oldSpans, to: newSpans, editedRange: NSRange(location: start, length: insertedLength),
                    changeInLength: insertedLength - removed, length: newLength)

                let oldKinds = kinds(oldSpans, length: old.length)
                let newKinds = kinds(newSpans, length: newLength)
                for x in 0..<newLength where !NSLocationInRange(x, range) {
                    let before = x < start ? x : x - (insertedLength - removed)
                    #expect(oldKinds[before] == newKinds[x], "\(language) \(newText.debugDescription) at \(x)")
                }
            }
        }
    }

    private func kinds(_ spans: [CodeSpan], length: Int) -> [CodeSpan.Kind?] {
        var result = [CodeSpan.Kind?](repeating: nil, count: length)
        for span in spans {
            for k in span.range.location..<NSMaxRange(span.range) { result[k] = span.kind }
        }
        return result
    }

    @Test func largeFileIsFast() {
        let block = """
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
        """
        let text = Array(repeating: block, count: 5_000 / 12).joined(separator: "\n")
        let json = "[" + Array(repeating: #"{"ad": "Çağlar", "sayı": -12.5e3, "ok": true, "x": null}"#, count: 5_000)
            .joined(separator: ",\n") + "]"
        let clock = ContinuousClock()
        var count = 0
        let elapsed = clock.measure {
            count = CodeHighlighter.spans(in: text, language: .swift).count
                + CodeHighlighter.spans(in: json, language: .json).count
        }
        #expect(count > 40_000)
        // Generous bound so debug builds pass too; release takes under 10 ms.
        #expect(elapsed < .seconds(1))
    }
}
