import Foundation
import Testing
@testable import NotesCore

struct NoteStoreTests {
    let root: URL
    let store: NoteStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NoteStoreTests-\(UUID().uuidString)")
        store = try NoteStore(root: root)
    }

    private func put(_ path: String, _ text: String = "") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func treeListsFoldersFirstAndSkipsHiddenAndNonMarkdown() throws {
        try put("b.md")
        try put("a.md")
        try put("image.png")
        try put(".hidden.md")
        try put(".git/config")
        try put("Work/plan.md")

        let tree = store.tree()
        #expect(tree.map(\.path) == ["Work", "a.md", "b.md"])
        #expect(tree[0].children?.map(\.path) == ["Work/plan.md"])
        #expect(tree[1].name == "a")
        #expect(tree[1].children == nil)
    }

    @Test func createWriteReadRoundTrip() throws {
        let path = try store.createNote(named: "  Günlük  ", in: "Kişisel")
        #expect(path == "Kişisel/Günlük.md")
        #expect(try store.read(path) == "")

        try store.write("# Başlık\nçğıöşü\n", to: path)
        #expect(try store.read(path) == "# Başlık\nçğıöşü\n")
    }

    @Test func createRejectsDuplicates() throws {
        try store.createNote(named: "a")
        #expect(throws: NoteStoreError.alreadyExists("a.md")) { try store.createNote(named: "a.md") }
        try store.createFolder(named: "F")
        #expect(throws: NoteStoreError.alreadyExists("F")) { try store.createFolder(named: "F") }
    }

    @Test(arguments: ["", "../escape", "a/../b", ".hidden", "a:b", "a?b", "trailing.", "x/ /y"])
    func rejectsInvalidPaths(path: String) {
        #expect(throws: NoteStoreError.invalidName(path)) { try store.url(for: path) }
    }

    @Test func renameKeepsExtensionAndFolder() throws {
        try put("Work/old.md", "x")
        let newPath = try store.rename("Work/old.md", to: "new")
        #expect(newPath == "Work/new.md")
        #expect(try store.read(newPath) == "x")
        #expect(store.modificationDate("Work/old.md") == nil)
    }

    @Test func renameChangingOnlyCase() throws {
        try put("note.md", "x")
        let newPath = try store.rename("note.md", to: "Note")
        #expect(newPath == "Note.md")
        #expect(store.notePaths() == ["Note.md"])
    }

    @Test func renameRejectsExistingTargetAndSlashes() throws {
        try put("a.md")
        try put("b.md")
        #expect(throws: NoteStoreError.alreadyExists("b.md")) { try store.rename("a.md", to: "b") }
        #expect(throws: NoteStoreError.invalidName("x/y")) { try store.rename("a.md", to: "x/y") }
    }

    @Test func searchMatchesNamesThenLinesIgnoringCaseAndDiacritics() throws {
        try put("Toplantı.md", "gündem\n")
        try put("other.md", "ilk satır\nTOPLANTI notları\nson")

        let hits = store.search("toplanti")
        #expect(hits.map(\.path) == ["Toplantı.md", "other.md"])
        #expect(hits[0].line == nil)
        #expect(hits[1].line == 2)
        #expect(hits[1].snippet == "TOPLANTI notları")
        #expect(store.search("   ").isEmpty)
    }
}
