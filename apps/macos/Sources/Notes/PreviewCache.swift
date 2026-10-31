import Foundation
import NotesCore

/// The sidebar's one-line previews, read lazily (only for rows that appear) from the first bytes of each file off the
/// main thread and kept until the file's modification date changes.
@Observable @MainActor
final class PreviewCache {
    private struct Entry {
        var modified: Date?
        var text: String?
    }

    /// What a row asked for last, so a change during a read is read again.
    private struct Wanted {
        var modified: Date?
    }

    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var wanted: [String: Wanted] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    private let limit = 5000

    /// The cached preview of `url`; `nil` while it loads or when there is none.
    func preview(for url: URL) -> String? { entries[url.path]?.text }

    /// Makes sure the preview for `url` at `modified` is cached. Only Markdown files have previews.
    func load(_ url: URL, modified: Date?) async {
        guard NoteStore.isMarkdown(url.lastPathComponent) else { return }
        let key = url.path
        wanted[key] = Wanted(modified: modified)
        guard inFlight.insert(key).inserted else { return }
        defer { inFlight.remove(key) }
        while let target = wanted[key] {
            if let entry = entries[key], entry.modified == target.modified { return }
            let text = await Task.detached(priority: .utility) { NoteStore.preview(ofFileAt: url) }.value
            if entries.count >= limit { entries.removeAll() }
            entries[key] = Entry(modified: target.modified, text: text)
        }
    }
}
