import Foundation
import Testing
@testable import NotesCore

@Suite("Outline")
struct MarkdownOutlineTests {
    @Test func listsAtxHeadingsWithOffsets() {
        let text = "# Başlık İ\n\ntext\n## Two ##\n### 😀 Three #\n####### seven\n#NoSpace\n"
        let headings = MarkdownOutline.headings(in: text)
        #expect(headings.map(\.title) == ["Başlık İ", "Two", "😀 Three"])
        #expect(headings.map(\.level) == [1, 2, 3])
        let ns = text as NSString
        #expect(headings.map { ns.substring(from: $0.location).hasPrefix("#") } == [true, true, true])
        #expect(headings[1].location == ("# Başlık İ\n\ntext\n" as NSString).length)
    }

    @Test func skipsFencedCodeAndEmptyHeadings() {
        let text = "```\n# not a heading\n```\n#\n# \n# Real\n"
        #expect(MarkdownOutline.headings(in: text).map(\.title) == ["Real"])
    }

    @Test func crlfDoesNotLeakIntoTitles() {
        #expect(MarkdownOutline.headings(in: "# A\r\n## B\r\n").map(\.title) == ["A", "B"])
    }
}

@Suite("Markdown images")
struct MarkdownImagesTests {
    @Test func findsImagesAndSkipsCode() {
        let text = "a ![alt](assets/x%201.png) b\n`![no](c.png)`\n```\n![no](d.png)\n```\n![](<my pic.png> \"t\")\n\\![no](e.png)\n"
        let images = MarkdownImages.references(in: text)
        #expect(images.map(\.destination) == ["assets/x%201.png", "my pic.png"])
        #expect(images[0].alt == "alt")
        #expect((text as NSString).substring(with: images[0].range) == "![alt](assets/x%201.png)")
    }

    @Test func utf16RangesWithEmoji() {
        let text = "😀 ![ç](ü.png)"
        let image = MarkdownImages.references(in: text)[0]
        #expect((text as NSString).substring(with: image.range) == "![ç](ü.png)")
    }

    @Test func rejectsBrokenSyntax() {
        #expect(MarkdownImages.references(in: "![a](b.png\n)").isEmpty)
        #expect(MarkdownImages.references(in: "![a] (b.png)").isEmpty)
        #expect(MarkdownImages.references(in: "![a]()").isEmpty)
    }

    @Test func resolvesDestinations() {
        let folder = URL(fileURLWithPath: "/tmp/notes/Work")
        #expect(MarkdownImages.fileURL(for: "assets/a%20b.png", noteFolder: folder)?.path == "/tmp/notes/Work/assets/a b.png")
        #expect(MarkdownImages.fileURL(for: "../x.png", noteFolder: folder)?.path == "/tmp/notes/x.png")
        #expect(MarkdownImages.fileURL(for: "/abs/x.png", noteFolder: folder)?.path == "/abs/x.png")
        #expect(MarkdownImages.fileURL(for: "file:///abs/y.png", noteFolder: nil)?.path == "/abs/y.png")
        #expect(MarkdownImages.fileURL(for: "https://example.com/x.png", noteFolder: folder) == nil)
        #expect(MarkdownImages.fileURL(for: "a.png", noteFolder: nil) == nil)
    }
}

@Suite("Note assets")
struct NoteAssetsTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "assets-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func namesFollowPortableRules() {
        #expect(NoteAssets.fileName(forNote: "Plan", index: 2, fileExtension: "png") == "Plan 2.png")
        #expect(NoteAssets.fileName(forNote: "Why?: a/b", index: 1, fileExtension: "png") == "Why?: a/b 1.png"
            .replacingOccurrences(of: "?", with: "-").replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-"))
        #expect(NoteAssets.fileName(forNote: "..", index: 1, fileExtension: "png") == "image 1.png")
        #expect(NoteAssets.fileName(forNote: "con.x", index: 1, fileExtension: "png") == "con_.x 1.png")
        #expect(NoteAssets.fileName(forNote: String(repeating: "a", count: 100), index: 1, fileExtension: "jpg").count == 60 + 6)
    }

    @Test func destinationIsPercentEncoded() {
        #expect(NoteAssets.destination(forFileName: "Çalışma (1) 2.png") == "assets/%C3%87al%C4%B1%C5%9Fma%20%281%29%202.png")
        let decoded = NoteAssets.destination(forFileName: "Çalışma (1) 2.png").removingPercentEncoding
        #expect(decoded == "assets/Çalışma (1) 2.png")
    }

    @Test func savesUniqueFilesAndLeavesNoTemporaries() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appending(path: "Notlar.md")
        let first = try NoteAssets.save(Data([1]), forNoteAt: note)
        let second = try NoteAssets.save(Data([2]), forNoteAt: note)
        #expect(first == "assets/Notlar%201.png")
        #expect(second == "assets/Notlar%202.png")
        let url = try #require(MarkdownImages.fileURL(for: second, noteFolder: folder))
        #expect(try Data(contentsOf: url) == Data([2]))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "assets").path)
        #expect(names.sorted() == ["Notlar 1.png", "Notlar 2.png"])
    }

    @Test func failsWhenAssetsIsAFile() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appending(path: "assets"))
        #expect(throws: (any Error).self) { try NoteAssets.save(Data([1]), forNoteAt: folder.appending(path: "a.md")) }
    }
}
