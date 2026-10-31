import Foundation

/// One ATX heading of a Markdown text, for the outline. See docs/format.md ("Outline").
public struct OutlineHeading: Equatable, Sendable {
    public let level: Int
    /// The heading text without `#` markers and closing `#`s, trimmed.
    public let title: String
    /// UTF-16 offset of the start of the heading's line.
    public let location: Int

    public init(level: Int, title: String, location: Int) {
        self.level = level
        self.title = title
        self.location = location
    }
}

public enum MarkdownOutline {
    /// The ATX headings (`# …` to `###### …`) in document order. Lines inside fenced code are not headings, and
    /// headings with no text are left out.
    public static func headings(in text: String) -> [OutlineHeading] {
        let ns = text as NSString
        var result: [OutlineHeading] = []
        for span in MarkdownStyler.spans(in: text) {
            guard case .heading(let level) = span.kind, NSMaxRange(span.range) <= ns.length else { continue }
            let title = title(of: ns.substring(with: span.range))
            if !title.isEmpty { result.append(OutlineHeading(level: level, title: title, location: span.range.location)) }
        }
        return result
    }

    static func title(of line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        // Closing sequence: `#`s preceded by a space (or the whole remainder).
        if text.hasSuffix("#") {
            let body = text.reversed().drop { $0 == "#" }
            if body.isEmpty { return "" }
            if body.first == " " || body.first == "\t" { text = String(body.reversed()).trimmingCharacters(in: .whitespaces) }
        }
        return text
    }
}
