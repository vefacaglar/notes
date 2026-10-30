import AppKit
import NotesCore
import SwiftUI

/// Everything the editors draw with: the theme of the window's appearance plus the editor settings.
/// A plain value, so the editors can tell cheaply whether anything changed.
struct EditorStyle: Equatable, Sendable {
    var theme: ResolvedTheme
    var textFont: FontChoice
    var codeFont: FontChoice
    var lineSpacing: Double
    var limitLineWidth: Bool
    var markerStyle: MarkerStyle
    var spellCheck: Bool
    var codeLineNumbers: Bool
    var codeWrap: Bool

    static let standard = EditorStyle(
        theme: ThemeLibrary.baseTheme(for: .light), textFont: AppSettings.defaultTextFont, codeFont: AppSettings.defaultCodeFont,
        lineSpacing: 1.2, limitLineWidth: true, markerStyle: .dimmed, spellCheck: false, codeLineNumbers: true, codeWrap: true
    )

    init(theme: ResolvedTheme, textFont: FontChoice, codeFont: FontChoice, lineSpacing: Double, limitLineWidth: Bool,
         markerStyle: MarkerStyle, spellCheck: Bool, codeLineNumbers: Bool, codeWrap: Bool) {
        self.theme = theme
        self.textFont = textFont
        self.codeFont = codeFont
        self.lineSpacing = lineSpacing
        self.limitLineWidth = limitLineWidth
        self.markerStyle = markerStyle
        self.spellCheck = spellCheck
        self.codeLineNumbers = codeLineNumbers
        self.codeWrap = codeWrap
    }

    @MainActor
    init(settings: AppSettings, colorScheme: ColorScheme) {
        self.init(
            theme: settings.resolvedTheme(for: colorScheme), textFont: settings.textFont, codeFont: settings.codeFont,
            lineSpacing: settings.lineSpacing, limitLineWidth: settings.limitLineWidth, markerStyle: settings.markerStyle,
            spellCheck: settings.spellCheck, codeLineNumbers: settings.codeLineNumbers, codeWrap: settings.codeWrap
        )
    }
}

extension ThemeColor {
    var nsColor: NSColor {
        NSColor(srgbRed: redComponent, green: greenComponent, blue: blueComponent, alpha: alphaComponent)
    }
}

/// AppKit fonts, colors and attributes built once per `EditorStyle`.
@MainActor
final class EditorPalette {
    let style: EditorStyle
    let colors: ResolvedTheme.Colors
    let textFont: NSFont
    let codeFont: NSFont
    let textParagraph: NSParagraphStyle
    let codeParagraph: NSParagraphStyle
    /// Body text of a Markdown note.
    let markdownBase: [NSAttributedString.Key: Any]
    /// Code files, and Markdown shown as source.
    let codeBase: [NSAttributedString.Key: Any]
    let syntax: [CodeSpan.Kind: [NSAttributedString.Key: Any]]
    /// Markdown syntax hidden off the cursor line: practically zero-width and invisible, still real text.
    let hiddenMarker: [NSAttributedString.Key: Any]

    init(_ style: EditorStyle) {
        self.style = style
        colors = style.theme.colors
        textFont = Self.font(style.textFont, monospaced: false)
        codeFont = Self.font(style.codeFont, monospaced: true)

        let text = NSMutableParagraphStyle()
        text.lineHeightMultiple = style.lineSpacing
        text.paragraphSpacing = 4
        textParagraph = text

        let code = NSMutableParagraphStyle()
        code.lineHeightMultiple = style.lineSpacing
        code.tabStops = []
        code.defaultTabInterval = 4 * (" " as NSString).size(withAttributes: [.font: codeFont]).width
        codeParagraph = code

        markdownBase = [.font: textFont, .foregroundColor: colors.text.nsColor, .paragraphStyle: textParagraph]
        codeBase = [.font: codeFont, .foregroundColor: colors.text.nsColor, .paragraphStyle: codeParagraph]

        let s = style.theme.syntax
        let keywordFont = Self.withTraits(.boldFontMask, codeFont, systemMonoWeight: style.codeFont.family == nil ? .semibold : nil)
        syntax = [
            .keyword: [.foregroundColor: s.keyword.nsColor, .font: keywordFont],
            .literal: [.foregroundColor: s.literal.nsColor],
            .string: [.foregroundColor: s.string.nsColor],
            .number: [.foregroundColor: s.number.nsColor],
            .comment: [.foregroundColor: s.comment.nsColor],
            .type: [.foregroundColor: s.type.nsColor],
            .property: [.foregroundColor: s.property.nsColor],
            .tag: [.foregroundColor: s.tag.nsColor],
        ]
        hiddenMarker = [.font: NSFont.systemFont(ofSize: 0.01), .foregroundColor: NSColor.clear]
    }

    var selectionColor: NSColor { colors.selection.composited(over: colors.background).nsColor }

    /// The code font at a size that keeps the code/text ratio from the settings, for code inside text of `size`.
    func codeFont(relativeTo size: CGFloat) -> NSFont {
        let scaled = size * codeFont.pointSize / max(textFont.pointSize, 1)
        return codeFont.withSize(scaled.rounded(.toNearestOrEven))
    }

    func headingFont(size: CGFloat) -> NSFont {
        let font = textFont.withSize(size)
        return style.textFont.family == nil ? NSFont.systemFont(ofSize: size, weight: .bold) : Self.withTraits(.boldFontMask, font)
    }

    // MARK: Fonts

    /// `family == nil`, or a family that is not installed: the system font (SF Pro / SF Mono).
    static func font(_ choice: FontChoice, monospaced: Bool) -> NSFont {
        let size = CGFloat(choice.size)
        if let family = choice.family,
           let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return font
        }
        return monospaced ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
    }

    /// Bold/italic variant if the family has one; the system monospaced font gets a real weight instead.
    static func withTraits(_ traits: NSFontTraitMask, _ font: NSFont, systemMonoWeight: NSFont.Weight? = nil) -> NSFont {
        if let systemMonoWeight { return .monospacedSystemFont(ofSize: font.pointSize, weight: systemMonoWeight) }
        return NSFontManager.shared.convert(font, toHaveTrait: traits)
    }
}

extension NSTextView {
    /// Colors and spell checking shared by both editors.
    func apply(_ palette: EditorPalette, spellCheck: Bool) {
        backgroundColor = palette.colors.background.nsColor
        insertionPointColor = palette.colors.cursor.nsColor
        selectedTextAttributes = [.backgroundColor: palette.selectionColor]
        isContinuousSpellCheckingEnabled = spellCheck
        isGrammarCheckingEnabled = spellCheck
        isAutomaticSpellingCorrectionEnabled = false
        enclosingScrollView?.backgroundColor = palette.colors.background.nsColor
        enclosingScrollView?.drawsBackground = true
    }
}
