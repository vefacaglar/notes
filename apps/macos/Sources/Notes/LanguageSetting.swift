import AppKit
import NotesCore

/// The UI language: English or Turkish, chosen in Settings (stored as the app's `AppleLanguages` default so AppKit's
/// own texts follow it too) or forced for one run with `-lang en|tr`. A change applies after a restart.
enum LanguageChoice: String, CaseIterable, Sendable {
    case system, english = "en", turkish = "tr"
}

enum LanguageSetting {
    private static let key = "AppleLanguages"
    /// Set while a quit that should be followed by a relaunch is under way (the save guards can still cancel it).
    nonisolated(unsafe) static var relaunchPending = false

    /// The language the user stored, `.system` when there is no override.
    static var stored: LanguageChoice {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
        guard let first = (domain?[key] as? [String])?.first else { return .system }
        return NamingLanguage.resolve(localization: first) == .turkish ? .turkish : .english
    }

    static func store(_ choice: LanguageChoice) {
        if choice == .system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([choice.rawValue], forKey: key)
        }
    }

    /// Resolves the language before anything reads a string: `-lang` (argument domain, never saved), else the saved
    /// override or the system languages as the resource bundle matches them.
    static func configureAtLaunch() {
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let forced = (arguments["lang"] as? String).flatMap { LanguageChoice(rawValue: $0) }.flatMap { $0 == .system ? nil : $0 }
        if let forced {
            arguments[key] = [forced.rawValue]
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        Localization.configure(code: forced?.rawValue ?? Localization.systemCode(in: .module))
    }

    /// Starts a new instance of this app with the same arguments and quits this one; the caller quit through
    /// `applicationShouldTerminate`, so unsaved changes were already dealt with.
    @MainActor static func relaunch(releasing model: NotesModel) {
        model.releaseDraftsForRelaunch()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = Array(CommandLine.arguments.dropFirst())
        // The process ends right after this returns; wait until LaunchServices has taken the request.
        let accepted = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in accepted.signal() }
        _ = accepted.wait(timeout: .now() + 3)
    }

    @MainActor static func requestRelaunch() {
        relaunchPending = true
        NSApp.terminate(nil)
    }
}
