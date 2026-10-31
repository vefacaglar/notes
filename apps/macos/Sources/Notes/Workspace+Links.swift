import AppKit
import NotesCore

extension Workspace {
    /// Follows a link clicked in `document`: web addresses go to the system, notes (relative paths and `[[wiki]]`
    /// links) open in a tab here. `raw` is the destination as written (`NoteLinks.classify`).
    func openLink(_ raw: String, from document: NoteDocument) {
        guard let destination = NoteLinks.classify(raw) else { return }
        switch destination {
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
        if NoteStore.isListed(url.lastPathComponent) {
            open(url, newTab: true, focus: true)
        } else if !NSWorkspace.shared.open(url) {
            report(L("The link “\(path)” couldn't be opened."))
        }
    }

    /// The file a link resolves to among the files of all roots; `NoteLinks.resolve` has the rules.
    private func resolvedURL(_ destination: LinkDestination, from document: NoteDocument) -> URL? {
        let candidates = roots.enumerated().flatMap { index, root in
            root.store.notePaths().map { NoteRef(root: index, path: $0) }
        }
        var origin: NoteRef?
        for (index, root) in roots.enumerated() {
            if let path = FilePaths.relative(document.url, to: root.url), !path.isEmpty {
                origin = NoteRef(root: index, path: path)
                break
            }
        }
        guard let ref = NoteLinks.resolve(destination, from: origin, among: candidates) else { return nil }
        return try? roots[ref.root].store.url(for: ref.path)
    }
}
