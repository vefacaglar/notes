import Foundation

/// The UI language of both targets. English and Turkish; the app sets it once at launch (`configure`), from `-lang`,
/// the `AppleLanguages` override or the system. Strings live in each target's `Localizable.xcstrings`.
public enum Localization {
    private static let storage = LanguageStorage()

    /// The language code strings are looked up in ("en" or "tr"): English until the app configures it, so tests and
    /// tools do not depend on the machine's language.
    public static var code: String { storage.value }

    /// Sets the UI language (and with it the language of written names, see `NamingLanguage`) for the rest of the run.
    public static func configure(code: String?) {
        let language = NamingLanguage.resolve(localization: code)
        storage.value = language == .turkish ? "tr" : "en"
        NamingLanguage.configure(localization: storage.value)
    }

    /// The effective language when nothing is forced: the first of `bundle`'s localizations the user's languages match.
    public static func systemCode(in bundle: Bundle) -> String? { bundle.preferredLocalizations.first }

    /// `bundle`, narrowed to the `.lproj` of the configured language so lookups never depend on cached system languages.
    public static func bundle(_ bundle: Bundle, code: String = Localization.code) -> Bundle {
        guard let path = bundle.path(forResource: code, ofType: "lproj"), let narrowed = Bundle(path: path) else {
            return bundle
        }
        return narrowed
    }

    /// The resource bundle of `NotesCore` in `code`'s language (the configured one by default).
    static func coreBundle(code: String = Localization.code) -> Bundle { bundle(.module, code: code) }
}

/// Looks `value` up in NotesCore's string catalog.
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: Localization.coreBundle())
}

private final class LanguageStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var code = "en"

    var value: String {
        get { lock.withLock { code } }
        set { lock.withLock { code = newValue } }
    }
}
