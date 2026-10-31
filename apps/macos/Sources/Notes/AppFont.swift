import AppKit
import SwiftUI

/// The text styles the app's own UI uses. Sizes are the system's for the style, so they never follow editor zoom.
enum AppTextStyle {
    case body, callout, caption, title3

    fileprivate var systemFont: Font {
        switch self {
        case .body: .body
        case .callout: .callout
        case .caption: .caption
        case .title3: .title3
        }
    }

    fileprivate var pointSize: Double {
        let style: NSFont.TextStyle = switch self {
        case .body: .body
        case .callout: .callout
        case .caption: .caption1
        case .title3: .title3
        }
        return NSFont.preferredFont(forTextStyle: style).pointSize
    }
}

extension Font {
    /// The UI font for a text style: the family picked in Settings at the style's system size, or the system font
    /// (exactly as before) when none is picked. A missing glyph falls back through the font cascade.
    static func app(_ style: AppTextStyle, weight: Font.Weight? = nil, family: String?) -> Font {
        guard let family else {
            return weight.map { style.systemFont.weight($0) } ?? style.systemFont
        }
        let font = Font.custom(family, fixedSize: style.pointSize)
        return weight.map { font.weight($0) } ?? font
    }
}

private struct AppFontModifier: ViewModifier {
    let style: AppTextStyle
    let weight: Font.Weight?
    @Environment(AppSettings.self) private var environmentSettings: AppSettings?

    func body(content: Content) -> some View {
        content.font(.app(style, weight: weight, family: (environmentSettings ?? .shared).baseTextFont.family))
    }
}

extension View {
    /// Draws text in the app font (the Settings text font family) at the size of `style`. Needs `AppSettings` in the
    /// environment; set it on a window's root to cover every view that doesn't pick its own style.
    func appFont(_ style: AppTextStyle = .body, weight: Font.Weight? = nil) -> some View {
        modifier(AppFontModifier(style: style, weight: weight))
    }
}
