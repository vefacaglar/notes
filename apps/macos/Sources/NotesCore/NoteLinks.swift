import Foundation

/// Where a link in a note points.
public enum LinkDestination: Equatable, Sendable {
    /// An absolute URL with a scheme (`https:`, `mailto:`, `file:`…).
    case web(URL)
    /// A relative (or absolute) file path, percent-decoded, without `#fragment` and `?query`.
    case file(String)
    /// `[[Note name]]`, `[[Note name|alias]]` or `[[Note name#heading]]`: the note name.
    case wiki(String)
}

/// A file in one of the workspace's roots.
public struct NoteRef: Hashable, Sendable {
    /// Index of the root in the workspace.
    public let root: Int
    /// Path relative to the root, `/`-separated.
    public let path: String

    public init(root: Int, path: String) {
        self.root = root
        self.path = path
    }
}

/// Link classification and resolution, pure so the Windows app can follow the same rules (docs/format.md, "Links").
public enum NoteLinks {
    /// `raw` is the destination of `[text](destination)` or a whole `[[wiki link]]`. `nil` for empty destinations and
    /// in-page anchors (`#heading`).
    public static func classify(_ raw: String) -> LinkDestination? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[["), text.hasSuffix("]]"), text.count >= 5 {
            return wikiName(String(text.dropFirst(2).dropLast(2))).map(LinkDestination.wiki)
        }
        guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
        if let colon = text.firstIndex(of: ":"), text.distance(from: text.startIndex, to: colon) >= 2,
           text[..<colon].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }),
           text.first?.isLetter == true {
            let url = URL(string: text)
                ?? text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
            return url.map(LinkDestination.web)
        }
        var path = text
        if let cut = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = String(path[..<cut]) }
        path = path.removingPercentEncoding ?? path
        return path.isEmpty ? nil : .file(path)
    }

    /// The note name of a wiki link's inner text: before `|` (alias) and `#` (heading), trimmed; `nil` when empty.
    public static func wikiName(_ inner: String) -> String? {
        var name = inner
        if let cut = name.firstIndex(where: { $0 == "|" || $0 == "#" }) { name = String(name[..<cut]) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Case-insensitive comparison key for note names: NFC, lowercased, with Turkish dotless and dotted i folded
    /// to `i` so `ÇALIŞMA` finds `çalışma`.
    public static func foldedName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
            .replacingOccurrences(of: "\u{131}", with: "i")
            .replacingOccurrences(of: "i\u{307}", with: "i")
    }

    /// The file `destination` refers to among `candidates` (every listed file of every root), or `nil`.
    /// `origin` is the note holding the link (`nil` for a file outside the roots).
    ///
    /// - File links are relative to the note's folder and stay inside its root; the match ignores case, and a path
    ///   without extension also tries `.md`. Without an origin they resolve to nothing (the caller tries the disk).
    /// - Wiki links match the file's display name, its file name or its path without `.md`, ignoring case. Of several
    ///   matches the one in the same folder wins, then the same root, then notes over other files, then the
    ///   shortest path.
    public static func resolve(_ destination: LinkDestination, from origin: NoteRef?, among candidates: [NoteRef]) -> NoteRef? {
        switch destination {
        case .web:
            return nil
        case .file(let relative):
            guard let origin, !relative.hasPrefix("/"), let path = join(folder: NoteStore.parent(origin.path), relative) else { return nil }
            let inRoot = candidates.filter { $0.root == origin.root }
            for wanted in [path, (path as NSString).pathExtension.isEmpty ? path + ".md" : nil].compactMap({ $0 }) {
                if let exact = inRoot.first(where: { $0.path == wanted }) { return exact }
                let key = foldedName(wanted)
                if let loose = inRoot.first(where: { foldedName($0.path) == key }) { return loose }
            }
            return nil
        case .wiki(let name):
            let key = foldedName(name)
            let keyWithoutExtension = key.hasSuffix(".md") ? String(key.dropLast(3)) : key
            let matches = candidates.filter { ref in
                let pathKey = foldedName(withoutNoteExtension(ref.path))
                return foldedName(NoteStore.displayName(ref.path)) == keyWithoutExtension
                    || foldedName(NoteStore.lastComponent(ref.path)) == key
                    || (key.contains("/") && (pathKey == keyWithoutExtension || pathKey.hasSuffix("/" + keyWithoutExtension)))
            }
            func rank(_ ref: NoteRef) -> (Int, Int, Int, String) {
                let tier = ref.root == origin?.root
                    ? (NoteStore.parent(ref.path) == origin.map { NoteStore.parent($0.path) } ? 0 : 1) : 2
                return (tier, NoteStore.isNote(ref.path) ? 0 : 1, NoteStore.components(ref.path).count, ref.path)
            }
            return matches.min { rank($0) < rank($1) }
        }
    }

    /// `relative` appended to `folder` with `.` and `..` resolved; `nil` when it climbs out of the root.
    public static func join(folder: String, _ relative: String) -> String? {
        var parts = folder.isEmpty ? [] : NoteStore.components(folder)
        for part in NoteStore.components(relative) {
            switch part {
            case "", ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(part)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// Whether the relative `path` of a note inside a root climbs above that root with `..`. Such a link resolves to
    /// nothing, and the disk is not tried either.
    public static func escapesRoot(_ relative: String, from origin: NoteRef) -> Bool {
        var depth = NoteStore.components(NoteStore.parent(origin.path)).filter { !$0.isEmpty }.count
        for part in NoteStore.components(relative) {
            switch part {
            case "", ".": continue
            case "..":
                if depth == 0 { return true }
                depth -= 1
            default: depth += 1
            }
        }
        return false
    }

    /// Extensions of programs, scripts and installers (lowercase, no dot). A click on a link to such a file shows it in
    /// the file manager instead of opening it; the apps add their own checks (executable bit, bundles).
    public static let programExtensions: Set<String> = [
        "app", "command", "sh", "bash", "zsh", "csh", "ksh", "fish", "pkg", "mpkg", "scpt", "scptd", "workflow", "action", "terminal",
        "exe", "com", "bat", "cmd", "ps1", "psm1", "vbs", "vbe", "wsf", "msi", "msp", "lnk", "scr", "jar", "dmg", "appref-ms",
    ]

    public static func isProgram(fileName: String) -> Bool {
        programExtensions.contains((fileName as NSString).pathExtension.lowercased())
    }

    private static func withoutNoteExtension(_ path: String) -> String {
        NoteStore.isNote(path) || NoteStore.isEncrypted(path) ? (path as NSString).deletingPathExtension : path
    }
}
