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

    @Test func treeListsFoldersFirstAndSkipsHiddenAndUnknownFiles() throws {
        try put("b.md")
        try put("a.md")
        try put("image.png")
        try put("Makefile")
        try put(".hidden.md")
        try put(".git/config")
        try put("Work/plan.md")

        let tree = store.tree()
        #expect(tree.map(\.path) == ["Work", "a.md", "b.md"])
        #expect(tree[0].children?.map(\.path) == ["Work/plan.md"])
        #expect(tree[1].name == "a")
        #expect(tree[1].isNote)
        #expect(tree[1].children == nil)
    }

    @Test func treeListsCodeAndTextFilesWithTheirExtension() throws {
        try put("config.json")
        try put("a.md")
        try put("Log.TXT")
        try put("data.csv")
        try put("server.log")
        try put("script.py")
        try put("Work/app.swift")

        let tree = store.tree()
        #expect(tree.map(\.name) == ["Work", "a", "config.json", "data.csv", "Log.TXT", "script.py", "server.log"])
        #expect(tree.filter(\.isNote).map(\.path) == ["a.md"])
        #expect(tree[0].children?.map(\.name) == ["app.swift"])
        #expect(store.notePaths() == ["Work/app.swift", "a.md", "config.json", "data.csv", "Log.TXT", "script.py", "server.log"])
    }

    @Test(arguments: ["a.md", "A.MD", "x.mdown", "x.mkd", "x.markdown", "x.json", "x.yml", "x.ts", "x.txt", "x.log", "x.csv", "Work/x.swift"])
    func listsKnownExtensions(path: String) {
        #expect(NoteStore.isListed(path))
    }

    @Test(arguments: ["x.png", "x.pdf", "Makefile", "x.", "x.docx"])
    func skipsUnknownExtensions(path: String) {
        #expect(!NoteStore.isListed(path))
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

    @Test(arguments: ["", "../escape", "a/../b", "a/./b", ".", ".hidden", "x//y", "/abs", "a/",
                      "..\u{301}/x", "a/.\u{200D}./b"])
    func rejectsInvalidPaths(path: String) {
        #expect(throws: NoteStoreError.invalidName(path)) { try store.url(for: path) }
    }

    /// Components that merely look like ".." (a mark or ZWJ before the dots) are ordinary names inside the root.
    @Test func lookalikeDotComponentsStayInsideTheRoot() throws {
        let url = try store.url(for: "a/\u{200D}../b")
        #expect(url.standardizedFileURL.path.unicodeScalars.starts(with: (root.standardizedFileURL.path + "/a/").unicodeScalars))
        #expect(url.standardizedFileURL.lastPathComponent == "b")
    }

    @Test func pathsSplitOnTheSlashScalar() throws {
        // "/" + U+0301 is one Character; it must still separate components.
        let path = "w/\u{301}x.md"
        #expect(NoteStore.components(path) == ["w", "\u{301}x.md"])
        #expect(try store.url(for: path) == root.standardizedFileURL.appendingPathComponent("w").appendingPathComponent("\u{301}x.md"))
        #expect(NoteStore.parent(path) == "w")
        #expect(NoteStore.moved(path, from: "w", to: "v")?.unicodeScalars.elementsEqual("v/\u{301}x.md".unicodeScalars) == true)
        #expect(NoteStore.moved("wx", from: "w", to: "v") == nil)
        #expect(NoteStore.displayName(path).unicodeScalars.elementsEqual("\u{301}x".unicodeScalars))
    }

    /// Files made by other apps may break the portable rules; they must still open, rename and trash.
    @Test func existingNonPortableNamesStillWork() throws {
        try put("Why?.md", "x")
        try put("10:30.md", "y")
        try put("trailing..md", "z")
        #expect(store.notePaths() == ["10:30.md", "trailing..md", "Why?.md"])
        #expect(try store.read("Why?.md") == "x")

        #expect(try store.rename("Why?.md", to: "Why") == "Why.md")
        #expect(try store.read("Why.md") == "x")
        try store.trash("10:30.md")
        #expect(store.notePaths() == ["trailing..md", "Why.md"])
    }

    @Test(arguments: ["a:b", "a?b", "a*b", "a|b", "a<b", "a\"b", "a\\b", "tab\tname", ".hidden"])
    func typedNamesFollowPortableRules(name: String) throws {
        try put("a.md")
        #expect(throws: NoteStoreError.self) { try store.createNote(named: name) }
        #expect(throws: NoteStoreError.self) { try store.createFolder(named: name) }
        #expect(throws: NoteStoreError.self) { try store.rename("a.md", to: name) }
        #expect(store.notePaths() == ["a.md"])
    }

    @Test func typedFolderNamesCannotEndWithADot() throws {
        #expect(throws: NoteStoreError.invalidName("F.")) { try store.createFolder(named: "F.") }
        try store.createFolder(named: "F")
        #expect(throws: NoteStoreError.invalidName("G.")) { try store.rename("F", to: "G.") }
    }

    @Test func renameKeepsExtensionAndFolder() throws {
        try put("Work/old.md", "x")
        let newPath = try store.rename("Work/old.md", to: "new")
        #expect(newPath == "Work/new.md")
        #expect(try store.read(newPath) == "x")
        #expect(store.modificationDate("Work/old.md") == nil)
    }

    @Test func renameToTheSameNameIsANoOp() throws {
        try put("Work/note.md", "x")
        #expect(try store.rename("Work/note.md", to: "note") == "Work/note.md")
        #expect(try store.rename("Work/note.md", to: " note.md ") == "Work/note.md")
        #expect(try store.read("Work/note.md") == "x")
    }

    @Test func renameKeepsTheExtensionOfOtherFiles() throws {
        try put("config.json", "{}")
        #expect(try store.rename("config.json", to: "settings") == "settings.json")
        #expect(try store.rename("settings.json", to: "settings.yaml") == "settings.yaml")
        // Only listed extensions count as extensions: ".5" or ".png" would make the file vanish from the list.
        #expect(try store.rename("settings.yaml", to: "Toplantı 3.5") == "Toplantı 3.5.yaml")
        #expect(try store.rename("Toplantı 3.5.yaml", to: "resim.png") == "resim.png.yaml")
        #expect(store.notePaths() == ["resim.png.yaml"])
        try store.createFolder(named: "Folder")
        #expect(try store.rename("Folder", to: "Klasör") == "Klasör")
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

    @Test func searchCoversTextFilesAndTheirExtensions() throws {
        try put("config.json", "{\"toplantı\": 1}")
        try put("notes.txt", "nothing")

        #expect(store.search("toplanti").map(\.path) == ["config.json"])
        #expect(store.search(".txt").map(\.path) == ["notes.txt"])
        #expect(store.search("md").isEmpty)
    }
}
