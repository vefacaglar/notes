import Foundation
import Testing
@testable import NotesCore

struct MarkdownEditingTests {
    /// The text after the edit, with the new caret as `|` or the new selection in `⟦⟧`; nil when there is no edit.
    private func apply(_ edit: TextEdit?, to text: String) -> String? {
        guard let edit else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        guard let sel = edit.selection else { return result }
        let ns = result as NSString
        if sel.length == 0 { return ns.replacingCharacters(in: sel, with: "|") }
        let closed = ns.replacingCharacters(in: NSRange(location: NSMaxRange(sel), length: 0), with: "⟧")
        return (closed as NSString).replacingCharacters(in: NSRange(location: sel.location, length: 0), with: "⟦")
    }

    /// Text with the caret (`|`) or selection (`⟦⟧`) marked, split into the text and the range.
    private func split(_ marked: String) -> (String, NSRange) {
        var text = marked
        let open = (text as NSString).range(of: "⟦")
        if open.location != NSNotFound {
            text = text.replacingOccurrences(of: "⟦", with: "")
            let close = (text as NSString).range(of: "⟧")
            text = text.replacingOccurrences(of: "⟧", with: "")
            return (text, NSRange(location: open.location, length: close.location - open.location))
        }
        let caret = (text as NSString).range(of: "|")
        text = text.replacingOccurrences(of: "|", with: "")
        return (text, NSRange(location: caret.location, length: 0))
    }

    private func newline(_ marked: String) -> String? {
        let (text, sel) = split(marked)
        return apply(MarkdownEditing.newline(in: text, selection: sel), to: text)
    }

    private func tab(_ marked: String, outdent: Bool = false) -> String? {
        let (text, sel) = split(marked)
        return apply(MarkdownEditing.indent(in: text, selection: sel, outdent: outdent), to: text)
    }

    @Test func bulletsContinue() {
        #expect(newline("- bir|") == "- bir\n- |")
        #expect(newline("* bir|") == "* bir\n* |")
        #expect(newline("+ bir|") == "+ bir\n+ |")
        #expect(newline("  - iç|") == "  - iç\n  - |")
        #expect(newline("\t- sekme|") == "\t- sekme\n\t- |")
        #expect(newline("önce\n- bir|\nsonra") == "önce\n- bir\n- |\nsonra")
    }

    @Test func splitsTheItemAtTheCaret() {
        #expect(newline("- şeker|pare") == "- şeker\n- |pare")
        #expect(newline("- 🙂 gül|ümse") == "- 🙂 gül\n- |ümse")
    }

    @Test func orderedItemsCountUp() {
        #expect(newline("1. a|") == "1. a\n2. |")
        #expect(newline("9) a|") == "9) a\n10) |")
        #expect(newline("  10. a|") == "  10. a\n  11. |")
    }

    @Test func tasksContinueUnchecked() {
        #expect(newline("- [ ] a|") == "- [ ] a\n- [ ] |")
        #expect(newline("- [x] ğ|") == "- [x] ğ\n- [ ] |")
        #expect(newline("1. [X] a|") == "1. [X] a\n2. [ ] |")
    }

    @Test func quotesContinue() {
        #expect(newline("> alıntı|") == "> alıntı\n> |")
        #expect(newline("> > iç|") == "> > iç\n> > |")
        #expect(newline(">sıkı|") == ">sıkı\n> |")
        #expect(newline("> - madde|") == "> - madde\n> - |")
    }

    @Test func emptyItemEndsTheList() {
        #expect(newline("- a\n- |") == "- a\n|")
        #expect(newline("- a\n  - |") == "- a\n|")
        #expect(newline("1. a\n2. |") == "1. a\n|")
        #expect(newline("- [ ] |") == "|")
        #expect(newline("> a\n> |") == "> a\n|")
        #expect(newline("> - |") == "> |")
        #expect(newline("- a\n-   |") == "- a\n|")
    }

    @Test func plainReturnWhereNothingContinues() {
        #expect(newline("düz metin|") == nil)
        #expect(newline("-|") == nil)
        #expect(newline("2025.|") == nil)
        #expect(newline("---|") == nil)
        #expect(newline("- - -|") == nil)
        #expect(newline("***|") == nil)
        #expect(newline("-x|") == nil)
        #expect(newline("|- a") == nil)
        #expect(newline("-| a") == nil)
        #expect(newline("⟦- a⟧") == nil)
        #expect(newline("```\n- a|\n```") == nil)
        #expect(newline("```\n- a\n```\n- b|") == "```\n- a\n```\n- b\n- |")
    }

    @Test func handlesCRLFLines() {
        // A CR before the LF is not content: an item holding only the marker still ends the list.
        let text = "- a\r\n- \r\n"
        let edit = MarkdownEditing.newline(in: text, selection: NSRange(location: 7, length: 0))
        #expect(edit?.range == NSRange(location: 5, length: 2))
        #expect(edit?.replacement == "")
        let item = MarkdownEditing.newline(in: "- a\r\nx", selection: NSRange(location: 3, length: 0))
        #expect(item?.replacement == "\n- ")
    }

    @Test func rangesAreUTF16() {
        let text = "😀 - x\n- 😀 y"
        let caret = (text as NSString).length
        let edit = MarkdownEditing.newline(in: text, selection: NSRange(location: caret, length: 0))
        #expect(edit?.range == NSRange(location: caret, length: 0))
        #expect(edit?.selection == NSRange(location: caret + 3, length: 0))
    }

    @Test func indentsBulletsByTwoAndOrderedByMarkerWidth() {
        #expect(tab("- a|") == "  - a|")
        #expect(tab("- [ ] a|") == "  - [ ] a|")
        #expect(tab("|1. a") == "   |1. a")
        #expect(tab("10. a|") == "    10. a|")
        #expect(tab("- a|b") == "  - a|b")
        #expect(tab("> - a|") == ">   - a|")
    }

    @Test func outdents() {
        #expect(tab("  - a|", outdent: true) == "- a|")
        #expect(tab("    - a|", outdent: true) == "  - a|")
        #expect(tab(" - a|", outdent: true) == "- a|")
        #expect(tab("\t- a|", outdent: true) == "- a|")
        #expect(tab("   1. a|", outdent: true) == "1. a|")
        #expect(tab("- a|", outdent: true) == nil)
    }

    @Test func indentsEverySelectedLine() {
        #expect(tab("- ⟦a\n- b\n- c⟧") == "  - ⟦a\n  - b\n  - c⟧")
        #expect(tab("- ⟦a\n- b\n⟧- c") == "  - ⟦a\n  - b\n⟧- c")
        #expect(tab("  - ⟦a\n- b⟧", outdent: true) == "- ⟦a\n- b⟧")
        #expect(tab("- ığ⟦ü\n- şö⟧") == "  - ığ⟦ü\n  - şö⟧")
    }

    @Test func notAListMeansNoIndentOverride() {
        #expect(tab("düz|") == nil)
        #expect(tab("- a\n⟦düz\n- b⟧") == nil)
        #expect(tab("```\n- a|\n```") == nil)
    }

    @Test func linkWrapsSelection() {
        func link(_ marked: String) -> String? {
            let (text, sel) = split(marked)
            return apply(MarkdownEditing.link(in: text, selection: sel), to: text)
        }
        #expect(link("a ⟦şiir⟧ b") == "a [şiir](|) b")
        #expect(link("a | b") == "a [|]() b")
        #expect(link("⟦https://x.com/ğ⟧") == "[|](https://x.com/ğ)")
        #expect(link("⟦😀⟧") == "[😀](|)")
    }

    @Test func togglesTaskBoxes() {
        let text = "- [ ] bir\n- [x] iki\n```\n- [ ] kod\n```"
        func toggled(_ at: Int) -> String? {
            MarkdownEditing.toggleTask(in: text, at: at).map { (text as NSString).replacingCharacters(in: $0.range, with: $0.replacement) }
        }
        #expect(toggled(2) == "- [x] bir\n- [x] iki\n```\n- [ ] kod\n```")
        #expect(toggled(4) == "- [x] bir\n- [x] iki\n```\n- [ ] kod\n```")
        #expect(toggled(12) == "- [ ] bir\n- [ ] iki\n```\n- [ ] kod\n```")
        #expect(toggled(6) == nil)
        #expect(toggled(0) == nil)
        let inCode = (text as NSString).range(of: "[ ] kod").location
        #expect(toggled(inCode) == nil)
    }
}
