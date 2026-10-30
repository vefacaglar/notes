import NotesCore
import SwiftUI

/// Where the Notes target's strings come from. SwiftUI's `Text("…")` and friends read `Bundle.main`, which has no
/// catalog under SwiftPM, so every user-facing literal goes through the `loc:` initializers below or `L(_:)`.
enum Strings {
    /// The module's resources narrowed to the UI language chosen at launch (`Localization.configure`).
    static let bundle = Localization.bundle(.module)
}

func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: Strings.bundle)
}

extension Text {
    init(loc key: LocalizedStringKey) { self.init(key, bundle: Strings.bundle) }
}

extension Button where Label == Text {
    init(loc key: LocalizedStringKey, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { Text(loc: key) }
    }
}

extension Toggle where Label == Text {
    init(loc key: LocalizedStringKey, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(loc: key) }
    }
}

extension Picker where Label == Text {
    init(loc key: LocalizedStringKey, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.init(selection: selection, content: content) { Text(loc: key) }
    }
}

extension Label where Title == Text, Icon == Image {
    init(loc key: LocalizedStringKey, systemImage: String) {
        self.init { Text(loc: key) } icon: { Image(systemName: systemImage) }
    }
}

extension TextField where Label == Text {
    init(loc key: LocalizedStringKey, text: Binding<String>) {
        self.init(text: text) { Text(loc: key) }
    }

    init<F: ParseableFormatStyle>(loc key: LocalizedStringKey, value: Binding<F.FormatInput>, format: F)
    where F.FormatOutput == String {
        self.init(value: value, format: format) { Text(loc: key) }
    }
}

extension Stepper where Label == Text {
    init<V: Strideable>(loc key: LocalizedStringKey, value: Binding<V>, in range: ClosedRange<V>, step: V.Stride = 1) {
        self.init(value: value, in: range, step: step) { Text(loc: key) }
    }
}

extension LabeledContent where Label == Text, Content: View {
    init(loc key: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content) { Text(loc: key) }
    }
}

extension View {
    func help(loc key: LocalizedStringKey) -> some View { help(Text(loc: key)) }
}
