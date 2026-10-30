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
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView(settings: settings)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            EditorSettingsView(settings: settings)
                .tabItem { Label("Editor", systemImage: "character.cursor.ibeam") }
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
                    Text("No folders in the workspace.")
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
                        Button("Remove") { settings.removeRoot?(path) }
                            .disabled(settings.removeRoot == nil)
                    }
                }
                HStack {
                    Spacer()
                    Button("Add Folder…") { settings.addRoot?() }
                        .disabled(settings.addRoot == nil)
                }
            } header: {
                Text("Workspace Folders")
            }

            Section {
                Toggle("Name notes after their first line", isOn: $settings.autoNaming)
                Toggle("Reopen tabs at launch", isOn: $settings.restoreTabs)
            }

            Section {
                Picker("Sort by", selection: $settings.sidebarSort) {
                    Text("Name").tag(SidebarSort.name)
                    Text("Date Modified").tag(SidebarSort.modified)
                }
                Toggle("Show other text and code files", isOn: $settings.showNonMarkdownFiles)
            } header: {
                Text("Sidebar")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Appearance

private struct AppearanceSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $settings.appearanceMode) {
                    Text("System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                .pickerStyle(.segmented)
            }

            Section {
                ThemePickerRow(settings: settings, appearance: .light, selection: $settings.lightThemeID)
                ThemePickerRow(settings: settings, appearance: .dark, selection: $settings.darkThemeID)
            } header: {
                Text("Themes")
            } footer: {
                HStack {
                    Button("Open Themes Folder") {
                        NSWorkspace.shared.open(settings.createThemesDirectory())
                    }
                    Button("Reload Themes") { settings.reloadThemes() }
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
                    Text("Theme files that could not be loaded")
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
            Picker(title, selection: $selection) {
                ForEach(themes) { theme in
                    Text(verbatim: theme.name).tag(theme.id)
                }
                if !known {
                    // A chosen theme that is gone (or still loading) keeps its id; the default is drawn meanwhile.
                    Text("\(selection) (not available)").tag(selection)
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
            run("# ", c.marker, heading, nil) + run("Notes", c.heading, heading, nil),
            run("Plain text, ", c.text, text, nil) + run("a link", c.link, text, nil) + run(" and ", c.text, text, nil)
                + run("`code`", c.inlineCode, code, c.inlineCodeBackground),
            run("> ", c.marker, text, nil) + run("A quote", c.blockquote, text, nil),
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
                Text("Fonts")
            }

            Section {
                LabeledContent("Line spacing") {
                    HStack {
                        Slider(value: $settings.lineSpacing, in: AppSettings.lineSpacingRange, step: 0.05)
                        Text(settings.lineSpacing, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                Toggle("Limit line width", isOn: $settings.limitLineWidth)
                Picker("Markdown syntax", selection: $settings.markerStyle) {
                    Text("Dimmed").tag(MarkerStyle.dimmed)
                    Text("Hidden, shown on the cursor line").tag(MarkerStyle.hidden)
                }
                Toggle("Check spelling while typing", isOn: $settings.spellCheck)
            } header: {
                Text("Notes")
            }

            Section {
                Toggle("Show line numbers", isOn: $settings.codeLineNumbers)
                Toggle("Wrap lines", isOn: $settings.codeWrap)
            } header: {
                Text("Code Files")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}
