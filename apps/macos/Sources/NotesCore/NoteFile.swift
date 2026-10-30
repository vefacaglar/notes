import Foundation

public enum NoteFileError: LocalizedError, Equatable {
    case tooLarge(bytes: Int)
    /// The file or its folder refuses writes (read-only file, locked item, deny ACL); `path` is the resolved file.
    case notWritable(path: String)
    /// `path` is a symbolic link whose target does not exist; nothing is written.
    case brokenLink(path: String)

    public var errorDescription: String? {
        switch self {
        case .notWritable(let path):
            String(localized: "“\(URL(fileURLWithPath: path).lastPathComponent)” can't be saved because it is read-only or locked.")
        case .brokenLink(let path):
            String(localized: "“\(URL(fileURLWithPath: path).lastPathComponent)” is a link to a file that doesn't exist.")
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

    /// The stamp of the file `url` points to (through links), or `nil` when there is none (also for a broken link).
    public static func stamp(_ url: URL) -> Stamp? {
        let path = url.resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        else { return nil }
        return Stamp(
            modificationDate: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.intValue,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.intValue
        )
    }

    /// Whether a save of the file `url` points to can succeed: the file (if it exists) and its folder accept writes.
    /// The editor opens files for which this is false read-only.
    public static func isWritable(_ url: URL) -> Bool {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        if isLink(target) { return false }
        let folderWritable = fm.isWritableFile(atPath: target.deletingLastPathComponent().path)
        return fm.fileExists(atPath: target.path) ? folderWritable && fm.isWritableFile(atPath: target.path) : folderWritable
    }

    /// UTF-8 text with a leading BOM dropped and CRLF turned into LF.
    public static func read(_ url: URL) throws -> String {
        var text = try String(contentsOf: url.resolvingSymlinksInPath(), encoding: .utf8)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Writes `text` as UTF-8 without a BOM, atomically. An existing file is replaced through
    /// `FileManager.replaceItemAt`, which keeps its permissions, Finder tags and most extended attributes; the hidden
    /// flag is copied over. Not preserved: `com.apple.ResourceFork`, `com.apple.quarantine`, hard links (the path gets a
    /// new inode). A link is followed, so the link itself stays; a link to a missing file throws `brokenLink`.
    /// Permission failures throw `notWritable`.
    public static func write(_ text: String, to url: URL) throws {
        try write(text, to: url, replacementFolder: itemReplacementFolder)
    }

    static func itemReplacementFolder(for target: URL) throws -> URL {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
    }

    /// `replacementFolder` makes the private folder the temp file is written in; when it fails (network shares whose
    /// root is not writable), the temp file goes next to the target as a hidden, uniquely named file instead.
    static func write(_ text: String, to url: URL, replacementFolder: (URL) throws -> URL) throws {
        let fm = FileManager.default
        let target = url.resolvingSymlinksInPath()
        if !fm.fileExists(atPath: target.path), isLink(target) || isLink(url) {
            throw NoteFileError.brokenLink(path: target.path)
        }
        let data = Data(text.utf8)
        do {
            guard fm.fileExists(atPath: target.path) else {
                try data.write(to: target, options: .atomic)
                return
            }
            let hiddenFlag = flags(target) & UInt32(UF_HIDDEN)
            var temp: URL
            var cleanup: URL
            do {
                let folder = try replacementFolder(target)
                cleanup = folder
                temp = folder.appendingPathComponent(target.lastPathComponent)
            } catch {
                temp = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
                cleanup = temp
            }
            defer { try? fm.removeItem(at: cleanup) }
            do {
                try data.write(to: temp)
            } catch where cleanup != temp {
                // The private folder exists but can't be written; same fallback.
                try? fm.removeItem(at: cleanup)
                temp = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
                cleanup = temp
                try data.write(to: temp)
            }
            _ = try fm.replaceItemAt(target, withItemAt: temp)
            if hiddenFlag != 0 { chflags(target.path, flags(target) | hiddenFlag) }
        } catch where isPermissionError(error) {
            throw NoteFileError.notWritable(path: target.path)
        }
    }

    private static func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func flags(_ url: URL) -> UInt32 {
        var info = stat()
        return stat(url.path, &info) == 0 ? info.st_flags : 0
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EACCES) || ns.code == Int(EPERM) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    /// Size in bytes of the file `url` points to.
    public static func size(_ url: URL) -> Int? {
        stamp(url)?.size
    }
}
