import Foundation
import Testing
@testable import NotesCore

struct NotePreviewTests {
    @Test func firstLineAfterTitle() {
        #expect(NoteStore.preview(from: "Title\nSecond line\nThird") == "Second line")
    }

    @Test func skipsBlankLinesAndStripsMarkers() {
        #expect(NoteStore.preview(from: "# Title\n\n\n## Heading two\n") == "Heading two")
        #expect(NoteStore.preview(from: "T\n- [x] **done** and `code`") == "done and code")
        #expect(NoteStore.preview(from: "T\n> quoted *text*") == "quoted text")
        #expect(NoteStore.preview(from: "T\n1. [a link](https://x.com) here") == "a link here")
    }

    @Test func skipsRulesAndFences() {
        #expect(NoteStore.preview(from: "T\n---\nAfter rule") == "After rule")
        #expect(NoteStore.preview(from: "T\n```swift\nlet x = 1\n```\nReal text") == "Real text")
    }

    @Test func nilWithoutSecondLine() {
        #expect(NoteStore.preview(from: "") == nil)
        #expect(NoteStore.preview(from: "Only title") == nil)
        #expect(NoteStore.preview(from: "Title\n   \n\t\n") == nil)
    }

    @Test func crlfBomAndCollapsedWhitespace() {
        #expect(NoteStore.preview(from: "\u{FEFF}Title\r\nİlk   satır\t ışık\r\nTwo") == "İlk satır ışık")
    }

    @Test func emojiAndLength() {
        #expect(NoteStore.preview(from: "T\n🙂 **hi** 👍🏽") == "🙂 hi 👍🏽")
        let long = String(repeating: "ab ", count: 200)
        #expect((NoteStore.preview(from: "T\n" + long)?.count ?? 0) <= NoteStore.maxPreviewLength)
    }

    @Test func readsOnlyTheFirstBytesAndSurvivesACutCharacter() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Preview-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        // The second line runs past the 2048-byte boundary inside a multi-byte character.
        let body = "Title\nBody " + String(repeating: "ş", count: 2000)
        try Data(body.utf8).write(to: url)
        let preview = try #require(NoteStore.preview(ofFileAt: url))
        #expect(preview.hasPrefix("Body ş"))
        #expect(preview.utf8.count <= NoteStore.previewBytes)
        #expect(NoteStore.preview(ofFileAt: url.appendingPathExtension("missing")) == nil)
    }
}
