import CommonCrypto
import CryptoKit
import Foundation

public enum NoteCryptoError: LocalizedError, Equatable {
    /// Too short, no magic, iteration count out of range, or the plaintext is not UTF-8.
    case damaged
    /// Unknown format version or key derivation: written by a newer app; leave the file alone.
    case newerVersion
    /// Authentication failed: a wrong password and tampered data can not be told apart.
    case wrongPasswordOrDamaged

    public var errorDescription: String? {
        switch self {
        case .damaged: L("This encrypted note is damaged.")
        case .newerVersion: L("This encrypted note was made by a newer version of Notes.")
        case .wrongPasswordOrDamaged: L("The password is wrong or the file is damaged.")
        }
    }
}

/// The `.mdenc` file format (docs/format.md, "Encrypted notes"): a 42-byte header, AES-256-GCM ciphertext, 16-byte tag.
/// The header is the authenticated data. Pure functions; callers keep a `Key` per unlocked file so only the first
/// unlock pays for the key derivation.
public enum NoteCrypto {
    public static let fileExtension = "mdenc"
    public static let defaultIterations: UInt32 = 600_000
    public static let iterationRange: ClosedRange<UInt32> = 10_000...10_000_000

    static let magic = Array("NOTESENC".utf8)
    static let version: UInt8 = 1
    static let kdfPBKDF2SHA256: UInt8 = 1
    static let saltSize = 16
    static let nonceSize = 12
    static let tagSize = 16
    static let headerSize = 42

    /// A derived key with the salt and iteration count it came from (what goes into a file's header).
    /// Never printed: `description` shows no material.
    public struct Key: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public let salt: Data
        public let iterations: UInt32
        let symmetric: SymmetricKey

        public var description: String { "NoteCrypto.Key(iterations: \(iterations))" }
        public var debugDescription: String { description }

        /// Whether `data` is an encrypted note made with this key's salt and iterations, so the key can decrypt it
        /// (or fails authentication) without deriving again. Looks at the header only.
        public func matches(_ data: Data) -> Bool {
            guard let header = try? Header(data) else { return false }
            return header.salt == salt && header.iterations == iterations
        }
    }

    struct Header {
        let iterations: UInt32
        let salt: Data

        init(_ data: Data) throws {
            let bytes = Array(data.prefix(NoteCrypto.headerSize))
            guard data.count >= NoteCrypto.headerSize + NoteCrypto.tagSize,
                  bytes.starts(with: NoteCrypto.magic)
            else { throw NoteCryptoError.damaged }
            guard bytes[8] == NoteCrypto.version, bytes[9] == NoteCrypto.kdfPBKDF2SHA256 else {
                throw NoteCryptoError.newerVersion
            }
            iterations = bytes[10..<14].reduce(0) { $0 << 8 | UInt32($1) }
            guard NoteCrypto.iterationRange.contains(iterations) else { throw NoteCryptoError.damaged }
            salt = Data(bytes[14..<30])
        }
    }

    /// A key for a new password: random salt, `defaultIterations`. Slow on purpose (about 0.2 s): call it off the main
    /// thread.
    public static func newKey(password: String) -> Key {
        newKey(password: password, iterations: defaultIterations)
    }

    /// `iterations` is for tests.
    static func newKey(password: String, iterations: UInt32) -> Key {
        var salt = Data(count: saltSize)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, saltSize, $0.baseAddress!) }
        precondition(status == errSecSuccess, "no random bytes")
        return Key(salt: salt, iterations: iterations, symmetric: derive(password, salt: salt, iterations: iterations))
    }

    /// The key `password` gives for the file `data` (its salt and iterations). Throws `damaged` or `newerVersion` for a
    /// bad header; a wrong password is only found by `decrypt`. Slow like `newKey`: call it off the main thread.
    public static func key(password: String, for data: Data) throws -> Key {
        let header = try Header(data)
        return Key(salt: header.salt, iterations: header.iterations,
                   symmetric: derive(password, salt: header.salt, iterations: header.iterations))
    }

    /// The file bytes for `text` (in on-disk form, see `NoteFile.normalized`), with a new random nonce every call.
    public static func encrypt(_ text: String, with key: Key) throws -> Data {
        try encrypt(text, with: key, nonce: AES.GCM.Nonce())
    }

    /// `nonce` is for the known-answer test; never pass a fixed nonce otherwise.
    static func encrypt(_ text: String, with key: Key, nonce: AES.GCM.Nonce) throws -> Data {
        var header = Data(magic)
        header.append(contentsOf: [version, kdfPBKDF2SHA256])
        withUnsafeBytes(of: key.iterations.bigEndian) { header.append(contentsOf: $0) }
        header.append(key.salt)
        header.append(contentsOf: nonce)
        let box = try AES.GCM.seal(Data(NoteFile.normalized(text).utf8), using: key.symmetric, nonce: nonce,
                                   authenticating: header)
        return header + box.ciphertext + box.tag
    }

    /// The text of the file `data`. Throws `damaged` (bad header, not UTF-8), `newerVersion`, or
    /// `wrongPasswordOrDamaged` (authentication failed, including a key made for another salt or iteration count).
    public static func decrypt(_ data: Data, with key: Key) throws -> String {
        _ = try Header(data)
        let bytes = Data(data)
        let header = bytes.prefix(headerSize)
        do {
            let nonce = try AES.GCM.Nonce(data: bytes[bytes.startIndex + 30..<bytes.startIndex + headerSize])
            let box = try AES.GCM.SealedBox(nonce: nonce,
                                            ciphertext: bytes[(bytes.startIndex + headerSize)..<(bytes.endIndex - tagSize)],
                                            tag: bytes.suffix(tagSize))
            let plain = try AES.GCM.open(box, using: key.symmetric, authenticating: header)
            guard let text = String(data: plain, encoding: .utf8) else { throw NoteCryptoError.damaged }
            return text
        } catch let error as NoteCryptoError {
            throw error
        } catch {
            throw NoteCryptoError.wrongPasswordOrDamaged
        }
    }

    /// The key for a given salt (tests).
    static func key(password: String, salt: Data, iterations: UInt32) -> Key {
        Key(salt: salt, iterations: iterations, symmetric: derive(password, salt: salt, iterations: iterations))
    }

    private static func derive(_ password: String, salt: Data, iterations: UInt32) -> SymmetricKey {
        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBufferPointer { pw in
            salt.withUnsafeBytes { salt in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) }, passwordBytes.count,
                    salt.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                    &derived, derived.count)
            }
        }
        precondition(status == kCCSuccess, "key derivation failed")
        defer { derived.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
        return SymmetricKey(data: derived)
    }
}
