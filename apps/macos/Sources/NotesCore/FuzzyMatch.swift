import Foundation

/// Subsequence matching for Quick Open: the query's characters must appear in order, case, diacritics and the Turkish
/// dotless ı ignored. Consecutive matches, matches at word starts and early matches score higher.
public enum FuzzyMatch {
    /// An item to match: its name, and its path for queries that name a folder too. Folded once, up front.
    public struct Candidate: Sendable {
        let name: [Unicode.Scalar]
        let path: [Unicode.Scalar]

        public init(name: String, path: String) {
            self.name = FuzzyMatch.fold(name)
            self.path = FuzzyMatch.fold(path)
        }
    }

    /// `text` lowercased, without diacritics and with ı/İ as i, as Unicode scalars.
    static func fold(_ text: String) -> [Unicode.Scalar] {
        let folded = NoteStore.foldDotlessI(text).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return Array(folded.unicodeScalars)
    }

    /// The score of `query` in `text` (both folded), `nil` when it is not a subsequence. Higher is better.
    static func score(_ query: [Unicode.Scalar], in text: [Unicode.Scalar]) -> Int? {
        guard !query.isEmpty else { return 0 }
        guard query.count <= text.count else { return nil }
        // Forward pass finds the earliest end; the backward pass then shrinks the match to the tightest window.
        var matched = 0
        var end = -1
        for (index, scalar) in text.enumerated() where scalar == query[matched] {
            matched += 1
            if matched == query.count {
                end = index
                break
            }
        }
        guard end >= 0 else { return nil }
        var positions = [Int](repeating: 0, count: query.count)
        var index = end
        for q in stride(from: query.count - 1, through: 0, by: -1) {
            while text[index] != query[q] { index -= 1 }
            positions[q] = index
            index -= 1
        }

        var score = 0
        for (q, position) in positions.enumerated() {
            score += 10
            if q > 0, position == positions[q - 1] + 1 { score += 15 }
            if position == 0 || !isWordCharacter(text[position - 1]) { score += 12 }
        }
        let span = end - positions[0] + 1
        score -= span - query.count
        score -= min(positions[0], 20)
        if positions[0] == 0 { score += 20 }
        if span == text.count { score += 30 }
        return score
    }

    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    /// The indexes of `candidates` that match `query`, best first (ties keep the given order); a match in the name beats
    /// one that needs the folder path. An empty query matches everything in the given order. At most `limit` indexes.
    public static func rank(_ query: String, in candidates: [Candidate], limit: Int = 100) -> [Int] {
        let query = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return Array(candidates.indices.prefix(limit)) }
        var scored: [(index: Int, score: Int)] = []
        for (index, candidate) in candidates.enumerated() {
            if let score = score(query, in: candidate.name) {
                scored.append((index, score + 100))
            } else if let score = score(query, in: candidate.path) {
                scored.append((index, score))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.prefix(limit).map(\.index)
    }
}
