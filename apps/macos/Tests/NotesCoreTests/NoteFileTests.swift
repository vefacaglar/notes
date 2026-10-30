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

    @Test func brokenLinkHasNoStampAndIsNeverReplaced() throws {
        let missing = folder.appendingPathComponent("yok.md")
        let link = folder.appendingPathComponent("kırık.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)

        #expect(NoteFile.stamp(link) == nil)
        #expect(NoteFile.size(link) == nil)
        #expect(!NoteFile.isWritable(link))
        #expect(throws: NoteFileError.self) { try NoteFile.write("x", to: link) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == missing.path)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func brokenLinkChainIsRejected() throws {
        let first = folder.appendingPathComponent("bir.md")
        let second = folder.appendingPathComponent("iki.md")
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: folder.appendingPathComponent("yok.md"))
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: second)
        #expect(NoteFile.stamp(first) == nil)
        #expect(throws: NoteFileError.self) { try NoteFile.write("x", to: first) }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: first.path)) == second.path)
    }

    @Test func fallsBackToATempFileInTheTargetFolder() throws {
        let file = folder.appendingPathComponent("a.md")
        try Data("eski".utf8).write(to: file)
        struct NoReplacementFolder: Error {}
        try NoteFile.write("yeni çğ", to: file) { _ in throw NoReplacementFolder() }
        #expect(try String(contentsOf: file, encoding: .utf8) == "yeni çğ")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["a.md"])
    }

    @Test func fallsBackWhenTheReplacementFolderCannotBeWritten() throws {
        let file = folder.appendingPathComponent("a.md")
        try Data("eski".utf8).write(to: file)
        let gone = folder.appendingPathComponent("yok-klasör/alt")
        try NoteFile.write("yeni", to: file) { _ in gone }
        #expect(try String(contentsOf: file, encoding: .utf8) == "yeni")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["a.md"])
    }

    @Test func readOnlyFileThrowsNotWritableAndKeepsItsContent() throws {
        let file = folder.appendingPathComponent("kilitli.md")
        try Data("eski".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        #expect(!NoteFile.isWritable(file))
        do {
            try NoteFile.write("yeni", to: file)
            Issue.record("write should have thrown")
        } catch let error as NoteFileError {
            #expect(error == .notWritable(path: file.resolvingSymlinksInPath().path))
            #expect(error.errorDescription?.contains("kilitli.md") == true)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "eski")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["kilitli.md"])
    }

    @Test func readOnlyFolderThrowsNotWritable() throws {
        let sub = folder.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent("a.md")
        try Data("eski".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sub.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sub.path) }
        #expect(!NoteFile.isWritable(file))
        #expect(throws: NoteFileError.notWritable(path: file.resolvingSymlinksInPath().path)) {
            try NoteFile.write("yeni", to: file)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "eski")
    }

    @Test func isWritableFollowsLinksAndHandlesMissingFiles() throws {
        let file = folder.appendingPathComponent("a.md")
        let link = folder.appendingPathComponent("bağ.md")
        try Data("a".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(NoteFile.isWritable(file))
        #expect(NoteFile.isWritable(link))
        #expect(NoteFile.isWritable(folder.appendingPathComponent("yeni.md")))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        #expect(!NoteFile.isWritable(link))
    }

    @Test func writeKeepsTheHiddenFlag() throws {
        let file = folder.appendingPathComponent("gizli.md")
        try Data("eski".utf8).write(to: file)
        #expect(chflags(file.path, UInt32(UF_HIDDEN)) == 0)
        try NoteFile.write("yeni", to: file)
        var info = stat()
        #expect(stat(file.path, &info) == 0)
        #expect(info.st_flags & UInt32(UF_HIDDEN) != 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "yeni")
    }
}
