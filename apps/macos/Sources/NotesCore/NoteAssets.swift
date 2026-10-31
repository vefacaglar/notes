import Foundation

/// An image reference `![alt](destination)` found in a Markdown text.
public struct MarkdownImage: Equatable, Sendable {
    /// The whole `![…](…)`, in UTF-16 coordinates.
    public let range: NSRange
    public let alt: String
    /// The destination as written (percent-encoded, without the `<>` or title).
    public let destination: String
}

/// Images in Markdown notes. See docs/format.md ("Images").
public enum MarkdownImages {
    /// The images in `text`, in order, except those inside `excluded` (code spans and fenced blocks, ascending).
    public static func references(in text: String, excluding excluded: [NSRange]) -> [MarkdownImage] {
        let ns = text as NSString
        var result: [MarkdownImage] = []
        var from = 0
        while from < ns.length {
            let found = ns.range(of: "![", options: .literal, range: NSRange(location: from, length: ns.length - from))
            guard found.location != NSNotFound else { break }
            from = found.location + 2
            if isExcluded(found.location, excluded) { continue }
            if found.location > 0, ns.character(at: found.location - 1) == 0x5C { continue }
            if let image = parse(ns, at: found.location) {
                result.append(image)
                from = NSMaxRange(image.range)
            }
        }
        return result
    }

    /// Same, finding code spans itself.
    public static func references(in text: String) -> [MarkdownImage] {
        references(in: text, excluding: codeRanges(in: MarkdownStyler.spans(in: text)))
    }

    /// Ranges of code spans and fenced blocks among `spans`, ascending.
    public static func codeRanges(in spans: [MarkdownSpan]) -> [NSRange] {
        spans.compactMap { $0.kind == .codeBlock || $0.kind == .inlineCode ? $0.range : nil }
    }

    private static func isExcluded(_ location: Int, _ ranges: [NSRange]) -> Bool {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(ranges[mid]) <= location { lo = mid + 1 } else { hi = mid }
        }
        var k = lo
        while k < ranges.count, ranges[k].location <= location {
            if NSLocationInRange(location, ranges[k]) { return true }
            k += 1
        }
        return false
    }

    private static func parse(_ ns: NSString, at start: Int) -> MarkdownImage? {
        let length = ns.length
        func at(_ i: Int) -> unichar? { i < length ? ns.character(at: i) : nil }
        // Alt text: up to the matching `]` on the same line.
        var i = start + 2, depth = 1
        while let c = at(i), c != 0x0A {
            if c == 0x5C { i += 2; continue }
            if c == 0x5B { depth += 1 } else if c == 0x5D { depth -= 1; if depth == 0 { break } }
            i += 1
        }
        guard at(i) == 0x5D, at(i + 1) == 0x28 else { return nil }
        let alt = ns.substring(with: NSRange(location: start + 2, length: i - start - 2))
        i += 2
        func skipSpaces() { while let c = at(i), c == 0x20 || c == 0x09 { i += 1 } }
        skipSpaces()
        var destination: String
        if at(i) == 0x3C {
            let begin = i + 1
            i = begin
            while let c = at(i), c != 0x3E, c != 0x0A { i += 1 }
            guard at(i) == 0x3E else { return nil }
            destination = ns.substring(with: NSRange(location: begin, length: i - begin))
            i += 1
        } else {
            let begin = i
            var parens = 0
            while let c = at(i), c != 0x20, c != 0x09, c != 0x0A, c != 0x0D {
                if c == 0x28 { parens += 1 } else if c == 0x29 { if parens == 0 { break }; parens -= 1 }
                i += 1
            }
            destination = ns.substring(with: NSRange(location: begin, length: i - begin))
        }
        skipSpaces()
        if let quote = at(i), quote == 0x22 || quote == 0x27 {
            i += 1
            while let c = at(i), c != quote, c != 0x0A { i += 1 }
            guard at(i) == quote else { return nil }
            i += 1
            skipSpaces()
        }
        guard at(i) == 0x29, !destination.isEmpty else { return nil }
        return MarkdownImage(range: NSRange(location: start, length: i + 1 - start), alt: alt, destination: destination)
    }

    /// The local file an image destination names: a relative path resolved against `noteFolder` (nil for a draft
    /// without a file), an absolute path, or a `file:` URL. Remote addresses (`http:`…) and anything else give nil.
    public static func fileURL(for destination: String, noteFolder: URL?) -> URL? {
        switch NoteLinks.classify(destination) {
        case .web(let url)?:
            return url.isFileURL ? url.standardizedFileURL : nil
        case .file(let path)?:
            if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
            guard let noteFolder else { return nil }
            return noteFolder.appending(path: path, directoryHint: .notDirectory).standardizedFileURL
        default:
            return nil
        }
    }
}

/// Pasted and dropped images: written to `assets/` next to the note, named after the note.
public enum NoteAssets {
    public static let folderName = "assets"

    /// `<note name> <n>.<ext>`, valid under the portable name rules (`NoteStore.portableName`, the note name capped at
    /// 60 characters; reserved device names fixed).
    public static func fileName(forNote noteName: String, index: Int, fileExtension: String) -> String {
        var base = NoteStore.portableName(noteName, maxCharacters: 60)
        if base.isEmpty { base = "image" }
        return NoteStore.avoidingReservedName("\(base) \(index).\(fileExtension)")
    }

    /// The Markdown destination for a file in the assets folder: `assets/` plus the name percent-encoded
    /// (everything but ASCII letters, digits and `-._~`), so spaces, parentheses and non-ASCII are safe.
    public static func destination(forFileName name: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return folderName + "/" + (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name)
    }

    /// Writes `data` as a new file in the `assets` folder next to the note at `noteURL` (created if missing) and
    /// returns the Markdown destination. The file is written to a hidden temporary file and moved into place, so a
    /// half-written image never shows and an existing file is never replaced.
    public static func save(_ data: Data, forNoteAt noteURL: URL, fileExtension: String = "png") throws -> String {
        let fm = FileManager.default
        let folder = noteURL.deletingLastPathComponent().appending(path: folderName, directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let noteName = noteURL.deletingPathExtension().lastPathComponent
        let temporary = folder.appending(path: ".\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        try data.write(to: temporary, options: .atomic)
        do {
            for index in 1...9_999 {
                let name = fileName(forNote: noteName, index: index, fileExtension: fileExtension)
                let target = folder.appending(path: name, directoryHint: .notDirectory)
                if fm.fileExists(atPath: target.path) { continue }
                do {
                    try fm.moveItem(at: temporary, to: target)
                    return destination(forFileName: name)
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    continue
                }
            }
            throw CocoaError(.fileWriteFileExists)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }
}
