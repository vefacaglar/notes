import Foundation
import Testing
@testable import NotesCore

struct DraftStoreTests {
    let base: URL
    let store: DraftStore

    init() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("DraftStoreTests-\(UUID().uuidString)")
        store = DraftStore(folder: base.appendingPathComponent("Drafts"))
    }

    private func put(_ name: String, _ text: String, in folder: URL? = nil) throws -> URL {
        let folder = folder ?? store.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private static func name(_ digit: Character) -> String { String(repeating: digit, count: 32) + ".md" }

    @Test func draftNames() {
        #expect(DraftStore.isDraftName(Self.name("a")))
        #expect(DraftStore.isDraftName("0123456789abcdef0123456789abcdef.md"))
        #expect(!DraftStore.isDraftName("0123456789ABCDEF0123456789abcdef.md"))
        #expect(!DraftStore.isDraftName(String(repeating: "a", count: 31) + ".md"))
        #expect(!DraftStore.isDraftName(String(repeating: "a", count: 32) + ".txt"))
        #expect(!DraftStore.isDraftName(String(repeating: "g", count: 32) + ".md"))
        #expect(!DraftStore.isDraftName("order.txt"))
        #expect(!DraftStore.isDraftName(".lock"))
        #expect(DraftStore.isDraftName(DraftStore.newDraftName()))
        #expect(DraftStore.newDraftName() != DraftStore.newDraftName())
    }

    @Test func savedFollowsTheOrderFileThenAgeAndDeletesEmptyDrafts() throws {
        let a = try put(Self.name("a"), "birinci")
        let b = try put(Self.name("b"), "ikinci 😀")
        let empty = try put(Self.name("c"), "")
        let d = try put(Self.name("d"), "dördüncü")
        _ = try put("notes.md", "not a draft")
        try store.writeOrder([Self.name("b"), Self.name("c"), "junk", Self.name("e"), Self.name("a")])

        let saved = store.saved()
        #expect(saved.map(\.lastPathComponent) == [b, a, d].map(\.lastPathComponent))
        #expect(!FileManager.default.fileExists(atPath: empty.path))
        #expect(FileManager.default.fileExists(atPath: store.folder.appendingPathComponent("notes.md").path))
        #expect(store.readOrder() == [Self.name("b"), Self.name("c"), Self.name("e"), Self.name("a")])
    }

    @Test func missingStoreIsEmpty() {
        #expect(store.saved().isEmpty)
        #expect(store.readOrder().isEmpty)
    }

    @Test func oneOwnerAtATime() throws {
        #expect(try store.lock())
        let other = DraftStore(folder: store.folder)
        #expect(try !other.lock())
        store.unlock()
        #expect(try other.lock())
        #expect(try !store.lock())
    }

    @Test func takeDraftsRenamesAndAppendsToTheOrder() throws {
        _ = try put(Self.name("1"), "eski")
        try store.writeOrder([Self.name("1")])
        let pending = base.appendingPathComponent("Pending/x")
        _ = try put(Self.name("2"), "taşınacak", in: pending)
        _ = try put(Self.name("3"), "", in: pending)

        #expect(store.takeDrafts(from: pending))
        let order = store.readOrder()
        #expect(order.count == 2)
        #expect(order[0] == Self.name("1"))
        #expect(order[1] != Self.name("2"))
        #expect(try NoteFile.read(store.folder.appendingPathComponent(order[1])) == "taşınacak")
        #expect(DraftStore(folder: pending).saved().isEmpty)
    }

    @Test func adoptPendingSkipsStoresStillInUse() throws {
        let pendingRoot = base.appendingPathComponent("PendingDrafts")
        let free = pendingRoot.appendingPathComponent("free")
        let busy = pendingRoot.appendingPathComponent("busy")
        _ = try put(Self.name("a"), "serbest", in: free)
        _ = try put(Self.name("b"), "meşgul", in: busy)
        let holder = DraftStore(folder: busy)
        #expect(try holder.lock())

        store.adoptPending(in: pendingRoot)
        #expect(!FileManager.default.fileExists(atPath: free.path))
        #expect(FileManager.default.fileExists(atPath: busy.appendingPathComponent(Self.name("b")).path))
        #expect(store.saved().count == 1)
        #expect(try NoteFile.read(store.saved()[0]) == "serbest")
    }

    @Test func lockSurvivesAndDetectsTheLockFileBeingReplaced() throws {
        #expect(try store.lock())
        let other = DraftStore(folder: store.folder)
        #expect(try !other.lock())
        // A lock file removed and recreated (stale cleanup) must not let a second owner in unnoticed: the new lock
        // lands on the new file.
        store.unlock()
        let lockFile = store.folder.appendingPathComponent(DraftStore.lockFileName)
        try FileManager.default.removeItem(at: lockFile)
        #expect(try other.lock())
        #expect(FileManager.default.fileExists(atPath: lockFile.path))
        #expect(try !store.lock())
    }
}
