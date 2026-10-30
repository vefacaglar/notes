import Foundation
import Testing
@testable import NotesCore

struct NoteNamingTests {
    @Test(arguments: [
        ("Alışveriş listesi", "Alışveriş listesi"),
        ("\n\n   \n  İlk satır  \nikinci", "İlk satır"),
        ("# Başlık\ngövde", "Başlık"),
        ("###   Üç   ###", "Üç"),
        ("## **Kalın** ve *eğik* başlık", "Kalın ve eğik başlık"),
        ("**Yarım kalan", "Yarım kalan"),
        ("> - [ ] Süt al", "Süt al"),
        ("- [x] Bitti", "Bitti"),
        ("1. Giriş", "Giriş"),
        ("[Bağlantı](https://example.com) metni", "Bağlantı metni"),
        ("`kod` parçası", "kod parçası"),
        ("~~eski~~ yeni", "eski yeni"),
        ("Toplantı: 3/4 \"önemli\"", "Toplantı- 3-4 'önemli'"),
        ("Ne yapmalı?", "Ne yapmalı"),
        ("a\\b|c<d>e", "a-b-c-d-e"),
        ("Sekme\tile\u{7}ayrılmış", "Sekme ile ayrılmış"),
        ("...gizli değil...", "gizli değil"),
        ("Bitiyor . . .", "Bitiyor"),
        ("çok    boşluklu   satır", "çok boşluklu satır"),
        ("🎉 Parti 👨‍👩‍👧", "🎉 Parti 👨‍👩‍👧"),
        ("#etiket", "#etiket"),
        ("Windows satırı\r\nikinci", "Windows satırı"),
    ])
    func title(content: String, expected: String) {
        #expect(NoteStore.title(from: content) == expected)
    }

    @Test(arguments: ["", "   \n\t\n", "# ", "#", "## ##", "- [ ] ", "> ", "---", "***", "```swift\nkod\n```", "???", "//", "**"])
    func noTitle(content: String) {
        #expect(NoteStore.title(from: content) == nil)
    }

    @Test func titleIsNormalizedToNFC() {
        #expect(NoteStore.title(from: "Gu\u{308}nlu\u{308}k")?.unicodeScalars.count == 6)
    }

    @Test func longTitlesAreCappedOnGraphemeBoundaries() throws {
        let words = String(repeating: "kelime ", count: 20)
        let title = try #require(NoteStore.title(from: words))
        #expect(title.count <= NoteStore.maxTitleLength)
        #expect(!title.hasSuffix(" "))
        #expect(words.hasPrefix(title))
        #expect(title.hasSuffix("kelime"))

        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 80)
        let capped = try #require(NoteStore.title(from: emoji))
        #expect(capped.utf8.count <= NoteStore.maxTitleBytes)
        #expect(capped.allSatisfy { $0 == "👨‍👩‍👧‍👦" })

        let turkish = try #require(NoteStore.title(from: String(repeating: "ş", count: 100)))
        #expect(turkish.count == NoteStore.maxTitleLength)
    }

    @Test func titlesAreValidNames() throws {
        let contents = [
            "a/b", ".x.", "x :", "\"q\"", "🎉 👨‍👩‍👧", String(repeating: "ğ", count: 90),
            ".\u{301}Gizli not", "w/🏻 notu", "a/\u{200D}b", "x.\u{301}", "a\u{2028}b", "\u{A0}.x\u{3000}",
            "CON", "nul.txt", "Lpt9 ", "com1.tar.gz",
        ]
        for content in contents {
            let title = try #require(NoteStore.title(from: content), "\(content.debugDescription)")
            #expect(NoteStore.isValidName(title + ".md"), "\(content.debugDescription) → \(title.debugDescription)")
            #expect(NoteStore.isValidName(title), "\(content.debugDescription) → \(title.debugDescription)")
        }
    }

    /// A "/" or "." that carries a combining mark, ZWJ or emoji modifier is one Character but still a separator or a dot.
    @Test(arguments: [
        (".\u{301}Gizli not", "Gizli not"),
        ("w/🏻 notu", "w-🏻 notu"),
        ("a/\u{200D}b", "a-\u{200D}b"),
        ("...\u{301}x", "x"),
    ])
    func separatorsAndDotsAreFoundPerScalar(content: String, expected: String) throws {
        let title = try #require(NoteStore.title(from: content))
        #expect(title.unicodeScalars.elementsEqual(expected.unicodeScalars), "\(title.debugDescription)")
        #expect(!title.unicodeScalars.contains("/"))
    }

    @Test func autoNamedNoteNeverLeavesItsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoteNamingTests-\(UUID().uuidString)")
        let store = try NoteStore(root: root)
        try store.createFolder(named: "w")
        let path = try store.createNote(named: "Adsız")
        let title = try #require(NoteStore.title(from: "w/🏻 notu"))
        let newPath = try store.rename(path, to: store.uniqueNoteName(title, in: nil, ignoring: path) + ".md")
        #expect(NoteStore.parent(newPath).isEmpty)
        #expect(store.tree().map(\.name).contains("w-🏻 notu"))
    }

    @Test(arguments: [("CON", "CON_"), ("nul", "nul_"), ("Aux.txt", "Aux_.txt"), ("COM1 .x", "COM1_ .x"), ("LPT10", "LPT10"),
                      ("Console", "Console"), ("PRN.", "PRN_")])
    func reservedNamesGetASuffix(content: String, expected: String) {
        #expect(NoteStore.title(from: content) == expected)
    }

    @Test func typedReservedNamesAreRejected() {
        for name in ["CON", "con.md", "Nul.txt", "COM9", "lpt1 .md"] { #expect(!NoteStore.isValidName(name), "\(name)") }
        for name in ["CONSOLE", "COM10", "NULL.md", "x.CON"] { #expect(NoteStore.isValidName(name), "\(name)") }
    }

    @Test func linesEndAtLineFeedOnly() {
        // A lone CR or U+2028 is not a line break; a CR before LF is dropped.
        #expect(NoteStore.title(from: "bir\riki\nüç") == "bir iki")
        #expect(NoteStore.title(from: "bir\u{2028}iki") == "bir iki")
        #expect(NoteStore.title(from: "\r\n \r\n\u{A0}\nİlk\r\n") == "İlk")
        #expect(NoteStore.autoName(for: "Eski", content: "\u{A0}\u{3000}\nYeni") == nil)
        #expect(NoteStore.autoName(for: "Eski", content: "Yeni\r\ngövde") == "Yeni")
    }

    @Test func titleIsNormalizedAfterMapping() throws {
        // NFC is applied to the mapped text, so a decomposed ğ next to a mapped "/" still composes.
        let title = try #require(NoteStore.title(from: "g\u{306}/x"))
        #expect(title.unicodeScalars.elementsEqual("ğ-x".unicodeScalars))
    }

    @Test func titleOfAHugeNoteOnlyReadsItsFirstLine() {
        let note = "# Başlık\n" + String(repeating: "uzun bir satır daha 😀\n", count: 300_000)
        let clock = ContinuousClock()
        var title: String?
        let elapsed = clock.measure {
            title = NoteStore.title(from: note)
            _ = NoteStore.autoName(for: "Başlık", content: note)
        }
        #expect(title == "Başlık")
        #expect(elapsed < .milliseconds(50))
    }

    @Test(arguments: [
        ("Adsız", "Adsız"), ("Adsız 2", "Adsız"), ("Adsız 12", "Adsız"), ("Plan 2026", "Plan"),
        ("Adsız 1", "Adsız 1"), ("Adsız 02", "Adsız 02"), ("Adsız 2a", "Adsız 2a"), ("Adsız -3", "Adsız -3"),
        (" 2", " 2"), ("2", "2"),
    ])
    func baseName(name: String, expected: String) {
        #expect(NoteStore.baseName(name) == expected)
    }

    @Test func autoNamedNotes() {
        #expect(NoteStore.isAutoNamed("Adsız", content: ""))
        #expect(NoteStore.isAutoNamed("Adsız 3", content: "# Bambaşka"))
        #expect(NoteStore.isAutoNamed("Alışveriş", content: "# Alışveriş\n- süt"))
        #expect(NoteStore.isAutoNamed("Alışveriş 2", content: "Alışveriş"))
        #expect(NoteStore.isAutoNamed("Bölüm 2", content: "Bölüm 2"))
        #expect(!NoteStore.isAutoNamed("Elle verilmiş", content: "# Alışveriş"))
        #expect(!NoteStore.isAutoNamed("alışveriş", content: "Alışveriş"))
        #expect(!NoteStore.isAutoNamed("Toplantı", content: ""))
    }

    @Test func autoNameFollowsTheFirstLine() {
        #expect(NoteStore.autoName(for: "Adsız", content: "# Yeni başlık\n") == "Yeni başlık")
        #expect(NoteStore.autoName(for: "Eski", content: "Yeni") == "Yeni")
        #expect(NoteStore.autoName(for: "eski", content: "Eski") == "Eski")
        #expect(NoteStore.autoName(for: "Aynı", content: "# Aynı\nmetin") == nil)
        #expect(NoteStore.autoName(for: "Aynı 2", content: "Aynı") == nil)
        #expect(NoteStore.autoName(for: "Adsız 2", content: "Adsız") == nil)
    }

    @Test func autoNameKeepsTheNameWhenTheFirstLineIsCleared() {
        #expect(NoteStore.autoName(for: "Eski", content: "") == nil)
        #expect(NoteStore.autoName(for: "Eski", content: "\ngövde") == nil)
        #expect(NoteStore.autoName(for: "Eski", content: "   \ngövde") == nil)
        #expect(NoteStore.autoName(for: "Eski", content: "# ") == nil)
        #expect(NoteStore.autoName(for: "Eski", content: "# \ngövde") == nil)
    }
}

struct UniqueNoteNameTests {
    let root: URL
    let store: NoteStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UniqueNoteNameTests-\(UUID().uuidString)")
        store = try NoteStore(root: root)
    }

    @Test func picksTheFirstFreeSuffix() throws {
        #expect(store.uniqueNoteName("Adsız", in: nil) == "Adsız")
        try store.createNote(named: "Adsız")
        #expect(store.uniqueNoteName("Adsız", in: nil) == "Adsız 2")
        try store.createNote(named: "Adsız 2")
        try store.createNote(named: "Adsız 4")
        #expect(store.uniqueNoteName("Adsız", in: nil) == "Adsız 3")
        #expect(store.uniqueNoteName("Adsız", in: "") == "Adsız 3")
    }

    @Test func isPerFolderAndIgnoresCase() throws {
        try store.createNote(named: "Plan", in: "İş")
        #expect(store.uniqueNoteName("Plan", in: nil) == "Plan")
        #expect(store.uniqueNoteName("plan", in: "İş") == "plan 2")
        #expect(store.uniqueNoteName("Plan", in: "Yok") == "Plan")
    }

    @Test func folderWithTheNoteFileNameCountsAsTaken() throws {
        try store.createFolder(named: "Notlar.md")
        #expect(store.uniqueNoteName("Notlar", in: nil) == "Notlar 2")
    }

    @Test func ignoringTheNoteItselfAllowsKeepingOrRecasingItsName() throws {
        let path = try store.createNote(named: "fikir")
        #expect(store.uniqueNoteName("Fikir", in: nil, ignoring: path) == "Fikir")
        #expect(store.uniqueNoteName("Fikir", in: nil) == "Fikir 2")
        let renamed = try store.rename(path, to: store.uniqueNoteName("Fikir", in: nil, ignoring: path) + ".md")
        #expect(renamed == "Fikir.md")
        #expect(store.notePaths() == ["Fikir.md"])
    }

    @Test func emojiAndTurkishNamesRoundTrip() throws {
        let name = try #require(NoteStore.title(from: "# 🎉 Doğum günü 👨‍👩‍👧"))
        let path = try store.createNote(named: store.uniqueNoteName(name, in: nil))
        #expect(path == "🎉 Doğum günü 👨‍👩‍👧.md")
        #expect(store.uniqueNoteName(name, in: nil) == "🎉 Doğum günü 👨‍👩‍👧 2")
    }
}

struct ConflictCopyNameTests {
    @Test func appendsTheMarkerBeforeTheExtension() {
        #expect(NoteStore.conflictCopyName(for: "Toplantı.md") { _ in false } == "Toplantı (çakışma).md")
        #expect(NoteStore.conflictCopyName(for: "config.json") { _ in false } == "config (çakışma).json")
        #expect(NoteStore.conflictCopyName(for: "Makefile") { _ in false } == "Makefile (çakışma)")
        #expect(NoteStore.conflictCopyName(for: "e\u{301}.md") { _ in false }
            .unicodeScalars.elementsEqual("e\u{301} (çakışma).md".unicodeScalars))
    }

    @Test func picksTheFirstFreeNumber() {
        let existing: Set = ["Not (çakışma).md", "Not (çakışma 2).md"]
        #expect(NoteStore.conflictCopyName(for: "Not.md") { existing.contains($0) } == "Not (çakışma 3).md")
    }

    @Test func urlIsNextToTheFileAndUnused() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ConflictCopyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("a.md")
        try Data().write(to: file)
        try Data().write(to: folder.appendingPathComponent("a (çakışma).md"))
        #expect(NoteStore.conflictCopyURL(for: file) == folder.appendingPathComponent("a (çakışma 2).md"))
    }
}
