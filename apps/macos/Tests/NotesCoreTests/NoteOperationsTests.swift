import Foundation
import Testing
@testable import NotesCore

/// Serialized: some tests switch the naming language, which is process-wide.
@Suite(.serialized)
struct NoteOperationsTests {
    let root: URL
    let store: NoteStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NoteOpsTests-\(UUID().uuidString)")
        store = try NoteStore(root: root)
    }

    private func put(_ path: String, _ text: String = "") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    @Test func moveIntoFolderKeepsContent() throws {
        try put("a.md", "hello")
        try put("Work/x.md")
        #expect(try store.move("a.md", to: "Work") == "Work/a.md")
        #expect(!exists("a.md"))
        #expect(try store.read("Work/a.md") == "hello")
    }

    @Test func moveToRootAndNoOp() throws {
        try put("Work/a.md", "x")
        #expect(try store.move("Work/a.md", to: "Work") == "Work/a.md")
        #expect(try store.move("Work/a.md", to: nil) == "a.md")
        #expect(exists("a.md"))
    }

    @Test func moveNeverOverwritesAndNumbersTheName() throws {
        try put("a.md", "new")
        try put("Work/a.md", "old")
        try put("Work/a 2.md", "older")
        #expect(try store.move("a.md", to: "Work") == "Work/a 3.md")
        #expect(try store.read("Work/a.md") == "old")
        #expect(try store.read("Work/a 3.md") == "new")
    }

    @Test func moveFolderNumbersWithoutExtension() throws {
        try put("Plans/p.md")
        try put("Work/Plans/q.md")
        #expect(try store.move("Plans", to: "Work") == "Work/Plans 2")
        #expect(exists("Work/Plans 2/p.md"))
    }

    @Test func moveRejectsItselfAndDescendants() throws {
        try put("A/B/x.md")
        #expect(throws: NoteStoreError.self) { try store.move("A", to: "A") }
        #expect(throws: NoteStoreError.self) { try store.move("A", to: "A/B") }
        #expect(exists("A/B/x.md"))
    }

    @Test func moveToMissingFolderThrows() throws {
        try put("a.md")
        #expect(throws: NoteStoreError.missingFolder("Gone")) { try store.move("a.md", to: "Gone") }
        #expect(exists("a.md"))
    }

    @Test func moveAcrossStores() throws {
        let other = try NoteStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("NoteOpsTests-\(UUID().uuidString)"))
        try put("Turkish/Toplantı ışık.md", "ı")
        try Data().write(to: other.root.appendingPathComponent("Toplantı ışık.md"))
        let moved = try store.move("Turkish/Toplantı ışık.md", to: nil, in: other)
        #expect(moved == "Toplantı ışık 2.md")
        #expect(try other.read(moved) == "ı")
        #expect(!exists("Turkish/Toplantı ışık.md"))
    }

    @Test func duplicateNamesCopy() throws {
        NamingLanguage.configure(localization: "en")
        try put("Plan.md", "text")
        #expect(try store.duplicate("Plan.md") == "Plan copy.md")
        #expect(try store.duplicate("Plan.md") == "Plan copy 2.md")
        #expect(try store.duplicate("Plan copy.md") == "Plan copy copy.md")
        #expect(try store.read("Plan copy 2.md") == "text")
    }

    @Test func duplicateInFolderAndTurkish() throws {
        try put("Work/Plan.md")
        try put("Work/config.json", "{}")
        NamingLanguage.configure(localization: "tr")
        defer { NamingLanguage.configure(localization: "en") }
        #expect(try store.duplicate("Work/Plan.md") == "Work/Plan kopya.md")
        #expect(try store.duplicate("Work/config.json") == "Work/config kopya.json")
    }

    @Test func copyInFileAndFolder() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("Outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("Dir"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: outside.appendingPathComponent("n.md"))
        try Data("b".utf8).write(to: outside.appendingPathComponent("Dir/m.md"))
        try put("n.md", "mine")
        #expect(try store.copyIn(outside.appendingPathComponent("n.md"), to: nil) == "n 2.md")
        #expect(try store.read("n.md") == "mine")
        #expect(try store.copyIn(outside.appendingPathComponent("Dir"), to: nil) == "Dir")
        #expect(try store.copyIn(outside.appendingPathComponent("Dir"), to: nil) == "Dir 2")
        #expect(try store.read("Dir 2/m.md") == "b")
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("n.md").path))
    }

    @Test func copyInRejectsHiddenAndOwnAncestor() throws {
        try put("Parent/Child/x.md")
        #expect(throws: NoteStoreError.self) { try store.copyIn(root.appendingPathComponent("Parent"), to: "Parent/Child") }
        let hidden = root.appendingPathComponent(".hidden.md")
        try Data().write(to: hidden)
        #expect(throws: NoteStoreError.self) { try store.copyIn(hidden, to: "Parent") }
    }

    @Test func treeCarriesModificationDates() throws {
        try put("a.md")
        try put("Work/b.md")
        let tree = store.tree()
        #expect(tree[0].modified == nil)
        #expect(tree[1].modified != nil)
    }
}
