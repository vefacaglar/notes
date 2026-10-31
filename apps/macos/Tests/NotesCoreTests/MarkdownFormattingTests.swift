import Foundation
import Testing
@testable import NotesCore

struct MarkdownFormattingTests {
    private func apply(_ edit: TextEdit?, to text: String) -> String? {
        guard let edit else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        guard let sel = edit.selection else { return result }
        let ns = result as NSString
        if sel.length == 0 { return ns.replacingCharacters(in: sel, with: "|") }
        let closed = ns.replacingCharacters(in: NSRange(location: NSMaxRange(sel), length: 0), with: "⟧")
        return (closed as NSString).replacingCharacters(in: NSRange(location: sel.location, length: 0), with: "⟦")
    }

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

    private func inline(_ style: InlineStyle, _ marked: String) -> String? {
        let (text, sel) = split(marked)
        return apply(MarkdownEditing.toggleInline(style, in: text, selection: sel), to: text)
    }

    private func line(_ style: LineStyle, _ marked: String) -> String? {
        let (text, sel) = split(marked)
        return apply(MarkdownEditing.apply(style, in: text, selection: sel), to: text)
    }

    // MARK: Inline

    @Test func wrapsSelection() {
        #expect(inline(.bold, "a ⟦word⟧ b") == "a **⟦word⟧** b")
        #expect(inline(.italic, "⟦şğı İ⟧") == "*⟦şğı İ⟧*")
        #expect(inline(.strikethrough, "⟦x⟧") == "~~⟦x⟧~~")
        #expect(inline(.code, "⟦x⟧") == "`⟦x⟧`")
    }

    @Test func unwrapsOutsideAndInside() {
        #expect(inline(.bold, "**⟦word⟧**") == "⟦word⟧")
        #expect(inline(.bold, "⟦**word**⟧") == "⟦word⟧")
        #expect(inline(.code, "`⟦x⟧`") == "⟦x⟧")
    }

    @Test func boldAndItalicCombine() {
        #expect(inline(.italic, "**⟦a⟧**") == "***⟦a⟧***")
        #expect(inline(.bold, "*⟦a⟧*") == "***⟦a⟧***")
        #expect(inline(.italic, "***⟦a⟧***") == "**⟦a⟧**")
        #expect(inline(.bold, "***⟦a⟧***") == "*⟦a⟧*")
    }

    @Test func caretInWordWrapsTheWord() {
        #expect(inline(.bold, "say İstanbu|l now") == "say **İstanbu|l** now")
        #expect(inline(.bold, "say **İstanbu|l** now") == "say İstanbu|l now")
        #expect(inline(.italic, "|word") == "*|word*")
    }

    @Test func emptyCaretInsertsPairAndRemovesIt() {
        #expect(inline(.bold, "a | b") == "a **|** b")
        #expect(inline(.bold, "a **|** b") == "a | b")
        #expect(inline(.italic, "a | b") == "a *|* b")
    }

    @Test func surroundingWhitespaceStaysOutside() {
        #expect(inline(.bold, "⟦ a b ⟧") == " **⟦a b⟧** ")
    }

    @Test func eachLineIsWrappedAlone() {
        #expect(inline(.bold, "⟦one\ntwo⟧") == "**⟦one**\n**two⟧**")
        #expect(inline(.bold, "⟦**one**\n**two**⟧") == "⟦one\ntwo⟧")
    }

    @Test func emojiAndCRLF() {
        #expect(inline(.bold, "👨‍👩‍👧 ⟦ok⟧ 🎉") == "👨‍👩‍👧 **⟦ok⟧** 🎉")
        #expect(inline(.bold, "⟦a⟧\r\nb") == "**⟦a⟧**\r\nb")
        #expect(inline(.bold, "⟦a b\r\nc⟧") == "**⟦a b**\r\n**c⟧**")
    }

    // MARK: Lines

    @Test func bulletsToggleAndReplace() {
        #expect(line(.bullet, "|one") == "- |one")
        #expect(line(.bullet, "- |one") == "|one")
        #expect(line(.bullet, "⟦one\ntwo⟧") == "- ⟦one\n- two⟧")
        #expect(line(.bullet, "⟦- one\n- two⟧") == "⟦one\ntwo⟧")
        #expect(line(.bullet, "⟦- one\ntwo⟧") == "- ⟦one\n- two⟧")
    }

    @Test func numberedRenumbersAndReplacesOtherMarkers() {
        #expect(line(.numbered, "⟦- a\n- b\n- c⟧") == "1. ⟦a\n2. b\n3. c⟧")
        #expect(line(.numbered, "⟦1. a\n- b⟧") == "1. ⟦a\n2. b⟧")
        #expect(line(.numbered, "⟦5. a\n7. b⟧") == "⟦a\nb⟧")
        #expect(line(.bullet, "⟦1. a\n2. b⟧") == "- ⟦a\n- b⟧")
    }

    @Test func blankLinesAreSkipped() {
        #expect(line(.bullet, "⟦a\n\nb⟧") == "- ⟦a\n\n- b⟧")
        #expect(line(.numbered, "⟦a\n\nb⟧") == "1. ⟦a\n\n2. b⟧")
    }

    @Test func tasksAndQuotes() {
        #expect(line(.task, "|a") == "- [ ] |a")
        #expect(line(.task, "- [x] |a") == "|a")
        #expect(line(.task, "- |a") == "- [ ] |a")
        #expect(line(.bullet, "- [ ] |a") == "- |a")
        #expect(line(.quote, "⟦a\nb⟧") == "> ⟦a\n> b⟧")
        #expect(line(.quote, "⟦> a\n> b⟧") == "⟦a\nb⟧")
        #expect(line(.quote, "> - |a") == "- |a")
    }

    @Test func headingsReplaceAndToggle() {
        #expect(line(.heading(1), "|Başlık") == "# |Başlık")
        #expect(line(.heading(2), "# |Başlık") == "## |Başlık")
        #expect(line(.heading(2), "## |Başlık") == "|Başlık")
        #expect(line(.body, "### |Başlık") == "|Başlık")
        #expect(line(.body, "|plain") == nil)
        #expect(line(.heading(1), "- |item") == "# |item")
        #expect(line(.heading(3), "> |q") == "> ### |q")
    }

    @Test func lineStylesKeepIndentCRLFAndEmoji() {
        #expect(line(.bullet, "  |🎉 a") == "  - |🎉 a")
        #expect(line(.bullet, "⟦a\r\nb⟧") == "- ⟦a\r\n- b⟧")
        #expect(line(.numbered, "⟦a\r\nb\r\n⟧") == "1. ⟦a\r\n2. b\r\n⟧")
    }

    @Test func noLineStylesInsideCodeBlocks() {
        #expect(line(.bullet, "```\n|a\n```") == nil)
    }

    // MARK: Blocks

    @Test func codeBlockWrapsAndUnwraps() {
        #expect(apply(MarkdownEditing.codeBlock(in: "a\nb", selection: NSRange(location: 0, length: 3)), to: "a\nb") == "```\n⟦a\nb⟧\n```")
        #expect(apply(MarkdownEditing.codeBlock(in: "a", selection: NSRange(location: 0, length: 0)), to: "a") == "```\n⟦a⟧\n```")
        let fenced = "```swift\nlet a = 1\n```"
        #expect(apply(MarkdownEditing.codeBlock(in: fenced, selection: NSRange(location: 0, length: fenced.utf16.count)), to: fenced) == "⟦let a = 1⟧")
        #expect(apply(MarkdownEditing.codeBlock(in: "", selection: NSRange(location: 0, length: 0)), to: "") == "```\n|\n```")
        #expect(apply(MarkdownEditing.codeBlock(in: "a\r\nb", selection: NSRange(location: 0, length: 4)), to: "a\r\nb") == "```\r\n⟦a\r\nb⟧\r\n```")
        #expect(apply(MarkdownEditing.codeBlock(in: "```\nx\n```", selection: NSRange(location: 4, length: 1)), to: "```\nx\n```") != nil)
    }

    @Test func horizontalRule() {
        func rule(_ marked: String) -> String? {
            let (text, sel) = split(marked)
            return apply(MarkdownEditing.horizontalRule(in: text, selection: sel), to: text)
        }
        #expect(rule("a|") == "a\n\n---\n|")
        #expect(rule("a|\nb") == "a\n\n---\n|\nb")
        #expect(rule("a\n|") == "a\n\n---\n|")
        #expect(rule("|") == "---\n|")
        #expect(rule("a\n\n|") == "a\n\n---\n|")
        #expect(rule("```\n|a\n```") == nil)
    }

    @Test func activeFormat() {
        func active(_ marked: String) -> ActiveFormat {
            let (text, sel) = split(marked)
            return MarkdownEditing.activeFormat(in: text, selection: sel)
        }
        #expect(active("## ti|tle").heading == 2)
        #expect(active("**bo|ld**").inline == [.bold])
        #expect(active("***bo|ld***").inline == [.bold, .italic])
        #expect(active("- [ ] a|").task)
        #expect(active("1. a|").numbered)
        #expect(active("> a|").quote)
        #expect(active("plain|") == ActiveFormat())
    }
}
