import AppKit
import NotesCore
import SwiftUI

/// A font picked in Settings. `family == nil` means the system font (SF Pro, or SF Mono for code).
struct FontChoice: Codable, Hashable, Sendable {
    var family: String?
    var size: Double

    static let sizeRange: ClosedRange<Double> = 8...36
}

enum MarkerStyle: String, Codable, Sendable, CaseIterable {
    /// Markdown syntax is shown in the theme's marker color.
    case dimmed
    /// Markdown syntax is hidden except on the lines with the cursor or selection.
    case hidden
}

enum SidebarSort: String, Codable, Sendable, CaseIterable {
    case name, modified
}

/// App-wide preferences, stored in `UserDefaults`. Every value is read leniently: a missing or bad value
/// falls back to its own default without touching the others.
@Observable @MainActor
final class AppSettings {
    static let shared = AppSettings()

    nonisolated static let defaultTextFont = FontChoice(family: nil, size: 15)
    nonisolated static let defaultCodeFont = FontChoice(family: nil, size: 13)
    nonisolated static let lineSpacingRange: ClosedRange<Double> = 1.0...2.0

    var appearanceMode: AppearanceMode { didSet { save(appearanceMode.rawValue, .appearanceMode); applyAppearance() } }
    var lightThemeID: String { didSet { save(lightThemeID, .lightThemeID) } }
    var darkThemeID: String { didSet { save(darkThemeID, .darkThemeID) } }
    var textFont: FontChoice { didSet { saveFont(textFont, .textFont) } }
    var codeFont: FontChoice { didSet { saveFont(codeFont, .codeFont) } }
    var lineSpacing: Double { didSet { save(lineSpacing, .lineSpacing) } }
    var limitLineWidth: Bool { didSet { save(limitLineWidth, .limitLineWidth) } }
    var markerStyle: MarkerStyle { didSet { save(markerStyle.rawValue, .markerStyle) } }
    var spellCheck: Bool { didSet { save(spellCheck, .spellCheck) } }
    var codeLineNumbers: Bool { didSet { save(codeLineNumbers, .codeLineNumbers) } }
    var codeWrap: Bool { didSet { save(codeWrap, .codeWrap) } }
    var restoreTabs: Bool { didSet { save(restoreTabs, .restoreTabs) } }
    var sidebarSort: SidebarSort { didSet { save(sidebarSort.rawValue, .sidebarSort) } }
    var showNonMarkdownFiles: Bool { didSet { save(showNonMarkdownFiles, .showNonMarkdownFiles) } }
    var autoNaming: Bool { didSet { save(autoNaming, .autoNaming) } }

    /// Built-in themes at once; user themes arrive after `reloadThemes()` finishes reading the folder off the main actor.
    private(set) var themeLibrary = ThemeLibrary()
    private(set) var isLoadingThemes = false

    /// The workspace's root folders (paths), kept current by the app model; Settings only displays them.
    var workspaceRoots: [String] = []
    /// Set by the app model: asks for a folder and adds it as a root.
    var addRoot: (@MainActor () -> Void)?
    /// Set by the app model: removes the root with this path from the workspace.
    var removeRoot: (@MainActor (String) -> Void)?

    private let defaults: UserDefaults
    private var reloadGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func string(_ key: Key) -> String? { defaults.string(forKey: key.name) }
        func bool(_ key: Key, _ fallback: Bool) -> Bool { defaults.object(forKey: key.name) as? Bool ?? fallback }
        appearanceMode = string(.appearanceMode).flatMap(AppearanceMode.init(rawValue:)) ?? .system
        lightThemeID = string(.lightThemeID).flatMap { $0.isEmpty ? nil : $0 } ?? ThemeLibrary.defaultLightID
        darkThemeID = string(.darkThemeID).flatMap { $0.isEmpty ? nil : $0 } ?? ThemeLibrary.defaultDarkID
        textFont = Self.font(defaults.object(forKey: Key.textFont.name), fallback: Self.defaultTextFont)
        codeFont = Self.font(defaults.object(forKey: Key.codeFont.name), fallback: Self.defaultCodeFont)
        if let spacing = defaults.object(forKey: Key.lineSpacing.name) as? Double, spacing.isFinite {
            lineSpacing = min(max(spacing, Self.lineSpacingRange.lowerBound), Self.lineSpacingRange.upperBound)
        } else {
            lineSpacing = 1.2
        }
        limitLineWidth = bool(.limitLineWidth, true)
        markerStyle = string(.markerStyle).flatMap(MarkerStyle.init(rawValue:)) ?? .dimmed
        spellCheck = bool(.spellCheck, false)
        codeLineNumbers = bool(.codeLineNumbers, true)
        codeWrap = bool(.codeWrap, true)
        restoreTabs = bool(.restoreTabs, true)
        sidebarSort = string(.sidebarSort).flatMap(SidebarSort.init(rawValue:)) ?? .name
        showNonMarkdownFiles = bool(.showNonMarkdownFiles, true)
        autoNaming = bool(.autoNaming, true)
        reloadThemes()
        applyAppearance()
    }

    // MARK: Themes

    /// `~/Library/Application Support/Notes/Themes`. Not created here; see `createThemesDirectory()`.
    var themesDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return support.appending(path: "Notes/Themes", directoryHint: .isDirectory)
    }

    @discardableResult
    func createThemesDirectory() -> URL {
        let url = themesDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Re-reads the user theme folder off the main actor; the latest call wins.
    func reloadThemes() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let directory = themesDirectory
        isLoadingThemes = true
        Task.detached(priority: .userInitiated) {
            let library = ThemeLibrary(userDirectory: directory)
            await MainActor.run {
                guard generation == self.reloadGeneration else { return }
                self.themeLibrary = library
                self.isLoadingThemes = false
            }
        }
    }

    var themePreferences: ThemePreferences {
        ThemePreferences(mode: appearanceMode, lightThemeID: lightThemeID, darkThemeID: darkThemeID)
    }

    /// The theme for an effective (window) color scheme. The mode is already reflected in the window's appearance.
    func resolvedTheme(for colorScheme: ColorScheme) -> ResolvedTheme {
        let appearance: ThemeAppearance = colorScheme == .dark ? .dark : .light
        return themeLibrary.resolvedTheme(id: appearance == .light ? lightThemeID : darkThemeID, for: appearance)
    }

    func resolvedTheme(for appearance: NSAppearance) -> ResolvedTheme {
        resolvedTheme(for: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)
    }

    // MARK: Appearance

    /// Sets `NSApp.appearance` from `appearanceMode`. Called on change; the app calls it once at launch too
    /// (safe to call before `NSApp` exists — it does nothing then).
    func applyAppearance() {
        guard let app = NSApp else { return }
        switch appearanceMode {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Storage

    private enum Key: String {
        case appearanceMode, lightThemeID, darkThemeID, textFont, codeFont, lineSpacing, limitLineWidth, markerStyle
        case spellCheck, codeLineNumbers, codeWrap, restoreTabs, sidebarSort, showNonMarkdownFiles, autoNaming

        var name: String { "settings." + rawValue }
    }

    private func save(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.name)
    }

    private func saveFont(_ font: FontChoice, _ key: Key) {
        var dictionary: [String: Any] = ["size": font.size]
        if let family = font.family { dictionary["family"] = family }
        save(dictionary, key)
    }

    private static func font(_ object: Any?, fallback: FontChoice) -> FontChoice {
        guard let dictionary = object as? [String: Any] else { return fallback }
        let family = (dictionary["family"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        var size = fallback.size
        if let value = dictionary["size"] as? Double, value.isFinite {
            size = min(max(value, FontChoice.sizeRange.lowerBound), FontChoice.sizeRange.upperBound)
        }
        return FontChoice(family: family, size: size)
    }
}
