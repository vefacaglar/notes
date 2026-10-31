import Foundation
import Testing
@testable import NotesCore

struct PathListTests {
    @Test func appendAndRemoveAreUnique() {
        var list = PathList()
        list.append("/a/b.md")
        list.append("/a/b.md")
        #expect(list.paths == ["/a/b.md"])
        list.remove("/a/b.md")
        #expect(list.paths.isEmpty)
    }

    @Test func pushMovesToFrontAndCaps() {
        var list = PathList(paths: ["/1", "/2", "/3"])
        list.push("/3", limit: 3)
        #expect(list.paths == ["/3", "/1", "/2"])
        list.push("/4", limit: 3)
        #expect(list.paths == ["/4", "/3", "/1"])
    }

    @Test func movedFollowsItemsAndFolders() {
        var list = PathList(paths: ["/r/Work/a.md", "/r/Worker.md", "/r/b.md"])
        list.moved(from: "/r/Work", to: "/r/Plans/Work")
        #expect(list.paths == ["/r/Plans/Work/a.md", "/r/Worker.md", "/r/b.md"])
        list.moved(from: "/r/b.md", to: "/r/Worker.md")
        #expect(list.paths == ["/r/Plans/Work/a.md", "/r/Worker.md"])
    }

    @Test func removeItemDropsFolderContents() {
        var list = PathList(paths: ["/r/Work/a.md", "/r/Worker.md", "/r/Work"])
        list.removeItem(at: "/r/Work")
        #expect(list.paths == ["/r/Worker.md"])
    }

    @Test func writeAndReadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Paths-\(UUID().uuidString)/pins.json")
        let list = PathList(paths: ["/r/Işık 🙂.md"])
        try list.write(to: url)
        #expect(PathList.read(url) == list)
        #expect(PathList.read(url.appendingPathExtension("none")) == nil)
    }
}
