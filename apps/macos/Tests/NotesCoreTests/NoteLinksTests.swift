import Foundation
import Testing
@testable import NotesCore

struct NoteLinksTests {
    @Test func classifiesDestinations() {
        #expect(NoteLinks.classify("https://example.com/a?b=1#c") == .web(URL(string: "https://example.com/a?b=1#c")!))
        #expect(NoteLinks.classify("mailto:a@b.co") == .web(URL(string: "mailto:a@b.co")!))
        #expect(NoteLinks.classify("Plan%C4%B1.md") == .file("Planı.md"))
        #expect(NoteLinks.classify("../Gün lük/not.md#başlık") == .file("../Gün lük/not.md"))
        #expect(NoteLinks.classify("x.md?a=b") == .file("x.md"))
        #expect(NoteLinks.classify("/tmp/x.md") == .file("/tmp/x.md"))
        #expect(NoteLinks.classify("C:\\x.md") == .file("C:\\x.md"))
        #expect(NoteLinks.classify("#anchor") == nil)
        #expect(NoteLinks.classify("  ") == nil)
        #expect(NoteLinks.classify("[[Alışveriş Listesi]]") == .wiki("Alışveriş Listesi"))
        #expect(NoteLinks.classify("[[Not|takma ad]]") == .wiki("Not"))
        #expect(NoteLinks.classify("[[Not#Başlık]]") == .wiki("Not"))
        #expect(NoteLinks.classify("[[ ]]") == nil)
    }

    private let candidates = [
        NoteRef(root: 0, path: "Work/Plan.md"),
        NoteRef(root: 0, path: "Work/Sub/Plan.md"),
        NoteRef(root: 0, path: "Ev/Alışveriş.md"),
        NoteRef(root: 0, path: "config.json"),
        NoteRef(root: 1, path: "Plan.md"),
        NoteRef(root: 1, path: "Ev/Alışveriş.md"),
    ]

    @Test func resolvesRelativeFiles() {
        let origin = NoteRef(root: 0, path: "Work/Sub/a.md")
        #expect(NoteLinks.resolve(.file("Plan.md"), from: origin, among: candidates) == candidates[1])
        #expect(NoteLinks.resolve(.file("../Plan.md"), from: origin, among: candidates) == candidates[0])
        #expect(NoteLinks.resolve(.file("../../Ev/alışveriş.md"), from: origin, among: candidates) == candidates[2])
        #expect(NoteLinks.resolve(.file("../Plan"), from: origin, among: candidates) == candidates[0])
        #expect(NoteLinks.resolve(.file("./../../config.json"), from: origin, among: candidates) == candidates[3])
        #expect(NoteLinks.resolve(.file("../../../Plan.md"), from: origin, among: candidates) == nil)
        #expect(NoteLinks.resolve(.file("yok.md"), from: origin, among: candidates) == nil)
        #expect(NoteLinks.resolve(.file("Plan.md"), from: nil, among: candidates) == nil)
        #expect(NoteLinks.resolve(.file("/Plan.md"), from: origin, among: candidates) == nil)
    }

    @Test func relativeFilesStayInTheirRoot() {
        let origin = NoteRef(root: 1, path: "Ev/a.md")
        #expect(NoteLinks.resolve(.file("../Plan.md"), from: origin, among: candidates) == candidates[4])
        #expect(NoteLinks.resolve(.file("Alışveriş.md"), from: origin, among: candidates) == candidates[5])
    }

    @Test func wikiLinksIgnoreCaseAndPreferNearby() {
        let origin = NoteRef(root: 0, path: "Work/Sub/a.md")
        #expect(NoteLinks.resolve(.wiki("plan"), from: origin, among: candidates) == candidates[1])
        #expect(NoteLinks.resolve(.wiki("PLAN"), from: NoteRef(root: 0, path: "Work/b.md"), among: candidates) == candidates[0])
        // Same root before other roots, shorter path first.
        #expect(NoteLinks.resolve(.wiki("plan"), from: NoteRef(root: 0, path: "Ev/c.md"), among: candidates) == candidates[0])
        #expect(NoteLinks.resolve(.wiki("plan"), from: NoteRef(root: 1, path: "x.md"), among: candidates) == candidates[4])
        #expect(NoteLinks.resolve(.wiki("ALIŞVERİŞ"), from: nil, among: candidates) == candidates[2])
        #expect(NoteLinks.resolve(.wiki("Alışveriş.md"), from: origin, among: candidates) == candidates[2])
        #expect(NoteLinks.resolve(.wiki("ev/alışveriş"), from: NoteRef(root: 1, path: "x.md"), among: candidates) == candidates[5])
        #expect(NoteLinks.resolve(.wiki("config.json"), from: origin, among: candidates) == candidates[3])
        #expect(NoteLinks.resolve(.wiki("config"), from: origin, among: candidates) == nil)
        #expect(NoteLinks.resolve(.wiki("yok"), from: origin, among: candidates) == nil)
    }

    @Test func foldsTurkishLetters() {
        #expect(NoteLinks.foldedName("ÇALIŞMA") == NoteLinks.foldedName("çalışma"))
        #expect(NoteLinks.foldedName("İstanbul") == NoteLinks.foldedName("istanbul"))
        #expect(NoteLinks.foldedName("e\u{301}") == NoteLinks.foldedName("\u{E9}"))
    }

    @Test func detectsRootEscapeAndPrograms() {
        let note = NoteRef(root: 0, path: "a/b/n.md")
        #expect(NoteLinks.escapesRoot("../../x.md", from: note) == false)
        #expect(NoteLinks.escapesRoot("../../../x.md", from: note))
        #expect(NoteLinks.escapesRoot("c/../../../x.md", from: note) == false)
        #expect(NoteLinks.escapesRoot("../../../../x.md", from: note))
        #expect(NoteLinks.escapesRoot("../x.md", from: NoteRef(root: 0, path: "n.md")))
        #expect(NoteLinks.isProgram(fileName: "Setup.COMMAND"))
        #expect(NoteLinks.isProgram(fileName: "tool.ps1"))
        #expect(!NoteLinks.isProgram(fileName: "notes.md"))
        #expect(!NoteLinks.isProgram(fileName: "app"))
    }

    @Test func schemeNeedsTwoCharactersLettersDigitsAndSigns() {
        #expect(NoteLinks.classify("v2:notes.md") == .web(URL(string: "v2:notes.md")!))
        #expect(NoteLinks.classify("C:\\x.md") == .file("C:\\x.md"))
        #expect(NoteLinks.classify("2a:x") == .file("2a:x"))
    }

    @Test func outlineEntriesPointAtTheLineStart() {
        let text = "intro\n   ### Çalışma 😀 ###\n# Üst\r\n"
        let headings = MarkdownOutline.headings(in: text)
        #expect(headings.map(\.title) == ["Çalışma 😀", "Üst"])
        #expect(headings[0].location == 6)
        #expect(headings[1].location == (text as NSString).range(of: "# Üst").location)
    }
}
