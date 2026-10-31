import AppKit
import NotesCore
import SwiftUI

/// The Settings window (⌘,): General, Appearance and Editor tabs. Changes apply at once.
struct SettingsView: View {
    @Environment(AppSettings.self) private var environmentSettings: AppSettings?

    var body: some View {
        let settings = environmentSettings ?? .shared
        TabView {
            GeneralSettingsView(settings: settings)
                .tabItem { Label(loc: "General", systemImage: "gearshape") }
            AppearanceSettingsView(settings: settings)
                .tabItem { Label(loc: "Appearance", systemImage: "paintpalette") }
            EditorSettingsView(settings: settings)
                .tabItem { Label(loc: "Editor", systemImage: "character.cursor.ibeam") }
        }
        .frame(width: 580)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                if settings.workspaceRoots.isEmpty {
                    Text(loc: "No folders in the workspace.")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.workspaceRoots, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        Spacer()
                        Button(loc: "Remove") { settings.removeRoot?(path) }
                            .disabled(settings.removeRoot == nil)
                    }
                }
                HStack {
                    Spacer()
                    Button(loc: "Add Folder…") { settings.addRoot?() }
                        .disabled(settings.addRoot == nil)
                }
            } header: {
                Text(loc: "Workspace Folders")
            }

            Section {
                Picker(loc: "Language", selection: $settings.language) {
                    Text(loc: "System").tag(LanguageChoice.system)
                    Text(verbatim: Self.languageName("en")).tag(LanguageChoice.english)
                    Text(verbatim: Self.languageName("tr")).tag(LanguageChoice.turkish)
                }
                if settings.needsRestart {
                    HStack {
                        Text(loc: "Restart \(L("Notes")) to apply")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(loc: "Restart") { LanguageSetting.requestRelaunch() }
                    }
                }
            }

            Section {
                Toggle(loc: "Name notes after their first line", isOn: $settings.autoNaming)
                Toggle(loc: "Reopen tabs at launch", isOn: $settings.restoreTabs)
            }

            Section {
                Picker(loc: "Sort by", selection: $settings.sidebarSort) {
                    Text(loc: "Name").tag(SidebarSort.name)
                    Text(loc: "Date Modified").tag(SidebarSort.modified)
                }
                Toggle(loc: "Show other text and code files", isOn: $settings.showNonMarkdownFiles)
                Toggle(loc: "Show preview in sidebar", isOn: $settings.showSidebarPreview)
            } header: {
                Text(loc: "Sidebar")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A language's name in that language ("English", "Türkçe").
    private static func languageName(_ code: String) -> String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forLanguageCode: code)?.capitalized(with: locale) ?? code
    }
}

// MARK: - Appearance

private struct AppearanceSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker(loc: "Appearance", selection: $settings.appearanceMode) {
                    Text(loc: "System").tag(AppearanceMode.system)
                    Text(loc: "Light").tag(AppearanceMode.light)
                    Text(loc: "Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
            }

            Section {
                ThemePickerRow(settings: settings, appearance: .light, selection: $settings.lightThemeID)
                ThemePickerRow(settings: settings, appearance: .dark, selection: $settings.darkThemeID)
            } header: {
                Text(loc: "Themes")
            } footer: {
                HStack {
                    Button(loc: "Open Themes Folder") {
                        NSWorkspace.shared.open(settings.createThemesDirectory())
                    }
                    Button(loc: "Reload Themes") { settings.reloadThemes() }
                    if settings.isLoadingThemes {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
            }

            let issues = settings.themeLibrary.issues
            if !issues.isEmpty {
                Section {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(issues, id: \.self) { issue in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: issue.file.lastPathComponent)
                                    Text(verbatim: issue.error.localizedDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                } header: {
                    Text(loc: "Theme files that could not be loaded")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ThemePickerRow: View {
    let settings: AppSettings
    let appearance: ThemeAppearance
    @Binding var selection: String

    var body: some View {
        let library = settings.themeLibrary
        let themes = library.themes(for: appearance)
        let known = themes.contains { $0.id == selection }
        let title: LocalizedStringKey = appearance == .light ? "Light theme" : "Dark theme"
        VStack(alignment: .leading, spacing: 8) {
            Picker(loc: title, selection: $selection) {
                ForEach(themes) { theme in
                    Text(verbatim: theme.displayName).tag(theme.id)
                }
                if !known {
                    // A chosen theme that is gone (or still loading) keeps its id; the default is drawn meanwhile.
                    Text(loc: "\(selection) (not available)").tag(selection)
                }
            }
            ThemePreview(theme: library.resolvedTheme(id: selection, for: appearance), settings: settings)
        }
    }
}

/// A small sample of Markdown and code drawn with `theme` and the editor fonts.
struct ThemePreview: View {
    let theme: ResolvedTheme
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines.indices, id: \.self) { Text(lines[$0]).lineLimit(1) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: theme.colors.background.nsColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .accessibilityHidden(true)
    }

    private var lines: [AttributedString] {
        let c = theme.colors, s = theme.syntax
        let text = EditorPalette.font(settings.textFont, monospaced: false).withSize(12)
        let code = EditorPalette.font(settings.codeFont, monospaced: true).withSize(11)
        let heading = NSFontManager.shared.convert(text.withSize(15), toHaveTrait: .boldFontMask)
        let block = c.codeBlockBackground
        let run = Self.run
        return [
            run("# ", c.marker, heading, nil) + run(L("Notes"), c.heading, heading, nil),
            run(L("Plain text, "), c.text, text, nil) + run(L("a link"), c.link, text, nil) + run(L(" and "), c.text, text, nil)
                + run("`code`", c.inlineCode, code, c.inlineCodeBackground),
            run("> ", c.marker, text, nil) + run(L("A quote"), c.blockquote, text, nil),
            run("let ", s.keyword, code, block) + run("name = ", c.text, code, block) + run("\"Ada\"", s.string, code, block)
                + run(" // ", s.comment, code, block) + run("42", s.number, code, block),
        ]
    }

    private static func run(_ string: String, _ color: ThemeColor, _ font: NSFont, _ background: ThemeColor?) -> AttributedString {
        var a = AttributedString(string)
        a.foregroundColor = Color(nsColor: color.nsColor)
        a.font = Font(font)
        if let background { a.backgroundColor = Color(nsColor: background.nsColor) }
        return a
    }
}

// MARK: - Editor

private struct EditorSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                FontSettingRow(title: "Text font", choice: $settings.textFont, monospaced: false)
                FontSettingRow(title: "Code font", choice: $settings.codeFont, monospaced: true)
            } header: {
                Text(loc: "Fonts")
            }

            Section {
                LabeledContent(loc: "Line spacing") {
                    HStack {
                        Slider(value: $settings.lineSpacing, in: AppSettings.lineSpacingRange, step: 0.05)
                        Text(settings.lineSpacing, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                Toggle(loc: "Limit line width", isOn: $settings.limitLineWidth)
                Picker(loc: "Markdown syntax", selection: $settings.markerStyle) {
                    Text(loc: "Dimmed").tag(MarkerStyle.dimmed)
                    Text(loc: "Hidden, shown on the cursor line").tag(MarkerStyle.hidden)
                }
                Toggle(loc: "Check spelling while typing", isOn: $settings.spellCheck)
            } header: {
                Text(loc: "Notes")
            }

            Section {
                Toggle(loc: "Show line numbers", isOn: $settings.codeLineNumbers)
                Toggle(loc: "Wrap lines", isOn: $settings.codeWrap)
            } header: {
                Text(loc: "Code Files")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
