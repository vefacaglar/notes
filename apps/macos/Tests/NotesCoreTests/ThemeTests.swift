import Foundation
import Testing
@testable import NotesCore

struct ThemeColorTests {
    @Test(arguments: [
        ("#FFFFFF", ThemeColor(red: 255, green: 255, blue: 255), "#FFFFFF"),
        ("#1e1E1f", ThemeColor(red: 0x1E, green: 0x1E, blue: 0x1F), "#1E1E1F"),
        ("#00000080", ThemeColor(red: 0, green: 0, blue: 0, alpha: 0x80), "#00000080"),
        ("#123456FF", ThemeColor(red: 0x12, green: 0x34, blue: 0x56), "#123456"),
    ])
    func parsesAndFormats(input: String, color: ThemeColor, formatted: String) throws {
        let parsed = try ThemeColor(hex: input)
        #expect(parsed == color)
        #expect(parsed.hex == formatted)
        #expect(try ThemeColor(hex: parsed.hex) == parsed)
    }

    @Test(arguments: ["", "#", "FFFFFF", "#FFF", "#FFFFF", "#FFFFFFF", "#FFFFFFFFF", "#GGGGGG", " #FFFFFF", "#FFFFFF ",
                      "#ＦＦＦＦＦＦ", "##FFFFF", "#-1FFFF", "0xFFFFFF", "#ffffff\n", "#FFFFFF00FF"])
    func rejectsMalformedHex(input: String) {
        #expect(throws: ThemeError.invalidColor(input)) { try ThemeColor(hex: input) }
    }

    @Test func errorMessageIsLocalized() {
        let message = ThemeError.invalidColor("#12").localizedDescription
        #expect(message.contains("Invalid color"))
        #expect(message.contains("#12"))
    }

    @Test func contrastRatioMatchesWCAG() {
        #expect(abs(ThemeColor.contrastRatio(.black, on: .white) - 21) < 0.001)
        #expect(ThemeColor.contrastRatio(.white, on: .white) == 1)
        // #777777 on white is the textbook 4.48:1.
        let gray = ThemeColor(red: 0x77, green: 0x77, blue: 0x77)
        #expect(abs(ThemeColor.contrastRatio(gray, on: .white) - 4.48) < 0.01)
        #expect(ThemeColor.contrastRatio(.white, on: gray) == ThemeColor.contrastRatio(gray, on: .white))
    }

    @Test func translucentColorsAreComposited() {
        let halfBlack = ThemeColor(red: 0, green: 0, blue: 0, alpha: 128)
        #expect(halfBlack.composited(over: .white) == ThemeColor(red: 127, green: 127, blue: 127))
        #expect(ThemeColor.contrastRatio(halfBlack, on: .white) == ThemeColor.contrastRatio(ThemeColor(red: 127, green: 127, blue: 127), on: .white))
        #expect(ThemeColor(red: 0, green: 0, blue: 0, alpha: 0).composited(over: .white) == .white)
    }

    @Test func codableIsAHexString() throws {
        let data = try JSONEncoder().encode(["c": ThemeColor(red: 1, green: 2, blue: 3, alpha: 4)])
        #expect(String(decoding: data, as: UTF8.self) == ##"{"c":"#01020304"}"##)
        #expect(try JSONDecoder().decode([String: ThemeColor].self, from: data)["c"]?.alpha == 4)
    }
}

struct ThemeDecodingTests {
    @Test func minimalThemeFallsBackToBase() throws {
        let theme = try Theme.decode(Data(##"{"id": "x", "name": "Benim", "appearance": "dark"}"##.utf8))
        let resolved = ThemeLibrary().resolved(theme)
        let base = ThemeLibrary.baseTheme(for: .dark)
        #expect(resolved.id == "x")
        #expect(resolved.name == "Benim")
        #expect(resolved.colors == base.colors)
        #expect(resolved.syntax == base.syntax)
    }

    @Test func partialThemeOverridesOnlyWhatItSets() throws {
        let json = """
        {
          "name": "Yarım", "appearance": "light",
          "colors": { "background": "#FAF0E6", "selection": "#0000FF33", "accent": null },
          "syntax": { "comment": "#808080" },
          "fonts": { "body": { "family": "Georgia" }, "mono": { "size": 13 } },
          "gelecekteBirAlan": true
        }
        """
        let theme = try Theme.decode(Data(json.utf8), fallbackID: "yarim")
        let resolved = ThemeLibrary().resolved(theme)
        let base = ThemeLibrary.baseTheme(for: .light)
        #expect(resolved.id == "yarim")
        #expect(resolved.colors.background == ThemeColor(red: 0xFA, green: 0xF0, blue: 0xE6))
        #expect(resolved.colors.selection.alpha == 0x33)
        #expect(resolved.colors.text == base.colors.text)
        #expect(resolved.colors.accent == base.colors.accent)
        #expect(resolved.syntax.comment.hex == "#808080")
        #expect(resolved.syntax.keyword == base.syntax.keyword)
    }

    @Test func idInFileWinsOverFallbackAndIsTrimmed() throws {
        let theme = try Theme.decode(Data(##"{"id": " gerçek ", "name": " Ad ", "appearance": "light"}"##.utf8), fallbackID: "dosya")
        #expect(theme.id == "gerçek")
        #expect(theme.name == "Ad")
    }

    @Test(arguments: [
        ("{", ThemeError.malformedJSON(line: 1, reason: "the file ended unexpectedly.")),
        ("[]", ThemeError.invalidJSON),
        ("\"tema\"", ThemeError.invalidJSON),
        (##"{"name": "A"}"##, ThemeError.missingField("appearance")),
        (##"{"appearance": "light"}"##, ThemeError.missingField("name")),
        (##"{"name": "A", "appearance": "sepia"}"##, ThemeError.invalidValue(field: "appearance", reason: "must be \"light\" or \"dark\".")),
        (##"{"name": "  ", "appearance": "light"}"##, ThemeError.invalidValue(field: "name", reason: "must not be empty.")),
        (##"{"name": "A", "appearance": "light", "colors": {"text": "#12"}}"##,
         ThemeError.invalidValue(field: "colors.text", reason: "must be a color like #RRGGBB or #RRGGBBAA.")),
        (##"{"name": "A", "appearance": "light", "syntax": {"tag": "red"}}"##,
         ThemeError.invalidValue(field: "syntax.tag", reason: "must be a color like #RRGGBB or #RRGGBBAA.")),
        (##"{"name": "A", "appearance": "light", "colors": {"text": 12}}"##,
         ThemeError.invalidValue(field: "colors.text", reason: "Expected a string.")),
        (##"{"name": null, "appearance": "light"}"##,
         ThemeError.invalidValue(field: "name", reason: "must not be null.")),
    ])
    func invalidThemesReportTheField(json: String, error: ThemeError) {
        #expect(throws: error) { try Theme.decode(Data(json.utf8), fallbackID: "f") }
    }

    @Test func missingIDWithoutFallbackIsAnError() {
        #expect(throws: ThemeError.missingField("id")) {
            try Theme.decode(Data(##"{"name": "A", "appearance": "light"}"##.utf8))
        }
    }

    @Test func errorMessagesAreLocalized() {
        #expect(ThemeError.missingField("name").localizedDescription == "The field \"name\" is missing.")
        #expect(ThemeError.invalidJSON.localizedDescription == "The file is not a valid JSON object.")
    }

    @Test func encodingRoundTripsAndOmitsUnsetFields() throws {
        let theme = try Theme(id: "t", name: "Tema", appearance: .dark, colors: .init(background: .black))
        let data = try theme.encodedJSON()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"background\" : \"#000000\""))
        #expect(!text.contains("text"))
        #expect(!text.contains("fonts"))
        #expect(try Theme.decode(data) == theme)
    }

    @Test func syntaxCoversEveryCodeSpanKind() {
        let syntax = ThemeLibrary.baseTheme(for: .light).syntax
        let kinds: [CodeSpan.Kind] = [.keyword, .string, .number, .comment, .literal, .type, .property, .tag]
        #expect(kinds.map { syntax[$0] } == [syntax.keyword, syntax.string, syntax.number, syntax.comment, syntax.literal, syntax.type, syntax.property, syntax.tag])
    }
}

struct BuiltInThemeTests {
    @Test func namesAndAppearances() {
        let themes = ThemeLibrary.builtInThemes
        #expect(themes.map(\.name) == ["Varsayılan Açık", "Sepya", "Kağıt", "Varsayılan Koyu", "Gece Mavisi", "Okyanus"])
        #expect(themes.map(\.appearance) == [.light, .light, .light, .dark, .dark, .dark])
        #expect(Set(themes.map(\.id)).count == themes.count)
        #expect(ThemeLibrary.baseTheme(for: .light).id == ThemeLibrary.defaultLightID)
        #expect(ThemeLibrary.baseTheme(for: .dark).id == ThemeLibrary.defaultDarkID)
    }

    @Test func everyBuiltInSetsEveryColor() {
        for theme in ThemeLibrary.builtInThemes {
            let values = Mirror(reflecting: theme.colors).children.map(\.value) + Mirror(reflecting: theme.syntax).children.map(\.value)
            #expect(values.count == 21)
            #expect(values.allSatisfy { $0 as? ThemeColor != nil }, "\(theme.id) leaves a color unset")
        }
    }

    /// The shared muted palette: headings and inline code are the body colour, markers and comments are one
    /// dimmed grey, and no colour is saturated (no bright reds, purples or neon tones).
    @Test func builtInPalettesAreMuted() {
        for theme in ThemeLibrary.builtInThemes {
            let c = theme.colors, s = theme.syntax
            #expect(c.heading == c.text, "\(theme.id): heading is not the text color")
            #expect(c.inlineCode == c.text, "\(theme.id): inline code is not the text color")
            #expect(c.marker == s.comment, "\(theme.id): markers and comments differ")

            // selection, cursor and accent are control colors (the system accent blue), not palette colors.
            let controls: Set<String> = ["selection", "cursor", "accent"]
            let colors = (Array(Mirror(reflecting: c).children) + Array(Mirror(reflecting: s).children))
                .filter { !controls.contains($0.label ?? "") }
                .compactMap { $0.value as? ThemeColor }
            for color in colors {
                let high = max(color.red, max(color.green, color.blue))
                let low = min(color.red, min(color.green, color.blue))
                #expect(Int(high) - Int(low) <= 120, "\(theme.id): \(color) is too saturated")
            }
        }
    }

    @Test func builtInJSONRoundTrips() throws {
        for theme in ThemeLibrary.builtInThemes {
            #expect(try Theme.decode(theme.encodedJSON()) == theme)
        }
    }

    @Test(arguments: ThemeLibrary.builtInThemes.map(\.id))
    func contrast(id: String) throws {
        let library = ThemeLibrary()
        let theme = library.resolved(try #require(library.theme(id: id)))
        let c = theme.colors, s = theme.syntax
        let codeBlock = c.codeBlockBackground

        func check(_ name: String, _ fg: ThemeColor, on bg: ThemeColor, atLeast minimum: Double) {
            let ratio = theme.contrastRatio(fg, on: bg)
            #expect(ratio >= minimum, "\(id): \(name) \(fg) on \(bg) is \(ratio)")
        }

        for (name, color) in [("text", c.text), ("heading", c.heading), ("link", c.link), ("blockquote", c.blockquote)] {
            check(name, color, on: c.background, atLeast: 4.5)
        }
        check("text on selection", c.text, on: c.selection, atLeast: 4.5)
        check("inline code", c.inlineCode, on: c.inlineCodeBackground, atLeast: 4.5)
        check("text in code block", c.text, on: codeBlock, atLeast: 4.5)
        for (name, color) in [("secondaryText", c.secondaryText), ("marker", c.marker), ("cursor", c.cursor), ("accent", c.accent)] {
            check(name, color, on: c.background, atLeast: 3)
        }
        for (name, color) in [("keyword", s.keyword), ("string", s.string), ("number", s.number), ("literal", s.literal),
                              ("type", s.type), ("property", s.property), ("tag", s.tag)] {
            check(name, color, on: c.background, atLeast: 4.5)
            check(name, color, on: codeBlock, atLeast: 4.5)
        }
        check("comment", s.comment, on: c.background, atLeast: 3)
        check("comment", s.comment, on: codeBlock, atLeast: 3)
    }

    @Test func appearanceMatchesBackgroundLuminance() {
        let library = ThemeLibrary()
        for theme in ThemeLibrary.builtInThemes {
            let luminance = library.resolved(theme).colors.background.relativeLuminance
            #expect(theme.appearance == .light ? luminance > 0.5 : luminance < 0.1, "\(theme.id)")
        }
    }
}

struct ThemeLibraryTests {
    private func makeDirectory(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ThemeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            try Data(content.utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    @Test func missingDirectoryMeansOnlyBuiltIns() {
        let library = ThemeLibrary(userDirectory: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
        #expect(library.userThemes.isEmpty)
        #expect(library.issues.isEmpty)
        #expect(library.themes.count == ThemeLibrary.builtInThemes.count)
        #expect(ThemeLibrary(userDirectory: nil).themes.count == 6)
    }

    @Test func loadsValidThemesAndReportsTheRest() throws {
        let dir = try makeDirectory([
            "Orman Yeşili.json": ##"{"name": "Orman", "appearance": "dark", "colors": {"background": "#0B1F14"}}"##,
            "b.json": ##"{"id": "kum", "name": "Kum", "appearance": "light"}"##,
            "c.JSON": ##"{"id": "ay", "name": "Ay ışığı", "appearance": "dark"}"##,
            "bozuk.json": "{ not json",
            "renk.json": ##"{"name": "R", "appearance": "light", "colors": {"link": "mavi"}}"##,
            "sepya-kopya.json": ##"{"id": "sepia", "name": "Sepya 2", "appearance": "light"}"##,
            "z-kum.json": ##"{"id": "kum", "name": "Kum 2", "appearance": "light"}"##,
            "notlar.txt": "ignored",
            ".gizli.json": "{",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("alt.json"), withIntermediateDirectories: true)

        let library = ThemeLibrary(userDirectory: dir)
        #expect(library.userThemes.map(\.id) == ["ay", "kum", "Orman Yeşili"])
        #expect(library.themes(for: .dark).map(\.name).suffix(2) == ["Ay ışığı", "Orman"])
        #expect(library.fileURL(forThemeID: "kum")?.lastPathComponent == "b.json")
        #expect(library.fileURL(forThemeID: "sepia") == nil)
        #expect(library.theme(id: "sepia")?.name == "Sepya")

        let issues = Dictionary(uniqueKeysWithValues: library.issues.map { ($0.file.lastPathComponent, $0.error) })
        #expect(issues.count == 4)
        #expect(issues["bozuk.json"] == .malformedJSON(line: 1, reason: "a key in quotes was expected."))
        #expect(issues["renk.json"] == .invalidValue(field: "colors.link", reason: "must be a color like #RRGGBB or #RRGGBBAA."))
        #expect(issues["sepya-kopya.json"] == .duplicateID("sepia"))
        #expect(issues["z-kum.json"] == .duplicateID("kum"))
        #expect(library.issues.first { $0.file.lastPathComponent == "z-kum.json" }!.description.hasPrefix("z-kum.json: The id \"kum\" is already"))
    }

    @Test func fileNameIDIsNFC() throws {
        let decomposed = "Gu\u{308}ne\u{15F}.json"
        let dir = try makeDirectory([decomposed: ##"{"name": "Güneş", "appearance": "light"}"##])
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = ThemeLibrary(userDirectory: dir)
        #expect(library.userThemes.first?.id == "Güneş".precomposedStringWithCanonicalMapping)
        #expect(library.userThemes.first?.id.unicodeScalars.count == 5)
    }

    @Test func oversizedFileIsReported() throws {
        let big = ##"{"name": "B", "appearance": "light", "x": ""## + String(repeating: "a", count: ThemeLibrary.maxFileSize) + "\"}"
        let dir = try makeDirectory(["buyuk.json": big])
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = ThemeLibrary(userDirectory: dir)
        #expect(library.userThemes.isEmpty)
        #expect(library.issues.map(\.error) == [.fileTooLarge])
    }

    @Test func directoryThatIsAFileIsReported() throws {
        let dir = try makeDirectory(["dosya": "x"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = ThemeLibrary(userDirectory: dir.appendingPathComponent("dosya"))
        #expect(library.userThemes.isEmpty)
        #expect(library.issues.count == 1)
    }

    @Test func preferencesPickThemePerAppearance() throws {
        let dir = try makeDirectory(["mine.json": ##"{"id": "mine", "name": "Benim", "appearance": "dark"}"##])
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = ThemeLibrary(userDirectory: dir)
        var prefs = ThemePreferences(mode: .system, lightThemeID: "sepia", darkThemeID: "mine")

        #expect(library.resolvedTheme(for: prefs, systemAppearance: .light).id == "sepia")
        #expect(library.resolvedTheme(for: prefs, systemAppearance: .dark).id == "mine")
        prefs.mode = .light
        #expect(library.resolvedTheme(for: prefs, systemAppearance: .dark).id == "sepia")
        prefs.mode = .dark
        #expect(library.resolvedTheme(for: prefs, systemAppearance: .light).id == "mine")

        // Deleted theme or wrong appearance falls back to the default of that appearance.
        prefs.darkThemeID = "silinmiş"
        #expect(library.resolvedTheme(for: prefs, systemAppearance: .light).id == ThemeLibrary.defaultDarkID)
        prefs.darkThemeID = "paper"
        #expect(library.resolvedTheme(for: prefs, systemAppearance: .light).id == ThemeLibrary.defaultDarkID)
    }

    @Test func preferencesAreCodableWithDefaults() throws {
        let prefs = ThemePreferences()
        #expect(prefs.mode == .system)
        #expect(prefs.lightThemeID == "default-light" && prefs.darkThemeID == "default-dark")
        #expect(try JSONDecoder().decode(ThemePreferences.self, from: JSONEncoder().encode(prefs)) == prefs)
        #expect(AppearanceMode.allCases.map(\.displayName) == ["System", "Light", "Dark"])
    }

    @Test func docsExampleDecodes() throws {
        // Keep in sync with the full example in docs/themes.md.
        let docs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("../../docs/themes.md").standardizedFileURL
        let text = try String(contentsOf: docs, encoding: .utf8)
        let blocks = text.components(separatedBy: "```json\n").dropFirst().map { $0.components(separatedBy: "\n```")[0] }
        #expect(blocks.count >= 2)
        for block in blocks {
            let theme = try Theme.decode(Data(block.utf8), fallbackID: "docs")
            #expect(!theme.name.isEmpty)
        }
    }
}

private func thrown(_ body: () throws -> Void) -> ThemeError? {
    do {
        try body()
        return nil
    } catch {
        return error as? ThemeError
    }
}

private func decode(_ json: String) throws -> Theme {
    try Theme.decode(Data(json.utf8), fallbackID: "f")
}

private let head = ##""name": "A", "appearance": "light""##

struct ThemeJSONGrammarTests {
    @Test(arguments: [
        "{\(head),}",
        "{\(head), \"x\": [1, 2,]}",
        "{\(head), // yorum\n}",
        "/* yorum */ {\(head)}",
        "{\(head), /* yorum */ \"x\": 1}",
        "{\(head), \"x\": 'a'}",
        "{\(head), \"x\": 01}",
        "{\(head), \"x\": +1}",
        "{\(head), \"x\": .5}",
        "{\(head), \"x\": 1.}",
        "{\(head), \"x\": 1e}",
        "{\(head), \"x\": NaN}",
        "{\(head), \"x\": Infinity}",
        "{\(head), \"x\": tru}",
        ##"{"name": "A", "appearance": "light", "x": "\x"}"##,
        ##"{"name": "A", "appearance": "light", "x": "\u12"}"##,
        ##"{"name": "A", "appearance": "light", "x": "\uD800"}"##,
        ##"{"name": "A", "appearance": "light", "x": "\uD800A"}"##,
        ##"{"name": "A", "appearance": "light", "x": "\uDC00"}"##,
        "{\(head), \"x\": \"a\tb\"}",
        "{\(head), \"x\": \"a\nb\"}",
        "{\(head)} {}",
        "{\(head)",
        "{\(head), \"x\": \"açık",
        "{name: \"A\"}",
        "{\(head) \"x\": 1}",
        "{\(head), \"x\" 1}",
        "{\(head),\u{A0}\"x\": 1}",
    ])
    func rejectsMalformedJSON(json: String) {
        guard case .malformedJSON = thrown({ _ = try decode(json) }) else {
            Issue.record("accepted or wrong error: \(json)")
            return
        }
    }

    @Test func malformedJSONNamesTheLine() {
        #expect(thrown { _ = try decode("{\n  \"name\": \"A\",\n  \"appearance\": \"light\",\n}") }
                == .malformedJSON(line: 4, reason: "a trailing comma is not allowed."))
        #expect(thrown { _ = try decode("{\r\n\"name\": \"A\", // not\r\n}") } == .malformedJSON(line: 2, reason: "comments are not allowed."))
        #expect(ThemeError.malformedJSON(line: 4, reason: "x").localizedDescription == "JSON error, line 4: x")
    }

    @Test(arguments: ["null", "[]", "1", "\"tema\"", "true", "   "])
    func nonObjectTopLevelIsInvalidJSON(json: String) {
        #expect(thrown { _ = try decode(json) } == .invalidJSON)
    }

    @Test func duplicateKeysAreErrors() {
        let reason = "the same key appears more than once."
        #expect(thrown { _ = try decode(##"{"name": "A", "name": "B", "appearance": "light"}"##) }
                == .invalidValue(field: "name", reason: reason))
        #expect(thrown { _ = try decode("{\(head), \"colors\": {\"text\": \"#000000\", \"text\": \"#111111\"}}") }
                == .invalidValue(field: "colors.text", reason: reason))
        #expect(thrown { _ = try decode("{\(head), \"x\": [{\"a\": 1, \"a\": 1}]}") }
                == .invalidValue(field: "x.0.a", reason: reason))
        // Same key in different objects is fine; keys compare ordinally, so NFC/NFD spellings differ.
        #expect(throws: Never.self) {
            try decode("{\(head), \"x\": {\"a\": 1}, \"y\": {\"a\": 1}, \"caf\\u00e9\": 1, \"cafe\\u0301\": 2}")
        }
    }

    @Test func nestingDepthIsLimitedTo64() throws {
        func nested(_ arrays: Int) -> String {
            "{\(head), \"x\": " + String(repeating: "[", count: arrays) + String(repeating: "]", count: arrays) + "}"
        }
        _ = try decode(nested(63))
        guard case .malformedJSON = thrown({ _ = try decode(nested(64)) }) else {
            Issue.record("depth 65 accepted")
            return
        }
        guard case .malformedJSON = thrown({ _ = try decode(nested(100_000)) }) else {
            Issue.record("deep nesting accepted")
            return
        }
    }

    @Test func validEscapesAndNumbersAreAccepted() throws {
        let theme = try decode(##"{"name": "Çınar 🌳 \"t\" \/ \\", "appearance": "light", "x": [-0.5e+3, 0, 1E-2, true, false, null, {}, []]}"##)
        #expect(theme.name == "Çınar 🌳 \"t\" / \\")
        _ = try decode("\r\n\t{\(head)}\n")
    }

    @Test func outOfRangeNumbersNameTheField() {
        #expect(thrown { _ = try decode("{\(head), \"fonts\": {\"body\": {\"size\": 1e400}}}") }
                == .invalidValue(field: "fonts.body.size", reason: "the number is too large."))
        #expect(thrown { _ = try decode("{\(head), \"x\": [0, -1e309]}") }
                == .invalidValue(field: "x.1", reason: "the number is too large."))
    }

    @Test func encodings() throws {
        let json = "{\(head)}"
        #expect(try Theme.decode(Data([0xEF, 0xBB, 0xBF]) + Data(json.utf8), fallbackID: "f").name == "A")
        #expect(thrown { _ = try Theme.decode(Data([0xFF, 0xFE]) + json.data(using: .utf16LittleEndian)!, fallbackID: "f") } == .notUTF8)
        #expect(thrown { _ = try Theme.decode(json.data(using: .utf16BigEndian)!, fallbackID: "f") } == .notUTF8)
        #expect(thrown { _ = try Theme.decode(Data("{\"name\": \"".utf8) + Data([0xC3, 0x28]) + Data("\", \"appearance\": \"light\"}".utf8), fallbackID: "f") } == .notUTF8)
        #expect(thrown { _ = try Theme.decode(Data([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF]) + Data(json.utf8), fallbackID: "f") } != nil)
    }

    @Test func idsFromJSONAreNFC() throws {
        let theme = try decode(##"{"id": " Güneş ", "name": "Gün", "appearance": "light"}"##)
        #expect(theme.id.unicodeScalars.count == 5)
        #expect(theme.id.unicodeScalars.elementsEqual("Güneş".precomposedStringWithCanonicalMapping.unicodeScalars))
        #expect(theme.name.unicodeScalars.count == 3)
    }

    /// Fonts left the theme format (they are app settings now); old files that still have them load unchanged,
    /// even with values that used to be errors.
    @Test func legacyFontsAreIgnored() throws {
        let theme = try decode("""
        {\(head), "fonts": {"body": {"family": "", "size": 200}, "mono": {"family": "Menlo", "size": "12"}}, "colors": {"text": "#123456"}}
        """)
        #expect(theme.colors.text?.hex == "#123456")
        let text = String(decoding: try theme.encodedJSON(), as: UTF8.self)
        #expect(!text.contains("fonts"))
    }

    @Test func initAndEncodingValidateLikeDecoding() throws {
        #expect(thrown { _ = try Theme(id: " ", name: "A", appearance: .light) } == .invalidValue(field: "id", reason: "must not be empty."))
        var theme = try Theme(id: " Gu\u{308}l ", name: " Gül ", appearance: .light)
        #expect(theme.id == "Gül" && theme.id.unicodeScalars.count == 3 && theme.name == "Gül")
        theme.name = "\n"
        #expect(thrown { _ = try theme.encodedJSON() } == .invalidValue(field: "name", reason: "must not be empty."))
    }
}

struct ThemeAlphaTests {
    @Test func backgroundAlphaIsIgnored() throws {
        let theme = try decode("{\(head), \"colors\": {\"background\": \"#F0F0F080\"}}")
        #expect(ThemeLibrary().resolved(theme).colors.background == ThemeColor(red: 0xF0, green: 0xF0, blue: 0xF0))
    }

    @Test func translucentBackgroundsCompositeOverTheThemeBackground() throws {
        let theme = try Theme.decode(Data(##"{"id": "d", "name": "D", "appearance": "dark", "colors": {"selection": "#FFFFFF33"}}"##.utf8))
        let resolved = ThemeLibrary().resolved(theme)
        let c = resolved.colors
        let expected = ThemeColor.contrastRatio(c.text, on: c.selection.composited(over: c.background))
        #expect(resolved.contrastRatio(c.text, on: c.selection) == expected)
        #expect(resolved.contrastRatio(c.text, on: c.selection) != ThemeColor.contrastRatio(c.text, on: c.selection.composited(over: .white)))
        #expect(resolved.contrastRatio(c.text) == ThemeColor.contrastRatio(c.text, on: c.background))
        // The static helper treats the background as opaque.
        #expect(ThemeColor.contrastRatio(.black, on: ThemeColor(red: 255, green: 255, blue: 255, alpha: 0)) == ThemeColor.contrastRatio(.black, on: .white))
    }
}

struct ThemePreferencesDecodingTests {
    private func prefs(_ json: String) throws -> ThemePreferences {
        try JSONDecoder().decode(ThemePreferences.self, from: Data(json.utf8))
    }

    @Test func oneBadKeyKeepsTheOthers() throws {
        #expect(try prefs(##"{"mode": "sepya", "lightThemeID": 5, "darkThemeID": "silinmiş"}"##)
                == ThemePreferences(mode: .system, lightThemeID: "default-light", darkThemeID: "silinmiş"))
        #expect(try prefs(##"{"mode": "dark", "lightThemeID": "paper", "darkThemeID": null}"##)
                == ThemePreferences(mode: .dark, lightThemeID: "paper", darkThemeID: "default-dark"))
        #expect(try prefs("{}") == ThemePreferences())
    }
}

struct ThemeLibraryFileSystemTests {
    private let fm = FileManager.default

    private func makeDirectory(_ files: [String: String] = [:]) throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("ThemeFS-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            try Data(content.utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    private func theme(_ id: String? = nil, name: String = "T") -> String {
        (id.map { "{\"id\": \"\($0)\", " } ?? "{") + "\"name\": \"\(name)\", \"appearance\": \"light\"}"
    }

    @Test func symlinkedDirectoryIsFollowed() throws {
        let real = try makeDirectory(["a.json": theme("a")])
        let outer = try makeDirectory()
        defer { try? fm.removeItem(at: real); try? fm.removeItem(at: outer) }
        let link = outer.appendingPathComponent("Themes")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let library = ThemeLibrary(userDirectory: link)
        #expect(library.issues.isEmpty)
        #expect(library.userThemes.map(\.id) == ["a"])
    }

    @Test func symlinkedFilesAreFollowedButOnlyToRegularFiles() throws {
        let elsewhere = try makeDirectory(["real.json": theme(nil, name: "Bağlı")])
        let dir = try makeDirectory()
        defer { try? fm.removeItem(at: elsewhere); try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: elsewhere.appendingPathComponent("klasor"), withIntermediateDirectories: true)
        #expect(mkfifo(elsewhere.appendingPathComponent("fifo").path, 0o644) == 0)
        #expect(mkfifo(dir.appendingPathComponent("boru.json").path, 0o644) == 0)

        try fm.createSymbolicLink(at: dir.appendingPathComponent("bagli.json"), withDestinationURL: elsewhere.appendingPathComponent("real.json"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("fifo.json"), withDestinationURL: elsewhere.appendingPathComponent("fifo"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("sifir.json"), withDestinationURL: URL(fileURLWithPath: "/dev/zero"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("kirik.json"), withDestinationURL: elsewhere.appendingPathComponent("yok.json"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("klasor.json"), withDestinationURL: elsewhere.appendingPathComponent("klasor"))
        try fm.createDirectory(at: dir.appendingPathComponent("alt.json"), withIntermediateDirectories: true)

        let library = ThemeLibrary(userDirectory: dir)
        // The id comes from the link's name, not the target's.
        #expect(library.userThemes.map(\.id) == ["bagli"])
        #expect(library.fileURL(forThemeID: "bagli")?.lastPathComponent == "bagli.json")

        let issues = Dictionary(uniqueKeysWithValues: library.issues.map { ($0.file.lastPathComponent, $0.error) })
        #expect(issues.keys.sorted() == ["boru.json", "fifo.json", "kirik.json", "sifir.json"])
        let notRegular = ThemeError.unreadable("not a regular file.")
        #expect(issues["boru.json"] == notRegular)
        #expect(issues["fifo.json"] == notRegular)
        #expect(issues["sifir.json"] == notRegular)
        guard case .unreadable = issues["kirik.json"] else {
            Issue.record("broken link: \(String(describing: issues["kirik.json"]))")
            return
        }
    }

    @Test func finderHiddenFilesAreSkipped() throws {
        let dir = try makeDirectory(["gizli.json": "{", "acik.json": theme("acik")])
        defer { try? fm.removeItem(at: dir) }
        var hidden = dir.appendingPathComponent("gizli.json")
        var values = URLResourceValues()
        values.isHidden = true
        try hidden.setResourceValues(values)

        let library = ThemeLibrary(userDirectory: dir)
        #expect(library.issues.isEmpty)
        #expect(library.userThemes.map(\.id) == ["acik"])
    }

    @Test func duplicateIDsResolveByOrdinalScalarOrderOfNFCFileNames() throws {
        let dir = try makeDirectory([
            "a.json": theme("x", name: "küçük a"),
            "B.json": theme("x", name: "büyük B"),
            "\u{FFFD}.json": theme("y", name: "FFFD"),
            "😀.json": theme("y", name: "emoji"),
            "e\u{301}.json": theme("z", name: "é"),
            "f.json": theme("z", name: "f"),
        ])
        defer { try? fm.removeItem(at: dir) }
        let library = ThemeLibrary(userDirectory: dir)
        #expect(Set(library.userThemes.map(\.name)) == ["büyük B", "FFFD", "f"])
        #expect(Set(library.issues.map { $0.file.lastPathComponent.precomposedStringWithCanonicalMapping })
                == ["a.json", "😀.json", "é.json"])
        // Issues are listed in that same order.
        #expect(library.issues.map { $0.file.lastPathComponent.precomposedStringWithCanonicalMapping } == ["a.json", "é.json", "😀.json"])
    }

    @Test func idsCompareExactlyAfterNFC() throws {
        let dir = try makeDirectory([
            "1.json": theme("caf\\u00e9"),
            "2.json": theme("cafe\\u0301"),
            "3.json": theme("Kum"),
            "4.json": theme("kum"),
        ])
        defer { try? fm.removeItem(at: dir) }
        let library = ThemeLibrary(userDirectory: dir)
        #expect(library.userThemes.count == 3)
        #expect(library.issues.map(\.file.lastPathComponent) == ["2.json"])
        #expect(library.theme(id: "cafe\u{301}") != nil)
    }

    @Test func fileCountIsCapped() throws {
        var files: [String: String] = [:]
        for n in 0...ThemeLibrary.maxFileCount {
            files[String(format: "t%04d.json", n)] = theme()
        }
        let dir = try makeDirectory(files)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("a-klasor.json"), withIntermediateDirectories: true)

        let library = ThemeLibrary(userDirectory: dir)
        #expect(library.userThemes.count == ThemeLibrary.maxFileCount)
        #expect(library.issues.map(\.file.lastPathComponent) == [String(format: "t%04d.json", ThemeLibrary.maxFileCount)])
        #expect(library.issues.first?.error == .tooManyFiles)
    }
}
