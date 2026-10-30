import Foundation

/// Automatic naming: new notes start as "Adsız" and follow their first line. See docs/format.md.
extension NoteStore {
    public static let untitledName = "Adsız"
    static let maxTitleLength = 60
    static let maxTitleBytes = 200

    /// The first line of `content`: up to the first LF, without a trailing CR. Scans only that far.
    static func firstLine(of content: String) -> Substring {
        let scalars = content.unicodeScalars
        let end = scalars.firstIndex(of: "\n") ?? scalars.endIndex
        var line = scalars[..<end]
        if line.last == "\r" { line.removeLast() }
        return Substring(line)
    }

    /// The first line that is not blank (only Unicode White_Space), found without splitting the whole note.
    static func firstNonBlankLine(of content: String) -> Substring? {
        let scalars = content.unicodeScalars
        var start = scalars.startIndex
        while start < scalars.endIndex {
            let end = scalars[start...].firstIndex(of: "\n") ?? scalars.endIndex
            var line = scalars[start..<end]
            if line.last == "\r" { line.removeLast() }
            if !line.allSatisfy(\.properties.isWhitespace) { return Substring(line) }
            guard end < scalars.endIndex else { break }
            start = scalars.index(after: end)
        }
        return nil
    }

    /// A note name (without `.md`) for `content`: its first non-blank line without Markdown syntax, made valid
    /// under the name rules and capped in length. `nil` when that line leaves nothing usable.
    public static func title(from content: String) -> String? {
        guard let line = firstNonBlankLine(of: content) else { return nil }
        let ns = String(line) as NSString

        // 1–2. Remove Markdown syntax.
        var kept = IndexSet(integersIn: 0..<ns.length)
        for span in MarkdownStyler.spans(in: ns as String) {
            switch span.kind {
            case .horizontalRule, .codeBlock: return nil
            case .marker, .listMarker, .taskMarker: kept.remove(integersIn: Range(span.range) ?? 0..<0)
            default: break
            }
        }
        let text = kept.rangeView.map { ns.substring(with: NSRange($0)) }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "*_~`").union(.whitespaces))

        // 3. Map characters a name can't hold, per Unicode scalar (a "/" with a combining mark is still a "/"),
        // and collapse White_Space runs to one space.
        var mapped = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            let replacement: Unicode.Scalar?
            switch scalar {
            case "?", "*": replacement = nil
            case "\"": replacement = "'"
            case "\\", "/", ":", "<", ">", "|": replacement = "-"
            default: replacement = forbidden.contains(scalar) || scalar.properties.isWhitespace ? " " : scalar
            }
            guard let replacement else { continue }
            if replacement == " " {
                pendingSpace = true
                continue
            }
            if pendingSpace && !mapped.isEmpty { mapped.append(" ") }
            pendingSpace = false
            mapped.append(replacement)
        }
        // Leading dots and spaces go as whole Characters, so a "." carrying a combining mark can't make it hidden.
        var title = Substring(String(mapped))
        title = title.drop { $0.unicodeScalars.first == "." || $0.unicodeScalars.first == " " }
        title = Substring(String(title).precomposedStringWithCanonicalMapping)

        // 4. Cap the length.
        if title.count > maxTitleLength {
            // Cut at the last space within the first 61 Characters if at least 30 come before it.
            let head = title.prefix(maxTitleLength + 1)
            if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= maxTitleLength / 2 {
                title = head[..<space]
            } else {
                title = head.prefix(maxTitleLength)
            }
        }
        while title.utf8.count > maxTitleBytes { title.removeLast() }
        var result = String(title)
        while let last = result.unicodeScalars.last, last == "." || last == " " { result.unicodeScalars.removeLast() }

        // 5. Nothing usable left.
        guard !result.unicodeScalars.allSatisfy({ $0 == "-" || $0 == " " }) else { return nil }
        return avoidingReservedName(result)
    }

    /// `name` with "_" after its stem when Windows reserves it ("CON" → "CON_", "nul.txt" → "nul_.txt").
    static func avoidingReservedName(_ name: String) -> String {
        guard isReservedName(name) else { return name }
        var scalars = name.unicodeScalars
        let dot = scalars.firstIndex(of: ".") ?? scalars.endIndex
        var stemEnd = dot
        while stemEnd > scalars.startIndex, scalars[scalars.index(before: stemEnd)] == " " {
            stemEnd = scalars.index(before: stemEnd)
        }
        scalars.insert("_", at: stemEnd)
        return String(scalars)
    }

    /// Whether a note called `name` follows its first line: its name, ignoring a " 2", " 3"… suffix,
    /// is "Adsız" or the title of `content`.
    public static func isAutoNamed(_ name: String, content: String) -> Bool {
        let base = baseName(name)
        if base == untitledName { return true }
        guard let title = title(from: content) else { return false }
        return name == title || base == title
    }

    /// The name an auto-named note called `name` should get now that it holds `content`, or `nil` to keep its name:
    /// when the first line is blank, yields no title, or the name already matches.
    public static func autoName(for name: String, content: String) -> String? {
        guard !firstLine(of: content).unicodeScalars.allSatisfy(\.properties.isWhitespace),
              let title = title(from: content),
              title != name, title != baseName(name)
        else { return nil }
        return title
    }

    /// `name` without a trailing uniqueness suffix (" 2", " 3"…: ASCII digits, no leading zero, at least 2).
    static func baseName(_ name: String) -> String {
        let scalars = name.unicodeScalars
        guard let space = scalars.lastIndex(of: " "), space > scalars.startIndex else { return name }
        let digits = scalars[scalars.index(after: space)...]
        guard digits.first != "0", !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }),
              let number = Int(String(digits)), number >= 2
        else { return name }
        return String(scalars[..<space])
    }

    /// `name`, or `name 2`, `name 3`…: the first note name (without `.md`) that no entry in `folder` has, as the file
    /// system sees it (so its own case and Unicode folding apply). The note at `ignoring` does not count, so a note
    /// can keep its name or change only its case.
    public func uniqueNoteName(_ name: String, in folder: String?, ignoring path: String? = nil) -> String {
        let dir = folder.flatMap { $0.isEmpty ? nil : try? url(for: $0) } ?? root
        let own = path.flatMap { try? url(for: $0) }
        var candidate = name
        var number = 2
        while Self.isTaken(dir.appendingPathComponent(candidate + ".md"), except: own) {
            candidate = "\(name) \(number)"
            number += 1
        }
        return candidate
    }

    /// Whether something exists at `url` other than the file at `own`.
    static func isTaken(_ url: URL, except own: URL?) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let own else { return true }
        return !isSameFile(url, own)
    }

    /// Where to keep local edits that would overwrite a file changed by another program: "<name> (çakışma).<ext>",
    /// then "<name> (çakışma 2).<ext>"…, the first name for which `isTaken` is false.
    public static func conflictCopyName(for fileName: String, isTaken: (String) -> Bool) -> String {
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        var number = 1
        while true {
            let suffix = number == 1 ? "çakışma" : "çakışma \(number)"
            let candidate = "\(base) (\(suffix))" + (ext.isEmpty ? "" : "." + ext)
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }

    /// `conflictCopyName` for a file anywhere on disk, checked against what its folder holds now.
    public static func conflictCopyURL(for url: URL) -> URL {
        let folder = url.deletingLastPathComponent()
        let name = conflictCopyName(for: url.lastPathComponent) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        return folder.appendingPathComponent(name)
    }
}
