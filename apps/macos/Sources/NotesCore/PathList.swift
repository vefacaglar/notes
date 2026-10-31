import Foundation

/// An ordered list of absolute file paths kept in the app's support folder: the pinned notes (`pins.json`) and the
/// recently opened ones (`recents.json`). App state, not part of any notes folder. See docs/format.md, "App state".
public struct PathList: Codable, Equatable, Sendable {
    public var version = 1
    public var paths: [String]

    public init(paths: [String] = []) {
        self.paths = paths
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.unicodeScalars.elementsEqual(b.unicodeScalars) }

    public func contains(_ path: String) -> Bool {
        paths.contains { Self.same($0, path) }
    }

    /// Adds `path` at the end (a pin).
    public mutating func append(_ path: String) {
        guard !contains(path) else { return }
        paths.append(path)
    }

    public mutating func remove(_ path: String) {
        paths.removeAll { Self.same($0, path) }
    }

    /// Puts `path` first, dropping what is past `limit` (a recent file).
    public mutating func push(_ path: String, limit: Int) {
        remove(path)
        paths.insert(path, at: 0)
        if paths.count > limit { paths.removeLast(paths.count - limit) }
    }

    /// Follows an item that was moved or renamed from `old` to `new`, whole folders included.
    public mutating func moved(from old: String, to new: String) {
        var result: [String] = []
        for path in paths {
            let updated = NoteStore.moved(path, from: old, to: new) ?? path
            if !result.contains(where: { Self.same($0, updated) }) { result.append(updated) }
        }
        paths = result
    }

    /// Drops `path` and everything inside it (the item went to the Trash).
    public mutating func removeItem(at path: String) {
        paths.removeAll { NoteStore.moved($0, from: path, to: $0) != nil }
    }

    public static func read(_ url: URL) -> PathList? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PathList.self, from: data)
    }

    /// Writes atomically, creating the folder.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
