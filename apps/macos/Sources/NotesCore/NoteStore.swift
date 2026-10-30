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
    /// File name without the `.md` extension for notes, folder name for folders.
    public let name: String
    public let isFolder: Bool
    /// `nil` for notes so that `List(children:)` shows no disclosure triangle.
    public let children: [NoteNode]?

    public var id: String { path }
}

public struct SearchHit: Identifiable, Hashable, Sendable {
    public let path: String
    /// 1-based line number of a content match; `nil` when the file name matched.
    public let line: Int?
    public let snippet: String?

    public var id: String { "\(path):\(line ?? 0)" }
}

/// A folder of plain Markdown files. See docs/format.md for the rules both apps follow.
public struct NoteStore: Sendable {
    public let root: URL

    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    public static func isNote(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".md")
    }

    // MARK: Paths

    /// Characters that are invalid in Windows file names; rejected everywhere so notes stay portable.
    private static let forbidden = CharacterSet(charactersIn: "\\:*?\"<>|").union(.controlCharacters)

    public func url(for path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let valid = parts.allSatisfy { part in
            !part.isEmpty
                && !part.hasPrefix(".")
                && !part.hasSuffix(".")
                && !part.hasSuffix(" ")
                && part.rangeOfCharacter(from: Self.forbidden) == nil
        }
        guard valid else { throw NoteStoreError.invalidName(path) }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    private static func join(_ folder: String?, _ name: String) -> String {
        guard let folder, !folder.isEmpty else { return name }
        return folder + "/" + name
    }

    // MARK: Listing

    public func tree() -> [NoteNode] {
        children(of: root, prefix: "")
    }

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
            guard Self.isNote(name) else { return nil }
            return NoteNode(path: path, name: String(name.dropLast(3)), isFolder: false, children: nil)
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
        try Data(text.utf8).write(to: url(for: path), options: .atomic)
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
        let path = Self.join(folder, name)
        let url = try url(for: path)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw NoteStoreError.alreadyExists(path) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url, options: .withoutOverwriting)
        return path
    }

    @discardableResult
    public func createFolder(named name: String, in parent: String? = nil) throws -> String {
        let path = Self.join(parent, name.trimmingCharacters(in: .whitespacesAndNewlines))
        let url = try url(for: path)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw NoteStoreError.alreadyExists(path) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return path
    }

    /// Renames a note or folder in place, keeping the `.md` extension on notes. Returns the new path.
    @discardableResult
    public func rename(_ path: String, to newName: String) throws -> String {
        let fm = FileManager.default
        let source = try url(for: path)
        var newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.contains("/") else { throw NoteStoreError.invalidName(newName) }
        if Self.isNote(path) && !Self.isNote(newName) { newName += ".md" }

        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        let newPath = Self.join(parent, newName)
        guard newPath != path else { return path }
        let target = try url(for: newPath)

        if newPath.lowercased() == path.lowercased() {
            // Case-only rename: on case-insensitive volumes the target "exists", so go through a temporary name.
            let temp = source.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
            try fm.moveItem(at: source, to: temp)
            try fm.moveItem(at: temp, to: target)
        } else {
            guard !fm.fileExists(atPath: target.path) else { throw NoteStoreError.alreadyExists(newPath) }
            try fm.moveItem(at: source, to: target)
        }
        return newPath
    }

    /// Moves a note or folder to the system Trash so it can be recovered.
    public func trash(_ path: String) throws {
        try FileManager.default.trashItem(at: url(for: path), resultingItemURL: nil)
    }

    // MARK: Search

    /// Case- and diacritic-insensitive search over file names and contents. File name matches come first.
    public func search(_ query: String, limit: Int = 100) -> [SearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        var nameHits: [SearchHit] = []
        var contentHits: [SearchHit] = []
        for path in notePaths() {
            if path.dropLast(3).range(of: query, options: options) != nil {
                nameHits.append(SearchHit(path: path, line: nil, snippet: nil))
            }
            guard contentHits.count < limit, let text = try? read(path) else { continue }
            var matchesInFile = 0
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.range(of: query, options: options) != nil else { continue }
                let snippet = String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
                contentHits.append(SearchHit(path: path, line: index + 1, snippet: snippet))
                matchesInFile += 1
                if matchesInFile == 3 { break }
            }
        }
        return Array((nameHits + contentHits).prefix(limit))
    }
}
