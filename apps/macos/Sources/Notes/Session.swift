import Foundation
import NotesCore

/// Command-line options for test runs. All are argument-domain values, so nothing is written to the preferences.
enum LaunchOptions {
    /// `-notesFolder <path>`, repeatable: the roots for this run, never saved as the workspace.
    static let testRoots: [String] = values("notesFolder")
    /// `-supportFolder <path>`: where session and drafts live instead of `~/Library/Application Support/Notes`.
    static let supportFolderOverride: String? = argument("supportFolder")
    /// `-theme light|dark`: forces the appearance for this run only (it is not saved).
    static let theme: AppearanceMode? = {
        guard let mode = argument("theme").flatMap(AppearanceMode.init(rawValue:)), mode != .system else { return nil }
        return mode
    }()

    /// Whether this run may change the user's saved workspace and app state.
    static var isPersistent: Bool { testRoots.isEmpty }

    /// Where preferences go: the user's defaults, or in a test run a throwaway suite (emptied at launch) so nothing
    /// real is read or written.
    nonisolated(unsafe) static let preferences: UserDefaults = {
        guard !isPersistent, let suite = UserDefaults(suiteName: "com.vefa.notes.testrun") else { return .standard }
        suite.removePersistentDomain(forName: "com.vefa.notes.testrun")
        return suite
    }()

    /// The app's own folder for the session file and drafts; `nil` for a test run without `-supportFolder`, which
    /// keeps no session and throwaway drafts.
    static var supportFolder: URL? {
        if let supportFolderOverride { return URL(fileURLWithPath: supportFolderOverride, isDirectory: true) }
        guard isPersistent else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Notes", isDirectory: true)
    }

    private static func argument(_ key: String) -> String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String
    }

    /// Every value given for `-key <value>` on the command line. The argument domain keeps only the last one, so a
    /// repeatable option is read from the arguments themselves; a value that starts with "-" is another option.
    private static func values(_ key: String) -> [String] {
        var result: [String] = []
        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            guard argument == "-" + key, let value = arguments.next(), !value.hasPrefix("-") else { continue }
            result.append(value)
        }
        return result
    }
}

/// The open windows and tabs, saved to `session.json` in the support folder so they come back after a relaunch.
/// App state, not part of any notes folder.
struct Session: Codable {
    struct Window: Codable {
        /// The main window (the user's roots); otherwise the window of an outside file, rooted at `root`.
        var isMain: Bool
        var root: String?
        var tabs: [Tab]
        var activeTab: Int?
        var sidebarVisible: Bool
        /// `NSStringFromRect` of the window frame; outside-file windows only (the main window is restored by AppKit).
        var frame: String?
    }

    struct Tab: Codable {
        /// Absolute path of the file, or the draft's file name in the draft store.
        var file: String?
        var draft: String?
        var showsSource: Bool
        var view: EditorViewState?
    }

    var version = 1
    var windows: [Window]

    static func read(_ url: URL) -> Session? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
