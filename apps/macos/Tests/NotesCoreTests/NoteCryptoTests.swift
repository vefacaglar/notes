import CryptoKit
import Foundation
import Testing
@testable import NotesCore

struct NoteCryptoTests {
    static let iterations: UInt32 = 10_000
    let key = NoteCrypto.newKey(password: "parola", iterations: NoteCryptoTests.iterations)

    @Test(arguments: ["", "hello", "Toplantı İşğüçö ıİ", "emoji 👩‍👩‍👧 🇹🇷", "a\nb\n"])
    func roundTrip(text: String) throws {
        let data = try NoteCrypto.encrypt(text, with: key)
        #expect(try NoteCrypto.decrypt(data, with: key) == text)
        #expect(data.count == 58 + text.utf8.count)
    }

    @Test func crlfAndBOMAreNormalized() throws {
        let data = try NoteCrypto.encrypt("\u{FEFF}a\r\nb", with: key)
        #expect(try NoteCrypto.decrypt(data, with: key) == "a\nb")
    }

    @Test func headerLayout() throws {
        let data = try NoteCrypto.encrypt("x", with: key)
        #expect(Array(data.prefix(8)) == Array("NOTESENC".utf8))
        #expect(data[8] == 1 && data[9] == 1)
        #expect(Array(data[10..<14]) == [0, 0, 0x27, 0x10])
        #expect(data[14..<30] == key.salt)
    }

    @Test func wrongPassword() throws {
        let data = try NoteCrypto.encrypt("secret", with: key)
        let other = NoteCrypto.newKey(password: "başka", iterations: Self.iterations)
        #expect(throws: NoteCryptoError.wrongPasswordOrDamaged) { try NoteCrypto.decrypt(data, with: other) }
        let sameSalt = try NoteCrypto.key(password: "başka", for: data)
        #expect(throws: NoteCryptoError.wrongPasswordOrDamaged) { try NoteCrypto.decrypt(data, with: sameSalt) }
    }

    @Test func everyByteIsAuthenticated() throws {
        let data = try NoteCrypto.encrypt("secret text", with: key)
        for index in 0..<data.count {
            var copy = data
            copy[index] ^= 0x01
            do {
                _ = try NoteCrypto.decrypt(copy, with: key)
                Issue.record("byte \(index) was not authenticated")
            } catch let error as NoteCryptoError {
                if index < 8 { #expect(error == .damaged) }
                else if index < 10 { #expect(error == .newerVersion) }
                else if index == 10 || index == 11 || index == 12 {
                    #expect(error == .damaged || error == .wrongPasswordOrDamaged)
                } else { #expect(error == .wrongPasswordOrDamaged) }
            }
        }
    }

    @Test func truncatedOrExtendedFails() throws {
        let data = try NoteCrypto.encrypt("secret text", with: key)
        for cut in 1...data.count {
            #expect(throws: NoteCryptoError.self) { try NoteCrypto.decrypt(data.dropLast(cut), with: key) }
        }
        #expect(throws: NoteCryptoError.wrongPasswordOrDamaged) { try NoteCrypto.decrypt(data + [0], with: key) }
    }

    @Test func tooShortOrNoMagic() throws {
        let data = try NoteCrypto.encrypt("", with: key)
        #expect(data.count == 58)
        #expect(throws: NoteCryptoError.damaged) { try NoteCrypto.decrypt(Data(), with: key) }
        #expect(throws: NoteCryptoError.damaged) { try NoteCrypto.decrypt(data.dropLast(), with: key) }
        #expect(throws: NoteCryptoError.damaged) { try NoteCrypto.decrypt(Data(repeating: 0x41, count: 100), with: key) }
        #expect(throws: NoteCryptoError.damaged) { try NoteCrypto.key(password: "x", for: Data("hello".utf8)) }
    }

    @Test func unknownVersionAndKDF() throws {
        var data = try NoteCrypto.encrypt("x", with: key)
        data[8] = 2
        #expect(throws: NoteCryptoError.newerVersion) { try NoteCrypto.decrypt(data, with: key) }
        #expect(throws: NoteCryptoError.newerVersion) { try NoteCrypto.key(password: "x", for: data) }
        data[8] = 1
        data[9] = 2
        #expect(throws: NoteCryptoError.newerVersion) { try NoteCrypto.decrypt(data, with: key) }
    }

    @Test func iterationBounds() throws {
        let data = try NoteCrypto.encrypt("x", with: key)
        func with(_ n: UInt32) -> Data {
            var copy = data
            for i in 0..<4 { copy[10 + i] = UInt8((n >> UInt32(24 - 8 * i)) & 0xFF) }
            return copy
        }
        for bad in [0, 9_999, 10_000_001, UInt32.max] as [UInt32] {
            #expect(throws: NoteCryptoError.damaged) { try NoteCrypto.key(password: "x", for: with(bad)) }
        }
        #expect(throws: Never.self) { try NoteCrypto.key(password: "x", for: with(10_000)) }
    }

    @Test func nonceDiffersBetweenEncryptions() throws {
        let a = try NoteCrypto.encrypt("same", with: key)
        let b = try NoteCrypto.encrypt("same", with: key)
        #expect(a[30..<42] != b[30..<42])
        #expect(a != b)
        #expect(a[0..<30] == b[0..<30])
    }

    @Test func keyForDataDecrypts() throws {
        let data = try NoteCrypto.encrypt("içerik", with: key)
        let again = try NoteCrypto.key(password: "parola", for: data)
        #expect(again.salt == key.salt && again.iterations == key.iterations)
        #expect(try NoteCrypto.decrypt(data, with: again) == "içerik")
    }

    @Test func passwordIsNFCNormalized() throws {
        let composed = "caf\u{E9}", decomposed = "cafe\u{301}"
        let k = NoteCrypto.newKey(password: composed, iterations: Self.iterations)
        let data = try NoteCrypto.encrypt("x", with: k)
        let k2 = try NoteCrypto.key(password: decomposed, for: data)
        #expect(try NoteCrypto.decrypt(data, with: k2) == "x")
    }

    @Test func matchesComparesSaltAndIterations() throws {
        let data = try NoteCrypto.encrypt("x", with: key)
        #expect(key.matches(data))
        #expect(!NoteCrypto.newKey(password: "parola", iterations: Self.iterations).matches(data))
        #expect(!key.matches(Data("junk".utf8)))
        var other = data
        other[13] ^= 1
        #expect(!key.matches(other))
    }

    @Test func descriptionHidesMaterial() {
        #expect(!"\(key)".contains("SymmetricKey"))
        #expect(!String(reflecting: key).contains("bytes"))
    }

    @Test func defaultIterationsRoundTrip() throws {
        let k = NoteCrypto.newKey(password: "p")
        #expect(k.iterations == 600_000)
        let data = try NoteCrypto.encrypt("x", with: k)
        #expect(try NoteCrypto.decrypt(data, with: NoteCrypto.key(password: "p", for: data)) == "x")
    }

    @Test func errorMessages() {
        #expect(NoteCryptoError.wrongPasswordOrDamaged.errorDescription == "The password is wrong or the file is damaged.")
    }

    @Test func writesAndReadsBytesAtomically() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("crypto-\(UUID().uuidString).mdenc")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try NoteCrypto.encrypt("x", with: key)
        try NoteFile.write(data, to: url)
        let second = try NoteCrypto.encrypt("y", with: key)
        try NoteFile.write(second, to: url)
        #expect(try NoteFile.readData(url) == second)
    }

    /// The shared test vector (docs/format.md): the Windows port must produce exactly these bytes.
    @Test func knownAnswer() throws {
        let salt = Data(0x00...0x0F)
        let nonce = try AES.GCM.Nonce(data: Data(0x00...0x0B))
        let key = NoteCrypto.key(password: "correct horse", salt: salt, iterations: 10_000)
        let data = try NoteCrypto.encrypt("# Merhaba\nşifreli not\n", with: key, nonce: nonce)
        let hex = "4e4f544553454e43010100002710000102030405060708090a0b0c0d0e0f000102030405060708090a0b59043478fa207924476c2c15bf69de34aaf25bac4a610f213beff55d3b7b60643ffafff21e5309"
        #expect(data.map { String(format: "%02x", $0) }.joined() == hex)
        #expect(try NoteCrypto.decrypt(data, with: key) == "# Merhaba\nşifreli not\n")
    }
}
