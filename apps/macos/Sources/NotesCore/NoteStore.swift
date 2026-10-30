import Foundation

public enum NoteStoreError: LocalizedError, Equatable {
    case invalidName(String)
    case alreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name): "Geçersiz ad: \"\(name)\""
        case .alreadyExists(let name): "Bu adda bir öğe zaten var: \"\(name)\""
        }
    }
}

public struct NoteNode: Identifiable, Hashable, Sendable {
    /// Path relative to the store root, always "/"-separated.
    public let path: String
    /// File name without the `.md` extension for notes, the full file name for other files, folder name for folders.
    public let name: String
    public let isFolder: Bool
    /// `nil` for notes so that `List(children:)` shows no disclosure triangle.
    public let children: [NoteNode]?

    public var id: String { path }
    public var isNote: Bool { !isFolder && NoteStore.isNote(path) }
}

public struct SearchHit: Identifiable, Hashable, Sendable {
    public let path: String
    /// 1-based line number of a content match; `nil` when the file name matched.
    public let line: Int?
    public let snippet: String?

    public var id: String { "\(path):\(line ?? 0)" }
}

/// A folder of plain Markdown notes plus other readable text files. See docs/format.md for the rules both apps follow.
public struct NoteStore: Sendable {
    public let root: URL

    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    /// Notes are the `.md` files; only they are created by New Note and named automatically.
    public static func isNote(_ path: String) -> Bool {
        (lastComponent(path) as NSString).pathExtension.lowercased() == "md"
    }

    /// Extensions (lowercased) of the files that are listed, searched and opened: notes, code and plain text.
    public static let listedExtensions = CodeLanguage.fileExtensions.union(["txt", "log", "csv"])

    public static func isListed(_ path: String) -> Bool {
        let ext = (lastComponent(path) as NSString).pathExtension.lowercased()
        return !ext.isEmpty && listedExtensions.contains(ext)
    }

    // MARK: Paths

    // Paths are split on the scalar "/", never on Characters: "/" followed by a combining mark, ZWJ or emoji
    // modifier forms one Character, so `String.split(separator: "/")` or `hasPrefix` would miss the separator.

    public static func components(_ path: String) -> [String] {
        path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map { String($0) }
    }

    public static func lastComponent(_ path: String) -> String {
        components(path).last ?? path
    }

    /// The containing folder's path; empty for items in the root.
    public static func parent(_ path: String) -> String {
        components(path).dropLast().joined(separator: "/")
    }

    /// The name shown for an item: the file name without `.md` for notes, the full name otherwise.
    public static func displayName(_ path: String) -> String {
        let name = lastComponent(path)
        return isNote(name) ? (name as NSString).deletingPathExtension : name
    }

    /// `path` rewritten after `old` was renamed to `new`; `nil` when `path` is not `old` or inside it.
    public static func moved(_ path: String, from old: String, to new: String) -> String? {
        if path.unicodeScalars.elementsEqual(old.unicodeScalars) { return new }
        let prefix = (old + "/").unicodeScalars
        guard path.unicodeScalars.starts(with: prefix) else { return nil }
        return new + "/" + String(path.unicodeScalars.dropFirst(prefix.count))
    }

    /// Characters that are invalid in Windows file names; rejected in names the user types so notes stay portable.
    /// Only C0/C1 controls: `.controlCharacters` would also reject format characters such as the emoji joiner U+200D.
    static let forbidden = CharacterSet(charactersIn: "\\:*?\"<>|")
        .union(CharacterSet(charactersIn: "\u{0}"..."\u{1F}"))
        .union(CharacterSet(charactersIn: "\u{7F}"..."\u{9F}"))

    /// Device names Windows reserves, with or without an extension (`CON`, `con.txt`, `LPT1.md`…).
    static let reservedNames: Set<String> = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })

    /// Whether `name`'s part before the first "." (trailing spaces ignored) is a reserved device name.
    public static func isReservedName(_ name: String) -> Bool {
        let stem = String(name.unicodeScalars.prefix { $0 != "." })
        var trimmed = stem.unicodeScalars
        while trimmed.last == " " { trimmed.removeLast() }
        return reservedNames.contains(String(trimmed).uppercased())
    }

    /// Whether `name` may be given to a new or renamed item: the portable (Windows) file name rules.
    /// Checked per Unicode scalar, so a "." or "/" carrying a combining mark is still caught.
    public static func isValidName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        return !scalars.isEmpty
            && scalars.first != "."
            && scalars.last != "."
            && scalars.last != " "
            && !scalars.contains("/")
            && name.rangeOfCharacter(from: forbidden) == nil
            && !isReservedName(name)
    }

    /// The URL of an existing item. Lenient so files made elsewhere (e.g. `Why?.md`) still open: it only rejects
    /// empty components and components starting with "." (hidden names, `.` and `..`), so the path can't leave the root.
    public func url(for path: String) throws -> URL {
        let parts = Self.components(path)
        guard parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.first != "." }) else {
            throw NoteStoreError.invalidName(path)
        }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    /// The URL for a new item called `name` in `folder`, after checking `name` against the portable rules.
    private func newURL(named name: String, in folder: String?) throws -> (path: String, url: URL) {
        guard Self.isValidName(name) else { throw NoteStoreError.invalidName(name) }
        let path = Self.join(folder, name)
        return (path, try url(for: path))
    }

    private static func join(_ folder: String?, _ name: String) -> String {
        guard let folder, !folder.isEmpty else { return name }
        return folder + "/" + name
    }

    // MARK: Listing

    public func tree() -> [NoteNode] {
        children(of: root, prefix: "")
    }

    /// Paths of all listed files (notes and other text files), in display order.
    public func notePaths() -> [String] {
        func flatten(_ nodes: [NoteNode]) -> [String] {
            nodes.flatMap { $0.isFolder ? flatten($0.children ?? []) : [$0.path] }
        }
        return flatten(tree())
    }

    private func children(of dir: URL, prefix: String) -> [NoteNode] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        let nodes: [NoteNode] = urls.compactMap { url in
            let name = url.lastPathComponent
            let path = prefix + name
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isFolder {
                return NoteNode(path: path, name: name, isFolder: true, children: children(of: url, prefix: path + "/"))
            }
            guard Self.isListed(name) else { return nil }
            return NoteNode(path: path, name: Self.displayName(name), isFolder: false, children: nil)
        }
        return nodes.sorted { a, b in
            a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: Reading & writing

    public func read(_ path: String) throws -> String {
        try String(contentsOf: url(for: path), encoding: .utf8)
    }

    public func write(_ text: String, to path: String) throws {
        try NoteFile.write(text, to: url(for: path))
    }

    public func modificationDate(_ path: String) -> Date? {
        guard let url = try? url(for: path) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: Managing

    /// Creates an empty note, appending `.md` when missing. Returns its path.
    @discardableResult
    public func createNote(named name: String, in folder: String? = nil) throws -> String {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !Self.isNote(name) { name += ".md" }
        let (path, url) = try newURL(named: name, in: folder)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw NoteStoreError.alreadyExists(path) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url, options: .withoutOverwriting)
        return path
    }

    @discardableResult
    public func createFolder(named name: String, in parent: String? = nil) throws -> String {
        let (path, url) = try newURL(named: name.trimmingCharacters(in: .whitespacesAndNewlines), in: parent)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw NoteStoreError.alreadyExists(path) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return path
    }

    /// Renames an item in place. Notes keep their `.md` extension; other files keep theirs unless the new name ends in
    /// a listed extension (so "Toplantı 3.5" for `a.txt` gives `Toplantı 3.5.txt`).
    /// Returns the new path.
    @discardableResult
    public func rename(_ path: String, to newName: String) throws -> String {
        let fm = FileManager.default
        let source = try url(for: path)
        var newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, !newName.unicodeScalars.contains("/") else { throw NoteStoreError.invalidName(newName) }
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isFolder) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        let oldExtension = (path as NSString).pathExtension
        if !isFolder.boolValue && Self.isNote(path) {
            if !Self.isNote(newName) { newName += ".md" }
        } else if !isFolder.boolValue, !oldExtension.isEmpty, !Self.isListed(newName) {
            newName += "." + oldExtension
        }

        let parent = Self.parent(path)
        let newPath = Self.join(parent, newName)
        guard newPath != path else { return path }
        let target = try newURL(named: newName, in: parent).url

        if fm.fileExists(atPath: target.path) {
            // The same file under another spelling (case, or Unicode folding) is a rename the volume can't do in
            // one step, so go through a temporary name and move back if the second step fails.
            guard Self.isSameFile(source, target) else { throw NoteStoreError.alreadyExists(newPath) }
            let temp = source.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
            try fm.moveItem(at: source, to: temp)
            do {
                try fm.moveItem(at: temp, to: target)
            } catch {
                try? fm.moveItem(at: temp, to: source)
                throw error
            }
        } else {
            try fm.moveItem(at: source, to: target)
        }
        return newPath
    }

    /// Whether both URLs name the same existing file system object (e.g. "a.md" and "A.md" on a case-insensitive volume).
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        func identifier(_ url: URL) -> (any NSObjectProtocol)? {
            (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
        }
        guard let x = identifier(a), let y = identifier(b) else { return false }
        return x.isEqual(y)
    }

    /// Moves a note or folder to the system Trash so it can be recovered.
    public func trash(_ path: String) throws {
        try FileManager.default.trashItem(at: url(for: path), resultingItemURL: nil)
    }

    // MARK: Search

    /// Case- and diacritic-insensitive search over file names and contents. File name matches come first.
    public func search(_ query: String, limit: Int = 100) -> [SearchHit] {
        let query = Self.foldDotlessI(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        var nameHits: [SearchHit] = []
        var contentHits: [SearchHit] = []
        for path in notePaths() {
            let name = Self.isNote(path) ? (path as NSString).deletingPathExtension : path
            if Self.foldDotlessI(name).range(of: query, options: options) != nil {
                nameHits.append(SearchHit(path: path, line: nil, snippet: nil))
            }
            guard contentHits.count < limit, let text = try? read(path) else { continue }
            var matchesInFile = 0
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard Self.foldDotlessI(String(line)).range(of: query, options: options) != nil else { continue }
                let snippet = String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
                contentHits.append(SearchHit(path: path, line: index + 1, snippet: snippet))
                matchesInFile += 1
                if matchesInFile == 3 { break }
            }
        }
        return Array((nameHits + contentHits).prefix(limit))
    }

    /// `.diacriticInsensitive` leaves Turkish ı/İ alone, so "toplanti" would miss "Toplantı".
    private static func foldDotlessI(_ text: String) -> String {
        guard text.contains(where: { $0 == "ı" || $0 == "İ" }) else { return text }
        return text.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "i")
    }
}
