import AppKit
import NotesCore
import UniformTypeIdentifiers

extension Workspace {
    /// Follows a link clicked in `document`: web addresses go to the system, notes (relative paths and `[[wiki]]`
    /// links) open in a tab here. `raw` is the destination as written (`NoteLinks.classify`).
    func openLink(_ raw: String, from document: NoteDocument) {
        guard let destination = NoteLinks.classify(raw) else { return }
        switch destination {
        case .web(let url) where url.isFileURL:
            openLocalFile(url.standardizedFileURL, shown: url.path)
        case .web(let url):
            if !NSWorkspace.shared.open(url) { report(L("The link “\(url.absoluteString)” couldn't be opened.")) }
        case .file(let path):
            openFileLink(path, destination, from: document)
        case .wiki(let name):
            guard let url = resolvedURL(destination, from: document) else {
                report(L("There is no note named “\(name)” in the workspace."))
                return
            }
            open(url, newTab: true, focus: true)
        }
    }

    private func openFileLink(_ path: String, _ destination: LinkDestination, from document: NoteDocument) {
        let url: URL
        if let origin = origin(of: document), !path.hasPrefix("/"), NoteLinks.escapesRoot(path, from: origin) {
            report(L("There is no note named “\((path as NSString).lastPathComponent)” in the workspace."))
            return
        }
        if let resolved = resolvedURL(destination, from: document) {
            url = resolved
        } else {
            // Outside the roots (or an absolute path): look on disk, relative to the note's folder.
            let base = document.url.deletingLastPathComponent()
            let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path, relativeTo: base)
            url = candidate.standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path), !FilePaths.isFolder(url) else {
                report(L("There is no note named “\((path as NSString).lastPathComponent)” in the workspace."))
                return
            }
        }
        openLocalFile(url, shown: path)
    }

    /// Listed files open in a tab; anything else goes to its default app, except programs: a click must never run
    /// one, so those are shown in Finder instead.
    private func openLocalFile(_ url: URL, shown path: String) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            report(L("There is no note named “\((path as NSString).lastPathComponent)” in the workspace."))
            return
        }
        if NoteStore.isListed(url.lastPathComponent) {
            open(url, newTab: true, focus: true)
        } else if Self.isProgram(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if !NSWorkspace.shared.open(url) {
            report(L("The link “\(path)” couldn't be opened."))
        }
    }

    private static func isProgram(_ url: URL) -> Bool {
        if NoteLinks.isProgram(fileName: url.lastPathComponent) { return true }
        let keys: Set<URLResourceKey> = [.isApplicationKey, .isPackageKey, .isExecutableKey, .isDirectoryKey, .contentTypeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        if values.isApplication == true || values.isPackage == true { return true }
        if let type = values.contentType,
           [UTType.application, .executable, .unixExecutable, .shellScript, .aliasFile].contains(where: { type.conforms(to: $0) }) { return true }
        return values.isExecutable == true && values.isDirectory != true
    }

    private func origin(of document: NoteDocument) -> NoteRef? {
        for (index, root) in roots.enumerated() {
            if let path = FilePaths.relative(document.url, to: root.url), !path.isEmpty {
                return NoteRef(root: index, path: path)
            }
        }
        return nil
    }

    /// The file a link resolves to among the files of all roots; `NoteLinks.resolve` has the rules.
    private func resolvedURL(_ destination: LinkDestination, from document: NoteDocument) -> URL? {
        let candidates = roots.enumerated().flatMap { index, root in
            root.store.notePaths().map { NoteRef(root: index, path: $0) }
        }
        guard let ref = NoteLinks.resolve(destination, from: origin(of: document), among: candidates) else { return nil }
        return try? roots[ref.root].store.url(for: ref.path)
    }
}
