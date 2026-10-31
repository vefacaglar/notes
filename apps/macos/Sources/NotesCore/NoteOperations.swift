import Foundation

/// Moving, duplicating and copying items in. Like renaming, none of these ever overwrites: a taken name gets a number.
/// See docs/format.md, "Moving, duplicating and copying in".
extension NoteStore {
    /// `fileName`, or with " 2", " 3"… before the extension (folders have none) until `dir` has no entry by that name,
    /// as the file system sees it. With `marker` the first candidate is already "<stem> <marker>" ("Plan copy.md",
    /// "Plan copy 2.md").
    public static func uniqueItemName(_ fileName: String, isFolder: Bool, marker: String? = nil, in dir: URL) -> String {
        let ext = isFolder ? "" : (fileName as NSString).pathExtension
        let stem = isFolder ? fileName : (fileName as NSString).deletingPathExtension
        let base = marker.map { "\(stem) \($0)" } ?? stem
        var number = 1
        while true {
            let candidate = (number == 1 ? base : "\(base) \(number)") + (ext.isEmpty ? "" : "." + ext)
            if !isTaken(dir.appendingPathComponent(candidate), except: nil) { return candidate }
            number += 1
        }
    }

    /// Whether `child` is `parent` or inside it, comparing resolved paths per Unicode scalar.
    static func isInside(_ child: URL, _ parent: URL) -> Bool {
        func scalars(_ url: URL) -> [Unicode.Scalar] {
            var path = Array(url.resolvingSymlinksInPath().standardizedFileURL.path.unicodeScalars)
            if path.last == "/" { path.removeLast() }
            return path
        }
        let base = scalars(parent), other = scalars(child)
        return other == base || other.starts(with: base + ["/"])
    }

    private func existingFolder(_ folder: String?) throws -> URL {
        guard let folder, !folder.isEmpty else { return root }
        let url = try url(for: folder)
        guard Self.isFolder(url) else { throw NoteStoreError.missingFolder(folder) }
        return url
    }

    /// Moves `path` into `folder` (`nil`: the root) of `destination` (`nil`: this store; another store moves it across
    /// roots). A taken name gets " 2", " 3"…; moving an item to the folder it is already in changes nothing. Throws
    /// when `folder` is the item or inside it. Returns the new path in the destination store.
    @discardableResult
    public func move(_ path: String, to folder: String?, in destination: NoteStore? = nil) throws -> String {
        let fm = FileManager.default
        let target = destination ?? self
        let source = try url(for: path)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        let dir = try target.existingFolder(folder)
        guard !Self.isInside(dir, source) else { throw NoteStoreError.invalidName(Self.lastComponent(path)) }

        let name = Self.lastComponent(path)
        if Self.isSameFile(dir, source.deletingLastPathComponent()) { return path }
        let finalName = Self.uniqueItemName(name, isFolder: isDirectory.boolValue, in: dir)
        try fm.moveItem(at: source, to: dir.appendingPathComponent(finalName))
        return Self.join(folder, finalName)
    }

    /// Copies the file at `path` next to itself as "<name> copy" ("<name> kopya" in Turkish; then " 2", " 3"…).
    /// Returns the copy's path.
    @discardableResult
    public func duplicate(_ path: String) throws -> String {
        let source = try url(for: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        let dir = source.deletingLastPathComponent()
        let name = Self.uniqueItemName(Self.portableFileName(Self.lastComponent(path), isFolder: isDirectory.boolValue),
                                       isFolder: isDirectory.boolValue,
                                       marker: NamingLanguage.current.copyMarker, in: dir)
        try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent(name))
        return Self.join(Self.parent(path), name)
    }

    /// Copies a file or folder from outside the store into `folder` (`nil`: the root), with a unique name. Throws when
    /// the item is missing, hidden (leading "."), or a folder that contains the destination. Returns the new path.
    @discardableResult
    public func copyIn(_ source: URL, to folder: String?) throws -> String {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        let name = source.lastPathComponent
        guard !name.isEmpty, name.unicodeScalars.first != "." else { throw NoteStoreError.invalidName(name) }
        let dir = try existingFolder(folder)
        guard !Self.isInside(dir, source) else { throw NoteStoreError.invalidName(name) }
        let finalName = Self.uniqueItemName(Self.portableFileName(name, isFolder: isDirectory.boolValue),
                                            isFolder: isDirectory.boolValue, in: dir)
        try fm.copyItem(at: source, to: dir.appendingPathComponent(finalName))
        return Self.join(folder, finalName)
    }
}
