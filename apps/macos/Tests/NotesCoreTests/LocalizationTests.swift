import Foundation
import Testing
@testable import NotesCore

struct LocalizationTests {
    private func turkish(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: Localization.coreBundle(code: "tr"))
    }

    private func english(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: Localization.coreBundle(code: "en"))
    }

    @Test func moduleBundleHasBothLanguages() {
        let bundle = Bundle.module
        #expect(bundle.path(forResource: "en", ofType: "lproj") != nil)
        #expect(bundle.path(forResource: "tr", ofType: "lproj") != nil)
    }

    @Test func turkishCoreMessagesComeFromTheCatalog() {
        #expect(turkish("Invalid name: \"\("a/b")\"") == "Geçersiz ad: \"a/b\"")
        #expect(turkish("The file is too large (\(300) MB); files up to \(200) MB can be opened.")
                == "Dosya çok büyük (300 MB); en fazla 200 MB açılabilir.")
        #expect(turkish("Invalid JSON (\(1):\(2)): \("empty document")") == "Geçersiz JSON (1:2): empty document")
        #expect(turkish("Default Dark") == "Varsayılan Koyu")
        #expect(turkish("Plain Text") == "Düz metin")
    }

    @Test func englishIsTheDefault() {
        #expect(Localization.code == "en")
        #expect(english("Plain Text") == "Plain text")
        #expect(CodeLanguage.plainText.displayName == "Plain text")
        #expect(AppearanceMode.system.displayName == "System")
        #expect(ThemeError.invalidJSON.localizedDescription == "The file is not a valid JSON object.")
        #expect(ThemeLibrary.builtInThemes.map(\.displayName) == ["Default Light", "Sepia", "Paper", "Default Dark", "Midnight", "Ocean"])
    }

    @Test func missingTranslationsFallBackToTheKey() {
        #expect(turkish("This text is in no catalog") == "This text is in no catalog")
    }

    @Test func languageCodesResolveToEnglishOrTurkish() {
        #expect(NamingLanguage.resolve(localization: "tr-TR") == .turkish)
        #expect(NamingLanguage.resolve(localization: "de") == .english)
        #expect(NamingLanguage.resolve(localization: nil) == .english)
    }

    /// Both catalogs: every string has an English and a Turkish value with the same placeholders.
    @Test(arguments: ["NotesCore", "Notes"])
    func catalogsAreComplete(target: String) throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/\(target)/Resources/Localizable.xcstrings")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sources)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: [String: Any]])
        #expect(!strings.isEmpty)
        func value(_ entry: [String: Any], _ language: String) -> String? {
            let localizations = entry["localizations"] as? [String: [String: Any]]
            if let unit = localizations?[language]?["stringUnit"] as? [String: Any] { return unit["value"] as? String }
            // Plural variations: the "other" form stands for the entry.
            let plural = (localizations?[language]?["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]]
            return (plural?["other"]?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        func placeholders(_ text: String) -> [String] {
            text.matches(of: /%(?:\d+\$)?(?:lld|@)/).map { String($0.output) }.sorted()
        }
        for (key, entry) in strings {
            let tr = value(entry, "tr")
            #expect(tr?.isEmpty == false, "no Turkish text for \(key)")
            #expect(value(entry, "en") != nil, "no English text for \(key)")
            if let tr { #expect(placeholders(tr) == placeholders(key), "placeholders differ for \(key)") }
        }
    }
}
