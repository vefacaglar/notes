import Foundation
import Testing
@testable import NotesCore

struct FuzzyMatchTests {
    private func rank(_ query: String, _ items: [(String, String)]) -> [String] {
        let candidates = items.map { FuzzyMatch.Candidate(name: $0.0, path: $0.1) }
        return FuzzyMatch.rank(query, in: candidates).map { items[$0].1 }
    }

    @Test func subsequenceMatches() {
        let items = [("Meeting notes", "Meeting notes.md"), ("Shopping", "Shopping.md")]
        #expect(rank("mtgn", items) == ["Meeting notes.md"])
        #expect(rank("zzz", items).isEmpty)
    }

    @Test func orderMatters() {
        #expect(rank("ba", [("ab", "ab.md")]).isEmpty)
    }

    @Test func emptyQueryKeepsGivenOrder() {
        let items = [("b", "b.md"), ("a", "a.md")]
        #expect(rank("  ", items) == ["b.md", "a.md"])
    }

    @Test func prefixAndConsecutiveBeatScattered() {
        let items = [("Big red apple", "x/Big red apple.md"), ("Apple pie", "Apple pie.md"), ("Pineapple", "Pineapple.md")]
        #expect(rank("apple", items) == ["Apple pie.md", "x/Big red apple.md", "Pineapple.md"])
    }

    @Test func turkishAndDiacriticsFold() {
        let items = [("Toplantı Notları", "Toplantı Notları.md"), ("Işık", "Işık.md")]
        #expect(rank("toplanti", items) == ["Toplantı Notları.md"])
        #expect(rank("TOPLANTI", items) == ["Toplantı Notları.md"])
        #expect(rank("isik", items) == ["Işık.md"])
        #expect(rank("İşık", items) == ["Işık.md"])
        #expect(rank("cafe", [("Café", "Café.md")]) == ["Café.md"])
    }

    @Test func emojiNamesDoNotCrash() {
        #expect(rank("ab", [("🙂a🙂b", "🙂a🙂b.md")]) == ["🙂a🙂b.md"])
    }

    @Test func nameMatchBeatsPathOnlyMatch() {
        let items = [("Plan", "Work/Plan.md"), ("Other", "Work/Other.md")]
        #expect(rank("work", items) == ["Work/Plan.md", "Work/Other.md"])
        #expect(rank("pl", items) == ["Work/Plan.md"])
        let both = [("x", "work/x.md"), ("Notes work", "A/Notes work.md")]
        #expect(rank("work", both).first == "A/Notes work.md")
    }

    @Test func limitApplies() {
        let candidates = (0..<10).map { FuzzyMatch.Candidate(name: "n\($0)", path: "n\($0).md") }
        #expect(FuzzyMatch.rank("n", in: candidates, limit: 3).count == 3)
    }
}
