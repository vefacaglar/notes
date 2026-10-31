import NotesCore
import SwiftUI

/// Word, character and line counts of the active document. Counted off the main actor, shortly after typing stops.
struct StatusBar: View {
    let document: NoteDocument
    @State private var statistics: TextStatistics?

    /// Which text was counted: a cheap token instead of comparing the whole text on every keystroke.
    private struct Token: Hashable {
        let document: UUID
        let revision: Int
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                if let statistics {
                    Text(L("\(statistics.words) words"))
                    Text(L("\(statistics.characters) characters"))
                    Text(L("\(statistics.lines) lines"))
                }
                Spacer(minLength: 0)
            }
            .appFont(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 22)
            .background(.bar)
        }
        .task(id: Token(document: document.id, revision: document.revision)) {
            // The first count is immediate; later ones wait for a pause in typing.
            if statistics != nil { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            let text = document.text
            let result = await Task.detached(priority: .utility) { TextStatistics(text) }.value
            if !Task.isCancelled { statistics = result }
        }
        .accessibilityElement(children: .combine)
    }
}
