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
        try store.createFolder(named: "Kişisel")
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

    @Test func creatingNeverRecreatesAMissingFolder() throws {
        try store.createFolder(named: "Gone")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Gone"))
        #expect(throws: NoteStoreError.missingFolder("Gone")) { try store.createNote(named: "x", in: "Gone") }
        #expect(throws: NoteStoreError.missingFolder("Gone")) { try store.createFolder(named: "y", in: "Gone") }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Gone").path))
        try FileManager.default.removeItem(at: root)
        #expect(throws: NoteStoreError.missingFolder("")) { try store.createNote(named: "x") }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func missingRootIsOnlyCreatedOnRequest() throws {
        let missing = root.appendingPathComponent("yok")
        #expect(throws: NoteStoreError.rootUnavailable(missing.standardizedFileURL.path)) {
            try NoteStore(root: missing, createIfMissing: false)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        try put("dosya.md")
        #expect(throws: NoteStoreError.self) { try NoteStore(root: root.appendingPathComponent("dosya.md"), createIfMissing: false) }
        _ = try NoteStore(root: missing)
        #expect(FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func treeDepthCapAndCancellation() throws {
        try put("a/b/c/d.md")
        try put("a/x.md")
        let capped = store.tree(ListingOptions(maxDepth: 2))
        #expect(capped.map(\.path) == ["a"])
        #expect(capped[0].children?.map(\.path) == ["a/b", "a/x.md"])
        #expect(capped[0].children?[0].children == [])
        #expect(store.tree(shouldContinue: { false }).isEmpty)
    }
}

struct ListingOptionsTests {
    let root: URL
    let store: NoteStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ListingOptionsTests-\(UUID().uuidString)")
        store = try NoteStore(root: root)
    }

    private func put(_ path: String, _ text: String = "", modified: TimeInterval) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
    }

    @Test func modifiedOrderKeepsFoldersFirstByNameAndPutsNewestFilesFirst() throws {
        try put("b.md", modified: 100)
        try put("a.md", modified: 300)
        try put("c.json", modified: 200)
        try put("d.md", modified: 200)
        try put("Zeta/x.md", modified: 1)
        try put("Alfa/y.md", modified: 1)

        let tree = store.tree(ListingOptions(order: .modified))
        #expect(tree.map(\.path) == ["Alfa", "Zeta", "a.md", "c.json", "d.md", "b.md"])
        #expect(store.tree().map(\.path) == ["Alfa", "Zeta", "a.md", "b.md", "c.json", "d.md"])
    }

    @Test func markdownOnlyHidesOtherFilesInTheTreeAndSearch() throws {
        try put("a.md", "kahve", modified: 1)
        try put("b.MARKDOWN", "kahve", modified: 1)
        try put("c.mkd", "kahve", modified: 1)
        try put("config.json", "kahve", modified: 1)
        try put("Kod/app.swift", "kahve", modified: 1)

        let options = ListingOptions(markdownOnly: true)
        #expect(store.tree(options).map(\.path) == ["Kod", "a.md", "b.MARKDOWN", "c.mkd"])
        #expect(store.tree(options)[0].children == [])
        #expect(Set(store.search("kahve", listing: options).map(\.path)) == ["a.md", "b.MARKDOWN", "c.mkd"])
        #expect(Set(store.search("kahve").map(\.path)).count == 5)
    }

    @Test(arguments: [("a.md", true), ("x.Markdown", true), ("x.mdown", true), ("x.mkd", true), ("x.txt", false),
                      ("x.json", false), ("md", false), ("Work/n.md", true)])
    func isMarkdown(path: String, expected: Bool) {
        #expect(NoteStore.isMarkdown(path) == expected)
    }
}

extension NoteStoreTests {
    private func putBytes(_ path: String, _ data: Data) throws {
        try data.write(to: root.appendingPathComponent(path))
    }

    @Test func encryptedNotesAreListedButNotNotes() throws {
        try put("Secret.mdenc")
        try put("a.md")
        #expect(NoteStore.isListed("Secret.MDENC") && NoteStore.isMarkdown("Secret.mdenc"))
        #expect(NoteStore.isEncrypted("Work/Secret.mdenc") && !NoteStore.isEncrypted("a.md"))
        #expect(!NoteStore.isNote("Secret.mdenc"))
        #expect(CodeLanguage(path: "Secret.mdenc") == .markdown)
        #expect(store.tree().map(\.name) == ["a", "Secret"])
        #expect(store.tree(ListingOptions(markdownOnly: true)).map(\.name) == ["a", "Secret"])
        #expect(NoteStore.displayName("Work/Secret.mdenc") == "Secret")
    }

    @Test func searchFindsEncryptedNamesNotContent() throws {
        try put("Gizli.mdenc", "needle in bytes")
        try put("n.md", "needle")
        #expect(store.search("needle").map(\.path) == ["n.md"])
        #expect(store.search("gizli") == [SearchHit(path: "Gizli.mdenc", line: nil, snippet: nil)])
        #expect(store.search("mdenc").isEmpty)
    }

    @Test func encryptedNoteHasNoPreview() throws {
        try put("s.mdenc", "title\n\nbody text")
        try put("s.md", "title\n\nbody text")
        #expect(NoteStore.preview(ofFileAt: root.appendingPathComponent("s.mdenc")) == nil)
        #expect(NoteStore.preview(ofFileAt: root.appendingPathComponent("s.md")) == "body text")
    }

    @Test func renameKeepsMdencExtension() throws {
        try put("s.mdenc")
        #expect(try store.rename("s.mdenc", to: "Yeni") == "Yeni.mdenc")
        #expect(try store.rename("Yeni.mdenc", to: "Başka.mdenc") == "Başka.mdenc")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Başka.mdenc").path))
    }

    @Test func renameNeverAddsOrRemovesMdenc() throws {
        try put("todo.txt")
        #expect(try store.rename("todo.txt", to: "todo.mdenc") == "todo.mdenc.txt")
        try put("n.md")
        #expect(try store.rename("n.md", to: "todo.mdenc") == "todo.mdenc.md")
        try put("e.mdenc")
        #expect(try store.rename("e.mdenc", to: "plain.md") == "plain.md.mdenc")
        #expect(!NoteStore.isNote("plain.md.mdenc") && NoteStore.isEncrypted("plain.md.mdenc"))
    }

    @Test func conflictCopyAndDuplicateKeepExtension() throws {
        try put("s.mdenc")
        let url = root.appendingPathComponent("s.mdenc")
        #expect(NoteStore.conflictCopyURL(for: url, language: .english).lastPathComponent == "s (conflict).mdenc")
        let copy = try store.duplicate("s.mdenc")
        #expect(copy.hasSuffix(".mdenc"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("F"), withIntermediateDirectories: true)
        #expect(try store.move("s.mdenc", to: "F") == "F/s.mdenc")
    }

    @Test func uniqueEncryptedURL() throws {
        try put("s.mdenc")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("F"), withIntermediateDirectories: true)
        #expect(try store.uniqueEncryptedURL(named: "n").path == "n.mdenc")
        #expect(try store.uniqueEncryptedURL(named: "s").path == "s 2.mdenc")
        #expect(try store.uniqueEncryptedURL(named: "s.mdenc").path == "s 2.mdenc")
        let inFolder = try store.uniqueEncryptedURL(named: "s", in: "F")
        #expect(inFolder.path == "F/s.mdenc" && inFolder.url == root.appendingPathComponent("F/s.mdenc"))
        #expect(throws: NoteStoreError.invalidName("a:b.mdenc")) { try store.uniqueEncryptedURL(named: "a:b") }
        #expect(throws: NoteStoreError.self) { try store.uniqueEncryptedURL(named: "x", in: "Nope") }
    }
}
