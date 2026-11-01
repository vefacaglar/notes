import Foundation
import Testing
@testable import NotesCore

struct MarkdownTableTests {
    /// Text with the caret `¦` or selection `⟦⟧` marked (pipes are table syntax, so `|` can not be the caret).
    private func split(_ marked: String) -> (String, NSRange) {
        var text = marked
        let open = (text as NSString).range(of: "⟦")
        if open.location != NSNotFound {
            text = text.replacingOccurrences(of: "⟦", with: "")
            let close = (text as NSString).range(of: "⟧")
            text = text.replacingOccurrences(of: "⟧", with: "")
            return (text, NSRange(location: open.location, length: close.location - open.location))
        }
        let at = (text as NSString).range(of: "¦")
        text = text.replacingOccurrences(of: "¦", with: "")
        return (text, NSRange(location: at.location, length: 0))
    }

    private func run(_ marked: String, _ make: (String, NSRange) -> TextEdit?) -> String? {
        let (text, sel) = split(marked)
        guard let edit = make(text, sel) else { return nil }
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        guard let s = edit.selection else { return result }
        let ns = result as NSString
        if s.length == 0 { return ns.replacingCharacters(in: s, with: "¦") }
        let closed = ns.replacingCharacters(in: NSRange(location: NSMaxRange(s), length: 0), with: "⟧")
        return (closed as NSString).replacingCharacters(in: NSRange(location: s.location, length: 0), with: "⟦")
    }

    @Test func detectsTables() {
        func rows(_ text: String) -> Int? { MarkdownTable.rows(in: Array(text.utf16), at: 0)?.count }
        #expect(rows("| a | b |\n| - | - |\n| 1 | 2 |") == 3)
        #expect(rows("a | b\n:-: | --:\n1 | 2") == 3)
        #expect(rows("| a | b |\n| - | - |\n\n| 1 | 2 |") == 2)
        #expect(rows("| a | b |\n| - |\n") == nil)
        #expect(rows("a | b\n---") == nil)
        #expect(rows("    | a |\n| - |") == nil)
        #expect(rows("| a |\r\n| - |\r\n| 1 |") == 3)
    }

    @Test func cellsRespectEscapesAndCodeSpans() {
        let text = "| a \\| b | `x|y` | z |"
        let row = MarkdownTable.row(Array(text.utf16), from: 0)
        #expect(row.cells.count == 3)
        #expect(row.pipes.count == 4)
        let units = Array(text.utf16)
        let cells = row.cells.map { String(decoding: units[$0.location..<NSMaxRange($0)], as: UTF16.self) }
        #expect(cells == ["a \\| b", "`x|y`", "z"])
    }

    @Test func tabMovesAndAligns() {
        let tab = { (text: String, back: Bool) in self.run(text) { MarkdownTable.tab(in: $0, selection: $1, backward: back) } }
        #expect(tab("|a¦|bb|\n|-|-|\n|1|2|", false) == "| a   | ⟦bb⟧  |\n| --- | --- |\n| 1   | 2   |")
        #expect(tab("| a | b |\n| --- | --- |\n| 1 | 2¦ |", false)
            == "| a   | b   |\n| --- | --- |\n| 1   | 2   |\n| ¦    |     |")
        #expect(tab("| a¦ | b |\n| --- | --- |", true) == nil)
        #expect(tab("| a | b¦ |\n| --- | --- |\n| 1 | 2 |", true) == "| ⟦a⟧   | b   |\n| --- | --- |\n| 1   | 2   |")
        #expect(tab("plain¦ text", false) == nil)
        #expect(tab("| a | b¦ |\n| --- | --- |\n| 1 | 2 |", false) == "| a   | b   |\n| --- | --- |\n| ⟦1⟧   | 2   |")
    }

    @Test func tabOnAlignedTableOnlyMovesTheSelection() {
        let text = "| a   | b   |\n| --- | --- |\n| 1   | 2   |"
        let edit = MarkdownTable.tab(in: text, selection: NSRange(location: 3, length: 0), backward: false)
        #expect(edit?.replacement == "")
        #expect(edit?.range.length == 0)
        #expect(edit?.selection == NSRange(location: 8, length: 1))
    }

    @Test func returnAddsRowAndExits() {
        let enter = { (text: String) in self.run(text) { MarkdownTable.newline(in: $0, selection: $1) } }
        #expect(enter("| a | b |\n| --- | --- |\n| 1¦ | 2 |")
            == "| a   | b   |\n| --- | --- |\n| 1   | 2   |\n| ¦    |     |")
        #expect(enter("| a¦ | b |\n| --- | --- |\n| 1 | 2 |")
            == "| a   | b   |\n| --- | --- |\n| ¦    |     |\n| 1   | 2   |")
        #expect(enter("| a | b |\n| --- | --- |\n| 1 | 2 |\n|  ¦ |  |") == "| a   | b   |\n| --- | --- |\n| 1   | 2   |\n¦")
        #expect(enter("| a | b |\n| --- | --- |\n| 1 | 2 |\n|  ¦ |  |\nnext") == "| a   | b   |\n| --- | --- |\n| 1   | 2   |\n¦\nnext")
        #expect(enter("| a | b |\n|¦ --- | --- |") == nil)
        #expect(enter("no table¦") == nil)
    }

    @Test func turkishEmojiAndWideTextAlign() {
        let out = run("| İş | Ğ¦ |\n|-|-|\n| 🎉 | 日本 |") { MarkdownTable.tab(in: $0, selection: $1, backward: false) }
        #expect(out == "| İş  | Ğ    |\n| --- | ---- |\n| ⟦🎉⟧  | 日本 |")
    }

    @Test func crlfIsKept() {
        let out = run("| a¦ |\r\n| - |\r\n| 1 |\r\nnext") { MarkdownTable.newline(in: $0, selection: $1) }
        #expect(out == "| a   |\r\n| --- |\r\n| ¦    |\r\n| 1   |\r\nnext")
    }

    @Test func escapedPipeAndCodeSpanStayInTheirCell() {
        let out = run("| a¦ | `x|y` | c \\| d |\n|-|-|-|") { MarkdownTable.tab(in: $0, selection: $1, backward: false) }
        #expect(out == "| a   | ⟦`x|y`⟧ | c \\| d |\n| --- | ----- | ------ |")
    }

    @Test func commands() {
        let t = "| a¦ | b |\n| :-- | --: |\n| 1 | 2 |"
        let go = { (command: TableCommand) in self.run(t) { MarkdownTable.perform(command, in: $0, selection: $1) } }
        #expect(go(.addRow(above: false)) == "| a   |   b |\n| :-- | --: |\n| ¦    |     |\n| 1   |   2 |")
        #expect(go(.addRow(above: true)) == nil)
        #expect(go(.addColumn(before: false)) == "| a   | ¦    |   b |\n| :-- | --- | --: |\n| 1   |     |   2 |")
        #expect(go(.addColumn(before: true)) == "| ¦    | a   |   b |\n| --- | :-- | --: |\n|     | 1   |   2 |")
        #expect(go(.deleteColumn) == "|   ¦b |\n| --: |\n|   2 |")
        #expect(go(.align(.center)) == "|  a¦  |   b |\n| :-: | --: |\n|  1  |   2 |")
        #expect(go(.align(.none)) == "| a¦   |   b |\n| --- | --: |\n| 1   |   2 |")
        #expect(go(.deleteRow) == nil)
        #expect(run("| a | b |\n| --- | --- |\n| 1¦ | 2 |") { MarkdownTable.perform(.deleteRow, in: $0, selection: $1) }
            == "| ¦a   | b   |\n| --- | --- |")
        #expect(run("| a | b¦ |\n| --- | --- |\n| 1 | 2 |") { MarkdownTable.perform(.deleteColumn, in: $0, selection: $1) }
            == "| ¦a   |\n| --- |\n| 1   |")
    }

    @Test func insertsTableWithCaretInFirstHeaderCell() {
        #expect(run("intro¦") { MarkdownTable.insert(rows: 2, columns: 2, in: $0, selection: $1) }
            == "intro\n\n| ¦    |     |\n| --- | --- |\n|     |     |\n")
        #expect(run("¦") { MarkdownTable.insert(rows: 1, columns: 1, in: $0, selection: $1) } == "| ¦    |\n| --- |\n")
        #expect(run("```\n¦\n```") { MarkdownTable.insert(rows: 2, columns: 2, in: $0, selection: $1) } == nil)
    }

    @Test func convertsTabAndCSVLines() {
        let convert = { (text: String) in self.run(text) { MarkdownTable.convertSelection(in: $0, selection: $1) } }
        #expect(convert("⟦Ad\tŞehir\nAli\tİzmir⟧") == "| ⟦Ad⟧  | Şehir |\n| --- | ----- |\n| Ali | İzmir |")
        #expect(convert("⟦a,\"b,c\",d\n1,2,3⟧") == "| ⟦a⟧   | b,c | d   |\n| --- | --- | --- |\n| 1   | 2   | 3   |")
        #expect(convert("⟦no separator⟧") == nil)
        #expect(convert("⟦x|y,z⟧")?.contains("x\\|y") == true)
        #expect(convert("text\n⟦a,b⟧")?.hasPrefix("text\n\n| ⟦a⟧") == true)
    }
}

struct TableRenderingTests {
    @Test func gridSplitsRowsAndAlignments() throws {
        let text = "x\n| Ad | Şehir |\n| :-- | --: |\n| 🎉 | `a|b` |\n\nson"
        let grid = try #require(MarkdownTable.grid(in: String(text.dropFirst(2)), offsetBy: 2))
        let ns = text as NSString
        #expect(grid.alignments == [.left, .right])
        #expect(grid.rows.count == 2)
        #expect(grid.rows[0].cells.map { ns.substring(with: $0) } == ["Ad", "Şehir"])
        #expect(grid.rows[1].cells.map { ns.substring(with: $0) } == ["🎉", "`a|b`"])
        #expect(ns.substring(with: grid.delimiter) == "| :-- | --: |")
        #expect(ns.substring(with: grid.rows[1].line) == "| 🎉 | `a|b` |")
        #expect(grid.columns == 2)
    }

    @Test func noGridWithoutDelimiterRow() {
        #expect(MarkdownTable.grid(in: "a | b\nc | d") == nil)
    }

    @Test func columnWidthsAndSlack() {
        #expect(TableMetrics.columnWidths([[10, 4], [6], [8, 12]], columns: 2) == [10, 12])
        #expect(TableMetrics.slack(cell: 4, column: 10, alignment: .none) == (0, 6))
        #expect(TableMetrics.slack(cell: 4, column: 10, alignment: .right) == (6, 0))
        #expect(TableMetrics.slack(cell: 4, column: 10, alignment: .center) == (3, 3))
        #expect(TableMetrics.slack(cell: 12, column: 10, alignment: .center) == (0, 0))
    }

    @Test func codeBlockText() {
        func code(_ text: String) -> String { MarkdownCodeBlock.code(in: text, block: NSRange(location: 0, length: text.utf16.count)) }
        #expect(code("```swift\nlet a = 1\n\nlet b = 2\n```") == "let a = 1\n\nlet b = 2")
        #expect(code("~~~\n```\nx\n~~~") == "```\nx")
        #expect(code("```\nunclosed\nlast\n") == "unclosed\nlast")
        #expect(code("```\n```") == "")
        #expect(code("```\r\na\r\n```") == "a")
        #expect(code("````\n```\n````") == "```")
        #expect(code("\t```\nx\n\t```") == "x")
    }
}
