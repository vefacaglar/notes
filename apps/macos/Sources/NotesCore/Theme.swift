import Foundation

// MARK: - Color

/// An sRGB color with 8-bit channels, written as `#RRGGBB` or `#RRGGBBAA` in theme files.
public struct ThemeColor: Hashable, Sendable, Codable, CustomStringConvertible {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Strict: `#` followed by exactly 6 or 8 hex digits (either case), nothing else.
    public init(hex: String) throws {
        let utf8 = Array(hex.utf8)
        guard utf8.first == UInt8(ascii: "#"), utf8.count == 7 || utf8.count == 9 else {
            throw ThemeError.invalidColor(hex)
        }
        var bytes: [UInt8] = []
        var i = 1
        while i < utf8.count {
            guard let high = Self.hexValue(utf8[i]), let low = Self.hexValue(utf8[i + 1]) else {
                throw ThemeError.invalidColor(hex)
            }
            bytes.append(high << 4 | low)
            i += 2
        }
        self.init(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes.count == 4 ? bytes[3] : 255)
    }

    /// Uppercase `#RRGGBB`, or `#RRGGBBAA` when not opaque.
    public var hex: String {
        let channels = alpha == 255 ? [red, green, blue] : [red, green, blue, alpha]
        return "#" + channels.map { String(format: "%02X", $0) }.joined()
    }

    public var description: String { hex }

    public var redComponent: Double { Double(red) / 255 }
    public var greenComponent: Double { Double(green) / 255 }
    public var blueComponent: Double { Double(blue) / 255 }
    public var alphaComponent: Double { Double(alpha) / 255 }

    /// This color blended over an opaque `background` (source-over), as it appears on screen.
    public func composited(over background: ThemeColor) -> ThemeColor {
        let a = alphaComponent
        func mix(_ top: UInt8, _ bottom: UInt8) -> UInt8 {
            UInt8((Double(top) * a + Double(bottom) * (1 - a)).rounded())
        }
        return ThemeColor(red: mix(red, background.red), green: mix(green, background.green), blue: mix(blue, background.blue))
    }

    /// WCAG 2 relative luminance of the color's RGB channels (alpha ignored).
    public var relativeLuminance: Double {
        func linear(_ v: UInt8) -> Double {
            let c = Double(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public var opaque: ThemeColor { ThemeColor(red: red, green: green, blue: blue) }

    /// WCAG 2 contrast ratio (1…21) of `foreground` drawn on `background`. A translucent foreground is composited
    /// over the background; the background's own alpha is ignored, so composite a translucent background over
    /// whatever lies beneath it first (`ResolvedTheme.contrastRatio` does that with the theme background).
    public static func contrastRatio(_ foreground: ThemeColor, on background: ThemeColor) -> Double {
        let opaqueBackground = background.opaque
        let opaqueForeground = foreground.alpha == 255 ? foreground : foreground.composited(over: opaqueBackground)
        let l1 = opaqueForeground.relativeLuminance, l2 = opaqueBackground.relativeLuminance
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    public static let white = ThemeColor(red: 255, green: 255, blue: 255)
    public static let black = ThemeColor(red: 0, green: 0, blue: 0)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        do {
            try self.init(hex: string)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid color")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    fileprivate static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

// MARK: - Errors

public enum ThemeError: Error, Hashable, Sendable, LocalizedError {
    case invalidColor(String)
    /// The file is valid JSON but not an object.
    case invalidJSON
    /// The file breaks the JSON grammar in docs/themes.md.
    case malformedJSON(line: Int, reason: String)
    case notUTF8
    case missingField(String)
    case invalidValue(field: String, reason: String)
    case fileTooLarge
    case tooManyFiles
    case unreadable(String)
    case duplicateID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidColor(let value):
            "Geçersiz renk \"\(value)\": #RRGGBB ya da #RRGGBBAA biçiminde olmalı."
        case .invalidJSON:
            "Dosya geçerli bir JSON nesnesi değil."
        case .malformedJSON(let line, let reason):
            "JSON hatası, satır \(line): \(reason)"
        case .notUTF8:
            "Dosya UTF-8 olarak kaydedilmeli (UTF-16 desteklenmez)."
        case .missingField(let field):
            "\"\(field)\" alanı eksik."
        case .invalidValue(let field, let reason):
            "\"\(field)\" alanı geçersiz: \(reason)"
        case .fileTooLarge:
            "Dosya bir tema için fazla büyük (en çok 1.000.000 bayt)."
        case .tooManyFiles:
            "Klasörde en çok \(ThemeLibrary.maxFileCount) tema dosyası okunur; bu dosya atlandı."
        case .unreadable(let reason):
            "Dosya okunamadı: \(reason)"
        case .duplicateID(let id):
            "\"\(id)\" kimliği başka bir tema tarafından kullanılıyor; bu dosya yok sayıldı."
        }
    }
}

// MARK: - Theme

public enum ThemeAppearance: String, Codable, Sendable, CaseIterable {
    case light, dark

    public var displayName: String {
        switch self {
        case .light: "Açık"
        case .dark: "Koyu"
        }
    }
}

/// The app-wide appearance setting.
public enum AppearanceMode: String, Codable, Sendable, CaseIterable {
    case system, light, dark

    public var displayName: String {
        switch self {
        case .system: "Sistem"
        case .light: "Açık"
        case .dark: "Koyu"
        }
    }

    /// The appearance to draw with, given what the system currently uses.
    public func effectiveAppearance(system: ThemeAppearance) -> ThemeAppearance {
        switch self {
        case .system: system
        case .light: .light
        case .dark: .dark
        }
    }
}

/// What the user picked: the appearance mode plus one theme for each appearance.
public struct ThemePreferences: Codable, Hashable, Sendable {
    public var mode: AppearanceMode
    public var lightThemeID: String
    public var darkThemeID: String

    public init(
        mode: AppearanceMode = .system,
        lightThemeID: String = ThemeLibrary.defaultLightID,
        darkThemeID: String = ThemeLibrary.defaultDarkID
    ) {
        self.mode = mode
        self.lightThemeID = lightThemeID
        self.darkThemeID = darkThemeID
    }

    public func themeID(for appearance: ThemeAppearance) -> String {
        appearance == .light ? lightThemeID : darkThemeID
    }

    private enum CodingKeys: String, CodingKey {
        case mode, lightThemeID, darkThemeID
    }

    /// Lenient: a missing or malformed key falls back to its default without losing the others.
    /// Unknown theme ids are kept; `ThemeLibrary` falls back when it resolves them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil }
        self.init(
            mode: string(.mode).flatMap(AppearanceMode.init(rawValue:)) ?? .system,
            lightThemeID: string(.lightThemeID) ?? ThemeLibrary.defaultLightID,
            darkThemeID: string(.darkThemeID) ?? ThemeLibrary.defaultDarkID
        )
    }
}

/// A theme as written in a JSON file. Everything except `name` and `appearance` is optional;
/// missing values come from the default built-in theme of the same appearance (see `docs/themes.md`).
public struct Theme: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var appearance: ThemeAppearance
    public var colors: Colors
    public var syntax: Syntax

    /// Applies the same normalization and validation as reading a file (trims, NFC).
    public init(id: String, name: String, appearance: ThemeAppearance, colors: Colors = .init(), syntax: Syntax = .init()) throws {
        self.id = id
        self.name = name
        self.appearance = appearance
        self.colors = colors
        self.syntax = syntax
        try normalize()
    }

    public struct Colors: Codable, Hashable, Sendable {
        /// Editor background.
        public var background: ThemeColor?
        public var text: ThemeColor?
        public var secondaryText: ThemeColor?
        /// Dimmed Markdown syntax: `#`, `**`, `` ` ``, `>`, list and link punctuation.
        public var marker: ThemeColor?
        public var heading: ThemeColor?
        public var link: ThemeColor?
        public var inlineCode: ThemeColor?
        public var inlineCodeBackground: ThemeColor?
        public var codeBlockBackground: ThemeColor?
        public var blockquote: ThemeColor?
        public var selection: ThemeColor?
        public var cursor: ThemeColor?
        public var accent: ThemeColor?

        public init(
            background: ThemeColor? = nil, text: ThemeColor? = nil, secondaryText: ThemeColor? = nil,
            marker: ThemeColor? = nil, heading: ThemeColor? = nil, link: ThemeColor? = nil,
            inlineCode: ThemeColor? = nil, inlineCodeBackground: ThemeColor? = nil, codeBlockBackground: ThemeColor? = nil,
            blockquote: ThemeColor? = nil, selection: ThemeColor? = nil, cursor: ThemeColor? = nil, accent: ThemeColor? = nil
        ) {
            self.background = background; self.text = text; self.secondaryText = secondaryText
            self.marker = marker; self.heading = heading; self.link = link
            self.inlineCode = inlineCode; self.inlineCodeBackground = inlineCodeBackground; self.codeBlockBackground = codeBlockBackground
            self.blockquote = blockquote; self.selection = selection; self.cursor = cursor; self.accent = accent
        }
    }

    /// One color per `CodeSpan.Kind`.
    public struct Syntax: Codable, Hashable, Sendable {
        public var keyword: ThemeColor?
        public var string: ThemeColor?
        public var number: ThemeColor?
        public var comment: ThemeColor?
        public var literal: ThemeColor?
        public var type: ThemeColor?
        public var property: ThemeColor?
        public var tag: ThemeColor?

        public init(
            keyword: ThemeColor? = nil, string: ThemeColor? = nil, number: ThemeColor? = nil, comment: ThemeColor? = nil,
            literal: ThemeColor? = nil, type: ThemeColor? = nil, property: ThemeColor? = nil, tag: ThemeColor? = nil
        ) {
            self.keyword = keyword; self.string = string; self.number = number; self.comment = comment
            self.literal = literal; self.type = type; self.property = property; self.tag = tag
        }
    }

    /// Fonts are app settings, not part of a theme; a `fonts` key in older files is ignored like any unknown key.
    private enum CodingKeys: String, CodingKey {
        case id, name, appearance, colors, syntax
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? (decoder.userInfo[Self.fallbackIDKey] as? String)
        guard let id else { throw ThemeError.missingField("id") }
        self.id = id
        name = try c.decode(String.self, forKey: .name)
        appearance = try c.decode(ThemeAppearance.self, forKey: .appearance)
        colors = try c.decodeIfPresent(Colors.self, forKey: .colors) ?? .init()
        syntax = try c.decodeIfPresent(Syntax.self, forKey: .syntax) ?? .init()
        try normalize()
    }

    /// Trims `id` and `name`, normalizes them to NFC, then validates.
    private mutating func normalize() throws {
        func clean(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        }
        id = clean(id)
        name = clean(name)
        if id.isEmpty { throw ThemeError.invalidValue(field: "id", reason: "boş olamaz.") }
        if name.isEmpty { throw ThemeError.invalidValue(field: "name", reason: "boş olamaz.") }
    }

    private static let fallbackIDKey = CodingUserInfoKey(rawValue: "notes.theme.fallbackID")!

    /// Decodes a theme file. `fallbackID` (usually the file name) is used when the JSON has no `id`.
    /// The bytes must follow the strict grammar in docs/themes.md (UTF-8, no comments, no trailing commas,
    /// no duplicate keys, depth ≤ 64). Errors are `ThemeError`s with Turkish messages naming the offending field.
    public static func decode(_ data: Data, fallbackID: String? = nil) throws -> Theme {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard !bytes.contains(0), String(bytes: bytes, encoding: .utf8) != nil else { throw ThemeError.notUTF8 }
        var validator = StrictJSONValidator(bytes)
        try validator.run()

        let decoder = JSONDecoder()
        if let fallbackID { decoder.userInfo[fallbackIDKey] = fallbackID }
        do {
            return try decoder.decode(Theme.self, from: Data(bytes))
        } catch let error as ThemeError {
            throw error
        } catch let error as DecodingError {
            throw ThemeError(error)
        }
    }

    /// Pretty-printed JSON with only the fields that are set, ready to save as a user theme.
    /// Normalizes and validates first, like `init`, so what it writes always reads back.
    public func encodedJSON() throws -> Data {
        var theme = self
        try theme.normalize()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(theme)
    }

    /// Fills every missing value from `base`. The editor background is always opaque (its alpha is ignored).
    public func resolved(over base: ResolvedTheme) -> ResolvedTheme {
        let c = colors, b = base.colors, s = syntax, bs = base.syntax
        return ResolvedTheme(
            id: id, name: name, appearance: appearance,
            colors: .init(
                background: (c.background ?? b.background).opaque, text: c.text ?? b.text,
                secondaryText: c.secondaryText ?? b.secondaryText, marker: c.marker ?? b.marker,
                heading: c.heading ?? b.heading, link: c.link ?? b.link,
                inlineCode: c.inlineCode ?? b.inlineCode, inlineCodeBackground: c.inlineCodeBackground ?? b.inlineCodeBackground,
                codeBlockBackground: c.codeBlockBackground ?? b.codeBlockBackground, blockquote: c.blockquote ?? b.blockquote,
                selection: c.selection ?? b.selection, cursor: c.cursor ?? b.cursor, accent: c.accent ?? b.accent
            ),
            syntax: .init(
                keyword: s.keyword ?? bs.keyword, string: s.string ?? bs.string, number: s.number ?? bs.number,
                comment: s.comment ?? bs.comment, literal: s.literal ?? bs.literal, type: s.type ?? bs.type,
                property: s.property ?? bs.property, tag: s.tag ?? bs.tag
            )
        )
    }
}

private extension ThemeError {
    init(_ error: DecodingError) {
        func path(_ codingPath: [CodingKey], _ last: CodingKey? = nil) -> String {
            (codingPath + (last.map { [$0] } ?? [])).map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            self = .missingField(path(context.codingPath, key))
        case .valueNotFound(_, let context):
            self = context.codingPath.isEmpty
                ? .invalidJSON
                : .invalidValue(field: path(context.codingPath), reason: "null olamaz.")
        case .typeMismatch(let type, let context):
            let expected = type == String.self ? "metin" : (type == Double.self ? "sayı" : "nesne")
            self = context.codingPath.isEmpty
                ? .invalidJSON
                : .invalidValue(field: path(context.codingPath), reason: "\(expected) bekleniyordu.")
        case .dataCorrupted(let context):
            let field = path(context.codingPath)
            if field.isEmpty {
                self = .invalidJSON
            } else if context.codingPath.last?.stringValue == "appearance" {
                self = .invalidValue(field: field, reason: "\"light\" ya da \"dark\" olmalı.")
            } else if context.debugDescription == "invalid color" {
                self = .invalidValue(field: field, reason: "#RRGGBB ya da #RRGGBBAA biçiminde bir renk olmalı.")
            } else {
                self = .invalidValue(field: field, reason: "okunamadı.")
            }
        @unknown default:
            self = .invalidJSON
        }
    }
}

/// A theme with every value filled in, ready for the editor.
public struct ResolvedTheme: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var appearance: ThemeAppearance
    public var colors: Colors
    public var syntax: Syntax

    public struct Colors: Hashable, Sendable {
        public var background, text, secondaryText, marker, heading, link: ThemeColor
        public var inlineCode, inlineCodeBackground, codeBlockBackground, blockquote, selection, cursor, accent: ThemeColor
    }

    public struct Syntax: Hashable, Sendable {
        public var keyword, string, number, comment, literal, type, property, tag: ThemeColor

        public subscript(kind: CodeSpan.Kind) -> ThemeColor {
            switch kind {
            case .keyword: keyword
            case .string: string
            case .number: number
            case .comment: comment
            case .literal: literal
            case .type: type
            case .property: property
            case .tag: tag
            }
        }
    }

    /// Contrast of `foreground` on `background` (default: the editor background) as drawn by this theme:
    /// a translucent background is composited over the editor background, then a translucent foreground over that.
    public func contrastRatio(_ foreground: ThemeColor, on background: ThemeColor? = nil) -> Double {
        let canvas = (background ?? colors.background).composited(over: colors.background)
        return ThemeColor.contrastRatio(foreground, on: canvas)
    }
}

// MARK: - Library

/// Built-in themes plus the user's themes loaded from a directory of `.json` files.
public struct ThemeLibrary: Sendable {
    public struct Issue: Hashable, Sendable, CustomStringConvertible {
        public var file: URL
        public var error: ThemeError

        public var description: String { "\(file.lastPathComponent): \(error.localizedDescription)" }
    }

    public static let defaultLightID = "default-light"
    public static let defaultDarkID = "default-dark"
    public static let maxFileSize = 1_000_000
    /// More `.json` files than this (in file-name order) are reported as `tooManyFiles` and not read.
    public static let maxFileCount = 500

    public static let builtInThemes: [Theme] = BuiltInThemes.json.map { json in
        do {
            return try Theme.decode(Data(json.utf8))
        } catch {
            preconditionFailure("Built-in theme does not decode: \(error)")
        }
    }

    public static func isBuiltIn(_ id: String) -> Bool { builtInThemes.contains { $0.id == id } }

    /// The complete built-in theme every theme of `appearance` falls back to.
    public static func baseTheme(for appearance: ThemeAppearance) -> ResolvedTheme {
        appearance == .light ? baseLight : baseDark
    }

    private static let baseLight = complete(defaultLightID)
    private static let baseDark = complete(defaultDarkID)

    private static func complete(_ id: String) -> ResolvedTheme {
        let theme = builtInThemes.first { $0.id == id }!
        let c = theme.colors, s = theme.syntax
        func v(_ color: ThemeColor?) -> ThemeColor {
            guard let color else { preconditionFailure("Base theme \(id) must set every color") }
            return color
        }
        return ResolvedTheme(
            id: theme.id, name: theme.name, appearance: theme.appearance,
            colors: .init(
                background: v(c.background), text: v(c.text), secondaryText: v(c.secondaryText), marker: v(c.marker),
                heading: v(c.heading), link: v(c.link), inlineCode: v(c.inlineCode), inlineCodeBackground: v(c.inlineCodeBackground),
                codeBlockBackground: v(c.codeBlockBackground), blockquote: v(c.blockquote), selection: v(c.selection),
                cursor: v(c.cursor), accent: v(c.accent)
            ),
            syntax: .init(
                keyword: v(s.keyword), string: v(s.string), number: v(s.number), comment: v(s.comment),
                literal: v(s.literal), type: v(s.type), property: v(s.property), tag: v(s.tag)
            )
        )
    }

    /// User themes sorted by name, then id.
    public private(set) var userThemes: [Theme] = []
    /// Files that were skipped, in file-name order.
    public private(set) var issues: [Issue] = []
    private var userFiles: [String: URL] = [:]

    /// Loads every `*.json` file directly inside `userDirectory` (hidden files and subfolders are ignored; symlinks
    /// are followed). A missing directory simply means no user themes. Nothing here throws or crashes.
    ///
    /// Does synchronous file IO (up to `maxFileCount` files of `maxFileSize` bytes): build it off the main actor.
    public init(userDirectory: URL? = nil) {
        guard let userDirectory else { return }
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: userDirectory.resolvingSymlinksInPath(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            issues.append(Issue(file: userDirectory, error: .unreadable(error.localizedDescription)))
            return
        }
        var seen = Set(Self.builtInThemes.map(\.id))
        var loaded = 0
        let files = urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { (name: $0.lastPathComponent.precomposedStringWithCanonicalMapping, url: $0) }
            // Ordinal by Unicode scalar value of the NFC name (= UTF-8 byte order), see docs/themes.md.
            .sorted { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }
        for (name, file) in files {
            let target = file.resolvingSymlinksInPath()
            if (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            do {
                loaded += 1
                guard loaded <= Self.maxFileCount else { throw ThemeError.tooManyFiles }
                let theme = try Self.load(target, fallbackID: String(name.dropLast(5)))
                guard seen.insert(theme.id).inserted else { throw ThemeError.duplicateID(theme.id) }
                userThemes.append(theme)
                userFiles[theme.id] = file
            } catch let error as ThemeError {
                issues.append(Issue(file: file, error: error))
            } catch {
                issues.append(Issue(file: file, error: .unreadable(error.localizedDescription)))
            }
        }
        userThemes.sort {
            switch $0.name.localizedStandardCompare($1.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: $0.id < $1.id
            }
        }
    }

    /// `file` has its symlinks resolved already, so the regular-file check sees the target.
    private static func load(_ file: URL, fallbackID: String) throws -> Theme {
        let values: URLResourceValues
        do {
            values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw ThemeError.unreadable(error.localizedDescription)
        }
        guard values.isRegularFile == true else { throw ThemeError.unreadable("normal bir dosya değil.") }
        if let size = values.fileSize, size > maxFileSize { throw ThemeError.fileTooLarge }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maxFileSize + 1) ?? Data()
        } catch {
            throw ThemeError.unreadable(error.localizedDescription)
        }
        if data.count > maxFileSize { throw ThemeError.fileTooLarge }
        return try Theme.decode(data, fallbackID: fallbackID)
    }

    /// Built-ins first (in their fixed order), then user themes.
    public var themes: [Theme] { Self.builtInThemes + userThemes }

    public func themes(for appearance: ThemeAppearance) -> [Theme] {
        themes.filter { $0.appearance == appearance }
    }

    public func theme(id: String) -> Theme? {
        themes.first { $0.id == id }
    }

    /// The JSON file a user theme came from; nil for built-ins.
    public func fileURL(forThemeID id: String) -> URL? { userFiles[id] }

    public func resolved(_ theme: Theme) -> ResolvedTheme {
        theme.resolved(over: Self.baseTheme(for: theme.appearance))
    }

    /// The theme to draw with. An unknown id, or a theme of the other appearance, falls back to the default for `appearance`.
    public func resolvedTheme(id: String, for appearance: ThemeAppearance) -> ResolvedTheme {
        guard let theme = theme(id: id), theme.appearance == appearance else { return Self.baseTheme(for: appearance) }
        return resolved(theme)
    }

    public func resolvedTheme(for preferences: ThemePreferences, systemAppearance: ThemeAppearance) -> ResolvedTheme {
        let appearance = preferences.mode.effectiveAppearance(system: systemAppearance)
        return resolvedTheme(id: preferences.themeID(for: appearance), for: appearance)
    }
}

// MARK: - Built-in themes

/// Stored as the same JSON a user would write (see docs/themes.md).
enum BuiltInThemes {
    static let json: [String] = [defaultLight, sepia, paper, defaultDark, midnight, ocean]

    static let defaultLight = """
    {
      "id": "default-light",
      "name": "Varsayılan Açık",
      "appearance": "light",
      "colors": {
        "background": "#FFFFFF",
        "text": "#1F1F1F",
        "secondaryText": "#6E6E73",
        "marker": "#8A8A8F",
        "heading": "#1D1D1F",
        "link": "#0068DA",
        "inlineCode": "#B42318",
        "inlineCodeBackground": "#F1F1F3",
        "codeBlockBackground": "#F6F6F8",
        "blockquote": "#4B4B50",
        "selection": "#B3D7FF",
        "cursor": "#007AFF",
        "accent": "#007AFF"
      },
      "syntax": {
        "keyword": "#9B2393",
        "string": "#C41A16",
        "number": "#1C00CF",
        "comment": "#5D6C79",
        "literal": "#6C36A9",
        "type": "#0B4F79",
        "property": "#326D74",
        "tag": "#0F68A0"
      }
    }
    """

    static let sepia = """
    {
      "id": "sepia",
      "name": "Sepya",
      "appearance": "light",
      "colors": {
        "background": "#F4ECD8",
        "text": "#3B2F23",
        "secondaryText": "#6F5F4B",
        "marker": "#8F7C66",
        "heading": "#2E2318",
        "link": "#8A4B12",
        "inlineCode": "#8C3A1E",
        "inlineCodeBackground": "#EADFC6",
        "codeBlockBackground": "#EEE4CE",
        "blockquote": "#5C4B39",
        "selection": "#DCC79A",
        "cursor": "#8A4B12",
        "accent": "#A0522D"
      },
      "syntax": {
        "keyword": "#8E3A59",
        "string": "#5F6B00",
        "number": "#2F5F8A",
        "comment": "#857259",
        "literal": "#7B4FA0",
        "type": "#2E6B5E",
        "property": "#7A4B1E",
        "tag": "#9C3D2B"
      }
    }
    """

    static let paper = """
    {
      "id": "paper",
      "name": "Kağıt",
      "appearance": "light",
      "colors": {
        "background": "#FAFAF7",
        "text": "#2B2B2B",
        "secondaryText": "#6B6B66",
        "marker": "#8C8C85",
        "heading": "#111111",
        "link": "#2F5D8C",
        "inlineCode": "#6A3D9A",
        "inlineCodeBackground": "#EFEFEA",
        "codeBlockBackground": "#F2F2EE",
        "blockquote": "#55554F",
        "selection": "#D8E2EC",
        "cursor": "#2B2B2B",
        "accent": "#2F5D8C"
      },
      "syntax": {
        "keyword": "#5B3E8C",
        "string": "#2F6B3A",
        "number": "#9A4A12",
        "comment": "#7E7E78",
        "literal": "#8C2F5A",
        "type": "#1F5A73",
        "property": "#6B4A1F",
        "tag": "#8A2F2F"
      }
    }
    """

    static let defaultDark = """
    {
      "id": "default-dark",
      "name": "Varsayılan Koyu",
      "appearance": "dark",
      "colors": {
        "background": "#1E1E1E",
        "text": "#E3E3E3",
        "secondaryText": "#A1A1A6",
        "marker": "#7D7D82",
        "heading": "#F5F5F7",
        "link": "#4DA3FF",
        "inlineCode": "#FF8170",
        "inlineCodeBackground": "#2C2C2E",
        "codeBlockBackground": "#262628",
        "blockquote": "#BDBDC2",
        "selection": "#3F638B",
        "cursor": "#0A84FF",
        "accent": "#0A84FF"
      },
      "syntax": {
        "keyword": "#FF7AB2",
        "string": "#FF8170",
        "number": "#D9C97C",
        "comment": "#7F8C98",
        "literal": "#D0A8FF",
        "type": "#5DD8FF",
        "property": "#67B7A4",
        "tag": "#ACF2E4"
      }
    }
    """

    static let midnight = """
    {
      "id": "midnight",
      "name": "Gece Mavisi",
      "appearance": "dark",
      "colors": {
        "background": "#141B2D",
        "text": "#D8DEE9",
        "secondaryText": "#94A0B8",
        "marker": "#6B7894",
        "heading": "#EEF2F8",
        "link": "#7AB8FF",
        "inlineCode": "#F2A97C",
        "inlineCodeBackground": "#1E2740",
        "codeBlockBackground": "#19213A",
        "blockquote": "#AEB8CC",
        "selection": "#2E4373",
        "cursor": "#7AB8FF",
        "accent": "#5E9BFF"
      },
      "syntax": {
        "keyword": "#C59BFF",
        "string": "#A5D6A7",
        "number": "#F2C879",
        "comment": "#7383A3",
        "literal": "#FF9EBB",
        "type": "#7FD4E8",
        "property": "#8FB8FF",
        "tag": "#FF8F8F"
      }
    }
    """

    static let ocean = """
    {
      "id": "ocean",
      "name": "Okyanus",
      "appearance": "dark",
      "colors": {
        "background": "#0F2229",
        "text": "#D4E6E8",
        "secondaryText": "#8FB0B5",
        "marker": "#5F858C",
        "heading": "#E8F5F6",
        "link": "#5CD0E6",
        "inlineCode": "#FFC07A",
        "inlineCodeBackground": "#173039",
        "codeBlockBackground": "#132A32",
        "blockquote": "#A6C4C8",
        "selection": "#1F4D5A",
        "cursor": "#5CD0E6",
        "accent": "#2FB5C8"
      },
      "syntax": {
        "keyword": "#7FB2FF",
        "string": "#9FE0A8",
        "number": "#FFC07A",
        "comment": "#6E959C",
        "literal": "#F49AC1",
        "type": "#5CD0E6",
        "property": "#B9A6FF",
        "tag": "#FF8A80"
      }
    }
    """
}

// MARK: - Strict JSON

/// Checks the theme-file JSON grammar (RFC 8259 plus the limits in docs/themes.md) before `JSONDecoder` sees the bytes,
/// because Foundation is more lenient (trailing commas, duplicate keys) than .NET's System.Text.Json.
/// Expects valid UTF-8 without a BOM.
struct StrictJSONValidator {
    static let maxDepth = 64

    private let s: [UInt8]
    private var i = 0
    private var line = 1
    private var path: [String] = []

    init(_ bytes: [UInt8]) { s = bytes }

    mutating func run() throws {
        skipWhitespace()
        guard peek == UInt8(ascii: "{") else {
            if peek == UInt8(ascii: "/") { throw fail("yorumlara izin verilmez.") }
            throw ThemeError.invalidJSON
        }
        try value(depth: 1)
        skipWhitespace()
        guard i == s.count else { throw unexpected("JSON nesnesinden sonra fazladan içerik var.") }
    }

    private var peek: UInt8? { i < s.count ? s[i] : nil }

    private func fail(_ reason: String) -> ThemeError { .malformedJSON(line: line, reason: reason) }

    private func unexpected(_ reason: String) -> ThemeError {
        switch peek {
        case nil: fail("dosya beklenmedik biçimde bitti.")
        case UInt8(ascii: "/"): fail("yorumlara izin verilmez.")
        default: fail(reason)
        }
    }

    private mutating func skipWhitespace() {
        while let c = peek {
            switch c {
            case 0x20, 0x09, 0x0D: i += 1
            case 0x0A: i += 1; line += 1
            default: return
            }
        }
    }

    private mutating func value(depth: Int) throws {
        guard let c = peek else { throw unexpected("değer bekleniyordu.") }
        switch c {
        case UInt8(ascii: "{"): try object(depth: depth)
        case UInt8(ascii: "["): try array(depth: depth)
        case UInt8(ascii: "\""): _ = try string()
        case UInt8(ascii: "t"): try word("true")
        case UInt8(ascii: "f"): try word("false")
        case UInt8(ascii: "n"): try word("null")
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): try number()
        default: throw unexpected("değer bekleniyordu.")
        }
    }

    private mutating func object(depth: Int) throws {
        guard depth <= Self.maxDepth else { throw fail("en çok \(Self.maxDepth) düzey iç içe nesne/dizi olabilir.") }
        i += 1
        skipWhitespace()
        if peek == UInt8(ascii: "}") { i += 1; return }
        var keys = Set<[UInt32]>()
        while true {
            skipWhitespace()
            guard peek == UInt8(ascii: "\"") else {
                throw unexpected(peek == UInt8(ascii: "}") ? "sondaki virgüle izin verilmez." : "tırnak içinde anahtar bekleniyordu.")
            }
            let key = try string()
            guard keys.insert(key.unicodeScalars.map(\.value)).inserted else {
                throw ThemeError.invalidValue(field: (path + [key]).joined(separator: "."), reason: "aynı anahtar birden fazla kez yazılmış.")
            }
            skipWhitespace()
            guard peek == UInt8(ascii: ":") else { throw unexpected("':' bekleniyordu.") }
            i += 1
            skipWhitespace()
            path.append(key)
            try value(depth: depth + 1)
            path.removeLast()
            skipWhitespace()
            switch peek {
            case UInt8(ascii: ","): i += 1
            case UInt8(ascii: "}"): i += 1; return
            default: throw unexpected("',' ya da '}' bekleniyordu.")
            }
        }
    }

    private mutating func array(depth: Int) throws {
        guard depth <= Self.maxDepth else { throw fail("en çok \(Self.maxDepth) düzey iç içe nesne/dizi olabilir.") }
        i += 1
        skipWhitespace()
        if peek == UInt8(ascii: "]") { i += 1; return }
        var index = 0
        while true {
            skipWhitespace()
            if peek == UInt8(ascii: "]") { throw fail("sondaki virgüle izin verilmez.") }
            path.append(String(index))
            try value(depth: depth + 1)
            path.removeLast()
            index += 1
            skipWhitespace()
            switch peek {
            case UInt8(ascii: ","): i += 1
            case UInt8(ascii: "]"): i += 1; return
            default: throw unexpected("',' ya da ']' bekleniyordu.")
            }
        }
    }

    private mutating func word(_ literal: StaticString) throws {
        let bytes = UnsafeBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount)
        guard s.count - i >= bytes.count, s[i..<(i + bytes.count)].elementsEqual(bytes) else { throw fail("geçersiz değer.") }
        i += bytes.count
    }

    private mutating func number() throws {
        let start = i
        func digits() -> Int {
            let from = i
            while let c = peek, c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") { i += 1 }
            return i - from
        }
        if peek == UInt8(ascii: "-") { i += 1 }
        if peek == UInt8(ascii: "0") {
            i += 1
        } else if digits() == 0 {
            throw fail("geçersiz sayı.")
        }
        if peek == UInt8(ascii: ".") {
            i += 1
            guard digits() > 0 else { throw fail("geçersiz sayı.") }
        }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            i += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { throw fail("geçersiz sayı.") }
        }
        guard let number = Double(String(decoding: s[start..<i], as: UTF8.self)), number.isFinite else {
            throw ThemeError.invalidValue(field: path.joined(separator: "."), reason: "sayı çok büyük.")
        }
    }

    /// Returns the decoded string. `i` is at the opening quote.
    private mutating func string() throws -> String {
        i += 1
        var scalars = String.UnicodeScalarView()
        while true {
            guard let c = peek else { throw fail("kapanmamış metin.") }
            switch c {
            case UInt8(ascii: "\""):
                i += 1
                return String(scalars)
            case 0..<0x20:
                throw fail("metin içinde kaçışsız kontrol karakteri var.")
            case UInt8(ascii: "\\"):
                i += 1
                guard let e = peek else { throw fail("kapanmamış metin.") }
                i += 1
                switch e {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{8}")
                case UInt8(ascii: "f"): scalars.append("\u{C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"): scalars.append(try unicodeEscape())
                default: throw fail("geçersiz kaçış dizisi.")
                }
            default:
                // Already validated as UTF-8: decode one scalar.
                let length = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4
                var value = length == 1 ? UInt32(c) : UInt32(c) & (0xFF >> (length + 1))
                for k in 1..<length { value = value << 6 | UInt32(s[i + k] & 0x3F) }
                i += length
                scalars.append(Unicode.Scalar(value)!)
            }
        }
    }

    /// `i` is after `\u`. Surrogates must come as a valid pair.
    private mutating func unicodeEscape() throws -> Unicode.Scalar {
        func hex4() throws -> UInt32 {
            guard s.count - i >= 4 else { throw fail("geçersiz \\u kaçışı.") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let digit = ThemeColor.hexValue(s[i]).map(UInt32.init) else { throw fail("geçersiz \\u kaçışı.") }
                value = value << 4 | digit
                i += 1
            }
            return value
        }
        let first = try hex4()
        if (0xDC00...0xDFFF).contains(first) { throw fail("eşi olmayan UTF-16 vekil karakteri.") }
        guard (0xD800...0xDBFF).contains(first) else { return Unicode.Scalar(first)! }
        guard s.count - i >= 2, s[i] == UInt8(ascii: "\\"), s[i + 1] == UInt8(ascii: "u") else {
            throw fail("eşi olmayan UTF-16 vekil karakteri.")
        }
        i += 2
        let second = try hex4()
        guard (0xDC00...0xDFFF).contains(second) else { throw fail("eşi olmayan UTF-16 vekil karakteri.") }
        return Unicode.Scalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00))!
    }
}
