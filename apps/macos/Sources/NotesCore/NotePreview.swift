import Foundation

/// The one-line preview the sidebar shows under a note's name. See docs/format.md, "Sidebar preview".
extension NoteStore {
    /// How much of a file is read for its preview.
    public static let previewBytes = 2048
    public static let maxPreviewLength = 200

    /// The first line after the title (the first non-blank line) that is not blank, a thematic break or inside a code
    /// fence, with Markdown syntax removed and whitespace runs collapsed to one space. `nil` when there is none.
    public static func preview(from content: String) -> String? {
        let text = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
        let ns = text as NSString
        var skipped: [NSRange] = []
        var removed: [NSRange] = []
        for span in MarkdownStyler.spans(in: text) {
            switch span.kind {
            case .horizontalRule, .codeBlock: skipped.append(span.range)
            case .marker, .listMarker, .taskMarker: removed.append(span.range)
            default: break
            }
        }

        var sawTitle = false
        var location = 0
        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(lineRange)
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
            guard !line.unicodeScalars.allSatisfy(\.properties.isWhitespace) else { continue }
            guard sawTitle else {
                sawTitle = true
                continue
            }
            if skipped.contains(where: { NSIntersectionRange($0, lineRange).length > 0 }) {
                continue
            }
            var kept = IndexSet(integersIn: lineRange.location..<(lineRange.location + (line as NSString).length))
            for range in removed { kept.remove(integersIn: Range(range) ?? 0..<0) }
            let stripped = kept.rangeView.map { ns.substring(with: NSRange($0)) }.joined()
            let words = stripped.split(whereSeparator: { $0.unicodeScalars.allSatisfy(\.properties.isWhitespace) })
            let result = words.joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: "*_~`").union(.whitespaces))
            if !result.isEmpty { return String(result.prefix(maxPreviewLength)) }
        }
        return nil
    }

    /// The preview of the file at `url`, reading only its first `previewBytes` bytes. `nil` when unreadable or empty.
    public static func preview(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard var data = try? handle.read(upToCount: previewBytes), !data.isEmpty else { return nil }
        // The cut may fall inside a multi-byte character: drop up to three bytes of it.
        var text = String(data: data, encoding: .utf8)
        var dropped = 0
        while text == nil, dropped < 3, !data.isEmpty {
            data.removeLast()
            dropped += 1
            text = String(data: data, encoding: .utf8)
        }
        return text.flatMap(preview(from:))
    }
}
