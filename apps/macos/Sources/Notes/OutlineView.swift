import NotesCore
import SwiftUI

/// The headings of a Markdown note as an indented list; choosing one calls `onSelect`.
struct OutlineView: View {
    let text: String
    var onSelect: (OutlineHeading) -> Void

    var body: some View {
        let headings = MarkdownOutline.headings(in: text)
        let top = headings.map(\.level).min() ?? 1
        Group {
            if headings.isEmpty {
                Text(loc: "No headings")
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(headings.enumerated()), id: \.offset) { _, heading in
                            Button { onSelect(heading) } label: {
                                Text(heading.title)
                                    .appFont(.body, weight: heading.level == top ? .semibold : nil)
                                    .foregroundStyle(heading.level <= top + 1 ? .primary : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .padding(.leading, CGFloat(heading.level - top) * 14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 12)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 280)
        .appFont()
    }
}
