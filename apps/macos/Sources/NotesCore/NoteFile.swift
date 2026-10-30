import Foundation

public enum NoteFileError: LocalizedError, Equatable {
    case tooLarge(bytes: Int)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let bytes):
            "Dosya çok büyük (\(bytes / 1_048_576) MB); en fazla \(NoteFile.maxOpenSize / 1_048_576) MB açılabilir."
        }
    }
}

/// Reading and writing one text file as both apps do (docs/format.md, "File contents" and "External changes").
/// Paths are followed through symbolic links, so a linked note stays a link and its target is what changes.
public enum NoteFile {
    /// Files above this size open read-only.
    public static let readOnlySize = 20 * 1_048_576
    /// Files above this size are not opened.
    public static let maxOpenSize = 200 * 1_048_576

    /// Identifies one version of a file: anything another program writes changes at least one of these.
    public struct Stamp: Equatable, Sendable {
        public let modificationDate: Date?
        public let size: Int?
        /// The inode; an atomic save by another program replaces it.
        public let fileNumber: Int?
    }

    /// The stamp of the file `url` points to (through links), or `nil` when there is none.
    public static func stamp(_ url: URL) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        else { return nil }
        return Stamp(
            modificationDate: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.intValue,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.intValue
        )
    }

    /// UTF-8 text with a leading BOM dropped and CRLF turned into LF.
    public static func read(_ url: URL) throws -> String {
        var text = try String(contentsOf: url.resolvingSymlinksInPath(), encoding: .utf8)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Writes `text` as UTF-8 without a BOM, atomically. An existing file is replaced through
    /// `FileManager.replaceItemAt`, which keeps its permissions, Finder tags and other extended attributes;
    /// a link is followed, so the link itself stays.
    public static func write(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        let data = Data(text.utf8)
        guard fm.fileExists(atPath: target.path) else {
            try data.write(to: target, options: .atomic)
            return
        }
        let folder = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: folder) }
        let temp = folder.appendingPathComponent(target.lastPathComponent)
        try data.write(to: temp)
        _ = try fm.replaceItemAt(target, withItemAt: temp)
    }

    /// Size in bytes of the file `url` points to.
    public static func size(_ url: URL) -> Int? {
        stamp(url)?.size
    }
}
