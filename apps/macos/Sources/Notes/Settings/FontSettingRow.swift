import AppKit
import CoreText
import SwiftUI

/// A font setting: the family (shown in itself, picked from a searchable list) and the size.
struct FontSettingRow: View {
    let title: LocalizedStringKey
    @Binding var choice: FontChoice
    let monospaced: Bool
    @State private var showsPicker = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Button {
                    showsPicker.toggle()
                } label: {
                    familyLabel
                        .lineLimit(1)
                        .frame(minWidth: 120, maxWidth: 200, alignment: .leading)
                }
                .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
                    FontFamilyList(selection: $choice.family, monospaced: monospaced)
                }
                TextField("Size", value: size, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                Stepper("Size", value: size, in: FontChoice.sizeRange, step: 1)
                    .labelsHidden()
            }
        }
    }

    @ViewBuilder private var familyLabel: some View {
        if let family = choice.family {
            Text(verbatim: family).font(.custom(family, size: 13))
        } else {
            Text("System")
        }
    }

    /// Clamped to 8–36.
    private var size: Binding<Double> {
        Binding {
            choice.size
        } set: { value in
            guard value.isFinite else { return }
            choice.size = min(max(value, FontChoice.sizeRange.lowerBound), FontChoice.sizeRange.upperBound)
        }
    }
}

/// Every installed family, each drawn in its own font. `nil` is the system font.
private struct FontFamilyList: View {
    @Binding var selection: String?
    let monospaced: Bool
    @State private var query = ""
    @State private var monospacedOnly: Bool
    @State private var catalog = FontFamilyCatalog.shared

    init(selection: Binding<String?>, monospaced: Bool) {
        _selection = selection
        self.monospaced = monospaced
        _monospacedOnly = State(initialValue: monospaced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
            if monospaced {
                Toggle("Monospaced only", isOn: $monospacedOnly)
                    .disabled(catalog.monospaced == nil)
            }
            List {
                if query.isEmpty {
                    row(nil)
                }
                ForEach(families, id: \.self) { row($0) }
            }
            .listStyle(.plain)
        }
        .padding(10)
        .frame(width: 300, height: 380)
        .onAppear { if monospaced { catalog.loadMonospaced() } }
    }

    private var families: [String] {
        var list = catalog.families
        if monospaced, let mono = catalog.monospaced {
            list = monospacedOnly ? list.filter(mono.contains) : list.filter(mono.contains) + list.filter { !mono.contains($0) }
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter { $0.localizedStandardContains(q) }
    }

    private func row(_ family: String?) -> some View {
        Button {
            selection = family
        } label: {
            HStack {
                if let family {
                    Text(verbatim: family).font(.custom(family, size: 14))
                } else {
                    Text("System").font(.system(size: 14, design: monospaced ? .monospaced : .default))
                }
                Spacer()
                if family == selection {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lineLimit(1)
    }
}

/// Installed font families, and which of them are monospaced (worked out once, off the main actor).
@Observable @MainActor
final class FontFamilyCatalog {
    static let shared = FontFamilyCatalog()

    let families: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    private(set) var monospaced: Set<String>?
    private var isLoading = false

    func loadMonospaced() {
        guard monospaced == nil, !isLoading else { return }
        isLoading = true
        let families = families
        Task.detached(priority: .userInitiated) {
            let mono = Set(families.filter(Self.isMonospaced))
            await MainActor.run {
                self.monospaced = mono
                self.isLoading = false
            }
        }
    }

    nonisolated private static func isMonospaced(_ family: String) -> Bool {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        return CTFontGetSymbolicTraits(font).contains(.traitMonoSpace)
    }
}
