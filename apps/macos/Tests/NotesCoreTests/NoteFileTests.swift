import Darwin
import Foundation
import Testing
@testable import NotesCore

struct NoteFileTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("NoteFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @Test func readDropsBOMAndCRLF() throws {
        let file = folder.appendingPathComponent("a.md")
        try Data("\u{FEFF}bir\r\niki\r\n".utf8).write(to: file)
        #expect(try NoteFile.read(file) == "bir\niki\n")
    }

    @Test func writeCreatesAMissingFile() throws {
        let file = folder.appendingPathComponent("yeni.md")
        try NoteFile.write("çğ 😀\n", to: file)
        #expect(try Data(contentsOf: file) == Data("çğ 😀\n".utf8))
    }

    @Test func writeFollowsSymlinksAndKeepsTheLink() throws {
        let target = folder.appendingPathComponent("gerçek.md")
        let link = folder.appendingPathComponent("bağ.md")
        try Data("eski".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try NoteFile.write("yeni", to: link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == "yeni")
        #expect(NoteFile.stamp(link) == NoteFile.stamp(target))
    }

    @Test func writeKeepsExtendedAttributesAndPermissions() throws {
        let file = folder.appendingPathComponent("etiketli.md")
        try Data("eski".utf8).write(to: file)
        let value = Array("kırmızı".utf8)
        #expect(setxattr(file.path, "com.example.notes-test", value, value.count, 0, 0) == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)

        try NoteFile.write("yeni", to: file)
        var buffer = [UInt8](repeating: 0, count: 64)
        let length = getxattr(file.path, "com.example.notes-test", &buffer, buffer.count, 0, 0)
        #expect(length == value.count)
        #expect(Array(buffer.prefix(max(length, 0))) == value)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o640)
        #expect(try String(contentsOf: file, encoding: .utf8) == "yeni")
    }

    /// Another program's atomic save is noticed even when it restores the old modification date and size.
    @Test func stampChangesWithTheFileNotJustItsDate() throws {
        let file = folder.appendingPathComponent("a.md")
        try NoteFile.write("abc", to: file)
        let before = try #require(NoteFile.stamp(file))

        let other = folder.appendingPathComponent("other.tmp")
        try Data("xyz".utf8).write(to: other)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: other, options: .usingNewMetadataOnly)
        try FileManager.default.setAttributes([.modificationDate: before.modificationDate as Any], ofItemAtPath: file.path)

        let after = try #require(NoteFile.stamp(file))
        // The date only round-trips to about a microsecond; size and inode tell the versions apart regardless.
        #expect(abs((after.modificationDate ?? .distantPast).timeIntervalSince(before.modificationDate ?? .distantFuture)) < 0.001)
        #expect(after.size == before.size)
        #expect(after.fileNumber != before.fileNumber)
        #expect(after != before)
        #expect(NoteFile.stamp(folder.appendingPathComponent("yok.md")) == nil)
    }
}
