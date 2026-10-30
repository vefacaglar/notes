import Foundation

/// The store of drafts, the unsaved notes of new tabs (docs/format.md, "Drafts"): one `<32 lowercase hex>.md` file per
/// draft plus `order.txt` with their tab order, in a folder of the app's own. One process owns a store at a time by
/// holding an exclusive `flock` on its `.lock` file; the OS releases it when the process ends.
public final class DraftStore {
    public static let orderFileName = "order.txt"
    public static let lockFileName = ".lock"

    public let folder: URL
    private var lockDescriptor: Int32 = -1

    public init(folder: URL) {
        self.folder = folder.standardizedFileURL
    }

    deinit {
        unlock()
    }

    /// `<32 lowercase hex digits>.md`; anything else in the folder is not a draft.
    public static func isDraftName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count == 35, scalars[32...] == [".", "m", "d"] else { return false }
        return scalars[..<32].allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    public static func newDraftName() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + ".md"
    }

    public var isLocked: Bool { lockDescriptor >= 0 }

    /// Takes the store's lock for as long as this object lives (or until `unlock()`). `false` when someone else holds it;
    /// throws when the folder or lock file can't be made. After `flock` the descriptor is checked to still be the file
    /// at the lock path: a lock file deleted or replaced meanwhile (by the previous owner's cleanup) would make two
    /// processes believe they hold the lock, so the lock is taken again on the new file.
    public func lock() throws -> Bool {
        if isLocked { return true }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent(Self.lockFileName).path
        for _ in 0..<5 {
            let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { throw Self.posixError() }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                close(descriptor)
                if code == EWOULDBLOCK { return false }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            var held = stat()
            var current = stat()
            if fstat(descriptor, &held) == 0, stat(path, &current) == 0,
               held.st_ino == current.st_ino, held.st_dev == current.st_dev {
                lockDescriptor = descriptor
                return true
            }
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        throw POSIXError(.EAGAIN)
    }

    public func unlock() {
        guard lockDescriptor >= 0 else { return }
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// Where a new draft goes; the folder exists afterwards. Nothing is written until the draft has text.
    public func newDraftURL() throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(Self.newDraftName())
    }

    /// The draft files with text, in their saved order, then the others oldest first. Empty drafts are deleted.
    public func saved() -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)
        else { return [] }
        var drafts: [(url: URL, created: Date)] = []
        for url in urls where Self.isDraftName(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            if values?.fileSize == 0 {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            drafts.append((url, values?.creationDate ?? .distantPast))
        }
        drafts.sort { $0.created != $1.created ? $0.created < $1.created : $0.url.lastPathComponent < $1.url.lastPathComponent }
        let byName = Dictionary(drafts.map { ($0.url.lastPathComponent, $0.url) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var result: [URL] = []
        for name in readOrder() where !seen.contains(name) {
            guard let url = byName[name] else { continue }
            seen.insert(name)
            result.append(url)
        }
        result += drafts.map(\.url).filter { !seen.contains($0.lastPathComponent) }
        return result
    }

    /// The draft names in `order.txt`, in order; empty when it is missing or unreadable.
    public func readOrder() -> [String] {
        guard let text = try? NoteFile.read(folder.appendingPathComponent(Self.orderFileName)) else { return [] }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter(Self.isDraftName)
    }

    /// Writes the tab order of the drafts atomically.
    public func writeOrder(_ names: [String]) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try NoteFile.write(names.joined(separator: "\n"), to: folder.appendingPathComponent(Self.orderFileName))
    }

    /// Moves the drafts of the store at `other` into this one under new names, appended to the order. `false` when a
    /// move failed; the drafts not moved stay where they were.
    @discardableResult
    public func takeDrafts(from other: URL) -> Bool {
        let drafts = DraftStore(folder: other).saved()
        guard !drafts.isEmpty else { return true }
        var moved: [String] = []
        var complete = true
        for draft in drafts {
            let name = Self.newDraftName()
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: draft, to: folder.appendingPathComponent(name))
                moved.append(name)
            } catch {
                complete = false
                break
            }
        }
        try? writeOrder(readOrder() + moved)
        return complete
    }

    /// Takes over every pending store below `pendingRoot` whose lock is free (its process has ended): moves its drafts
    /// in and deletes its folder. A store that is still locked, or whose drafts could not all be moved, stays.
    public func adoptPending(in pendingRoot: URL) {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: pendingRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let pending = DraftStore(folder: folder)
            guard (try? pending.lock()) == true else { continue }
            if takeDrafts(from: folder) { try? FileManager.default.removeItem(at: folder) }
            pending.unlock()
        }
    }
}
